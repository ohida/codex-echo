import AppKit
import XCTest

@testable import CodexEcho

@MainActor
final class CodexDesktopAppControllerTests: XCTestCase {
  func testStartReconcilesInstalledAndRunningState() {
    let workspace = TestCodexDesktopAppWorkspace()
    workspace.isInstalled = true
    workspace.isRunning = false
    let controller = CodexDesktopAppController(workspace: workspace)

    controller.start()

    XCTAssertEqual(controller.state, .notRunning)

    workspace.isRunning = true
    controller.reconcileState()
    XCTAssertEqual(controller.state, .running)

    workspace.isRunning = false
    controller.reconcileState()
    XCTAssertEqual(controller.state, .notRunning)
  }

  func testOpenWithoutAnInstalledAppNeverEntersLaunching() {
    let workspace = TestCodexDesktopAppWorkspace()
    workspace.isInstalled = false
    let controller = CodexDesktopAppController(workspace: workspace)
    controller.start()

    controller.openCodex()

    XCTAssertEqual(controller.state, .notInstalled)
    XCTAssertEqual(workspace.launchCount, 0)
  }

  func testLaunchFailureLeavesOpeningAndCanRetry() async {
    let workspace = TestCodexDesktopAppWorkspace()
    workspace.launchError = TestLaunchError.failed
    let controller = CodexDesktopAppController(workspace: workspace)
    controller.start()

    controller.openCodex()
    XCTAssertEqual(controller.state, .launching)
    await waitForLaunchToFinish(controller)

    XCTAssertEqual(controller.state, .launchFailed)
    XCTAssertEqual(workspace.launchCount, 1)

    controller.openCodex()
    XCTAssertEqual(controller.state, .launching)
    await waitForLaunchToFinish(controller)
    XCTAssertEqual(workspace.launchCount, 2)
  }

  func testCurrentRunningStateWinsOverAStaleLaunchFailure() async {
    let workspace = TestCodexDesktopAppWorkspace()
    workspace.launchError = TestLaunchError.failed
    let controller = CodexDesktopAppController(workspace: workspace)
    controller.start()

    controller.openCodex()
    XCTAssertEqual(controller.state, .launching)

    workspace.isRunning = true
    controller.reconcileState()
    XCTAssertEqual(controller.state, .running)

    await Task.yield()
    XCTAssertEqual(controller.state, .running)
  }

  func testSuccessfulLaunchRequeriesRunningApplications() async {
    let workspace = TestCodexDesktopAppWorkspace()
    workspace.marksRunningOnLaunch = true
    let controller = CodexDesktopAppController(workspace: workspace)
    controller.start()

    controller.openCodex()
    XCTAssertEqual(controller.state, .launching)
    await waitForLaunchToFinish(controller)

    XCTAssertEqual(controller.state, .running)
    XCTAssertEqual(workspace.launchCount, 1)
  }

  func testDesktopProcessBoundaryInvalidatesCachedTasksBeforeFastRestart() throws {
    let suiteName = "CodexEchoTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let desktopAppController = TestCodexDesktopAppController(state: .running)
    let model = CodexActivityModel(
      desktopAppController: desktopAppController,
      userDefaults: defaults,
      debugTaskFixtureName: "completion-unread"
    )
    XCTAssertFalse(model.tasks.isEmpty)

    desktopAppController.send(.notRunning)

    XCTAssertEqual(model.desktopAppState, .notRunning)
    XCTAssertTrue(model.tasks.isEmpty)
    XCTAssertTrue(model.statusBarTasks.isEmpty)

    desktopAppController.send(.running)

    XCTAssertEqual(model.desktopAppState, .running)
    XCTAssertTrue(model.tasks.isEmpty)
    XCTAssertTrue(model.statusBarTasks.isEmpty)
  }

  func testCompletedRetentionFixtureKeepsUnreadAndRespondsToTheSetting() async throws {
    let suiteName = "CodexEchoTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let settings = MenuBarSettings(userDefaults: defaults)
    let model = CodexActivityModel(
      desktopAppController: TestCodexDesktopAppController(state: .running),
      settings: settings,
      userDefaults: defaults,
      debugTaskFixtureName: "completion-retention"
    )

    XCTAssertEqual(
      Set(model.tasks.map(\.id)),
      Set(["debug-expired-unread", "debug-expired-read"])
    )
    XCTAssertEqual(model.crewTasks.map(\.id), ["debug-expired-unread"])

    settings.automaticallyHidesCompletedTasks = false
    await Task.yield()
    XCTAssertEqual(
      Set(model.crewTasks.map(\.id)),
      Set(["debug-expired-unread", "debug-expired-read"])
    )

    settings.automaticallyHidesCompletedTasks = true
    await Task.yield()
    XCTAssertEqual(model.crewTasks.map(\.id), ["debug-expired-unread"])
  }

  private func waitForLaunchToFinish(_ controller: CodexDesktopAppController) async {
    for _ in 0..<20 {
      if controller.state != .launching { return }
      await Task.yield()
    }
  }
}

@MainActor
private final class TestCodexDesktopAppController: CodexDesktopAppControlling {
  private(set) var state: CodexDesktopAppState
  var stateDidChange: ((CodexDesktopAppState) -> Void)?

  init(state: CodexDesktopAppState) {
    self.state = state
  }

  func start() {}
  func stop() {}
  func openCodex() {}

  func send(_ state: CodexDesktopAppState) {
    self.state = state
    stateDidChange?(state)
  }
}

private enum TestLaunchError: Error {
  case failed
}

@MainActor
private final class TestCodexDesktopAppWorkspace: CodexDesktopAppWorkspace {
  let notificationCenter = NotificationCenter()
  var isInstalled = true
  var isRunning = false
  var launchError: (any Error)?
  var marksRunningOnLaunch = false
  private(set) var launchCount = 0

  func applicationURL(withBundleIdentifier _: String) -> URL? {
    isInstalled ? URL(fileURLWithPath: "/Applications/ChatGPT.app") : nil
  }

  func isApplicationRunning(withBundleIdentifier _: String) -> Bool {
    isRunning
  }

  func launchApplication(at _: URL) async throws {
    launchCount += 1
    if let launchError { throw launchError }
    if marksRunningOnLaunch { isRunning = true }
  }
}
