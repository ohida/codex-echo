import AppKit
import Foundation
import XCTest

@testable import CodexEcho

@MainActor
final class ProjectCustomizationSettingsTests: XCTestCase {
  func testNoProjectSharedSettingsAlwaysHaveAnEditableManagerRow() throws {
    let suiteName = "CodexEchoTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = TaskCustomizationStore(userDefaults: defaults)

    XCTAssertEqual(
      store.projectCustomizations,
      [ProjectCustomization(identity: .noProject, color: nil, voice: nil)]
    )

    store.setParentColor(.teal, for: .noProject)
    store.setParentVoice(.flo, for: .noProject)

    XCTAssertEqual(
      store.projectCustomizations.first,
      ProjectCustomization(
        identity: .noProject,
        color: .teal,
        voice: .flo
      )
    )
  }

  func testManagerUsesAnIndependentMovableResizableWindow() throws {
    let suiteName = "CodexEchoTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let windowController = ProjectCustomizationWindowFactory.make(
      customizations: TaskCustomizationStore(userDefaults: defaults),
      savesFrame: false
    )
    let window = try XCTUnwrap(windowController.window)

    XCTAssertEqual(window.title, "Project Customizations")
    XCTAssertNil(window.sheetParent)
    XCTAssertTrue(window.isMovable)
    XCTAssertTrue(window.styleMask.contains(.titled))
    XCTAssertTrue(window.styleMask.contains(.closable))
    XCTAssertTrue(window.styleMask.contains(.miniaturizable))
    XCTAssertTrue(window.styleMask.contains(.resizable))
    XCTAssertEqual(
      window.contentMinSize,
      NSSize(
        width: ProjectCustomizationWindowMetrics.minimumWidth,
        height: ProjectCustomizationWindowMetrics.minimumHeight
      )
    )
    XCTAssertFalse(window.isReleasedWhenClosed)

    let originalOrigin = window.frame.origin
    window.setFrameOrigin(
      NSPoint(
        x: originalOrigin.x + 24,
        y: originalOrigin.y + 24
      )
    )
    XCTAssertEqual(window.frame.origin.x, originalOrigin.x + 24)
    XCTAssertEqual(window.frame.origin.y, originalOrigin.y + 24)

    window.close()
  }

  func testStoreCombinesProjectColorsAndVoicesByNormalizedProjectPath() throws {
    let suiteName = "CodexEchoTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    var colors = TaskColorPreferences()
    colors.setProjectColor(.orange, for: "/tmp/zeta")
    colors.setProjectColor(.teal, for: "/tmp/alpha")
    colors.save(to: defaults)

    var voices = TaskVoicePreferences()
    voices.setProjectVoice(.reed, for: "/tmp/zeta")
    voices.setProjectVoice(.flo, for: "/tmp/voice-only")
    voices.save(to: defaults)

    let store = TaskCustomizationStore(userDefaults: defaults)

    XCTAssertEqual(
      store.projectCustomizations,
      [
        ProjectCustomization(identity: .noProject, color: nil, voice: nil),
        ProjectCustomization(
          projectID: "/tmp/alpha",
          color: .teal,
          voice: nil
        ),
        ProjectCustomization(
          projectID: "/tmp/voice-only",
          color: nil,
          voice: .flo
        ),
        ProjectCustomization(
          projectID: "/tmp/zeta",
          color: .orange,
          voice: .reed
        ),
      ]
    )
  }

  func testMigrationMovesLegacyWorktreeCustomizationToCanonicalProject() throws {
    let suiteName = "CodexEchoTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let canonicalProjectID = "/Users/example/Codes/medianoche"
    let worktreeProjectID = "/Users/example/.codex/worktrees/ff9f/medianoche"

    var colors = TaskColorPreferences()
    colors.setProjectColor(.green, for: worktreeProjectID)
    colors.save(to: defaults)

    var voices = TaskVoicePreferences()
    voices.setProjectVoice(.flo, for: worktreeProjectID)
    voices.save(to: defaults)

    let store = TaskCustomizationStore(userDefaults: defaults)
    store.migrateProjectCustomizations([
      (legacyProjectID: worktreeProjectID, canonicalProjectID: canonicalProjectID)
    ])

    XCTAssertEqual(store.projectColor(for: canonicalProjectID), .green)
    XCTAssertEqual(store.projectVoice(for: canonicalProjectID), .flo)
    XCTAssertNil(store.projectColor(for: worktreeProjectID))
    XCTAssertNil(store.projectVoice(for: worktreeProjectID))
    XCTAssertEqual(
      store.projectCustomizations.map(\.identity),
      [.noProject, .project(canonicalProjectID)]
    )

    let reloadedStore = TaskCustomizationStore(userDefaults: defaults)
    XCTAssertEqual(reloadedStore.projectColor(for: canonicalProjectID), .green)
    XCTAssertEqual(reloadedStore.projectVoice(for: canonicalProjectID), .flo)
    XCTAssertNil(reloadedStore.projectColor(for: worktreeProjectID))
    XCTAssertNil(reloadedStore.projectVoice(for: worktreeProjectID))
  }

  func testCanonicalCustomizationWinsAndLegacyValueDoesNotReturnAfterClear() throws {
    let suiteName = "CodexEchoTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let canonicalProjectID = "/Users/example/Codes/medianoche"
    let worktreeProjectID = "/Users/example/.codex/worktrees/ff9f/medianoche"

    var colors = TaskColorPreferences()
    colors.setProjectColor(.orange, for: canonicalProjectID)
    colors.setProjectColor(.green, for: worktreeProjectID)
    colors.save(to: defaults)

    var voices = TaskVoicePreferences()
    voices.setProjectVoice(.reed, for: canonicalProjectID)
    voices.setProjectVoice(.flo, for: worktreeProjectID)
    voices.save(to: defaults)

    let store = TaskCustomizationStore(userDefaults: defaults)
    store.migrateProjectCustomizations([
      (legacyProjectID: worktreeProjectID, canonicalProjectID: canonicalProjectID)
    ])

    XCTAssertEqual(store.projectColor(for: canonicalProjectID), .orange)
    XCTAssertEqual(store.projectVoice(for: canonicalProjectID), .reed)
    XCTAssertNil(store.projectColor(for: worktreeProjectID))
    XCTAssertNil(store.projectVoice(for: worktreeProjectID))

    store.removeProjectCustomization(for: canonicalProjectID)

    var lateColors = TaskColorPreferences.load(from: defaults)
    lateColors.setProjectColor(.purple, for: worktreeProjectID)
    lateColors.save(to: defaults)
    var lateVoices = TaskVoicePreferences.load(from: defaults)
    lateVoices.setProjectVoice(.sandy, for: worktreeProjectID)
    lateVoices.save(to: defaults)

    let lateStore = TaskCustomizationStore(userDefaults: defaults)
    lateStore.migrateProjectCustomizations([
      (legacyProjectID: worktreeProjectID, canonicalProjectID: canonicalProjectID)
    ])

    let reloadedStore = TaskCustomizationStore(userDefaults: defaults)
    XCTAssertNil(reloadedStore.projectColor(for: canonicalProjectID))
    XCTAssertNil(reloadedStore.projectVoice(for: canonicalProjectID))
    XCTAssertNil(reloadedStore.projectColor(for: worktreeProjectID))
    XCTAssertNil(reloadedStore.projectVoice(for: worktreeProjectID))
    XCTAssertEqual(reloadedStore.projectCustomizations.map(\.identity), [.noProject])
  }

  func testLateAliasesChooseTheSameDeterministicPreferenceInEitherOrder() throws {
    let canonicalProjectID = "/Users/example/Codes/medianoche"
    let firstWorktreeProjectID = "/Users/example/.codex/worktrees/aaaa/medianoche"
    let lastWorktreeProjectID = "/Users/example/.codex/worktrees/zzzz/medianoche"

    for migrationOrder in [
      [lastWorktreeProjectID, firstWorktreeProjectID],
      [firstWorktreeProjectID, lastWorktreeProjectID],
    ] {
      let suiteName = "CodexEchoTests.\(UUID().uuidString)"
      let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
      defer { defaults.removePersistentDomain(forName: suiteName) }

      var colors = TaskColorPreferences()
      colors.setProjectColor(.orange, for: firstWorktreeProjectID)
      colors.setProjectColor(.green, for: lastWorktreeProjectID)
      colors.save(to: defaults)
      var voices = TaskVoicePreferences()
      voices.setProjectVoice(.reed, for: firstWorktreeProjectID)
      voices.setProjectVoice(.flo, for: lastWorktreeProjectID)
      voices.save(to: defaults)

      for legacyProjectID in migrationOrder {
        let store = TaskCustomizationStore(userDefaults: defaults)
        store.migrateProjectCustomizations([
          (legacyProjectID: legacyProjectID, canonicalProjectID: canonicalProjectID)
        ])
      }

      let reloadedStore = TaskCustomizationStore(userDefaults: defaults)
      XCTAssertEqual(reloadedStore.projectColor(for: canonicalProjectID), .orange)
      XCTAssertEqual(reloadedStore.projectVoice(for: canonicalProjectID), .reed)
      XCTAssertNil(reloadedStore.projectColor(for: firstWorktreeProjectID))
      XCTAssertNil(reloadedStore.projectColor(for: lastWorktreeProjectID))
      XCTAssertNil(reloadedStore.projectVoice(for: firstWorktreeProjectID))
      XCTAssertNil(reloadedStore.projectVoice(for: lastWorktreeProjectID))
    }
  }

  func testCanonicalProjectPathIsNeverConsumedAsAnotherProjectsAlias() throws {
    let suiteName = "CodexEchoTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let firstAlias = "/Users/example/.codex/worktrees/aaaa/medianoche"
    let firstCanonical = "/Users/example/Codes/medianoche"
    let unrelatedCanonical = "/Users/example/Codes/another-project"

    var colors = TaskColorPreferences()
    colors.setProjectColor(.green, for: firstAlias)
    colors.setProjectColor(.orange, for: firstCanonical)
    colors.save(to: defaults)
    var voices = TaskVoicePreferences()
    voices.setProjectVoice(.flo, for: firstAlias)
    voices.setProjectVoice(.reed, for: firstCanonical)
    voices.save(to: defaults)

    let store = TaskCustomizationStore(userDefaults: defaults)
    store.migrateProjectCustomizations([
      (legacyProjectID: firstAlias, canonicalProjectID: firstCanonical),
      (legacyProjectID: firstCanonical, canonicalProjectID: unrelatedCanonical),
    ])

    XCTAssertEqual(store.projectColor(for: firstCanonical), .orange)
    XCTAssertEqual(store.projectVoice(for: firstCanonical), .reed)
    XCTAssertNil(store.projectColor(for: firstAlias))
    XCTAssertNil(store.projectVoice(for: firstAlias))
    XCTAssertNil(store.projectColor(for: unrelatedCanonical))
    XCTAssertNil(store.projectVoice(for: unrelatedCanonical))
  }

  func testRemovingProjectCustomizationPreservesTaskAndOtherProjectPreferences() throws {
    let suiteName = "CodexEchoTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    var colors = TaskColorPreferences()
    colors.setTaskColor(.purple, for: "task-1")
    colors.setProjectColor(.orange, for: "/tmp/remove")
    colors.setProjectColor(.teal, for: "/tmp/keep")
    colors.save(to: defaults)

    var voices = TaskVoicePreferences()
    voices.setTaskVoicePreference(.voice(.flo), for: "task-1")
    voices.setProjectVoice(.reed, for: "/tmp/remove")
    voices.setProjectVoice(.sandy, for: "/tmp/keep")
    voices.save(to: defaults)

    let store = TaskCustomizationStore(userDefaults: defaults)
    store.removeProjectCustomization(for: "/tmp/remove")

    let restoredColors = TaskColorPreferences.load(from: defaults)
    let restoredVoices = TaskVoicePreferences.load(from: defaults)
    XCTAssertEqual(restoredColors.taskColor(for: "task-1"), .purple)
    XCTAssertNil(restoredColors.projectColor(for: "/tmp/remove"))
    XCTAssertEqual(restoredColors.projectColor(for: "/tmp/keep"), .teal)
    XCTAssertEqual(restoredVoices.taskVoice(for: "task-1"), .flo)
    XCTAssertNil(restoredVoices.projectVoice(for: "/tmp/remove"))
    XCTAssertEqual(restoredVoices.projectVoice(for: "/tmp/keep"), .sandy)
    XCTAssertEqual(
      store.projectCustomizations.map(\.identity),
      [.noProject, .project("/tmp/keep")]
    )
  }

  func testNoProjectCustomizationIsSharedAndMovementOnlySwitchesTheParentScope() throws {
    let suiteName = "CodexEchoTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let store = TaskCustomizationStore(userDefaults: defaults)
    store.setParentColor(.teal, for: .noProject)
    store.setParentVoice(.flo, for: .noProject)

    for taskID in ["no-project-1", "no-project-2"] {
      XCTAssertEqual(store.parentColor(for: .noProject), .teal, taskID)
      XCTAssertEqual(store.parentVoice(for: .noProject), .flo, taskID)
    }

    store.setTaskColorPreference(.accent(.purple), for: "no-project-1")
    store.setTaskVoicePreference(.voice(.reed), for: "no-project-1")
    store.setParentColor(.orange, for: .project("/tmp/destination"))
    store.setParentVoice(.sandy, for: .project("/tmp/destination"))

    XCTAssertEqual(store.taskColorPreference(for: "no-project-1"), .accent(.purple))
    XCTAssertEqual(store.taskVoicePreference(for: "no-project-1"), .voice(.reed))
    XCTAssertEqual(store.parentColor(for: .project("/tmp/destination")), .orange)
    XCTAssertEqual(store.parentVoice(for: .project("/tmp/destination")), .sandy)
    XCTAssertEqual(store.parentColor(for: .noProject), .teal)
    XCTAssertEqual(store.parentVoice(for: .noProject), .flo)
  }

  func testNoProjectCustomizationHasAPathlessManagerRowAndCanBeRemovedAlone() throws {
    let suiteName = "CodexEchoTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let store = TaskCustomizationStore(userDefaults: defaults)
    store.setParentColor(.mint, for: .noProject)
    store.setParentVoice(.reed, for: .project("/tmp/keep"))

    XCTAssertEqual(
      store.projectCustomizations,
      [
        ProjectCustomization(identity: .noProject, color: .mint, voice: nil),
        ProjectCustomization(projectID: "/tmp/keep", color: nil, voice: .reed),
      ]
    )
    XCTAssertNil(store.projectCustomizations.first?.projectID)
    XCTAssertEqual(store.projectCustomizations.first?.displayName, "No Project")

    store.removeProjectCustomization(for: .noProject)

    XCTAssertNil(store.parentColor(for: .noProject))
    XCTAssertEqual(store.parentVoice(for: .project("/tmp/keep")), .reed)
    XCTAssertEqual(
      store.projectCustomizations.map(\.identity),
      [.noProject, .project("/tmp/keep")]
    )
    XCTAssertNil(store.projectCustomizations.first?.color)
    XCTAssertNil(store.projectCustomizations.first?.voice)
  }

  func testManagerRemovalImmediatelyRefreshesActiveProjectPresentation() throws {
    let suiteName = "CodexEchoTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let store = TaskCustomizationStore(userDefaults: defaults)
    let model = CodexActivityModel(
      userDefaults: defaults,
      customizationStore: store,
      debugTaskFixtureName: "color-palette"
    )
    let projectID = "/tmp/codex-echo"

    model.setProjectColor(.green, for: projectID)
    model.setProjectVoice(.reed, for: projectID)
    store.removeProjectCustomization(for: projectID)

    let projectTasks = model.tasks.filter { $0.projectID == projectID }
    XCTAssertFalse(projectTasks.isEmpty)
    XCTAssertTrue(projectTasks.allSatisfy { $0.projectColor == nil })
    XCTAssertTrue(projectTasks.allSatisfy { $0.projectVoice == nil })
  }
}
