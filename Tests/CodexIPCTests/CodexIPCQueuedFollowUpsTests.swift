import XCTest

@testable import CodexIPC

final class CodexIPCQueuedFollowUpsTests: XCTestCase {
  func testQueuedFollowUpsBroadcastUsesVerifiedVersionAndSubscribedConversation() {
    let message: [String: Any] = [
      "method": "thread-queued-followups-changed",
      "version": 1,
      "params": [
        "conversationId": "thread-1",
        "messages": [
          ["id": "queued-1", "text": "Sensitive text is intentionally ignored"],
          ["id": "queued-2", "text": "Only the count is projected"],
        ],
      ],
    ]

    XCTAssertEqual(
      CodexIPCQueuedFollowUpsChange(
        broadcast: message,
        subscribedConversationIDs: ["thread-1"]
      ),
      CodexIPCQueuedFollowUpsChange(
        conversationID: "thread-1",
        queuedCount: 2
      )
    )

    var oldVersionMessage = message
    oldVersionMessage["version"] = 0
    XCTAssertNil(
      CodexIPCQueuedFollowUpsChange(
        broadcast: oldVersionMessage,
        subscribedConversationIDs: ["thread-1"]
      )
    )
    XCTAssertNil(
      CodexIPCQueuedFollowUpsChange(
        broadcast: message,
        subscribedConversationIDs: ["another-thread"]
      )
    )

    var malformedMessage = message
    malformedMessage["params"] = [
      "conversationId": "thread-1",
      "messages": "not-an-array",
    ]
    XCTAssertNil(
      CodexIPCQueuedFollowUpsChange(
        broadcast: malformedMessage,
        subscribedConversationIDs: ["thread-1"]
      )
    )
  }
}
