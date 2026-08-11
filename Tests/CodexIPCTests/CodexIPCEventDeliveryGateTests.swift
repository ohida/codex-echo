import XCTest

@testable import CodexIPC

final class CodexIPCEventDeliveryGateTests: XCTestCase {
  @MainActor
  func testImmediateStopDropsEventsFromWorkThatStartedAheadOfStop() async {
    var deliveredStates: [CodexIPCConnectionState] = []
    var clients: [CodexIPCClient] = []

    for index in 0..<32 {
      let missingSocket = URL(fileURLWithPath: "/private/tmp/codex-echo-missing-\(index)-\(UUID().uuidString)")
      let client = CodexIPCClient(socketURL: missingSocket)
      client.eventHandler = { event in
        guard case .connectionStateChanged(let state) = event else { return }
        deliveredStates.append(state)
      }
      clients.append(client)
      client.start()
      client.stop()
    }

    for _ in 0..<8 { await Task.yield() }
    XCTAssertTrue(deliveredStates.isEmpty)
    withExtendedLifetime(clients) {}
  }

  @MainActor
  func testInvalidatedConnectionDropsPendingEventsAndFreshConnectionDelivers() async {
    let gate = CodexIPCEventDeliveryGate()
    let oldGeneration = gate.beginConnection()
    var deliveredConversationIDs: [String] = []

    gate.deliver(
      .snapshot(
        conversationID: "old-task",
        revision: 1,
        state: .object(["id": .string("old-task")])
      ),
      generation: oldGeneration
    ) { event in
      guard case .snapshot(let conversationID, _, _) = event else { return }
      deliveredConversationIDs.append(conversationID)
    }

    gate.invalidateCurrentConnection()
    await Task.yield()
    XCTAssertTrue(deliveredConversationIDs.isEmpty)

    let freshGeneration = gate.beginConnection()
    gate.deliver(
      .snapshot(
        conversationID: "fresh-task",
        revision: 1,
        state: .object(["id": .string("fresh-task")])
      ),
      generation: freshGeneration
    ) { event in
      guard case .snapshot(let conversationID, _, _) = event else { return }
      deliveredConversationIDs.append(conversationID)
    }

    await Task.yield()
    XCTAssertEqual(deliveredConversationIDs, ["fresh-task"])
  }
}
