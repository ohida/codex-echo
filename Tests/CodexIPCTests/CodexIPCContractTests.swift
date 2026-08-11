import Foundation
import XCTest

@testable import CodexIPC

final class CodexIPCContractTests: XCTestCase {
  func testDefaultSocketPathTargetsCodexIPC() {
    XCTAssertTrue(
      CodexIPCClient.defaultSocketURL.path.hasSuffix("/.codex/ipc/ipc.sock")
    )
  }

  func testFrameDecoderHandlesFragmentedAndCoalescedFrames() throws {
    let first = try IPCFrameCodec.encode(payload: Data("first".utf8))
    let second = try IPCFrameCodec.encode(payload: Data("second".utf8))
    var decoder = IPCFrameDecoder()

    XCTAssertTrue(try decoder.append(Data(first.prefix(3))).isEmpty)
    var remainder = Data(first.dropFirst(3))
    remainder.append(second)
    XCTAssertEqual(
      try decoder.append(remainder),
      [Data("first".utf8), Data("second".utf8)]
    )
  }

  func testAppliesCodexStyleArrayPathPatches() throws {
    var value: JSONValue = .object([
      "items": .array([.string("a")]),
      "status": .string("idle"),
    ])

    try value.apply([
      JSONPatch(
        operation: .add,
        path: [.key("items"), .index(1)],
        value: .string("b")
      ),
      JSONPatch(
        operation: .replace,
        path: [.key("status")],
        value: .string("active")
      ),
      JSONPatch(
        operation: .remove,
        path: [.key("items"), .index(0)]
      ),
    ])

    XCTAssertEqual(value["items"], .array([.string("b")]))
    XCTAssertEqual(value["status"], .string("active"))
  }

  func testSummarizesActiveTaskAndLatestSubagentStates() throws {
    let object: [String: Any] = [
      "id": "thread-1",
      "title": "Signal test",
      "cwd": "/tmp/project",
      "updatedAt": 1_700_000_000,
      "threadRuntimeStatus": [
        "type": "active",
        "activeFlags": ["waitingOnUserInput"],
      ],
      "turnHistory": [
        "history": [
          "entitiesByKey": [
            "turn-completed": [
              "turnStartedAtMs": 0,
              "status": "completed",
              "items": [
                [
                  "type": "subAgentActivity",
                  "kind": "started",
                  "agentThreadId": "completed-agent-1",
                ],
                [
                  "type": "subAgentActivity",
                  "kind": "started",
                  "agentThreadId": "completed-agent-2",
                ],
              ],
            ],
            "turn-1": [
              "turnStartedAtMs": 1,
              "status": "inProgress",
              "items": [
                [
                  "type": "subAgentActivity",
                  "kind": "started",
                  "agentThreadId": "agent-1",
                ],
                [
                  "type": "subAgentActivity",
                  "kind": "started",
                  "agentThreadId": "agent-2",
                ],
                [
                  "type": "collabAgentToolCall",
                  "tool": "wait",
                  "receiverThreadIds": ["agent-1"],
                  "agentsStates": [
                    "agent-1": ["status": "completed"]
                  ],
                ],
                [
                  "type": "subAgentActivity",
                  "kind": "interacted",
                  "agentThreadId": "agent-1",
                ],
              ],
            ],
          ]
        ]
      ],
    ]
    let activity = try XCTUnwrap(
      ConversationActivity(conversationState: try JSONValue(any: object))
    )

    XCTAssertEqual(activity.id, "thread-1")
    XCTAssertEqual(activity.state, .needsInput)
    XCTAssertEqual(activity.activeSubagentCount, 1)

    let noActiveSubagentsObject: [String: Any] = [
      "id": "thread-with-completed-subagents",
      "threadRuntimeStatus": ["type": "active"],
      "turnHistory": [
        "history": [
          "entitiesByKey": [
            "turn-completed": [
              "turnStartedAtMs": 1,
              "status": "completed",
              "items": [
                [
                  "type": "subAgentActivity",
                  "kind": "started",
                  "agentThreadId": "old-agent",
                ]
              ],
            ],
            "turn-current": [
              "turnStartedAtMs": 2,
              "status": "inProgress",
              "items": [],
            ],
          ]
        ]
      ],
    ]
    let noActiveSubagentsActivity = try XCTUnwrap(
      ConversationActivity(
        conversationState: try JSONValue(any: noActiveSubagentsObject)
      )
    )
    XCTAssertEqual(noActiveSubagentsActivity.activeSubagentCount, 0)

    let approvalObject: [String: Any] = [
      "id": "thread-approval",
      "threadRuntimeStatus": [
        "type": "active",
        "activeFlags": ["waitingOnApproval"],
      ],
    ]
    let approvalActivity = try XCTUnwrap(
      ConversationActivity(
        conversationState: try JSONValue(any: approvalObject)
      )
    )
    XCTAssertEqual(approvalActivity.state, .needsApproval)
  }

  func testSummarizesCurrentActivityAndTurnStart() throws {
    let turnStartedAtMs = 1_700_000_000_000.0
    let object: [String: Any] = [
      "id": "thread-current-activity",
      "threadRuntimeStatus": ["type": "active"],
      "turnHistory": [
        "history": [
          "entitiesByKey": [
            "turn-current": [
              "turnStartedAtMs": turnStartedAtMs,
              "status": "inProgress",
              "items": [
                ["type": "reasoning"],
                ["type": "commandExecution", "status": "inProgress"],
              ],
            ]
          ]
        ]
      ],
    ]
    let activity = try XCTUnwrap(
      ConversationActivity(conversationState: try JSONValue(any: object))
    )

    XCTAssertEqual(activity.currentActivity, .runningCommand)
    XCTAssertEqual(
      activity.turnStartedAt,
      Date(timeIntervalSince1970: turnStartedAtMs / 1_000)
    )
  }

  func testSummarizesContextCompactionActivity() throws {
    func activity(completed: Bool) throws -> ConversationActivity {
      let object: [String: Any] = [
        "id": "thread-context-compaction",
        "threadRuntimeStatus": ["type": "active"],
        "turnHistory": [
          "history": [
            "entitiesByKey": [
              "turn-current": [
                "status": "inProgress",
                "items": [
                  ["type": "reasoning"],
                  [
                    "type": "contextCompaction",
                    "completed": completed,
                    "source": "automatic",
                  ],
                ],
              ]
            ]
          ]
        ],
      ]
      return try XCTUnwrap(
        ConversationActivity(conversationState: try JSONValue(any: object))
      )
    }

    XCTAssertEqual(
      try activity(completed: false).currentActivity,
      .compactingContext
    )
    XCTAssertEqual(
      try activity(completed: true).currentActivity,
      .thinking
    )
  }

  func testSummarizesLatestCompletedTurnTiming() throws {
    let completedTurnStartedAtMs = 1_700_000_000_000.0
    let durationMs = 245_500.0
    let object: [String: Any] = [
      "id": "thread-completed-timing",
      "hasUnreadTurn": true,
      "threadRuntimeStatus": ["type": "idle"],
      "turnHistory": [
        "history": [
          "entitiesByKey": [
            "turn-older": [
              "turnStartedAtMs": completedTurnStartedAtMs - 1_000,
              "durationMs": 500,
              "status": "completed",
              "items": [],
            ],
            "turn-latest": [
              "turnStartedAtMs": completedTurnStartedAtMs,
              "durationMs": durationMs,
              "status": "completed",
              "items": [],
            ],
          ]
        ]
      ],
    ]
    let activity = try XCTUnwrap(
      ConversationActivity(conversationState: try JSONValue(any: object))
    )

    XCTAssertEqual(activity.state, .ready)
    XCTAssertTrue(activity.isUnread)
    XCTAssertEqual(activity.lastCompletedTurnDuration, durationMs / 1_000)
    XCTAssertEqual(
      activity.lastCompletedTurnAt,
      Date(
        timeIntervalSince1970:
          (completedTurnStartedAtMs + durationMs) / 1_000
      )
    )

    let readObject: [String: Any] = [
      "id": "thread-completed-read",
      "hasUnreadTurn": false,
      "unreadMessageCount": 0,
      "threadRuntimeStatus": ["type": "idle"],
    ]
    let readActivity = try XCTUnwrap(
      ConversationActivity(conversationState: try JSONValue(any: readObject))
    )
    XCTAssertFalse(readActivity.isUnread)
    XCTAssertEqual(readActivity.state, .idle)
  }

  func testUpdatesUnreadStateWithoutRebuildingConversationHistory() throws {
    let unreadObject: [String: Any] = [
      "id": "thread-unread-update",
      "hasUnreadTurn": true,
      "threadRuntimeStatus": ["type": "idle"],
    ]
    let unreadActivity = try XCTUnwrap(
      ConversationActivity(conversationState: try JSONValue(any: unreadObject))
    )
    let readActivity = unreadActivity.updatingUnreadState(false)
    XCTAssertFalse(readActivity.isUnread)
    XCTAssertEqual(readActivity.state, .idle)

    let workingObject: [String: Any] = [
      "id": "thread-working-unread-update",
      "hasUnreadTurn": true,
      "threadRuntimeStatus": ["type": "active"],
    ]
    let workingActivity = try XCTUnwrap(
      ConversationActivity(conversationState: try JSONValue(any: workingObject))
    )
    let readWorkingActivity = workingActivity.updatingUnreadState(false)
    XCTAssertFalse(readWorkingActivity.isUnread)
    XCTAssertEqual(readWorkingActivity.state, .working)
  }
}
