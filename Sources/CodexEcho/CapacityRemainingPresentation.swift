struct CapacityRemainingPresentation {
  let remainingPercent: Int
  let ordinaryUsageAllowed: Bool?

  init(_ remainingPercent: Int, ordinaryUsageAllowed: Bool? = nil) {
    self.remainingPercent = min(max(remainingPercent, 0), 100)
    self.ordinaryUsageAllowed = ordinaryUsageAllowed
  }

  // The rounded usage percentage alone cannot prove that requests are blocked.
  var percentText: String {
    remainingPercent == 0 && ordinaryUsageAllowed != false
      ? "<1%" : "\(remainingPercent)%"
  }

  var accessibilityValue: String {
    remainingPercent == 0 && ordinaryUsageAllowed != false
      ? "less than 1 percent remaining"
      : "\(remainingPercent) percent remaining"
  }
}
