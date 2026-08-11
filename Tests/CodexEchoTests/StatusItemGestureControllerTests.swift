import AppKit
import XCTest

@testable import CodexEcho

final class StatusItemGestureControllerTests: XCTestCase {
  @MainActor
  func testControllerRoutesTaskOverflowAndBackgroundThroughTypedActions() {
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 22))
    let harness = GestureControllerTestHarness(
      snapshot: StatusItemGestureController.Snapshot(
        taskIDs: ["task"],
        overflowCount: 0,
        capacityRemainingPercent: nil,
        taskOpenMouseButton: .left
      )
    )
    let controller = harness.makeController(coordinateView: view)

    controller.handleClick(at: NSPoint(x: 1, y: 10), isSecondaryClick: false)
    XCTAssertEqual(
      harness.actions,
      [.updateDrag(nil), .clearHover, .openTask(taskID: "task")]
    )

    harness.actions.removeAll()
    controller.handleClick(at: NSPoint(x: 1, y: 10), isSecondaryClick: true)
    XCTAssertEqual(
      harness.actions,
      [.updateDrag(nil), .presentContextMenu(taskID: "task")]
    )

    harness.actions.removeAll()
    harness.snapshot = StatusItemGestureController.Snapshot(
      taskIDs: ["task"],
      overflowCount: 2,
      capacityRemainingPercent: nil,
      taskOpenMouseButton: .left
    )
    let overflowX = WorkerCrewLayout.taskGroupWidth(for: 1)
      + WorkerCrewLayout.summarySpacing + 1
    controller.handleClick(at: NSPoint(x: overflowX, y: 10), isSecondaryClick: false)
    XCTAssertEqual(harness.actions, [.updateDrag(nil), .presentOverflowMenu])

    harness.actions.removeAll()
    harness.snapshot = StatusItemGestureController.Snapshot(
      taskIDs: ["task"],
      overflowCount: 0,
      capacityRemainingPercent: nil,
      taskOpenMouseButton: .left
    )
    controller.handleClick(at: NSPoint(x: 200, y: 10), isSecondaryClick: false)
    XCTAssertEqual(
      harness.actions,
      [.updateDrag(nil), .presentContextMenu(taskID: nil)]
    )
  }

  @MainActor
  func testControllerEmitsActivationThenLiveDragUpdatesAndOneCommit() {
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 22))
    let harness = GestureControllerTestHarness(
      snapshot: StatusItemGestureController.Snapshot(
        taskIDs: ["one", "two", "three"],
        overflowCount: 0,
        capacityRemainingPercent: nil,
        taskOpenMouseButton: .left
      )
    )
    let controller = harness.makeController(coordinateView: view)

    controller.beginDrag(at: NSPoint(x: 1, y: 10))
    harness.actions.removeAll()
    controller.updateDrag(
      translation: CGSize(width: 4, height: 0),
      inputPhase: .dragged
    )
    let firstPresentation = CrewRingDragPresentation(
      taskID: "one",
      sourceIndex: 0,
      destinationIndex: 0,
      translationX: 4
    )
    XCTAssertEqual(harness.actions, [.clearHover, .updateDrag(firstPresentation)])

    harness.actions.removeAll()
    let stride = WorkerCrewLayout.taskStride
    controller.updateDrag(
      translation: CGSize(width: stride * 1.6, height: 0),
      inputPhase: .dragged
    )
    let finalPresentation = CrewRingDragPresentation(
      taskID: "one",
      sourceIndex: 0,
      destinationIndex: 2,
      translationX: stride * 1.6
    )
    XCTAssertEqual(harness.actions, [.updateDrag(finalPresentation)])

    harness.actions.removeAll()
    XCTAssertTrue(controller.finishDrag())
    XCTAssertEqual(harness.actions, [.commitDrag(finalPresentation)])
    harness.actions.removeAll()
    XCTAssertFalse(controller.finishDrag())
    XCTAssertEqual(harness.actions, [])

    controller.beginDrag(at: NSPoint(x: 1, y: 10))
    harness.actions.removeAll()
    controller.updateDrag(
      translation: CGSize(width: 4, height: 0),
      inputPhase: .dragged
    )
    harness.actions.removeAll()
    harness.snapshot = StatusItemGestureController.Snapshot(
      taskIDs: ["two", "three"],
      overflowCount: 0,
      capacityRemainingPercent: nil,
      taskOpenMouseButton: .left
    )
    controller.updateDrag(
      translation: CGSize(width: 8, height: 0),
      inputPhase: .dragged
    )
    XCTAssertEqual(harness.actions, [.updateDrag(nil)])
    harness.actions.removeAll()
    XCTAssertFalse(controller.finishDrag())
    XCTAssertEqual(harness.actions, [])
  }

  @MainActor
  func testInstalledRecognizersUseTheOwnerAndDoNotRetainIt() throws {
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 22))
    let button = NSStatusBarButton(frame: view.frame)
    var controller: StatusItemGestureController? = StatusItemGestureController(
      coordinateView: view,
      snapshot: {
        StatusItemGestureController.Snapshot(
          taskIDs: [],
          overflowCount: 0,
          capacityRemainingPercent: nil,
          taskOpenMouseButton: .left
        )
      },
      onAction: { _ in }
    )
    controller?.install(on: button)

    let click = try XCTUnwrap(
      button.gestureRecognizers.compactMap { $0 as? NSClickGestureRecognizer }.first
    )
    let pan = try XCTUnwrap(
      button.gestureRecognizers.compactMap { $0 as? NSPanGestureRecognizer }.first
    )
    XCTAssertTrue(click.delegate === controller)
    XCTAssertTrue(pan.delegate === controller)
    XCTAssertTrue(
      try XCTUnwrap(controller).gestureRecognizer(
        click,
        shouldRequireFailureOf: pan
      )
    )
    XCTAssertFalse(
      try XCTUnwrap(controller).gestureRecognizer(
        pan,
        shouldRequireFailureOf: click
      )
    )

    let commandClick = try XCTUnwrap(
      NSEvent.mouseEvent(
        with: .leftMouseDown,
        location: .zero,
        modifierFlags: .command,
        timestamp: 1,
        windowNumber: 0,
        context: nil,
        eventNumber: 1,
        clickCount: 1,
        pressure: 0
      )
    )
    XCTAssertFalse(
      try XCTUnwrap(controller).gestureRecognizer(
        click,
        shouldAttemptToRecognizeWith: commandClick
      )
    )
    XCTAssertFalse(
      try XCTUnwrap(controller).gestureRecognizer(
        pan,
        shouldAttemptToRecognizeWith: commandClick
      )
    )

    let weakController = { [weak controller] in controller }
    controller = nil
    XCTAssertNil(weakController())
    XCTAssertNil(click.delegate)
    XCTAssertNil(pan.delegate)
  }

  func testPendingDragDoesNotActivateOnReleaseAndFinishesWithoutACommit() {
    var state = StatusItemGestureState()
    state.beginDrag(taskID: "two")

    XCTAssertEqual(
      state.updateDrag(
        translation: CGSize(width: 3, height: 20),
        inputPhase: .dragged,
        visibleTaskIDs: ["one", "two", "three"]
      ),
      .unchanged
    )
    XCTAssertNil(state.ringDrag)
    XCTAssertEqual(
      state.updateDrag(
        translation: CGSize(width: 30, height: 0),
        inputPhase: .released,
        visibleTaskIDs: ["one", "two", "three"]
      ),
      .unchanged
    )

    XCTAssertNil(state.finishDrag())
    XCTAssertNil(state.ringDrag)
  }

  func testActiveDragPublishesOneActivationAndCommitsTheLatestDestination() throws {
    var state = StatusItemGestureState()
    state.beginDrag(taskID: "two")
    let stride = WorkerCrewLayout.taskStride

    let activatedPresentation = CrewRingDragPresentation(
      taskID: "two",
      sourceIndex: 1,
      destinationIndex: 2,
      translationX: stride * 0.6
    )
    XCTAssertEqual(
      state.updateDrag(
        translation: CGSize(width: stride * 0.6, height: 0),
        inputPhase: .dragged,
        visibleTaskIDs: ["one", "two", "three", "four"]
      ),
      .activated(activatedPresentation)
    )
    XCTAssertEqual(state.ringDrag, activatedPresentation)

    XCTAssertEqual(
      state.updateDrag(
        translation: CGSize(width: stride * 1.7, height: 0),
        inputPhase: .dragged,
        visibleTaskIDs: ["one", "two", "three", "four"]
      ),
      .changed(
        CrewRingDragPresentation(
          taskID: "two",
          sourceIndex: 1,
          destinationIndex: 3,
          translationX: stride * 1.7
        )
      )
    )
    let committedDrag = try XCTUnwrap(state.finishDrag())
    XCTAssertEqual(committedDrag.destinationIndex, 3)
    XCTAssertEqual(committedDrag.translationX, stride * 1.7)
    XCTAssertNil(state.ringDrag)
    XCTAssertNil(state.finishDrag())
  }

  func testTaskDisappearanceAndCancellationClearEveryTransientDragValue() {
    var state = StatusItemGestureState()
    state.beginDrag(taskID: "two")
    XCTAssertEqual(
      state.updateDrag(
        translation: CGSize(width: 4, height: 0),
        inputPhase: .dragged,
        visibleTaskIDs: ["one", "two"]
      ),
      .activated(
        CrewRingDragPresentation(
          taskID: "two",
          sourceIndex: 1,
          destinationIndex: 1,
          translationX: 4
        )
      )
    )
    XCTAssertNotNil(state.ringDrag)

    XCTAssertEqual(
      state.updateDrag(
        translation: CGSize(width: 8, height: 0),
        inputPhase: .dragged,
        visibleTaskIDs: ["one"]
      ),
      .cancelled
    )
    XCTAssertNil(state.ringDrag)
    XCTAssertNil(state.finishDrag())

    state.beginDrag(taskID: "one")
    _ = state.updateDrag(
      translation: CGSize(width: 4, height: 0),
      inputPhase: .dragged,
      visibleTaskIDs: ["one", "two"]
    )
    state.cancelDrag()
    XCTAssertNil(state.ringDrag)
    XCTAssertNil(state.finishDrag())
  }

  func testSecondaryActionIdentityIsConsumedOnlyOnceByARightMouseUp() {
    var state = StatusItemGestureState()
    let first = StatusItemActionEventIdentity(eventNumber: 42, timestamp: 1.25)
    let second = StatusItemActionEventIdentity(eventNumber: 43, timestamp: 1.5)

    XCTAssertFalse(state.shouldHandleSecondaryAction(eventType: .leftMouseUp, identity: first))
    XCTAssertTrue(state.shouldHandleSecondaryAction(eventType: .rightMouseUp, identity: first))
    XCTAssertFalse(state.shouldHandleSecondaryAction(eventType: .rightMouseUp, identity: first))
    XCTAssertTrue(state.shouldHandleSecondaryAction(eventType: .rightMouseUp, identity: second))
  }
}

@MainActor
private final class GestureControllerTestHarness {
  var snapshot: StatusItemGestureController.Snapshot
  var actions: [StatusItemGestureController.Action] = []

  init(snapshot: StatusItemGestureController.Snapshot) {
    self.snapshot = snapshot
  }

  func makeController(coordinateView: NSView) -> StatusItemGestureController {
    StatusItemGestureController(
      coordinateView: coordinateView,
      snapshot: { [weak self] in
        self?.snapshot
          ?? StatusItemGestureController.Snapshot(
            taskIDs: [],
            overflowCount: 0,
            capacityRemainingPercent: nil,
            taskOpenMouseButton: .left
          )
      },
      onAction: { [weak self] in self?.actions.append($0) }
    )
  }
}
