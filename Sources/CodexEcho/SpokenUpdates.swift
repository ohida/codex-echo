@preconcurrency import AVFoundation
import Combine
import CodexIPC
import Foundation

enum SpokenUpdateCue: Equatable {
  case none
  case attention
  case important
}

extension SpokenAnnouncementAlertSound {
  var cue: SpokenUpdateCue {
    switch self {
    case .none: .none
    case .onePip: .attention
    case .twoPips: .important
    }
  }
}

struct SpokenUpdateAnnouncement: Equatable {
  let event: SpokenAnnouncementEvent
  let text: String
  let cue: SpokenUpdateCue

  init(
    event: SpokenAnnouncementEvent,
    text: String,
    cue: SpokenUpdateCue = .none
  ) {
    self.event = event
    self.text = text
    self.cue = cue
  }
}

struct SpokenUpdate: Equatable {
  enum RepetitionKey: Hashable {
    case taskActivity(CodexTaskCurrentActivity)
  }

  let taskID: String
  let event: SpokenAnnouncementEvent
  let text: String
  let voice: SpokenUpdateVoice
  let repetitionKey: RepetitionKey?

  init(
    taskID: String,
    event: SpokenAnnouncementEvent = .taskStarted,
    text: String,
    voice: SpokenUpdateVoice = .defaultVoice,
    repetitionKey: RepetitionKey? = nil
  ) {
    self.taskID = taskID
    self.event = event
    self.text = text
    self.voice = voice
    self.repetitionKey = repetitionKey
  }
}

enum SpokenUpdateChannel: Hashable {
  case startup
  case system
  case preview
  case task(String)
}

struct SpokenUpdateVoiceGroup {
  let language: String
  let displayName: String
  let voices: [SpokenUpdateVoice]
}

@MainActor
enum SpokenUpdateVoiceCatalog {
  static let useDefaultVoiceTitle = "Use Default Voice"

  static let availableEnglishUSVoices: [SpokenUpdateVoice] =
    normalizedEnglishUSVoices(
      AVSpeechSynthesisVoice.speechVoices().map { voice in
        SpokenUpdateVoice(
          identifier: voice.identifier,
          displayName: voice.name,
          language: voice.language
        )
      }
    )

  static func normalizedEnglishUSVoices(
    _ voices: [SpokenUpdateVoice]
  ) -> [SpokenUpdateVoice] {
    var seenIdentifiers = Set<String>()
    return voices
      .filter { $0.language == "en-US" }
      .filter { voice in
        guard seenIdentifiers.insert(voice.identifier).inserted else { return false }
        return true
      }
      .sorted {
        ($0.language, $0.displayName, $0.identifier)
          < ($1.language, $1.displayName, $1.identifier)
      }
  }

  static let availableEnglishUSVoiceGroups: [SpokenUpdateVoiceGroup] =
    Dictionary(grouping: availableEnglishUSVoices, by: \.language)
      .map { language, voices in
        SpokenUpdateVoiceGroup(
          language: language,
          displayName: englishLocale.localizedString(forIdentifier: language) ?? language,
          voices: voices
        )
      }
      .sorted { $0.language < $1.language }

  static func menuTitle(
    for voice: SpokenUpdateVoice,
    defaultVoice: SpokenUpdateVoice
  ) -> String {
    voice.identifier == defaultVoice.identifier
      ? "\(voice.displayName) (Default)"
      : voice.displayName
  }

  static func effectiveVoice(
    for task: TaskPresentation,
    defaultVoice: SpokenUpdateVoice = .defaultVoice,
    availableVoices: [SpokenUpdateVoice]? = nil
  ) -> SpokenUpdateVoice {
    let availableVoices = availableVoices ?? availableEnglishUSVoices
    let defaultVoice =
      canonicalVoice(defaultVoice, availableVoices: availableVoices)
      ?? canonicalVoice(.defaultVoice, availableVoices: availableVoices)
      ?? .defaultVoice
    if task.usesDefaultTaskVoice {
      return defaultVoice
    }
    return canonicalVoice(task.taskVoice, availableVoices: availableVoices)
      ?? canonicalVoice(task.projectVoice, availableVoices: availableVoices)
      ?? defaultVoice
  }

  static func taskMenuPreference(
    for task: TaskPresentation,
    availableVoices: [SpokenUpdateVoice]? = nil
  ) -> TaskVoicePreference {
    let availableVoices = availableVoices ?? availableEnglishUSVoices
    if task.usesDefaultTaskVoice { return .defaultVoice }
    if let voice = canonicalVoice(
      task.taskVoice,
      availableVoices: availableVoices
    ) {
      return .voice(voice)
    }
    return task.projectIdentity == nil ? .defaultVoice : .inheritProject
  }

  static func canonicalVoice(
    _ voice: SpokenUpdateVoice?,
    availableVoices: [SpokenUpdateVoice]? = nil
  ) -> SpokenUpdateVoice? {
    guard let voice else { return nil }
    if let availableVoices {
      return availableVoices.first { $0.identifier == voice.identifier }
    }
    return availableEnglishUSVoicesByIdentifier[voice.identifier]
  }

  static func voice(
    identifier: String?,
    availableVoices: [SpokenUpdateVoice]? = nil
  ) -> SpokenUpdateVoice? {
    guard let identifier else { return nil }
    if let availableVoices {
      return availableVoices.first { $0.identifier == identifier }
    }
    return availableEnglishUSVoicesByIdentifier[identifier]
  }

  private static let englishLocale = Locale(identifier: "en_US")
  private static let availableEnglishUSVoicesByIdentifier = Dictionary(
    uniqueKeysWithValues: availableEnglishUSVoices.map { ($0.identifier, $0) }
  )
}

enum SpokenUpdateCopy {
  static let announcementsEnabled = "Announcements on."
  static let voiceSelected = "Voice selected."

  static func startupStatus(
    observedRunningTaskCount: Int,
    remainingPercent: Int? = nil,
    information: Set<StartupAnnouncementInformation> = [.activeTasks]
  ) -> String {
    let informationText = startupInformationStatus(
      observedRunningTaskCount: observedRunningTaskCount,
      remainingPercent: remainingPercent,
      information: information
    )
    var sentences = [SpokenAnnouncementEvent.startupSummary.announcementText]
    if !informationText.isEmpty {
      sentences.append(informationText)
    }
    return sentences.joined(separator: " ")
  }

  static func startupInformationStatus(
    observedRunningTaskCount: Int,
    remainingPercent: Int?,
    information: Set<StartupAnnouncementInformation>
  ) -> String {
    StartupAnnouncementInformation.allCases.compactMap { item in
      guard information.contains(item) else { return nil }
      return switch item {
      case .codexCapacity:
        remainingPercent.map(startupCapacity)
      case .activeTasks:
        switch observedRunningTaskCount {
        case 1:
          "One active task signal detected."
        case 2...:
          "\(observedRunningTaskCount) active task signals detected."
        default:
          nil
        }
      }
    }.joined(separator: " ")
  }

  static func startupCapacity(remainingPercent: Int) -> String {
    let remainingPercent = min(max(remainingPercent, 0), 100)
    return remainingPercent == 0
      ? "Codex capacity depleted."
      : "Codex capacity, \(remainingPercent) percent remaining."
  }

  static func activityStatus(
    _ activity: CodexTaskCurrentActivity
  ) -> String {
    switch activity {
    case .working:
      "Processing."
    case .thinking:
      "Analysis."
    case .planning:
      "Planning."
    case .runningCommand:
      "Command execution."
    case .editingFiles:
      "File modification."
    case .coordinatingAgents:
      "Agent coordination."
    case .checkingPermissions:
      "Permission check."
    case .writingResponse:
      "Response generation."
    case .compactingContext:
      "Context compaction."
    }
  }

}

enum UsageAnnouncementPolicy {
  static let keyEventThresholds = [20, 10, 5, 1, 0]
  static let importantCueThresholds = [5, 1, 0]

  static func announcement(
    previousRemainingPercent: Int?,
    remainingPercent: Int,
    delivery: SpokenAnnouncementDelivery
  ) -> SpokenUpdateAnnouncement? {
    let remainingPercent = min(max(remainingPercent, 0), 100)
    let clampedPreviousPercent = previousRemainingPercent.map {
      min(max($0, 0), 100)
    }
    guard clampedPreviousPercent != remainingPercent else { return nil }
    let event = event(
      previousRemainingPercent: clampedPreviousPercent,
      remainingPercent: remainingPercent
    )
    let rule = delivery.rule(for: event)
    guard rule.speaks else { return nil }
    return SpokenUpdateAnnouncement(
      event: event,
      text: event == .usageIncreased
        ? "Codex capacity increased to \(remainingPercent) percent."
        : SpokenUpdateCopy.startupCapacity(
          remainingPercent: remainingPercent
        ),
      cue: rule.alertSound.cue
    )
  }

  private static func event(
    previousRemainingPercent: Int?,
    remainingPercent: Int
  ) -> SpokenAnnouncementEvent {
    guard let previousRemainingPercent else {
      switch remainingPercent {
      case 0: return .usageDepleted
      case 1: return .usageOnePercent
      case 2...5: return .usageFivePercent
      case 6...10: return .usageTenPercent
      default: return .usageChanged
      }
    }
    if remainingPercent > previousRemainingPercent {
      return .usageIncreased
    }
    if remainingPercent == 0 && previousRemainingPercent > 0 {
      return .usageDepleted
    }
    if previousRemainingPercent > 1 && remainingPercent <= 1 {
      return .usageOnePercent
    }
    if previousRemainingPercent > 5 && remainingPercent <= 5 {
      return .usageFivePercent
    }
    if previousRemainingPercent > 10 && remainingPercent <= 10 {
      return .usageTenPercent
    }
    if previousRemainingPercent > 20 && remainingPercent <= 20 {
      return .usageTwentyPercent
    }
    return .usageChanged
  }
}

struct SpokenUpdateHydration: Equatable {
  let catalogSnapshot: CodexTaskCatalogSnapshot?
  let observedRunningTaskCount: Int
  let connectionHealth: CodexConnectionHealth

  var readySnapshot: SpokenUpdateStartupSnapshot? {
    guard connectionHealth == .live else { return nil }
    guard let catalogSnapshot else { return nil }
    return SpokenUpdateStartupSnapshot(
      knownTaskIDs: catalogSnapshot.taskIDs,
      observedRunningTaskCount: observedRunningTaskCount
    )
  }
}

struct SpokenUpdateStartupSnapshot: Equatable {
  let knownTaskIDs: Set<String>
  let observedRunningTaskCount: Int
}

enum CodexMonitoringAvailability: Equatable {
  case inactive
  case available
  case unavailable

  static func resolve(
    desktopAppState: CodexDesktopAppState,
    connectionHealth: CodexConnectionHealth
  ) -> Self {
    guard desktopAppState == .running else { return .inactive }
    return connectionHealth == .live ? .available : .unavailable
  }

  var announcementDelay: TimeInterval {
    self == .unavailable ? 10 : 0
  }
}

struct SpokenUpdateTracker {
  private struct Snapshot {
    let state: CodexTaskActivityState
    let activeSubagentCount: Int
    let currentActivity: CodexTaskCurrentActivity?
  }

  private var snapshotsByTaskID: [String: Snapshot] = [:]
  private var knownTaskIDs: Set<String> = []

  mutating func updates(
    for tasks: [TaskPresentation],
    announceNewTasks: Bool = false,
    voiceForTask: (TaskPresentation) -> SpokenUpdateVoice = {
      $0.effectiveVoice
    }
  ) -> [SpokenUpdate] {
    let previousSnapshots = snapshotsByTaskID
    let previouslyKnownTaskIDs = knownTaskIDs
    snapshotsByTaskID = Dictionary(
      uniqueKeysWithValues: tasks.map {
        (
          $0.id,
          Snapshot(
            state: $0.state,
            activeSubagentCount: $0.activeSubagentCount,
            currentActivity: $0.currentActivity
          )
        )
      }
    )
    knownTaskIDs.formUnion(tasks.map(\.id))

    return tasks.flatMap { task -> [SpokenUpdate] in
      guard let previous = previousSnapshots[task.id] else {
        guard announceNewTasks,
          !previouslyKnownTaskIDs.contains(task.id),
          task.state == .working
        else { return [] }
        return [
          SpokenUpdate(
            taskID: task.id,
            event: .taskStarted,
            text: SpokenAnnouncementEvent.taskStarted.announcementText,
            voice: voiceForTask(task)
          )
        ]
      }
      var updates: [SpokenUpdate] = []

      if previous.state != task.state,
        let announcement = statusAnnouncement(
          from: previous.state,
          to: task.state
        )
      {
        updates.append(
          SpokenUpdate(
            taskID: task.id,
            event: announcement.event,
            text: announcement.text,
            voice: voiceForTask(task)
          )
        )
      }

      if task.activeSubagentCount > previous.activeSubagentCount {
        updates.append(
          SpokenUpdate(
            taskID: task.id,
            event: .subagentBecameActive,
            text: SpokenAnnouncementEvent.subagentBecameActive.announcementText,
            voice: voiceForTask(task)
          )
        )
      }

      if updates.isEmpty,
        task.state == .working,
        task.currentActivity != previous.currentActivity,
        let currentActivity = task.currentActivity
      {
        let event = SpokenAnnouncementEvent.event(for: currentActivity)
        updates.append(
          SpokenUpdate(
            taskID: task.id,
            event: event,
            text: event.announcementText,
            voice: voiceForTask(task),
            repetitionKey: .taskActivity(currentActivity)
          )
        )
      }

      return updates
    }
  }

  mutating func seedKnownTaskIDs(_ taskIDs: Set<String>) {
    knownTaskIDs.formUnion(taskIDs)
  }

  private func statusAnnouncement(
    from previousState: CodexTaskActivityState,
    to state: CodexTaskActivityState
  ) -> SpokenUpdateAnnouncement? {
    switch state {
    case .ready:
      SpokenUpdateAnnouncement(
        event: .taskCompleted,
        text: SpokenAnnouncementEvent.taskCompleted.announcementText
      )
    case .needsInput:
      SpokenUpdateAnnouncement(
        event: .inputRequired,
        text: SpokenAnnouncementEvent.inputRequired.announcementText
      )
    case .needsApproval:
      SpokenUpdateAnnouncement(
        event: .approvalRequired,
        text: SpokenAnnouncementEvent.approvalRequired.announcementText
      )
    case .blocked:
      SpokenUpdateAnnouncement(
        event: .taskError,
        text: SpokenAnnouncementEvent.taskError.announcementText
      )
    case .working:
      if previousState == .needsApproval
        || previousState == .needsInput
        || previousState == .blocked
      {
        SpokenUpdateAnnouncement(
          event: .executionResumed,
          text: SpokenAnnouncementEvent.executionResumed.announcementText
        )
      } else {
        SpokenUpdateAnnouncement(
          event: .taskStarted,
          text: SpokenAnnouncementEvent.taskStarted.announcementText
        )
      }
    case .idle:
      nil
    }
  }
}

@MainActor
protocol SpokenUpdateSpeaking: AnyObject {
  func speak(
    _ text: String,
    channel: SpokenUpdateChannel,
    voice: SpokenUpdateVoice,
    cue: SpokenUpdateCue
  )
  func stop(_ channel: SpokenUpdateChannel)
  func stopAll()
}

extension SpokenUpdateSpeaking {
  func speak(
    _ text: String,
    channel: SpokenUpdateChannel,
    voice: SpokenUpdateVoice
  ) {
    speak(text, channel: channel, voice: voice, cue: .none)
  }

  func speak(_ text: String, channel: SpokenUpdateChannel) {
    speak(text, channel: channel, voice: .defaultVoice, cue: .none)
  }
}

@MainActor
final class SpokenUpdateAnnouncer {
  static let taskActivityRepeatInterval: TimeInterval = 5

  private struct PendingStartupInformation {
    let snapshot: SpokenUpdateStartupSnapshot
    let information: Set<StartupAnnouncementInformation>
  }

  private let speaker: any SpokenUpdateSpeaking
  private let uptime: () -> TimeInterval
  private var defaultVoice: SpokenUpdateVoice
  private var tracker = SpokenUpdateTracker()
  private var lastRepeatableAnnouncementsByTaskID:
    [String: [SpokenUpdate.RepetitionKey: TimeInterval]] = [:]
  private var liveUpdatesAreArmed = false
  private var previousDesktopAppState: CodexDesktopAppState?
  private var queuedFollowUpCountsByTaskID: [String: Int] = [:]
  private var previousRemainingUsagePercent: Int?
  private var currentDelivery: SpokenAnnouncementDelivery?
  private var deliveryChangedSinceLaunch = false
  private var completedInitialHydration = false
  private var pendingStartupInformation: PendingStartupInformation?
  private var monitoringInterruptionWasAnnounced = false
  private var monitoringRestorationIsPending = false
  private var desktopApplicationWasObservedOffline = false
  private var desktopApplicationRestorationIsPending = false

  init(
    speaker: any SpokenUpdateSpeaking,
    defaultVoice: SpokenUpdateVoice = .defaultVoice,
    uptime: @escaping () -> TimeInterval = {
      ProcessInfo.processInfo.systemUptime
    }
  ) {
    self.speaker = speaker
    self.defaultVoice = defaultVoice
    self.uptime = uptime
  }

  func observe(
    tasks: [TaskPresentation],
    delivery: SpokenAnnouncementDelivery
  ) {
    let workingTaskIDs = Set(
      tasks.lazy
        .filter { $0.state == .working }
        .map(\.id)
    )
    lastRepeatableAnnouncementsByTaskID =
      lastRepeatableAnnouncementsByTaskID
      .filter { workingTaskIDs.contains($0.key) }
    let updates = tracker.updates(
      for: tasks,
      announceNewTasks: liveUpdatesAreArmed,
      voiceForTask: { task in
        SpokenUpdateVoiceCatalog.effectiveVoice(
          for: task,
          defaultVoice: self.defaultVoice
        )
      }
    )
    guard liveUpdatesAreArmed else { return }
    for update in updates {
      let rule = delivery.rule(for: update.event)
      guard rule.speaks, shouldAnnounce(update) else { continue }
      speaker.speak(
        update.text,
        channel: .task(update.taskID),
        voice: update.voice,
        cue: rule.alertSound.cue
      )
    }
  }

  private func shouldAnnounce(_ update: SpokenUpdate) -> Bool {
    guard let repetitionKey = update.repetitionKey else { return true }
    let timestamp = uptime()
    if let lastAnnouncement =
      lastRepeatableAnnouncementsByTaskID[update.taskID]?[repetitionKey],
      timestamp - lastAnnouncement < Self.taskActivityRepeatInterval
    {
      return false
    }
    lastRepeatableAnnouncementsByTaskID[update.taskID, default: [:]][
      repetitionKey
    ] = timestamp
    return true
  }

  func preview() {
    speaker.stop(.preview)
    speaker.speak(
      SpokenAnnouncementEvent.taskCompleted.announcementText,
      channel: .preview,
      voice: defaultVoice
    )
  }

  func preview(voice: SpokenUpdateVoice) {
    speaker.stop(.preview)
    speaker.speak(
      SpokenUpdateCopy.voiceSelected,
      channel: .preview,
      voice: voice
    )
  }

  func preview(
    _ event: SpokenAnnouncementEvent,
    configuration: SpokenAnnouncementConfiguration
  ) {
    speaker.stop(.preview)
    speaker.speak(
      event == .startupSummary
        ? SpokenUpdateCopy.startupStatus(
          observedRunningTaskCount: 1,
          remainingPercent: 67,
          information: configuration.startupInformation
        )
        : event.announcementText,
      channel: .preview,
      voice: defaultVoice,
      cue: configuration.rule(for: event).alertSound.cue
    )
  }

  func updateDefaultVoice(_ voice: SpokenUpdateVoice) {
    defaultVoice =
      SpokenUpdateVoiceCatalog.canonicalVoice(voice)
      ?? SpokenUpdateVoiceCatalog.canonicalVoice(.defaultVoice)
      ?? .defaultVoice
  }

  func updateDelivery(_ delivery: SpokenAnnouncementDelivery) {
    if let currentDelivery, delivery != currentDelivery {
      if delivery.isEnabled != currentDelivery.isEnabled {
        deliveryChangedSinceLaunch = true
      }
      if currentDelivery.isEnabled, !delivery.isEnabled {
        speaker.stopAll()
      } else if !currentDelivery.isEnabled, delivery.isEnabled {
        speaker.speak(
          SpokenUpdateCopy.announcementsEnabled,
          channel: .system,
          voice: defaultVoice
        )
      }
    }
    if pendingStartupInformation != nil,
      !delivery.rule(for: .startupSummary).speaks
        || !delivery.configuration.includesStartupInformation(.codexCapacity)
    {
      pendingStartupInformation = nil
    }
    currentDelivery = delivery
  }

  func observeIPCConnectionState(_ state: CodexIPCConnectionState) {
    if state != .connected {
      liveUpdatesAreArmed = false
      queuedFollowUpCountsByTaskID.removeAll()
      lastRepeatableAnnouncementsByTaskID.removeAll()
    }
  }

  func observeQueuedFollowUps(
    taskID: String,
    queuedCount: Int,
    voice: SpokenUpdateVoice,
    delivery: SpokenAnnouncementDelivery
  ) {
    let previousCount = queuedFollowUpCountsByTaskID[taskID] ?? 0
    queuedFollowUpCountsByTaskID[taskID] = queuedCount
    let rule = delivery.rule(for: .directiveQueued)
    guard liveUpdatesAreArmed,
      rule.speaks,
      queuedCount > previousCount
    else { return }

    speaker.speak(
      SpokenAnnouncementEvent.directiveQueued.announcementText,
      channel: .task(taskID),
      voice: voice,
      cue: rule.alertSound.cue
    )
  }

  func observeUsage(
    remainingPercent: Int?,
    delivery: SpokenAnnouncementDelivery
  ) {
    guard let remainingPercent else { return }
    let previousRemainingPercent = previousRemainingUsagePercent
    previousRemainingUsagePercent = remainingPercent
    guard liveUpdatesAreArmed else { return }
    if previousRemainingPercent == nil {
      announcePendingStartupInformationIfReady(delivery: delivery)
      return
    }
    guard
      let announcement = UsageAnnouncementPolicy.announcement(
        previousRemainingPercent: previousRemainingPercent,
        remainingPercent: remainingPercent,
        delivery: delivery
      )
    else { return }
    speaker.speak(
      announcement.text,
      channel: .system,
      voice: defaultVoice,
      cue: announcement.cue
    )
  }

  func observeDesktopAppState(
    _ state: CodexDesktopAppState,
    delivery: SpokenAnnouncementDelivery
  ) {
    let previousState = previousDesktopAppState
    previousDesktopAppState = state
    if previousState == .running, state != .running {
      queuedFollowUpCountsByTaskID.removeAll()
      desktopApplicationWasObservedOffline = completedInitialHydration
      desktopApplicationRestorationIsPending = false
    } else if previousState != nil,
      previousState != .running,
      state == .running,
      desktopApplicationWasObservedOffline
    {
      desktopApplicationWasObservedOffline = false
      desktopApplicationRestorationIsPending =
        delivery.rule(for: .applicationOnline).speaks
    }
    let rule = delivery.rule(for: .applicationOffline)
    guard rule.speaks,
      previousState == .running,
      state != .running
    else { return }

    speaker.speak(
      SpokenAnnouncementEvent.applicationOffline.announcementText,
      channel: .system,
      voice: defaultVoice,
      cue: rule.alertSound.cue
    )
  }

  func observeMonitoringAvailability(
    _ availability: CodexMonitoringAvailability
  ) {
    switch availability {
    case .inactive:
      monitoringInterruptionWasAnnounced = false
      monitoringRestorationIsPending = false
    case .unavailable:
      monitoringRestorationIsPending = false
      guard completedInitialHydration,
        !monitoringInterruptionWasAnnounced,
        let currentDelivery
      else { return }
      let rule = currentDelivery.rule(for: .monitoringInterrupted)
      guard rule.speaks else { return }
      monitoringInterruptionWasAnnounced = true
      speaker.speak(
        SpokenAnnouncementEvent.monitoringInterrupted.announcementText,
        channel: .system,
        voice: defaultVoice,
        cue: rule.alertSound.cue
      )
    case .available:
      guard monitoringInterruptionWasAnnounced else {
        monitoringRestorationIsPending = false
        return
      }
      if liveUpdatesAreArmed {
        announceMonitoringRestoration()
      } else {
        monitoringRestorationIsPending = true
      }
    }
  }

  func completeHydration(_ startupSnapshot: SpokenUpdateStartupSnapshot) {
    guard !liveUpdatesAreArmed else { return }
    tracker.seedKnownTaskIDs(startupSnapshot.knownTaskIDs)
    if !completedInitialHydration {
      if !deliveryChangedSinceLaunch,
        let currentDelivery,
        currentDelivery.rule(for: .startupSummary).speaks
      {
        let defersStartupInformation =
          previousRemainingUsagePercent == nil
          && currentDelivery.configuration.includesStartupInformation(
            .codexCapacity
          )
        let startupInformation =
          currentDelivery.configuration.startupInformation
        pendingStartupInformation = defersStartupInformation
          ? PendingStartupInformation(
            snapshot: startupSnapshot,
            information: startupInformation
          )
          : nil
        speaker.speak(
          SpokenUpdateCopy.startupStatus(
            observedRunningTaskCount:
              startupSnapshot.observedRunningTaskCount,
            remainingPercent: previousRemainingUsagePercent,
            information: defersStartupInformation ? [] : startupInformation
          ),
          channel: .startup,
          voice: defaultVoice,
          cue: currentDelivery.rule(for: .startupSummary).alertSound.cue
        )
      }
      completedInitialHydration = true
    } else if let pendingStartupInformation {
      self.pendingStartupInformation = PendingStartupInformation(
        snapshot: startupSnapshot,
        information: pendingStartupInformation.information
      )
    }
    liveUpdatesAreArmed = true
    if let currentDelivery {
      announcePendingStartupInformationIfReady(delivery: currentDelivery)
    }
    if desktopApplicationRestorationIsPending {
      announceDesktopApplicationRestoration()
    }
    if monitoringRestorationIsPending {
      announceMonitoringRestoration()
    }
  }

  private func announcePendingStartupInformationIfReady(
    delivery: SpokenAnnouncementDelivery
  ) {
    guard let remainingPercent = previousRemainingUsagePercent,
      let pendingInformation = pendingStartupInformation
    else { return }
    pendingStartupInformation = nil
    announcePendingStartupInformation(
      remainingPercent: remainingPercent,
      pendingInformation: pendingInformation,
      delivery: delivery
    )
  }

  private func announcePendingStartupInformation(
    remainingPercent: Int,
    pendingInformation: PendingStartupInformation,
    delivery: SpokenAnnouncementDelivery
  ) {
    let rule = delivery.rule(for: .startupSummary)
    guard !deliveryChangedSinceLaunch,
      rule.speaks,
      delivery.configuration.includesStartupInformation(.codexCapacity)
    else { return }
    let text = SpokenUpdateCopy.startupInformationStatus(
      observedRunningTaskCount:
        pendingInformation.snapshot.observedRunningTaskCount,
      remainingPercent: remainingPercent,
      information: pendingInformation.information
        .intersection(delivery.configuration.startupInformation)
    )
    guard !text.isEmpty else { return }
    speaker.speak(
      text,
      channel: .startup,
      voice: defaultVoice,
      cue: .none
    )
  }

  private func announceMonitoringRestoration() {
    guard monitoringInterruptionWasAnnounced else {
      monitoringRestorationIsPending = false
      return
    }
    let rule = currentDelivery?.rule(for: .monitoringRestored) ?? .silent
    if rule.speaks {
      speaker.speak(
        SpokenAnnouncementEvent.monitoringRestored.announcementText,
        channel: .system,
        voice: defaultVoice,
        cue: rule.alertSound.cue
      )
    }
    monitoringInterruptionWasAnnounced = false
    monitoringRestorationIsPending = false
  }

  private func announceDesktopApplicationRestoration() {
    guard desktopApplicationRestorationIsPending else { return }
    desktopApplicationRestorationIsPending = false
    let rule = currentDelivery?.rule(for: .applicationOnline) ?? .silent
    guard rule.speaks else { return }
    speaker.speak(
      SpokenAnnouncementEvent.applicationOnline.announcementText,
      channel: .system,
      voice: defaultVoice,
      cue: rule.alertSound.cue
    )
  }

  #if DEBUG
    func previewOverlap() {
      speaker.speak(
        "Alpha. Task initiated.",
        channel: .task("alpha"),
        voice: defaultVoice
      )
      speaker.speak(
        "Beta. \(SpokenAnnouncementEvent.subagentBecameActive.announcementText)",
        channel: .task("beta"),
        voice: defaultVoice
      )
      speaker.speak(
        "Gamma. Analysis.",
        channel: .task("gamma"),
        voice: defaultVoice
      )
    }

    func previewContextCompaction() {
      speaker.speak(
        SpokenUpdateCopy.activityStatus(.compactingContext),
        channel: .task("context-compaction"),
        voice: defaultVoice
      )
    }

    func previewQueuedDirective() {
      speaker.speak(
        SpokenAnnouncementEvent.directiveQueued.announcementText,
        channel: .task("queued-directive"),
        voice: defaultVoice
      )
    }

    func previewVoiceSelection() {
      preview(voice: defaultVoice)
    }

    func previewExecutionResumed() {
      speaker.speak(
        SpokenAnnouncementEvent.executionResumed.announcementText,
        channel: .task("execution-resumed"),
        voice: defaultVoice
      )
    }

    func previewImportantCue() {
      speaker.speak(
        "Approval required.",
        channel: .preview,
        voice: defaultVoice,
        cue: .important
      )
    }

    func previewStartupExclusivity() {
      speaker.speak(
        "\(AppPresentationCopy.startupAnnouncement) Two active task signals detected.",
        channel: .startup,
        voice: defaultVoice
      )
      speaker.speak(
        "Input required.",
        channel: .task("startup-exclusivity"),
        voice: defaultVoice,
        cue: .important
      )
    }
  #endif
}

@MainActor
final class SpokenUpdateCoordinator {
  private let announcer: SpokenUpdateAnnouncer
  private let settings: MenuBarSettings
  private var cancellables: Set<AnyCancellable> = []

  init(
    model: CodexActivityModel,
    settings: MenuBarSettings,
    speaker: any SpokenUpdateSpeaking
  ) {
    let announcer = SpokenUpdateAnnouncer(
      speaker: speaker,
      defaultVoice: settings.defaultSpokenUpdateVoice
    )
    self.announcer = announcer
    self.settings = settings

    settings.$defaultSpokenUpdateVoice
      .removeDuplicates()
      .sink { [weak announcer] voice in
        announcer?.updateDefaultVoice(voice)
      }
      .store(in: &cancellables)

    let deliveryPublisher = settings.$speaksAnnouncements
      .combineLatest(settings.$spokenAnnouncementConfiguration)
      .map { isEnabled, configuration in
        SpokenAnnouncementDelivery(
          isEnabled: isEnabled,
          configuration: configuration
        )
      }
      .removeDuplicates()
      .eraseToAnyPublisher()

    deliveryPublisher
      .sink { [weak announcer] delivery in
        announcer?.updateDelivery(delivery)
      }
      .store(in: &cancellables)

    model.$ipcConnectionState
      .removeDuplicates()
      .sink { [weak announcer] state in
        announcer?.observeIPCConnectionState(state)
      }
      .store(in: &cancellables)

    model.$tasks
      .combineLatest(deliveryPublisher)
      .sink { [weak announcer] tasks, delivery in
        announcer?.observe(tasks: tasks, delivery: delivery)
      }
      .store(in: &cancellables)

    model.queuedFollowUpsChanges
      .sink { [weak announcer, weak model] change in
        guard let announcer, let model else { return }
        let voice =
          model.tasks.first(where: { $0.id == change.taskID })
          .map {
            SpokenUpdateVoiceCatalog.effectiveVoice(
              for: $0,
              defaultVoice: settings.defaultSpokenUpdateVoice
            )
          }
          ?? settings.defaultSpokenUpdateVoice
        announcer.observeQueuedFollowUps(
          taskID: change.taskID,
          queuedCount: change.queuedCount,
          voice: voice,
          delivery: settings.spokenAnnouncementDelivery
        )
      }
      .store(in: &cancellables)

    model.$codexUsageSnapshot
      .map { $0?.remainingPercent }
      .combineLatest(deliveryPublisher)
      .sink { [weak announcer] remainingPercent, delivery in
        announcer?.observeUsage(
          remainingPercent: remainingPercent,
          delivery: delivery
        )
      }
      .store(in: &cancellables)

    model.$desktopAppState
      .combineLatest(deliveryPublisher)
      .sink { [weak announcer] state, delivery in
        announcer?.observeDesktopAppState(
          state,
          delivery: delivery
        )
      }
      .store(in: &cancellables)

    let connectionHealthPublisher = Publishers.CombineLatest(
      model.$ipcConnectionState,
      model.$appServerConnectionState
    )
    .map(CodexConnectionHealthPolicy.resolve)
    .removeDuplicates()
    .eraseToAnyPublisher()

    Publishers.CombineLatest(
      model.$desktopAppState.removeDuplicates(),
      connectionHealthPublisher
    )
    .map(CodexMonitoringAvailability.resolve)
    .removeDuplicates()
    .map { availability -> AnyPublisher<CodexMonitoringAvailability, Never> in
      guard availability.announcementDelay > 0 else {
        return Just(availability).eraseToAnyPublisher()
      }
      return Just(availability)
        .delay(
          for: .seconds(availability.announcementDelay),
          scheduler: RunLoop.main
        )
        .eraseToAnyPublisher()
    }
    .switchToLatest()
    .sink { [weak announcer] availability in
      announcer?.observeMonitoringAvailability(availability)
    }
    .store(in: &cancellables)

    Publishers.CombineLatest3(
      model.$taskCatalogSnapshot,
      model.$tasks.map { tasks in
        tasks.count(where: { $0.state == .working })
      },
      connectionHealthPublisher
    )
      .map { catalogSnapshot, observedRunningTaskCount, connectionHealth in
        SpokenUpdateHydration(
          catalogSnapshot: catalogSnapshot,
          observedRunningTaskCount: observedRunningTaskCount,
          connectionHealth: connectionHealth
        )
      }
      .removeDuplicates()
      .debounce(for: .seconds(2), scheduler: RunLoop.main)
      .compactMap(\.readySnapshot)
      .sink { [weak announcer] startupSnapshot in
        announcer?.completeHydration(startupSnapshot)
      }
      .store(in: &cancellables)

    #if DEBUG
      let spokenFixture = ProcessInfo.processInfo.environment[
        "CODEX_ECHO_DEBUG_SPOKEN_UPDATE_FIXTURE"
      ]
      if spokenFixture == "overlap" {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak announcer] in
          announcer?.previewOverlap()
        }
      } else if spokenFixture == "context-compaction" {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak announcer] in
          announcer?.previewContextCompaction()
        }
      } else if spokenFixture == "queued-directive" {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak announcer] in
          announcer?.previewQueuedDirective()
        }
      } else if spokenFixture == "voice-selected" {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak announcer] in
          announcer?.previewVoiceSelection()
        }
      } else if spokenFixture == "execution-resumed" {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak announcer] in
          announcer?.previewExecutionResumed()
        }
      } else if spokenFixture == "important-cue" {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak announcer] in
          announcer?.previewImportantCue()
        }
      } else if spokenFixture == "startup-exclusivity" {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak announcer] in
          announcer?.previewStartupExclusivity()
        }
      }
    #endif
  }

  func preview() {
    announcer.preview()
  }

  func preview(voice: SpokenUpdateVoice) {
    announcer.preview(voice: voice)
  }

  func preview(_ event: SpokenAnnouncementEvent) {
    announcer.preview(
      event,
      configuration: settings.spokenAnnouncementConfiguration
    )
  }
}
