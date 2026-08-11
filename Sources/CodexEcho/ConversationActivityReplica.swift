import CodexIPC

@MainActor
final class ConversationActivityReplica {
  struct Transition: Equatable {
    let previous: ConversationActivity?
    let current: ConversationActivity
  }

  enum ReadStateResult: Equatable {
    case ignored
    case applied(Transition)
    case snapshotRequired
  }

  enum PatchResult: Equatable {
    case applied(Transition)
    case staleOrMissing
    case invalidAndEvicted
  }

  private struct StoredConversation {
    var revision: Int
    var state: JSONValue
    var activity: ConversationActivity
  }

  private var conversationsByID: [String: StoredConversation] = [:]

  var activities: [ConversationActivity] {
    conversationsByID.values.map(\.activity)
  }

  func activity(for conversationID: String) -> ConversationActivity? {
    conversationsByID[conversationID]?.activity
  }

  @discardableResult
  func replaceSnapshot(
    conversationID: String,
    revision: Int,
    state: JSONValue
  ) -> Transition? {
    guard let activity = ConversationActivity(conversationState: state) else {
      return nil
    }

    let transition = Transition(
      previous: conversationsByID[conversationID]?.activity,
      current: activity
    )
    conversationsByID[conversationID] = StoredConversation(
      revision: revision,
      state: state,
      activity: activity
    )
    return transition
  }

  @discardableResult
  func applyPatches(
    conversationID: String,
    baseRevision: Int,
    revision: Int,
    patches: [JSONPatch]
  ) -> PatchResult {
    guard var stored = conversationsByID[conversationID],
      stored.revision == baseRevision
    else {
      return .staleOrMissing
    }

    do {
      try stored.state.apply(patches)
    } catch {
      return evictInvalidConversation(conversationID)
    }
    guard let activity = ConversationActivity(conversationState: stored.state) else {
      return evictInvalidConversation(conversationID)
    }

    let transition = Transition(previous: stored.activity, current: activity)
    stored.revision = revision
    stored.activity = activity
    conversationsByID[conversationID] = stored
    return .applied(transition)
  }

  @discardableResult
  func updateReadState(
    conversationID: String,
    hasUnreadTurn: Bool
  ) -> ReadStateResult {
    guard var stored = conversationsByID[conversationID] else { return .ignored }

    let previousActivity = stored.activity
    do {
      var patches = [
        JSONPatch(
          operation: .add,
          path: [.key("hasUnreadTurn")],
          value: .bool(hasUnreadTurn)
        )
      ]
      if !hasUnreadTurn {
        patches.append(
          JSONPatch(
            operation: .add,
            path: [.key("unreadMessageCount")],
            value: .number(0)
          ))
      }
      try stored.state.apply(patches)
    } catch {
      return .snapshotRequired
    }

    stored.activity = stored.activity.updatingUnreadState(hasUnreadTurn)
    conversationsByID[conversationID] = stored
    return .applied(Transition(previous: previousActivity, current: stored.activity))
  }

  @discardableResult
  func removeConversations(notIn conversationIDs: Set<String>) -> Set<String> {
    let removedIDs = Set(conversationsByID.keys).subtracting(conversationIDs)
    for conversationID in removedIDs {
      conversationsByID.removeValue(forKey: conversationID)
    }
    return removedIDs
  }

  func remove(_ conversationID: String) {
    conversationsByID.removeValue(forKey: conversationID)
  }

  func removeAll() {
    conversationsByID.removeAll()
  }

  private func evictInvalidConversation(_ conversationID: String) -> PatchResult {
    conversationsByID.removeValue(forKey: conversationID)
    return .invalidAndEvicted
  }
}
