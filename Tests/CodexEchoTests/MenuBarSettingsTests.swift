import Combine
import Foundation
import ServiceManagement
import SwiftUI
import XCTest

@testable import CodexIPC
@testable import CodexEcho

final class MenuBarSettingsTests: XCTestCase {
  func testAppPresentationCopyUsesTheCodexEchoBrand() {
    XCTAssertEqual(AppPresentationCopy.displayName, "Codex Echo")
    XCTAssertEqual(AppPresentationCopy.settingsWindowTitle, "Codex Echo Settings")
    XCTAssertEqual(AppPresentationCopy.quitMenuTitle, "Quit Codex Echo")
    XCTAssertEqual(AppPresentationCopy.startupAnnouncement, "Codex Echo online.")
    XCTAssertEqual(
      AppPresentationCopy.launchAtLoginApprovalHint,
      "Opens System Settings so Codex Echo can be approved to launch at login."
    )
    XCTAssertEqual(
      AppPresentationCopy.launchAtLoginDescription,
      "Open Codex Echo automatically when you log in."
    )
  }

  func testSpeakAnnouncementsCopyKeepsMenuAndSettingsSemanticsAligned() {
    XCTAssertEqual(
      MenuBarSettingsCopy.speakAnnouncementsMenuTitle,
      "Speak Announcements"
    )
    XCTAssertEqual(
      MenuBarSettingsCopy.speakAnnouncementsSettingsTitle,
      "Speak announcements"
    )
    XCTAssertEqual(
      MenuBarSettingsCopy.speakAnnouncementsDescription,
      "Speaks the announcement and alert sound choices below."
    )
  }

  func testSoftwareUpdateSettingsCopyDistinguishesDistributionAndDevelopmentBuilds() {
    XCTAssertEqual(
      MenuBarSettingsCopy.automaticallyCheckForUpdatesTitle,
      "Automatically check for updates"
    )
    XCTAssertEqual(MenuBarSettingsCopy.checkNowTitle, "Check Now…")
    XCTAssertEqual(
      MenuBarSettingsCopy.softwareUpdateDescription(
        displayVersion: "0.1.1",
        isAvailable: true
      ),
      "Codex Echo 0.1.1."
    )
    XCTAssertEqual(
      MenuBarSettingsCopy.softwareUpdateDescription(
        displayVersion: "0.1.1",
        isAvailable: false
      ),
      "Codex Echo 0.1.1. Updates aren’t available in this development build."
    )
  }

  @MainActor
  func testSoftwareUpdateControllerOwnsAutomaticCheckingAndManualCheckActions() {
    var automaticCheckChanges: [Bool] = []
    var manualCheckCount = 0
    let controller = SparkleAppUpdateController(
      displayVersion: "0.1.1",
      isAvailable: true,
      canCheckForUpdates: true,
      automaticallyChecksForUpdates: false,
      checkForUpdatesAction: {
        manualCheckCount += 1
      },
      setAutomaticallyChecksForUpdatesAction: {
        automaticCheckChanges.append($0)
      }
    )

    XCTAssertEqual(controller.displayVersion, "0.1.1")
    XCTAssertTrue(controller.isAvailable)
    XCTAssertTrue(controller.canCheckForUpdates)
    XCTAssertFalse(controller.automaticallyChecksForUpdates)

    controller.setAutomaticallyChecksForUpdates(true)
    controller.checkForUpdates()

    XCTAssertTrue(controller.automaticallyChecksForUpdates)
    XCTAssertEqual(automaticCheckChanges, [true])
    XCTAssertEqual(manualCheckCount, 1)
  }

  @MainActor
  func testSoftwareUpdateControllerChecksInBackgroundOnceAtLaunchWhenAutomaticChecksAreEnabled() {
    var launchBackgroundCheckCount = 0

    _ = SparkleAppUpdateController(
      displayVersion: "0.1.1",
      isAvailable: true,
      canCheckForUpdates: true,
      automaticallyChecksForUpdates: true,
      checkForUpdatesInBackgroundAtLaunchAction: {
        launchBackgroundCheckCount += 1
      }
    )

    XCTAssertEqual(launchBackgroundCheckCount, 1)
  }

  @MainActor
  func testSoftwareUpdateControllerSkipsLaunchCheckWhenAutomaticChecksAreDisabled() {
    var launchBackgroundCheckCount = 0

    _ = SparkleAppUpdateController(
      displayVersion: "0.1.1",
      isAvailable: true,
      canCheckForUpdates: true,
      automaticallyChecksForUpdates: false,
      checkForUpdatesInBackgroundAtLaunchAction: {
        launchBackgroundCheckCount += 1
      }
    )

    XCTAssertEqual(launchBackgroundCheckCount, 0)
  }

  @MainActor
  func testSoftwareUpdateControllerSkipsLaunchCheckWhenUpdaterCannotCheck() {
    var launchBackgroundCheckCount = 0

    _ = SparkleAppUpdateController(
      displayVersion: "0.1.1",
      isAvailable: true,
      canCheckForUpdates: false,
      automaticallyChecksForUpdates: true,
      checkForUpdatesInBackgroundAtLaunchAction: {
        launchBackgroundCheckCount += 1
      }
    )

    XCTAssertEqual(launchBackgroundCheckCount, 0)
  }

  @MainActor
  func testSoftwareUpdateControllerTracksLiveUpdaterState() {
    let canCheckForUpdates = PassthroughSubject<Bool, Never>()
    let automaticallyChecksForUpdates = PassthroughSubject<Bool, Never>()
    let controller = SparkleAppUpdateController(
      displayVersion: "0.1.1",
      isAvailable: true,
      canCheckForUpdates: true,
      automaticallyChecksForUpdates: false,
      canCheckForUpdatesPublisher: canCheckForUpdates.eraseToAnyPublisher(),
      automaticallyChecksForUpdatesPublisher:
        automaticallyChecksForUpdates.eraseToAnyPublisher()
    )

    canCheckForUpdates.send(false)
    automaticallyChecksForUpdates.send(true)

    XCTAssertFalse(controller.canCheckForUpdates)
    XCTAssertTrue(controller.automaticallyChecksForUpdates)

    canCheckForUpdates.send(true)
    automaticallyChecksForUpdates.send(false)

    XCTAssertTrue(controller.canCheckForUpdates)
    XCTAssertFalse(controller.automaticallyChecksForUpdates)
  }

  func testCapacityPresentationUsesOneUserFacingVocabulary() {
    XCTAssertEqual(
      [
        MenuBarSettingsCopy.generalSectionTitle,
        MenuBarSettingsCopy.menuBarSectionTitle,
        MenuBarSettingsCopy.capacityPaneTitle,
        MenuBarSettingsCopy.speechPaneTitle,
      ],
      ["General", "Menu Bar", "Capacity", "Speech"]
    )
    XCTAssertEqual(
      MenuBarSettingsCopy.showCapacityInMenuBarTitle,
      "Show Capacity in Menu Bar"
    )
    XCTAssertEqual(
      MenuBarSettingsCopy.recordCapacityHistoryTitle,
      "Record Capacity History"
    )
    XCTAssertEqual(
      MenuBarSettingsCopy.recordCapacityHistoryDescription,
      "Saves new Capacity observations locally. Turning this off stops new entries; existing history remains available until cleared."
    )
    XCTAssertEqual(MenuBarSettingsCopy.codexCapacityMenuTitle, "Codex Capacity")
    XCTAssertEqual(
      CapacityMenuItemPresentation.systemImageName,
      "gauge.open.with.lines.needle.33percent"
    )
    XCTAssertEqual(
      CapacityMenuItemPresentation.make(
        remainingPercent: 43
      ),
      CapacityMenuItemPresentation(
        title: "Codex Capacity (43%)"
      )
    )
    XCTAssertEqual(
      CapacityMenuItemPresentation.make(
        remainingPercent: nil
      ),
      CapacityMenuItemPresentation(
        title: "Codex Capacity"
      )
    )
  }

  func testSettingsUseFourNativeToolbarPanes() {
    XCTAssertEqual(
      MenuBarSettingsPane.allCases.map(\.title),
      ["General", "Menu Bar", "Capacity", "Speech"]
    )
    XCTAssertEqual(
      MenuBarSettingsPane.allCases.map(\.systemImageName),
      [
        "gearshape",
        "menubar.rectangle",
        "gauge.open.with.lines.needle.33percent",
        "speaker.wave.2",
      ]
    )
    XCTAssertEqual(MenuBarSettingsMetrics.width, 460)
    XCTAssertEqual(MenuBarSettingsMetrics.toolbarStyle, .preference)
    XCTAssertEqual(MenuBarSettingsMetrics.titlebarSeparatorStyle, .none)
  }

  @MainActor
  func testCapacityHistoryRecordingDefaultsOnAndPersistsAnExplicitChoice() {
    withSettingsDefaults { defaults in
      let settings = MenuBarSettings(userDefaults: defaults)

      XCTAssertTrue(settings.recordsCapacityHistory)
      XCTAssertNil(defaults.object(forKey: "recordsCapacityHistory"))

      settings.recordsCapacityHistory = false

      XCTAssertFalse(
        MenuBarSettings(userDefaults: defaults).recordsCapacityHistory
      )
      XCTAssertEqual(
        defaults.object(forKey: "recordsCapacityHistory") as? Bool,
        false
      )
    }
  }

  @MainActor
  func testSettingsHeightFollowsTheVisiblePaneContent() {
    withSettings { settings, _ in
      settings.selectedPane = .general
      let compactSize = settingsFittingSize(
        settings: settings,
        launchAtLogin: LaunchAtLoginController(
          service: LaunchAtLoginServiceSpy(status: .enabled)
        )
      )
      let approvalSize = settingsFittingSize(
        settings: settings,
        launchAtLogin: LaunchAtLoginController(
          service: LaunchAtLoginServiceSpy(status: .requiresApproval)
        )
      )

      XCTAssertEqual(
        compactSize.width,
        MenuBarSettingsMetrics.width,
        accuracy: 1
      )
      XCTAssertEqual(
        approvalSize.width,
        MenuBarSettingsMetrics.width,
        accuracy: 1
      )
      XCTAssertGreaterThan(approvalSize.height, compactSize.height)
    }
  }

  @MainActor
  func testSettingsRestoreTheMostRecentlyViewedPane() {
    withSettings { settings, defaults in
      XCTAssertEqual(settings.selectedPane, .general)

      settings.selectedPane = .announcements

      XCTAssertEqual(
        MenuBarSettings(userDefaults: defaults).selectedPane,
        .announcements
      )
    }
  }

  @MainActor
  func testCompletedTaskAutoHideDefaultsAndChoicesStayFinite() {
    withSettings { settings, _ in
      XCTAssertTrue(settings.automaticallyHidesCompletedTasks)
      XCTAssertEqual(settings.completedTaskAutoHideDelay, .fifteenMinutes)
      XCTAssertEqual(
        CompletedTaskAutoHideDelay.allCases.map(\.title),
        ["5 minutes", "15 minutes", "30 minutes", "1 hour"]
      )
      XCTAssertEqual(
        CompletedTaskAutoHideDelay.allCases.map(\.timeInterval),
        [300, 900, 1_800, 3_600]
      )
      XCTAssertEqual(
        MenuBarSettingsCopy.automaticallyHideCompletedTasksTitle,
        "Hide completed tasks"
      )
      XCTAssertEqual(
        MenuBarSettingsCopy.automaticallyHideCompletedTasksDescription,
        "After completion; unread tasks stay visible."
      )
      XCTAssertEqual(MenuBarSettingsCopy.completedTaskAutoHideDelayTitle, "Hide after")
    }
  }

  @MainActor
  func testCompletedTaskAutoHideSettingsPersist() {
    withSettings { settings, defaults in
      settings.automaticallyHidesCompletedTasks = false
      settings.completedTaskAutoHideDelay = .oneHour

      let restored = MenuBarSettings(userDefaults: defaults)

      XCTAssertFalse(restored.automaticallyHidesCompletedTasks)
      XCTAssertEqual(restored.completedTaskAutoHideDelay, .oneHour)
    }
  }

  func testAnnouncementEventsExposeTheirSpokenTextAsGroupedSettingsCopy() {
    XCTAssertEqual(
      SpokenAnnouncementCategory.allCases.map(\.title),
      ["Startup", "Task", "Capacity", "Subagent", "Connection"]
    )
    XCTAssertEqual(
      SpokenAnnouncementEvent.events(in: .startup).map(\.announcementText),
      ["Codex Echo online."]
    )
    XCTAssertEqual(
      StartupAnnouncementInformation.allCases.map(\.announcementText),
      [
        "Codex capacity, 67 percent remaining.",
        "2 active task signals detected.",
      ]
    )
    XCTAssertEqual(
      SpokenAnnouncementEvent.events(in: .task).map(\.announcementText),
      [
        "Task initiated.",
        "Task complete.",
        "Input required.",
        "Approval required.",
        "Task error.",
        "Execution resumed.",
        "Directive queued.",
        "Processing.",
        "Analysis.",
        "Planning.",
        "Command execution.",
        "File modification.",
        "Agent coordination.",
        "Permission check.",
        "Response generation.",
        "Context compaction.",
      ]
    )
    XCTAssertEqual(
      SpokenAnnouncementEvent.events(in: .capacity).map(\.announcementText),
      [
        "Codex capacity, 67 percent remaining.",
        "Codex capacity, 20 percent remaining.",
        "Codex capacity, 10 percent remaining.",
        "Codex capacity, 5 percent remaining.",
        "Codex capacity, 1 percent remaining.",
        "Codex capacity depleted.",
        "Codex capacity increased to 100 percent.",
      ]
    )
    XCTAssertEqual(
      SpokenAnnouncementEvent.events(in: .subagent).map(\.announcementText),
      ["Sub-agent active."]
    )
    XCTAssertEqual(
      SpokenAnnouncementEvent.events(in: .connection).map(\.announcementText),
      [
        "Codex monitoring interrupted.",
        "Codex monitoring restored.",
        "Codex application offline.",
        "Codex application online.",
      ]
    )
    XCTAssertEqual(
      SpokenAnnouncementEvent.approvalRequired.announcementText,
      "Approval required."
    )
  }

  func testAnnouncementRowsUseTheSpokenTextAsTheirOnlyTitle() {
    for event in SpokenAnnouncementEvent.allCases {
      XCTAssertEqual(
        event.definition.announcementText,
        event.announcementText,
        event.rawValue
      )
    }
  }

  func testVariableAnnouncementRowsUseTemplatesInsteadOfFakeLiveValues() {
    XCTAssertEqual(
      SpokenAnnouncementEvent.usageChanged.settingsText,
      "Codex capacity, [remaining] percent remaining."
    )
    XCTAssertEqual(
      SpokenAnnouncementEvent.usageOnePercent.settingsText,
      "Codex capacity, 1 percent remaining."
    )
    XCTAssertEqual(
      SpokenAnnouncementEvent.usageIncreased.settingsText,
      "Codex capacity increased to [remaining] percent."
    )
    XCTAssertEqual(
      StartupAnnouncementInformation.codexCapacity.settingsText,
      "Codex capacity, [remaining] percent remaining."
    )
    XCTAssertEqual(
      StartupAnnouncementInformation.activeTasks.settingsText,
      "[count] active task signals detected."
    )
  }

  func testAnnouncementSearchMatchesConcreteVisibleAnnouncementCopy() {
    XCTAssertEqual(
      SpokenAnnouncementSearch.results(
        in: .task,
        matching: "response generation"
      ).map(\.event),
      [.taskResponseGeneration]
    )
    XCTAssertEqual(
      SpokenAnnouncementSearch.results(
        in: .task,
        matching: "writing response"
      ).map(\.event),
      [.taskResponseGeneration]
    )
    XCTAssertEqual(
      SpokenAnnouncementSearch.results(
        in: .task,
        matching: "thinking"
      ).map(\.event),
      [.taskAnalysis]
    )
    XCTAssertEqual(
      SpokenAnnouncementSearch.results(
        in: .task,
        matching: "needs input"
      ).map(\.event),
      [.inputRequired]
    )
    XCTAssertEqual(
      SpokenAnnouncementSearch.results(
        in: .task,
        matching: "waitingOnApproval"
      ).map(\.event),
      [.approvalRequired]
    )
    XCTAssertEqual(
      SpokenAnnouncementSearch.results(
        in: .task,
        matching: "blocked"
      ).map(\.event),
      [.taskError]
    )
    XCTAssertEqual(
      SpokenAnnouncementSearch.results(
        in: .task,
        matching: "systemError"
      ).map(\.event),
      [.taskError]
    )
    XCTAssertEqual(
      SpokenAnnouncementSearch.results(
        in: .connection,
        matching: "OFFLINE"
      ).map(\.event),
      [.applicationOffline]
    )
    XCTAssertEqual(
      SpokenAnnouncementSearch.results(
        in: .capacity,
        matching: "capacity"
      ).map(\.event),
      SpokenAnnouncementEvent.events(in: .capacity)
    )
    XCTAssertEqual(
      SpokenAnnouncementSearch.startupInformation(matching: "running tasks"),
      [.activeTasks]
    )
  }

  func testResponseSearchResultHasOneConsistentMeaning() throws {
    let responseResult = try XCTUnwrap(
      SpokenAnnouncementSearch.results(
        in: .task,
        matching: "response"
      ).first
    )
    XCTAssertEqual(responseResult.event, .taskResponseGeneration)
    XCTAssertEqual(
      responseResult.event.announcementText,
      "Response generation."
    )
  }

  func testEveryTaskActivityMapsToOneConcreteAnnouncement() {
    XCTAssertEqual(
      CodexTaskCurrentActivity.allCases.map(
        SpokenAnnouncementEvent.event(for:)
      ),
      [
        .taskProcessing,
        .taskAnalysis,
        .taskPlanning,
        .taskCommandExecution,
        .taskFileModification,
        .taskAgentCoordination,
        .taskPermissionCheck,
        .taskResponseGeneration,
        .taskContextCompaction,
      ]
    )
    XCTAssertEqual(
      SpokenAnnouncementEvent.taskActivityEvents.map(\.announcementText),
      CodexTaskCurrentActivity.allCases.map(SpokenUpdateCopy.activityStatus)
    )
  }

  func testAnnouncementSearchTreatsWhitespaceAsUnfiltered() {
    XCTAssertFalse(SpokenAnnouncementSearch.hasQuery(" \n "))
    for category in SpokenAnnouncementCategory.allCases {
      XCTAssertEqual(
        SpokenAnnouncementSearch.results(
          in: category,
          matching: " \n "
        ).map(\.event),
        SpokenAnnouncementEvent.events(in: category)
      )
    }
    XCTAssertEqual(
      SpokenAnnouncementSearch.startupInformation(matching: " \n "),
      StartupAnnouncementInformation.allCases
    )
  }

  func testAlertSoundChoicesUseTheSamePipNamesInUIAndStorage()
    throws
  {
    XCTAssertEqual(
      SpokenAnnouncementAlertSound.allCases.map(\.title),
      ["None", "1 Pip", "2 Pips"]
    )
    XCTAssertEqual(SpokenAnnouncementAlertSound.onePip.rawValue, "onePip")
    XCTAssertEqual(
      SpokenAnnouncementAlertSound.twoPips.rawValue,
      "twoPips"
    )
    XCTAssertEqual(
      try JSONDecoder().decode(
        SpokenAnnouncementAlertSound.self,
        from: Data(#""onePip""#.utf8)
      ),
      .onePip
    )
    XCTAssertEqual(
      try JSONDecoder().decode(
        SpokenAnnouncementAlertSound.self,
        from: Data(#""twoPips""#.utf8)
      ),
      .twoPips
    )
  }

  @MainActor
  func testAnnouncementCustomizationUsesAnIndependentMovableResizableWindow()
  {
    withSettings { settings, _ in
      let windowController = SpokenAnnouncementWindowFactory.make(
        settings: settings,
        previewSpokenAnnouncement: { _ in },
        savesFrame: false
      )
      guard let window = windowController.window else {
        XCTFail("Expected an announcement customization window")
        return
      }

      XCTAssertEqual(window.title, "Customize Announcements")
      XCTAssertNil(window.sheetParent)
      XCTAssertTrue(window.isMovable)
      XCTAssertTrue(window.styleMask.contains(.titled))
      XCTAssertTrue(window.styleMask.contains(.closable))
      XCTAssertTrue(window.styleMask.contains(.resizable))
      XCTAssertEqual(
        window.contentMinSize,
        NSSize(
          width: MenuBarSettingsMetrics.announcementWindowMinimumWidth,
          height: MenuBarSettingsMetrics.announcementWindowMinimumHeight
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
  }

  func testAnnouncementRowsUseOneSharedColumnMetricsContract() {
    XCTAssertEqual(
      MenuBarSettingsMetrics.spokenAnnouncementColumns,
      SpokenAnnouncementColumnMetrics(
        spacing: 12,
        horizontalPadding: 12,
        speakWidth: 52,
        alertSoundWidth: 210,
        previewWidth: 52
      )
    )
  }

  @MainActor
  func testAnnouncementSettingsUsesANativeSearchField() {
    withSettings { settings, _ in
      let view = NSHostingView(
        rootView: SpokenAnnouncementSettingsView(
          settings: settings,
          previewSpokenAnnouncement: { _ in },
          close: {}
        )
      )
      view.frame = NSRect(
        origin: .zero,
        size: NSSize(
          width: MenuBarSettingsMetrics.announcementWindowWidth,
          height: MenuBarSettingsMetrics.announcementWindowHeight
        )
      )
      view.layoutSubtreeIfNeeded()
      view.displayIfNeeded()

      @MainActor
      func descendants(of root: NSView) -> [NSView] {
        root.subviews.flatMap { [$0] + descendants(of: $0) }
      }

      guard
        let searchField = descendants(of: view)
          .compactMap({ $0 as? NSSearchField })
          .first
      else {
        XCTFail("Expected a native announcement search field")
        return
      }

      XCTAssertEqual(searchField.placeholderString, "Search announcements")
      XCTAssertEqual(searchField.accessibilityLabel(), "Search announcements")
    }
  }

  func testDefaultAnnouncementConfigurationSpeaksEveryEventWithExpectedAlerts() {
    let configuration = SpokenAnnouncementConfiguration.defaults

    XCTAssertEqual(configuration.allEventsSpeakState, .allOn)
    XCTAssertNil(configuration.allEventsAlertSound)
    for event in SpokenAnnouncementEvent.allCases {
      XCTAssertEqual(
        configuration.rule(for: event),
        event.definition.defaultRule,
        "\(event)"
      )
    }
    XCTAssertEqual(
      configuration.rule(for: .startupSummary).alertSound,
      .onePip
    )
    XCTAssertEqual(
      configuration.rule(for: .approvalRequired).alertSound,
      .twoPips
    )
    XCTAssertEqual(
      configuration.rule(for: .usageFivePercent).alertSound,
      .onePip
    )
    XCTAssertEqual(
      configuration.rule(for: .usageOnePercent).alertSound,
      .onePip
    )
    XCTAssertEqual(
      configuration.rule(for: .usageDepleted).alertSound,
      .onePip
    )
    XCTAssertEqual(
      configuration.rule(for: .applicationOffline).alertSound,
      .onePip
    )
    XCTAssertEqual(
      configuration.rule(for: .applicationOnline).alertSound,
      .onePip
    )
    XCTAssertEqual(
      configuration.rule(for: .monitoringInterrupted).alertSound,
      .onePip
    )
    XCTAssertEqual(
      configuration.rule(for: .monitoringRestored).alertSound,
      .none
    )
    XCTAssertEqual(
      configuration.rule(for: .taskCompleted).alertSound,
      .onePip
    )
    XCTAssertTrue(configuration.includesStartupInformation(.activeTasks))
    XCTAssertTrue(configuration.includesStartupInformation(.codexCapacity))
  }

  func testAllEventsBulkStateTracksAndAppliesMixedEventChoices() {
    var configuration = SpokenAnnouncementConfiguration.defaults

    configuration.setAllEventsSpeak(false)

    XCTAssertEqual(configuration.allEventsSpeakState, .allOff)
    XCTAssertTrue(
      SpokenAnnouncementEvent.allCases.allSatisfy {
        !configuration.rule(for: $0).speaks
      }
    )

    configuration.setSpeaks(true, for: .startupSummary)

    XCTAssertEqual(configuration.allEventsSpeakState, .mixed)

    configuration.setAllEventsAlertSound(.none)

    XCTAssertEqual(
      configuration.allEventsAlertSound,
      SpokenAnnouncementAlertSound.none
    )
    XCTAssertTrue(
      SpokenAnnouncementEvent.allCases.allSatisfy {
        configuration.rule(for: $0).alertSound == .none
      }
    )

    configuration.setAlertSound(.onePip, for: .startupSummary)

    XCTAssertNil(configuration.allEventsAlertSound)
  }

  @MainActor
  func testAllEventsBulkEditsPersistWithoutChangingMasterOrStartupInformation()
  {
    withSettings { settings, defaults in
      settings.setStartupAnnouncementIncludes(
        false,
        information: .codexCapacity
      )

      settings.setAllEventsSpeak(false)
      settings.setAllEventsAlertSound(.twoPips)

      XCTAssertFalse(settings.speaksAnnouncements)
      XCTAssertEqual(settings.allEventsSpeakState, .allOff)
      XCTAssertEqual(settings.allEventsAlertSound, .twoPips)
      XCTAssertFalse(settings.startupAnnouncementIncludes(.codexCapacity))

      let restored = MenuBarSettings(userDefaults: defaults)
      XCTAssertFalse(restored.speaksAnnouncements)
      XCTAssertEqual(restored.allEventsSpeakState, .allOff)
      XCTAssertEqual(restored.allEventsAlertSound, .twoPips)
      XCTAssertFalse(restored.startupAnnouncementIncludes(.codexCapacity))
    }
  }

  @MainActor
  func testEditingAnAnnouncementPersistsWithoutChangingTheMasterSwitch() {
    withSettings { settings, defaults in
      XCTAssertFalse(settings.speaksAnnouncements)
      settings.setSpokenAnnouncementSpeaks(
        false,
        for: .subagentBecameActive
      )
      settings.setSpokenAnnouncementAlertSound(
        .onePip,
        for: .taskCompleted
      )

      XCTAssertFalse(settings.speaksAnnouncements)
      XCTAssertFalse(
        settings.spokenAnnouncementRule(for: .subagentBecameActive).speaks
      )
      XCTAssertEqual(
        settings.spokenAnnouncementRule(for: .taskCompleted).alertSound,
        .onePip
      )

      let restored = MenuBarSettings(userDefaults: defaults)
      XCTAssertFalse(restored.speaksAnnouncements)
      XCTAssertFalse(
        restored.spokenAnnouncementRule(for: .subagentBecameActive).speaks
      )
      XCTAssertEqual(
        restored.spokenAnnouncementRule(for: .taskCompleted).alertSound,
        .onePip
      )
    }
  }

  @MainActor
  func testCurrentCustomConfigurationAndEnabledStateRestore() throws {
    var configuration = SpokenAnnouncementConfiguration.defaults
    configuration.setSpeaks(false, for: .taskCompleted)
    let data = try JSONEncoder().encode(configuration)

    withSettingsDefaults { defaults in
      defaults.set(true, forKey: "speaksAnnouncements")
      defaults.set(data, forKey: "spokenAnnouncementConfiguration")

      let settings = MenuBarSettings(userDefaults: defaults)

      XCTAssertTrue(settings.speaksAnnouncements)
      XCTAssertFalse(
        settings.spokenAnnouncementRule(for: .taskCompleted).speaks
      )
      XCTAssertTrue(defaults.bool(forKey: "speaksAnnouncements"))
    }
  }

  @MainActor
  func testIncompatibleAnnouncementConfigurationFallsBackToDefaults() {
    withSettingsDefaults { defaults in
      defaults.set(
        Data(#"{"rulesByEventID":{}}"#.utf8),
        forKey: "spokenAnnouncementConfiguration"
      )

      let settings = MenuBarSettings(userDefaults: defaults)

      XCTAssertEqual(settings.allEventsSpeakState, .allOn)
      XCTAssertTrue(settings.startupAnnouncementIncludes(.activeTasks))
      XCTAssertTrue(settings.startupAnnouncementIncludes(.codexCapacity))
      XCTAssertEqual(
        settings.spokenAnnouncementRule(for: .startupSummary).alertSound,
        .onePip
      )
    }
  }

  @MainActor
  func testAnnouncementConfigurationMissingACurrentEventIsCleared() throws {
    let encodedDefaults = try JSONEncoder().encode(
      SpokenAnnouncementConfiguration.defaults
    )
    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: encodedDefaults)
        as? [String: Any]
    )
    var rulesByEventID = try XCTUnwrap(
      object["rulesByEventID"] as? [String: Any]
    )
    rulesByEventID.removeValue(
      forKey: SpokenAnnouncementEvent.applicationOnline.rawValue
    )
    object["rulesByEventID"] = rulesByEventID
    let incompleteData = try JSONSerialization.data(withJSONObject: object)

    withSettingsDefaults { defaults in
      defaults.set(
        incompleteData,
        forKey: "spokenAnnouncementConfiguration"
      )

      let settings = MenuBarSettings(userDefaults: defaults)

      XCTAssertEqual(settings.allEventsSpeakState, .allOn)
      XCTAssertTrue(
        settings.spokenAnnouncementRule(for: .applicationOnline).speaks
      )
      XCTAssertNil(
        defaults.object(forKey: "spokenAnnouncementConfiguration")
      )
    }
  }

  @MainActor
  func testAnnouncementConfigurationWithUnknownStartupInformationIsCleared()
    throws
  {
    let encodedDefaults = try JSONEncoder().encode(
      SpokenAnnouncementConfiguration.defaults
    )
    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: encodedDefaults)
        as? [String: Any]
    )
    var startupInformationIDs = try XCTUnwrap(
      object["startupInformationIDs"] as? [String]
    )
    startupInformationIDs.append("futureUnknownInformation")
    object["startupInformationIDs"] = startupInformationIDs
    let incompatibleData = try JSONSerialization.data(withJSONObject: object)

    withSettingsDefaults { defaults in
      defaults.set(
        incompatibleData,
        forKey: "spokenAnnouncementConfiguration"
      )

      let settings = MenuBarSettings(userDefaults: defaults)

      XCTAssertEqual(settings.allEventsSpeakState, .allOn)
      XCTAssertTrue(settings.startupAnnouncementIncludes(.activeTasks))
      XCTAssertTrue(settings.startupAnnouncementIncludes(.codexCapacity))
      XCTAssertNil(
        defaults.object(forKey: "spokenAnnouncementConfiguration")
      )
    }
  }

  @MainActor
  func testStartupInformationChoicesPersistInsideTheStartupAnnouncement() {
    withSettings { settings, defaults in
      settings.setStartupAnnouncementIncludes(
        false,
        information: .activeTasks
      )

      XCTAssertFalse(settings.startupAnnouncementIncludes(.activeTasks))
      XCTAssertTrue(settings.startupAnnouncementIncludes(.codexCapacity))

      let restored = MenuBarSettings(userDefaults: defaults)
      XCTAssertFalse(restored.startupAnnouncementIncludes(.activeTasks))
      XCTAssertTrue(restored.startupAnnouncementIncludes(.codexCapacity))
    }
  }

  @MainActor
  func testDisablingStartupAnnouncementDisablesButPreservesItsInformationChoices()
  {
    withSettings { settings, _ in
      settings.setStartupAnnouncementIncludes(
        false,
        information: .codexCapacity
      )
      settings.setSpokenAnnouncementSpeaks(
        false,
        for: .startupSummary
      )

      XCTAssertFalse(settings.startupInformationControlsAreEnabled)
      XCTAssertTrue(settings.startupAnnouncementIncludes(.activeTasks))
      XCTAssertFalse(settings.startupAnnouncementIncludes(.codexCapacity))

      settings.setSpokenAnnouncementSpeaks(
        true,
        for: .startupSummary
      )

      XCTAssertTrue(settings.startupInformationControlsAreEnabled)
      XCTAssertTrue(settings.startupAnnouncementIncludes(.activeTasks))
      XCTAssertFalse(settings.startupAnnouncementIncludes(.codexCapacity))
    }
  }

  @MainActor
  func testMasterSwitchKeepsTheEditedConfiguration() {
    withSettings { settings, defaults in
      settings.setSpokenAnnouncementSpeaks(false, for: .taskCompleted)
      settings.speaksAnnouncements = true
      XCTAssertFalse(
        settings.spokenAnnouncementDelivery.rule(for: .taskCompleted).speaks
      )

      settings.speaksAnnouncements = false
      XCTAssertFalse(
        settings.spokenAnnouncementDelivery.rule(for: .taskStarted).speaks
      )
      let restored = MenuBarSettings(userDefaults: defaults)
      XCTAssertFalse(restored.speaksAnnouncements)
      XCTAssertFalse(
        restored.spokenAnnouncementRule(for: .taskCompleted).speaks
      )
    }
  }

  @MainActor
  func testRestoreDefaultsKeepsTheMasterSwitchAndRestoresAllActivity() {
    withSettings { settings, _ in
      settings.speaksAnnouncements = true
      settings.setSpokenAnnouncementSpeaks(false, for: .taskCompleted)
      settings.setSpokenAnnouncementAlertSound(.twoPips, for: .taskCompleted)
      settings.setStartupAnnouncementIncludes(
        false,
        information: .codexCapacity
      )

      settings.restoreDefaultSpokenAnnouncements()

      XCTAssertTrue(settings.speaksAnnouncements)
      XCTAssertTrue(settings.spokenAnnouncementRule(for: .taskCompleted).speaks)
      XCTAssertEqual(
        settings.spokenAnnouncementRule(for: .taskCompleted).alertSound,
        .onePip
      )
      XCTAssertTrue(
        settings.spokenAnnouncementRule(for: .taskAnalysis).speaks
      )
      XCTAssertEqual(
        settings.spokenAnnouncementRule(for: .startupSummary).alertSound,
        .onePip
      )
      XCTAssertTrue(settings.startupAnnouncementIncludes(.activeTasks))
      XCTAssertTrue(settings.startupAnnouncementIncludes(.codexCapacity))
    }
  }

  @MainActor
  func testDefaultsMatchTheCurrentMenuBarBehavior() {
    withSettings { settings, _ in
      XCTAssertEqual(settings.maximumVisibleTaskCount, 4)
      XCTAssertEqual(settings.taskOpenMouseButton, .left)
      XCTAssertFalse(settings.speaksAnnouncements)
      XCTAssertEqual(settings.defaultSpokenUpdateVoice, .defaultVoice)
      XCTAssertTrue(settings.showsCapacityInMenuBar)
      XCTAssertTrue(settings.recordsCapacityHistory)
      XCTAssertTrue(
        settings.spokenAnnouncementRule(for: .taskAnalysis).speaks
      )
    }
  }

  @MainActor
  func testSettingsPersistAcrossInstances() {
    withSettings { settings, defaults in
      let persistedVoice = SpokenUpdateVoice.defaultVoice
      settings.maximumVisibleTaskCount = 7
      settings.taskOpenMouseButton = .right
      settings.speaksAnnouncements = true
      settings.showsCapacityInMenuBar = true
      settings.recordsCapacityHistory = false
      settings.defaultSpokenUpdateVoice = persistedVoice

      let restored = MenuBarSettings(userDefaults: defaults)
      XCTAssertEqual(restored.maximumVisibleTaskCount, 7)
      XCTAssertEqual(restored.taskOpenMouseButton, .right)
      XCTAssertTrue(restored.speaksAnnouncements)
      XCTAssertTrue(restored.showsCapacityInMenuBar)
      XCTAssertFalse(restored.recordsCapacityHistory)
      XCTAssertEqual(restored.defaultSpokenUpdateVoice, persistedVoice)
    }
  }

  @MainActor
  func testZeroVisibleTaskCountPersistsAcrossInstances() {
    withSettings { settings, defaults in
      settings.maximumVisibleTaskCount = 0

      let restored = MenuBarSettings(userDefaults: defaults)

      XCTAssertEqual(restored.maximumVisibleTaskCount, 0)
    }
  }

  @MainActor
  func testUnavailableStoredDefaultVoiceFallsBackToZarvox() {
    withSettingsDefaults { defaults in
      defaults.set(
        "com.example.removed-voice",
        forKey: "defaultSpokenUpdateVoiceIdentifier"
      )

      XCTAssertEqual(
        MenuBarSettings(userDefaults: defaults).defaultSpokenUpdateVoice,
        .defaultVoice
      )
    }
  }

  @MainActor
  func testLegacySpokenSettingsAreIgnored() {
    withSettingsDefaults { defaults in
      defaults.set(true, forKey: "spokenUpdatesEnabled")
      defaults.set("allActivity", forKey: "spokenUpdateLevel")

      let settings = MenuBarSettings(userDefaults: defaults)

      XCTAssertFalse(settings.speaksAnnouncements)
      XCTAssertEqual(settings.allEventsSpeakState, .allOn)
      XCTAssertNil(defaults.object(forKey: "speaksAnnouncements"))
    }
  }

  @MainActor
  func testMissingPreferencesDefaultCapacityOnAndAnnouncementsOff() {
    withSettingsDefaults { defaults in
      let settings = MenuBarSettings(userDefaults: defaults)

      XCTAssertFalse(settings.speaksAnnouncements)
      XCTAssertTrue(settings.showsCapacityInMenuBar)
      XCTAssertTrue(settings.recordsCapacityHistory)
      XCTAssertNil(defaults.object(forKey: "speaksAnnouncements"))
      XCTAssertNil(defaults.object(forKey: "showsCapacityInMenuBar"))
      XCTAssertNil(defaults.object(forKey: "recordsCapacityHistory"))
    }
  }

  @MainActor
  func testExplicitlyDisabledCapacityAndAnnouncementsStayOff() {
    withSettingsDefaults { defaults in
      defaults.set(false, forKey: "speaksAnnouncements")
      defaults.set(false, forKey: "showsCapacityInMenuBar")

      let settings = MenuBarSettings(userDefaults: defaults)

      XCTAssertFalse(settings.speaksAnnouncements)
      XCTAssertFalse(settings.showsCapacityInMenuBar)
    }
  }

  @MainActor
  func testMaximumVisibleTaskCountStaysWithinTheSupportedRange() {
    withSettings { settings, _ in
      settings.maximumVisibleTaskCount = -1
      XCTAssertEqual(settings.maximumVisibleTaskCount, 0)

      settings.maximumVisibleTaskCount = 0
      XCTAssertEqual(settings.maximumVisibleTaskCount, 0)

      settings.maximumVisibleTaskCount = 99
      XCTAssertEqual(settings.maximumVisibleTaskCount, 16)
    }
  }

  @MainActor
  func testInitialOverridesDoNotChangePersistedPreferences() {
    withSettings { _, defaults in
      let overridden = MenuBarSettings(
        userDefaults: defaults,
        initialSelectedPaneOverride: .menuBar,
        initialMaximumVisibleTaskCountOverride: 7,
        initialShowsCapacityInMenuBarOverride: true,
        initialTaskOpenMouseButtonOverride: .right
      )
      XCTAssertEqual(overridden.selectedPane, .menuBar)
      XCTAssertEqual(overridden.maximumVisibleTaskCount, 7)
      XCTAssertTrue(overridden.showsCapacityInMenuBar)
      XCTAssertEqual(overridden.taskOpenMouseButton, .right)

      let restored = MenuBarSettings(userDefaults: defaults)
      XCTAssertEqual(restored.selectedPane, .general)
      XCTAssertEqual(restored.maximumVisibleTaskCount, 4)
      XCTAssertTrue(restored.showsCapacityInMenuBar)
      XCTAssertEqual(restored.taskOpenMouseButton, .left)
    }
  }

  func testClickPolicyUsesTheConfiguredMouseButtonOnlyForTaskRings() {
    XCTAssertEqual(
      StatusItemClickPolicy.intent(
        isSecondaryClick: false,
        target: .task,
        taskOpenMouseButton: .left
      ),
      .openTask
    )
    XCTAssertEqual(
      StatusItemClickPolicy.intent(
        isSecondaryClick: true,
        target: .task,
        taskOpenMouseButton: .left
      ),
      .showMenu
    )
    XCTAssertEqual(
      StatusItemClickPolicy.intent(
        isSecondaryClick: false,
        target: .task,
        taskOpenMouseButton: .right
      ),
      .showMenu
    )
    XCTAssertEqual(
      StatusItemClickPolicy.intent(
        isSecondaryClick: true,
        target: .task,
        taskOpenMouseButton: .right
      ),
      .openTask
    )
    XCTAssertEqual(
      StatusItemClickPolicy.intent(
        isSecondaryClick: false,
        target: .overflow,
        taskOpenMouseButton: .left
      ),
      .showOverflowMenu
    )
    XCTAssertEqual(
      StatusItemClickPolicy.intent(
        isSecondaryClick: true,
        target: .overflow,
        taskOpenMouseButton: .left
      ),
      .showOverflowMenu
    )
    XCTAssertEqual(
      StatusItemClickPolicy.intent(
        isSecondaryClick: false,
        target: .overflow,
        taskOpenMouseButton: .right
      ),
      .showOverflowMenu
    )
    XCTAssertEqual(
      StatusItemClickPolicy.intent(
        isSecondaryClick: true,
        target: .overflow,
        taskOpenMouseButton: .right
      ),
      .showOverflowMenu
    )
    XCTAssertEqual(
      StatusItemClickPolicy.intent(
        isSecondaryClick: false,
        target: .background,
        taskOpenMouseButton: .right
      ),
      .showMenu
    )
    XCTAssertEqual(
      StatusItemClickPolicy.intent(
        isSecondaryClick: true,
        target: .background,
        taskOpenMouseButton: .right
      ),
      .showMenu
    )
  }

  func testConfiguredMaximumControlsVisibleTasksAndStatusItemWidth() {
    let tasks = (1...6).map { index in
      TaskPresentation(
        id: "task-\(index)",
        title: "Task \(index)",
        project: nil,
        state: .working,
        activeSubagentCount: 0,
        updatedAt: nil
      )
    }

    XCTAssertEqual(
      StatusItemTaskPolicy.statusBarTasks(from: tasks, limit: 2).map(\.id),
      ["task-1", "task-2"]
    )
    XCTAssertEqual(
      WorkerCrewLayout.contentWidth(
        forCrewCount: tasks.count,
        maximumVisibleCrews: 2
      ),
      WorkerCrewLayout.taskGroupWidth(for: 2)
        + WorkerCrewLayout.summarySpacing
        + WorkerCrewLayout.summaryWidth(
          overflowCount: 4,
          capacityRemainingPercent: nil
        )
    )
  }

  func testCapacitySummaryUsesItsRenderedDigitWidth() {
    let capacityWidth = WorkerCrewLayout.summaryWidth(
      overflowCount: 0,
      capacityRemainingPercent: 9
    )
    XCTAssertGreaterThanOrEqual(capacityWidth, 24)
    XCTAssertLessThanOrEqual(capacityWidth, 27)
    XCTAssertEqual(
      WorkerCrewLayout.contentWidth(
        forDisplayedCrewCount: 0,
        overflowCount: 0,
        capacityRemainingPercent: 9
      ),
      WorkerCrewLayout.cellWidth
        + WorkerCrewLayout.summarySpacing
        + capacityWidth
    )
    XCTAssertEqual(
      WorkerCrewLayout.contentWidth(
        forDisplayedCrewCount: 2,
        overflowCount: 0,
        capacityRemainingPercent: 9
      ),
      WorkerCrewLayout.taskGroupWidth(for: 2)
        + WorkerCrewLayout.summarySpacing
        + capacityWidth
    )
    XCTAssertEqual(
      WorkerCrewLayout.contentWidth(
        forDisplayedCrewCount: 2,
        overflowCount: 3,
        capacityRemainingPercent: 9
      ),
      WorkerCrewLayout.taskGroupWidth(for: 2)
        + WorkerCrewLayout.summarySpacing
        + WorkerCrewLayout.summaryWidth(
          overflowCount: 3,
          capacityRemainingPercent: 9
        )
    )
  }

  @MainActor
  func testLaunchAtLoginControllerRegistersAndUnregistersTheMainApp() {
    let service = LaunchAtLoginServiceSpy(status: .notRegistered)
    let controller = LaunchAtLoginController(service: service)

    XCTAssertFalse(controller.isEnabled)

    controller.setEnabled(true)

    XCTAssertEqual(service.registerCallCount, 1)
    XCTAssertTrue(controller.isEnabled)
    XCTAssertNil(controller.errorMessage)

    controller.setEnabled(false)

    XCTAssertEqual(service.unregisterCallCount, 1)
    XCTAssertFalse(controller.isEnabled)
    XCTAssertNil(controller.errorMessage)
  }

  @MainActor
  func testLaunchAtLoginControllerKeepsApprovalRequiredRegistrationVisible() {
    let service = LaunchAtLoginServiceSpy(status: .requiresApproval)
    let controller = LaunchAtLoginController(service: service)

    XCTAssertTrue(controller.isEnabled)
    XCTAssertTrue(controller.requiresApproval)

    controller.openSystemSettings()

    XCTAssertEqual(service.openSystemSettingsCallCount, 1)

    controller.setEnabled(false)

    XCTAssertEqual(service.unregisterCallCount, 1)
    XCTAssertFalse(controller.isEnabled)
    XCTAssertFalse(controller.requiresApproval)
  }

  @MainActor
  func testLaunchAtLoginControllerReportsFailureWithoutInventingEnabledState() {
    let service = LaunchAtLoginServiceSpy(status: .notRegistered)
    service.registerError = LaunchAtLoginTestError.registrationFailed
    let controller = LaunchAtLoginController(service: service)

    controller.setEnabled(true)

    XCTAssertFalse(controller.isEnabled)
    XCTAssertEqual(
      controller.errorMessage,
      "Couldn’t update Launch at Login. Registration failed."
    )
  }

  @MainActor
  func testLaunchAtLoginControllerRefreshesChangesMadeInSystemSettings() {
    let service = LaunchAtLoginServiceSpy(status: .notRegistered)
    let controller = LaunchAtLoginController(service: service)

    service.status = .enabled
    controller.refresh()

    XCTAssertTrue(controller.isEnabled)
    XCTAssertFalse(controller.requiresApproval)
  }

  @MainActor
  func testBundledMainAppTreatsInitialNotFoundStatusAsRegisterable() {
    XCTAssertEqual(
      SystemLaunchAtLoginService.projectedStatus(
        for: SMAppService.Status.notFound,
        isMainApplicationBundle: true
      ),
      .notRegistered
    )
  }

  @MainActor
  func testUnbundledCopyDisablesLaunchAtLogin() {
    XCTAssertEqual(
      SystemLaunchAtLoginService.projectedStatus(
        for: SMAppService.Status.notFound,
        isMainApplicationBundle: false
      ),
      .unavailable
    )
    XCTAssertEqual(
      SystemLaunchAtLoginService.projectedStatus(
        for: SMAppService.Status.notRegistered,
        isMainApplicationBundle: false
      ),
      .unavailable
    )

    let service = LaunchAtLoginServiceSpy(status: .unavailable)
    let controller = LaunchAtLoginController(service: service)

    controller.setEnabled(true)

    XCTAssertFalse(controller.isAvailable)
    XCTAssertEqual(service.registerCallCount, 0)
  }

  @MainActor
  func testLaunchAtLoginRecognizesOnlyTheSupportedMainApplicationBundle() {
    XCTAssertTrue(
      SystemLaunchAtLoginService.isSupportedMainApplicationBundle(
        bundleURL: URL(fileURLWithPath: "/Applications/Codex Echo.app"),
        bundleIdentifier: "app.ohida.codex-echo",
        packageType: "APPL"
      )
    )
    XCTAssertFalse(
      SystemLaunchAtLoginService.isSupportedMainApplicationBundle(
        bundleURL: URL(fileURLWithPath: "/usr/local/bin"),
        bundleIdentifier: nil,
        packageType: nil
      )
    )
    XCTAssertFalse(
      SystemLaunchAtLoginService.isSupportedMainApplicationBundle(
        bundleURL: URL(fileURLWithPath: "/Applications/Other.app"),
        bundleIdentifier: "com.example.other",
        packageType: "APPL"
      )
    )
  }

  @MainActor
  func testSupportedMaximumShowsSixteenTasksBeforeOverflow() {
    let tasks = (1...17).map { index in
      TaskPresentation(
        id: "task-\(index)",
        title: "Task \(index)",
        project: nil,
        state: .working,
        activeSubagentCount: 0,
        updatedAt: nil
      )
    }

    XCTAssertEqual(MenuBarSettings.supportedMaximumVisibleTaskCount, 0...16)
    XCTAssertEqual(
      StatusItemTaskPolicy.statusBarTasks(from: tasks, limit: 16).count,
      16
    )
    XCTAssertEqual(
      WorkerCrewLayout.contentWidth(
        forCrewCount: tasks.count,
        maximumVisibleCrews: 16
      ),
      WorkerCrewLayout.taskGroupWidth(for: 16)
        + WorkerCrewLayout.summarySpacing
        + WorkerCrewLayout.summaryWidth(
          overflowCount: 1,
          capacityRemainingPercent: nil
        )
    )
  }

  @MainActor
  private func withSettings(
    _ body: (MenuBarSettings, UserDefaults) -> Void
  ) {
    withSettingsDefaults { defaults in
      body(MenuBarSettings(userDefaults: defaults), defaults)
    }
  }

  @MainActor
  private func settingsFittingSize(
    settings: MenuBarSettings,
    launchAtLogin: LaunchAtLoginController
  ) -> NSSize {
    let view = NSHostingView(
      rootView: MenuBarSettingsView(
        settings: settings,
        launchAtLogin: launchAtLogin,
        updateController: SparkleAppUpdateController(
          displayVersion: "0.1.1",
          isAvailable: true,
          canCheckForUpdates: true,
          automaticallyChecksForUpdates: true
        ),
        previewSpokenVoice: { _ in },
        openProjectCustomizationSettings: {},
        openSpokenAnnouncementSettings: {}
      )
    )
    view.layoutSubtreeIfNeeded()
    return view.fittingSize
  }

  private func withSettingsDefaults(
    _ body: (UserDefaults) -> Void
  ) {
    let suiteName = "CodexEchoTests.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
      XCTFail("Unable to create isolated user defaults")
      return
    }
    defer { defaults.removePersistentDomain(forName: suiteName) }
    body(defaults)
  }
}

private enum LaunchAtLoginTestError: LocalizedError {
  case registrationFailed

  var errorDescription: String? {
    "Registration failed."
  }
}

@MainActor
private final class LaunchAtLoginServiceSpy: LaunchAtLoginService {
  var status: LaunchAtLoginStatus
  var registerError: Error?
  var unregisterError: Error?
  private(set) var registerCallCount = 0
  private(set) var unregisterCallCount = 0
  private(set) var openSystemSettingsCallCount = 0

  init(status: LaunchAtLoginStatus) {
    self.status = status
  }

  func register() throws {
    registerCallCount += 1
    if let registerError {
      throw registerError
    }
    status = .enabled
  }

  func unregister() throws {
    unregisterCallCount += 1
    if let unregisterError {
      throw unregisterError
    }
    status = .notRegistered
  }

  func openSystemSettings() {
    openSystemSettingsCallCount += 1
  }
}
