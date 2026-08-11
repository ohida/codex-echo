import XCTest

@testable import CodexIPC
@testable import CodexEcho

private enum TestAnnouncementMode: Equatable {
  case off
  case keyEvents
  case allActivity
}

private func testDelivery(
  _ mode: TestAnnouncementMode,
  speaksAtStartup: Bool = false
) -> SpokenAnnouncementDelivery {
  let configuration: SpokenAnnouncementConfiguration
  switch mode {
  case .off:
    configuration = .defaults
  case .keyEvents:
    var keyEvents = SpokenAnnouncementConfiguration.defaults
    keyEvents.setSpeaks(false, for: .directiveQueued)
    for event in SpokenAnnouncementEvent.taskActivityEvents {
      keyEvents.setSpeaks(false, for: event)
    }
    keyEvents.setSpeaks(false, for: .usageChanged)
    configuration = keyEvents
  case .allActivity:
    configuration = .defaults
  }
  var configuredDelivery = configuration
  if !speaksAtStartup {
    configuredDelivery.setSpeaks(false, for: .startupSummary)
  }
  return SpokenAnnouncementDelivery(
    isEnabled: mode != .off,
    configuration: configuredDelivery
  )
}

private extension UsageAnnouncementPolicy {
  static func copy(
    previousRemainingPercent: Int?,
    remainingPercent: Int,
    level: TestAnnouncementMode
  ) -> String? {
    announcement(
      previousRemainingPercent: previousRemainingPercent,
      remainingPercent: remainingPercent,
      delivery: testDelivery(level)
    )?.text
  }

  static func announcement(
    previousRemainingPercent: Int?,
    remainingPercent: Int,
    level: TestAnnouncementMode
  ) -> SpokenUpdateAnnouncement? {
    announcement(
      previousRemainingPercent: previousRemainingPercent,
      remainingPercent: remainingPercent,
      delivery: testDelivery(level)
    )
  }
}

@MainActor
private extension SpokenUpdateAnnouncer {
  func updateLevel(
    _ level: TestAnnouncementMode,
    speaksAtStartup: Bool = false
  ) {
    updateDelivery(
      testDelivery(
        level,
        speaksAtStartup: speaksAtStartup
      )
    )
  }

  func observe(
    tasks: [TaskPresentation],
    level: TestAnnouncementMode
  ) {
    observe(tasks: tasks, delivery: testDelivery(level))
  }

  func observeQueuedFollowUps(
    taskID: String,
    queuedCount: Int,
    voice: SpokenUpdateVoice,
    level: TestAnnouncementMode
  ) {
    observeQueuedFollowUps(
      taskID: taskID,
      queuedCount: queuedCount,
      voice: voice,
      delivery: testDelivery(level)
    )
  }

  func observeUsage(
    remainingPercent: Int?,
    level: TestAnnouncementMode,
    speaksAtStartup: Bool = false
  ) {
    observeUsage(
      remainingPercent: remainingPercent,
      delivery: testDelivery(
        level,
        speaksAtStartup: speaksAtStartup
      )
    )
  }

  func observeDesktopAppState(
    _ state: CodexDesktopAppState,
    level: TestAnnouncementMode
  ) {
    observeDesktopAppState(state, delivery: testDelivery(level))
  }
}

final class SpokenUpdateTests: XCTestCase {
  func testQueuedDirectiveCopyUsesConciseOperationsLanguage() {
    XCTAssertEqual(
      SpokenAnnouncementEvent.directiveQueued.announcementText,
      "Directive queued."
    )
  }

  func testVoiceSelectionCopyConfirmsTheMenuAction() {
    XCTAssertEqual(
      SpokenUpdateCopy.voiceSelected,
      "Voice selected."
    )
  }

  func testEnablingAnnouncementsCopyConfirmsTheSettingChange() {
    XCTAssertEqual(
      SpokenUpdateCopy.announcementsEnabled,
      "Announcements on."
    )
  }

  func testStartupStatusCombinesOnlineStateWithObservedSignals() {
    XCTAssertEqual(
      SpokenUpdateCopy.startupStatus(observedRunningTaskCount: 0),
      "Codex Echo online."
    )
    XCTAssertEqual(
      SpokenUpdateCopy.startupStatus(observedRunningTaskCount: 1),
      "Codex Echo online. One active task signal detected."
    )
    XCTAssertEqual(
      SpokenUpdateCopy.startupStatus(observedRunningTaskCount: 2),
      "Codex Echo online. 2 active task signals detected."
    )
    XCTAssertEqual(
      SpokenUpdateCopy.startupStatus(
        observedRunningTaskCount: 2,
        remainingPercent: 67,
        information: [.activeTasks, .codexCapacity]
      ),
      "Codex Echo online. Codex capacity, 67 percent remaining. "
        + "2 active task signals detected."
    )
    XCTAssertEqual(
      SpokenUpdateCopy.startupStatus(
        observedRunningTaskCount: 2,
        remainingPercent: 67,
        information: [.codexCapacity]
      ),
      "Codex Echo online. Codex capacity, 67 percent remaining."
    )
  }

  func testStartupCapacityUsesTheSameConciseCapacityCopy() {
    XCTAssertEqual(
      SpokenUpdateCopy.startupCapacity(remainingPercent: 67),
      "Codex capacity, 67 percent remaining."
    )
    XCTAssertEqual(
      SpokenUpdateCopy.startupCapacity(remainingPercent: 0),
      "Codex capacity depleted."
    )
  }

  func testMonitoringCopyUsesPairedOperationsLanguage() {
    XCTAssertEqual(
      SpokenAnnouncementEvent.monitoringInterrupted.announcementText,
      "Codex monitoring interrupted."
    )
    XCTAssertEqual(
      SpokenAnnouncementEvent.monitoringRestored.announcementText,
      "Codex monitoring restored."
    )
  }

  func testControlAICopyCoversLiveTaskActivities() {
    let activities: [CodexTaskCurrentActivity] = [
      .working,
      .thinking,
      .planning,
      .runningCommand,
      .editingFiles,
      .coordinatingAgents,
      .checkingPermissions,
      .writingResponse,
      .compactingContext,
    ]
    XCTAssertEqual(
      activities.map(SpokenUpdateCopy.activityStatus),
      [
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
  }

  func testTrackerIdentifiesTaskActivityRepetitionByTypedState() {
    var tracker = SpokenUpdateTracker()
    _ = tracker.updates(
      for: [
        task(
          state: .working,
          currentActivity: .thinking
        )
      ]
    )

    let updates = tracker.updates(
      for: [
        task(
          state: .working,
          currentActivity: .planning
        )
      ]
    )

    XCTAssertEqual(
      updates.first?.repetitionKey,
      .taskActivity(.planning)
    )
  }

  func testTrackerKeepsDiscreteEventsOutOfRepetitionSuppression() {
    var tracker = SpokenUpdateTracker()
    _ = tracker.updates(
      for: [
        task(
          state: .working,
          currentActivity: .thinking
        )
      ]
    )

    let updates = tracker.updates(
      for: [task(state: .needsApproval)]
    )

    XCTAssertEqual(updates.first?.event, .approvalRequired)
    XCTAssertNil(updates.first?.repetitionKey)
  }

  func testDeliveryMasterSwitchSilencesTheConfiguredEvents() {
    XCTAssertFalse(testDelivery(.off).rule(for: .taskCompleted).speaks)
    XCTAssertFalse(testDelivery(.off).rule(for: .taskAnalysis).speaks)
    XCTAssertTrue(testDelivery(.keyEvents).rule(for: .taskCompleted).speaks)
    XCTAssertFalse(testDelivery(.keyEvents).rule(for: .taskAnalysis).speaks)
    XCTAssertTrue(testDelivery(.allActivity).rule(for: .taskCompleted).speaks)
    XCTAssertTrue(testDelivery(.allActivity).rule(for: .taskAnalysis).speaks)
  }

  @MainActor
  func testCustomConfigurationSuppressesOnlyItsDisabledAnnouncement() {
    let speaker = SpokenUpdateSpeakerSpy()
    let announcer = SpokenUpdateAnnouncer(speaker: speaker)
    var configuration = SpokenAnnouncementConfiguration.defaults
    configuration.setSpeaks(false, for: .taskCompleted)
    configuration.setSpeaks(false, for: .startupSummary)
    let delivery = SpokenAnnouncementDelivery(
      isEnabled: true,
      configuration: configuration
    )
    announcer.updateDelivery(delivery)
    announcer.observe(
      tasks: [task(state: .working)],
      delivery: delivery
    )
    announcer.completeHydration(
      SpokenUpdateStartupSnapshot(
        knownTaskIDs: ["task"],
        observedRunningTaskCount: 0
      )
    )

    announcer.observe(
      tasks: [task(state: .ready)],
      delivery: delivery
    )
    announcer.observe(
      tasks: [task(state: .working)],
      delivery: delivery
    )

    XCTAssertEqual(speaker.spokenTexts, ["Task initiated."])
  }

  @MainActor
  func testEventPreviewIgnoresSpeakChoiceButUsesItsAlertSoundChoice() {
    let speaker = SpokenUpdateSpeakerSpy()
    let announcer = SpokenUpdateAnnouncer(speaker: speaker)
    var configuration = SpokenAnnouncementConfiguration.defaults
    configuration.setSpeaks(false, for: .approvalRequired)
    configuration.setAlertSound(.twoPips, for: .approvalRequired)

    announcer.preview(
      .approvalRequired,
      configuration: configuration
    )

    XCTAssertEqual(speaker.stoppedChannels, [.preview])
    XCTAssertEqual(speaker.spokenTexts, ["Approval required."])
    XCTAssertEqual(speaker.spokenChannels, [.preview])
    XCTAssertEqual(speaker.spokenVoices, [.defaultVoice])
    XCTAssertEqual(speaker.spokenCues, [.important])
  }

  @MainActor
  func testResponseGenerationPreviewSpeaksItsOwnExactCopy() {
    let speaker = SpokenUpdateSpeakerSpy()
    let announcer = SpokenUpdateAnnouncer(speaker: speaker)

    announcer.preview(
      .taskResponseGeneration,
      configuration: .defaults
    )

    XCTAssertEqual(speaker.stoppedChannels, [.preview])
    XCTAssertEqual(speaker.spokenTexts, ["Response generation."])
    XCTAssertEqual(speaker.spokenChannels, [.preview])
    XCTAssertEqual(speaker.spokenVoices, [.defaultVoice])
    XCTAssertEqual(speaker.spokenCues, [.none])
  }

  @MainActor
  func testEventPreviewUsesTheConfiguredDefaultVoice() {
    let configuredVoice = SpokenUpdateVoice.reed
    let speaker = SpokenUpdateSpeakerSpy()
    let announcer = SpokenUpdateAnnouncer(
      speaker: speaker,
      defaultVoice: configuredVoice
    )

    announcer.preview(
      .taskCompleted,
      configuration: .defaults
    )

    XCTAssertEqual(speaker.spokenVoices, [configuredVoice])
  }

  @MainActor
  func testStartupPreviewIncludesOnlyItsSelectedInformation() {
    let speaker = SpokenUpdateSpeakerSpy()
    let announcer = SpokenUpdateAnnouncer(speaker: speaker)
    var configuration = SpokenAnnouncementConfiguration.defaults
    configuration.setIncludesStartupInformation(
      false,
      information: .activeTasks
    )

    announcer.preview(
      .startupSummary,
      configuration: configuration
    )

    XCTAssertEqual(
      speaker.spokenTexts,
      [
        "Codex Echo online. "
          + "Codex capacity, 67 percent remaining."
      ]
    )
    XCTAssertEqual(speaker.spokenChannels, [.preview])
    XCTAssertEqual(speaker.spokenCues, [.attention])
  }

  func testAllActivityReportsEveryObservedWholePercentageDecrease() {
    XCTAssertEqual(
      UsageAnnouncementPolicy.copy(
        previousRemainingPercent: 98,
        remainingPercent: 97,
        level: .allActivity
      ),
      "Codex capacity, 97 percent remaining."
    )
    XCTAssertEqual(
      UsageAnnouncementPolicy.copy(
        previousRemainingPercent: 97,
        remainingPercent: 94,
        level: .allActivity
      ),
      "Codex capacity, 94 percent remaining."
    )
    XCTAssertNil(
      UsageAnnouncementPolicy.copy(
        previousRemainingPercent: 94,
        remainingPercent: 94,
        level: .allActivity
      )
    )
  }

  func testKeyEventsReportsOnlyLowUsageThresholdCrossings() {
    XCTAssertEqual(
      UsageAnnouncementPolicy.copy(
        previousRemainingPercent: 21,
        remainingPercent: 20,
        level: .keyEvents
      ),
      "Codex capacity, 20 percent remaining."
    )
    XCTAssertNil(
      UsageAnnouncementPolicy.copy(
        previousRemainingPercent: 20,
        remainingPercent: 19,
        level: .keyEvents
      )
    )
    XCTAssertEqual(
      UsageAnnouncementPolicy.copy(
        previousRemainingPercent: 11,
        remainingPercent: 9,
        level: .keyEvents
      ),
      "Codex capacity, 9 percent remaining."
    )
    XCTAssertEqual(
      UsageAnnouncementPolicy.copy(
        previousRemainingPercent: 2,
        remainingPercent: 1,
        level: .keyEvents
      ),
      "Codex capacity, 1 percent remaining."
    )
    XCTAssertEqual(
      UsageAnnouncementPolicy.copy(
        previousRemainingPercent: 1,
        remainingPercent: 0,
        level: .keyEvents
      ),
      "Codex capacity depleted."
    )
  }

  func testUsageWarningsRequestAttentionRatherThanActionRequiredCue() {
    XCTAssertEqual(
      UsageAnnouncementPolicy.announcement(
        previousRemainingPercent: 6,
        remainingPercent: 5,
        level: .keyEvents
      )?.cue,
      .attention
    )
    XCTAssertEqual(
      UsageAnnouncementPolicy.announcement(
        previousRemainingPercent: 5,
        remainingPercent: 4,
        level: .allActivity
      )?.cue,
      SpokenUpdateCue.none
    )
    XCTAssertEqual(
      UsageAnnouncementPolicy.announcement(
        previousRemainingPercent: 2,
        remainingPercent: 1,
        level: .keyEvents
      )?.cue,
      .attention
    )
    XCTAssertEqual(
      UsageAnnouncementPolicy.announcement(
        previousRemainingPercent: 1,
        remainingPercent: 0,
        level: .keyEvents
      )?.cue,
      .attention
    )
    XCTAssertEqual(
      UsageAnnouncementPolicy.announcement(
        previousRemainingPercent: nil,
        remainingPercent: 3,
        level: .keyEvents
      )?.cue,
      .attention
    )
    XCTAssertEqual(
      UsageAnnouncementPolicy.announcement(
        previousRemainingPercent: 3,
        remainingPercent: 100,
        level: .keyEvents
      )?.cue,
      SpokenUpdateCue.none
    )
  }

  func testUsageIncreaseIsAKeyEventAtEitherEnabledLevel() {
    for level in [TestAnnouncementMode.keyEvents, .allActivity] {
      XCTAssertEqual(
        UsageAnnouncementPolicy.copy(
          previousRemainingPercent: 2,
          remainingPercent: 100,
          level: level
        ),
        "Codex capacity increased to 100 percent."
      )
    }
    XCTAssertNil(
      UsageAnnouncementPolicy.copy(
        previousRemainingPercent: 2,
        remainingPercent: 100,
        level: .off
      )
    )
  }

  func testHydrationWaitsForLiveConnectionAndCatalogResponse() {
    let snapshot = CodexTaskCatalogSnapshot(
      taskIDs: ["one", "two", "input", "ready"]
    )
    XCTAssertNil(
      SpokenUpdateHydration(
        catalogSnapshot: nil,
        observedRunningTaskCount: 2,
        connectionHealth: .live
      ).readySnapshot
    )
    XCTAssertNil(
      SpokenUpdateHydration(
        catalogSnapshot: snapshot,
        observedRunningTaskCount: 2,
        connectionHealth: .connecting
      ).readySnapshot
    )
    XCTAssertEqual(
      SpokenUpdateHydration(
        catalogSnapshot: snapshot,
        observedRunningTaskCount: 2,
        connectionHealth: .live
      ).readySnapshot,
      SpokenUpdateStartupSnapshot(
        knownTaskIDs: snapshot.taskIDs,
        observedRunningTaskCount: 2
      )
    )
  }

  func testEmptyTaskListDoesNotProveStartupHydrationCompleted() {
    XCTAssertNil(
      SpokenUpdateHydration(
        catalogSnapshot: nil,
        observedRunningTaskCount: 0,
        connectionHealth: .live
      ).readySnapshot
    )
    XCTAssertEqual(
      SpokenUpdateHydration(
        catalogSnapshot: CodexTaskCatalogSnapshot(
          taskIDs: []
        ),
        observedRunningTaskCount: 0,
        connectionHealth: .live
      ).readySnapshot?.observedRunningTaskCount,
      0
    )
  }

  func testMonitoringAvailabilityRequiresARunningDesktopAndLiveConnections() {
    XCTAssertEqual(
      CodexMonitoringAvailability.resolve(
        desktopAppState: .notRunning,
        connectionHealth: .live
      ),
      .inactive
    )
    XCTAssertEqual(
      CodexMonitoringAvailability.resolve(
        desktopAppState: .running,
        connectionHealth: .live
      ),
      .available
    )
    for health in [
      CodexConnectionHealth.connecting,
      .degraded(.taskCatalogUnavailable),
      .degraded(.liveActivityUnavailable),
      .incompatible,
      .offline,
    ] {
      XCTAssertEqual(
        CodexMonitoringAvailability.resolve(
          desktopAppState: .running,
          connectionHealth: health
        ),
        .unavailable
      )
    }
  }

  func testOnlyMonitoringInterruptionUsesTheTransientFailureDelay() {
    XCTAssertEqual(CodexMonitoringAvailability.inactive.announcementDelay, 0)
    XCTAssertEqual(CodexMonitoringAvailability.available.announcementDelay, 0)
    XCTAssertEqual(CodexMonitoringAvailability.unavailable.announcementDelay, 10)
  }

  func testInitialTasksDoNotProduceSpokenUpdates() {
    var tracker = SpokenUpdateTracker()

    XCTAssertEqual(
      tracker.updates(
        for: [
          task(state: .ready),
          task(id: "input", state: .needsInput),
          task(id: "agent", state: .working, activeSubagentCount: 1),
        ]
      ),
      []
    )
  }

  func testReportsMeaningfulStateTransitionsOnce() {
    var tracker = SpokenUpdateTracker()
    _ = tracker.updates(
      for: [
        task(id: "complete", state: .working),
        task(id: "input", state: .working),
        task(id: "approval", state: .working),
        task(id: "blocked", state: .working),
      ]
    )

    XCTAssertEqual(
      tracker.updates(
        for: [
          task(id: "complete", state: .ready),
          task(id: "input", state: .needsInput),
          task(id: "approval", state: .needsApproval),
          task(id: "blocked", state: .blocked),
        ]
      ),
      [
        SpokenUpdate(
          taskID: "complete",
          event: .taskCompleted,
          text: "Task complete."
        ),
        SpokenUpdate(
          taskID: "input",
          event: .inputRequired,
          text: "Input required."
        ),
        SpokenUpdate(
          taskID: "approval",
          event: .approvalRequired,
          text: "Approval required."
        ),
        SpokenUpdate(
          taskID: "blocked",
          event: .taskError,
          text: "Task error."
        ),
      ]
    )

    XCTAssertEqual(
      tracker.updates(
        for: [
          task(id: "complete", state: .ready),
          task(id: "input", state: .needsInput),
          task(id: "approval", state: .needsApproval),
          task(id: "blocked", state: .blocked),
        ]
      ),
      []
    )
  }

  @MainActor
  func testAnnouncerDispatchesSimultaneousTaskUpdatesIndependently() {
    let speaker = SpokenUpdateSpeakerSpy()
    let announcer = SpokenUpdateAnnouncer(speaker: speaker)
    announcer.updateLevel(.keyEvents, speaksAtStartup: true)
    announcer.observe(
      tasks: [
        task(id: "one", state: .working),
        task(id: "two", state: .working),
      ],
      level: .keyEvents
    )
    announcer.completeHydration(
      SpokenUpdateStartupSnapshot(
        knownTaskIDs: ["one", "two"],
        observedRunningTaskCount: 2
      )
    )

    announcer.observe(
      tasks: [
        task(id: "one", state: .ready),
        task(id: "two", state: .needsInput),
      ],
      level: .keyEvents
    )

    XCTAssertEqual(
      speaker.spokenTexts,
      [
        "Codex Echo online.",
        "Task complete.",
        "Input required.",
      ]
    )
    XCTAssertEqual(
      speaker.spokenChannels,
      [
        .startup,
        .task("one"),
        .task("two"),
      ]
    )
    XCTAssertEqual(speaker.spokenCues, [.attention, .attention, .important])
  }

  @MainActor
  func testAllActivityAnnouncesInitialUsageAfterHydrationAndFutureChanges() {
    let speaker = SpokenUpdateSpeakerSpy()
    let announcer = SpokenUpdateAnnouncer(speaker: speaker)
    announcer.updateLevel(.allActivity, speaksAtStartup: true)

    announcer.observeUsage(remainingPercent: 2, level: .allActivity)
    XCTAssertEqual(speaker.spokenTexts, [])

    announcer.completeHydration(
      SpokenUpdateStartupSnapshot(
        knownTaskIDs: [],
        observedRunningTaskCount: 0
      )
    )
    announcer.observeUsage(remainingPercent: 1, level: .allActivity)
    announcer.observeUsage(remainingPercent: 0, level: .allActivity)

    XCTAssertEqual(
      speaker.spokenTexts,
      [
        "Codex Echo online. Codex capacity, 2 percent remaining.",
        "Codex capacity, 1 percent remaining.",
        "Codex capacity depleted.",
      ]
    )
    XCTAssertEqual(speaker.spokenChannels, [.startup, .system, .system])
    XCTAssertEqual(speaker.spokenVoices, [.defaultVoice, .defaultVoice, .defaultVoice])
    XCTAssertEqual(speaker.spokenCues, [.attention, .attention, .attention])
  }

  @MainActor
  func testStartupCapacityInformationCanBeDisabledWithoutDisablingFutureUsageChanges() {
    let speaker = SpokenUpdateSpeakerSpy()
    let announcer = SpokenUpdateAnnouncer(speaker: speaker)
    var configuration = SpokenAnnouncementConfiguration.defaults
    configuration.setIncludesStartupInformation(
      false,
      information: .codexCapacity
    )
    let delivery = SpokenAnnouncementDelivery(
      isEnabled: true,
      configuration: configuration
    )
    announcer.updateDelivery(delivery)

    announcer.observeUsage(remainingPercent: 67, delivery: delivery)
    announcer.completeHydration(
      SpokenUpdateStartupSnapshot(
        knownTaskIDs: [],
        observedRunningTaskCount: 2
      )
    )
    announcer.observeUsage(remainingPercent: 66, delivery: delivery)

    XCTAssertEqual(
      speaker.spokenTexts,
      [
        "Codex Echo online. 2 active task signals detected.",
        "Codex capacity, 66 percent remaining.",
      ]
    )
    XCTAssertEqual(speaker.spokenChannels, [.startup, .system])
  }

  @MainActor
  func testDisablingStartupAnnouncementSuppressesItsSelectedInformation() {
    let speaker = SpokenUpdateSpeakerSpy()
    let announcer = SpokenUpdateAnnouncer(speaker: speaker)
    var configuration = SpokenAnnouncementConfiguration.defaults
    configuration.setSpeaks(false, for: .startupSummary)
    let delivery = SpokenAnnouncementDelivery(
      isEnabled: true,
      configuration: configuration
    )
    announcer.updateDelivery(delivery)
    announcer.observeUsage(remainingPercent: 67, delivery: delivery)

    announcer.completeHydration(
      SpokenUpdateStartupSnapshot(
        knownTaskIDs: [],
        observedRunningTaskCount: 2
      )
    )
    announcer.observeUsage(remainingPercent: 66, delivery: delivery)

    XCTAssertEqual(
      speaker.spokenTexts,
      ["Codex capacity, 66 percent remaining."]
    )
    XCTAssertEqual(speaker.spokenChannels, [.system])
  }

  @MainActor
  func testStartupCanIncludeCapacityWithoutActiveTaskCount() {
    let speaker = SpokenUpdateSpeakerSpy()
    let announcer = SpokenUpdateAnnouncer(speaker: speaker)
    var configuration = SpokenAnnouncementConfiguration.defaults
    configuration.setIncludesStartupInformation(
      false,
      information: .activeTasks
    )
    let delivery = SpokenAnnouncementDelivery(
      isEnabled: true,
      configuration: configuration
    )
    announcer.updateDelivery(delivery)
    announcer.observeUsage(remainingPercent: 67, delivery: delivery)

    announcer.completeHydration(
      SpokenUpdateStartupSnapshot(
        knownTaskIDs: [],
        observedRunningTaskCount: 2
      )
    )

    XCTAssertEqual(
      speaker.spokenTexts,
      ["Codex Echo online. Codex capacity, 67 percent remaining."]
    )
    XCTAssertEqual(speaker.spokenChannels, [.startup])
  }

  @MainActor
  func testStartupCombinesAvailableInformationIntoOneAnnouncement() {
    let speaker = SpokenUpdateSpeakerSpy()
    let announcer = SpokenUpdateAnnouncer(speaker: speaker)
    announcer.updateLevel(.allActivity, speaksAtStartup: true)
    announcer.observeUsage(remainingPercent: 67, level: .allActivity)

    announcer.completeHydration(
      SpokenUpdateStartupSnapshot(
        knownTaskIDs: [],
        observedRunningTaskCount: 2
      )
    )

    XCTAssertEqual(
      speaker.spokenTexts,
      [
        "Codex Echo online. Codex capacity, 67 percent remaining. "
          + "2 active task signals detected."
      ]
    )
    XCTAssertEqual(speaker.spokenChannels, [.startup])
  }

  @MainActor
  func testLateInitialCapacityPrecedesTheDeferredRunningTaskCount() {
    let speaker = SpokenUpdateSpeakerSpy()
    let announcer = SpokenUpdateAnnouncer(speaker: speaker)
    announcer.updateLevel(.allActivity, speaksAtStartup: true)

    announcer.completeHydration(
      SpokenUpdateStartupSnapshot(
        knownTaskIDs: [],
        observedRunningTaskCount: 2
      )
    )
    announcer.observeUsage(
      remainingPercent: 67,
      level: .allActivity,
      speaksAtStartup: true
    )

    XCTAssertEqual(
      speaker.spokenTexts,
      [
        "Codex Echo online.",
        "Codex capacity, 67 percent remaining. "
          + "2 active task signals detected.",
      ]
    )
    XCTAssertEqual(speaker.spokenChannels, [.startup, .startup])
    XCTAssertEqual(speaker.spokenCues, [.attention, .none])
  }

  @MainActor
  func testDeferredStartupInformationHonorsInformationDisabledBeforeCapacityArrives() {
    let speaker = SpokenUpdateSpeakerSpy()
    let announcer = SpokenUpdateAnnouncer(speaker: speaker)
    var configuration = SpokenAnnouncementConfiguration.defaults
    let initialDelivery = SpokenAnnouncementDelivery(
      isEnabled: true,
      configuration: configuration
    )
    announcer.updateDelivery(initialDelivery)
    announcer.completeHydration(
      SpokenUpdateStartupSnapshot(
        knownTaskIDs: [],
        observedRunningTaskCount: 2
      )
    )

    configuration.setIncludesStartupInformation(
      false,
      information: .activeTasks
    )
    let updatedDelivery = SpokenAnnouncementDelivery(
      isEnabled: true,
      configuration: configuration
    )
    announcer.updateDelivery(updatedDelivery)
    announcer.observeUsage(
      remainingPercent: 67,
      delivery: updatedDelivery
    )

    XCTAssertEqual(
      speaker.spokenTexts,
      [
        "Codex Echo online.",
        "Codex capacity, 67 percent remaining.",
      ]
    )
    XCTAssertEqual(speaker.spokenChannels, [.startup, .startup])
  }

  @MainActor
  func testDeferredStartupInformationDoesNotAddInformationEnabledAfterHydration() {
    let speaker = SpokenUpdateSpeakerSpy()
    let announcer = SpokenUpdateAnnouncer(speaker: speaker)
    var configuration = SpokenAnnouncementConfiguration.defaults
    configuration.setIncludesStartupInformation(
      false,
      information: .activeTasks
    )
    let initialDelivery = SpokenAnnouncementDelivery(
      isEnabled: true,
      configuration: configuration
    )
    announcer.updateDelivery(initialDelivery)
    announcer.completeHydration(
      SpokenUpdateStartupSnapshot(
        knownTaskIDs: [],
        observedRunningTaskCount: 2
      )
    )

    configuration.setIncludesStartupInformation(
      true,
      information: .activeTasks
    )
    let updatedDelivery = SpokenAnnouncementDelivery(
      isEnabled: true,
      configuration: configuration
    )
    announcer.updateDelivery(updatedDelivery)
    announcer.observeUsage(
      remainingPercent: 67,
      delivery: updatedDelivery
    )

    XCTAssertEqual(
      speaker.spokenTexts,
      [
        "Codex Echo online.",
        "Codex capacity, 67 percent remaining.",
      ]
    )
    XCTAssertEqual(speaker.spokenChannels, [.startup, .startup])
  }

  @MainActor
  func testDeferredStartupInformationWaitsForFreshHydrationAfterDisconnect() {
    let speaker = SpokenUpdateSpeakerSpy()
    let announcer = SpokenUpdateAnnouncer(speaker: speaker)
    let delivery = SpokenAnnouncementDelivery(
      isEnabled: true,
      configuration: .defaults
    )
    announcer.updateDelivery(delivery)
    announcer.completeHydration(
      SpokenUpdateStartupSnapshot(
        knownTaskIDs: [],
        observedRunningTaskCount: 2
      )
    )

    announcer.observeIPCConnectionState(.disconnected)
    announcer.observeUsage(
      remainingPercent: 67,
      delivery: delivery
    )
    announcer.observeIPCConnectionState(.connected)
    announcer.completeHydration(
      SpokenUpdateStartupSnapshot(
        knownTaskIDs: [],
        observedRunningTaskCount: 1
      )
    )

    XCTAssertEqual(
      speaker.spokenTexts,
      [
        "Codex Echo online.",
        "Codex capacity, 67 percent remaining. "
          + "One active task signal detected.",
      ]
    )
    XCTAssertEqual(speaker.spokenChannels, [.startup, .startup])
    XCTAssertEqual(speaker.spokenCues, [.attention, .none])
  }

  @MainActor
  func testEnablingStartupAfterHydrationDoesNotReplayTheStartupAnnouncement() {
    let speaker = SpokenUpdateSpeakerSpy()
    let announcer = SpokenUpdateAnnouncer(speaker: speaker)
    var configuration = SpokenAnnouncementConfiguration.defaults
    configuration.setSpeaks(false, for: .startupSummary)
    let disabledStartupDelivery = SpokenAnnouncementDelivery(
      isEnabled: true,
      configuration: configuration
    )
    announcer.updateDelivery(disabledStartupDelivery)
    announcer.completeHydration(
      SpokenUpdateStartupSnapshot(
        knownTaskIDs: [],
        observedRunningTaskCount: 2
      )
    )

    configuration.setSpeaks(true, for: .startupSummary)
    let enabledStartupDelivery = SpokenAnnouncementDelivery(
      isEnabled: true,
      configuration: configuration
    )
    announcer.updateDelivery(enabledStartupDelivery)
    announcer.observeUsage(
      remainingPercent: 67,
      delivery: enabledStartupDelivery
    )

    XCTAssertEqual(speaker.spokenTexts, [])
    XCTAssertEqual(speaker.spokenCues, [])
  }

  @MainActor
  func testEnablingStartupCapacityAfterHydrationDoesNotAmendPastStartup() {
    let speaker = SpokenUpdateSpeakerSpy()
    let announcer = SpokenUpdateAnnouncer(speaker: speaker)
    var configuration = SpokenAnnouncementConfiguration.defaults
    configuration.setIncludesStartupInformation(
      false,
      information: .codexCapacity
    )
    let capacityDisabledDelivery = SpokenAnnouncementDelivery(
      isEnabled: true,
      configuration: configuration
    )
    announcer.updateDelivery(capacityDisabledDelivery)
    announcer.completeHydration(
      SpokenUpdateStartupSnapshot(
        knownTaskIDs: [],
        observedRunningTaskCount: 0
      )
    )

    configuration.setIncludesStartupInformation(
      true,
      information: .codexCapacity
    )
    let capacityEnabledDelivery = SpokenAnnouncementDelivery(
      isEnabled: true,
      configuration: configuration
    )
    announcer.updateDelivery(capacityEnabledDelivery)
    announcer.observeUsage(
      remainingPercent: 67,
      delivery: capacityEnabledDelivery
    )

    XCTAssertEqual(speaker.spokenTexts, ["Codex Echo online."])
    XCTAssertEqual(speaker.spokenCues, [.attention])
  }

  @MainActor
  func testPendingStartupCapacityDoesNotReviveAfterItIsDisabled() {
    let speaker = SpokenUpdateSpeakerSpy()
    let announcer = SpokenUpdateAnnouncer(speaker: speaker)
    var configuration = SpokenAnnouncementConfiguration.defaults
    let enabledDelivery = SpokenAnnouncementDelivery(
      isEnabled: true,
      configuration: configuration
    )
    announcer.updateDelivery(enabledDelivery)
    announcer.completeHydration(
      SpokenUpdateStartupSnapshot(
        knownTaskIDs: [],
        observedRunningTaskCount: 0
      )
    )

    configuration.setIncludesStartupInformation(
      false,
      information: .codexCapacity
    )
    announcer.updateDelivery(
      SpokenAnnouncementDelivery(
        isEnabled: true,
        configuration: configuration
      )
    )
    configuration.setIncludesStartupInformation(
      true,
      information: .codexCapacity
    )
    let reenabledDelivery = SpokenAnnouncementDelivery(
      isEnabled: true,
      configuration: configuration
    )
    announcer.updateDelivery(reenabledDelivery)
    announcer.observeUsage(
      remainingPercent: 67,
      delivery: reenabledDelivery
    )

    XCTAssertEqual(speaker.spokenTexts, ["Codex Echo online."])
    XCTAssertEqual(speaker.spokenCues, [.attention])
  }

  @MainActor
  func testPreviewUsesTheTaskCompletePhrase() {
    let speaker = SpokenUpdateSpeakerSpy()
    let announcer = SpokenUpdateAnnouncer(speaker: speaker)

    announcer.preview()

    XCTAssertEqual(speaker.spokenTexts, ["Task complete."])
    XCTAssertEqual(speaker.spokenChannels, [.preview])
    XCTAssertEqual(speaker.spokenVoices, [.defaultVoice])
  }

  @MainActor
  func testVoicePreviewUsesTheSelectedVoice() {
    let speaker = SpokenUpdateSpeakerSpy()
    let announcer = SpokenUpdateAnnouncer(speaker: speaker)

    announcer.preview(voice: .rocko)

    XCTAssertEqual(speaker.spokenTexts, ["Voice selected."])
    XCTAssertEqual(speaker.spokenChannels, [.preview])
    XCTAssertEqual(speaker.spokenVoices, [.rocko])
  }

  @MainActor
  func testVoicePreviewReplacesOnlyThePreviousPreviewChannel() {
    let speaker = SpokenUpdateSpeakerSpy()
    let announcer = SpokenUpdateAnnouncer(speaker: speaker)

    announcer.preview(voice: .rocko)
    announcer.preview(voice: .reed)

    XCTAssertEqual(
      speaker.spokenChannels,
      [.preview, .preview]
    )
    XCTAssertEqual(speaker.stoppedChannels, [.preview, .preview])
    XCTAssertEqual(
      speaker.spokenVoices,
      [.rocko, .reed]
    )
    XCTAssertEqual(
      speaker.spokenTexts,
      [
        "Voice selected.",
        "Voice selected.",
      ]
    )
  }

  @MainActor
  func testEditingConfigurationKeepsCurrentAudioAndStartupStatus() {
    let speaker = SpokenUpdateSpeakerSpy()
    let announcer = SpokenUpdateAnnouncer(speaker: speaker)
    let initialDelivery = SpokenAnnouncementDelivery(
      isEnabled: true,
      configuration: .defaults
    )
    var editedConfiguration = SpokenAnnouncementConfiguration.defaults
    editedConfiguration.setAlertSound(.twoPips, for: .usageTwentyPercent)

    announcer.updateDelivery(initialDelivery)
    announcer.updateDelivery(
      SpokenAnnouncementDelivery(
        isEnabled: true,
        configuration: editedConfiguration
      )
    )
    announcer.completeHydration(
      SpokenUpdateStartupSnapshot(
        knownTaskIDs: [],
        observedRunningTaskCount: 1
      )
    )

    XCTAssertEqual(speaker.stopAllCallCount, 0)
    XCTAssertEqual(
      speaker.spokenTexts,
      ["Codex Echo online."]
    )
  }

  @MainActor
  func testTurningOffTheMasterSwitchStopsCurrentAndQueuedAudio() {
    let speaker = SpokenUpdateSpeakerSpy()
    let announcer = SpokenUpdateAnnouncer(speaker: speaker)

    announcer.updateDelivery(
      SpokenAnnouncementDelivery(
        isEnabled: true,
        configuration: .defaults
      )
    )
    announcer.updateDelivery(
      SpokenAnnouncementDelivery(
        isEnabled: false,
        configuration: .defaults
      )
    )

    XCTAssertEqual(speaker.stopAllCallCount, 1)
    XCTAssertEqual(speaker.spokenTexts, [])
  }

  @MainActor
  func testTurningOnTheMasterSwitchConfirmsTheSettingChange() {
    let speaker = SpokenUpdateSpeakerSpy()
    let announcer = SpokenUpdateAnnouncer(speaker: speaker)

    announcer.updateDelivery(
      SpokenAnnouncementDelivery(
        isEnabled: false,
        configuration: .defaults
      )
    )
    announcer.updateDelivery(
      SpokenAnnouncementDelivery(
        isEnabled: true,
        configuration: .defaults
      )
    )

    XCTAssertEqual(
      speaker.spokenTexts,
      ["Announcements on."]
    )
    XCTAssertEqual(speaker.spokenChannels, [.system])
    XCTAssertEqual(speaker.spokenVoices, [.defaultVoice])
    XCTAssertEqual(speaker.spokenCues, [.none])
  }

  @MainActor
  func testInitiallyEnabledAnnouncementsDoNotSpeakASettingConfirmation() {
    let speaker = SpokenUpdateSpeakerSpy()
    let announcer = SpokenUpdateAnnouncer(speaker: speaker)

    announcer.updateDelivery(
      SpokenAnnouncementDelivery(
        isEnabled: true,
        configuration: .defaults
      )
    )

    XCTAssertEqual(speaker.spokenTexts, [])
  }

  @MainActor
  func testAnnouncerReportsOnlyAStoppedRunningCodexApplication() {
    let speaker = SpokenUpdateSpeakerSpy()
    let announcer = SpokenUpdateAnnouncer(speaker: speaker)

    announcer.observeDesktopAppState(.notRunning, level: .keyEvents)
    announcer.observeDesktopAppState(.running, level: .keyEvents)
    announcer.observeDesktopAppState(.running, level: .keyEvents)

    XCTAssertEqual(speaker.spokenTexts, [])

    announcer.observeDesktopAppState(.notRunning, level: .keyEvents)
    announcer.observeDesktopAppState(.notRunning, level: .keyEvents)

    XCTAssertEqual(
      speaker.spokenTexts,
      ["Codex application offline."]
    )
    XCTAssertEqual(speaker.spokenChannels, [.system])
    XCTAssertEqual(speaker.spokenCues, [.attention])
  }

  @MainActor
  func testDisabledDesktopAppTransitionIsNotReplayedWhenEnabled() {
    let speaker = SpokenUpdateSpeakerSpy()
    let announcer = SpokenUpdateAnnouncer(speaker: speaker)

    announcer.observeDesktopAppState(.running, level: .off)
    announcer.observeDesktopAppState(.notRunning, level: .off)
    announcer.observeDesktopAppState(.notRunning, level: .keyEvents)

    XCTAssertEqual(speaker.spokenTexts, [])
  }

  @MainActor
  func testCodexApplicationRecoveryWaitsForFreshHydration() {
    let speaker = SpokenUpdateSpeakerSpy()
    let announcer = SpokenUpdateAnnouncer(speaker: speaker)
    announcer.updateLevel(.keyEvents)

    announcer.observeDesktopAppState(.notRunning, level: .keyEvents)
    announcer.observeDesktopAppState(.running, level: .keyEvents)
    announcer.completeHydration(
      SpokenUpdateStartupSnapshot(
        knownTaskIDs: [],
        observedRunningTaskCount: 0
      )
    )

    announcer.observeDesktopAppState(.notRunning, level: .keyEvents)
    announcer.observeIPCConnectionState(.disconnected)
    announcer.observeDesktopAppState(.running, level: .keyEvents)

    XCTAssertEqual(
      speaker.spokenTexts,
      ["Codex application offline."]
    )

    announcer.completeHydration(
      SpokenUpdateStartupSnapshot(
        knownTaskIDs: [],
        observedRunningTaskCount: 0
      )
    )
    announcer.completeHydration(
      SpokenUpdateStartupSnapshot(
        knownTaskIDs: [],
        observedRunningTaskCount: 0
      )
    )

    XCTAssertEqual(
      speaker.spokenTexts,
      [
        "Codex application offline.",
        "Codex application online.",
      ]
    )
    XCTAssertEqual(speaker.spokenChannels, [.system, .system])
    XCTAssertEqual(speaker.spokenCues, [.attention, .attention])
  }

  @MainActor
  func testDisabledCodexApplicationRecoveryIsNotReplayedWhenEnabled() {
    let speaker = SpokenUpdateSpeakerSpy()
    let announcer = SpokenUpdateAnnouncer(speaker: speaker)
    announcer.updateLevel(.keyEvents)
    announcer.observeDesktopAppState(.running, level: .keyEvents)
    announcer.completeHydration(
      SpokenUpdateStartupSnapshot(
        knownTaskIDs: [],
        observedRunningTaskCount: 0
      )
    )

    announcer.observeDesktopAppState(.notRunning, level: .keyEvents)
    announcer.observeIPCConnectionState(.disconnected)
    announcer.observeDesktopAppState(.running, level: .off)
    announcer.updateLevel(.keyEvents)
    announcer.completeHydration(
      SpokenUpdateStartupSnapshot(
        knownTaskIDs: [],
        observedRunningTaskCount: 0
      )
    )

    XCTAssertEqual(
      speaker.spokenTexts,
      ["Codex application offline."]
    )
  }

  @MainActor
  func testMonitoringInterruptionAndRestorationArePaired() {
    let speaker = SpokenUpdateSpeakerSpy()
    let announcer = SpokenUpdateAnnouncer(speaker: speaker)
    announcer.updateLevel(.keyEvents)
    announcer.completeHydration(
      SpokenUpdateStartupSnapshot(
        knownTaskIDs: [],
        observedRunningTaskCount: 0
      )
    )

    announcer.observeMonitoringAvailability(.unavailable)
    announcer.observeMonitoringAvailability(.unavailable)
    announcer.observeMonitoringAvailability(.available)
    announcer.observeMonitoringAvailability(.available)

    XCTAssertEqual(
      speaker.spokenTexts,
      [
        "Codex monitoring interrupted.",
        "Codex monitoring restored.",
      ]
    )
    XCTAssertEqual(speaker.spokenChannels, [.system, .system])
    XCTAssertEqual(speaker.spokenCues, [.attention, .none])
  }

  @MainActor
  func testMonitoringRestorationWaitsForIPCHydration() {
    let speaker = SpokenUpdateSpeakerSpy()
    let announcer = SpokenUpdateAnnouncer(speaker: speaker)
    announcer.updateLevel(.keyEvents)
    announcer.completeHydration(
      SpokenUpdateStartupSnapshot(
        knownTaskIDs: ["task"],
        observedRunningTaskCount: 0
      )
    )

    announcer.observeIPCConnectionState(.disconnected)
    announcer.observeMonitoringAvailability(.unavailable)
    announcer.observeMonitoringAvailability(.available)
    XCTAssertEqual(
      speaker.spokenTexts,
      ["Codex monitoring interrupted."]
    )

    announcer.completeHydration(
      SpokenUpdateStartupSnapshot(
        knownTaskIDs: ["task"],
        observedRunningTaskCount: 0
      )
    )
    XCTAssertEqual(
      speaker.spokenTexts,
      [
        "Codex monitoring interrupted.",
        "Codex monitoring restored.",
      ]
    )
  }

  @MainActor
  func testMonitoringObservedBeforeInitialHydrationIsNotReplayed() {
    let speaker = SpokenUpdateSpeakerSpy()
    let announcer = SpokenUpdateAnnouncer(speaker: speaker)
    announcer.updateLevel(.keyEvents)

    announcer.observeMonitoringAvailability(.unavailable)
    announcer.completeHydration(
      SpokenUpdateStartupSnapshot(
        knownTaskIDs: [],
        observedRunningTaskCount: 0
      )
    )
    announcer.observeMonitoringAvailability(.available)

    XCTAssertEqual(speaker.spokenTexts, [])
  }

  @MainActor
  func testAnnouncerReportsOnlyQueuedDirectiveCountIncreases() {
    let speaker = SpokenUpdateSpeakerSpy()
    let announcer = SpokenUpdateAnnouncer(speaker: speaker)
    announcer.updateLevel(.allActivity)
    announcer.completeHydration(
      SpokenUpdateStartupSnapshot(
        knownTaskIDs: ["task"],
        observedRunningTaskCount: 0
      )
    )

    announcer.observeQueuedFollowUps(
      taskID: "task",
      queuedCount: 1,
      voice: .rocko,
      level: .allActivity
    )
    announcer.observeQueuedFollowUps(
      taskID: "task",
      queuedCount: 1,
      voice: .rocko,
      level: .allActivity
    )
    announcer.observeQueuedFollowUps(
      taskID: "task",
      queuedCount: 0,
      voice: .rocko,
      level: .allActivity
    )
    announcer.observeQueuedFollowUps(
      taskID: "task",
      queuedCount: 1,
      voice: .rocko,
      level: .allActivity
    )

    XCTAssertEqual(
      speaker.spokenTexts,
      ["Directive queued.", "Directive queued."]
    )
    XCTAssertEqual(
      speaker.spokenChannels,
      [.task("task"), .task("task")]
    )
    XCTAssertEqual(speaker.spokenVoices, [.rocko, .rocko])
  }

  @MainActor
  func testKeyEventsKeepsQueuedDirectivesSilent() {
    let speaker = SpokenUpdateSpeakerSpy()
    let announcer = SpokenUpdateAnnouncer(speaker: speaker)
    announcer.updateLevel(.keyEvents)
    announcer.completeHydration(
      SpokenUpdateStartupSnapshot(
        knownTaskIDs: ["task"],
        observedRunningTaskCount: 0
      )
    )

    announcer.observeQueuedFollowUps(
      taskID: "task",
      queuedCount: 1,
      voice: .rocko,
      level: .keyEvents
    )

    XCTAssertEqual(speaker.spokenTexts, [])
  }

  @MainActor
  func testQueuedDirectiveObservedDuringHydrationIsNotReplayed() {
    let speaker = SpokenUpdateSpeakerSpy()
    let announcer = SpokenUpdateAnnouncer(speaker: speaker)
    announcer.updateLevel(.allActivity)

    announcer.observeQueuedFollowUps(
      taskID: "task",
      queuedCount: 1,
      voice: .rocko,
      level: .allActivity
    )
    announcer.completeHydration(
      SpokenUpdateStartupSnapshot(
        knownTaskIDs: ["task"],
        observedRunningTaskCount: 0
      )
    )
    announcer.observeQueuedFollowUps(
      taskID: "task",
      queuedCount: 1,
      voice: .rocko,
      level: .allActivity
    )
    announcer.observeQueuedFollowUps(
      taskID: "task",
      queuedCount: 2,
      voice: .rocko,
      level: .allActivity
    )

    XCTAssertEqual(speaker.spokenTexts, ["Directive queued."])
  }

  @MainActor
  func testDesktopProcessBoundaryResetsQueuedDirectiveCounts() {
    let speaker = SpokenUpdateSpeakerSpy()
    let announcer = SpokenUpdateAnnouncer(speaker: speaker)
    announcer.updateLevel(.allActivity)
    announcer.completeHydration(
      SpokenUpdateStartupSnapshot(
        knownTaskIDs: ["task"],
        observedRunningTaskCount: 0
      )
    )
    announcer.observeDesktopAppState(.running, level: .allActivity)
    announcer.observeQueuedFollowUps(
      taskID: "task",
      queuedCount: 1,
      voice: .rocko,
      level: .allActivity
    )

    announcer.observeDesktopAppState(.notRunning, level: .allActivity)
    announcer.observeDesktopAppState(.running, level: .allActivity)
    announcer.observeQueuedFollowUps(
      taskID: "task",
      queuedCount: 1,
      voice: .rocko,
      level: .allActivity
    )

    XCTAssertEqual(
      speaker.spokenTexts,
      [
        "Directive queued.",
        "Codex application offline.",
        "Directive queued.",
      ]
    )
  }

  @MainActor
  func testAnnouncerSuppressesBootstrapTransitionsUntilStartupSituation() {
    let speaker = SpokenUpdateSpeakerSpy()
    let announcer = SpokenUpdateAnnouncer(speaker: speaker)
    announcer.updateLevel(.allActivity, speaksAtStartup: true)

    announcer.observe(
      tasks: [
        task(
          state: .working,
          currentActivity: .thinking
        )
      ],
      level: .allActivity
    )
    announcer.observe(
      tasks: [
        task(
          state: .working,
          currentActivity: .runningCommand
        )
      ],
      level: .allActivity
    )

    XCTAssertEqual(speaker.spokenTexts, [])

    announcer.completeHydration(
      SpokenUpdateStartupSnapshot(
        knownTaskIDs: ["task"],
        observedRunningTaskCount: 1
      )
    )
    announcer.observe(
      tasks: [
        task(
          state: .working,
          currentActivity: .planning
        )
      ],
      level: .allActivity
    )

    XCTAssertEqual(
      speaker.spokenTexts,
      [
        "Codex Echo online.",
        "Planning.",
      ]
    )
  }

  @MainActor
  func testRepeatedTaskActivitiesUseAPerTaskFiveSecondCooldown() {
    var uptime: TimeInterval = 1_000
    let speaker = SpokenUpdateSpeakerSpy()
    let announcer = SpokenUpdateAnnouncer(
      speaker: speaker,
      uptime: { uptime }
    )
    announcer.updateLevel(.allActivity)
    announcer.observe(
      tasks: [
        task(
          state: .working,
          currentActivity: .thinking
        )
      ],
      level: .allActivity
    )
    announcer.completeHydration(
      SpokenUpdateStartupSnapshot(
        knownTaskIDs: ["task"],
        observedRunningTaskCount: 0
      )
    )

    uptime += 1
    announcer.observe(
      tasks: [
        task(
          state: .working,
          currentActivity: .runningCommand
        )
      ],
      level: .allActivity
    )
    uptime += 1
    announcer.observe(
      tasks: [
        task(
          state: .working,
          currentActivity: .thinking
        )
      ],
      level: .allActivity
    )
    uptime += 1
    announcer.observe(
      tasks: [
        task(
          state: .working,
          currentActivity: .runningCommand
        )
      ],
      level: .allActivity
    )
    uptime += 1
    announcer.observe(
      tasks: [
        task(
          state: .working,
          currentActivity: .thinking
        )
      ],
      level: .allActivity
    )

    XCTAssertEqual(
      speaker.spokenTexts,
      [
        "Command execution.",
        "Analysis.",
      ]
    )

    uptime += 2
    announcer.observe(
      tasks: [
        task(
          state: .working,
          currentActivity: .runningCommand
        )
      ],
      level: .allActivity
    )

    XCTAssertEqual(
      speaker.spokenTexts,
      [
        "Command execution.",
        "Analysis.",
        "Command execution.",
      ]
    )
  }

  @MainActor
  func testThreeActivityCyclesUseTheSameRepetitionSuppression() {
    var uptime: TimeInterval = 1_000
    let speaker = SpokenUpdateSpeakerSpy()
    let announcer = SpokenUpdateAnnouncer(
      speaker: speaker,
      uptime: { uptime }
    )
    announcer.updateLevel(.allActivity)
    announcer.observe(
      tasks: [
        task(
          state: .working,
          currentActivity: .thinking
        )
      ],
      level: .allActivity
    )
    announcer.completeHydration(
      SpokenUpdateStartupSnapshot(
        knownTaskIDs: ["task"],
        observedRunningTaskCount: 0
      )
    )

    for activity in [
      CodexTaskCurrentActivity.runningCommand,
      .planning,
      .thinking,
      .runningCommand,
      .planning,
      .thinking,
    ] {
      uptime += 1
      announcer.observe(
        tasks: [
          task(
            state: .working,
            currentActivity: activity
          )
        ],
        level: .allActivity
      )
    }

    XCTAssertEqual(
      speaker.spokenTexts,
      [
        "Command execution.",
        "Planning.",
        "Analysis.",
      ]
    )
  }

  @MainActor
  func testTaskActivityRepetitionSuppressionIsIndependentPerTask() {
    var uptime: TimeInterval = 1_000
    let speaker = SpokenUpdateSpeakerSpy()
    let announcer = SpokenUpdateAnnouncer(
      speaker: speaker,
      uptime: { uptime }
    )
    announcer.updateLevel(.allActivity)
    announcer.observe(
      tasks: [
        task(
          id: "alpha",
          state: .working,
          currentActivity: .thinking
        ),
        task(
          id: "beta",
          state: .working,
          currentActivity: .planning
        ),
      ],
      level: .allActivity
    )
    announcer.completeHydration(
      SpokenUpdateStartupSnapshot(
        knownTaskIDs: ["alpha", "beta"],
        observedRunningTaskCount: 0
      )
    )

    uptime += 1
    announcer.observe(
      tasks: [
        task(
          id: "alpha",
          state: .working,
          currentActivity: .runningCommand
        ),
        task(
          id: "beta",
          state: .working,
          currentActivity: .planning
        ),
      ],
      level: .allActivity
    )
    uptime += 1
    announcer.observe(
      tasks: [
        task(
          id: "alpha",
          state: .working,
          currentActivity: .thinking
        ),
        task(
          id: "beta",
          state: .working,
          currentActivity: .planning
        ),
      ],
      level: .allActivity
    )
    uptime += 1
    announcer.observe(
      tasks: [
        task(
          id: "alpha",
          state: .working,
          currentActivity: .runningCommand
        ),
        task(
          id: "beta",
          state: .working,
          currentActivity: .runningCommand
        ),
      ],
      level: .allActivity
    )

    XCTAssertEqual(
      speaker.spokenChannels,
      [
        .task("alpha"),
        .task("alpha"),
        .task("beta"),
      ]
    )
  }

  @MainActor
  func testLeavingWorkingClearsTaskActivityRepetitionHistory() {
    var uptime: TimeInterval = 1_000
    let speaker = SpokenUpdateSpeakerSpy()
    let announcer = SpokenUpdateAnnouncer(
      speaker: speaker,
      uptime: { uptime }
    )
    announcer.updateLevel(.allActivity)
    announcer.observe(
      tasks: [
        task(
          state: .working,
          currentActivity: .thinking
        )
      ],
      level: .allActivity
    )
    announcer.completeHydration(
      SpokenUpdateStartupSnapshot(
        knownTaskIDs: ["task"],
        observedRunningTaskCount: 0
      )
    )

    uptime += 1
    announcer.observe(
      tasks: [
        task(
          state: .working,
          currentActivity: .runningCommand
        )
      ],
      level: .allActivity
    )
    uptime += 1
    announcer.observe(
      tasks: [task(state: .ready)],
      level: .allActivity
    )
    uptime += 1
    announcer.observe(
      tasks: [
        task(
          state: .working,
          currentActivity: .thinking
        )
      ],
      level: .allActivity
    )
    uptime += 1
    announcer.observe(
      tasks: [
        task(
          state: .working,
          currentActivity: .runningCommand
        )
      ],
      level: .allActivity
    )

    XCTAssertEqual(
      speaker.spokenTexts,
      [
        "Command execution.",
        "Task complete.",
        "Task initiated.",
        "Command execution.",
      ]
    )
  }

  @MainActor
  func testIPCDisconnectClearsTaskActivityRepetitionHistory() {
    var uptime: TimeInterval = 1_000
    let speaker = SpokenUpdateSpeakerSpy()
    let announcer = SpokenUpdateAnnouncer(
      speaker: speaker,
      uptime: { uptime }
    )
    announcer.updateLevel(.allActivity)
    announcer.observe(
      tasks: [
        task(
          state: .working,
          currentActivity: .thinking
        )
      ],
      level: .allActivity
    )
    announcer.completeHydration(
      SpokenUpdateStartupSnapshot(
        knownTaskIDs: ["task"],
        observedRunningTaskCount: 0
      )
    )

    uptime += 1
    announcer.observe(
      tasks: [
        task(
          state: .working,
          currentActivity: .runningCommand
        )
      ],
      level: .allActivity
    )
    announcer.observeIPCConnectionState(.disconnected)
    announcer.observe(
      tasks: [
        task(
          state: .working,
          currentActivity: .thinking
        )
      ],
      level: .allActivity
    )
    announcer.observeIPCConnectionState(.connected)
    announcer.completeHydration(
      SpokenUpdateStartupSnapshot(
        knownTaskIDs: ["task"],
        observedRunningTaskCount: 0
      )
    )
    uptime += 1
    announcer.observe(
      tasks: [
        task(
          state: .working,
          currentActivity: .runningCommand
        )
      ],
      level: .allActivity
    )

    XCTAssertEqual(
      speaker.spokenTexts,
      [
        "Command execution.",
        "Command execution.",
      ]
    )
  }

  @MainActor
  func testDiscreteTaskEventsBypassTaskActivityRepetitionSuppression() {
    let speaker = SpokenUpdateSpeakerSpy()
    let announcer = SpokenUpdateAnnouncer(speaker: speaker)
    announcer.updateLevel(.allActivity)
    announcer.observe(
      tasks: [
        task(
          state: .working,
          currentActivity: .thinking
        )
      ],
      level: .allActivity
    )
    announcer.completeHydration(
      SpokenUpdateStartupSnapshot(
        knownTaskIDs: ["task"],
        observedRunningTaskCount: 0
      )
    )

    announcer.observe(
      tasks: [task(state: .needsApproval)],
      level: .allActivity
    )
    announcer.observe(
      tasks: [
        task(
          state: .working,
          currentActivity: .thinking
        )
      ],
      level: .allActivity
    )
    announcer.observe(
      tasks: [task(state: .needsApproval)],
      level: .allActivity
    )

    XCTAssertEqual(
      speaker.spokenTexts,
      [
        "Approval required.",
        "Execution resumed.",
        "Approval required.",
      ]
    )
  }

  @MainActor
  func testEnablingConfirmsTheSettingWithoutReplayingStateObservedWhileDisabled() {
    let speaker = SpokenUpdateSpeakerSpy()
    let announcer = SpokenUpdateAnnouncer(speaker: speaker)
    announcer.updateLevel(.off)

    announcer.observe(
      tasks: [task(state: .working)],
      level: .off
    )
    announcer.observe(
      tasks: [task(state: .ready)],
      level: .off
    )
    announcer.completeHydration(
      SpokenUpdateStartupSnapshot(
        knownTaskIDs: ["task"],
        observedRunningTaskCount: 0
      )
    )
    announcer.updateLevel(.keyEvents)
    announcer.observe(
      tasks: [task(state: .ready)],
      level: .keyEvents
    )

    XCTAssertEqual(speaker.spokenTexts, ["Announcements on."])

    announcer.observe(
      tasks: [task(state: .working)],
      level: .keyEvents
    )

    XCTAssertEqual(
      speaker.spokenTexts,
      [
        "Announcements on.",
        "Task initiated.",
      ]
    )
  }

  @MainActor
  func testAnnouncerPassesTheResolvedTaskVoiceToTheSpeaker() {
    let speaker = SpokenUpdateSpeakerSpy()
    let announcer = SpokenUpdateAnnouncer(speaker: speaker)
    announcer.updateLevel(.keyEvents)
    announcer.observe(
      tasks: [
        TaskPresentation(
          id: "task",
          title: "Task title",
          project: "codex-echo",
          projectID: "/tmp/codex-echo",
          state: .idle,
          activeSubagentCount: 0,
          updatedAt: nil,
          projectVoice: .reed
        )
      ],
      level: .keyEvents
    )
    announcer.completeHydration(
      SpokenUpdateStartupSnapshot(
        knownTaskIDs: ["task"],
        observedRunningTaskCount: 0
      )
    )
    announcer.observe(
      tasks: [
        TaskPresentation(
          id: "task",
          title: "Task title",
          project: "codex-echo",
          projectID: "/tmp/codex-echo",
          state: .working,
          activeSubagentCount: 0,
          updatedAt: nil,
          taskVoice: .rocko,
          projectVoice: .reed
        )
      ],
      level: .keyEvents
    )

    XCTAssertEqual(speaker.spokenTexts, ["Task initiated."])
    XCTAssertEqual(speaker.spokenVoices, [.rocko])
  }

  @MainActor
  func testNewWorkingTaskAfterHydrationReportsInitiation() {
    let speaker = SpokenUpdateSpeakerSpy()
    let announcer = SpokenUpdateAnnouncer(speaker: speaker)
    announcer.updateLevel(.keyEvents)

    announcer.observe(tasks: [], level: .keyEvents)
    announcer.completeHydration(
      SpokenUpdateStartupSnapshot(
        knownTaskIDs: [],
        observedRunningTaskCount: 0
      )
    )
    announcer.observe(
      tasks: [task(id: "new-task", state: .working)],
      level: .keyEvents
    )

    XCTAssertEqual(
      speaker.spokenTexts,
      ["Task initiated."]
    )
  }

  @MainActor
  func testReconnectHydrationDoesNotReplayExistingOrNewCatalogTasks() {
    let speaker = SpokenUpdateSpeakerSpy()
    let announcer = SpokenUpdateAnnouncer(speaker: speaker)
    announcer.updateLevel(.keyEvents, speaksAtStartup: true)
    announcer.observe(
      tasks: [task(id: "existing", state: .working)],
      level: .keyEvents
    )
    announcer.completeHydration(
      SpokenUpdateStartupSnapshot(
        knownTaskIDs: ["existing"],
        observedRunningTaskCount: 1
      )
    )

    announcer.observeIPCConnectionState(.disconnected)
    announcer.observe(tasks: [], level: .keyEvents)
    announcer.observeIPCConnectionState(.connected)
    announcer.completeHydration(
      SpokenUpdateStartupSnapshot(
        knownTaskIDs: ["existing", "during-reconnect"],
        observedRunningTaskCount: 2
      )
    )
    announcer.observe(
      tasks: [
        task(id: "existing", state: .working),
        task(id: "during-reconnect", state: .working),
      ],
      level: .keyEvents
    )

    XCTAssertEqual(
      speaker.spokenTexts,
      ["Codex Echo online."]
    )
  }

  @MainActor
  func testCatalogOnlyOutageKeepsAuthoritativeIPCUpdatesArmed() {
    let speaker = SpokenUpdateSpeakerSpy()
    let announcer = SpokenUpdateAnnouncer(speaker: speaker)
    announcer.updateLevel(.keyEvents, speaksAtStartup: true)
    announcer.observe(
      tasks: [task(state: .working)],
      level: .keyEvents
    )
    announcer.completeHydration(
      SpokenUpdateStartupSnapshot(
        knownTaskIDs: ["task"],
        observedRunningTaskCount: 1
      )
    )

    announcer.observeIPCConnectionState(.connected)
    announcer.observe(
      tasks: [task(state: .ready)],
      level: .keyEvents
    )

    XCTAssertEqual(
      speaker.spokenTexts,
      [
        "Codex Echo online.",
        "Task complete.",
      ]
    )
  }

  @MainActor
  func testIPCOutageSuppressesTransitionsWithoutReplayingThemAfterHydration() {
    let speaker = SpokenUpdateSpeakerSpy()
    let announcer = SpokenUpdateAnnouncer(speaker: speaker)
    announcer.updateLevel(.keyEvents, speaksAtStartup: true)
    announcer.observe(
      tasks: [task(state: .working)],
      level: .keyEvents
    )
    announcer.completeHydration(
      SpokenUpdateStartupSnapshot(
        knownTaskIDs: ["task"],
        observedRunningTaskCount: 1
      )
    )

    announcer.observeIPCConnectionState(.disconnected)
    announcer.observe(
      tasks: [task(state: .ready)],
      level: .keyEvents
    )
    announcer.observeIPCConnectionState(.connected)
    announcer.completeHydration(
      SpokenUpdateStartupSnapshot(
        knownTaskIDs: ["task"],
        observedRunningTaskCount: 0
      )
    )
    announcer.observe(
      tasks: [task(state: .ready)],
      level: .keyEvents
    )

    XCTAssertEqual(
      speaker.spokenTexts,
      ["Codex Echo online."]
    )
  }

  func testReportsTaskInitiationAndSubagentCountIncreases() {
    var tracker = SpokenUpdateTracker()
    _ = tracker.updates(for: [task(state: .idle)])

    XCTAssertEqual(
      tracker.updates(for: [task(state: .working)]),
      [
        SpokenUpdate(
          taskID: "task",
          text: "Task initiated."
        )
      ]
    )
    XCTAssertEqual(
      tracker.updates(for: [task(state: .working, activeSubagentCount: 1)]),
      [
        SpokenUpdate(
          taskID: "task",
          event: .subagentBecameActive,
          text: "Sub-agent active."
        )
      ]
    )
    XCTAssertEqual(
      tracker.updates(for: [task(state: .working, activeSubagentCount: 2)]),
      [
        SpokenUpdate(
          taskID: "task",
          event: .subagentBecameActive,
          text: "Sub-agent active."
        )
      ]
    )
  }

  func testWaitingTasksReportExecutionResumedWhenWorkContinues() {
    for waitingState in [
      CodexTaskActivityState.needsApproval,
      .needsInput,
      .blocked,
    ] {
      var tracker = SpokenUpdateTracker()
      _ = tracker.updates(for: [task(state: waitingState)])

      XCTAssertEqual(
        tracker.updates(for: [task(state: .working)]),
        [
          SpokenUpdate(
            taskID: "task",
            event: .executionResumed,
            text: "Execution resumed."
          )
        ]
      )
    }
  }

  func testReportsStateAndSubagentActivationInTheSameUpdate() {
    var tracker = SpokenUpdateTracker()
    _ = tracker.updates(for: [task(state: .working)])

    XCTAssertEqual(
      tracker.updates(
        for: [
          task(
            state: .needsApproval,
            activeSubagentCount: 1
          )
        ]
      ),
      [
        SpokenUpdate(
          taskID: "task",
          event: .approvalRequired,
          text: "Approval required."
        ),
        SpokenUpdate(
          taskID: "task",
          event: .subagentBecameActive,
          text: "Sub-agent active."
        )
      ]
    )
  }

  func testKeyEventSuppressesActivityFromTheSameTaskUpdate() {
    var tracker = SpokenUpdateTracker()
    _ = tracker.updates(for: [task(state: .idle)])

    XCTAssertEqual(
      tracker.updates(
        for: [
          task(
            state: .working,
            currentActivity: .thinking
          )
        ]
      ),
      [
        SpokenUpdate(
          taskID: "task",
          text: "Task initiated."
        )
      ]
    )

    XCTAssertEqual(
      tracker.updates(
        for: [
          task(
            state: .working,
            activeSubagentCount: 1,
            currentActivity: .coordinatingAgents
          )
        ]
      ),
      [
        SpokenUpdate(
          taskID: "task",
          event: .subagentBecameActive,
          text: "Sub-agent active."
        )
      ]
    )
  }

  @MainActor
  func testKeyEventsSuppressActivityWithoutReplayingItWhenLevelIncreases() {
    let speaker = SpokenUpdateSpeakerSpy()
    let announcer = SpokenUpdateAnnouncer(speaker: speaker)
    announcer.updateLevel(.keyEvents, speaksAtStartup: true)

    announcer.observe(
      tasks: [
        task(
          state: .working,
          currentActivity: .thinking
        )
      ],
      level: .keyEvents
    )
    announcer.completeHydration(
      SpokenUpdateStartupSnapshot(
        knownTaskIDs: ["task"],
        observedRunningTaskCount: 1
      )
    )
    announcer.observe(
      tasks: [
        task(
          state: .working,
          currentActivity: .runningCommand
        )
      ],
      level: .keyEvents
    )
    announcer.updateLevel(.allActivity)
    announcer.observe(
      tasks: [
        task(
          state: .working,
          currentActivity: .planning
        )
      ],
      level: .allActivity
    )

    XCTAssertEqual(
      speaker.spokenTexts,
      [
        "Codex Echo online.",
        "Planning.",
      ]
    )
  }

  func testReportsOnlyActualCurrentActivityChanges() {
    var tracker = SpokenUpdateTracker()
    _ = tracker.updates(
      for: [
        task(
          state: .working,
          currentActivity: .thinking
        )
      ]
    )

    XCTAssertEqual(
      tracker.updates(
        for: [
          task(
            state: .working,
            currentActivity: .thinking
          )
        ]
      ),
      []
    )
    XCTAssertEqual(
      tracker.updates(
        for: [
          task(
            state: .working,
            currentActivity: .runningCommand
          )
        ]
      ),
      [
        SpokenUpdate(
          taskID: "task",
          event: .taskCommandExecution,
          text: "Command execution.",
          repetitionKey: .taskActivity(.runningCommand)
        )
      ]
    )
  }

  func testTaskUpdatesCarryTheResolvedTaskVoice() {
    var tracker = SpokenUpdateTracker()
    let idleTask = TaskPresentation(
      id: "task",
      title: "Task title",
      project: "codex-echo",
      projectID: "/tmp/codex-echo",
      state: .idle,
      activeSubagentCount: 0,
      updatedAt: nil,
      projectVoice: .reed
    )
    _ = tracker.updates(for: [idleTask])

    let workingTask = TaskPresentation(
      id: "task",
      title: "Task title",
      project: "codex-echo",
      projectID: "/tmp/codex-echo",
      state: .working,
      activeSubagentCount: 0,
      updatedAt: nil,
      taskVoice: .rocko,
      projectVoice: .reed
    )

    XCTAssertEqual(
      tracker.updates(for: [workingTask]),
      [
        SpokenUpdate(
          taskID: "task",
          text: "Task initiated.",
          voice: .rocko
        )
      ]
    )
  }

  func testReappearingTaskIsTreatedAsAFreshSnapshot() {
    var tracker = SpokenUpdateTracker()
    _ = tracker.updates(for: [task(state: .working)])
    _ = tracker.updates(for: [])

    XCTAssertEqual(
      tracker.updates(for: [task(state: .ready)]),
      []
    )
  }

  func testTaskStatusCopyOmitsProjectAndTitleIdentity() {
    var tracker = SpokenUpdateTracker()
    _ = tracker.updates(
      for: [
        task(
          title: "Review_status-update",
          project: nil,
          state: .working
        )
      ]
    )

    XCTAssertEqual(
      tracker.updates(
        for: [
          task(
            title: "Review_status-update",
            project: nil,
            state: .ready
          )
        ]
      ),
      [
        SpokenUpdate(
          taskID: "task",
          event: .taskCompleted,
          text: "Task complete."
        )
      ]
    )
  }

  private func task(
    id: String = "task",
    title: String = "Task title",
    project: String? = "codex-echo",
    state: CodexTaskActivityState,
    activeSubagentCount: Int = 0,
    currentActivity: CodexTaskCurrentActivity? = nil
  ) -> TaskPresentation {
    TaskPresentation(
      id: id,
      title: title,
      project: project,
      state: state,
      activeSubagentCount: activeSubagentCount,
      updatedAt: nil,
      currentActivity: currentActivity
    )
  }

}

@MainActor
private final class SpokenUpdateSpeakerSpy: SpokenUpdateSpeaking {
  private(set) var spokenTexts: [String] = []
  private(set) var spokenChannels: [SpokenUpdateChannel] = []
  private(set) var spokenVoices: [SpokenUpdateVoice] = []
  private(set) var spokenCues: [SpokenUpdateCue] = []
  private(set) var stoppedChannels: [SpokenUpdateChannel] = []
  private(set) var stopAllCallCount = 0

  func speak(
    _ text: String,
    channel: SpokenUpdateChannel,
    voice: SpokenUpdateVoice,
    cue: SpokenUpdateCue
  ) {
    spokenTexts.append(text)
    spokenChannels.append(channel)
    spokenVoices.append(voice)
    spokenCues.append(cue)
  }

  func stop(_ channel: SpokenUpdateChannel) {
    stoppedChannels.append(channel)
  }

  func stopAll() {
    stopAllCallCount += 1
  }
}
