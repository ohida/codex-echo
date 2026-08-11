import AppKit
import Foundation
import XCTest

@testable import CodexEcho

final class TaskColorPreferencesTests: XCTestCase {
  func testTaskColorOverridesProjectColorAndSupportsExplicitNoColor() {
    XCTAssertEqual(
      TaskColorResolution.effectiveColor(
        taskColor: .purple,
        projectColor: .blue,
        usesSystemTaskColor: false
      ),
      .purple
    )
    XCTAssertEqual(
      TaskColorResolution.effectiveColor(
        taskColor: nil,
        projectColor: .blue,
        usesSystemTaskColor: false
      ),
      .blue
    )
    XCTAssertNil(
      TaskColorResolution.effectiveColor(
        taskColor: nil,
        projectColor: .blue,
        usesSystemTaskColor: true
      )
    )
    XCTAssertNil(
      TaskColorResolution.effectiveColor(
        taskColor: nil,
        projectColor: nil,
        usesSystemTaskColor: false
      )
    )
  }

  func testProjectIdentityUsesTheNormalizedFullPath() {
    XCTAssertEqual(
      ProjectColorIdentity.key(for: "/tmp/teams/../codex-echo/"),
      "/tmp/codex-echo"
    )
    XCTAssertNotEqual(
      ProjectColorIdentity.key(for: "/tmp/one/project"),
      ProjectColorIdentity.key(for: "/tmp/two/project")
    )
    XCTAssertNil(ProjectColorIdentity.key(for: nil))
    XCTAssertNil(ProjectColorIdentity.key(for: "   "))
  }

  func testTaskProjectIdentityPrefersAssignmentAndRepresentsNoProjectExplicitly() {
    XCTAssertEqual(
      TaskProjectIdentity.resolve(
        projectContext: .project(path: "/tmp/destination/../assigned"),
        fallbackCWD: "/tmp/generated-workspace"
      ),
      .project("/tmp/assigned")
    )
    XCTAssertEqual(
      TaskProjectIdentity.resolve(
        projectContext: .noProject,
        fallbackCWD: "/tmp/generated-workspace"
      ),
      .noProject
    )
    XCTAssertEqual(
      TaskProjectIdentity.resolve(
        projectContext: nil,
        fallbackCWD: "/tmp/fallback/../project"
      ),
      .project("/tmp/project")
    )
    XCTAssertNil(TaskProjectIdentity.resolve(projectContext: nil, fallbackCWD: nil))
    XCTAssertEqual(TaskProjectIdentity.noProject.displayName, "No Project")
  }

  func testNoProjectColorPersistsSeparatelyFromProjectPathColors() throws {
    let suiteName = "CodexEchoTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    var preferences = TaskColorPreferences.load(from: defaults)
    preferences.setProjectColor(.orange, for: "/tmp/generated-workspace")
    preferences.setNoProjectColor(.teal)
    preferences.save(to: defaults)

    var restored = TaskColorPreferences.load(from: defaults)
    XCTAssertEqual(restored.projectColor(for: "/tmp/generated-workspace"), .orange)
    XCTAssertEqual(restored.noProjectColor, .teal)
    XCTAssertEqual(restored.parentColor(for: .noProject), .teal)
    XCTAssertEqual(restored.parentColor(for: .project("/tmp/generated-workspace")), .orange)

    restored.setNoProjectColor(nil)
    restored.save(to: defaults)
    XCTAssertNil(TaskColorPreferences.load(from: defaults).noProjectColor)
    XCTAssertEqual(
      TaskColorPreferences.load(from: defaults).projectColor(for: "/tmp/generated-workspace"),
      .orange
    )
  }

  func testColorPreferencesPersistTaskAndProjectSelections() {
    let suiteName = "CodexEchoTests.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
      XCTFail("Unable to create isolated user defaults")
      return
    }
    defer { defaults.removePersistentDomain(forName: suiteName) }

    var preferences = TaskColorPreferences.load(from: defaults)
    preferences.setTaskColor(.orange, for: "task-1")
    preferences.setProjectColor(.teal, for: "/tmp/project")
    preferences.save(to: defaults)

    let restored = TaskColorPreferences.load(from: defaults)
    XCTAssertEqual(restored.taskColor(for: "task-1"), .orange)
    XCTAssertEqual(restored.projectColor(for: "/tmp/project"), .teal)

    var cleared = restored
    cleared.setTaskColor(nil, for: "task-1")
    cleared.setProjectColor(nil, for: "/tmp/project")
    cleared.save(to: defaults)

    let empty = TaskColorPreferences.load(from: defaults)
    XCTAssertNil(empty.taskColor(for: "task-1"))
    XCTAssertNil(empty.projectColor(for: "/tmp/project"))
  }

  func testTaskNoColorPreferencePersistsAndCanReturnToProjectInheritance() {
    let suiteName = "CodexEchoTests.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
      XCTFail("Unable to create isolated user defaults")
      return
    }
    defer { defaults.removePersistentDomain(forName: suiteName) }

    var preferences = TaskColorPreferences.load(from: defaults)
    preferences.setTaskColorPreference(.system, for: "task-1")
    preferences.save(to: defaults)

    var restored = TaskColorPreferences.load(from: defaults)
    XCTAssertEqual(restored.taskColorPreference(for: "task-1"), .system)

    restored.setTaskColorPreference(.inheritProject, for: "task-1")
    restored.save(to: defaults)

    let inherited = TaskColorPreferences.load(from: defaults)
    XCTAssertEqual(inherited.taskColorPreference(for: "task-1"), .inheritProject)
  }

  func testLegacyPreferencesWithoutSystemOverridesStillDecode() throws {
    let suiteName = "CodexEchoTests.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
      XCTFail("Unable to create isolated user defaults")
      return
    }
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let legacyJSON = #"{"taskColorsByID":{"task-1":"orange"},"projectColorsByID":{"/tmp/project":"teal"}}"#
    defaults.set(try XCTUnwrap(legacyJSON.data(using: .utf8)), forKey: "taskColorPreferencesV1")

    let preferences = TaskColorPreferences.load(from: defaults)
    XCTAssertEqual(preferences.taskColorPreference(for: "task-1"), .accent(.orange))
    XCTAssertEqual(preferences.projectColor(for: "/tmp/project"), .teal)
  }

  func testUnknownFutureColorsDoNotDiscardKnownPreferences() throws {
    let suiteName = "CodexEchoTests.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
      XCTFail("Unable to create isolated user defaults")
      return
    }
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let futureJSON = #"""
      {
        "taskColorsByID": {
          "known-task": "orange",
          "future-task": "ultraviolet"
        },
        "projectColorsByID": {
          "/known/project": "teal",
          "/future/project": "ultraviolet"
        },
        "taskSystemColorIDs": ["system-task"]
      }
      """#
    defaults.set(try XCTUnwrap(futureJSON.data(using: .utf8)), forKey: "taskColorPreferencesV1")

    let preferences = TaskColorPreferences.load(from: defaults)
    XCTAssertEqual(preferences.taskColorPreference(for: "known-task"), .accent(.orange))
    XCTAssertEqual(preferences.taskColorPreference(for: "future-task"), .inheritProject)
    XCTAssertEqual(preferences.taskColorPreference(for: "system-task"), .system)
    XCTAssertEqual(preferences.projectColor(for: "/known/project"), .teal)
    XCTAssertNil(preferences.projectColor(for: "/future/project"))
  }

  func testMalformedColorEntriesDoNotDiscardValidSiblings() throws {
    let suiteName = "CodexEchoTests.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
      XCTFail("Unable to create isolated user defaults")
      return
    }
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let malformedJSON = #"""
      {
        "taskColorsByID": {
          "known-task": "purple",
          "broken-task": 42
        },
        "projectColorsByID": {
          "/known/project": "green",
          "/broken/project": false
        },
        "taskSystemColorIDs": ["system-task", 42]
      }
      """#
    defaults.set(
      try XCTUnwrap(malformedJSON.data(using: .utf8)),
      forKey: "taskColorPreferencesV1"
    )

    let preferences = TaskColorPreferences.load(from: defaults)
    XCTAssertEqual(preferences.taskColorPreference(for: "known-task"), .accent(.purple))
    XCTAssertEqual(preferences.taskColorPreference(for: "broken-task"), .inheritProject)
    XCTAssertEqual(preferences.taskColorPreference(for: "system-task"), .system)
    XCTAssertEqual(preferences.projectColor(for: "/known/project"), .green)
    XCTAssertNil(preferences.projectColor(for: "/broken/project"))
  }

  @MainActor
  func testColorPaletteFixtureKeepsTasksWhenChangingTaskAndProjectColors() throws {
    let suiteName = "CodexEchoTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let model = CodexActivityModel(
      userDefaults: defaults,
      debugTaskFixtureName: "color-palette"
    )
    let initialTaskIDs = model.tasks.map(\.id)
    let task = try XCTUnwrap(model.tasks.first)
    let projectID = try XCTUnwrap(task.projectID)

    model.setTaskColorPreference(.system, for: task.id)

    XCTAssertEqual(model.tasks.map(\.id), initialTaskIDs)
    XCTAssertTrue(try XCTUnwrap(model.tasks.first { $0.id == task.id }).usesSystemTaskColor)
    XCTAssertNil(try XCTUnwrap(model.tasks.first { $0.id == task.id }).effectiveColor)

    model.setProjectColor(.green, for: projectID)

    XCTAssertEqual(model.tasks.map(\.id), initialTaskIDs)
    XCTAssertTrue(
      model.tasks
        .filter { $0.projectID == projectID }
        .allSatisfy { $0.projectColor == .green }
    )
  }

  func testPaletteUsesUniqueDisplayNames() {
    XCTAssertEqual(
      Set(TaskAccentColor.allCases.map(\.displayName)).count,
      TaskAccentColor.allCases.count
    )
  }

  @MainActor
  func testAttentionBadgeForegroundMeetsContrastAcrossAppearances() throws {
    let appearanceNames: [NSAppearance.Name] = [
      .aqua,
      .darkAqua,
      .accessibilityHighContrastAqua,
      .accessibilityHighContrastDarkAqua,
    ]

    for appearanceName in appearanceNames {
      let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
      for accent in TaskAccentColor.allCases {
        let background = TaskAccentBadgeContrast.resolvedColor(
          accent.nsColor,
          appearance: appearance
        )
        let foreground = TaskAccentBadgeContrast.foregroundColor(
          for: accent,
          appearance: appearance
        )
        XCTAssertGreaterThanOrEqual(
          TaskAccentBadgeContrast.contrastRatio(
            foreground: foreground,
            background: background
          ),
          4.5,
          "\(accent.displayName) under \(appearanceName.rawValue)"
        )
      }
    }
  }

  @MainActor
  func testMenuRingUsesColorForEffectiveTaskIdentity() {
    let coloredTask = TaskPresentation(
      id: "colored",
      title: "Colored",
      project: "project",
      projectID: "/tmp/project",
      state: .ready,
      activeSubagentCount: 0,
      updatedAt: nil,
      taskColor: nil,
      projectColor: .blue
    )
    let plainTask = TaskPresentation(
      id: "plain",
      title: "Plain",
      project: nil,
      state: .ready,
      activeSubagentCount: 0,
      updatedAt: nil
    )

    XCTAssertEqual(coloredTask.effectiveColor, .blue)
    XCTAssertFalse(MenuTaskRingImage.render(task: coloredTask, phase: 0).isTemplate)
    XCTAssertTrue(MenuTaskRingImage.render(task: plainTask, phase: 0).isTemplate)
  }

  @MainActor
  func testMenuRingScalesFilledAndStrokedCoresFromTheSameOuterDiameter() {
    XCTAssertEqual(
      MenuTaskRingImage.Geometry.ringPathDiameter
        + MenuTaskRingImage.Geometry.ringLineWidth,
      MenuTaskRingImage.Geometry.signalCoreDiameter,
      accuracy: 0.0001
    )
    XCTAssertEqual(
      MenuTaskRingImage.Geometry.signalCoreDiameter,
      WorkerCrewRingGeometry.signalCoreDiameter * MenuTaskRingImage.Geometry.scale,
      accuracy: 0.0001
    )
  }

  @MainActor
  func testMenuRingKeepsTheReducedMotionSignalHaloInsideTheImageBounds() {
    let renderedHaloDiameter =
      MenuTaskRingImage.Geometry.signalHaloDiameter
      + WorkerCrewRingGeometry.reducedMotionSignalHaloLineWidth
        * MenuTaskRingImage.Geometry.scale

    XCTAssertLessThanOrEqual(
      renderedHaloDiameter,
      MenuTaskRingImage.size.height,
      "The widest signal halo must not be clipped by the menu image"
    )
  }
}
