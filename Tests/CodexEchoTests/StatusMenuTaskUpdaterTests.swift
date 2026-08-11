import AppKit
import XCTest

@testable import CodexEcho
@testable import CodexIPC

final class StatusMenuTaskUpdaterTests: XCTestCase {
  @MainActor
  func testRefreshUpdatesPresentationAndRecoversAnUnavailableTask() throws {
    let now = Date(timeIntervalSince1970: 10_000)
    let initialTask = task(
      title: "Initial title",
      state: .working,
      turnStartedAt: now.addingTimeInterval(-60)
    )
    let menu = NSMenu()
    let updater = StatusMenuTaskUpdater(shouldReduceMotion: { true })
    let item = NSMenuItem(title: initialTask.title, action: nil, keyEquivalent: "")
    TaskMenuTextPolicy.configureTaskTitle(initialTask.title, on: item)

    updater.prepareForMenuRebuild(
      menu,
      currentTasks: [initialTask],
      relativeTo: now
    )
    updater.track(item, presenting: initialTask)
    let initialImage = try XCTUnwrap(item.image)

    updater.refresh(currentTasks: [], relativeTo: now)

    XCTAssertFalse(item.isEnabled)
    if #available(macOS 14.4, *) {
      XCTAssertEqual(item.subtitle, "No Longer Available")
    }

    let updatedTask = task(
      title: "Updated title",
      state: .needsApproval,
      isUnread: true
    )
    updater.refresh(currentTasks: [updatedTask], relativeTo: now)

    XCTAssertTrue(item.isEnabled)
    XCTAssertEqual(item.title, "Updated title")
    XCTAssertEqual(item.accessibilityLabel(), "Updated title")
    XCTAssertFalse(initialImage === item.image)
    if #available(macOS 14.4, *) {
      XCTAssertEqual(item.subtitle, "No Project · Approval Required")
    }
  }

  @MainActor
  func testRefreshPreservesInitialSubtitlePolicyThenAddsLiveActivity() {
    let now = Date(timeIntervalSince1970: 10_000)
    let currentTask = task(
      state: .working,
      turnStartedAt: now.addingTimeInterval(-245)
    )
    let menu = NSMenu()
    let updater = StatusMenuTaskUpdater(shouldReduceMotion: { true })
    let item = NSMenuItem(title: currentTask.title, action: nil, keyEquivalent: "")

    updater.prepareForMenuRebuild(
      menu,
      currentTasks: [currentTask],
      relativeTo: now
    )
    updater.track(item, presenting: currentTask)

    if #available(macOS 14.4, *) {
      XCTAssertNil(item.subtitle)
    }

    updater.refresh(currentTasks: [currentTask], relativeTo: now)

    if #available(macOS 14.4, *) {
      XCTAssertEqual(item.subtitle, "No Project · Working · 4 min")
    }
  }

  @MainActor
  func testMenuOpenImmediatelyRefreshesEveryTrackedTaskSubtitle() {
    let now = Date()
    let currentTask = task(
      state: .working,
      turnStartedAt: now.addingTimeInterval(-245)
    )
    let menu = NSMenu()
    let updater = StatusMenuTaskUpdater(shouldReduceMotion: { true })
    let item = NSMenuItem(title: currentTask.title, action: nil, keyEquivalent: "")

    updater.prepareForMenuRebuild(menu, currentTasks: [currentTask])
    updater.track(item, presenting: currentTask)
    updater.menuWillOpen(menu)

    if #available(macOS 14.4, *) {
      XCTAssertEqual(item.subtitle, "No Project · Working · 4 min")
    }
    XCTAssertTrue(updater.isRefreshingTaskInformation)
    updater.menuDidClose(menu)
  }

  @MainActor
  func testReduceMotionStopsOnlyRingAnimationDuringAnOpenMenu() {
    var shouldReduceMotion = false
    let workingTask = task(state: .working)
    let menu = NSMenu()
    let updater = StatusMenuTaskUpdater(
      shouldReduceMotion: { shouldReduceMotion }
    )
    let item = NSMenuItem(title: workingTask.title, action: nil, keyEquivalent: "")

    updater.prepareForMenuRebuild(menu, currentTasks: [workingTask])
    updater.track(item, presenting: workingTask)
    updater.menuWillOpen(menu)

    XCTAssertTrue(updater.isRefreshingTaskInformation)
    XCTAssertTrue(updater.isAnimatingTaskRings)

    shouldReduceMotion = true
    updater.refresh(currentTasks: [workingTask])

    XCTAssertTrue(updater.isRefreshingTaskInformation)
    XCTAssertFalse(updater.isAnimatingTaskRings)

    shouldReduceMotion = false
    updater.refresh(currentTasks: [workingTask])
    XCTAssertTrue(updater.isAnimatingTaskRings)

    updater.refresh(currentTasks: [task(state: .idle)])
    XCTAssertTrue(updater.isRefreshingTaskInformation)
    XCTAssertFalse(updater.isAnimatingTaskRings)

    updater.menuDidClose(menu)
  }

  @MainActor
  func testMenuIdentityOwnsTimerAndBindingLifecycle() {
    let firstTask = task(title: "First")
    let firstMenu = NSMenu()
    let secondMenu = NSMenu()
    let updater = StatusMenuTaskUpdater(shouldReduceMotion: { true })
    let firstItem = NSMenuItem(title: firstTask.title, action: nil, keyEquivalent: "")

    updater.prepareForMenuRebuild(firstMenu, currentTasks: [firstTask])
    updater.track(firstItem, presenting: firstTask)
    updater.menuWillOpen(firstMenu)

    XCTAssertEqual(updater.trackedTaskCount, 1)
    XCTAssertTrue(updater.isRefreshingTaskInformation)

    XCTAssertFalse(updater.menuDidClose(secondMenu))

    XCTAssertEqual(updater.trackedTaskCount, 1)
    XCTAssertTrue(updater.isRefreshingTaskInformation)

    let secondTask = task(title: "Second")
    let secondItem = NSMenuItem(title: secondTask.title, action: nil, keyEquivalent: "")
    updater.prepareForMenuRebuild(secondMenu, currentTasks: [secondTask])
    updater.track(secondItem, presenting: secondTask)
    updater.menuWillOpen(secondMenu)
    XCTAssertFalse(updater.menuDidClose(firstMenu))

    XCTAssertEqual(updater.trackedTaskCount, 1)
    XCTAssertTrue(updater.isRefreshingTaskInformation)

    let refreshedSecondTask = task(title: "Second updated")
    updater.refresh(currentTasks: [refreshedSecondTask])

    XCTAssertEqual(firstItem.title, "First")
    XCTAssertEqual(secondItem.title, "Second updated")

    XCTAssertTrue(updater.menuDidClose(secondMenu))

    XCTAssertEqual(updater.trackedTaskCount, 0)
    XCTAssertFalse(updater.isRefreshingTaskInformation)
    XCTAssertFalse(updater.isAnimatingTaskRings)
  }

  @MainActor
  func testEventTrackingRunLoopAdvancesAnimationAndCloseStopsIt() {
    let workingTask = task(state: .working)
    let menu = NSMenu()
    let updater = StatusMenuTaskUpdater(shouldReduceMotion: { false })
    let item = NSMenuItem(title: workingTask.title, action: nil, keyEquivalent: "")

    updater.prepareForMenuRebuild(menu, currentTasks: [workingTask])
    updater.track(item, presenting: workingTask)
    updater.menuWillOpen(menu)

    let animationDeadline = Date().addingTimeInterval(0.2)
    while updater.animationFrameCount == 0, Date() < animationDeadline {
      RunLoop.main.run(
        mode: .eventTracking,
        before: Date().addingTimeInterval(0.02)
      )
    }

    XCTAssertGreaterThan(updater.animationFrameCount, 0)
    XCTAssertTrue(updater.menuDidClose(menu))
    let frameCountAfterClose = updater.animationFrameCount

    RunLoop.main.run(
      mode: .eventTracking,
      before: Date().addingTimeInterval(0.08)
    )

    XCTAssertEqual(updater.animationFrameCount, frameCountAfterClose)
    XCTAssertFalse(updater.isRefreshingTaskInformation)
    XCTAssertFalse(updater.isAnimatingTaskRings)
  }

  @MainActor
  func testUnavailableWorkingTaskStopsAnimationUntilItReturns() {
    let workingTask = task(state: .working)
    let menu = NSMenu()
    let updater = StatusMenuTaskUpdater(shouldReduceMotion: { false })
    let item = NSMenuItem(title: workingTask.title, action: nil, keyEquivalent: "")

    updater.prepareForMenuRebuild(menu, currentTasks: [workingTask])
    updater.track(item, presenting: workingTask)
    updater.menuWillOpen(menu)
    XCTAssertTrue(updater.isAnimatingTaskRings)

    updater.refresh(currentTasks: [])
    XCTAssertFalse(item.isEnabled)
    XCTAssertFalse(updater.isAnimatingTaskRings)
    let frameCountAfterRemoval = updater.animationFrameCount

    RunLoop.main.run(
      mode: .eventTracking,
      before: Date().addingTimeInterval(0.08)
    )
    XCTAssertEqual(updater.animationFrameCount, frameCountAfterRemoval)

    updater.refresh(currentTasks: [workingTask])
    XCTAssertTrue(item.isEnabled)
    XCTAssertTrue(updater.isAnimatingTaskRings)
    updater.menuDidClose(menu)
  }

  private func task(
    id: String = "task-1",
    title: String = "Task",
    state: CodexTaskActivityState = .idle,
    isUnread: Bool = false,
    turnStartedAt: Date? = nil
  ) -> TaskPresentation {
    TaskPresentation(
      id: id,
      title: title,
      projectIdentity: .noProject,
      state: state,
      isUnread: isUnread,
      activeSubagentCount: 0,
      updatedAt: nil,
      turnStartedAt: turnStartedAt
    )
  }
}
