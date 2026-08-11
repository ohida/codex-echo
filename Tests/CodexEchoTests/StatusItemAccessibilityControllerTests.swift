import AppKit
import XCTest

@testable import CodexEcho

@MainActor
final class StatusItemAccessibilityControllerTests: XCTestCase {
  func testUpdateBuildsOrderedTreeAndDispatchesTypedActions() throws {
    let harness = makeHarness()
    let controller = StatusItemAccessibilityController()
    var actions: [StatusItemAccessibilityController.Action] = []

    controller.update(
      parent: harness.parent,
      coordinateView: harness.coordinateView,
      snapshot: populatedSnapshot()
    ) { action in
      actions.append(action)
      return true
    }

    let children = try accessibilityChildren(of: harness.parent)
    XCTAssertEqual(
      children.compactMap { $0.accessibilityIdentifier() },
      ["task:one", "task:two", "overflow", "connection-health"]
    )
    XCTAssertEqual(children[0].accessibilityLabel(), "First task")
    XCTAssertEqual(children[0].accessibilityValue() as? String, "Working")
    XCTAssertEqual(
      children[0].accessibilityCustomActions()?.map(\.name),
      ["Move Right", "Hide"]
    )
    XCTAssertEqual(
      children[1].accessibilityCustomActions()?.map(\.name),
      ["Move Left", "Hide"]
    )
    XCTAssertEqual(
      children[2].accessibilityLabel(),
      "3 more tasks, 1 needs attention, 2 completed unread, Codex capacity 89 percent remaining"
    )
    XCTAssertEqual(children[3].accessibilityLabel(), "Connection interrupted")

    XCTAssertTrue(children[0].accessibilityPerformPress())
    XCTAssertTrue(
      try XCTUnwrap(children[0].accessibilityCustomActions()?.first?.handler)()
    )
    XCTAssertTrue(children[2].accessibilityPerformPress())
    XCTAssertEqual(
      actions,
      [
        .openTask("one"),
        .moveTask("one", direction: .right),
        .showOverflowMenu,
      ]
    )

    let frames = children.map { $0.accessibilityFrame() }
    XCTAssertEqual(frames[0].width, WorkerCrewLayout.cellWidth, accuracy: 0.001)
    XCTAssertEqual(
      frames[1].minX - frames[0].maxX,
      WorkerCrewLayout.taskSpacing,
      accuracy: 0.001
    )
    XCTAssertEqual(
      frames[2].minX - frames[1].maxX,
      WorkerCrewLayout.summarySpacing,
      accuracy: 0.001
    )
    XCTAssertEqual(
      frames[2].width,
      WorkerCrewLayout.summaryWidth(
        overflowCount: 3,
        capacityRemainingPercent: 89
      ),
      accuracy: 0.001
    )
    XCTAssertEqual(
      frames[3].minX - frames[2].maxX,
      WorkerCrewLayout.spacing,
      accuracy: 0.001
    )
    XCTAssertEqual(frames[3].width, WorkerCrewLayout.healthWidth, accuracy: 0.001)
  }

  func testUpdateReusesActiveElementsAndPrunesRemovedElements() throws {
    let harness = makeHarness()
    let controller = StatusItemAccessibilityController()
    let handler: (StatusItemAccessibilityController.Action) -> Bool = { _ in true }

    controller.update(
      parent: harness.parent,
      coordinateView: harness.coordinateView,
      snapshot: populatedSnapshot(),
      onAction: handler
    )
    let initialChildren = try accessibilityChildren(of: harness.parent)
    let firstTaskElement = initialChildren[0]
    let removedTaskElement = initialChildren[1]

    let reducedSnapshot = StatusItemAccessibilityController.Snapshot(
      tasks: [
        .init(
          id: "one",
          title: "Renamed task",
          value: "Approval Required",
          canMoveLeft: false,
          canMoveRight: false
        )
      ],
      overflowCount: 0,
      overflowAttentionCount: 0,
      overflowUnreadCompletionCount: 0,
      capacityRemainingPercent: 89,
      showsHealth: false,
      statusLabel: "Codex Tasks"
    )
    controller.update(
      parent: harness.parent,
      coordinateView: harness.coordinateView,
      snapshot: reducedSnapshot,
      onAction: handler
    )

    let reducedChildren = try accessibilityChildren(of: harness.parent)
    XCTAssertEqual(
      reducedChildren.compactMap { $0.accessibilityIdentifier() },
      ["task:one", "codex-capacity"]
    )
    XCTAssertTrue(reducedChildren[0] === firstTaskElement)
    XCTAssertEqual(reducedChildren[0].accessibilityLabel(), "Renamed task")
    XCTAssertEqual(reducedChildren[0].accessibilityValue() as? String, "Approval Required")

    controller.update(
      parent: harness.parent,
      coordinateView: harness.coordinateView,
      snapshot: populatedSnapshot(),
      onAction: handler
    )
    let restoredChildren = try accessibilityChildren(of: harness.parent)
    XCTAssertFalse(restoredChildren[1] === removedTaskElement)
  }

  func testFallbackPressAndCapacityTopologyRemainExplicit() throws {
    let harness = makeHarness()
    let controller = StatusItemAccessibilityController()
    var actions: [StatusItemAccessibilityController.Action] = []
    let snapshot = StatusItemAccessibilityController.Snapshot(
      tasks: [],
      overflowCount: 0,
      overflowAttentionCount: 0,
      overflowUnreadCompletionCount: 0,
      capacityRemainingPercent: 42,
      showsHealth: false,
      statusLabel: "Codex is offline"
    )

    controller.update(
      parent: harness.parent,
      coordinateView: harness.coordinateView,
      snapshot: snapshot
    ) { action in
      actions.append(action)
      return true
    }

    let children = try accessibilityChildren(of: harness.parent)
    XCTAssertEqual(
      children.compactMap { $0.accessibilityIdentifier() },
      ["fallback", "codex-capacity"]
    )
    XCTAssertEqual(children[0].accessibilityLabel(), "Codex is offline")
    XCTAssertEqual(children[0].accessibilityHelp(), "Shows the Codex task menu")
    XCTAssertEqual(children[1].accessibilityLabel(), "Codex capacity")
    XCTAssertEqual(children[1].accessibilityValue() as? String, "42 percent remaining")
    XCTAssertTrue(children[0].accessibilityPerformPress())
    XCTAssertEqual(actions, [.showContextMenu])
  }

  private func populatedSnapshot() -> StatusItemAccessibilityController.Snapshot {
    StatusItemAccessibilityController.Snapshot(
      tasks: [
        .init(
          id: "one",
          title: "First task",
          value: "Working",
          canMoveLeft: false,
          canMoveRight: true
        ),
        .init(
          id: "two",
          title: "Second task",
          value: "Needs Input",
          canMoveLeft: true,
          canMoveRight: false
        ),
      ],
      overflowCount: 3,
      overflowAttentionCount: 1,
      overflowUnreadCompletionCount: 2,
      capacityRemainingPercent: 89,
      showsHealth: true,
      statusLabel: "Connection interrupted"
    )
  }

  private func makeHarness() -> (
    window: NSWindow,
    parent: NSButton,
    coordinateView: NSView
  ) {
    let window = NSWindow(
      contentRect: NSRect(x: 120, y: 160, width: 400, height: 80),
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
    let parent = NSButton(frame: NSRect(x: 20, y: 20, width: 300, height: 22))
    let coordinateView = NSView(frame: parent.bounds)
    window.contentView?.addSubview(parent)
    parent.addSubview(coordinateView)
    parent.layoutSubtreeIfNeeded()
    return (window, parent, coordinateView)
  }

  private func accessibilityChildren(
    of parent: NSView
  ) throws -> [StatusItemAccessibilityElement] {
    try XCTUnwrap(parent.accessibilityChildren() as? [StatusItemAccessibilityElement])
  }
}
