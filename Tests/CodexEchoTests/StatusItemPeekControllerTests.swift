import AppKit
import XCTest

@testable import CodexEcho

final class StatusItemPeekControllerTests: XCTestCase {
  func testPlacementCentersBelowAnchorWithoutScreenConstraints() {
    let anchor = NSRect(x: 100, y: 200, width: 20, height: 22)
    let size = NSSize(width: 80, height: 40)

    let origin = StatusItemPeekPlacement.origin(
      anchoredTo: anchor,
      peekSize: size,
      visibleScreenFrame: nil
    )

    XCTAssertEqual(origin.x, 70)
    XCTAssertEqual(origin.y, 200 - 40 - CrewPeekMetrics.gap)
  }

  func testPlacementClampsHorizontallyAndFlipsAboveTheAnchorNearTheScreenBottom() {
    let screen = NSRect(x: 0, y: 0, width: 300, height: 200)
    let anchor = NSRect(x: 0, y: 2, width: 20, height: 22)
    let size = NSSize(width: 80, height: 40)

    let origin = StatusItemPeekPlacement.origin(
      anchoredTo: anchor,
      peekSize: size,
      visibleScreenFrame: screen
    )

    XCTAssertEqual(origin.x, CrewPeekMetrics.screenInset)
    XCTAssertEqual(origin.y, anchor.maxY + CrewPeekMetrics.gap)
  }

  @MainActor
  func testChangingTargetCancelsThePendingPeekAndRevealsOnlyTheLatestTarget() {
    let anchorView = makeAnchorView()
    var hoveredTaskIDs: [String?] = []
    var revealedTargets: [StatusItemPeekTarget] = []
    let controller = StatusItemPeekController(
      anchorView: anchorView,
      hoverDelay: 0.02,
      onHoveredTaskIDChange: { hoveredTaskIDs.append($0) }
    )
    controller.updateHover(to: .task("first")) { target in
      revealedTargets.append(target)
      return self.content()
    }
    controller.updateHover(to: .task("second")) { target in
      revealedTargets.append(target)
      return self.content()
    }

    runMainLoopUntil { revealedTargets.count == 1 }

    XCTAssertEqual(revealedTargets, [.task("second")])
    XCTAssertEqual(hoveredTaskIDs, ["first", "second"])
    XCTAssertEqual(controller.activeTarget, .task("second"))
    XCTAssertFalse(controller.isVisible)
    controller.clear()
  }

  @MainActor
  func testClearingHoverCancelsPendingPresentationAndResetsTaskHover() {
    let anchorView = makeAnchorView()
    var hoveredTaskIDs: [String?] = []
    var contentRequestCount = 0
    let controller = StatusItemPeekController(
      anchorView: anchorView,
      hoverDelay: 0.02,
      onHoveredTaskIDChange: { hoveredTaskIDs.append($0) }
    )

    controller.updateHover(to: .task("task")) { _ in
      contentRequestCount += 1
      return self.content()
    }
    controller.clear()
    runMainLoop(for: 0.05)

    XCTAssertEqual(contentRequestCount, 0)
    XCTAssertEqual(hoveredTaskIDs, ["task", nil])
    XCTAssertNil(controller.activeTarget)
    XCTAssertFalse(controller.isVisible)
  }

  @MainActor
  func testRefreshClearsAPeekWhoseSemanticTargetDisappeared() {
    let anchorView = makeAnchorView()
    var hoveredTaskIDs: [String?] = []
    var contentRequestCount = 0
    let controller = StatusItemPeekController(
      anchorView: anchorView,
      hoverDelay: 0,
      onHoveredTaskIDChange: { hoveredTaskIDs.append($0) }
    )

    controller.updateHover(to: .task("removed")) { _ in
      contentRequestCount += 1
      return self.content()
    }
    runMainLoopUntil { contentRequestCount == 1 }
    controller.refreshVisiblePeek(
      isAvailable: { _ in false },
      makeContent: { _ in self.content() }
    )

    XCTAssertEqual(hoveredTaskIDs, ["removed", nil])
    XCTAssertNil(controller.activeTarget)
    XCTAssertFalse(controller.isVisible)
  }

  @MainActor
  private func makeAnchorView() -> NSView {
    NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 22))
  }

  @MainActor
  private func content() -> StatusItemPeekContent {
    let viewController = NSViewController()
    viewController.view = NSView(frame: NSRect(origin: .zero, size: CrewPeekMetrics.size))
    return StatusItemPeekContent(
      viewController: viewController,
      anchorRect: NSRect(x: 20, y: 0, width: 20, height: 22)
    )
  }

  @MainActor
  private func runMainLoopUntil(
    timeout: TimeInterval = 0.25,
    _ condition: () -> Bool
  ) {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
      RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
    XCTAssertTrue(condition(), "Timed out waiting for the peek lifecycle")
  }

  @MainActor
  private func runMainLoop(for duration: TimeInterval) {
    let deadline = Date().addingTimeInterval(duration)
    while Date() < deadline {
      RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
  }
}
