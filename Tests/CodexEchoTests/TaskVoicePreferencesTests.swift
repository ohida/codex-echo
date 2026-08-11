import Foundation
import XCTest

@testable import CodexEcho

final class TaskVoicePreferencesTests: XCTestCase {
  func testTaskVoiceOverridesProjectVoiceAndSupportsExplicitDefaultVoice() {
    XCTAssertEqual(
      TaskVoiceResolution.effectiveVoice(
        taskVoice: .flo,
        projectVoice: .reed,
        usesDefaultTaskVoice: false
      ),
      .flo
    )
    XCTAssertEqual(
      TaskVoiceResolution.effectiveVoice(
        taskVoice: nil,
        projectVoice: .reed,
        usesDefaultTaskVoice: false
      ),
      .reed
    )
    XCTAssertEqual(
      TaskVoiceResolution.effectiveVoice(
        taskVoice: nil,
        projectVoice: .reed,
        usesDefaultTaskVoice: true
      ),
      .defaultVoice
    )
    XCTAssertEqual(
      TaskVoiceResolution.effectiveVoice(
        taskVoice: nil,
        projectVoice: nil,
        usesDefaultTaskVoice: false,
        defaultVoice: .reed
      ),
      .reed
    )
    XCTAssertEqual(
      TaskVoiceResolution.effectiveVoice(
        taskVoice: nil,
        projectVoice: .flo,
        usesDefaultTaskVoice: true,
        defaultVoice: .reed
      ),
      .reed
    )
  }

  func testVoicePreferencesPersistTaskProjectAndDefaultSelections() throws {
    let suiteName = "CodexEchoTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    var preferences = TaskVoicePreferences.load(from: defaults)
    preferences.setTaskVoicePreference(.voice(.rocko), for: "task-1")
    preferences.setTaskVoicePreference(.defaultVoice, for: "task-2")
    preferences.setProjectVoice(.reed, for: "/tmp/project")
    preferences.save(to: defaults)

    var restored = TaskVoicePreferences.load(from: defaults)
    XCTAssertEqual(restored.taskVoicePreference(for: "task-1"), .voice(.rocko))
    XCTAssertEqual(restored.taskVoicePreference(for: "task-2"), .defaultVoice)
    XCTAssertEqual(restored.projectVoice(for: "/tmp/project"), .reed)

    restored.setTaskVoicePreference(.inheritProject, for: "task-1")
    restored.setProjectVoice(nil, for: "/tmp/project")
    restored.save(to: defaults)

    let cleared = TaskVoicePreferences.load(from: defaults)
    XCTAssertEqual(cleared.taskVoicePreference(for: "task-1"), .inheritProject)
    XCTAssertNil(cleared.projectVoice(for: "/tmp/project"))
  }

  func testNoProjectVoicePersistsSeparatelyFromProjectPathVoices() throws {
    let suiteName = "CodexEchoTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    var preferences = TaskVoicePreferences.load(from: defaults)
    preferences.setProjectVoice(.reed, for: "/tmp/generated-workspace")
    preferences.setNoProjectVoice(.flo)
    preferences.save(to: defaults)

    var restored = TaskVoicePreferences.load(from: defaults)
    XCTAssertEqual(restored.projectVoice(for: "/tmp/generated-workspace"), .reed)
    XCTAssertEqual(restored.noProjectVoice, .flo)
    XCTAssertEqual(restored.parentVoice(for: .noProject), .flo)
    XCTAssertEqual(restored.parentVoice(for: .project("/tmp/generated-workspace")), .reed)

    restored.setNoProjectVoice(nil)
    restored.save(to: defaults)
    XCTAssertNil(TaskVoicePreferences.load(from: defaults).noProjectVoice)
    XCTAssertEqual(
      TaskVoicePreferences.load(from: defaults).projectVoice(for: "/tmp/generated-workspace"),
      .reed
    )
  }

  func testMalformedVoiceEntriesDoNotDiscardKnownPreferences() throws {
    let suiteName = "CodexEchoTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let futureJSON = #"""
      {
        "taskVoicesByID": {
          "known-task": {
            "identifier": "com.apple.eloquence.en-US.Rocko",
            "displayName": "Rocko",
            "language": "en-US"
          },
          "broken-task": 42
        },
        "projectVoicesByID": {
          "/known/project": {
            "identifier": "com.apple.eloquence.en-US.Reed",
            "displayName": "Reed",
            "language": "en-US"
          },
          "/broken/project": false
        },
        "taskDefaultVoiceIDs": ["default-task"]
      }
      """#
    defaults.set(
      try XCTUnwrap(futureJSON.data(using: .utf8)),
      forKey: "taskVoicePreferencesV1"
    )

    let preferences = TaskVoicePreferences.load(from: defaults)
    XCTAssertEqual(preferences.taskVoicePreference(for: "known-task"), .voice(.rocko))
    XCTAssertEqual(preferences.taskVoicePreference(for: "broken-task"), .inheritProject)
    XCTAssertEqual(preferences.taskVoicePreference(for: "default-task"), .defaultVoice)
    XCTAssertEqual(preferences.projectVoice(for: "/known/project"), .reed)
    XCTAssertNil(preferences.projectVoice(for: "/broken/project"))
  }

  @MainActor
  func testVoiceCatalogKeepsUniqueUSVoicesInStableOrder() {
    XCTAssertEqual(SpokenUpdateVoice.defaultVoice, .zarvox)
    let reed = SpokenUpdateVoice(
      identifier: "voice-reed",
      displayName: "Reed",
      language: "en-US"
    )
    let rocko = SpokenUpdateVoice(
      identifier: "voice-rocko",
      displayName: "Rocko",
      language: "en-US"
    )
    let voices = SpokenUpdateVoiceCatalog.normalizedEnglishUSVoices([
      rocko,
      reed,
      SpokenUpdateVoice(
        identifier: reed.identifier,
        displayName: "Duplicate Reed",
        language: "en-US"
      ),
      SpokenUpdateVoice(
        identifier: "voice-french",
        displayName: "French Voice",
        language: "fr-FR"
      ),
    ])

    XCTAssertEqual(voices, [reed, rocko])
    XCTAssertEqual(
      Set(voices.map(\.identifier)).count,
      voices.count
    )
  }

  @MainActor
  func testVoiceMenuCopySeparatesTheDefaultActionFromItsCurrentVoice() {
    XCTAssertEqual(
      SpokenUpdateVoiceCatalog.useDefaultVoiceTitle,
      "Use Default Voice"
    )
    XCTAssertEqual(
      SpokenUpdateVoiceCatalog.menuTitle(for: .zarvox, defaultVoice: .zarvox),
      "Zarvox (Default)"
    )
    XCTAssertEqual(
      SpokenUpdateVoiceCatalog.menuTitle(for: .reed, defaultVoice: .zarvox),
      "Reed"
    )
  }

  @MainActor
  func testVoiceResolutionCanonicalizesAndFallsBackThroughProject() {
    let installedProjectVoice = SpokenUpdateVoice.reed
    let availableVoices = [SpokenUpdateVoice.defaultVoice, installedProjectVoice]
    let staleTaskVoice = SpokenUpdateVoice(
      identifier: "com.example.removed-voice",
      displayName: "Removed Voice",
      language: "en-US"
    )
    let staleMetadata = SpokenUpdateVoice(
      identifier: installedProjectVoice.identifier,
      displayName: "Old Display Name",
      language: "en-US"
    )

    let inheritedTask = TaskPresentation(
      id: "inherited",
      title: "Inherited voice",
      project: "codex-echo",
      projectID: "/tmp/codex-echo",
      state: .working,
      activeSubagentCount: 0,
      updatedAt: nil,
      taskVoice: staleTaskVoice,
      projectVoice: installedProjectVoice
    )
    XCTAssertEqual(
      SpokenUpdateVoiceCatalog.effectiveVoice(
        for: inheritedTask,
        availableVoices: availableVoices
      ),
      installedProjectVoice
    )
    XCTAssertEqual(
      SpokenUpdateVoiceCatalog.taskMenuPreference(
        for: inheritedTask,
        availableVoices: availableVoices
      ),
      .inheritProject
    )

    let defaultedTask = TaskPresentation(
      id: "defaulted",
      title: "Default voice",
      project: nil,
      state: .working,
      activeSubagentCount: 0,
      updatedAt: nil,
      taskVoice: staleTaskVoice,
      projectVoice: staleTaskVoice
    )
    XCTAssertEqual(
      SpokenUpdateVoiceCatalog.effectiveVoice(
        for: defaultedTask,
        availableVoices: availableVoices
      ),
      .defaultVoice
    )
    XCTAssertEqual(
      SpokenUpdateVoiceCatalog.effectiveVoice(
        for: defaultedTask,
        defaultVoice: installedProjectVoice,
        availableVoices: availableVoices
      ),
      installedProjectVoice
    )
    XCTAssertEqual(
      SpokenUpdateVoiceCatalog.taskMenuPreference(
        for: defaultedTask,
        availableVoices: availableVoices
      ),
      .defaultVoice
    )

    let canonicalizedTask = TaskPresentation(
      id: "canonicalized",
      title: "Canonicalized voice",
      project: "codex-echo",
      projectID: "/tmp/codex-echo",
      state: .working,
      activeSubagentCount: 0,
      updatedAt: nil,
      taskVoice: staleMetadata
    )
    XCTAssertEqual(
      SpokenUpdateVoiceCatalog.effectiveVoice(
        for: canonicalizedTask,
        availableVoices: availableVoices
      ),
      installedProjectVoice
    )
    XCTAssertEqual(
      SpokenUpdateVoiceCatalog.taskMenuPreference(
        for: canonicalizedTask,
        availableVoices: availableVoices
      ),
      .voice(installedProjectVoice)
    )

    let noProjectTask = TaskPresentation(
      id: "no-project",
      title: "Shared No Project voice",
      projectIdentity: .noProject,
      state: .working,
      activeSubagentCount: 0,
      updatedAt: nil,
      projectVoice: installedProjectVoice
    )
    XCTAssertEqual(
      SpokenUpdateVoiceCatalog.taskMenuPreference(
        for: noProjectTask,
        availableVoices: availableVoices
      ),
      .inheritProject
    )
    XCTAssertEqual(
      SpokenUpdateVoiceCatalog.effectiveVoice(
        for: noProjectTask,
        availableVoices: availableVoices
      ),
      installedProjectVoice
    )
  }

  @MainActor
  func testVoiceFixtureKeepsTasksWhenChangingTaskAndProjectVoices() throws {
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

    model.setProjectVoice(.reed, for: projectID)

    XCTAssertEqual(model.tasks.map(\.id), initialTaskIDs)
    XCTAssertTrue(
      model.tasks
        .filter { $0.projectID == projectID }
        .allSatisfy { $0.projectVoice == .reed && $0.effectiveVoice == .reed }
    )

    model.setTaskVoicePreference(.defaultVoice, for: task.id)

    let updatedTask = try XCTUnwrap(model.tasks.first { $0.id == task.id })
    XCTAssertTrue(updatedTask.usesDefaultTaskVoice)
    XCTAssertEqual(updatedTask.effectiveVoice, .defaultVoice)
  }
}
