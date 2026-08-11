import CodexIPC
import Foundation

enum SpokenAnnouncementCategory: String, CaseIterable, Identifiable {
  case startup
  case task
  case capacity
  case subagent
  case connection

  var id: Self { self }

  var title: String {
    return switch self {
    case .startup: "Startup"
    case .task: "Task"
    case .capacity: "Capacity"
    case .subagent: "Subagent"
    case .connection: "Connection"
    }
  }
}

struct SpokenAnnouncementDefinition: Equatable {
  let category: SpokenAnnouncementCategory
  let announcementText: String
  let defaultAlertSound: SpokenAnnouncementAlertSound
  let sourceStateAliases: [String]

  init(
    category: SpokenAnnouncementCategory,
    announcementText: String,
    defaultAlertSound: SpokenAnnouncementAlertSound,
    sourceStateAliases: [String] = []
  ) {
    self.category = category
    self.announcementText = announcementText
    self.defaultAlertSound = defaultAlertSound
    self.sourceStateAliases = sourceStateAliases
  }

  var defaultRule: SpokenAnnouncementRule {
    SpokenAnnouncementRule(
      speaks: true,
      alertSound: defaultAlertSound
    )
  }
}

enum SpokenAnnouncementEvent: String, CaseIterable, Codable, Identifiable {
  case startupSummary
  case taskStarted
  case taskCompleted
  case inputRequired
  case approvalRequired
  case taskError
  case executionResumed
  case directiveQueued
  case taskProcessing
  case taskAnalysis
  case taskPlanning
  case taskCommandExecution
  case taskFileModification
  case taskAgentCoordination
  case taskPermissionCheck
  case taskResponseGeneration
  case taskContextCompaction
  case usageChanged
  case usageTwentyPercent
  case usageTenPercent
  case usageFivePercent
  case usageOnePercent
  case usageDepleted
  case usageIncreased
  case subagentBecameActive
  case monitoringInterrupted
  case monitoringRestored
  case applicationOffline
  case applicationOnline

  var id: Self { self }

  private static let taskActivityEventPairs:
    [(activity: CodexTaskCurrentActivity, event: SpokenAnnouncementEvent)] =
      [
        (.working, .taskProcessing),
        (.thinking, .taskAnalysis),
        (.planning, .taskPlanning),
        (.runningCommand, .taskCommandExecution),
        (.editingFiles, .taskFileModification),
        (.coordinatingAgents, .taskAgentCoordination),
        (.checkingPermissions, .taskPermissionCheck),
        (.writingResponse, .taskResponseGeneration),
        (.compactingContext, .taskContextCompaction),
      ]

  static var taskActivityEvents: [SpokenAnnouncementEvent] {
    taskActivityEventPairs.map(\.event)
  }

  static func event(
    for activity: CodexTaskCurrentActivity
  ) -> SpokenAnnouncementEvent {
    guard
      let event = taskActivityEventPairs.first(where: {
        $0.activity == activity
      })?.event
    else {
      preconditionFailure(
        "Missing spoken announcement event for \(activity.rawValue)"
      )
    }
    return event
  }

  private var taskActivity: CodexTaskCurrentActivity? {
    Self.taskActivityEventPairs.first(where: {
      $0.event == self
    })?.activity
  }

  var definition: SpokenAnnouncementDefinition {
    if let taskActivity {
      return SpokenAnnouncementDefinition(
        category: .task,
        announcementText: SpokenUpdateCopy.activityStatus(taskActivity),
        defaultAlertSound: .none
      )
    }

    return switch self {
    case .startupSummary:
      SpokenAnnouncementDefinition(
        category: .startup,
        announcementText: AppPresentationCopy.startupAnnouncement,
        defaultAlertSound: .onePip
      )
    case .taskStarted:
      SpokenAnnouncementDefinition(
        category: .task,
        announcementText: "Task initiated.",
        defaultAlertSound: .none
      )
    case .taskCompleted:
      SpokenAnnouncementDefinition(
        category: .task,
        announcementText: "Task complete.",
        defaultAlertSound: .onePip,
        sourceStateAliases: ["Ready"]
      )
    case .inputRequired:
      SpokenAnnouncementDefinition(
        category: .task,
        announcementText: "Input required.",
        defaultAlertSound: .twoPips,
        sourceStateAliases: [
          "Needs Input",
          "needsInput",
          "waitingOnUserInput",
        ]
      )
    case .approvalRequired:
      SpokenAnnouncementDefinition(
        category: .task,
        announcementText: "Approval required.",
        defaultAlertSound: .twoPips,
        sourceStateAliases: [
          "Needs Approval",
          "needsApproval",
          "waitingOnApproval",
        ]
      )
    case .taskError:
      SpokenAnnouncementDefinition(
        category: .task,
        announcementText: "Task error.",
        defaultAlertSound: .twoPips,
        sourceStateAliases: [
          "Blocked",
          "systemError",
        ]
      )
    case .executionResumed:
      SpokenAnnouncementDefinition(
        category: .task,
        announcementText: "Execution resumed.",
        defaultAlertSound: .none
      )
    case .directiveQueued:
      SpokenAnnouncementDefinition(
        category: .task,
        announcementText: "Directive queued.",
        defaultAlertSound: .none
      )
    case .taskProcessing,
      .taskAnalysis,
      .taskPlanning,
      .taskCommandExecution,
      .taskFileModification,
      .taskAgentCoordination,
      .taskPermissionCheck,
      .taskResponseGeneration,
      .taskContextCompaction:
      preconditionFailure("Task activity definition was not resolved")
    case .usageChanged:
      SpokenAnnouncementDefinition(
        category: .capacity,
        announcementText: "Codex capacity, 67 percent remaining.",
        defaultAlertSound: .none
      )
    case .usageTwentyPercent:
      SpokenAnnouncementDefinition(
        category: .capacity,
        announcementText: "Codex capacity, 20 percent remaining.",
        defaultAlertSound: .none
      )
    case .usageTenPercent:
      SpokenAnnouncementDefinition(
        category: .capacity,
        announcementText: "Codex capacity, 10 percent remaining.",
        defaultAlertSound: .none
      )
    case .usageFivePercent:
      SpokenAnnouncementDefinition(
        category: .capacity,
        announcementText: "Codex capacity, 5 percent remaining.",
        defaultAlertSound: .onePip
      )
    case .usageOnePercent:
      SpokenAnnouncementDefinition(
        category: .capacity,
        announcementText: "Codex capacity, 1 percent remaining.",
        defaultAlertSound: .onePip
      )
    case .usageDepleted:
      SpokenAnnouncementDefinition(
        category: .capacity,
        announcementText: "Codex capacity depleted.",
        defaultAlertSound: .onePip
      )
    case .usageIncreased:
      SpokenAnnouncementDefinition(
        category: .capacity,
        announcementText: "Codex capacity increased to 100 percent.",
        defaultAlertSound: .none
      )
    case .subagentBecameActive:
      SpokenAnnouncementDefinition(
        category: .subagent,
        announcementText: "Sub-agent active.",
        defaultAlertSound: .none
      )
    case .monitoringInterrupted:
      SpokenAnnouncementDefinition(
        category: .connection,
        announcementText: "Codex monitoring interrupted.",
        defaultAlertSound: .onePip
      )
    case .monitoringRestored:
      SpokenAnnouncementDefinition(
        category: .connection,
        announcementText: "Codex monitoring restored.",
        defaultAlertSound: .none
      )
    case .applicationOffline:
      SpokenAnnouncementDefinition(
        category: .connection,
        announcementText: "Codex application offline.",
        defaultAlertSound: .onePip
      )
    case .applicationOnline:
      SpokenAnnouncementDefinition(
        category: .connection,
        announcementText: "Codex application online.",
        defaultAlertSound: .onePip
      )
    }
  }

  var category: SpokenAnnouncementCategory {
    definition.category
  }

  var announcementText: String {
    definition.announcementText
  }

  var settingsText: String {
    switch self {
    case .usageChanged:
      "Codex capacity, [remaining] percent remaining."
    case .usageIncreased:
      "Codex capacity increased to [remaining] percent."
    default:
      announcementText
    }
  }

  var searchTerms: [String] {
    var terms = [
      category.title,
      settingsText,
      announcementText,
    ] + definition.sourceStateAliases
    if let taskActivity {
      terms.append(contentsOf: [
        taskActivity.displayLabel,
        taskActivity.rawValue,
      ])
    }
    return terms
  }

  static func events(
    in category: SpokenAnnouncementCategory
  ) -> [SpokenAnnouncementEvent] {
    allCases.filter { $0.category == category }
  }
}

struct SpokenAnnouncementSearchResult: Equatable, Identifiable {
  let event: SpokenAnnouncementEvent

  var id: SpokenAnnouncementEvent {
    event
  }
}

enum StartupAnnouncementInformation: String, CaseIterable, Codable, Identifiable {
  case codexCapacity
  case activeTasks

  var id: Self { self }

  var announcementText: String {
    switch self {
    case .activeTasks: "2 active task signals detected."
    case .codexCapacity: "Codex capacity, 67 percent remaining."
    }
  }

  var settingsText: String {
    switch self {
    case .codexCapacity:
      "Codex capacity, [remaining] percent remaining."
    case .activeTasks:
      "[count] active task signals detected."
    }
  }

  fileprivate var searchAliases: [String] {
    switch self {
    case .codexCapacity: ["Codex Capacity"]
    case .activeTasks: ["Running Tasks"]
    }
  }
}

enum SpokenAnnouncementSearch {
  static func hasQuery(_ query: String) -> Bool {
    !normalizedQuery(query).isEmpty
  }

  static func results(
    in category: SpokenAnnouncementCategory,
    matching query: String
  ) -> [SpokenAnnouncementSearchResult] {
    let query = normalizedQuery(query)
    return SpokenAnnouncementEvent.events(in: category).compactMap { event in
      guard query.isEmpty
        || matches(query, terms: baseSearchTerms(for: event))
      else {
        return nil
      }
      return SpokenAnnouncementSearchResult(event: event)
    }
  }

  static func startupInformation(
    matching query: String
  ) -> [StartupAnnouncementInformation] {
    let query = normalizedQuery(query)
    guard !query.isEmpty else {
      return StartupAnnouncementInformation.allCases
    }
    return StartupAnnouncementInformation.allCases.filter { information in
      matches(
        query,
        terms: [
          SpokenAnnouncementCategory.startup.title,
          information.settingsText,
          information.announcementText,
        ] + information.searchAliases
      )
    }
  }

  static func normalizedQuery(_ query: String) -> String {
    query.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func baseSearchTerms(
    for event: SpokenAnnouncementEvent
  ) -> [String] {
    event.searchTerms
  }

  private static func matches(
    _ query: String,
    terms: [String]
  ) -> Bool {
    terms.contains { $0.localizedCaseInsensitiveContains(query) }
  }
}

enum SpokenAnnouncementAlertSound: String, CaseIterable, Codable, Identifiable {
  case none
  case onePip
  case twoPips

  var id: Self { self }

  var title: String {
    switch self {
    case .none: "None"
    case .onePip: "1 Pip"
    case .twoPips: "2 Pips"
    }
  }
}

struct SpokenAnnouncementRule: Codable, Equatable {
  var speaks: Bool
  var alertSound: SpokenAnnouncementAlertSound

  static let silent = SpokenAnnouncementRule(
    speaks: false,
    alertSound: .none
  )
}

enum SpokenAnnouncementBulkSpeakState: Equatable {
  case allOn
  case allOff
  case mixed
}

struct SpokenAnnouncementConfiguration: Codable, Equatable {
  private var rulesByEventID: [String: SpokenAnnouncementRule]
  private var startupInformationIDs: Set<String>

  static let defaults = SpokenAnnouncementConfiguration(
    rulesByEventID: Dictionary(
      uniqueKeysWithValues: SpokenAnnouncementEvent.allCases.map { event in
        (event.rawValue, event.definition.defaultRule)
      }
    ),
    startupInformationIDs: Set(
      StartupAnnouncementInformation.allCases.map(\.rawValue)
    )
  )

  func rule(for event: SpokenAnnouncementEvent) -> SpokenAnnouncementRule {
    rulesByEventID[event.rawValue] ?? .silent
  }

  var isValid: Bool {
    Set(rulesByEventID.keys)
      == Set(SpokenAnnouncementEvent.allCases.map(\.rawValue))
      && startupInformationIDs.isSubset(
        of: Set(StartupAnnouncementInformation.allCases.map(\.rawValue))
      )
  }

  mutating func setSpeaks(
    _ speaks: Bool,
    for event: SpokenAnnouncementEvent
  ) {
    var rule = rule(for: event)
    rule.speaks = speaks
    rulesByEventID[event.rawValue] = rule
  }

  mutating func setAlertSound(
    _ alertSound: SpokenAnnouncementAlertSound,
    for event: SpokenAnnouncementEvent
  ) {
    var rule = rule(for: event)
    rule.alertSound = alertSound
    rulesByEventID[event.rawValue] = rule
  }

  var allEventsSpeakState: SpokenAnnouncementBulkSpeakState {
    let speakingEventCount = SpokenAnnouncementEvent.allCases.reduce(0) {
      $0 + (rule(for: $1).speaks ? 1 : 0)
    }
    if speakingEventCount == 0 {
      return .allOff
    }
    if speakingEventCount == SpokenAnnouncementEvent.allCases.count {
      return .allOn
    }
    return .mixed
  }

  mutating func setAllEventsSpeak(_ speaks: Bool) {
    for event in SpokenAnnouncementEvent.allCases {
      setSpeaks(speaks, for: event)
    }
  }

  var allEventsAlertSound: SpokenAnnouncementAlertSound? {
    guard let firstEvent = SpokenAnnouncementEvent.allCases.first else {
      return nil
    }
    let alertSound = rule(for: firstEvent).alertSound
    return SpokenAnnouncementEvent.allCases.allSatisfy {
      rule(for: $0).alertSound == alertSound
    } ? alertSound : nil
  }

  mutating func setAllEventsAlertSound(
    _ alertSound: SpokenAnnouncementAlertSound
  ) {
    for event in SpokenAnnouncementEvent.allCases {
      setAlertSound(alertSound, for: event)
    }
  }

  func includesStartupInformation(
    _ information: StartupAnnouncementInformation
  ) -> Bool {
    startupInformationIDs.contains(information.rawValue)
  }

  mutating func setIncludesStartupInformation(
    _ includes: Bool,
    information: StartupAnnouncementInformation
  ) {
    if includes {
      startupInformationIDs.insert(information.rawValue)
    } else {
      startupInformationIDs.remove(information.rawValue)
    }
  }

  var startupInformation: Set<StartupAnnouncementInformation> {
    Set(
      StartupAnnouncementInformation.allCases.filter {
        includesStartupInformation($0)
      }
    )
  }
}

struct SpokenAnnouncementDelivery: Equatable {
  let isEnabled: Bool
  let configuration: SpokenAnnouncementConfiguration

  func rule(for event: SpokenAnnouncementEvent) -> SpokenAnnouncementRule {
    isEnabled ? configuration.rule(for: event) : .silent
  }
}
