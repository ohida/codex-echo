import Foundation

public struct CodexRateLimitResetCredits: Equatable, Sendable {
  public let availableCount: Int
  public let expirationDates: [Date]

  public init(
    availableCount: Int,
    expirationDates: [Date]
  ) {
    self.availableCount = max(availableCount, 0)
    self.expirationDates = Array(
      expirationDates.prefix(self.availableCount)
    )
  }

  fileprivate init?(object: Any?) {
    guard
      let object = object as? [String: Any],
      let availableCount = (object["availableCount"] as? NSNumber)?.intValue
    else { return nil }

    let expirationDates: [Date] = (object["credits"] as? [Any])?.compactMap {
      value -> Date? in
      guard let credit = value as? [String: Any] else { return nil }
      return (credit["expiresAt"] as? NSNumber).map {
        Date(timeIntervalSince1970: $0.doubleValue)
      }
    } ?? []

    self.init(
      availableCount: availableCount,
      expirationDates: expirationDates
    )
  }
}

public struct CodexRateLimitWindowSlot: RawRepresentable, Codable, Hashable,
  Sendable
{
  public static let primary = Self(rawValue: "primary")
  public static let secondary = Self(rawValue: "secondary")

  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }
}

public struct CodexRateLimitWindow: Equatable, Sendable {
  public let slot: CodexRateLimitWindowSlot
  public let usedPercent: Int
  public let windowDurationMinutes: Int?
  public let resetsAt: Date?

  public var remainingPercent: Int {
    100 - usedPercent
  }

  public init(
    slot: CodexRateLimitWindowSlot,
    usedPercent: Int,
    windowDurationMinutes: Int? = nil,
    resetsAt: Date? = nil
  ) {
    self.slot = slot
    self.usedPercent = min(max(usedPercent, 0), 100)
    self.windowDurationMinutes = windowDurationMinutes.flatMap {
      $0 > 0 ? $0 : nil
    }
    self.resetsAt = resetsAt
  }

  fileprivate init?(
    slot: CodexRateLimitWindowSlot,
    object: Any?
  ) {
    guard
      let object = object as? [String: Any],
      let usedPercent = (object["usedPercent"] as? NSNumber)?.intValue
    else { return nil }

    self.init(
      slot: slot,
      usedPercent: usedPercent,
      windowDurationMinutes:
        (object["windowDurationMins"] as? NSNumber)?.intValue,
      resetsAt: (object["resetsAt"] as? NSNumber).map {
        Date(timeIntervalSince1970: $0.doubleValue)
      }
    )
  }

  fileprivate func mergingMissingMetadata(
    from previous: Self?
  ) -> Self {
    guard let previous, previous.slot == slot else { return self }
    return Self(
      slot: slot,
      usedPercent: usedPercent,
      windowDurationMinutes:
        windowDurationMinutes ?? previous.windowDurationMinutes,
      resetsAt: resetsAt ?? previous.resetsAt
    )
  }
}

public struct CodexUsageSnapshot: Equatable, Sendable {
  public static let mainLimitID = "codex"

  public let limitID: String
  public let windows: [CodexRateLimitWindow]
  public let rateLimitResetCredits: CodexRateLimitResetCredits?

  public var primaryWindow: CodexRateLimitWindow? {
    windows.first { $0.slot == .primary }
  }

  public var secondaryWindow: CodexRateLimitWindow? {
    windows.first { $0.slot == .secondary }
  }

  public var constrainingWindow: CodexRateLimitWindow? {
    windows.max { lhs, rhs in
      if lhs.usedPercent != rhs.usedPercent {
        return lhs.usedPercent < rhs.usedPercent
      }
      let lhsReset = lhs.resetsAt ?? .distantFuture
      let rhsReset = rhs.resetsAt ?? .distantFuture
      if lhsReset != rhsReset {
        return lhsReset > rhsReset
      }
      return (lhs.windowDurationMinutes ?? .max)
        > (rhs.windowDurationMinutes ?? .max)
    }
  }

  public var usedPercent: Int {
    constrainingWindow?.usedPercent ?? 0
  }

  public var windowDurationMinutes: Int? {
    constrainingWindow?.windowDurationMinutes
  }

  public var resetsAt: Date? {
    constrainingWindow?.resetsAt
  }

  public var remainingPercent: Int {
    100 - usedPercent
  }

  public func window(
    durationMinutes: Int
  ) -> CodexRateLimitWindow? {
    windows.first { $0.windowDurationMinutes == durationMinutes }
  }

  public func nextResetAt(after date: Date) -> Date? {
    windows.compactMap(\.resetsAt)
      .filter { $0 >= date }
      .min()
  }

  public init(
    limitID: String = Self.mainLimitID,
    usedPercent: Int,
    windowDurationMinutes: Int? = nil,
    resetsAt: Date? = nil,
    rateLimitResetCredits: CodexRateLimitResetCredits? = nil
  ) {
    self.limitID = limitID
    windows = [
      CodexRateLimitWindow(
        slot: .primary,
        usedPercent: usedPercent,
        windowDurationMinutes: windowDurationMinutes,
        resetsAt: resetsAt
      )
    ]
    self.rateLimitResetCredits = rateLimitResetCredits
  }

  public init(
    limitID: String = Self.mainLimitID,
    windows: [CodexRateLimitWindow],
    rateLimitResetCredits: CodexRateLimitResetCredits? = nil
  ) {
    self.limitID = limitID
    self.windows = windows
    self.rateLimitResetCredits = rateLimitResetCredits
  }

  public init(
    limitID: String = Self.mainLimitID,
    primaryWindow: CodexRateLimitWindow?,
    secondaryWindow: CodexRateLimitWindow?,
    rateLimitResetCredits: CodexRateLimitResetCredits? = nil
  ) {
    self.init(
      limitID: limitID,
      windows: [primaryWindow, secondaryWindow].compactMap { $0 },
      rateLimitResetCredits: rateLimitResetCredits
    )
  }

  static func readResult(_ result: [String: Any]) -> Self? {
    let resetCredits = CodexRateLimitResetCredits(
      object: result["rateLimitResetCredits"]
    )
    if let buckets = result["rateLimitsByLimitId"] as? [String: Any],
      let mainBucket = buckets[mainLimitID] as? [String: Any],
      let snapshot = Self(
        rateLimitObject: mainBucket,
        rateLimitResetCredits: resetCredits
      )
    {
      return snapshot
    }
    guard let historicalBucket = result["rateLimits"] as? [String: Any] else {
      return nil
    }
    return Self(
      rateLimitObject: historicalBucket,
      rateLimitResetCredits: resetCredits
    )
  }

  static func updatedNotification(_ params: [String: Any]) -> Self? {
    guard
      let rateLimits = params["rateLimits"] as? [String: Any],
      rateLimits["limitId"] as? String == mainLimitID
    else {
      return nil
    }
    return Self(rateLimitObject: rateLimits)
  }

  func mergingMissingMetadata(from previous: Self?) -> Self {
    guard let previous, previous.limitID == limitID else { return self }
    var mergedWindows = previous.windows
    for window in windows {
      if let index = mergedWindows.firstIndex(where: { $0.slot == window.slot }) {
        mergedWindows[index] = window.mergingMissingMetadata(
          from: mergedWindows[index]
        )
      } else {
        mergedWindows.append(window)
      }
    }
    return Self(
      limitID: limitID,
      windows: mergedWindows,
      rateLimitResetCredits: rateLimitResetCredits ?? previous.rateLimitResetCredits
    )
  }

  func preservingKnownResetCredits(from previous: Self?) -> Self {
    guard
      rateLimitResetCredits == nil,
      let previous,
      previous.limitID == limitID,
      let previousResetCredits = previous.rateLimitResetCredits
    else { return self }

    return Self(
      limitID: limitID,
      windows: windows,
      rateLimitResetCredits: previousResetCredits
    )
  }

  private init?(
    rateLimitObject: [String: Any],
    rateLimitResetCredits: CodexRateLimitResetCredits? = nil
  ) {
    let observedLimitID = rateLimitObject["limitId"] as? String
    guard observedLimitID == nil || observedLimitID == Self.mainLimitID else {
      return nil
    }
    let knownSlots: Set<String> = [
      CodexRateLimitWindowSlot.primary.rawValue,
      CodexRateLimitWindowSlot.secondary.rawValue,
    ]
    let windows = rateLimitObject.compactMap { key, value -> CodexRateLimitWindow? in
      guard let object = value as? [String: Any] else { return nil }
      let hasPositiveDuration =
        (object["windowDurationMins"] as? NSNumber)
        .map { $0.intValue > 0 } ?? false
      guard knownSlots.contains(key) || hasPositiveDuration else { return nil }
      return CodexRateLimitWindow(
        slot: CodexRateLimitWindowSlot(rawValue: key),
        object: object
      )
    }
    .sorted { lhs, rhs in
      let lhsDuration = lhs.windowDurationMinutes ?? .max
      let rhsDuration = rhs.windowDurationMinutes ?? .max
      if lhsDuration != rhsDuration {
        return lhsDuration < rhsDuration
      }
      return lhs.slot.rawValue < rhs.slot.rawValue
    }
    guard !windows.isEmpty else { return nil }
    self.init(
      limitID: observedLimitID ?? Self.mainLimitID,
      windows: windows,
      rateLimitResetCredits: rateLimitResetCredits
    )
  }
}
