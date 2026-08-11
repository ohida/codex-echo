import CodexAppServer
import Combine
import Foundation

struct CapacityObservation: Codable, Equatable, Identifiable, Sendable {
  private static let legacyWindowDurationMinutes = 7 * 24 * 60

  private enum CodingKeys: String, CodingKey {
    case observedAt
    case remainingPercent
    case sessionID
    case windowDurationMinutes
    case resetsAt
  }

  let observedAt: Date
  let remainingPercent: Int
  let sessionID: UUID
  let windowDurationMinutes: Int
  let resetsAt: Date?

  init(
    observedAt: Date,
    remainingPercent: Int,
    sessionID: UUID,
    windowDurationMinutes: Int,
    resetsAt: Date? = nil
  ) {
    self.observedAt = observedAt
    self.remainingPercent = min(max(remainingPercent, 0), 100)
    self.sessionID = sessionID
    self.windowDurationMinutes = windowDurationMinutes
    self.resetsAt = resetsAt
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      observedAt: try container.decode(Date.self, forKey: .observedAt),
      remainingPercent: try container.decode(Int.self, forKey: .remainingPercent),
      sessionID: try container.decode(UUID.self, forKey: .sessionID),
      windowDurationMinutes: try container.decodeIfPresent(
        Int.self,
        forKey: .windowDurationMinutes
      ) ?? Self.legacyWindowDurationMinutes,
      resetsAt: try container.decodeIfPresent(Date.self, forKey: .resetsAt)
    )
  }

  var id: String {
    [
      sessionID.uuidString,
      String(observedAt.timeIntervalSinceReferenceDate),
      String(remainingPercent),
      String(windowDurationMinutes),
      resetsAt.map { String($0.timeIntervalSinceReferenceDate) } ?? "unknown",
    ].joined(separator: "-")
  }
}

enum CapacityHistoryResetBoundary {
  static let timestampTolerance: TimeInterval = 10

  static func matches(_ lhs: Date?, _ rhs: Date?) -> Bool {
    switch (lhs, rhs) {
    case (.none, .none): true
    case (.some(let lhs), .some(let rhs)):
      abs(lhs.timeIntervalSince(rhs)) <= timestampTolerance
    default: false
    }
  }
}

struct CapacityHistoryLimit: Hashable, Identifiable, Sendable {
  static let unresolved = Self(windowDurationMinutes: 0)

  let windowDurationMinutes: Int

  var id: Int { windowDurationMinutes }

  var title: String {
    guard windowDurationMinutes > 0 else { return "Unavailable" }
    var remainder = windowDurationMinutes
    let days = remainder / (24 * 60)
    remainder %= 24 * 60
    let hours = remainder / 60
    let minutes = remainder % 60
    return [
      days > 0 ? "\(days)-Day" : nil,
      hours > 0 ? "\(hours)-Hour" : nil,
      minutes > 0 ? "\(minutes)-Minute" : nil,
    ]
    .compactMap { $0 }
    .joined(separator: " ")
  }

  var pickerTitle: String {
    "\(title) Limit"
  }

  func matches(_ observation: CapacityObservation) -> Bool {
    observation.windowDurationMinutes == windowDurationMinutes
  }
}

enum CapacityHistoryRangeSelection: String, CaseIterable, Identifiable, Sendable {
  case currentWindow
  case twentyFourHours
  case sevenDays
  case thirtyDays

  var id: Self { self }

  var title: String {
    switch self {
    case .currentWindow: "Current Cycle"
    case .twentyFourHours: "24 Hours"
    case .sevenDays: "7 Days"
    case .thirtyDays: "30 Days"
    }
  }

  var period: CapacityHistoryPeriod? {
    switch self {
    case .currentWindow: nil
    case .twentyFourHours: .twentyFourHours
    case .sevenDays: .sevenDays
    case .thirtyDays: .thirtyDays
    }
  }
}

enum CapacityHistoryAxisStyle: Equatable, Sendable {
  case hourlyWindow
  case twentyFourHours
  case sevenDays
  case thirtyDays

  var projectionPeriod: CapacityHistoryPeriod {
    switch self {
    case .hourlyWindow, .twentyFourHours: .twentyFourHours
    case .sevenDays: .sevenDays
    case .thirtyDays: .thirtyDays
    }
  }

  static func currentWindow(durationMinutes: Int) -> Self {
    switch durationMinutes {
    case ...(12 * 60): .hourlyWindow
    case ...(2 * 24 * 60): .twentyFourHours
    case ...(14 * 24 * 60): .sevenDays
    default: .thirtyDays
    }
  }
}

struct CapacityHistoryViewport: Equatable, Sendable {
  let rangeStart: Date
  let rangeEnd: Date
  let axisStyle: CapacityHistoryAxisStyle
  let title: String
  let includesFuture: Bool

  static func make(
    selection: CapacityHistoryRangeSelection,
    window: CodexRateLimitWindow?,
    now: Date
  ) -> Self? {
    if let period = selection.period {
      return Self(
        rangeStart: now.addingTimeInterval(-period.duration),
        rangeEnd: now,
        axisStyle: period.axisStyle,
        title: period.title,
        includesFuture: false
      )
    }

    guard
      let durationMinutes = window?.windowDurationMinutes,
      durationMinutes > 0,
      let resetsAt = window?.resetsAt,
      resetsAt > now
    else { return nil }
    let duration = TimeInterval(durationMinutes * 60)
    let rangeStart = resetsAt.addingTimeInterval(-duration)
    guard rangeStart <= now else { return nil }
    return Self(
      rangeStart: rangeStart,
      rangeEnd: resetsAt,
      axisStyle: .currentWindow(durationMinutes: durationMinutes),
      title: "Current Cycle",
      includesFuture: true
    )
  }
}

enum CapacityHistoryPeriod: String, CaseIterable, Identifiable, Sendable {
  case twentyFourHours
  case sevenDays
  case thirtyDays

  var id: Self { self }

  var title: String {
    switch self {
    case .twentyFourHours: "24 Hours"
    case .sevenDays: "7 Days"
    case .thirtyDays: "30 Days"
    }
  }

  var duration: TimeInterval {
    switch self {
    case .twentyFourHours: 24 * 60 * 60
    case .sevenDays: 7 * 24 * 60 * 60
    case .thirtyDays: 30 * 24 * 60 * 60
    }
  }

  var axisStyle: CapacityHistoryAxisStyle {
    switch self {
    case .twentyFourHours: .twentyFourHours
    case .sevenDays: .sevenDays
    case .thirtyDays: .thirtyDays
    }
  }
}

struct CapacityHistoryLiveValue: Equatable, Sendable {
  let remainingPercent: Int
  let observedAt: Date
  let sessionID: UUID?
  let windowDurationMinutes: Int
  let resetsAt: Date?
}

enum CapacityHistoryTrendKind: String, CaseIterable, Identifiable, Sendable {
  case sinceReset
  case evenPace

  var id: Self { self }

  var title: String {
    switch self {
    case .sinceReset: "Since Reset"
    case .evenPace: "Even Pace"
    }
  }
}

struct CapacityHistoryTrendLine: Equatable, Identifiable, Sendable {
  static let minimumCycleDuration: TimeInterval = 5 * 60

  let kind: CapacityHistoryTrendKind
  let startsAt: Date
  let endsAt: Date
  let startRemainingPercent: Double
  let endRemainingPercent: Double
  let predictedDepletionAt: Date?

  init(
    kind: CapacityHistoryTrendKind,
    startsAt: Date,
    endsAt: Date,
    startRemainingPercent: Double,
    endRemainingPercent: Double,
    predictedDepletionAt: Date?
  ) {
    self.kind = kind
    self.startsAt = startsAt
    self.endsAt = endsAt
    self.startRemainingPercent = startRemainingPercent
    self.endRemainingPercent = endRemainingPercent
    self.predictedDepletionAt = predictedDepletionAt
  }

  var id: CapacityHistoryTrendKind { kind }
  var title: String { kind.title }

  func remainingPercent(at date: Date) -> Double? {
    guard date >= startsAt, date <= endsAt else { return nil }
    let duration = endsAt.timeIntervalSince(startsAt)
    guard duration > 0 else { return endRemainingPercent }
    let progress = date.timeIntervalSince(startsAt) / duration
    return startRemainingPercent
      + (endRemainingPercent - startRemainingPercent) * progress
  }

  static func makeSinceReset(
    liveValue: CapacityHistoryLiveValue?,
    window: CodexRateLimitWindow?,
    isConnected: Bool,
    now: Date,
    freshnessInterval: TimeInterval = CapacityHistoryProjection.gapThreshold
  ) -> Self? {
    guard let context = liveContext(
      liveValue: liveValue,
      window: window,
      isConnected: isConnected,
      now: now,
      freshnessInterval: freshnessInterval
    ) else { return nil }
    let elapsed = now.timeIntervalSince(context.windowStart)
    guard elapsed >= minimumCycleDuration else { return nil }

    return projectedLine(
      kind: .sinceReset,
      startsAt: context.windowStart,
      startRemainingPercent: 100,
      observedAt: now,
      currentRemainingPercent: context.currentRemainingPercent,
      resetsAt: context.resetsAt
    )
  }

  static func makeEvenPace(
    window: CodexRateLimitWindow?,
    now: Date
  ) -> Self? {
    guard
      let durationMinutes = window?.windowDurationMinutes,
      durationMinutes > 0,
      let resetsAt = window?.resetsAt,
      resetsAt > now
    else { return nil }
    let windowStart = resetsAt.addingTimeInterval(
      -TimeInterval(durationMinutes * 60)
    )
    guard windowStart <= now else { return nil }
    return Self(
      kind: .evenPace,
      startsAt: windowStart,
      endsAt: resetsAt,
      startRemainingPercent: 100,
      endRemainingPercent: 0,
      predictedDepletionAt: nil
    )
  }

  private struct LiveContext {
    let windowStart: Date
    let resetsAt: Date
    let currentRemainingPercent: Double
  }

  private static func liveContext(
    liveValue: CapacityHistoryLiveValue?,
    window: CodexRateLimitWindow?,
    isConnected: Bool,
    now: Date,
    freshnessInterval: TimeInterval
  ) -> LiveContext? {
    guard
      isConnected,
      let liveValue,
      let window,
      let durationMinutes = window.windowDurationMinutes,
      durationMinutes > 0,
      durationMinutes == liveValue.windowDurationMinutes,
      let resetsAt = window.resetsAt,
      let liveResetsAt = liveValue.resetsAt,
      CapacityHistoryResetBoundary.matches(liveResetsAt, resetsAt),
      resetsAt > now,
      liveValue.observedAt <= now,
      now.timeIntervalSince(liveValue.observedAt) <= freshnessInterval
    else { return nil }
    let windowStart = resetsAt.addingTimeInterval(
      -TimeInterval(durationMinutes * 60)
    )
    guard windowStart <= now else { return nil }
    return LiveContext(
      windowStart: windowStart,
      resetsAt: resetsAt,
      currentRemainingPercent: min(
        max(Double(liveValue.remainingPercent), 0),
        100
      )
    )
  }

  private static func projectedLine(
    kind: CapacityHistoryTrendKind,
    startsAt: Date,
    startRemainingPercent: Double,
    observedAt: Date,
    currentRemainingPercent: Double,
    resetsAt: Date
  ) -> Self? {
    let elapsed = observedAt.timeIntervalSince(startsAt)
    guard elapsed > 0 else { return nil }
    let consumed = startRemainingPercent - currentRemainingPercent
    guard consumed >= 0 else { return nil }
    guard consumed > 0 else {
      return Self(
        kind: kind,
        startsAt: startsAt,
        endsAt: resetsAt,
        startRemainingPercent: startRemainingPercent,
        endRemainingPercent: currentRemainingPercent,
        predictedDepletionAt: nil
      )
    }

    let pointsPerSecond = consumed / elapsed
    let timeUntilReset = resetsAt.timeIntervalSince(observedAt)
    let projectedConsumption = pointsPerSecond * timeUntilReset
    if projectedConsumption <= currentRemainingPercent {
      return Self(
        kind: kind,
        startsAt: startsAt,
        endsAt: resetsAt,
        startRemainingPercent: startRemainingPercent,
        endRemainingPercent: max(
          currentRemainingPercent - projectedConsumption,
          0
        ),
        predictedDepletionAt: nil
      )
    }
    let depletionAt = observedAt.addingTimeInterval(
      currentRemainingPercent / pointsPerSecond
    )
    return Self(
      kind: kind,
      startsAt: startsAt,
      endsAt: depletionAt,
      startRemainingPercent: startRemainingPercent,
      endRemainingPercent: 0,
      predictedDepletionAt: depletionAt
    )
  }
}

struct CapacityHistoryChange: Equatable, Identifiable, Sendable {
  let previous: CapacityObservation
  let current: CapacityObservation

  var id: String { current.id }
  var delta: Int { current.remainingPercent - previous.remainingPercent }
}

struct CapacityHistoryGap: Equatable, Identifiable, Sendable {
  let startsAt: Date
  let endsAt: Date

  var id: String {
    "\(startsAt.timeIntervalSinceReferenceDate)-\(endsAt.timeIntervalSinceReferenceDate)"
  }

  var duration: TimeInterval { endsAt.timeIntervalSince(startsAt) }
}

struct CapacityHistorySegment: Equatable, Identifiable, Sendable {
  let observations: [CapacityObservation]

  var id: String { observations.first?.id ?? "empty-segment" }
}

enum HistoryHeartbeatSchedule {
  static func firstFireDate(
    startedAt: Date,
    interval: TimeInterval = CapacityHistoryProjection.heartbeatInterval
  ) -> Date {
    guard interval > 0 else { return startedAt }
    let earliestFire = startedAt.timeIntervalSince1970 + interval
    let boundary = ceil(earliestFire / interval) * interval
    return Date(timeIntervalSince1970: boundary)
  }

  static func publisherAlignmentDelay(
    startedAt: Date,
    interval: TimeInterval = CapacityHistoryProjection.heartbeatInterval
  ) -> TimeInterval {
    max(
      firstFireDate(
        startedAt: startedAt,
        interval: interval
      ).timeIntervalSince(startedAt) - interval,
      0
    )
  }
}

struct CapacityHistoryProjection: Equatable, Sendable {
  static let heartbeatInterval: TimeInterval = 5 * 60
  static let gapSchedulingTolerance: TimeInterval = 60
  static let gapThreshold =
    (2 * heartbeatInterval) + gapSchedulingTolerance

  let period: CapacityHistoryPeriod
  let axisStyle: CapacityHistoryAxisStyle
  let rangeTitle: String
  let includesFuture: Bool
  let rangeStart: Date
  let rangeEnd: Date
  let observationsInRange: [CapacityObservation]
  let segments: [CapacityHistorySegment]
  let changes: [CapacityHistoryChange]
  let gaps: [CapacityHistoryGap]
  let observedDecrease: Int
  let observedIncrease: Int

  var latestObservation: CapacityObservation? {
    observationsInRange.last
  }

  var latestChange: CapacityHistoryChange? {
    changes.last
  }

  func remainingPercent(
    at date: Date,
    liveTail: CapacityHistoryLiveTail?
  ) -> Int? {
    guard date >= rangeStart, date <= rangeEnd else { return nil }

    if
      let liveTail,
      date >= liveTail.startsAt,
      date <= liveTail.endsAt
    {
      return liveTail.remainingPercent
    }

    for segment in segments {
      guard
        let first = segment.observations.first,
        let last = segment.observations.last,
        date >= first.observedAt,
        date <= last.observedAt
      else { continue }

      return segment.observations.last(where: {
        $0.observedAt <= date
      })?.remainingPercent
    }

    return nil
  }

  init(
    observations: [CapacityObservation],
    period: CapacityHistoryPeriod,
    now: Date,
    gapThreshold: TimeInterval = Self.gapThreshold
  ) {
    self.init(
      observations: observations,
      period: period,
      viewport: CapacityHistoryViewport(
        rangeStart: now.addingTimeInterval(-period.duration),
        rangeEnd: now,
        axisStyle: period.axisStyle,
        title: period.title,
        includesFuture: false
      ),
      observedThrough: now,
      gapThreshold: gapThreshold
    )
  }

  init(
    observations: [CapacityObservation],
    period: CapacityHistoryPeriod,
    viewport: CapacityHistoryViewport,
    observedThrough: Date,
    gapThreshold: TimeInterval = Self.gapThreshold
  ) {
    self.period = period
    axisStyle = viewport.axisStyle
    rangeTitle = viewport.title
    includesFuture = viewport.includesFuture
    let selectedRangeStart = viewport.rangeStart
    rangeStart = selectedRangeStart
    rangeEnd = viewport.rangeEnd

    let sorted = observations
      .filter { $0.observedAt <= min(observedThrough, viewport.rangeEnd) }
      .sorted { $0.observedAt < $1.observedAt }
    observationsInRange = sorted.filter {
      $0.observedAt >= selectedRangeStart
        && $0.observedAt <= viewport.rangeEnd
    }

    guard
      let firstInRangeIndex = sorted.firstIndex(where: {
        $0.observedAt >= selectedRangeStart
      })
    else {
      segments = []
      changes = []
      gaps = []
      observedDecrease = 0
      observedIncrease = 0
      return
    }

    let contextStartIndex = max(sorted.startIndex, firstInRangeIndex - 1)
    let context = Array(sorted[contextStartIndex...])
    var projectedSegments: [CapacityHistorySegment] = []
    var currentSegment: [CapacityObservation] = []
    var projectedChanges: [CapacityHistoryChange] = []
    var projectedGaps: [CapacityHistoryGap] = []

    for observation in context {
      guard let previous = currentSegment.last else {
        currentSegment = [observation]
        continue
      }

      let elapsed = observation.observedAt.timeIntervalSince(previous.observedAt)
      let hasGap =
        observation.sessionID != previous.sessionID
        || observation.windowDurationMinutes
          != previous.windowDurationMinutes
        || !CapacityHistoryResetBoundary.matches(
          observation.resetsAt,
          previous.resetsAt
        )
        || elapsed > gapThreshold
      if hasGap {
        projectedSegments.append(
          CapacityHistorySegment(observations: currentSegment)
        )
        projectedGaps.append(
          CapacityHistoryGap(
            startsAt: previous.observedAt,
            endsAt: observation.observedAt
          )
        )
        currentSegment = [observation]
        continue
      }

      currentSegment.append(observation)
      let change = CapacityHistoryChange(
        previous: previous,
        current: observation
      )
      if observation.observedAt >= selectedRangeStart, change.delta != 0 {
        projectedChanges.append(change)
      }
    }

    if !currentSegment.isEmpty {
      projectedSegments.append(
        CapacityHistorySegment(observations: currentSegment)
      )
    }

    segments = projectedSegments
    changes = projectedChanges
    gaps = projectedGaps.filter {
      $0.endsAt >= selectedRangeStart && $0.startsAt <= viewport.rangeEnd
    }
    observedDecrease = projectedChanges.reduce(into: 0) { total, change in
      if change.delta < 0 { total += -change.delta }
    }
    observedIncrease = projectedChanges.reduce(into: 0) { total, change in
      if change.delta > 0 { total += change.delta }
    }
  }
}

enum CapacityHistoryMonitoringState: Equatable, Sendable {
  case disabled(lastRecordedAt: Date?)
  case recording(observedAt: Date)
  case notRecording(lastObservedAt: Date?)

  static func resolve(
    isRecordingEnabled: Bool = true,
    isConnected: Bool,
    liveObservedAt: Date?,
    latestStoredObservedAt: Date?,
    now: Date,
    freshnessInterval: TimeInterval = CapacityHistoryProjection.gapThreshold
  ) -> Self {
    guard isRecordingEnabled else {
      return .disabled(lastRecordedAt: latestStoredObservedAt)
    }
    let lastObservedAt = [liveObservedAt, latestStoredObservedAt]
      .compactMap { $0 }
      .max()

    guard
      isConnected,
      let liveObservedAt,
      now.timeIntervalSince(liveObservedAt) <= freshnessInterval
    else {
      return .notRecording(lastObservedAt: lastObservedAt)
    }
    return .recording(observedAt: liveObservedAt)
  }

  var isRecording: Bool {
    if case .recording = self { return true }
    return false
  }

  var lastObservedAt: Date? {
    switch self {
    case .disabled(let lastRecordedAt):
      lastRecordedAt
    case .recording(let observedAt):
      observedAt
    case .notRecording(let lastObservedAt):
      lastObservedAt
    }
  }
}

struct CapacityHistoryLiveTail: Equatable, Sendable {
  let startsAt: Date
  let endsAt: Date
  let remainingPercent: Int

  init?(
    latestObservation: CapacityObservation?,
    liveRemainingPercent: Int?,
    liveSessionID: UUID?,
    monitoringState: CapacityHistoryMonitoringState,
    now: Date,
    gapThreshold: TimeInterval = CapacityHistoryProjection.gapThreshold
  ) {
    guard
      case .recording(let liveObservedAt) = monitoringState,
      let liveRemainingPercent,
      let liveSessionID,
      liveObservedAt <= now
    else { return nil }

    let canContinueLatestSegment =
      latestObservation?.remainingPercent == liveRemainingPercent
      && latestObservation?.sessionID == liveSessionID
      && latestObservation.map {
        $0.observedAt <= liveObservedAt
          && liveObservedAt.timeIntervalSince($0.observedAt) <= gapThreshold
      } == true

    startsAt =
      canContinueLatestSegment
      ? latestObservation?.observedAt ?? liveObservedAt
      : liveObservedAt
    endsAt = now
    remainingPercent = min(max(liveRemainingPercent, 0), 100)
  }
}

struct CapacityHistoryRecordingPolicy: Sendable {
  static let heartbeatInterval = CapacityHistoryProjection.heartbeatInterval

  private(set) var isRunning = false
  private var sessionID: UUID?
  private var lastRecordedObservation: CapacityObservation?
  private let makeSessionID: @Sendable () -> UUID

  init(
    makeSessionID: @escaping @Sendable () -> UUID = { UUID() }
  ) {
    self.makeSessionID = makeSessionID
  }

  var currentSessionID: UUID? { sessionID }

  mutating func handleConnectionState(
    _ state: CodexAppServerConnectionState
  ) {
    guard state == .running else {
      isRunning = false
      sessionID = nil
      lastRecordedObservation = nil
      return
    }

    if !isRunning {
      isRunning = true
      sessionID = nil
      lastRecordedObservation = nil
    }
  }

  mutating func observation(
    remainingPercent: Int,
    observedAt: Date,
    windowDurationMinutes: Int,
    resetsAt: Date? = nil
  ) -> CapacityObservation? {
    guard isRunning else { return nil }

    let currentSessionID: UUID
    if let sessionID {
      currentSessionID = sessionID
    } else {
      let newSessionID = makeSessionID()
      sessionID = newSessionID
      currentSessionID = newSessionID
    }

    let shouldRecord: Bool
    if let lastRecordedObservation {
      shouldRecord =
        remainingPercent != lastRecordedObservation.remainingPercent
        || windowDurationMinutes
          != lastRecordedObservation.windowDurationMinutes
        || !CapacityHistoryResetBoundary.matches(
          resetsAt,
          lastRecordedObservation.resetsAt
        )
        || observedAt.timeIntervalSince(lastRecordedObservation.observedAt)
          >= Self.heartbeatInterval
    } else {
      shouldRecord = true
    }
    guard shouldRecord else { return nil }

    let observation = CapacityObservation(
      observedAt: observedAt,
      remainingPercent: min(max(remainingPercent, 0), 100),
      sessionID: currentSessionID,
      windowDurationMinutes: windowDurationMinutes,
      resetsAt: resetsAt
    )
    lastRecordedObservation = observation
    return observation
  }

  mutating func beginNewSession() {
    sessionID = nil
    lastRecordedObservation = nil
  }
}

#if DEBUG
  enum CapacityHistoryDebugFixture {
    static let currentSessionID =
      UUID(uuidString: "5A1D0000-0000-0000-0000-000000000001") ?? UUID()

    static func seedIfRequested(
      store: CapacityHistoryStore,
      environment: [String: String] = ProcessInfo.processInfo.environment,
      now: Date = Date()
    ) {
      let fixture = environment[
        "CODEX_ECHO_DEBUG_CAPACITY_HISTORY_FIXTURE"
      ]
      guard
        let fixture,
        ["story", "flat", "microsteps", "trend"].contains(fixture),
        let requestedPath =
          environment["CODEX_ECHO_DEBUG_CAPACITY_HISTORY_FILE"],
        !requestedPath.isEmpty,
        store.fileURL.standardizedFileURL
          == URL(fileURLWithPath: requestedPath).standardizedFileURL
      else { return }

      let minute: TimeInterval = 60
      let firstSession = UUID()
      let currentSession = currentSessionID
      let longWindowDurationMinutes = 7 * 24 * 60
      let shortWindowDurationMinutes = 5 * 60
      let longWindowReset = now.addingTimeInterval(4 * 24 * 60 * 60)
      let shortWindowReset = now.addingTimeInterval(2 * 60 * 60)
      var observations: [CapacityObservation] = []

      if fixture == "trend" {
        let trendPoints: [(TimeInterval, Int, UUID)] = [
          (-70 * 60, 100, firstSession),
          (-60 * 60, 99, firstSession),
          (-50 * 60, 99, firstSession),
          (-35 * 60, 97, currentSession),
          (-25 * 60, 98, currentSession),
          (-12 * 60, 96, currentSession),
          (-2 * 60, 94, currentSession),
          (0, 94, currentSession),
        ]
        observations = trendPoints.map { minuteOffset, remainingPercent, sessionID in
          CapacityObservation(
            observedAt: now.addingTimeInterval(minuteOffset * minute),
            remainingPercent: remainingPercent,
            sessionID: sessionID,
            windowDurationMinutes: longWindowDurationMinutes,
            resetsAt: longWindowReset
          )
        }
      } else if fixture == "microsteps" {
        for index in 0...18 {
          observations.append(
            CapacityObservation(
              observedAt: now.addingTimeInterval(
                TimeInterval((-14 * 60) + (index * 5)) * minute
              ),
              remainingPercent: 92 - index,
              sessionID: firstSession,
              windowDurationMinutes: longWindowDurationMinutes,
              resetsAt: longWindowReset
            )
          )
        }
        for index in 0...20 {
          observations.append(
            CapacityObservation(
              observedAt: now.addingTimeInterval(
                TimeInterval((-5 * 60) + (index * 5)) * minute
              ),
              remainingPercent: 80 - index,
              sessionID: currentSession,
              windowDurationMinutes: longWindowDurationMinutes,
              resetsAt: longWindowReset
            )
          )
        }
      } else if fixture == "flat" {
        for minuteOffset in stride(from: -10 * 60, through: 0, by: 5) {
          observations.append(
            CapacityObservation(
              observedAt: now.addingTimeInterval(
                TimeInterval(minuteOffset) * minute
              ),
              remainingPercent: 88,
              sessionID: currentSession,
              windowDurationMinutes: longWindowDurationMinutes,
              resetsAt: longWindowReset
            )
          )
        }
      } else {
        for minuteOffset in stride(from: -23 * 60, through: -16 * 60, by: 5) {
          let remainingPercent: Int
          switch minuteOffset {
          case ..<(-21 * 60): remainingPercent = 92
          case ..<(-18 * 60): remainingPercent = 88
          default: remainingPercent = 81
          }
          observations.append(
            CapacityObservation(
              observedAt: now.addingTimeInterval(
                TimeInterval(minuteOffset) * minute
              ),
              remainingPercent: remainingPercent,
              sessionID: firstSession,
              windowDurationMinutes: longWindowDurationMinutes,
              resetsAt: longWindowReset
            )
          )
        }

        for minuteOffset in stride(from: -13 * 60, through: 0, by: 5) {
          let remainingPercent: Int
          switch minuteOffset {
          case ..<(-10 * 60): remainingPercent = 100
          case ..<(-7 * 60): remainingPercent = 95
          case ..<(-5 * 60): remainingPercent = 91
          case ..<(-2 * 60): remainingPercent = 96
          case ..<(-30): remainingPercent = 84
          default: remainingPercent = 82
          }
          observations.append(
            CapacityObservation(
              observedAt: now.addingTimeInterval(
                TimeInterval(minuteOffset) * minute
              ),
              remainingPercent: remainingPercent,
              sessionID: currentSession,
              windowDurationMinutes: longWindowDurationMinutes,
              resetsAt: longWindowReset
            )
          )
        }

        for minuteOffset in stride(from: -3 * 60, through: 0, by: 5) {
          let remainingPercent: Int
          switch minuteOffset {
          case ..<(-2 * 60): remainingPercent = 92
          case ..<(-60): remainingPercent = 81
          case ..<(-20): remainingPercent = 72
          default: remainingPercent = 65
          }
          observations.append(
            CapacityObservation(
              observedAt: now.addingTimeInterval(
                TimeInterval(minuteOffset) * minute
              ),
              remainingPercent: remainingPercent,
              sessionID: currentSession,
              windowDurationMinutes: shortWindowDurationMinutes,
              resetsAt: shortWindowReset
            )
          )
        }
      }

      do {
        try store.clearSynchronously()
        for observation in observations {
          try store.appendSynchronouslyForDebug(observation)
        }
      } catch {
        assertionFailure(
          "Failed to seed Capacity history debug fixture: \(error)"
        )
      }
    }
  }
#endif

@MainActor
final class CapacityHistoryRecorder: ObservableObject {
  @Published private(set) var revision = 0
  @Published private(set) var isRecordingEnabled: Bool
  @Published private(set) var isConnected = false
  @Published private(set) var liveRemainingPercent: Int?
  @Published private(set) var liveObservedAt: Date?
  @Published private(set) var liveSessionID: UUID?
  @Published private(set) var liveValuesByDuration: [Int: CapacityHistoryLiveValue] = [:]
  @Published private(set) var recordingErrorDescription: String?

  private let model: CodexActivityModel
  private let store: CapacityHistoryStore
  private let now: @Sendable () -> Date
  private let makeSessionID: @Sendable () -> UUID
  private struct PolicyKey: Hashable {
    let slot: CodexRateLimitWindowSlot
    let durationMinutes: Int?
  }

  private var policies: [PolicyKey: CapacityHistoryRecordingPolicy] = [:]
  private var isClearing = false
  private var cancellables = Set<AnyCancellable>()

  init(
    model: CodexActivityModel,
    store: CapacityHistoryStore,
    now: @escaping @Sendable () -> Date = Date.init,
    makeSessionID: @escaping @Sendable () -> UUID = { UUID() }
  ) {
    self.model = model
    self.store = store
    self.now = now
    self.makeSessionID = makeSessionID
    isRecordingEnabled = model.settings.recordsCapacityHistory

    model.$appServerConnectionState
      .removeDuplicates()
      .sink { [weak self] state in
        self?.handleConnectionState(state)
      }
      .store(in: &cancellables)

    model.$codexUsageSnapshot
      .sink { [weak self] snapshot in
        self?.handleUsageSnapshot(snapshot)
      }
      .store(in: &cancellables)

    model.settings.$recordsCapacityHistory
      .removeDuplicates()
      .dropFirst()
      .sink { [weak self] isEnabled in
        self?.handleRecordingEnabled(isEnabled)
      }
      .store(in: &cancellables)
  }

  func clearHistory() async throws {
    isClearing = true
    defer { isClearing = false }
    try await store.clear()
    for key in Array(policies.keys) {
      policies[key]?.beginNewSession()
    }
    revision += 1
    recordingErrorDescription = nil

    guard isRecordingEnabled else {
      liveSessionID = nil
      return
    }

    guard
      model.appServerConnectionState == .running,
      let snapshot = model.codexUsageSnapshot
    else { return }
    let observations = capture(
      snapshot: snapshot,
      observedAt: now(),
      recordsHistory: true
    )
    for observation in observations {
      try await store.append(observation)
    }
    if !observations.isEmpty {
      revision += 1
    }
  }

  private func handleConnectionState(
    _ state: CodexAppServerConnectionState
  ) {
    isConnected = state == .running
    for key in Array(policies.keys) {
      policies[key]?.handleConnectionState(state)
    }
    guard state != .running else { return }
    liveRemainingPercent = nil
    liveObservedAt = nil
    liveSessionID = nil
    liveValuesByDuration = [:]
  }

  private func handleUsageSnapshot(_ snapshot: CodexUsageSnapshot?) {
    guard let snapshot, model.appServerConnectionState == .running else {
      liveRemainingPercent = nil
      liveObservedAt = nil
      liveSessionID = nil
      liveValuesByDuration = [:]
      return
    }
    let observedAt = now()
    let observations = capture(
      snapshot: snapshot,
      observedAt: observedAt,
      recordsHistory: !isClearing && isRecordingEnabled
    )
    for observation in observations {
      persist(observation)
    }
  }

  private func handleRecordingEnabled(_ isEnabled: Bool) {
    guard isRecordingEnabled != isEnabled else { return }
    isRecordingEnabled = isEnabled
    for key in Array(policies.keys) {
      policies[key]?.beginNewSession()
    }
    liveSessionID = nil
    guard
      isEnabled,
      model.appServerConnectionState == .running,
      let snapshot = model.codexUsageSnapshot
    else { return }

    let observations = capture(
      snapshot: snapshot,
      observedAt: now(),
      recordsHistory: true
    )
    for observation in observations {
      persist(observation)
    }
  }

  func liveValue(
    for limit: CapacityHistoryLimit
  ) -> CapacityHistoryLiveValue? {
    liveValuesByDuration[limit.windowDurationMinutes]
  }

  private func capture(
    snapshot: CodexUsageSnapshot,
    observedAt: Date,
    recordsHistory: Bool
  ) -> [CapacityObservation] {
    var observations: [CapacityObservation] = []
    var liveValues: [Int: CapacityHistoryLiveValue] = [:]

    for window in snapshot.windows {
      guard
        let durationMinutes = window.windowDurationMinutes,
        durationMinutes > 0
      else { continue }
      let key = PolicyKey(
        slot: window.slot,
        durationMinutes: durationMinutes
      )
      var policy = policies[key]
        ?? CapacityHistoryRecordingPolicy(makeSessionID: makeSessionID)
      if !policy.isRunning {
        policy.handleConnectionState(.running)
      }
      let observation = recordsHistory
        ? policy.observation(
          remainingPercent: window.remainingPercent,
          observedAt: observedAt,
          windowDurationMinutes: durationMinutes,
          resetsAt: window.resetsAt
        )
        : nil
      policies[key] = policy
      if let observation {
        observations.append(observation)
      }
      liveValues[durationMinutes] = CapacityHistoryLiveValue(
        remainingPercent: window.remainingPercent,
        observedAt: observedAt,
        sessionID: recordsHistory ? policy.currentSessionID : nil,
        windowDurationMinutes: durationMinutes,
        resetsAt: window.resetsAt
      )
    }

    liveValuesByDuration = liveValues
    liveRemainingPercent = snapshot.remainingPercent
    liveObservedAt = observedAt
    if let constrainingWindow = snapshot.constrainingWindow {
      let key = PolicyKey(
        slot: constrainingWindow.slot,
        durationMinutes: constrainingWindow.windowDurationMinutes
      )
      liveSessionID = recordsHistory ? policies[key]?.currentSessionID : nil
    } else {
      liveSessionID = nil
    }
    return observations
  }

  private func persist(_ observation: CapacityObservation) {
    store.enqueueAppend(observation) { [weak self] result in
      DispatchQueue.main.async {
        guard let self else { return }
        switch result {
        case .success:
          self.recordingErrorDescription = nil
          self.revision += 1
        case .failure(let error):
          self.recordingErrorDescription = error.localizedDescription
        }
      }
    }
  }
}
