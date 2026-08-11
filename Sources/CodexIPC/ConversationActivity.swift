import Foundation

public enum CodexTaskActivityState: String, CaseIterable, Equatable, Sendable {
  case idle
  case working
  case needsApproval
  case needsInput
  case ready
  case blocked

  public var isActive: Bool {
    self == .working || self == .needsApproval || self == .needsInput
  }
}

public enum CodexTaskCurrentActivity:
  String, CaseIterable, Equatable, Hashable, Sendable
{
  case working
  case thinking
  case planning
  case runningCommand
  case editingFiles
  case coordinatingAgents
  case checkingPermissions
  case writingResponse
  case compactingContext
}

public struct ConversationActivity: Equatable, Identifiable, Sendable {
  public let id: String
  public let title: String?
  public let cwd: String?
  public private(set) var state: CodexTaskActivityState
  public private(set) var isUnread: Bool
  public let activeSubagentCount: Int
  public let updatedAt: Date?
  public let turnStartedAt: Date?
  public let lastCompletedTurnAt: Date?
  public let lastCompletedTurnDuration: TimeInterval?
  public let currentActivity: CodexTaskCurrentActivity?

  public init?(conversationState: JSONValue) {
    guard let id = conversationState["id"]?.stringValue else { return nil }
    self.id = id
    self.title = conversationState["title"]?.stringValue
    self.cwd = conversationState["cwd"]?.stringValue
    let isUnread = Self.isUnread(conversationState)
    self.state = Self.activityState(from: conversationState, isUnread: isUnread)
    self.isUnread = isUnread
    let activeTurn = Self.latestActiveTurn(in: conversationState)
    self.activeSubagentCount = state.isActive ? Self.countActiveSubagents(in: activeTurn) : 0
    self.updatedAt = Self.date(from: conversationState["updatedAt"]?.numberValue)
    self.turnStartedAt =
      state.isActive
      ? Self.date(from: activeTurn?["turnStartedAtMs"]?.numberValue)
      : nil
    let completedTurn = Self.latestCompletedTurn(in: conversationState)
    let completedTurnStartedAt = Self.date(
      from: completedTurn?["turnStartedAtMs"]?.numberValue
    )
    let completedTurnDuration = Self.duration(
      fromMilliseconds: completedTurn?["durationMs"]?.numberValue
    )
    if let completedTurnStartedAt, let completedTurnDuration {
      self.lastCompletedTurnAt = completedTurnStartedAt.addingTimeInterval(
        completedTurnDuration
      )
      self.lastCompletedTurnDuration = completedTurnDuration
    } else {
      self.lastCompletedTurnAt = nil
      self.lastCompletedTurnDuration = nil
    }
    self.currentActivity =
      state == .working
      ? Self.currentActivity(in: activeTurn)
      : nil
  }

  public func updatingUnreadState(_ isUnread: Bool) -> ConversationActivity {
    var activity = self
    activity.isUnread = isUnread
    if activity.state == .idle || activity.state == .ready {
      activity.state = isUnread ? .ready : .idle
    }
    return activity
  }

  private static func activityState(
    from state: JSONValue,
    isUnread: Bool
  ) -> CodexTaskActivityState {
    let runtime = state["threadRuntimeStatus"]
    let type = runtime?["type"]?.stringValue
    let flags = Set(runtime?["activeFlags"]?.arrayValue?.compactMap(\.stringValue) ?? [])
    if type == "systemError" { return .blocked }
    if type == "active" {
      if flags.contains("waitingOnApproval") { return .needsApproval }
      if flags.contains("waitingOnUserInput") { return .needsInput }
      return .working
    }
    if isUnread { return .ready }
    return .idle
  }

  private static func isUnread(_ state: JSONValue) -> Bool {
    state["hasUnreadTurn"]?.boolValue == true
      || (state["unreadMessageCount"]?.numberValue ?? 0) > 0
  }

  private static func latestActiveTurn(in state: JSONValue) -> JSONValue? {
    latestTurn(in: state, status: "inProgress")
  }

  private static func latestCompletedTurn(in state: JSONValue) -> JSONValue? {
    latestTurn(in: state, status: "completed")
  }

  private static func latestTurn(in state: JSONValue, status: String) -> JSONValue? {
    let entities =
      state.value(at: "turnHistory", "history", "entitiesByKey")?.objectValue
      .map { Array($0.values) } ?? []
    let matchingTurns = entities.filter { $0["status"]?.stringValue == status }
    return matchingTurns.max(by: {
      ($0["turnStartedAtMs"]?.numberValue ?? 0)
        < ($1["turnStartedAtMs"]?.numberValue ?? 0)
    })
  }

  private static func countActiveSubagents(in activeTurn: JSONValue?) -> Int {
    guard let activeTurn else { return 0 }

    var activeByID: [String: Bool] = [:]

    for item in activeTurn["items"]?.arrayValue ?? [] {
      switch item["type"]?.stringValue {
      case "subAgentActivity":
        guard let id = item["agentThreadId"]?.stringValue else { continue }
        switch item["kind"]?.stringValue {
        case "started": activeByID[id] = true
        case "interrupted": activeByID[id] = false
        default: break
        }

      case "collabAgentToolCall":
        let receiverIDs = item["receiverThreadIds"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let tool = item["tool"]?.stringValue
        for id in receiverIDs {
          if tool == "closeAgent" {
            activeByID[id] = false
          } else if tool == "spawnAgent" || tool == "resumeAgent" || tool == "sendInput" {
            activeByID[id] = true
          }
        }
        for (id, agentState) in item["agentsStates"]?.objectValue ?? [:] {
          let status = agentState["status"]?.stringValue
          activeByID[id] = status == "pendingInit" || status == "running"
        }

      default:
        continue
      }
    }

    return activeByID.values.filter { $0 }.count
  }

  private static func currentActivity(
    in activeTurn: JSONValue?
  ) -> CodexTaskCurrentActivity {
    for item in (activeTurn?["items"]?.arrayValue ?? []).reversed() {
      let type = item["type"]?.stringValue
      let status = item["status"]?.stringValue
      switch type {
      case "contextCompaction" where item["completed"]?.boolValue != true:
        return .compactingContext
      case "commandExecution" where status == "inProgress" || status == "running":
        return .runningCommand
      case "fileChange" where status == "inProgress" || status == "running":
        return .editingFiles
      case "collabAgentToolCall", "subAgentActivity":
        return .coordinatingAgents
      case "automaticApprovalReview":
        return .checkingPermissions
      case "todo-list":
        return .planning
      case "reasoning":
        return .thinking
      case "agentMessage":
        return .writingResponse
      default:
        continue
      }
    }
    return .working
  }

  private static func date(from timestamp: Double?) -> Date? {
    guard let timestamp, timestamp > 0 else { return nil }
    return Date(
      timeIntervalSince1970: timestamp > 1_000_000_000_000 ? timestamp / 1_000 : timestamp)
  }

  private static func duration(fromMilliseconds milliseconds: Double?) -> TimeInterval? {
    guard let milliseconds, milliseconds.isFinite, milliseconds >= 0 else { return nil }
    return milliseconds / 1_000
  }
}
