import CryptoKit
import Foundation

struct CapacityMCPHistoryQueryEngine: Sendable {
  static let defaultMaxPoints = 300
  static let maximumMaxPoints = 1_000
  static let minimumMaxPoints = 10
  static let gapThreshold: TimeInterval = 11 * 60

  let fileURL: URL
  var context: CapacityMCPHistoryQueryContext

  init(
    fileURL: URL = CapacityHistoryStore.defaultFileURL(),
    context: CapacityMCPHistoryQueryContext = .init()
  ) {
    self.fileURL = fileURL
    self.context = context
  }

  func query(
    _ request: CapacityMCPHistoryQueryRequest,
    now: Date = Date()
  ) throws -> CapacityMCPHistoryQueryResult {
    if let cursor = request.cursor {
      guard request.hasOnlyCursor else {
        throw CapacityMCPHistoryQueryError.invalidArguments(
          "A cursor continuation cannot include initial query arguments."
        )
      }
      return try continueRawQuery(cursor: cursor)
    }

    let maxPoints = request.maxPoints ?? Self.defaultMaxPoints
    guard (Self.minimumMaxPoints...Self.maximumMaxPoints).contains(maxPoints)
    else {
      throw CapacityMCPHistoryQueryError.invalidArguments(
        "max_points must be between 10 and 1000."
      )
    }
    if let duration = request.windowDurationMinutes, duration <= 0 {
      throw CapacityMCPHistoryQueryError.invalidArguments(
        "window_duration_minutes must be positive."
      )
    }

    let range = request.range ?? .twentyFourHours
    let resolution = request.resolution ?? .auto
    try validateRangeArguments(request, range: range)

    guard let boundary = try stableBoundary() else {
      return CapacityMCPHistoryQueryResult(
        schemaVersion: 1,
        historyStatus: .missing,
        historyThrough: nil,
        analysisCutoff: now,
        windows: [],
        points: [],
        truncated: false,
        omittedEventPoints: 0,
        nextCursor: nil
      )
    }

    switch resolution {
    case .auto:
      return try makeInitialAutoQuery(
        boundary: boundary,
        request: request,
        range: range,
        now: now,
        maxPoints: maxPoints
      )
    case .raw:
      return try makeInitialRawQuery(
        boundary: boundary,
        request: request,
        range: range,
        now: now,
        maxPoints: maxPoints
      )
    }
  }
}

private extension CapacityMCPHistoryQueryRequest {
  var hasOnlyCursor: Bool {
    cursor != nil
      && windowDurationMinutes == nil
      && range == nil
      && startAt == nil
      && endAt == nil
      && resolution == nil
      && maxPoints == nil
  }
}

private extension CapacityMCPHistoryQueryEngine {
  struct StoredObservation: Sendable {
    let observation: CapacityObservation
    let startOffset: UInt64
    let endOffset: UInt64
  }

  struct FileIdentity: Codable, Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    let createdAt: TimeInterval
  }

  struct StableBoundary: Sendable {
    let identity: FileIdentity
    let endOffset: UInt64
  }

  struct ResolvedWindowRange: Codable, Equatable, Sendable {
    let windowDurationMinutes: Int
    let startAt: Date
    let endAt: Date
  }

  struct CursorQueryDescriptor: Codable, Equatable, Sendable {
    let ranges: [ResolvedWindowRange]
    let maxPoints: Int
    let analysisCutoff: Date
  }

  struct RawCursor: Codable, Sendable {
    let schemaVersion: Int
    let queryHash: String
    let query: CursorQueryDescriptor
    let fileIdentity: FileIdentity
    let endOffset: UInt64
    let nextOffset: UInt64
  }

  struct PointFacts: Sendable {
    var gapBefore = false
    var isIncrease = false
    var resetScheduleChanged = false

    var isImportantEvent: Bool {
      gapBefore || isIncrease || resetScheduleChanged
    }
  }

  struct AnalyzedWindow: Sendable {
    let range: ResolvedWindowRange
    let summary: CapacityMCPHistorySummary
  }

  struct RenderedRecord: Sendable {
    let record: StoredObservation
    let facts: PointFacts
  }

  struct RawWindowAccumulator: Sendable {
    let range: ResolvedWindowRange
    var previous: CapacityObservation?
    var observedDecreasePoints = 0
    var observedIncreasePoints = 0
    var observedSeconds: TimeInterval = 0
    var gapCount = 0
    var resetScheduleChangeCount = 0
    var sourcePointCount = 0

    init(
      range: ResolvedWindowRange,
      previous: CapacityObservation? = nil
    ) {
      self.range = range
      self.previous = previous
    }

    mutating func consume(_ record: StoredObservation) -> PointFacts? {
      let observation = record.observation
      guard observation.observedAt <= range.endAt else { return nil }
      guard observation.observedAt >= range.startAt else {
        previous = observation
        return nil
      }

      sourcePointCount += 1
      var facts = PointFacts()
      if let previous {
        let elapsed = observation.observedAt.timeIntervalSince(
          previous.observedAt
        )
        let hasGap =
          previous.sessionID != observation.sessionID
          || previous.windowDurationMinutes != observation.windowDurationMinutes
          || elapsed > CapacityMCPHistoryQueryEngine.gapThreshold
        let scheduleChanged = !CapacityHistoryResetBoundary.matches(
          previous.resetsAt,
          observation.resetsAt
        )
        let delta = observation.remainingPercent - previous.remainingPercent
        facts.gapBefore = hasGap
        facts.isIncrease = !hasGap && delta > 0
        facts.resetScheduleChanged = scheduleChanged
        if scheduleChanged { resetScheduleChangeCount += 1 }
        if hasGap {
          gapCount += 1
        } else {
          let coveredStart = max(previous.observedAt, range.startAt)
          observedSeconds += max(
            0,
            observation.observedAt.timeIntervalSince(coveredStart)
          )
          if delta < 0 { observedDecreasePoints += -delta }
          if delta > 0 { observedIncreasePoints += delta }
        }
      }
      previous = observation
      return facts
    }

    var summary: CapacityMCPHistorySummary {
      let requested = max(0, range.endAt.timeIntervalSince(range.startAt))
      return CapacityMCPHistorySummary(
        observedDecreasePoints: observedDecreasePoints,
        observedIncreasePoints: observedIncreasePoints,
        observedSeconds: observedSeconds,
        requestedSeconds: requested,
        coverageRatio: requested > 0 ? min(1, observedSeconds / requested) : 0,
        gapCount: gapCount,
        resetScheduleChangeCount: resetScheduleChangeCount,
        sourcePointCount: sourcePointCount,
        returnedPointCount: 0
      )
    }
  }

  struct WindowIdentityEvidence: Codable, Sendable {
    let observedAt: Date
    let sessionID: UUID
  }

  struct WindowIdentityTracker: Sendable {
    var latestByDuration: [Int: WindowIdentityEvidence] = [:]

    mutating func observe(_ observation: CapacityObservation) throws {
      let duration = observation.windowDurationMinutes
      if
        let latest = latestByDuration[duration],
        latest.observedAt == observation.observedAt,
        latest.sessionID != observation.sessionID
      {
        throw CapacityMCPHistoryQueryError.ambiguousWindowIdentity(
          durationMinutes: duration
        )
      }
      latestByDuration[duration] = WindowIdentityEvidence(
        observedAt: observation.observedAt,
        sessionID: observation.sessionID
      )
    }
  }

  struct RawContinuationState: Codable, Sendable {
    let previousByDuration: [Int: CapacityObservation]
    let identityEvidenceByDuration: [Int: WindowIdentityEvidence]

    static let empty = Self(
      previousByDuration: [:],
      identityEvidenceByDuration: [:]
    )
  }

  struct RawSummaryScan: Sendable {
    let analyzed: [AnalyzedWindow]
    let historyThrough: Date?
    let stateBeforeOffset: RawContinuationState?
  }

  struct RawPageScan: Sendable {
    let page: [RenderedRecord]
    let firstExtraOffset: UInt64?
  }

  struct AutoWindowEndpoints: Sendable {
    var first: RenderedRecord?
    var last: RenderedRecord?
  }

  struct AutoScan: Sendable {
    let analyzed: [AnalyzedWindow]
    let endpointsByDuration: [Int: AutoWindowEndpoints]
    let increases: [RenderedRecord]
    let gaps: [RenderedRecord]
    let scheduleChanges: [RenderedRecord]
    let shapeCandidates: [RenderedRecord]
    let factImportantPointCount: Int
    let historyThrough: Date?
  }

  struct DeterministicReservoir: Sendable {
    let capacity: Int
    private(set) var records: [RenderedRecord] = []
    private var seenCount: UInt64 = 0

    init(capacity: Int) {
      self.capacity = capacity
    }

    mutating func consider(_ record: RenderedRecord) {
      guard capacity > 0 else { return }
      seenCount += 1
      if records.count < capacity {
        records.append(record)
        return
      }
      let index = Int(mixed(record.record.startOffset) % seenCount)
      if index < capacity {
        records[index] = record
      }
    }

    private func mixed(_ value: UInt64) -> UInt64 {
      var result = value &+ 0x9E37_79B9_7F4A_7C15
      result = (result ^ (result >> 30)) &* 0xBF58_476D_1CE4_E5B9
      result = (result ^ (result >> 27)) &* 0x94D0_49BB_1331_11EB
      return result ^ (result >> 31)
    }
  }

  func validateRangeArguments(
    _ request: CapacityMCPHistoryQueryRequest,
    range: CapacityMCPHistoryRange
  ) throws {
    switch range {
    case .custom:
      guard let start = request.startAt, let end = request.endAt, start < end
      else {
        throw CapacityMCPHistoryQueryError.invalidArguments(
          "custom range requires start_at earlier than end_at."
        )
      }
    default:
      guard request.startAt == nil, request.endAt == nil else {
        throw CapacityMCPHistoryQueryError.invalidArguments(
          "start_at and end_at are valid only for a custom range."
        )
      }
    }
  }

  func resolvedRanges(
    request: CapacityMCPHistoryQueryRequest,
    range: CapacityMCPHistoryRange,
    now: Date,
    durations availableDurations: Set<Int>
  ) throws -> [ResolvedWindowRange] {
    let requestedDuration = request.windowDurationMinutes

    if range == .currentWindow {
      let grouped = Dictionary(
        grouping: context.currentWindows,
        by: \CapacityMCPHistoryWindowContext.windowDurationMinutes
      )
      let durations = requestedDuration.map { [$0] } ?? grouped.keys.sorted()
      guard !durations.isEmpty else {
        throw CapacityMCPHistoryQueryError.invalidArguments(
          "current_window requires current window metadata."
        )
      }
      return try durations.map { duration in
        guard let matches = grouped[duration], !matches.isEmpty else {
          throw CapacityMCPHistoryQueryError.invalidArguments(
            "No current window matches duration \(duration)."
          )
        }
        guard matches.count == 1 else {
          throw CapacityMCPHistoryQueryError.ambiguousWindowIdentity(
            durationMinutes: duration
          )
        }
        guard let resetsAt = matches[0].resetsAt else {
          throw CapacityMCPHistoryQueryError.invalidArguments(
            "current_window requires reset metadata."
          )
        }
        let start = resetsAt.addingTimeInterval(-TimeInterval(duration) * 60)
        guard resetsAt > now, start < now else {
          throw CapacityMCPHistoryQueryError.invalidArguments(
            "The current window reset must be in the future."
          )
        }
        return ResolvedWindowRange(
          windowDurationMinutes: duration,
          startAt: start,
          endAt: now
        )
      }
    }

    let durations: [Int]
    if let requestedDuration {
      durations = [requestedDuration]
    } else {
      durations = availableDurations.sorted()
    }
    let contextsByDuration = Dictionary(
      grouping: context.currentWindows,
      by: \CapacityMCPHistoryWindowContext.windowDurationMinutes
    )
    if let ambiguous = durations.first(where: {
      (contextsByDuration[$0]?.count ?? 0) > 1
    }) {
      throw CapacityMCPHistoryQueryError.ambiguousWindowIdentity(
        durationMinutes: ambiguous
      )
    }

    let end: Date
    let start: Date
    switch range {
    case .twentyFourHours:
      end = now
      start = now.addingTimeInterval(-24 * 60 * 60)
    case .sevenDays:
      end = now
      start = now.addingTimeInterval(-7 * 24 * 60 * 60)
    case .thirtyDays:
      end = now
      start = now.addingTimeInterval(-30 * 24 * 60 * 60)
    case .custom:
      start = request.startAt!
      end = request.endAt!
    case .currentWindow:
      preconditionFailure("Handled above")
    }
    return durations.map {
      ResolvedWindowRange(
        windowDurationMinutes: $0,
        startAt: start,
        endAt: end
      )
    }
  }

  func makePoint(_ rendered: RenderedRecord) -> CapacityMCPHistoryPoint {
    CapacityMCPHistoryPoint(
      observedAt: rendered.record.observation.observedAt,
      remainingPercent: rendered.record.observation.remainingPercent,
      windowDurationMinutes:
        rendered.record.observation.windowDurationMinutes,
      gapBefore: rendered.facts.gapBefore,
      isIncrease: rendered.facts.isIncrease,
      resetScheduleChanged: rendered.facts.resetScheduleChanged
    )
  }

  func makeWindowResults(
    analyzed: [AnalyzedWindow],
    returned: [RenderedRecord]
  ) -> [CapacityMCPHistoryWindowResult] {
    let returnedCounts = Dictionary(
      grouping: returned,
      by: { $0.record.observation.windowDurationMinutes }
    ).mapValues(\.count)
    let contexts = Dictionary(
      grouping: context.currentWindows,
      by: \CapacityMCPHistoryWindowContext.windowDurationMinutes
    )

    return analyzed.map { window in
      let matchingContexts = contexts[window.range.windowDurationMinutes] ?? []
      let identityStatus: CapacityMCPHistoryWindowIdentityStatus
      let slot: String?
      switch matchingContexts.count {
      case 0:
        identityStatus = .legacyDurationOnly
        slot = nil
      case 1:
        identityStatus = .matchedSlot
        slot = matchingContexts[0].slot
      default:
        identityStatus = .ambiguousWindowIdentity
        slot = nil
      }
      var summary = window.summary
      summary.returnedPointCount =
        returnedCounts[window.range.windowDurationMinutes] ?? 0
      return CapacityMCPHistoryWindowResult(
        slot: slot,
        windowDurationMinutes: window.range.windowDurationMinutes,
        identityStatus: identityStatus,
        rangeStart: window.range.startAt,
        rangeEnd: window.range.endAt,
        summary: summary
      )
    }
  }

  func makeInitialAutoQuery(
    boundary initialBoundary: StableBoundary,
    request: CapacityMCPHistoryQueryRequest,
    range: CapacityMCPHistoryRange,
    now: Date,
    maxPoints: Int
  ) throws -> CapacityMCPHistoryQueryResult {
    var boundary = initialBoundary
    for attempt in 0..<2 {
      do {
        let durations = try collectDurations(upTo: boundary.endOffset)
        let descriptor = CursorQueryDescriptor(
          ranges: try resolvedRanges(
            request: request,
            range: range,
            now: now,
            durations: durations
          ),
          maxPoints: maxPoints,
          analysisCutoff: now
        )
        let scan = try scanAuto(
          upTo: boundary.endOffset,
          descriptor: descriptor
        )
        guard
          try currentFileIdentity() == boundary.identity,
          let size = try currentFileSize(),
          size >= boundary.endOffset
        else { throw CapacityMCPHistoryQueryError.cursorInvalidated }
        return makeAutoResult(scan: scan, descriptor: descriptor)
      } catch CapacityMCPHistoryQueryError.cursorInvalidated where attempt == 0 {
        guard let replacement = try stableBoundary() else {
          throw CapacityMCPHistoryQueryError.cursorInvalidated
        }
        boundary = replacement
      }
    }
    throw CapacityMCPHistoryQueryError.cursorInvalidated
  }

  func scanAuto(
    upTo endOffset: UInt64,
    descriptor: CursorQueryDescriptor
  ) throws -> AutoScan {
    var accumulators = Dictionary(
      uniqueKeysWithValues: descriptor.ranges.map {
        ($0.windowDurationMinutes, RawWindowAccumulator(range: $0))
      }
    )
    var endpoints: [Int: AutoWindowEndpoints] = [:]
    let endpointAllowance = descriptor.ranges.count * 2
    let candidateLimit = descriptor.maxPoints * 3 + endpointAllowance
    var increases: [RenderedRecord] = []
    var gaps: [RenderedRecord] = []
    var scheduleChanges: [RenderedRecord] = []
    var shapes = DeterministicReservoir(
      capacity: descriptor.maxPoints + endpointAllowance
    )
    var factImportantPointCount = 0
    var historyThrough: Date?
    var identityTracker = WindowIdentityTracker()

    try forEachRecord(upTo: endOffset) { record in
      let observation = record.observation
      historyThrough = max(
        historyThrough ?? observation.observedAt,
        observation.observedAt
      )
      let duration = observation.windowDurationMinutes
      guard var accumulator = accumulators[duration] else { return }
      let facts = accumulator.consume(record)
      accumulators[duration] = accumulator
      guard let facts else { return }
      try identityTracker.observe(observation)

      let rendered = RenderedRecord(record: record, facts: facts)
      var windowEndpoints = endpoints[duration] ?? AutoWindowEndpoints()
      windowEndpoints.first = windowEndpoints.first ?? rendered
      windowEndpoints.last = rendered
      endpoints[duration] = windowEndpoints

      if facts.isImportantEvent {
        factImportantPointCount += 1
      } else {
        shapes.consider(rendered)
      }
      if facts.isIncrease, increases.count < candidateLimit {
        increases.append(rendered)
      }
      if facts.gapBefore, gaps.count < candidateLimit {
        gaps.append(rendered)
      }
      if facts.resetScheduleChanged,
        scheduleChanges.count < candidateLimit
      {
        scheduleChanges.append(rendered)
      }
    }

    let analyzed = descriptor.ranges.map { range in
      let accumulator = accumulators[range.windowDurationMinutes]
        ?? RawWindowAccumulator(range: range)
      return AnalyzedWindow(
        range: range,
        summary: accumulator.summary
      )
    }
    return AutoScan(
      analyzed: analyzed,
      endpointsByDuration: endpoints,
      increases: increases,
      gaps: gaps,
      scheduleChanges: scheduleChanges,
      shapeCandidates: shapes.records,
      factImportantPointCount: factImportantPointCount,
      historyThrough: historyThrough
    )
  }

  func makeAutoResult(
    scan: AutoScan,
    descriptor: CursorQueryDescriptor
  ) -> CapacityMCPHistoryQueryResult {
    var selected: [RenderedRecord] = []
    var selectedOffsets = Set<UInt64>()
    func add(_ record: RenderedRecord) {
      guard
        selected.count < descriptor.maxPoints,
        selectedOffsets.insert(record.record.startOffset).inserted
      else { return }
      selected.append(record)
    }

    for range in descriptor.ranges {
      guard
        let endpoints = scan.endpointsByDuration[
          range.windowDurationMinutes
        ]
      else { continue }
      if let first = endpoints.first { add(first) }
      if let last = endpoints.last { add(last) }
    }
    scan.increases.sorted(by: chronologicalOrder).forEach(add)
    scan.gaps.sorted(by: chronologicalOrder).forEach(add)
    scan.scheduleChanges.sorted(by: chronologicalOrder).forEach(add)

    let remainingSlots = descriptor.maxPoints - selected.count
    if remainingSlots > 0 {
      let shapes = scan.shapeCandidates
        .filter { !selectedOffsets.contains($0.record.startOffset) }
        .sorted(by: chronologicalOrder)
      if shapes.count <= remainingSlots {
        shapes.forEach(add)
      } else {
        let step = Double(shapes.count) / Double(remainingSlots)
        for index in 0..<remainingSlots {
          add(
            shapes[min(
              shapes.count - 1,
              Int((Double(index) + 0.5) * step)
            )]
          )
        }
      }
    }

    let endpointRecords = scan.endpointsByDuration.values.flatMap {
      [$0.first, $0.last].compactMap { $0 }
    }
    let endpointOffsets = Set(endpointRecords.map { $0.record.startOffset })
    let nonFactEndpointCount = endpointRecords.reduce(into: Set<UInt64>()) {
      offsets, record in
      if !record.facts.isImportantEvent {
        offsets.insert(record.record.startOffset)
      }
    }.count
    let totalImportant = scan.factImportantPointCount + nonFactEndpointCount
    let selectedImportant = selected.reduce(into: 0) { count, record in
      if
        endpointOffsets.contains(record.record.startOffset)
        || record.facts.isImportantEvent
      {
        count += 1
      }
    }
    let sourcePointCount = scan.analyzed.reduce(0) {
      $0 + $1.summary.sourcePointCount
    }
    let ordered = selected.sorted(by: chronologicalOrder)
    return CapacityMCPHistoryQueryResult(
      schemaVersion: 1,
      historyStatus: .available,
      historyThrough: scan.historyThrough,
      analysisCutoff: descriptor.analysisCutoff,
      windows: makeWindowResults(analyzed: scan.analyzed, returned: ordered),
      points: ordered.map(makePoint),
      truncated: ordered.count < sourcePointCount,
      omittedEventPoints: max(0, totalImportant - selectedImportant),
      nextCursor: nil
    )
  }

  func makeInitialRawResult(
    boundary: StableBoundary,
    descriptor: CursorQueryDescriptor,
  ) throws -> CapacityMCPHistoryQueryResult {
    let summary = try scanRawSummary(
      upTo: boundary.endOffset,
      descriptor: descriptor
    )
    let page = try scanRawPage(
      from: 0,
      upTo: boundary.endOffset,
      descriptor: descriptor,
      state: .empty
    )
    guard
      try currentFileIdentity() == boundary.identity,
      let size = try currentFileSize(),
      size >= boundary.endOffset
    else { throw CapacityMCPHistoryQueryError.cursorInvalidated }
    return try rawResult(
      boundary: boundary,
      descriptor: descriptor,
      analyzed: summary.analyzed,
      historyThrough: summary.historyThrough,
      page: page
    )
  }

  func makeInitialRawQuery(
    boundary initialBoundary: StableBoundary,
    request: CapacityMCPHistoryQueryRequest,
    range: CapacityMCPHistoryRange,
    now: Date,
    maxPoints: Int
  ) throws -> CapacityMCPHistoryQueryResult {
    var boundary = initialBoundary
    for attempt in 0..<2 {
      do {
        let durations = try collectDurations(upTo: boundary.endOffset)
        let ranges = try resolvedRanges(
          request: request,
          range: range,
          now: now,
          durations: durations
        )
        return try makeInitialRawResult(
          boundary: boundary,
          descriptor: try normalizedRawDescriptor(
            CursorQueryDescriptor(
              ranges: ranges,
              maxPoints: maxPoints,
              analysisCutoff: now
            )
          )
        )
      } catch CapacityMCPHistoryQueryError.cursorInvalidated where attempt == 0 {
        guard let replacement = try stableBoundary() else {
          throw CapacityMCPHistoryQueryError.cursorInvalidated
        }
        boundary = replacement
      }
    }
    throw CapacityMCPHistoryQueryError.cursorInvalidated
  }

  func rawResult(
    boundary: StableBoundary,
    descriptor: CursorQueryDescriptor,
    analyzed: [AnalyzedWindow],
    historyThrough: Date?,
    page: RawPageScan
  ) throws -> CapacityMCPHistoryQueryResult {
    let cursor: String?
    if let nextOffset = page.firstExtraOffset {
      let cursorValue = RawCursor(
        schemaVersion: 1,
        queryHash: try queryHash(descriptor),
        query: descriptor,
        fileIdentity: boundary.identity,
        endOffset: boundary.endOffset,
        nextOffset: nextOffset
      )
      cursor = try encodeCursor(cursorValue)
    } else {
      cursor = nil
    }
    return CapacityMCPHistoryQueryResult(
      schemaVersion: 1,
      historyStatus: .available,
      historyThrough: historyThrough,
      analysisCutoff: descriptor.analysisCutoff,
      windows: makeWindowResults(analyzed: analyzed, returned: page.page),
      points: page.page.map(makePoint),
      truncated: page.firstExtraOffset != nil,
      omittedEventPoints: 0,
      nextCursor: cursor
    )
  }

  func continueRawQuery(cursor encodedCursor: String) throws
    -> CapacityMCPHistoryQueryResult
  {
    guard encodedCursor.utf8.count <= 16_384 else {
      throw CapacityMCPHistoryQueryError.invalidCursor
    }
    let cursor = try decodeCursor(encodedCursor)
    guard
      cursor.schemaVersion == 1,
      isValidCursorDescriptor(cursor),
      cursor.queryHash == (try queryHash(cursor.query))
    else { throw CapacityMCPHistoryQueryError.invalidCursor }
    guard cursor.nextOffset <= cursor.endOffset else {
      throw CapacityMCPHistoryQueryError.invalidCursor
    }

    guard
      let identity = try currentFileIdentity(),
      identity == cursor.fileIdentity,
      let size = try currentFileSize(),
      size >= cursor.endOffset
    else { throw CapacityMCPHistoryQueryError.cursorInvalidated }

    guard
      try isLineBoundary(cursor.nextOffset),
      try isLineBoundary(cursor.endOffset)
    else {
      throw CapacityMCPHistoryQueryError.invalidCursor
    }

    let summary = try scanRawSummary(
      upTo: cursor.endOffset,
      descriptor: cursor.query,
      stateBefore: cursor.nextOffset
    )
    guard let state = summary.stateBeforeOffset else {
      throw CapacityMCPHistoryQueryError.invalidCursor
    }
    let page = try scanRawPage(
      from: cursor.nextOffset,
      upTo: cursor.endOffset,
      descriptor: cursor.query,
      state: state
    )
    guard
      try currentFileIdentity() == cursor.fileIdentity,
      let sizeAfterRead = try currentFileSize(),
      sizeAfterRead >= cursor.endOffset
    else {
      throw CapacityMCPHistoryQueryError.cursorInvalidated
    }
    return try rawResult(
      boundary: StableBoundary(
        identity: cursor.fileIdentity,
        endOffset: cursor.endOffset
      ),
      descriptor: cursor.query,
      analyzed: summary.analyzed,
      historyThrough: summary.historyThrough,
      page: page
    )
  }

  func scanRawSummary(
    upTo endOffset: UInt64,
    descriptor: CursorQueryDescriptor,
    stateBefore offset: UInt64? = nil
  ) throws -> RawSummaryScan {
    var accumulators = Dictionary(
      uniqueKeysWithValues: descriptor.ranges.map {
        ($0.windowDurationMinutes, RawWindowAccumulator(range: $0))
      }
    )
    var historyThrough: Date?
    var identityTracker = WindowIdentityTracker()
    var stateBeforeOffset: RawContinuationState?

    try forEachRecord(upTo: endOffset) { record in
      let observation = record.observation
      if record.startOffset == offset {
        stateBeforeOffset = RawContinuationState(
          previousByDuration: accumulators.compactMapValues(\.previous),
          identityEvidenceByDuration: identityTracker.latestByDuration
        )
      }
      historyThrough = max(
        historyThrough ?? observation.observedAt,
        observation.observedAt
      )
      let duration = observation.windowDurationMinutes
      guard var accumulator = accumulators[duration] else { return }
      if accumulator.consume(record) != nil {
        try identityTracker.observe(observation)
      }
      accumulators[duration] = accumulator
    }

    let analyzed = descriptor.ranges.map { range in
      let accumulator = accumulators[range.windowDurationMinutes]
        ?? RawWindowAccumulator(range: range)
      return AnalyzedWindow(
        range: range,
        summary: accumulator.summary
      )
    }
    return RawSummaryScan(
      analyzed: analyzed,
      historyThrough: historyThrough,
      stateBeforeOffset: stateBeforeOffset
    )
  }

  func scanRawPage(
    from startOffset: UInt64,
    upTo endOffset: UInt64,
    descriptor: CursorQueryDescriptor,
    state: RawContinuationState
  ) throws -> RawPageScan {
    var accumulators = Dictionary(
      uniqueKeysWithValues: descriptor.ranges.map { range in
        (
          range.windowDurationMinutes,
          RawWindowAccumulator(
            range: range,
            previous: state.previousByDuration[range.windowDurationMinutes]
          )
        )
      }
    )
    var identityTracker = WindowIdentityTracker(
      latestByDuration: state.identityEvidenceByDuration
    )
    var page: [RenderedRecord] = []
    var firstExtraOffset: UInt64?

    try forEachRecord(from: startOffset, upTo: endOffset) { record in
      let observation = record.observation
      let duration = observation.windowDurationMinutes
      guard var accumulator = accumulators[duration] else { return true }

      let isInRange = observation.observedAt >= accumulator.range.startAt
        && observation.observedAt <= accumulator.range.endAt
      if isInRange, page.count >= descriptor.maxPoints {
        firstExtraOffset = record.startOffset
        return false
      }

      let facts = accumulator.consume(record)
      accumulators[duration] = accumulator
      if let facts {
        try identityTracker.observe(observation)
        page.append(RenderedRecord(record: record, facts: facts))
      }
      return true
    }

    return RawPageScan(
      page: page,
      firstExtraOffset: firstExtraOffset
    )
  }

  func chronologicalOrder(
    _ lhs: RenderedRecord,
    _ rhs: RenderedRecord
  ) -> Bool {
    let lhsDate = lhs.record.observation.observedAt
    let rhsDate = rhs.record.observation.observedAt
    if lhsDate == rhsDate {
      return lhs.record.startOffset < rhs.record.startOffset
    }
    return lhsDate < rhsDate
  }

  func isValidCursorDescriptor(_ cursor: RawCursor) -> Bool {
    let descriptor = cursor.query
    guard
      (Self.minimumMaxPoints...Self.maximumMaxPoints)
        .contains(descriptor.maxPoints),
      !descriptor.ranges.isEmpty,
      descriptor.analysisCutoff.timeIntervalSinceReferenceDate.isFinite,
      cursor.nextOffset < cursor.endOffset
    else { return false }

    let durations = descriptor.ranges.map(\.windowDurationMinutes)
    guard Set(durations).count == durations.count else { return false }
    for range in descriptor.ranges {
      guard
        range.windowDurationMinutes > 0,
        range.startAt < range.endAt,
        range.startAt.timeIntervalSinceReferenceDate.isFinite,
        range.endAt.timeIntervalSinceReferenceDate.isFinite
      else { return false }
    }
    return true
  }
}

private extension CapacityMCPHistoryQueryEngine {
  func stableBoundary() throws -> StableBoundary? {
    guard let identity = try currentFileIdentity() else { return nil }
    return StableBoundary(
      identity: identity,
      endOffset: try lastCompleteLineOffset()
    )
  }

  func collectDurations(upTo endOffset: UInt64) throws -> Set<Int> {
    var durations = Set<Int>()
    try forEachRecord(upTo: endOffset) { record in
      durations.insert(record.observation.windowDurationMinutes)
    }
    return durations
  }

  func currentFileIdentity() throws -> FileIdentity? {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
    let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
    let device = (attributes[.systemNumber] as? NSNumber)?.uint64Value ?? 0
    let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
    let createdAt = (attributes[.creationDate] as? Date)?
      .timeIntervalSince1970 ?? 0
    return FileIdentity(device: device, inode: inode, createdAt: createdAt)
  }

  func currentFileSize() throws -> UInt64? {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
    let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
    return (attributes[.size] as? NSNumber)?.uint64Value
  }

  func isLineBoundary(_ offset: UInt64) throws -> Bool {
    guard offset > 0 else { return true }
    let handle = try FileHandle(forReadingFrom: fileURL)
    defer { try? handle.close() }
    try handle.seek(toOffset: offset - 1)
    return try handle.read(upToCount: 1)?.first == 0x0A
  }

  func lastCompleteLineOffset() throws -> UInt64 {
    guard let size = try currentFileSize(), size > 0 else { return 0 }
    let handle = try FileHandle(forReadingFrom: fileURL)
    defer { try? handle.close() }
    try handle.seek(toOffset: size - 1)
    if try handle.read(upToCount: 1)?.first == 0x0A { return size }

    let chunkSize: UInt64 = 64 * 1_024
    var cursor = size
    while cursor > 0 {
      let start = cursor > chunkSize ? cursor - chunkSize : 0
      try handle.seek(toOffset: start)
      let data = try handle.read(upToCount: Int(cursor - start)) ?? Data()
      if let newline = data.lastIndex(of: 0x0A) {
        return start + UInt64(data.distance(from: data.startIndex, to: newline)) + 1
      }
      cursor = start
    }
    return 0
  }

  func forEachRecord(
    upTo endOffset: UInt64,
    _ body: (StoredObservation) throws -> Void
  ) throws {
    try forEachRecord(from: 0, upTo: endOffset) { record in
      try body(record)
      return true
    }
  }

  func forEachRecord(
    from startOffset: UInt64,
    upTo endOffset: UInt64,
    _ body: (StoredObservation) throws -> Bool
  ) throws {
    guard startOffset < endOffset else { return }
    let handle = try FileHandle(forReadingFrom: fileURL)
    defer { try? handle.close() }
    try handle.seek(toOffset: startOffset)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    var buffer = Data()
    var bufferStart = startOffset
    var fileOffset = startOffset

    while fileOffset < endOffset {
      let count = Int(min(64 * 1_024, endOffset - fileOffset))
      let chunk = try handle.read(upToCount: count) ?? Data()
      guard !chunk.isEmpty else { break }
      buffer.append(chunk)
      fileOffset += UInt64(chunk.count)

      while let newline = buffer.firstIndex(of: 0x0A) {
        let afterNewline = buffer.index(after: newline)
        let line = Data(buffer[..<newline])
        let lineEnd = bufferStart
          + UInt64(buffer.distance(from: buffer.startIndex, to: afterNewline))
        if !line.isEmpty {
          let observation: CapacityObservation
          do {
            observation = try decoder.decode(
              CapacityObservation.self,
              from: line
            )
          } catch {
            throw CapacityMCPHistoryQueryError.malformedLine(
              byteOffset: bufferStart
            )
          }
          let shouldContinue = try body(
            StoredObservation(
              observation: observation,
              startOffset: bufferStart,
              endOffset: lineEnd
            )
          )
          if !shouldContinue { return }
        }
        buffer.removeSubrange(..<afterNewline)
        bufferStart = lineEnd
      }
    }
  }

  func queryHash(_ descriptor: CursorQueryDescriptor) throws -> String {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    encoder.outputFormatting = [.sortedKeys]
    let digest = SHA256.hash(data: try encoder.encode(descriptor))
    return digest.map { String(format: "%02x", $0) }.joined()
  }

  func normalizedRawDescriptor(
    _ descriptor: CursorQueryDescriptor
  ) throws -> CursorQueryDescriptor {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .millisecondsSince1970
    return try decoder.decode(
      CursorQueryDescriptor.self,
      from: encoder.encode(descriptor)
    )
  }

  func encodeCursor(_ cursor: RawCursor) throws -> String {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(cursor).base64URLEncodedString()
  }

  func decodeCursor(_ value: String) throws -> RawCursor {
    guard let data = Data(base64URLEncoded: value) else {
      throw CapacityMCPHistoryQueryError.invalidCursor
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .millisecondsSince1970
    do {
      return try decoder.decode(RawCursor.self, from: data)
    } catch {
      throw CapacityMCPHistoryQueryError.invalidCursor
    }
  }
}

private extension Data {
  func base64URLEncodedString() -> String {
    base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  init?(base64URLEncoded value: String) {
    var base64 = value
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    let padding = (4 - (base64.count % 4)) % 4
    base64 += String(repeating: "=", count: padding)
    self.init(base64Encoded: base64)
  }
}
