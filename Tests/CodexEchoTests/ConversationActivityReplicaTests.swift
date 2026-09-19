import XCTest

@testable import CodexEcho
@testable import CodexIPC

final class ConversationActivityReplicaTests: XCTestCase {
  @MainActor
  func testAppliesRevisionedPatchesAndRetainsStateAfterStaleRevision() {
    let replica = ConversationActivityReplica()

    let snapshot = replica.replaceSnapshot(
      conversationID: "thread-1",
      revision: 4,
      state: conversationState(title: "Initial")
    )
    XCTAssertEqual(snapshot?.previous, nil)
    XCTAssertEqual(snapshot?.current.title, "Initial")

    let applied = replica.applyPatches(
      conversationID: "thread-1",
      baseRevision: 4,
      revision: 5,
      patches: [
        JSONPatch(
          operation: .replace,
          path: [.key("title")],
          value: .string("Updated")
        )
      ]
    )
    XCTAssertEqual(applied.appliedTransition?.previous?.title, "Initial")
    XCTAssertEqual(applied.appliedTransition?.current.title, "Updated")

    XCTAssertEqual(
      replica.applyPatches(
        conversationID: "thread-1",
        baseRevision: 4,
        revision: 6,
        patches: []
      ),
      .staleOrMissing
    )
    XCTAssertEqual(replica.activity(for: "thread-1")?.title, "Updated")

    let next = replica.applyPatches(
      conversationID: "thread-1",
      baseRevision: 5,
      revision: 6,
      patches: [
        JSONPatch(
          operation: .replace,
          path: [.key("title")],
          value: .string("Next")
        )
      ]
    )
    XCTAssertEqual(next.appliedTransition?.current.title, "Next")
  }

  @MainActor
  func testInvalidPatchEvictsOnlyItsConversationAndRequestsRecovery() {
    let replica = ConversationActivityReplica()
    _ = replica.replaceSnapshot(
      conversationID: "thread-1",
      revision: 1,
      state: conversationState(title: "One")
    )
    _ = replica.replaceSnapshot(
      conversationID: "thread-2",
      revision: 1,
      state: conversationState(id: "thread-2", title: "Two")
    )

    XCTAssertEqual(
      replica.applyPatches(
        conversationID: "thread-1",
        baseRevision: 1,
        revision: 2,
        patches: [
          JSONPatch(
            operation: .replace,
            path: [.key("missing")],
            value: .string("Invalid")
          )
        ]
      ),
      .invalidAndEvicted
    )
    XCTAssertNil(replica.activity(for: "thread-1"))
    XCTAssertEqual(replica.activity(for: "thread-2")?.title, "Two")
  }

  @MainActor
  func testPatchThatProducesInvalidActivityEvictsTheConversation() {
    let replica = ConversationActivityReplica()
    _ = replica.replaceSnapshot(
      conversationID: "thread-1",
      revision: 1,
      state: conversationState(title: "Valid")
    )

    XCTAssertEqual(
      replica.applyPatches(
        conversationID: "thread-1",
        baseRevision: 1,
        revision: 2,
        patches: [
          JSONPatch(
            operation: .remove,
            path: [.key("id")]
          )
        ]
      ),
      .invalidAndEvicted
    )
    XCTAssertNil(replica.activity(for: "thread-1"))
  }

  @MainActor
  func testReadStateUpdatesRawDocumentWithoutAdvancingRevision() {
    let replica = ConversationActivityReplica()
    _ = replica.replaceSnapshot(
      conversationID: "thread-1",
      revision: 7,
      state: conversationState(title: "Unread", hasUnreadTurn: true)
    )

    let read = replica.updateReadState(
      conversationID: "thread-1",
      hasUnreadTurn: false
    )
    XCTAssertEqual(read.appliedTransition?.previous?.isUnread, true)
    XCTAssertEqual(read.appliedTransition?.current.isUnread, false)

    let patched = replica.applyPatches(
      conversationID: "thread-1",
      baseRevision: 7,
      revision: 8,
      patches: [
        JSONPatch(
          operation: .replace,
          path: [.key("title")],
          value: .string("Still current")
        )
      ]
    )
    XCTAssertEqual(patched.appliedTransition?.current.title, "Still current")
    XCTAssertEqual(patched.appliedTransition?.current.isUnread, false)
  }

  @MainActor
  func testInvalidSnapshotAndMissingReadStateLeaveExistingReplicaUntouched() {
    let replica = ConversationActivityReplica()
    _ = replica.replaceSnapshot(
      conversationID: "thread-1",
      revision: 1,
      state: conversationState(title: "Valid")
    )

    XCTAssertEqual(
      replica.replaceSnapshot(
        conversationID: "thread-1",
        revision: 2,
        state: .object(["title": .string("Missing ID")])
      ),
      nil
    )
    XCTAssertEqual(
      replica.updateReadState(conversationID: "missing", hasUnreadTurn: true),
      .ignored
    )
    XCTAssertEqual(replica.activity(for: "thread-1")?.title, "Valid")
  }

  @MainActor
  func testPruneRemoveAndClearOwnReplicaMembership() {
    let replica = ConversationActivityReplica()
    for id in ["thread-1", "thread-2", "thread-3"] {
      _ = replica.replaceSnapshot(
        conversationID: id,
        revision: 1,
        state: conversationState(id: id, title: id)
      )
    }

    XCTAssertEqual(
      replica.removeConversations(notIn: ["thread-1", "thread-3"]),
      ["thread-2"]
    )
    XCTAssertEqual(Set(replica.activities.map(\.id)), ["thread-1", "thread-3"])

    replica.remove("thread-1")
    XCTAssertEqual(replica.activities.map(\.id), ["thread-3"])

    replica.removeAll()
    XCTAssertTrue(replica.activities.isEmpty)
  }

  private func conversationState(
    id: String = "thread-1",
    title: String,
    hasUnreadTurn: Bool = false
  ) -> JSONValue {
    .object([
      "id": .string(id),
      "title": .string(title),
      "hasUnreadTurn": .bool(hasUnreadTurn),
      "unreadMessageCount": .number(hasUnreadTurn ? 1 : 0),
      "threadRuntimeStatus": .object([
        "type": .string("idle"),
        "activeFlags": .array([]),
      ]),
    ])
  }
}

private extension ConversationActivityReplica.PatchResult {
  var appliedTransition: ConversationActivityReplica.Transition? {
    guard case .applied(let transition) = self else { return nil }
    return transition
  }
}

private extension ConversationActivityReplica.ReadStateResult {
  var appliedTransition: ConversationActivityReplica.Transition? {
    guard case .applied(let transition) = self else { return nil }
    return transition
  }
}
