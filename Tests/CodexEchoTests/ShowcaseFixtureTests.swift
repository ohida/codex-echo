import XCTest

@testable import CodexEcho

@MainActor
final class ShowcaseFixtureTests: XCTestCase {
  func testProductHuntFixtureTellsTheCoreMenuBarStory() throws {
    let suiteName = "CodexEchoTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let settings = MenuBarSettings(userDefaults: defaults)
    let model = CodexActivityModel(
      settings: settings,
      userDefaults: defaults,
      debugTaskFixtureName: "product-hunt"
    )

    let visibleTasks = model.statusBarTasks
    let overflowTasks = model.overflowCrewTasks

    XCTAssertEqual(model.tasks.count, 6)
    XCTAssertEqual(visibleTasks.count, 4)
    XCTAssertEqual(overflowTasks.count, 2)
    XCTAssertEqual(
      model.tasks.map(\.title),
      [
        "Craft the launch experience",
        "Polish the onboarding flow",
        "Choose the hero message",
        "Prepare the release candidate",
        "Approve production deployment",
        "Unblock the signing pipeline",
      ]
    )
    XCTAssertEqual(
      visibleTasks.map(\.state),
      [.working, .working, .needsInput, .ready]
    )
    XCTAssertEqual(
      visibleTasks.map(\.effectiveColor),
      [nil, nil, .orange, .teal]
    )
    XCTAssertEqual(
      visibleTasks.map(\.taskColorPreference),
      [.system, .system, .inheritProject, .inheritProject]
    )
    XCTAssertEqual(
      visibleTasks.map(\.projectColor),
      [.teal, .orange, .orange, .teal]
    )
    XCTAssertEqual(
      visibleTasks.compactMap(\.currentActivity),
      [.thinking, .editingFiles]
    )
    XCTAssertTrue(try XCTUnwrap(visibleTasks.last).showsUnreadCompletionSignal)
    XCTAssertEqual(
      overflowTasks.map(\.state),
      [.needsApproval, .blocked]
    )
    XCTAssertEqual(
      overflowTasks.map(\.effectiveColor),
      [nil, .red]
    )
    XCTAssertEqual(
      overflowTasks.map(\.taskColorPreference),
      [.system, .accent(.red)]
    )
    XCTAssertTrue(model.tasks.allSatisfy { $0.projectIdentity != nil })
  }
}
