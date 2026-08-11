import AppKit
import CodexAppServer
import CodexIPC
import Combine
import Foundation

struct TaskPresentation: Equatable, Identifiable {
  let id: String
  let title: String
  let project: String?
  let projectIdentity: TaskProjectIdentity?
  let state: CodexTaskActivityState
  let isUnread: Bool
  let activeSubagentCount: Int
  let updatedAt: Date?
  let turnStartedAt: Date?
  let currentActivity: CodexTaskCurrentActivity?
  let completedAt: Date?
  let completedDuration: TimeInterval?
  let taskColor: TaskAccentColor?
  let projectColor: TaskAccentColor?
  let usesSystemTaskColor: Bool
  let taskVoice: SpokenUpdateVoice?
  let projectVoice: SpokenUpdateVoice?
  let usesDefaultTaskVoice: Bool

  init(
    id: String,
    title: String,
    project: String? = nil,
    projectID: String? = nil,
    projectIdentity: TaskProjectIdentity? = nil,
    state: CodexTaskActivityState,
    isUnread: Bool = false,
    activeSubagentCount: Int,
    updatedAt: Date?,
    turnStartedAt: Date? = nil,
    currentActivity: CodexTaskCurrentActivity? = nil,
    completedAt: Date? = nil,
    completedDuration: TimeInterval? = nil,
    taskColor: TaskAccentColor? = nil,
    projectColor: TaskAccentColor? = nil,
    usesSystemTaskColor: Bool = false,
    taskVoice: SpokenUpdateVoice? = nil,
    projectVoice: SpokenUpdateVoice? = nil,
    usesDefaultTaskVoice: Bool = false
  ) {
    self.id = id
    self.title = title
    self.projectIdentity = projectIdentity
      ?? projectID.flatMap(ProjectColorIdentity.key(for:)).map(TaskProjectIdentity.project)
    self.project = project ?? self.projectIdentity?.displayName
    self.state = state
    self.isUnread = isUnread
    self.activeSubagentCount = activeSubagentCount
    self.updatedAt = updatedAt
    self.turnStartedAt = turnStartedAt
    self.currentActivity = currentActivity
    self.completedAt = completedAt
    self.completedDuration = completedDuration
    self.taskColor = taskColor
    self.projectColor = projectColor
    self.usesSystemTaskColor = usesSystemTaskColor
    self.taskVoice = taskVoice
    self.projectVoice = projectVoice
    self.usesDefaultTaskVoice = usesDefaultTaskVoice
  }

  var projectID: String? { projectIdentity?.projectID }

  var effectiveColor: TaskAccentColor? {
    TaskColorResolution.effectiveColor(
      taskColor: taskColor,
      projectColor: projectColor,
      usesSystemTaskColor: usesSystemTaskColor
    )
  }

  var taskColorPreference: TaskColorPreference {
    if usesSystemTaskColor { return .system }
    if let taskColor { return .accent(taskColor) }
    return .inheritProject
  }

  var effectiveVoice: SpokenUpdateVoice {
    TaskVoiceResolution.effectiveVoice(
      taskVoice: taskVoice,
      projectVoice: projectVoice,
      usesDefaultTaskVoice: usesDefaultTaskVoice
    )
  }

  var taskVoicePreference: TaskVoicePreference {
    if usesDefaultTaskVoice { return .defaultVoice }
    if let taskVoice { return .voice(taskVoice) }
    return .inheritProject
  }

  func replacingTaskColorPreference(_ preference: TaskColorPreference) -> Self {
    let replacementTaskColor: TaskAccentColor?
    let replacementUsesSystemColor: Bool
    switch preference {
    case .inheritProject:
      replacementTaskColor = nil
      replacementUsesSystemColor = false
    case .system:
      replacementTaskColor = nil
      replacementUsesSystemColor = true
    case .accent(let color):
      replacementTaskColor = color
      replacementUsesSystemColor = false
    }
    return replacingColors(
      taskColor: replacementTaskColor,
      projectColor: projectColor,
      usesSystemTaskColor: replacementUsesSystemColor
    )
  }

  func replacingProjectColor(_ color: TaskAccentColor?) -> Self {
    replacingColors(
      taskColor: taskColor,
      projectColor: color,
      usesSystemTaskColor: usesSystemTaskColor
    )
  }

  private func replacingColors(
    taskColor: TaskAccentColor?,
    projectColor: TaskAccentColor?,
    usesSystemTaskColor: Bool
  ) -> Self {
    Self(
      id: id,
      title: title,
      project: project,
      projectIdentity: projectIdentity,
      state: state,
      isUnread: isUnread,
      activeSubagentCount: activeSubagentCount,
      updatedAt: updatedAt,
      turnStartedAt: turnStartedAt,
      currentActivity: currentActivity,
      completedAt: completedAt,
      completedDuration: completedDuration,
      taskColor: taskColor,
      projectColor: projectColor,
      usesSystemTaskColor: usesSystemTaskColor,
      taskVoice: self.taskVoice,
      projectVoice: self.projectVoice,
      usesDefaultTaskVoice: self.usesDefaultTaskVoice
    )
  }

  func replacingTaskVoicePreference(_ preference: TaskVoicePreference) -> Self {
    let replacementTaskVoice: SpokenUpdateVoice?
    let replacementUsesDefaultVoice: Bool
    switch preference {
    case .inheritProject:
      replacementTaskVoice = nil
      replacementUsesDefaultVoice = false
    case .defaultVoice:
      replacementTaskVoice = nil
      replacementUsesDefaultVoice = true
    case .voice(let voice):
      replacementTaskVoice = voice
      replacementUsesDefaultVoice = false
    }
    return replacingVoices(
      taskVoice: replacementTaskVoice,
      projectVoice: projectVoice,
      usesDefaultTaskVoice: replacementUsesDefaultVoice
    )
  }

  func replacingProjectVoice(_ voice: SpokenUpdateVoice?) -> Self {
    replacingVoices(
      taskVoice: taskVoice,
      projectVoice: voice,
      usesDefaultTaskVoice: usesDefaultTaskVoice
    )
  }

  private func replacingVoices(
    taskVoice: SpokenUpdateVoice?,
    projectVoice: SpokenUpdateVoice?,
    usesDefaultTaskVoice: Bool
  ) -> Self {
    Self(
      id: id,
      title: title,
      project: project,
      projectIdentity: projectIdentity,
      state: state,
      isUnread: isUnread,
      activeSubagentCount: activeSubagentCount,
      updatedAt: updatedAt,
      turnStartedAt: turnStartedAt,
      currentActivity: currentActivity,
      completedAt: completedAt,
      completedDuration: completedDuration,
      taskColor: self.taskColor,
      projectColor: self.projectColor,
      usesSystemTaskColor: self.usesSystemTaskColor,
      taskVoice: taskVoice,
      projectVoice: projectVoice,
      usesDefaultTaskVoice: usesDefaultTaskVoice
    )
  }
}

enum CrewRingMoveDirection {
  case left
  case right
}

enum CrewRingMenuAction: Equatable {
  case hide
}

enum CrewRingMenuPolicy {
  static func actions(forStatusBarTaskCount count: Int) -> [CrewRingMenuAction] {
    guard count > 0 else { return [] }
    return [.hide]
  }
}

enum CrewRingVisibilityPolicy {
  static func shouldRestoreHiddenRing(
    from previousState: CodexTaskActivityState?,
    to state: CodexTaskActivityState
  ) -> Bool {
    switch state {
    case .working:
      previousState != .working
    case .needsApproval:
      previousState != .needsApproval
    case .needsInput:
      previousState != .needsInput
    case .blocked:
      previousState != .blocked
    case .idle, .ready:
      false
    }
  }
}

enum CrewRingOrderPolicy {
  static func appendingMissing(taskIDs: [String], to preferredTaskIDs: [String]) -> [String] {
    var orderedTaskIDs: [String] = []
    var knownTaskIDs = Set<String>()
    for taskID in preferredTaskIDs + taskIDs where knownTaskIDs.insert(taskID).inserted {
      orderedTaskIDs.append(taskID)
    }
    return orderedTaskIDs
  }

  static func restoringAtEnd(
    taskID: String,
    preferredTaskIDs: [String]
  ) -> [String] {
    preferredTaskIDs.filter { $0 != taskID } + [taskID]
  }

  static func moving(
    taskID: String,
    toVisibleIndex destinationIndex: Int,
    visibleTaskIDs: [String],
    displayedTaskIDs: [String],
    preferredTaskIDs: [String]
  ) -> [String]? {
    guard let sourceIndex = visibleTaskIDs.firstIndex(of: taskID),
      visibleTaskIDs.indices.contains(destinationIndex),
      sourceIndex != destinationIndex
    else { return nil }

    var reorderedVisibleTaskIDs = visibleTaskIDs
    reorderedVisibleTaskIDs.remove(at: sourceIndex)
    reorderedVisibleTaskIDs.insert(taskID, at: destinationIndex)

    let visibleTaskIDSet = Set(visibleTaskIDs)
    let displayedTaskIDSet = Set(displayedTaskIDs)
    let normalizedPreferredTaskIDs = appendingMissing(
      taskIDs: displayedTaskIDs + visibleTaskIDs,
      to: preferredTaskIDs
    )
    let reorderedDisplayedTaskIDs = reorderedVisibleTaskIDs
      + displayedTaskIDs.filter { !visibleTaskIDSet.contains($0) }
    var reorderedDisplayedIndex = 0
    return normalizedPreferredTaskIDs.map { preferredTaskID in
      guard displayedTaskIDSet.contains(preferredTaskID) else { return preferredTaskID }
      defer { reorderedDisplayedIndex += 1 }
      return reorderedDisplayedTaskIDs[reorderedDisplayedIndex]
    }
  }

  static func addingToVisibleEnd(
    taskID: String,
    visibleLimit: Int,
    displayedTaskIDs: [String],
    preferredTaskIDs: [String]
  ) -> [String]? {
    movingOverflowTask(
      taskID: taskID,
      visibleLimit: visibleLimit,
      destinationIndex: visibleLimit,
      displayedTaskIDs: displayedTaskIDs,
      preferredTaskIDs: preferredTaskIDs
    )
  }

  static func replacingVisibleEnd(
    taskID: String,
    visibleLimit: Int,
    displayedTaskIDs: [String],
    preferredTaskIDs: [String]
  ) -> [String]? {
    movingOverflowTask(
      taskID: taskID,
      visibleLimit: visibleLimit,
      destinationIndex: visibleLimit - 1,
      displayedTaskIDs: displayedTaskIDs,
      preferredTaskIDs: preferredTaskIDs
    )
  }

  private static func movingOverflowTask(
    taskID: String,
    visibleLimit: Int,
    destinationIndex: Int,
    displayedTaskIDs: [String],
    preferredTaskIDs: [String]
  ) -> [String]? {
    guard visibleLimit >= 0,
      destinationIndex >= 0,
      let sourceIndex = displayedTaskIDs.firstIndex(of: taskID),
      sourceIndex >= visibleLimit
    else { return nil }

    var reorderedDisplayedTaskIDs = displayedTaskIDs
    reorderedDisplayedTaskIDs.remove(at: sourceIndex)
    reorderedDisplayedTaskIDs.insert(
      taskID,
      at: min(destinationIndex, reorderedDisplayedTaskIDs.count)
    )

    let displayedTaskIDSet = Set(displayedTaskIDs)
    let normalizedPreferredTaskIDs = appendingMissing(
      taskIDs: displayedTaskIDs,
      to: preferredTaskIDs
    )
    var reorderedDisplayedIndex = 0
    return normalizedPreferredTaskIDs.map { preferredTaskID in
      guard displayedTaskIDSet.contains(preferredTaskID) else { return preferredTaskID }
      defer { reorderedDisplayedIndex += 1 }
      return reorderedDisplayedTaskIDs[reorderedDisplayedIndex]
    }
  }
}

enum StatusItemTaskPolicy {
  static let visibleLimit = 4

  static func statusBarTasks(
    from orderedTasks: [TaskPresentation],
    limit: Int = visibleLimit
  ) -> [TaskPresentation] {
    guard limit > 0 else { return [] }
    return Array(orderedTasks.prefix(limit))
  }

  static func overflowTasks(
    from orderedTasks: [TaskPresentation],
    visibleTasks: [TaskPresentation]
  ) -> [TaskPresentation] {
    let visibleIDs = Set(visibleTasks.map(\.id))
    return orderedTasks.filter { !visibleIDs.contains($0.id) }
  }

  static func menuTasks(
    crewTasks: [TaskPresentation],
    allTasks: [TaskPresentation]
  ) -> [TaskPresentation] {
    let crewIDs = Set(crewTasks.map(\.id))
    return crewTasks + allTasks.filter { !crewIDs.contains($0.id) }
  }

}

enum CodexConnectionDegradation: Equatable {
  case taskCatalogUnavailable
  case liveActivityUnavailable
}

enum CodexConnectionHealth: Equatable {
  case live
  case connecting
  case degraded(CodexConnectionDegradation)
  case incompatible
  case offline

  var requiresStatusBadge: Bool {
    switch self {
    case .degraded, .incompatible: true
    case .live, .connecting, .offline: false
    }
  }

  var showsMenuStatus: Bool {
    self != .live
  }
}

enum CodexConnectionHealthPolicy {
  static func resolve(
    ipc: CodexIPCConnectionState,
    appServer: CodexAppServerConnectionState
  ) -> CodexConnectionHealth {
    if case .incompatible = ipc { return .incompatible }

    switch (ipc, appServer) {
    case (.connected, .running):
      return .live
    case (.connected, .failed):
      return .degraded(.taskCatalogUnavailable)
    case (.connected, .starting), (.connected, .stopped):
      return .connecting
    case (.connecting, .failed):
      return .degraded(.taskCatalogUnavailable)
    case (.connecting, _):
      return .connecting
    case (.disconnected, .running):
      return .degraded(.liveActivityUnavailable)
    case (.disconnected, .starting):
      return .connecting
    case (.disconnected, .stopped), (.disconnected, .failed):
      return .offline
    case (.incompatible, _):
      return .incompatible
    }
  }
}

struct CompletedTaskTiming: Codable, Equatable {
  let turnStartedAt: Date
  let completedAt: Date
  let duration: TimeInterval
}

enum CompletionTimingPolicy {
  static func resolve(
    exactCompletedAt: Date?,
    exactDuration: TimeInterval?,
    previousTurnStartedAt: Date?,
    observedAt: Date
  ) -> CompletedTaskTiming? {
    if let exactCompletedAt, let exactDuration,
      exactDuration.isFinite, exactDuration >= 0
    {
      return CompletedTaskTiming(
        turnStartedAt: exactCompletedAt.addingTimeInterval(-exactDuration),
        completedAt: exactCompletedAt,
        duration: exactDuration
      )
    }

    guard let previousTurnStartedAt else { return nil }
    let duration = observedAt.timeIntervalSince(previousTurnStartedAt)
    guard duration.isFinite, duration >= 0 else { return nil }
    return CompletedTaskTiming(
      turnStartedAt: previousTurnStartedAt,
      completedAt: observedAt,
      duration: duration
    )
  }
}

enum CompletedTaskAutoHidePolicy {
  static func shouldHide(
    _ task: TaskPresentation,
    isEnabled: Bool,
    delay: CompletedTaskAutoHideDelay,
    now: Date
  ) -> Bool {
    shouldHide(
      state: task.state,
      isUnread: task.isUnread,
      completedAt: task.completedAt,
      isEnabled: isEnabled,
      delay: delay,
      now: now
    )
  }

  static func shouldHide(
    state: CodexTaskActivityState,
    isUnread: Bool,
    completedAt: Date?,
    isEnabled: Bool,
    delay: CompletedTaskAutoHideDelay,
    now: Date
  ) -> Bool {
    guard isEnabled, state == .ready, !isUnread, let completedAt else {
      return false
    }
    return now >= completedAt.addingTimeInterval(delay.timeInterval)
  }

  static func nextExpiration(
    among tasks: [TaskPresentation],
    isEnabled: Bool,
    delay: CompletedTaskAutoHideDelay,
    now: Date
  ) -> Date? {
    guard isEnabled else { return nil }
    return tasks.compactMap { task in
      guard task.state == .ready, !task.isUnread, let completedAt = task.completedAt
      else { return nil }
      let expiration = completedAt.addingTimeInterval(delay.timeInterval)
      return expiration > now ? expiration : nil
    }
    .min()
  }
}

enum CompletedTaskTimingPersistence {
  static func load(
    from userDefaults: UserDefaults,
    key: String
  ) -> [String: CompletedTaskTiming] {
    guard let data = userDefaults.data(forKey: key) else { return [:] }
    return (try? JSONDecoder().decode([String: CompletedTaskTiming].self, from: data)) ?? [:]
  }

  static func save(
    _ timings: [String: CompletedTaskTiming],
    to userDefaults: UserDefaults,
    key: String
  ) {
    guard let data = try? JSONEncoder().encode(timings) else { return }
    userDefaults.set(data, forKey: key)
  }
}

struct CodexTaskCatalogSnapshot: Equatable {
  let taskIDs: Set<String>

  init(taskIDs: Set<String>) {
    self.taskIDs = taskIDs
  }

  init(threads: [CodexThreadDescriptor]) {
    taskIDs = Set(threads.map(\.id))
  }
}

struct CodexQueuedFollowUpsChange: Equatable {
  let taskID: String
  let queuedCount: Int
}

enum CodexUsageAvailability: Equatable {
  case pending
  case available
  case unavailable
}

@MainActor
final class CodexActivityModel: ObservableObject {
  private static let completedCrewTaskIDsKey = "completedCrewTaskIDs"
  private static let completedTaskTimingsKey = "completedTaskTimingsV1"

  @Published private(set) var ipcConnectionState: CodexIPCConnectionState = .disconnected
  @Published private(set) var appServerConnectionState: CodexAppServerConnectionState = .stopped
  @Published private(set) var codexUsageAvailability = CodexUsageAvailability.pending
  @Published private(set) var desktopAppState: CodexDesktopAppState
  @Published private(set) var tasks: [TaskPresentation] = []
  @Published private(set) var crewTasks: [TaskPresentation] = []
  @Published private(set) var taskCatalogSnapshot: CodexTaskCatalogSnapshot? = nil
  @Published private(set) var codexUsageSnapshot: CodexUsageSnapshot? = nil
  let queuedFollowUpsChanges = PassthroughSubject<CodexQueuedFollowUpsChange, Never>()

  let settings: MenuBarSettings

  private let ipcClient: CodexIPCClient
  private let appServerClient: CodexAppServerClient
  private let desktopAppController: any CodexDesktopAppControlling
  private let userDefaults: UserDefaults
  private var taskCatalog = CodexTaskCatalog()
  private let conversationReplica = ConversationActivityReplica()
  private let projectIdentityResolver = TaskProjectIdentityResolver()
  private let crewRingState: CrewRingStateStore
  private var completedCrewTaskIDs: Set<String>
  private var completedTaskTimingsByID: [String: CompletedTaskTiming]
  let customizationStore: TaskCustomizationStore
  private var customizationObservation: AnyCancellable?
  private var completedTaskAutoHideSettingsObservation: AnyCancellable?
  private var completedTaskAutoHideWorkItem: DispatchWorkItem?
  #if DEBUG
    private var debugInspectedConversationIDs = Set<String>()
    private var isUsingDebugTaskFixture = false
  #endif

  init(
    ipcClient: CodexIPCClient = CodexIPCClient(),
    appServerClient: CodexAppServerClient = CodexAppServerClient(),
    desktopAppController: any CodexDesktopAppControlling = CodexDesktopAppController(),
    settings: MenuBarSettings = MenuBarSettings(),
    userDefaults: UserDefaults = .standard,
    customizationStore: TaskCustomizationStore? = nil,
    debugTaskFixtureName: String? = nil,
    startsTransportClients: Bool = true
  ) {
    self.ipcClient = ipcClient
    self.appServerClient = appServerClient
    self.desktopAppController = desktopAppController
    self.desktopAppState = desktopAppController.state
    self.settings = settings
    self.userDefaults = userDefaults
    self.crewRingState = CrewRingStateStore(userDefaults: userDefaults)
    self.completedCrewTaskIDs = Set(
      userDefaults.stringArray(forKey: Self.completedCrewTaskIDsKey) ?? []
    )
    self.completedTaskTimingsByID = Self.loadCompletedTaskTimings(from: userDefaults)
    self.customizationStore =
      customizationStore ?? TaskCustomizationStore(userDefaults: userDefaults)
    ipcClient.eventHandler = { [weak self] event in self?.handleIPCEvent(event) }
    appServerClient.eventHandler = { [weak self] event in self?.handleAppServerEvent(event) }
    desktopAppController.stateDidChange = { [weak self] state in
      self?.handleDesktopAppStateChange(state)
    }
    customizationObservation = self.customizationStore.projectCustomizationDidChange
      .sink { [weak self] projectIdentity in
        self?.refreshProjectCustomizationPresentation(for: projectIdentity)
      }
    completedTaskAutoHideSettingsObservation = settings.$automaticallyHidesCompletedTasks
      .combineLatest(settings.$completedTaskAutoHideDelay)
      .dropFirst()
      .sink { [weak self] _ in
        DispatchQueue.main.async {
          self?.refreshCompletedTaskAutoHidePresentation()
        }
      }
    #if DEBUG
      let requestedFixtureName = debugTaskFixtureName
        ?? ProcessInfo.processInfo.environment["CODEX_ECHO_DEBUG_TASK_FIXTURE"]
      if let fixtureName = requestedFixtureName,
        let fixture = Self.debugTaskFixture(named: fixtureName)
      {
        isUsingDebugTaskFixture = true
        tasks = fixture
        rebuildCrewTasks(from: fixture)
        scheduleNextCompletedTaskAutoHide(from: fixture, now: Date())
        taskCatalogSnapshot = CodexTaskCatalogSnapshot(
          taskIDs: Set(fixture.map(\.id))
        )
        switch ProcessInfo.processInfo.environment[
          "CODEX_ECHO_DEBUG_DESKTOP_APP_FIXTURE"
        ] {
        case "not-installed": desktopAppState = .notInstalled
        case "not-running": desktopAppState = .notRunning
        case "launching": desktopAppState = .launching
        case "launch-failed": desktopAppState = .launchFailed
        default: desktopAppState = .running
        }
        switch ProcessInfo.processInfo.environment[
          "CODEX_ECHO_DEBUG_CONNECTION_FIXTURE"
        ] {
        case "degraded-catalog":
          ipcConnectionState = .connected
          appServerConnectionState = .failed(message: "Debug task catalog failure")
        case "degraded-live":
          ipcConnectionState = .disconnected
          appServerConnectionState = .running
        case "incompatible":
          ipcConnectionState = .incompatible(reason: "Debug incompatible version")
          appServerConnectionState = .running
        default:
          ipcConnectionState = .connected
          appServerConnectionState = .running
        }
        if let remainingPercent = ProcessInfo.processInfo.environment[
          "CODEX_ECHO_DEBUG_USAGE_REMAINING_PERCENT"
        ].flatMap(Int.init) {
          let now = Date()
          let availableResetCount = ProcessInfo.processInfo.environment[
            "CODEX_ECHO_DEBUG_AVAILABLE_RESETS"
          ].flatMap(Int.init)
          let rateLimitResetCredits: CodexRateLimitResetCredits? =
            availableResetCount.flatMap { count in
              guard count > 0 else { return nil }
              let requestedDetailCount = ProcessInfo.processInfo.environment[
                "CODEX_ECHO_DEBUG_REPORTED_RESET_EXPIRATIONS"
              ].flatMap(Int.init) ?? count
              let detailCount = min(max(requestedDetailCount, 0), count)
              let expirationDates = detailCount > 0
                ? (1...detailCount).map { index in
                  now.addingTimeInterval(
                    TimeInterval(index * 7 * 24 * 60 * 60)
                  )
                }
                : []
              return CodexRateLimitResetCredits(
                availableCount: count,
                expirationDates: expirationDates
              )
            }
          if let shortWindowRemainingPercent = ProcessInfo.processInfo.environment[
            "CODEX_ECHO_DEBUG_FIVE_HOUR_REMAINING_PERCENT"
          ].flatMap(Int.init) {
            codexUsageSnapshot = CodexUsageSnapshot(
              primaryWindow: CodexRateLimitWindow(
                slot: .primary,
                usedPercent: 100 - shortWindowRemainingPercent,
                windowDurationMinutes: 300,
                resetsAt: now.addingTimeInterval(2 * 60 * 60)
              ),
              secondaryWindow: CodexRateLimitWindow(
                slot: .secondary,
                usedPercent: 100 - remainingPercent,
                windowDurationMinutes: 10_080,
                resetsAt: now.addingTimeInterval(4 * 24 * 60 * 60)
              ),
              rateLimitResetCredits: rateLimitResetCredits
            )
          } else {
            codexUsageSnapshot = CodexUsageSnapshot(
              usedPercent: 100 - remainingPercent,
              windowDurationMinutes: 10_080,
              resetsAt: now.addingTimeInterval(4 * 24 * 60 * 60),
              rateLimitResetCredits: rateLimitResetCredits
            )
          }
        }
        codexUsageAvailability = {
          if codexUsageSnapshot != nil { return .available }
          return appServerConnectionState == .running
            ? .pending
            : .unavailable
        }()
        return
      }
    #endif
    desktopAppController.start()
    if startsTransportClients {
      ipcClient.start()
      appServerClient.start()
    }
  }

  func stop() {
    desktopAppController.stop()
    ipcClient.stop()
    appServerClient.stop()
  }

  var activeTaskCount: Int {
    tasks.filter { $0.state.isActive }.count
  }

  var activeSubagentCount: Int {
    tasks.reduce(0) { $0 + $1.activeSubagentCount }
  }

  var attentionTaskCount: Int {
    tasks.filter { $0.state.requiresAttention }.count
  }

  var hasAttention: Bool {
    attentionTaskCount > 0
  }

  var hasActivity: Bool {
    activeTaskCount > 0 || activeSubagentCount > 0
  }

  var connectionLabel: String {
    switch connectionHealth {
    case .live: "Live"
    case .connecting: "Connecting"
    case .degraded: "Degraded"
    case .incompatible: "Incompatible"
    case .offline: "Scanning"
    }
  }

  var connectionHealth: CodexConnectionHealth {
    CodexConnectionHealthPolicy.resolve(
      ipc: ipcConnectionState,
      appServer: appServerConnectionState
    )
  }

  var statusPresentation: CodexStatusPresentation {
    CodexStatusPresentationPolicy.resolve(
      desktopAppState: desktopAppState,
      connectionHealth: connectionHealth
    )
  }

  var statusBarTasks: [TaskPresentation] {
    guard statusPresentation.showsTaskSignals else { return [] }
    return StatusItemTaskPolicy.statusBarTasks(
      from: crewTasks,
      limit: settings.maximumVisibleTaskCount
    )
  }

  var overflowCrewTasks: [TaskPresentation] {
    guard statusPresentation.showsTaskSignals else { return [] }
    return StatusItemTaskPolicy.overflowTasks(from: crewTasks, visibleTasks: statusBarTasks)
  }

  var menuTasks: [TaskPresentation] {
    guard statusPresentation.showsTaskSignals else { return [] }
    return StatusItemTaskPolicy.menuTasks(crewTasks: statusBarTasks, allTasks: tasks)
  }

  func openTask(_ task: TaskPresentation) {
    guard let url = URL(string: "codex://threads/\(task.id)") else { return }
    NSWorkspace.shared.open(url)
  }

  func openCodex() {
    desktopAppController.openCodex()
  }

  func requestUsageRefresh() {
    appServerClient.requestUsageRefresh()
  }

  func supportDiagnosticsRuntimeSnapshot() -> SupportDiagnosticsRuntimeSnapshot {
    return SupportDiagnosticsRuntimeSnapshot(
      desktopAppState: desktopAppState,
      ipc: ipcClient.diagnosticsSnapshot(),
      appServer: appServerClient.diagnosticsSnapshot()
    )
  }

  func setTaskColorPreference(_ preference: TaskColorPreference, for taskID: String) {
    customizationStore.setTaskColorPreference(preference, for: taskID)
    #if DEBUG
      if updateDebugFixtureTasks({ task in
        guard task.id == taskID else { return task }
        return task.replacingTaskColorPreference(preference)
      }) { return }
    #endif
    rebuildTasks()
  }

  func setProjectColor(_ color: TaskAccentColor?, for identity: TaskProjectIdentity) {
    customizationStore.setParentColor(color, for: identity)
  }

  func setProjectColor(_ color: TaskAccentColor?, for projectID: String) {
    setProjectColor(color, for: .project(projectID))
  }

  func setTaskVoicePreference(_ preference: TaskVoicePreference, for taskID: String) {
    customizationStore.setTaskVoicePreference(preference, for: taskID)
    #if DEBUG
      if updateDebugFixtureTasks({ task in
        guard task.id == taskID else { return task }
        return task.replacingTaskVoicePreference(preference)
      }) { return }
    #endif
    rebuildTasks()
  }

  func setProjectVoice(_ voice: SpokenUpdateVoice?, for identity: TaskProjectIdentity) {
    customizationStore.setParentVoice(voice, for: identity)
  }

  func setProjectVoice(_ voice: SpokenUpdateVoice?, for projectID: String) {
    setProjectVoice(voice, for: .project(projectID))
  }

  private func refreshProjectCustomizationPresentation(for identity: TaskProjectIdentity) {
    let color = customizationStore.parentColor(for: identity)
    let voice = customizationStore.parentVoice(for: identity)
    #if DEBUG
      if updateDebugFixtureTasks({ task in
        guard task.projectIdentity == identity else { return task }
        return task
          .replacingProjectColor(color)
          .replacingProjectVoice(voice)
      }) { return }
    #endif
    rebuildTasks()
  }

  #if DEBUG
    private func updateDebugFixtureTasks(
      _ transform: (TaskPresentation) -> TaskPresentation
    ) -> Bool {
      guard isUsingDebugTaskFixture else { return false }
      tasks = tasks.map(transform)
      crewTasks = crewTasks.map(transform)
      return true
    }
  #endif

  func isCrewRingVisible(for task: TaskPresentation) -> Bool {
    crewTasks.contains { $0.id == task.id }
  }

  func hideCrewRing(for task: TaskPresentation) {
    guard isCrewRingVisible(for: task) else { return }
    crewRingState.hide(task.id)
    rebuildTasks()
  }

  func canMoveCrewRing(taskID: String, direction: CrewRingMoveDirection) -> Bool {
    let visibleTaskIDs = statusBarTasks.map(\.id)
    guard let sourceIndex = visibleTaskIDs.firstIndex(of: taskID) else { return false }
    let destinationIndex = sourceIndex + (direction == .left ? -1 : 1)
    return visibleTaskIDs.indices.contains(destinationIndex)
  }

  @discardableResult
  func moveCrewRing(taskID: String, direction: CrewRingMoveDirection) -> Bool {
    let visibleTaskIDs = statusBarTasks.map(\.id)
    guard let sourceIndex = visibleTaskIDs.firstIndex(of: taskID) else { return false }
    let destinationIndex = sourceIndex + (direction == .left ? -1 : 1)
    return moveCrewRing(taskID: taskID, toVisibleIndex: destinationIndex)
  }

  @discardableResult
  func moveCrewRing(taskID: String, toVisibleIndex destinationIndex: Int) -> Bool {
    guard crewRingState.move(
      taskID,
      toVisibleIndex: destinationIndex,
      visibleTaskIDs: statusBarTasks.map(\.id),
      displayedTaskIDs: crewTasks.map(\.id)
    ) else { return false }

    rebuildCrewTasks(from: tasks)
    return true
  }

  @discardableResult
  func addCrewTaskToMenuBar(taskID: String) -> Bool {
    let visibleLimit = settings.maximumVisibleTaskCount
    guard visibleLimit < MenuBarSettings.supportedMaximumVisibleTaskCount.upperBound,
      crewRingState.addOverflowTaskToVisibleEnd(
        taskID,
        visibleLimit: visibleLimit,
        displayedTaskIDs: crewTasks.map(\.id)
      )
    else { return false }

    rebuildCrewTasks(from: tasks)
    settings.maximumVisibleTaskCount = visibleLimit + 1
    return true
  }

  @discardableResult
  func replaceRightmostCrewTask(taskID: String) -> Bool {
    guard crewRingState.replaceVisibleEnd(
      with: taskID,
      visibleLimit: settings.maximumVisibleTaskCount,
      displayedTaskIDs: crewTasks.map(\.id)
    ) else { return false }

    rebuildCrewTasks(from: tasks)
    return true
  }

  private func handleIPCEvent(_ event: CodexIPCEvent) {
    switch event {
    case .connectionStateChanged(let state):
      ipcConnectionState = state
      if state == .disconnected || isIncompatible(state) {
        conversationReplica.removeAll()
        rebuildTasks()
      }

    case .queuedFollowUpsChanged(let conversationID, let queuedCount):
      queuedFollowUpsChanges.send(
        CodexQueuedFollowUpsChange(
          taskID: conversationID,
          queuedCount: queuedCount
        ))

    case .readStateChanged(let conversationID, let hasUnreadTurn):
      switch conversationReplica.updateReadState(
        conversationID: conversationID,
        hasUnreadTurn: hasUnreadTurn
      ) {
      case .ignored:
        return
      case .snapshotRequired:
        ipcClient.requestSnapshot(for: conversationID)
        return
      case .applied(let transition):
        updateCompletionLatch(
          for: conversationID,
          previousActivity: transition.previous,
          activity: transition.current
        )
        rebuildTasks()
      }

    case .threadArchived(let conversationID):
      taskCatalog.remove(conversationID)
      removeConversation(conversationID)
      if let catalogIDs = taskCatalog.authoritativeIDs {
        ipcClient.setSubscriptions(catalogIDs)
      }
      rebuildTasks()
      appServerClient.requestCatalogRefresh()

    case .threadUnarchived:
      appServerClient.requestCatalogRefresh()

    case .snapshot(let conversationID, let revision, let state):
      guard taskCatalog.admits(conversationID) else { return }
      #if DEBUG
        debugInspectActivitySchema(conversationID: conversationID, state: state)
      #endif
      guard let transition = conversationReplica.replaceSnapshot(
        conversationID: conversationID,
        revision: revision,
        state: state
      ) else { return }
      restoreHiddenCrewTaskForNewActivity(
        conversationID,
        from: transition.previous,
        to: transition.current.state
      )
      updateCompletionLatch(
        for: conversationID,
        previousActivity: transition.previous,
        activity: transition.current
      )
      rebuildTasks()

    case .patches(let conversationID, let baseRevision, let revision, let patches):
      guard taskCatalog.admits(conversationID) else { return }
      switch conversationReplica.applyPatches(
        conversationID: conversationID,
        baseRevision: baseRevision,
        revision: revision,
        patches: patches
      ) {
      case .staleOrMissing:
        ipcClient.requestSnapshot(for: conversationID)
      case .invalidAndEvicted:
        ipcClient.requestSnapshot(for: conversationID)
        rebuildTasks()
      case .applied(let transition):
        restoreHiddenCrewTaskForNewActivity(
          conversationID,
          from: transition.previous,
          to: transition.current.state
        )
        updateCompletionLatch(
          for: conversationID,
          previousActivity: transition.previous,
          activity: transition.current
        )
        rebuildTasks()
      }
    }
  }

  private func handleDesktopAppStateChange(_ state: CodexDesktopAppState) {
    let crossedDesktopProcessBoundary = desktopAppState == .running && state != .running
    if crossedDesktopProcessBoundary {
      ipcClient.resetAfterDesktopProcessBoundary()
    }
    desktopAppState = state
    if state == .running {
      appServerClient.restartIfExecutableChanged()
      return
    }

    // A desktop-process boundary invalidates every live snapshot, even if IPC has not
    // delivered its disconnect yet. Fresh snapshots repopulate these after reconnect.
    conversationReplica.removeAll()
    rebuildTasks()
  }

  private func handleAppServerEvent(_ event: CodexAppServerEvent) {
    switch event {
    case .connectionStateChanged(let state):
      appServerConnectionState = state
      if state != .running {
        taskCatalogSnapshot = nil
        codexUsageSnapshot = nil
      }
      switch state {
      case .starting:
        codexUsageAvailability = .pending
      case .running:
        break
      case .stopped, .failed:
        codexUsageAvailability = .unavailable
      }
    case .threadsChanged(let threads, let projectPathAliases):
      migrateProjectCustomizationAliases(projectPathAliases)
      let catalogIDs = taskCatalog.replace(with: threads)
      removeConversationsMissingFromCatalog(catalogIDs)
      ipcClient.setSubscriptions(catalogIDs)
      rebuildTasks()
      taskCatalogSnapshot = CodexTaskCatalogSnapshot(threads: threads)
    case .usageChanged(let usage):
      codexUsageSnapshot = usage
      codexUsageAvailability = .available
    case .usageUnavailable:
      codexUsageSnapshot = nil
      codexUsageAvailability = .unavailable
    }
  }

  private func rebuildTasks(now: Date = Date()) {
    let rebuiltTasks = conversationReplica.activities.map { activity in
      let catalog = taskCatalog.descriptor(for: activity.id)
      let fallbackCWD = catalog?.cwd ?? activity.cwd
      let projectIdentity = projectIdentityResolver.resolve(
        projectContext: catalog?.projectContext,
        fallbackCWD: fallbackCWD
      )
      let presentationState = presentationState(for: activity)
      let completedTiming = completedTaskTimingsByID[activity.id]
      return TaskPresentation(
        id: activity.id,
        title: nonEmpty(activity.title) ?? catalog?.title ?? "Untitled task",
        projectIdentity: projectIdentity,
        state: presentationState,
        isUnread: activity.isUnread,
        activeSubagentCount: activity.activeSubagentCount,
        updatedAt: activity.updatedAt ?? catalog?.updatedAt,
        turnStartedAt: activity.turnStartedAt,
        currentActivity: activity.currentActivity,
        completedAt: completedTiming?.completedAt,
        completedDuration: completedTiming?.duration,
        taskColor: customizationStore.taskColor(for: activity.id),
        projectColor: customizationStore.parentColor(for: projectIdentity),
        usesSystemTaskColor:
          customizationStore.taskColorPreference(for: activity.id) == .system,
        taskVoice: customizationStore.taskVoice(for: activity.id),
        projectVoice: customizationStore.parentVoice(for: projectIdentity),
        usesDefaultTaskVoice:
          customizationStore.taskVoicePreference(for: activity.id) == .defaultVoice
      )
    }
    .sorted { left, right in
      let leftPriority = priority(left.state)
      let rightPriority = priority(right.state)
      if leftPriority != rightPriority { return leftPriority < rightPriority }
      return (left.updatedAt ?? .distantPast) > (right.updatedAt ?? .distantPast)
    }
    if tasks != rebuiltTasks {
      tasks = rebuiltTasks
    }
    rebuildCrewTasks(from: rebuiltTasks, now: now)
    scheduleNextCompletedTaskAutoHide(from: rebuiltTasks, now: now)
  }

  private func migrateProjectCustomizationAliases(
    _ projectPathAliases: [CodexProjectPathAlias]
  ) {
    let aliases: [(legacyProjectID: String, canonicalProjectID: String)] =
      projectPathAliases.compactMap { alias in
        guard
          let canonicalProjectID = ProjectColorIdentity.key(for: alias.canonicalPath),
          let legacyProjectID = ProjectColorIdentity.key(for: alias.assignmentPath)
        else { return nil }
        return (legacyProjectID, canonicalProjectID)
      }
    customizationStore.migrateProjectCustomizations(aliases)
  }

  private func rebuildCrewTasks(
    from tasks: [TaskPresentation],
    now: Date = Date()
  ) {
    let displayedTasks = tasks.filter {
      crewRingState.shouldDisplay($0.id, showsByDefault: $0.state.showsCrewRing)
        && !CompletedTaskAutoHidePolicy.shouldHide(
          $0,
          isEnabled: settings.automaticallyHidesCompletedTasks,
          delay: settings.completedTaskAutoHideDelay,
          now: now
        )
    }
    let orderedTaskIDs = crewRingState.orderedTaskIDs(for: displayedTasks.map(\.id))

    let tasksByID = Dictionary(uniqueKeysWithValues: displayedTasks.map { ($0.id, $0) })
    let rebuiltCrewTasks = orderedTaskIDs.compactMap { tasksByID[$0] }
    if crewTasks != rebuiltCrewTasks {
      crewTasks = rebuiltCrewTasks
    }
  }

  private func scheduleNextCompletedTaskAutoHide(
    from tasks: [TaskPresentation],
    now: Date
  ) {
    completedTaskAutoHideWorkItem?.cancel()
    completedTaskAutoHideWorkItem = nil
    guard
      let expiration = CompletedTaskAutoHidePolicy.nextExpiration(
        among: tasks,
        isEnabled: settings.automaticallyHidesCompletedTasks,
        delay: settings.completedTaskAutoHideDelay,
        now: now
      )
    else { return }

    let workItem = DispatchWorkItem { [weak self] in
      self?.rebuildTasks()
    }
    completedTaskAutoHideWorkItem = workItem
    DispatchQueue.main.asyncAfter(
      deadline: .now() + expiration.timeIntervalSince(now),
      execute: workItem
    )
  }

  private func refreshCompletedTaskAutoHidePresentation() {
    #if DEBUG
      if isUsingDebugTaskFixture {
        let now = Date()
        rebuildCrewTasks(from: tasks, now: now)
        scheduleNextCompletedTaskAutoHide(from: tasks, now: now)
        return
      }
    #endif
    rebuildTasks()
  }

  private func removeConversationsMissingFromCatalog(_ catalogIDs: Set<String>) {
    let removedIDs = conversationReplica.removeConversations(notIn: catalogIDs)
    if !removedIDs.isEmpty {
      for id in removedIDs {
        completedCrewTaskIDs.remove(id)
        completedTaskTimingsByID.removeValue(forKey: id)
      }
      crewRingState.removeFromCurrentOrder(taskIDs: removedIDs)
      persistCompletedCrewTaskIDs()
      persistCompletedTaskTimings()
    }

    crewRingState.retain(taskIDs: catalogIDs)

    let previousCompletedCount = completedCrewTaskIDs.count
    completedCrewTaskIDs.formIntersection(catalogIDs)
    if completedCrewTaskIDs.count != previousCompletedCount { persistCompletedCrewTaskIDs() }
  }

  private func removeConversation(_ conversationID: String) {
    conversationReplica.remove(conversationID)

    crewRingState.remove(conversationID)
    if completedCrewTaskIDs.remove(conversationID) != nil { persistCompletedCrewTaskIDs() }
    if completedTaskTimingsByID.removeValue(forKey: conversationID) != nil {
      persistCompletedTaskTimings()
    }
  }

  private func restoreHiddenCrewTaskForNewActivity(
    _ conversationID: String,
    from previousActivity: ConversationActivity?,
    to state: CodexTaskActivityState,
    observedAt: Date = Date()
  ) {
    guard CrewRingVisibilityPolicy.shouldRestoreHiddenRing(
      from: previousActivity?.state,
      to: state
    ) else { return }
    let wasAutomaticallyHidden = previousActivity.map { activity in
      CompletedTaskAutoHidePolicy.shouldHide(
        state: presentationState(for: activity),
        isUnread: activity.isUnread,
        completedAt: completedTaskTimingsByID[conversationID]?.completedAt,
        isEnabled: settings.automaticallyHidesCompletedTasks,
        delay: settings.completedTaskAutoHideDelay,
        now: observedAt
      )
    } ?? false
    _ = crewRingState.restoreAtEnd(
      conversationID,
      wasAutomaticallyHidden: wasAutomaticallyHidden
    )
  }

  private func updateCompletionLatch(
    for conversationID: String,
    previousActivity: ConversationActivity?,
    activity: ConversationActivity,
    observedAt: Date = Date()
  ) {
    let previousState = previousActivity?.state
    let state = activity.state
    let shouldLatchCompletion: Bool
    switch state {
    case .ready:
      shouldLatchCompletion = true
    case .idle:
      shouldLatchCompletion = previousState == .working || previousState == .ready
    case .working, .needsApproval, .needsInput, .blocked:
      shouldLatchCompletion = false
    }

    if previousState == .working, shouldLatchCompletion {
      appServerClient.requestUsageRefresh()
    }

    let completionLatchChanged: Bool
    if shouldLatchCompletion && !crewRingState.isHidden(conversationID) {
      completionLatchChanged = completedCrewTaskIDs.insert(conversationID).inserted
    } else if state != .idle {
      completionLatchChanged = completedCrewTaskIDs.remove(conversationID) != nil
    } else {
      completionLatchChanged = false
    }
    if completionLatchChanged { persistCompletedCrewTaskIDs() }

    var timingChanged = false
    if shouldLatchCompletion,
      let timing = CompletionTimingPolicy.resolve(
        exactCompletedAt: activity.lastCompletedTurnAt,
        exactDuration: activity.lastCompletedTurnDuration,
        previousTurnStartedAt: previousActivity?.turnStartedAt,
        observedAt: observedAt
      ),
      completedTaskTimingsByID[conversationID] != timing
    {
      completedTaskTimingsByID[conversationID] = timing
      timingChanged = true
    } else if state != .idle && !shouldLatchCompletion {
      timingChanged = completedTaskTimingsByID.removeValue(forKey: conversationID) != nil
    }
    if timingChanged { persistCompletedTaskTimings() }
  }

  private func presentationState(for activity: ConversationActivity) -> CodexTaskActivityState {
    if activity.state == .idle, completedCrewTaskIDs.contains(activity.id) { return .ready }
    return activity.state
  }

  private func persistCompletedCrewTaskIDs() {
    userDefaults.set(Array(completedCrewTaskIDs).sorted(), forKey: Self.completedCrewTaskIDsKey)
  }

  private static func loadCompletedTaskTimings(
    from userDefaults: UserDefaults
  ) -> [String: CompletedTaskTiming] {
    CompletedTaskTimingPersistence.load(
      from: userDefaults,
      key: completedTaskTimingsKey
    )
  }

  private func persistCompletedTaskTimings() {
    CompletedTaskTimingPersistence.save(
      completedTaskTimingsByID,
      to: userDefaults,
      key: Self.completedTaskTimingsKey
    )
  }

  private func isIncompatible(_ state: CodexIPCConnectionState) -> Bool {
    if case .incompatible = state { return true }
    return false
  }

  private func nonEmpty(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
      return nil
    }
    return value
  }

  private func priority(_ state: CodexTaskActivityState) -> Int {
    switch state {
    case .needsApproval: 0
    case .needsInput: 1
    case .blocked: 2
    case .working: 3
    case .ready: 4
    case .idle: 5
    }
  }

  #if DEBUG
    private func debugInspectActivitySchema(
      conversationID: String,
      state: JSONValue
    ) {
      guard
        ProcessInfo.processInfo.environment[
          "CODEX_ECHO_DEBUG_INSPECT_ACTIVITY"
        ] == "1",
        debugInspectedConversationIDs.count < 3,
        debugInspectedConversationIDs.insert(conversationID).inserted
      else { return }

      let topLevelKeys = state.objectValue?.keys.sorted() ?? []
      let runtimeKeys = state["threadRuntimeStatus"]?.objectValue?.keys.sorted() ?? []
      let entities =
        state.value(at: "turnHistory", "history", "entitiesByKey")?
        .objectValue?.values ?? [String: JSONValue]().values
      let activeTurn =
        entities
        .filter { $0["status"]?.stringValue == "inProgress" }
        .max {
          ($0["turnStartedAtMs"]?.numberValue ?? 0)
            < ($1["turnStartedAtMs"]?.numberValue ?? 0)
        }
      let turnKeys = activeTurn?.objectValue?.keys.sorted() ?? []
      let itemSummaries = (activeTurn?["items"]?.arrayValue ?? []).prefix(20).map { item in
        let type = item["type"]?.stringValue ?? "-"
        let keys = item.objectValue?.keys.sorted().joined(separator: ",") ?? "-"
        return "\(type){\(keys)}"
      }
      print(
        "ACTIVITY_SCHEMA conversation=\(conversationID) "
          + "unread=\(state["hasUnreadTurn"]?.boolValue == true) "
          + "unreadCount=\(state["unreadMessageCount"]?.numberValue ?? 0) "
          + "top=\(topLevelKeys) runtime=\(runtimeKeys) "
          + "turn=\(turnKeys) items=\(itemSummaries)"
      )
    }

    private static func debugTaskFixture(named name: String) -> [TaskPresentation]? {
      if name == "idle" { return [] }
      let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
      let debugNow = Date()
      if name == "completion-unread" {
        return [
          TaskPresentation(
            id: "debug-complete-unread",
            title: "Unread completed task",
            project: "codex-echo",
            state: .ready,
            isUnread: true,
            activeSubagentCount: 0,
            updatedAt: timestamp.addingTimeInterval(1),
            completedAt: debugNow.addingTimeInterval(-30),
            completedDuration: 245
          ),
          TaskPresentation(
            id: "debug-complete-read",
            title: "Read completed task",
            project: "codex-echo",
            state: .ready,
            activeSubagentCount: 0,
            updatedAt: timestamp,
            completedAt: debugNow.addingTimeInterval(-60),
            completedDuration: 95
          ),
        ]
      }
      if name == "completion-retention" {
        return [
          TaskPresentation(
            id: "debug-expired-unread",
            title: "Expired unread completion",
            project: "codex-echo",
            state: .ready,
            isUnread: true,
            activeSubagentCount: 0,
            updatedAt: timestamp.addingTimeInterval(1),
            completedAt: debugNow.addingTimeInterval(-1_800),
            completedDuration: 245
          ),
          TaskPresentation(
            id: "debug-expired-read",
            title: "Expired read completion",
            project: "codex-echo",
            state: .ready,
            activeSubagentCount: 0,
            updatedAt: timestamp,
            completedAt: debugNow.addingTimeInterval(-1_800),
            completedDuration: 95
          ),
        ]
      }
      if name == "context-compaction" {
        return [
          TaskPresentation(
            id: "debug-context-compaction",
            title: "Context compaction activity",
            project: "codex-echo",
            state: .working,
            activeSubagentCount: 0,
            updatedAt: timestamp,
            turnStartedAt: debugNow.addingTimeInterval(-30),
            currentActivity: .compactingContext
          )
        ]
      }
      if name == "ring-contours" {
        let contours: [(String, String, CodexTaskCurrentActivity)] = [
          ("circular", "Writing response — circular", .writingResponse),
          ("smooth-wave", "Thinking — smooth wave", .thinking),
          ("faceted-wave", "Editing files — faceted wave", .editingFiles),
        ]
        return contours.enumerated().map { index, contour in
          TaskPresentation(
            id: "debug-ring-contour-\(contour.0)",
            title: contour.1,
            project: "codex-echo",
            state: .working,
            activeSubagentCount: 0,
            updatedAt: timestamp.addingTimeInterval(Double(contours.count - index)),
            turnStartedAt: debugNow.addingTimeInterval(-90),
            currentActivity: contour.2
          )
        }
      }
      if name == "product-hunt" {
        return [
          TaskPresentation(
            id: "showcase-launch-experience",
            title: "Craft the launch experience",
            project: "codex-echo",
            projectID: "/Users/demo/codex-echo",
            state: .working,
            activeSubagentCount: 2,
            updatedAt: timestamp.addingTimeInterval(6),
            turnStartedAt: debugNow.addingTimeInterval(-245),
            currentActivity: .thinking,
            projectColor: .teal,
            usesSystemTaskColor: true
          ),
          TaskPresentation(
            id: "showcase-onboarding-flow",
            title: "Polish the onboarding flow",
            project: "launch-assets",
            projectID: "/Users/demo/launch-assets",
            state: .working,
            activeSubagentCount: 0,
            updatedAt: timestamp.addingTimeInterval(5),
            turnStartedAt: debugNow.addingTimeInterval(-95),
            currentActivity: .editingFiles,
            projectColor: .orange,
            usesSystemTaskColor: true
          ),
          TaskPresentation(
            id: "showcase-choose-hero-message",
            title: "Choose the hero message",
            project: "launch-assets",
            projectID: "/Users/demo/launch-assets",
            state: .needsInput,
            activeSubagentCount: 0,
            updatedAt: timestamp.addingTimeInterval(4),
            projectColor: .orange
          ),
          TaskPresentation(
            id: "showcase-prepare-release-candidate",
            title: "Prepare the release candidate",
            project: "codex-echo",
            projectID: "/Users/demo/codex-echo",
            state: .ready,
            isUnread: true,
            activeSubagentCount: 0,
            updatedAt: timestamp.addingTimeInterval(3),
            completedAt: debugNow.addingTimeInterval(-30),
            completedDuration: 245,
            projectColor: .teal
          ),
          TaskPresentation(
            id: "showcase-approve-production-deployment",
            title: "Approve production deployment",
            project: "launch-assets",
            projectID: "/Users/demo/launch-assets",
            state: .needsApproval,
            activeSubagentCount: 0,
            updatedAt: timestamp.addingTimeInterval(2),
            projectColor: .orange,
            usesSystemTaskColor: true
          ),
          TaskPresentation(
            id: "showcase-unblock-signing-pipeline",
            title: "Unblock the signing pipeline",
            project: "codex-echo",
            projectID: "/Users/demo/codex-echo",
            state: .blocked,
            activeSubagentCount: 0,
            updatedAt: timestamp.addingTimeInterval(1),
            taskColor: .red,
            projectColor: .teal
          ),
        ]
      }
      if name == "no-project-customizations" {
        return [
          TaskPresentation(
            id: "debug-no-project-one",
            title: "No Project task one",
            projectIdentity: .noProject,
            state: .working,
            activeSubagentCount: 0,
            updatedAt: timestamp.addingTimeInterval(1),
            turnStartedAt: debugNow.addingTimeInterval(-90),
            currentActivity: .thinking
          ),
          TaskPresentation(
            id: "debug-no-project-two",
            title: "No Project task two",
            projectIdentity: .noProject,
            state: .working,
            activeSubagentCount: 0,
            updatedAt: timestamp,
            turnStartedAt: debugNow.addingTimeInterval(-45),
            currentActivity: .writingResponse
          ),
        ]
      }
      if name == "color-palette" {
        let colors = Array(TaskAccentColor.allCases.prefix(8))
        let states: [CodexTaskActivityState] = [
          .working, .ready, .needsApproval, .needsInput,
          .blocked, .ready, .working, .ready,
        ]
        return colors.enumerated().map { index, color in
          let projectName = index < 4 ? "codex-echo" : "design-lab"
          let projectID = index < 4
            ? "/tmp/codex-echo"
            : "/tmp/design-lab"
          return TaskPresentation(
            id: "debug-color-\(color.rawValue)",
            title: "\(color.displayName) task color",
            project: projectName,
            projectID: projectID,
            state: states[index],
            isUnread: index == 5,
            activeSubagentCount: index == 6 ? 2 : 0,
            updatedAt: timestamp.addingTimeInterval(Double(colors.count - index)),
            turnStartedAt: states[index] == .working
              ? debugNow.addingTimeInterval(-90)
              : nil,
            currentActivity: states[index] == .working ? .thinking : nil,
            completedAt: states[index] == .ready
              ? debugNow.addingTimeInterval(-30)
              : nil,
            completedDuration: states[index] == .ready ? 95 : nil,
            taskColor: color,
            projectColor: index < 4 ? .blue : .purple
          )
        }
      }
      if name == "maximum-visible" {
        let states: [CodexTaskActivityState] = [
          .working, .ready, .needsApproval, .needsInput, .blocked,
        ]
        return (1...17).map { index in
          let state = states[(index - 1) % states.count]
          return TaskPresentation(
            id: "debug-maximum-visible-\(index)",
            title: "Maximum visible task \(index)",
            project: "codex-echo",
            state: state,
            isUnread: state == .ready,
            activeSubagentCount: index == 1 ? 2 : 0,
            updatedAt: timestamp.addingTimeInterval(Double(18 - index)),
            turnStartedAt: state == .working
              ? debugNow.addingTimeInterval(-Double(index * 10))
              : nil,
            currentActivity: state == .working ? .thinking : nil,
            completedAt: state == .ready
              ? debugNow.addingTimeInterval(-Double(index * 5))
              : nil,
            completedDuration: state == .ready ? Double(index * 12) : nil
          )
        }
      }
      guard name == "overflow-attention" else { return nil }
      return [
        TaskPresentation(
          id: "debug-working-one",
          title: "Build the menu bar signal",
          project: "codex-echo",
          state: .working,
          activeSubagentCount: 0,
          updatedAt: timestamp.addingTimeInterval(6),
          turnStartedAt: debugNow.addingTimeInterval(-245),
          currentActivity: .thinking
        ),
        TaskPresentation(
          id: "debug-complete",
          title: "Review completed task behavior",
          project: "codex-echo",
          state: .ready,
          activeSubagentCount: 0,
          updatedAt: timestamp.addingTimeInterval(5),
          completedAt: debugNow.addingTimeInterval(-30),
          completedDuration: 245
        ),
        TaskPresentation(
          id: "debug-working-two",
          title: "Verify the native task menu",
          project: "codex-echo",
          state: .working,
          activeSubagentCount: 2,
          updatedAt: timestamp.addingTimeInterval(4),
          turnStartedAt: debugNow.addingTimeInterval(-95),
          currentActivity: .runningCommand
        ),
        TaskPresentation(
          id: "debug-ready-two",
          title: "Inspect overflow targeting",
          project: "codex-echo",
          state: .ready,
          isUnread: true,
          activeSubagentCount: 0,
          updatedAt: timestamp.addingTimeInterval(3),
          completedAt: debugNow.addingTimeInterval(-10),
          completedDuration: 45
        ),
        TaskPresentation(
          id: "debug-input",
          title: "Choose the overflow interaction",
          project: "codex-echo",
          state: .needsInput,
          activeSubagentCount: 0,
          updatedAt: timestamp.addingTimeInterval(2)
        ),
        TaskPresentation(
          id: "debug-approval",
          title: "Approve the release check",
          project: "codex-echo",
          state: .needsApproval,
          activeSubagentCount: 0,
          updatedAt: timestamp.addingTimeInterval(1)
        ),
      ]
    }
  #endif
}
