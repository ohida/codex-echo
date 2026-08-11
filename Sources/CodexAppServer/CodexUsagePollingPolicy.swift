import Foundation

struct CodexUsagePollingPolicy {
  static let standardInterval: TimeInterval = 5 * 60
  static let lowUsageInterval: TimeInterval = 30
  static let lowUsageBurstDuration: TimeInterval = 10 * 60
  static let resetRefreshGraceInterval: TimeInterval = 1

  private var latestRemainingPercent: Int?
  private var latestChangeAt: Date?

  mutating func observe(remainingPercent: Int, at date: Date) {
    let remainingPercent = min(max(remainingPercent, 0), 100)
    if latestRemainingPercent != remainingPercent {
      latestRemainingPercent = remainingPercent
      latestChangeAt = date
    }
  }

  mutating func reset() {
    latestRemainingPercent = nil
    latestChangeAt = nil
  }

  func pollInterval(at date: Date) -> TimeInterval {
    guard let latestRemainingPercent,
      (1...5).contains(latestRemainingPercent),
      let latestChangeAt,
      date.timeIntervalSince(latestChangeAt) < Self.lowUsageBurstDuration
    else {
      return Self.standardInterval
    }
    return Self.lowUsageInterval
  }

  func pollDelay(at date: Date) -> TimeInterval {
    let interval = pollInterval(at: date)
    guard interval > 0 else { return 0 }
    let current = date.timeIntervalSince1970
    let nextBoundary = (floor(current / interval) + 1) * interval
    return max(nextBoundary - current, 0)
  }

  static func resetRefreshDelay(resetsAt: Date?, now: Date) -> TimeInterval? {
    guard let resetsAt else { return nil }
    let interval = resetsAt.timeIntervalSince(now)
    guard interval > 0 else { return nil }
    return interval + resetRefreshGraceInterval
  }
}
