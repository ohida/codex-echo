import AppKit
import Foundation
import SwiftUI

struct SpokenAnnouncementColumnMetrics: Equatable {
  let spacing: CGFloat
  let horizontalPadding: CGFloat
  let speakWidth: CGFloat
  let alertSoundWidth: CGFloat
  let previewWidth: CGFloat
}

enum MenuBarSettingsMetrics {
  static let width: CGFloat = 460
  static let toolbarStyle: NSWindow.ToolbarStyle = .preference
  static let titlebarSeparatorStyle: NSTitlebarSeparatorStyle = .none
  static let announcementWindowWidth: CGFloat = 800
  static let announcementWindowHeight: CGFloat = 610
  static let announcementWindowMinimumWidth: CGFloat = 700
  static let announcementWindowMinimumHeight: CGFloat = 480
  static let spokenAnnouncementColumns = SpokenAnnouncementColumnMetrics(
    spacing: 12,
    horizontalPadding: 12,
    speakWidth: 52,
    alertSoundWidth: 210,
    previewWidth: 52
  )
}

enum MenuBarSettingsCopy {
  static let generalSectionTitle = "General"
  static let menuBarSectionTitle = "Menu Bar"
  static let capacityPaneTitle = "Capacity"
  static let speechPaneTitle = "Speech"
  static let tasksOnMenuBarTitle = "Tasks on Menu Bar"
  static let showCapacityInMenuBarTitle = "Show Capacity in Menu Bar"
  static let codexCapacityMenuTitle = "Codex Capacity"
  static let recordCapacityHistoryTitle = "Record Capacity History"
  static let recordCapacityHistoryDescription =
    "Saves new Capacity observations locally. Turning this off stops new entries; existing history remains available until cleared."
  static let automaticallyHideCompletedTasksTitle =
    "Hide completed tasks"
  static let automaticallyHideCompletedTasksDescription =
    "After completion; unread tasks stay visible."
  static let completedTaskAutoHideDelayTitle = "Hide after"
  static let automaticallyCheckForUpdatesTitle =
    "Automatically check for updates"
  static let checkNowTitle = "Check Now…"
  static let speakAnnouncementsMenuTitle = "Speak Announcements"
  static let speakAnnouncementsSettingsTitle = "Speak announcements"
  static let speakAnnouncementsDescription =
    "Speaks the announcement and alert sound choices below."

  static func softwareUpdateDescription(
    displayVersion: String,
    isAvailable: Bool
  ) -> String {
    let version = "\(AppPresentationCopy.displayName) \(displayVersion)."
    guard !isAvailable else { return version }
    return "\(version) Updates aren’t available in this development build."
  }
}

struct CapacityMenuItemPresentation: Equatable {
  static let systemImageName = "gauge.open.with.lines.needle.33percent"

  let title: String

  static func make(
    remainingPercent: Int?
  ) -> Self {
    return Self(
      title: remainingPercent.map {
        "\(MenuBarSettingsCopy.codexCapacityMenuTitle) (\($0)%)"
      } ?? MenuBarSettingsCopy.codexCapacityMenuTitle
    )
  }
}

enum TaskOpenMouseButton: String, CaseIterable, Identifiable {
  case left
  case right

  var id: Self { self }

  var title: String {
    switch self {
    case .left: "Left Click"
    case .right: "Right Click"
    }
  }
}

enum MenuBarSettingsPane: String, CaseIterable, Identifiable {
  case general
  case menuBar
  case capacity
  case announcements

  var id: Self { self }

  var title: String {
    switch self {
    case .general: MenuBarSettingsCopy.generalSectionTitle
    case .menuBar: MenuBarSettingsCopy.menuBarSectionTitle
    case .capacity: MenuBarSettingsCopy.capacityPaneTitle
    case .announcements: MenuBarSettingsCopy.speechPaneTitle
    }
  }

  var systemImageName: String {
    switch self {
    case .general: "gearshape"
    case .menuBar: "menubar.rectangle"
    case .capacity: CapacityMenuItemPresentation.systemImageName
    case .announcements: "speaker.wave.2"
    }
  }
}

enum CompletedTaskAutoHideDelay: String, CaseIterable, Identifiable {
  case fiveMinutes
  case fifteenMinutes
  case thirtyMinutes
  case oneHour

  var id: Self { self }

  var title: String {
    switch self {
    case .fiveMinutes: "5 minutes"
    case .fifteenMinutes: "15 minutes"
    case .thirtyMinutes: "30 minutes"
    case .oneHour: "1 hour"
    }
  }

  var timeInterval: TimeInterval {
    switch self {
    case .fiveMinutes: 5 * 60
    case .fifteenMinutes: 15 * 60
    case .thirtyMinutes: 30 * 60
    case .oneHour: 60 * 60
    }
  }
}

@MainActor
final class MenuBarSettings: ObservableObject {
  static let supportedMaximumVisibleTaskCount = 0...16
  static let defaultMaximumVisibleTaskCount = StatusItemTaskPolicy.visibleLimit
  static let defaultShowsCapacityInMenuBar = true
  static let defaultRecordsCapacityHistory = true
  static let defaultAutomaticallyHidesCompletedTasks = true
  static let defaultCompletedTaskAutoHideDelay = CompletedTaskAutoHideDelay.fifteenMinutes
  static let defaultSpeaksAnnouncements = false

  private enum Key {
    static let selectedPane = "selectedSettingsPane"
    static let maximumVisibleTaskCount = "maximumVisibleTaskCount"
    static let showsCapacityInMenuBar = "showsCapacityInMenuBar"
    static let recordsCapacityHistory = "recordsCapacityHistory"
    static let automaticallyHidesCompletedTasks = "automaticallyHidesCompletedTasks"
    static let completedTaskAutoHideDelay = "completedTaskAutoHideDelay"
    static let taskOpenMouseButton = "taskOpenMouseButton"
    static let speaksAnnouncements = "speaksAnnouncements"
    static let spokenAnnouncementConfiguration =
      "spokenAnnouncementConfiguration"
    static let defaultSpokenUpdateVoiceIdentifier =
      "defaultSpokenUpdateVoiceIdentifier"
  }

  private let userDefaults: UserDefaults

  @Published var selectedPane: MenuBarSettingsPane {
    didSet {
      userDefaults.set(selectedPane.rawValue, forKey: Key.selectedPane)
    }
  }

  @Published var maximumVisibleTaskCount: Int {
    didSet {
      let supportedValue = Self.clampedMaximumVisibleTaskCount(maximumVisibleTaskCount)
      guard supportedValue == maximumVisibleTaskCount else {
        maximumVisibleTaskCount = supportedValue
        return
      }
      userDefaults.set(maximumVisibleTaskCount, forKey: Key.maximumVisibleTaskCount)
    }
  }

  @Published var showsCapacityInMenuBar: Bool {
    didSet {
      userDefaults.set(
        showsCapacityInMenuBar,
        forKey: Key.showsCapacityInMenuBar
      )
    }
  }

  @Published var recordsCapacityHistory: Bool {
    didSet {
      userDefaults.set(
        recordsCapacityHistory,
        forKey: Key.recordsCapacityHistory
      )
    }
  }

  @Published var automaticallyHidesCompletedTasks: Bool {
    didSet {
      userDefaults.set(
        automaticallyHidesCompletedTasks,
        forKey: Key.automaticallyHidesCompletedTasks
      )
    }
  }

  @Published var completedTaskAutoHideDelay: CompletedTaskAutoHideDelay {
    didSet {
      userDefaults.set(
        completedTaskAutoHideDelay.rawValue,
        forKey: Key.completedTaskAutoHideDelay
      )
    }
  }

  @Published var taskOpenMouseButton: TaskOpenMouseButton {
    didSet {
      userDefaults.set(taskOpenMouseButton.rawValue, forKey: Key.taskOpenMouseButton)
    }
  }

  @Published var defaultSpokenUpdateVoice: SpokenUpdateVoice {
    didSet {
      userDefaults.set(
        defaultSpokenUpdateVoice.identifier,
        forKey: Key.defaultSpokenUpdateVoiceIdentifier
      )
    }
  }

  @Published var speaksAnnouncements: Bool {
    didSet {
      userDefaults.set(
        speaksAnnouncements,
        forKey: Key.speaksAnnouncements
      )
    }
  }

  @Published private(set) var spokenAnnouncementConfiguration:
    SpokenAnnouncementConfiguration
  {
    didSet {
      guard
        let data = try? JSONEncoder().encode(spokenAnnouncementConfiguration)
      else { return }
      userDefaults.set(data, forKey: Key.spokenAnnouncementConfiguration)
    }
  }

  init(
    userDefaults: UserDefaults = .standard,
    initialSelectedPaneOverride: MenuBarSettingsPane? = nil,
    initialMaximumVisibleTaskCountOverride: Int? = nil,
    initialShowsCapacityInMenuBarOverride: Bool? = nil,
    initialTaskOpenMouseButtonOverride: TaskOpenMouseButton? = nil
  ) {
    self.userDefaults = userDefaults
    selectedPane =
      initialSelectedPaneOverride
      ?? userDefaults.string(forKey: Key.selectedPane)
        .flatMap(MenuBarSettingsPane.init(rawValue:))
      ?? .general
    let storedMaximum = userDefaults.object(forKey: Key.maximumVisibleTaskCount) as? Int
    maximumVisibleTaskCount = Self.clampedMaximumVisibleTaskCount(
      initialMaximumVisibleTaskCountOverride
        ?? storedMaximum
        ?? Self.defaultMaximumVisibleTaskCount
    )
    let storedShowsCapacityInMenuBar =
      userDefaults.object(forKey: Key.showsCapacityInMenuBar) as? Bool
    showsCapacityInMenuBar =
      initialShowsCapacityInMenuBarOverride
      ?? storedShowsCapacityInMenuBar
      ?? Self.defaultShowsCapacityInMenuBar
    recordsCapacityHistory =
      userDefaults.object(forKey: Key.recordsCapacityHistory) as? Bool
      ?? Self.defaultRecordsCapacityHistory
    automaticallyHidesCompletedTasks =
      userDefaults.object(forKey: Key.automaticallyHidesCompletedTasks) as? Bool
      ?? Self.defaultAutomaticallyHidesCompletedTasks
    completedTaskAutoHideDelay =
      userDefaults.string(forKey: Key.completedTaskAutoHideDelay)
        .flatMap(CompletedTaskAutoHideDelay.init(rawValue:))
      ?? Self.defaultCompletedTaskAutoHideDelay
    let storedTaskOpenMouseButton = userDefaults.string(forKey: Key.taskOpenMouseButton)
      .flatMap(TaskOpenMouseButton.init(rawValue:))
    taskOpenMouseButton = initialTaskOpenMouseButtonOverride
      ?? storedTaskOpenMouseButton
      ?? .left
    defaultSpokenUpdateVoice =
      SpokenUpdateVoiceCatalog.voice(
        identifier: userDefaults.string(
          forKey: Key.defaultSpokenUpdateVoiceIdentifier
        )
      )
      ?? .defaultVoice
    let restoredSpeaksAnnouncements =
      userDefaults.object(forKey: Key.speaksAnnouncements) as? Bool
      ?? Self.defaultSpeaksAnnouncements
    let storedConfiguration: SpokenAnnouncementConfiguration?
    if let data = userDefaults.data(
      forKey: Key.spokenAnnouncementConfiguration
    ),
      let configuration = try? JSONDecoder().decode(
        SpokenAnnouncementConfiguration.self,
        from: data
      ),
      configuration.isValid
    {
      storedConfiguration = configuration
    } else {
      userDefaults.removeObject(
        forKey: Key.spokenAnnouncementConfiguration
      )
      storedConfiguration = nil
    }
    let restoredConfiguration = storedConfiguration ?? .defaults
    speaksAnnouncements = restoredSpeaksAnnouncements
    spokenAnnouncementConfiguration = restoredConfiguration
  }

  var spokenAnnouncementDelivery: SpokenAnnouncementDelivery {
    SpokenAnnouncementDelivery(
      isEnabled: speaksAnnouncements,
      configuration: spokenAnnouncementConfiguration
    )
  }

  func spokenAnnouncementRule(
    for event: SpokenAnnouncementEvent
  ) -> SpokenAnnouncementRule {
    spokenAnnouncementConfiguration.rule(for: event)
  }

  func setSpokenAnnouncementSpeaks(
    _ speaks: Bool,
    for event: SpokenAnnouncementEvent
  ) {
    spokenAnnouncementConfiguration.setSpeaks(speaks, for: event)
  }

  func setSpokenAnnouncementAlertSound(
    _ alertSound: SpokenAnnouncementAlertSound,
    for event: SpokenAnnouncementEvent
  ) {
    spokenAnnouncementConfiguration.setAlertSound(
      alertSound,
      for: event
    )
  }

  var allEventsSpeakState: SpokenAnnouncementBulkSpeakState {
    spokenAnnouncementConfiguration.allEventsSpeakState
  }

  func setAllEventsSpeak(_ speaks: Bool) {
    spokenAnnouncementConfiguration.setAllEventsSpeak(speaks)
  }

  var allEventsAlertSound: SpokenAnnouncementAlertSound? {
    spokenAnnouncementConfiguration.allEventsAlertSound
  }

  func setAllEventsAlertSound(
    _ alertSound: SpokenAnnouncementAlertSound
  ) {
    spokenAnnouncementConfiguration.setAllEventsAlertSound(alertSound)
  }

  func startupAnnouncementIncludes(
    _ information: StartupAnnouncementInformation
  ) -> Bool {
    spokenAnnouncementConfiguration.includesStartupInformation(information)
  }

  func setStartupAnnouncementIncludes(
    _ includes: Bool,
    information: StartupAnnouncementInformation
  ) {
    spokenAnnouncementConfiguration.setIncludesStartupInformation(
      includes,
      information: information
    )
  }

  var startupInformationControlsAreEnabled: Bool {
    spokenAnnouncementRule(for: .startupSummary).speaks
  }

  func restoreDefaultSpokenAnnouncements() {
    spokenAnnouncementConfiguration = .defaults
  }

  private static func clampedMaximumVisibleTaskCount(_ count: Int) -> Int {
    min(
      max(count, supportedMaximumVisibleTaskCount.lowerBound),
      supportedMaximumVisibleTaskCount.upperBound
    )
  }
}

struct MenuBarSettingsView: View {
  @ObservedObject var settings: MenuBarSettings
  @ObservedObject var launchAtLogin: LaunchAtLoginController
  @ObservedObject var updateController: SparkleAppUpdateController
  let previewSpokenVoice: (SpokenUpdateVoice) -> Void
  let openProjectCustomizationSettings: () -> Void
  let openSpokenAnnouncementSettings: () -> Void

  var body: some View {
    TabView(selection: $settings.selectedPane) {
      ForEach(MenuBarSettingsPane.allCases) { pane in
        settingsPane(for: pane)
          .tabItem {
            Label(pane.title, systemImage: pane.systemImageName)
          }
          .tag(pane)
      }
    }
    .frame(width: MenuBarSettingsMetrics.width)
    .fixedSize(horizontal: false, vertical: true)
    .background(Color(nsColor: .windowBackgroundColor))
    .background(SettingsWindowTitleView(title: settings.selectedPane.title))
    .onAppear {
      launchAtLogin.refresh()
      updateController.refresh()
    }
    .onReceive(
      NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
    ) { _ in
      launchAtLogin.refresh()
      updateController.refresh()
    }
  }

  @ViewBuilder
  private func settingsPane(for pane: MenuBarSettingsPane) -> some View {
    switch pane {
    case .general:
      generalSettingsPane
    case .menuBar:
      menuBarSettingsPane
    case .capacity:
      capacitySettingsPane
    case .announcements:
      speechSettingsPane
    }
  }

  private var generalSettingsPane: some View {
    SettingsPaneContent {
      SettingsRow(
        title: "Launch at Login",
        description: launchAtLoginDescription
      ) {
        Toggle(
          "Launch at Login",
          isOn: Binding(
            get: { launchAtLogin.isEnabled },
            set: { launchAtLogin.setEnabled($0) }
          )
        )
        .labelsHidden()
        .toggleStyle(.switch)
        .disabled(!launchAtLogin.isAvailable)
      }

      if launchAtLogin.requiresApproval {
        Button("Open Login Items Settings…") {
          launchAtLogin.openSystemSettings()
        }
        .buttonStyle(.link)
        .font(.caption)
        .accessibilityHint(
          AppPresentationCopy.launchAtLoginApprovalHint
        )
      }

      Divider()

      SettingsRow(
        title: "Project customizations",
        description: "Review or remove saved project colors and voices."
      ) {
        Button("Manage…") {
          openProjectCustomizationSettings()
        }
      }

      Divider()

      SettingsRow(
        title: "Open task with",
        description: "The other click opens its task menu. Either click opens +N."
      ) {
        Picker("Open task with", selection: $settings.taskOpenMouseButton) {
          ForEach(TaskOpenMouseButton.allCases) { mouseButton in
            Text(mouseButton.title).tag(mouseButton)
          }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .frame(width: 172)
        .accessibilityLabel("Open task with")
      }

      Divider()

      SettingsRow(
        title: MenuBarSettingsCopy.automaticallyCheckForUpdatesTitle,
        description: MenuBarSettingsCopy.softwareUpdateDescription(
          displayVersion: updateController.displayVersion,
          isAvailable: updateController.isAvailable
        )
      ) {
        HStack(spacing: 8) {
          Button(MenuBarSettingsCopy.checkNowTitle) {
            updateController.checkForUpdates()
          }
          .disabled(!updateController.canCheckForUpdates)

          Toggle(
            MenuBarSettingsCopy.automaticallyCheckForUpdatesTitle,
            isOn: Binding(
              get: {
                updateController.automaticallyChecksForUpdates
              },
              set: {
                updateController.setAutomaticallyChecksForUpdates($0)
              }
            )
          )
          .labelsHidden()
          .toggleStyle(.switch)
          .disabled(!updateController.isAvailable)
          .accessibilityLabel(
            MenuBarSettingsCopy.automaticallyCheckForUpdatesTitle
          )
        }
      }
    }
  }

  private var menuBarSettingsPane: some View {
    SettingsPaneContent {
      SettingsRow(
        title: MenuBarSettingsCopy.tasksOnMenuBarTitle,
        description: "Set to 0 to keep every task ring in the +N menu."
      ) {
        Stepper(
          value: $settings.maximumVisibleTaskCount,
          in: MenuBarSettings.supportedMaximumVisibleTaskCount
        ) {
          Text(settings.maximumVisibleTaskCount, format: .number)
            .monospacedDigit()
            .frame(minWidth: 20, alignment: .trailing)
        }
        .accessibilityLabel(MenuBarSettingsCopy.tasksOnMenuBarTitle)
        .accessibilityValue(
          Text(settings.maximumVisibleTaskCount, format: .number)
        )
      }

      Divider()

      SettingsRow(
        title: MenuBarSettingsCopy.automaticallyHideCompletedTasksTitle,
        description: MenuBarSettingsCopy.automaticallyHideCompletedTasksDescription
      ) {
        HStack(spacing: 8) {
          Picker(
            MenuBarSettingsCopy.completedTaskAutoHideDelayTitle,
            selection: $settings.completedTaskAutoHideDelay
          ) {
            ForEach(CompletedTaskAutoHideDelay.allCases) { delay in
              Text(delay.title).tag(delay)
            }
          }
          .labelsHidden()
          .pickerStyle(.menu)
          .frame(width: 116)
          .disabled(!settings.automaticallyHidesCompletedTasks)
          .accessibilityLabel(MenuBarSettingsCopy.completedTaskAutoHideDelayTitle)

          Toggle(
            MenuBarSettingsCopy.automaticallyHideCompletedTasksTitle,
            isOn: $settings.automaticallyHidesCompletedTasks
          )
          .labelsHidden()
          .toggleStyle(.switch)
        }
      }
    }
  }

  private var capacitySettingsPane: some View {
    SettingsPaneContent {
      SettingsRow(
        title: MenuBarSettingsCopy.showCapacityInMenuBarTitle,
        description: "Shows remaining Codex capacity beside the task rings."
      ) {
        Toggle(
          MenuBarSettingsCopy.showCapacityInMenuBarTitle,
          isOn: $settings.showsCapacityInMenuBar
        )
        .labelsHidden()
        .toggleStyle(.switch)
      }

      Divider()

      SettingsRow(
        title: MenuBarSettingsCopy.recordCapacityHistoryTitle,
        description: MenuBarSettingsCopy.recordCapacityHistoryDescription
      ) {
        Toggle(
          MenuBarSettingsCopy.recordCapacityHistoryTitle,
          isOn: $settings.recordsCapacityHistory
        )
        .labelsHidden()
        .toggleStyle(.switch)
      }
    }
  }

  private var speechSettingsPane: some View {
    SettingsPaneContent {
      SettingsRow(
        title: MenuBarSettingsCopy.speakAnnouncementsSettingsTitle,
        description: MenuBarSettingsCopy.speakAnnouncementsDescription
      ) {
        Toggle(
          MenuBarSettingsCopy.speakAnnouncementsSettingsTitle,
          isOn: $settings.speaksAnnouncements
        )
        .labelsHidden()
        .toggleStyle(.switch)
      }

      Divider()

      SettingsRow(
        title: "Customize announcements",
        description: "Choose events, phrases, and alert sounds."
      ) {
        Button("Customize…") {
          openSpokenAnnouncementSettings()
        }
      }

      Divider()

      SettingsRow(
        title: "Default voice",
        description:
          "Used for system announcements and when a task or project does not choose another voice."
      ) {
        HStack(spacing: 8) {
          Picker(
            "Default voice",
            selection: $settings.defaultSpokenUpdateVoice
          ) {
            ForEach(
              SpokenUpdateVoiceCatalog.availableEnglishUSVoiceGroups,
              id: \.language
            ) { group in
              Section(group.displayName) {
                ForEach(group.voices) { voice in
                  Text(voice.displayName).tag(voice)
                }
              }
            }
          }
          .labelsHidden()
          .pickerStyle(.menu)
          .frame(width: 122)
          .accessibilityLabel("Default voice")

          Button("Play Sample") {
            previewSpokenVoice(settings.defaultSpokenUpdateVoice)
          }
          .accessibilityHint("Speaks a sample using the selected default voice.")
        }
      }
    }
  }

  private var launchAtLoginDescription: String {
    if let errorMessage = launchAtLogin.errorMessage {
      return errorMessage
    }
    if launchAtLogin.requiresApproval {
      return "Approval is required in System Settings before the app can open at login."
    }
    if !launchAtLogin.isAvailable {
      return "Launch at Login isn’t available for this copy of the app."
    }
    return AppPresentationCopy.launchAtLoginDescription
  }
}

private struct AllEventsSpeakCheckbox: NSViewRepresentable {
  let state: SpokenAnnouncementBulkSpeakState
  let setAll: (Bool) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(parent: self)
  }

  func makeNSView(context: Context) -> NSView {
    let container = NSView()
    let button = NSButton(
      checkboxWithTitle: "",
      target: context.coordinator,
      action: #selector(Coordinator.toggleAll(_:))
    )
    button.allowsMixedState = true
    button.setAccessibilityLabel("Set Speak for all events")
    button.toolTip =
      "Turn Speak on for every event, or off when every event is on."
    button.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(button)
    NSLayoutConstraint.activate([
      button.centerXAnchor.constraint(equalTo: container.centerXAnchor),
      button.centerYAnchor.constraint(equalTo: container.centerYAnchor),
    ])
    return container
  }

  func updateNSView(_ container: NSView, context: Context) {
    context.coordinator.parent = self
    guard let button = container.subviews.first as? NSButton else { return }
    switch state {
    case .allOn:
      button.state = .on
      button.setAccessibilityValue("All on")
    case .allOff:
      button.state = .off
      button.setAccessibilityValue("All off")
    case .mixed:
      button.state = .mixed
      button.setAccessibilityValue("Mixed")
    }
  }

  @MainActor
  final class Coordinator: NSObject {
    var parent: AllEventsSpeakCheckbox

    init(parent: AllEventsSpeakCheckbox) {
      self.parent = parent
    }

    @objc
    func toggleAll(_ sender: NSButton) {
      parent.setAll(parent.state != .allOn)
    }
  }
}

private struct AnnouncementSearchField: NSViewRepresentable {
  @Binding var text: String

  func makeCoordinator() -> Coordinator {
    Coordinator(parent: self)
  }

  func makeNSView(context: Context) -> NSSearchField {
    let searchField = NSSearchField()
    searchField.placeholderString = "Search announcements"
    searchField.delegate = context.coordinator
    searchField.sendsSearchStringImmediately = true
    searchField.setAccessibilityLabel("Search announcements")
    return searchField
  }

  func updateNSView(_ searchField: NSSearchField, context: Context) {
    context.coordinator.parent = self
    if searchField.stringValue != text {
      searchField.stringValue = text
    }
  }

  @MainActor
  final class Coordinator: NSObject, NSSearchFieldDelegate {
    var parent: AnnouncementSearchField

    init(parent: AnnouncementSearchField) {
      self.parent = parent
    }

    func controlTextDidChange(_ notification: Notification) {
      guard let searchField = notification.object as? NSSearchField else {
        return
      }
      parent.text = searchField.stringValue
    }
  }
}

struct SpokenAnnouncementSettingsView: View {
  @ObservedObject var settings: MenuBarSettings
  let previewSpokenAnnouncement: (SpokenAnnouncementEvent) -> Void
  let close: () -> Void
  @State private var confirmsRestoreDefaults = false
  @State private var searchText: String

  init(
    settings: MenuBarSettings,
    previewSpokenAnnouncement:
      @escaping (SpokenAnnouncementEvent) -> Void,
    close: @escaping () -> Void,
    initialSearchText: String = ""
  ) {
    self.settings = settings
    self.previewSpokenAnnouncement = previewSpokenAnnouncement
    self.close = close
    _searchText = State(initialValue: initialSearchText)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 16) {
          Text("Customize Announcements")
            .font(.title2)
            .fontWeight(.semibold)

          Spacer()

          AnnouncementSearchField(text: $searchText)
            .frame(width: 240, height: 24)
        }

        Text(
          "Changes are saved automatically. Use Speak announcements to turn the configured set on or off."
        )
        .foregroundStyle(.secondary)
      }
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)

      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          announcementColumnHeader
            .fixedSize(horizontal: false, vertical: true)

          if !SpokenAnnouncementSearch.hasQuery(searchText) {
            allEventsSection
              .fixedSize(horizontal: false, vertical: true)
          }

          ForEach(matchingCategories) { category in
            announcementSection(for: category)
          }

          if matchingCategories.isEmpty {
            ContentUnavailableView(
              "No Announcements Found",
              systemImage: "magnifyingglass",
              description: Text("Try a different search.")
            )
            .frame(maxWidth: .infinity)
            .padding(.vertical, 48)
          }
        }
        .padding(.vertical, 2)
      }

      HStack {
        Button("Restore Defaults…", role: .destructive) {
          confirmsRestoreDefaults = true
        }

        Spacer()

        Text("Preview is available even when Speak is off.")
          .font(.caption)
          .foregroundStyle(.secondary)

        Button("Done") {
          close()
        }
        .keyboardShortcut(.defaultAction)
      }
      .fixedSize(horizontal: false, vertical: true)
    }
    .padding(20)
    .frame(
      minWidth: MenuBarSettingsMetrics.announcementWindowMinimumWidth,
      idealWidth: MenuBarSettingsMetrics.announcementWindowWidth,
      maxWidth: .infinity,
      minHeight: MenuBarSettingsMetrics.announcementWindowMinimumHeight,
      idealHeight: MenuBarSettingsMetrics.announcementWindowHeight,
      maxHeight: .infinity
    )
    .background(Color(nsColor: .windowBackgroundColor))
    .alert(
      "Restore Announcement Defaults?",
      isPresented: $confirmsRestoreDefaults
    ) {
      Button("Cancel", role: .cancel) {}
      Button("Restore Defaults", role: .destructive) {
        settings.restoreDefaultSpokenAnnouncements()
      }
    } message: {
      Text(
        "All announcements and their default alert sounds will be restored. Speak announcements will stay \(settings.speaksAnnouncements ? "on" : "off")."
      )
    }
  }

  private var matchingCategories: [SpokenAnnouncementCategory] {
    SpokenAnnouncementCategory.allCases.filter { category in
      if !SpokenAnnouncementSearch.results(
        in: category,
        matching: searchText
      ).isEmpty {
        return true
      }
      return category == .startup
        && !SpokenAnnouncementSearch.startupInformation(
          matching: searchText
        ).isEmpty
    }
  }

  private var announcementColumnHeader: some View {
    let columns = MenuBarSettingsMetrics.spokenAnnouncementColumns
    return HStack(spacing: columns.spacing) {
      Text("Announcement")
        .frame(maxWidth: .infinity, alignment: .leading)

      Text("Speak")
        .frame(width: columns.speakWidth)

      Text("Alert Sound")
        .frame(width: columns.alertSoundWidth)

      Text("Preview")
        .frame(width: columns.previewWidth)
    }
    .font(.caption)
    .foregroundStyle(.secondary)
    .padding(.horizontal, columns.horizontalPadding)
  }

  private var allEventsRow: some View {
    let columns = MenuBarSettingsMetrics.spokenAnnouncementColumns
    return HStack(spacing: columns.spacing) {
      Text("All Events")
        .fontWeight(.medium)
        .frame(maxWidth: .infinity, alignment: .leading)

      AllEventsSpeakCheckbox(
        state: settings.allEventsSpeakState,
        setAll: settings.setAllEventsSpeak
      )
      .frame(width: columns.speakWidth, height: 18)

      Picker(
        "Alert sound for all events",
        selection: Binding<SpokenAnnouncementAlertSound?>(
          get: { settings.allEventsAlertSound },
          set: { alertSound in
            guard let alertSound else { return }
            settings.setAllEventsAlertSound(alertSound)
          }
        )
      ) {
        Text("Mixed")
          .tag(Optional<SpokenAnnouncementAlertSound>.none)
          .disabled(true)
        ForEach(SpokenAnnouncementAlertSound.allCases) { alertSound in
          Text(alertSound.title)
            .tag(Optional(alertSound))
        }
      }
      .labelsHidden()
      .pickerStyle(.menu)
      .frame(width: columns.alertSoundWidth)
      .accessibilityLabel("Set alert sound for all events")
      .help("Apply one alert sound choice to every event.")

      Color.clear
        .frame(width: columns.previewWidth, height: 1)
    }
    .padding(.vertical, 7)
  }

  private var allEventsSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Bulk Edit")
        .font(.headline)

      allEventsRow
        .padding(.horizontal, 12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        }
    }
  }

  private func announcementRow(
    for result: SpokenAnnouncementSearchResult
  ) -> some View {
    let event = result.event
    let columns = MenuBarSettingsMetrics.spokenAnnouncementColumns
    return HStack(spacing: columns.spacing) {
      Text(event.settingsText)
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)

      Toggle(
        "Speak \(event.settingsText) announcements",
        isOn: Binding(
          get: { settings.spokenAnnouncementRule(for: event).speaks },
          set: { settings.setSpokenAnnouncementSpeaks($0, for: event) }
        )
      )
      .labelsHidden()
      .toggleStyle(.checkbox)
      .frame(width: columns.speakWidth)
      .accessibilityLabel("Speak \(event.settingsText) announcements")

      Picker(
        "Alert sound for \(event.settingsText) announcements",
        selection: Binding(
          get: { settings.spokenAnnouncementRule(for: event).alertSound },
          set: { settings.setSpokenAnnouncementAlertSound($0, for: event) }
        )
      ) {
        ForEach(SpokenAnnouncementAlertSound.allCases) { alertSound in
          Text(alertSound.title).tag(alertSound)
        }
      }
      .labelsHidden()
      .pickerStyle(.menu)
      .frame(width: columns.alertSoundWidth)
      .accessibilityLabel(
        "Alert sound for \(event.settingsText) announcements"
      )
      .help("Play a short alert sound before this announcement.")

      Button {
        previewSpokenAnnouncement(event)
      } label: {
        Image(systemName: "play.fill")
      }
      .buttonStyle(.borderless)
      .frame(width: columns.previewWidth)
      .accessibilityLabel("Preview \(event.settingsText) announcement")
    }
    .padding(.vertical, 7)
  }

  private func startupInformationRow(
    for information: StartupAnnouncementInformation
  ) -> some View {
    let columns = MenuBarSettingsMetrics.spokenAnnouncementColumns
    return HStack(spacing: columns.spacing) {
      Text(information.settingsText)
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)

      Toggle(
        "Include \(information.settingsText) in the startup announcement",
        isOn: Binding(
          get: { settings.startupAnnouncementIncludes(information) },
          set: {
            settings.setStartupAnnouncementIncludes(
              $0,
              information: information
            )
          }
        )
      )
      .labelsHidden()
      .toggleStyle(.checkbox)
      .frame(width: columns.speakWidth)
      .accessibilityLabel(
        "Include \(information.settingsText) in the startup announcement"
      )

      Color.clear
        .frame(width: columns.alertSoundWidth, height: 1)

      Color.clear
        .frame(width: columns.previewWidth, height: 1)
    }
    .padding(.vertical, 7)
    .disabled(!settings.startupInformationControlsAreEnabled)
  }

  @ViewBuilder
  private func announcementRows(
    for category: SpokenAnnouncementCategory
  ) -> some View {
    if category == .startup {
      let results = SpokenAnnouncementSearch.results(
        in: category,
        matching: searchText
      )
      let informationRows = SpokenAnnouncementSearch.startupInformation(
        matching: searchText
      )
      let startupResult = results.first(where: {
        $0.event == .startupSummary
      })

      if let startupResult {
        announcementRow(for: startupResult)
      }
      ForEach(
        Array(informationRows.enumerated()),
        id: \.element
      ) { index, information in
        if startupResult != nil || index > 0 {
          Divider()
        }
        startupInformationRow(for: information)
      }
    } else {
      let results = SpokenAnnouncementSearch.results(
        in: category,
        matching: searchText
      )
      ForEach(Array(results.enumerated()), id: \.element.id) {
        index,
        result in
        announcementRow(for: result)
        if index < results.count - 1 {
          Divider()
        }
      }
    }
  }

  private func announcementSection(
    for category: SpokenAnnouncementCategory
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(category.title)
        .font(.headline)

      VStack(spacing: 0) {
        announcementRows(for: category)
      }
      .padding(.horizontal, 12)
      .background(Color(nsColor: .controlBackgroundColor))
      .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
      }
    }
  }
}

private struct SettingsPaneContent<Content: View>: View {
  @ViewBuilder let content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      content
    }
    .padding(.horizontal, 24)
    .padding(.vertical, 20)
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .fixedSize(horizontal: false, vertical: true)
    .background(Color(nsColor: .windowBackgroundColor))
    .overlay(alignment: .top) {
      Divider()
    }
  }
}

private struct SettingsRow<Control: View>: View {
  let title: String
  let description: String
  @ViewBuilder let control: Control

  var body: some View {
    HStack(alignment: .top, spacing: 20) {
      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(.body)

        Text(description)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      control
        .fixedSize()
    }
  }
}

private struct SettingsWindowTitleView: NSViewRepresentable {
  let title: String

  func makeNSView(context: Context) -> WindowTitleHostingView {
    WindowTitleHostingView(title: title)
  }

  func updateNSView(_ nsView: WindowTitleHostingView, context: Context) {
    nsView.title = title
    nsView.applyTitle()
  }
}

private final class WindowTitleHostingView: NSView {
  var title: String

  init(title: String) {
    self.title = title
    super.init(frame: .zero)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    applyTitle()
  }

  func applyTitle() {
    window?.title = title
    window?.toolbarStyle = MenuBarSettingsMetrics.toolbarStyle
    window?.titlebarSeparatorStyle = MenuBarSettingsMetrics.titlebarSeparatorStyle
    window?.toolbar?.allowsUserCustomization = false
  }
}
