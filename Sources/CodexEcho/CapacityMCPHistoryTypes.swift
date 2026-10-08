import Foundation

enum CapacityMCPHistoryRange: String, Codable, CaseIterable, Sendable {
  case currentWindow = "current_window"
  case twentyFourHours = "24h"
  case sevenDays = "7d"
  case thirtyDays = "30d"
  case custom
}

enum CapacityMCPHistoryResolution: String, Codable, CaseIterable, Sendable {
  case auto
  case raw
}

struct CapacityMCPHistoryQueryRequest: Codable, Equatable, Sendable {
  var windowDurationMinutes: Int?
  var range: CapacityMCPHistoryRange?
  var startAt: Date?
  var endAt: Date?
  var resolution: CapacityMCPHistoryResolution?
  var maxPoints: Int?
  var cursor: String?

  init(
    windowDurationMinutes: Int? = nil,
    range: CapacityMCPHistoryRange? = nil,
    startAt: Date? = nil,
    endAt: Date? = nil,
    resolution: CapacityMCPHistoryResolution? = nil,
    maxPoints: Int? = nil,
    cursor: String? = nil
  ) {
    self.windowDurationMinutes = windowDurationMinutes
    self.range = range
    self.startAt = startAt
    self.endAt = endAt
    self.resolution = resolution
    self.maxPoints = maxPoints
    self.cursor = cursor
  }
}

struct CapacityMCPHistoryWindowContext: Codable, Equatable, Sendable {
  let slot: String
  let windowDurationMinutes: Int
  let remainingPercent: Int
  let observedAt: Date
  let resetsAt: Date?

  init(
    slot: String,
    windowDurationMinutes: Int,
    remainingPercent: Int,
    observedAt: Date,
    resetsAt: Date?
  ) {
    self.slot = slot
    self.windowDurationMinutes = windowDurationMinutes
    self.remainingPercent = min(max(remainingPercent, 0), 100)
    self.observedAt = observedAt
    self.resetsAt = resetsAt
  }
}

struct CapacityMCPHistoryQueryContext: Codable, Equatable, Sendable {
  var currentWindows: [CapacityMCPHistoryWindowContext]

  init(currentWindows: [CapacityMCPHistoryWindowContext] = []) {
    self.currentWindows = currentWindows
  }
}

enum CapacityMCPHistoryStatus: String, Codable, Sendable {
  case available
  case missing
}

enum CapacityMCPHistoryWindowIdentityStatus: String, Codable, Sendable {
  case matchedSlot = "matched_slot"
  case legacyDurationOnly = "legacy_duration_only"
  case ambiguousWindowIdentity = "ambiguous_window_identity"
}

struct CapacityMCPHistorySummary: Codable, Equatable, Sendable {
  let observedDecreasePoints: Int
  let observedIncreasePoints: Int
  let observedSeconds: TimeInterval
  let requestedSeconds: TimeInterval
  let coverageRatio: Double
  let gapCount: Int
  let resetScheduleChangeCount: Int
  let sourcePointCount: Int
  var returnedPointCount: Int
}

struct CapacityMCPHistoryWindowResult: Codable, Equatable, Sendable {
  let slot: String?
  let windowDurationMinutes: Int
  let identityStatus: CapacityMCPHistoryWindowIdentityStatus
  let rangeStart: Date
  let rangeEnd: Date
  var summary: CapacityMCPHistorySummary
}

struct CapacityMCPHistoryPoint: Codable, Equatable, Sendable {
  let observedAt: Date
  let remainingPercent: Int
  let windowDurationMinutes: Int
  let gapBefore: Bool
  let isIncrease: Bool
  let resetScheduleChanged: Bool
}

struct CapacityMCPHistoryQueryResult: Codable, Equatable, Sendable {
  let schemaVersion: Int
  let historyStatus: CapacityMCPHistoryStatus
  let historyThrough: Date?
  let analysisCutoff: Date
  var windows: [CapacityMCPHistoryWindowResult]
  let points: [CapacityMCPHistoryPoint]
  let truncated: Bool
  let omittedEventPoints: Int
  let nextCursor: String?
}

struct CapacityMCPWindowArithmetic: Codable, Equatable, Sendable {
  let windowStartedAt: Date
  let progressRatio: Double
  let expectedRemainingPercent: Double
  let remainingVsEvenPacePoints: Double
  let linearScenario: CapacityMCPLinearScenario?
}

struct CapacityMCPLinearScenario: Codable, Equatable, Sendable {
  enum Basis: String, Codable, Sendable {
    case netConsumptionSinceInferredWindowStart =
      "net_consumption_since_inferred_window_start"
  }

  enum Assumption: String, Codable, Sendable {
    case sameAverageNetConsumptionContinues =
      "same_average_net_consumption_continues"
  }

  let basis: Basis
  let assumption: Assumption
  let depletionAt: Date?
  let remainingAtReset: Double?
}

enum CapacityMCPWindowArithmeticPolicy {
  static func make(
    context: CapacityMCPHistoryWindowContext,
    now: Date,
    isAvailable: Bool,
    freshnessInterval: TimeInterval = 6 * 60
  ) -> CapacityMCPWindowArithmetic? {
    guard
      context.windowDurationMinutes > 0,
      let resetsAt = context.resetsAt,
      resetsAt > now
    else { return nil }

    let duration = TimeInterval(context.windowDurationMinutes) * 60
    let windowStartedAt = resetsAt.addingTimeInterval(-duration)
    let elapsed = context.observedAt.timeIntervalSince(windowStartedAt)
    guard elapsed >= 0, elapsed <= duration else { return nil }

    let progress = elapsed / duration
    let expectedRemaining = 100 * (1 - progress)
    let evenPaceDelta = Double(context.remainingPercent) - expectedRemaining
    var scenario: CapacityMCPLinearScenario?

    if
      isAvailable,
      now.timeIntervalSince(context.observedAt) <= freshnessInterval,
      now >= context.observedAt,
      progress >= 0.1,
      elapsed > 0
    {
      let consumed = Double(100 - context.remainingPercent)
      let rate = consumed / elapsed
      if rate > 0 {
        let depletionAt = windowStartedAt.addingTimeInterval(100 / rate)
        let remainingAtReset = max(0, 100 - (rate * duration))
        scenario = CapacityMCPLinearScenario(
          basis: .netConsumptionSinceInferredWindowStart,
          assumption: .sameAverageNetConsumptionContinues,
          depletionAt: depletionAt <= resetsAt ? depletionAt : nil,
          remainingAtReset: depletionAt <= resetsAt ? nil : remainingAtReset
        )
      }
    }

    return CapacityMCPWindowArithmetic(
      windowStartedAt: windowStartedAt,
      progressRatio: progress,
      expectedRemainingPercent: expectedRemaining,
      remainingVsEvenPacePoints: evenPaceDelta,
      linearScenario: scenario
    )
  }
}

enum CapacityMCPHistoryQueryError: Error, LocalizedError, Equatable {
  case invalidArguments(String)
  case malformedLine(byteOffset: UInt64)
  case cursorInvalidated
  case invalidCursor
  case ambiguousWindowIdentity(durationMinutes: Int)

  var errorDescription: String? {
    switch self {
    case .invalidArguments(let reason): reason
    case .malformedLine(let offset):
      "Capacity history is damaged near byte offset \(offset)."
    case .cursorInvalidated:
      "The capacity history changed while this cursor was active."
    case .invalidCursor: "The capacity history cursor is invalid."
    case .ambiguousWindowIdentity(let duration):
      "More than one current window uses duration \(duration)."
    }
  }

  var code: String {
    switch self {
    case .invalidArguments: "invalid_arguments"
    case .malformedLine: "history_corrupt"
    case .cursorInvalidated: "cursor_invalidated"
    case .invalidCursor: "invalid_cursor"
    case .ambiguousWindowIdentity: "ambiguous_window_identity"
    }
  }
}
