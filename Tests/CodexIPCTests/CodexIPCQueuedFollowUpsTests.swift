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

  func testHostScopedVersionsProjectOnlyTheLocalSubscribedQueueCount() {
    for version in [2, 3] {
      for count in [0, 2] {
        let message: [String: Any] = [
          "method": "thread-queued-followups-changed",
          "version": version,
          "params": [
            "hostId": "local",
            "conversationId": "thread-1",
            "messages": Array(repeating: ["text": "Ignored content"], count: count),
          ],
        ]

        XCTAssertEqual(
          CodexIPCQueuedFollowUpsChange(
            broadcast: message,
            subscribedConversationIDs: ["thread-1"]
          ),
          CodexIPCQueuedFollowUpsChange(conversationID: "thread-1", queuedCount: count)
        )
        XCTAssertNil(
          CodexIPCQueuedFollowUpsChange(
            broadcast: message,
            subscribedConversationIDs: ["another-thread"]
          )
        )
      }
    }
  }

  func testHostScopedVersionsRejectRemoteMissingAndMalformedHosts() {
    for version in [2, 3] {
      for hostID: Any? in ["remote-host", nil, NSNull(), 1] {
        var params: [String: Any] = [
          "conversationId": "thread-1",
          "messages": [["text": "Ignored content"]],
        ]
        params["hostId"] = hostID
        XCTAssertNil(
          CodexIPCQueuedFollowUpsChange(
            broadcast: [
              "method": "thread-queued-followups-changed",
              "version": version,
              "params": params,
            ],
            subscribedConversationIDs: ["thread-1"]
          )
        )
      }
    }
  }

  func testQueuedFollowUpsRejectsUnknownVersionsAndMalformedMessages() {
    for version in [0, 4] {
      XCTAssertNil(
        CodexIPCQueuedFollowUpsChange(
          broadcast: [
            "method": "thread-queued-followups-changed",
            "version": version,
            "params": ["hostId": "local", "conversationId": "thread-1", "messages": []],
          ],
          subscribedConversationIDs: ["thread-1"]
        )
      )
    }
    for version in [1, 2, 3] {
      for messages: Any? in [nil, NSNull(), "invalid", ["not": "an array"]] {
        var params: [String: Any] = ["hostId": "local", "conversationId": "thread-1"]
        params["messages"] = messages
        XCTAssertNil(
          CodexIPCQueuedFollowUpsChange(
            broadcast: [
              "method": "thread-queued-followups-changed",
              "version": version,
              "params": params,
            ],
            subscribedConversationIDs: ["thread-1"]
          )
        )
      }
    }
  }

  func testVersionThreeProjectsOnlyCountDespiteAdditionalMetadata() {
    let message: [String: Any] = [
      "method": "thread-queued-followups-changed",
      "version": 3,
      "sourceClientId": "sender",
      "params": [
        "hostId": "local",
        "conversationId": "thread-1",
        "messages": [["text": "Ignored content", "id": "message-1"]],
        "additionalMetadata": "Ignored metadata",
      ],
    ]
    XCTAssertEqual(
      CodexIPCQueuedFollowUpsChange(
        broadcast: message, subscribedConversationIDs: ["thread-1"]
      ),
      CodexIPCQueuedFollowUpsChange(conversationID: "thread-1", queuedCount: 1)
    )
  }
}
