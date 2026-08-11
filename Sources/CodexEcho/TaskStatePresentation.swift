import CodexIPC
import Foundation

enum TaskActivityPresentationTiming {
  static let elapsedRefreshInterval: TimeInterval = 15
}

extension CodexTaskActivityState {
  var requiresAttention: Bool {
    self == .needsApproval || self == .needsInput || self == .blocked
  }

  var displayLabel: String {
    switch self {
    case .idle: "Idle"
    case .working: "Working"
    case .needsApproval: "Approval Required"
    case .needsInput: "Needs Input"
    case .ready: "Complete"
    case .blocked: "Error"
    }
  }

}

extension CodexTaskCurrentActivity {
  var displayLabel: String {
    switch self {
    case .working: "Working"
    case .thinking: "Thinking"
    case .planning: "Planning"
    case .runningCommand: "Running command"
    case .editingFiles: "Editing files"
    case .coordinatingAgents: "Coordinating agents"
    case .checkingPermissions: "Checking permissions"
    case .writingResponse: "Writing response"
    case .compactingContext: "Compacting context"
    }
  }
}

extension TaskPresentation {
  var showsUnreadCompletionSignal: Bool {
    state == .ready && isUnread
  }

  var currentWorkDisplayLabel: String {
    guard state == .working,
      let currentActivity,
      currentActivity != .working
    else {
      return state.displayLabel
    }
    return currentActivity.displayLabel
  }

  var activityDisplayLabel: String {
    if state == .ready, let durationLabel = completedDurationLabel {
      return "Completed in \(durationLabel)"
    }
    return currentWorkDisplayLabel
  }

  func hoverActivitySummary(relativeTo now: Date = Date()) -> String {
    activitySummary(relativeTo: now, includesProject: false)
  }

  func menuActivitySummary(relativeTo now: Date = Date()) -> String {
    activitySummary(relativeTo: now, includesProject: true)
  }

  var accessibilityValue: String {
    var parts = [activityDisplayLabel]
    if showsUnreadCompletionSignal { parts.append("unread") }
    if activeSubagentCount > 0 {
      let noun = activeSubagentCount == 1 ? "subagent" : "subagents"
      parts.append("\(activeSubagentCount) active \(noun)")
    }
    return parts.joined(separator: ", ")
  }

  func elapsedLabel(relativeTo now: Date = Date()) -> String? {
    guard let turnStartedAt else { return nil }
    let elapsed = now.timeIntervalSince(turnStartedAt)
    guard elapsed >= 0 else { return nil }
    if elapsed < 60 { return "<1 min" }
    if elapsed < 3_600 { return "\(Int(elapsed / 60)) min" }
    if elapsed < 86_400 { return "\(Int(elapsed / 3_600)) hr" }
    return "\(Int(elapsed / 86_400)) d"
  }

  var completedDurationLabel: String? {
    guard let completedDuration,
      completedDuration.isFinite,
      completedDuration >= 0
    else { return nil }
    if completedDuration < 60 { return "under 1 min" }
    if completedDuration < 3_600 { return "\(Int(completedDuration / 60)) min" }
    if completedDuration < 86_400 { return "\(Int(completedDuration / 3_600)) hr" }
    return "\(Int(completedDuration / 86_400)) d"
  }

  private func activitySummary(
    relativeTo now: Date,
    includesProject: Bool
  ) -> String {
    var parts: [String] = []
    if includesProject, let project { parts.append(project) }
    parts.append(activityDisplayLabel)
    if showsUnreadCompletionSignal { parts.append("Unread") }
    if state == .working, let elapsedLabel = elapsedLabel(relativeTo: now) {
      parts.append(elapsedLabel)
    }
    if activeSubagentCount > 0 {
      let noun = activeSubagentCount == 1 ? "subagent" : "subagents"
      parts.append("\(activeSubagentCount) \(noun)")
    }
    return parts.joined(separator: " · ")
  }
}

extension CodexConnectionHealth {
  var accessibilityLabel: String {
    switch self {
    case .live: "Connected to Codex"
    case .connecting: "Connecting to Codex"
    case .degraded(.taskCatalogUnavailable): "Codex task list unavailable"
    case .degraded(.liveActivityUnavailable): "Codex live status unavailable"
    case .incompatible: "Codex version incompatible"
    case .offline: "Waiting for Codex"
    }
  }
}
