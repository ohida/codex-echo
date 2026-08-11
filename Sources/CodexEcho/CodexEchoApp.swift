import AppKit
import SwiftUI

@MainActor
enum SpokenAnnouncementWindowFactory {
  static let frameAutosaveName =
    NSWindow.FrameAutosaveName("CodexEcho.CustomizeAnnouncements")

  static func make(
    settings: MenuBarSettings,
    previewSpokenAnnouncement:
      @escaping (SpokenAnnouncementEvent) -> Void,
    savesFrame: Bool = true
  ) -> NSWindowController {
    let contentRect = NSRect(
      x: 0,
      y: 0,
      width: MenuBarSettingsMetrics.announcementWindowWidth,
      height: MenuBarSettingsMetrics.announcementWindowHeight
    )
    let window = NSWindow(
      contentRect: contentRect,
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )
    window.title = "Customize Announcements"
    window.contentMinSize = NSSize(
      width: MenuBarSettingsMetrics.announcementWindowMinimumWidth,
      height: MenuBarSettingsMetrics.announcementWindowMinimumHeight
    )
    window.isReleasedWhenClosed = false
    window.tabbingMode = .disallowed
    window.center()
    if savesFrame {
      window.setFrameAutosaveName(frameAutosaveName)
    }

    window.contentView = NSHostingView(
      rootView: SpokenAnnouncementSettingsView(
        settings: settings,
        previewSpokenAnnouncement: previewSpokenAnnouncement,
        close: { [weak window] in
          window?.performClose(nil)
        }
      )
    )

    let windowController = NSWindowController(window: window)
    windowController.shouldCascadeWindows = true
    return windowController
  }
}

#if DEBUG
  enum CapacityHistoryDebugStorePolicy {
    private static let explicitFileKey =
      "CODEX_ECHO_DEBUG_CAPACITY_HISTORY_FILE"
    private static let syntheticCapacityKeys = [
      "CODEX_ECHO_DEBUG_USAGE_REMAINING_PERCENT",
      "CODEX_ECHO_DEBUG_FIVE_HOUR_REMAINING_PERCENT",
      "CODEX_ECHO_DEBUG_AVAILABLE_RESETS",
      "CODEX_ECHO_DEBUG_REPORTED_RESET_EXPIRATIONS",
      "CODEX_ECHO_DEBUG_CAPACITY_HISTORY_FIXTURE",
    ]

    static func fileURL(
      environment: [String: String],
      defaultFileURL: URL = CapacityHistoryStore.defaultFileURL(),
      temporaryDirectory: URL = FileManager.default.temporaryDirectory,
      makeIdentifier: () -> String = { UUID().uuidString }
    ) -> URL {
      if let explicitPath = environment[explicitFileKey], !explicitPath.isEmpty {
        return URL(fileURLWithPath: explicitPath)
      }
      guard syntheticCapacityKeys.contains(where: { environment[$0] != nil })
      else { return defaultFileURL }

      return temporaryDirectory
        .appendingPathComponent("CodexEchoCapacityFixtures", isDirectory: true)
        .appendingPathComponent(makeIdentifier(), isDirectory: true)
        .appendingPathComponent("v1.jsonl")
    }
  }

  enum CapacityHistoryResizeCapturePolicy {
    struct CaptureSize: Equatable {
      let width: CGFloat
      let height: CGFloat
      let fileName: String
    }

    static let directoryEnvironmentKey =
      "CODEX_ECHO_CAPTURE_CAPACITY_HISTORY_DIRECTORY"
    static let sizes = [
      CaptureSize(
        width: 600,
        height: CapacityHistoryWindowMetrics.minimumHeight,
        fileName: "compact-600x380.png"
      ),
      CaptureSize(
        width: 1_400,
        height: CapacityHistoryWindowMetrics.minimumHeight,
        fileName: "spacious-1400x380.png"
      ),
      CaptureSize(
        width: 600,
        height: CapacityHistoryWindowMetrics.height,
        fileName: "compact-600x500.png"
      ),
      CaptureSize(
        width: 1_400,
        height: CapacityHistoryWindowMetrics.height,
        fileName: "spacious-1400x500.png"
      ),
    ]
    static let settleDelay: TimeInterval = 0.2
    static let completionFileName = "capture-complete"

    static func isRequested(
      environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
      guard let directory = environment[directoryEnvironmentKey] else {
        return false
      }
      return !directory.isEmpty
    }
  }
#endif

@main
struct CodexEchoApp: App {
  @NSApplicationDelegateAdaptor(CodexEchoAppDelegate.self)
  private var appDelegate

  var body: some Scene {
    Settings {
      MenuBarSettingsView(
        settings: appDelegate.settings,
        launchAtLogin: appDelegate.launchAtLogin,
        updateController: appDelegate.updateController,
        previewSpokenVoice: { voice in
          appDelegate.previewSpokenVoice(voice)
        },
        openProjectCustomizationSettings: {
          appDelegate.openProjectCustomizationSettings()
        },
        openSpokenAnnouncementSettings: {
          appDelegate.openSpokenAnnouncementSettings()
        }
      )
    }
    .windowResizability(.contentSize)
  }
}

@MainActor
final class CodexEchoAppDelegate: NSObject, NSApplicationDelegate {
  private enum ApplicationInstanceLockState {
    case acquired(ApplicationInstanceLock)
    case alreadyRunning
    case failed(Error)

    var allowsProductState: Bool {
      if case .acquired = self {
        return true
      }
      return false
    }
  }

  private let applicationInstanceLockState: ApplicationInstanceLockState
  let settings: MenuBarSettings
  let launchAtLogin: LaunchAtLoginController
  let taskCustomizations: TaskCustomizationStore
  let capacityHistoryStore: CapacityHistoryStore
  lazy var capacityHistoryViewModel = CapacityHistoryViewModel(
    store: capacityHistoryStore,
    userDefaults: userDefaults
  )
  lazy var updateController: SparkleAppUpdateController = {
    guard applicationInstanceLockState.allowsProductState else {
      return SparkleAppUpdateController(
        displayVersion: AppUpdateConfiguration.displayVersion(
          infoDictionary: Bundle.main.infoDictionary
        ),
        isAvailable: false,
        canCheckForUpdates: false,
        automaticallyChecksForUpdates: false
      )
    }
    #if DEBUG
      if ProcessInfo.processInfo.environment[
        "CODEX_ECHO_DEBUG_UPDATES_AVAILABLE"
      ] == "1" {
        return SparkleAppUpdateController(
          displayVersion: AppUpdateConfiguration.displayVersion(
            infoDictionary: Bundle.main.infoDictionary
          ),
          isAvailable: true,
          canCheckForUpdates: true,
          automaticallyChecksForUpdates: true
        )
      }
    #endif
    return SparkleAppUpdateController()
  }()
  private let userDefaults: UserDefaults
  private var model: CodexActivityModel?
  private var statusItemController: StatusItemController?
  private var spokenUpdateCoordinator: SpokenUpdateCoordinator?
  private var capacityHistoryRecorder: CapacityHistoryRecorder?
  private var capacityHistoryWindowController: NSWindowController?
  private var spokenAnnouncementWindowController: NSWindowController?
  private var projectCustomizationWindowController: NSWindowController?
  private var supportDiagnosticsWindowController: NSWindowController?
  private var supportDiagnosticsViewModel: SupportDiagnosticsViewModel?

  override init() {
    applicationInstanceLockState = Self.acquireApplicationInstanceLock()
    launchAtLogin = LaunchAtLoginController()
    #if DEBUG
      let environment = ProcessInfo.processInfo.environment
      let userDefaults =
        environment["CODEX_ECHO_DEBUG_USER_DEFAULTS_SUITE"]
          .flatMap(UserDefaults.init(suiteName:))
        ?? .standard
      self.userDefaults = userDefaults
      settings = MenuBarSettings(
        userDefaults: userDefaults,
        initialSelectedPaneOverride: environment[
          "CODEX_ECHO_DEBUG_SETTINGS_PANE"
        ].flatMap(MenuBarSettingsPane.init(rawValue:)),
        initialMaximumVisibleTaskCountOverride: environment[
          "CODEX_ECHO_DEBUG_MAXIMUM_VISIBLE_TASK_COUNT"
        ].flatMap(Int.init),
        initialShowsCapacityInMenuBarOverride: environment[
          "CODEX_ECHO_DEBUG_SHOW_CAPACITY"
        ].map { $0 == "1" },
        initialTaskOpenMouseButtonOverride: environment[
          "CODEX_ECHO_DEBUG_TASK_OPEN_MOUSE_BUTTON"
        ].flatMap(TaskOpenMouseButton.init(rawValue:))
      )
    #else
      let userDefaults = UserDefaults.standard
      self.userDefaults = userDefaults
      settings = MenuBarSettings(userDefaults: userDefaults)
    #endif
    taskCustomizations = TaskCustomizationStore(userDefaults: userDefaults)
    #if DEBUG
      capacityHistoryStore = CapacityHistoryStore(
        fileURL: CapacityHistoryDebugStorePolicy.fileURL(
          environment: environment
        )
      )
    #else
      capacityHistoryStore = CapacityHistoryStore()
    #endif
    super.init()
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApplication.shared.setActivationPolicy(.accessory)
    guard finishApplicationInstanceLockPreflight() else { return }
    #if DEBUG
      CapacityHistoryDebugFixture.seedIfRequested(
        store: capacityHistoryStore
      )
      if ProcessInfo.processInfo.environment[
        "CODEX_ECHO_DEBUG_LIGHT_APPEARANCE"
      ] == "1" {
        NSApplication.shared.appearance = NSAppearance(named: .aqua)
      } else if ProcessInfo.processInfo.environment[
        "CODEX_ECHO_DEBUG_DARK_APPEARANCE"
      ] == "1" {
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
      }
    #endif
    let model = CodexActivityModel(
      settings: settings,
      userDefaults: userDefaults,
      customizationStore: taskCustomizations
    )
    self.model = model
    let capacityHistorySessionID: @Sendable () -> UUID = {
      #if DEBUG
        if
          let fixture = ProcessInfo.processInfo.environment[
            "CODEX_ECHO_DEBUG_CAPACITY_HISTORY_FIXTURE"
          ],
          ["story", "flat", "microsteps", "trend"].contains(fixture)
        {
          return CapacityHistoryDebugFixture.currentSessionID
        }
      #endif
      return UUID()
    }
    let capacityHistoryRecorder = CapacityHistoryRecorder(
      model: model,
      store: capacityHistoryStore,
      makeSessionID: capacityHistorySessionID
    )
    self.capacityHistoryRecorder = capacityHistoryRecorder
    let spokenUpdateCoordinator = SpokenUpdateCoordinator(
      model: model,
      settings: settings,
      speaker: SystemSpokenUpdateSpeaker()
    )
    self.spokenUpdateCoordinator = spokenUpdateCoordinator
    statusItemController = StatusItemController(
      model: model,
      updateChecker: updateController,
      previewSpokenUpdate: { [weak spokenUpdateCoordinator] voice in
        spokenUpdateCoordinator?.preview(voice: voice)
      },
      openCapacityHistory: { [weak self] in
        self?.openCapacityHistory()
      },
      showDiagnostics: { [weak self] in
        self?.openSupportDiagnostics()
      }
    )
    #if DEBUG
      if ProcessInfo.processInfo.environment[
        "CODEX_ECHO_DEBUG_OPEN_CAPACITY_HISTORY_WINDOW"
      ] == "1" {
        DispatchQueue.main.async { [weak self] in
          self?.openCapacityHistory()
        }
      }
      if ProcessInfo.processInfo.environment[
        "CODEX_ECHO_DEBUG_OPEN_PROJECT_CUSTOMIZATIONS_WINDOW"
      ] == "1" {
        DispatchQueue.main.async { [weak self] in
          self?.openProjectCustomizationSettings()
        }
      }
      if ProcessInfo.processInfo.environment[
        "CODEX_ECHO_DEBUG_OPEN_DIAGNOSTICS_WINDOW"
      ] == "1" {
        DispatchQueue.main.async { [weak self] in
          self?.openSupportDiagnostics()
        }
      }
    #endif
  }

  func applicationWillTerminate(_ notification: Notification) {
    model?.stop()
    capacityHistoryStore.flushSynchronously()
  }

  private static func acquireApplicationInstanceLock()
    -> ApplicationInstanceLockState
  {
    do {
      guard let lock = try ApplicationInstanceLock.acquire() else {
        return .alreadyRunning
      }
      return .acquired(lock)
    } catch {
      return .failed(error)
    }
  }

  private func finishApplicationInstanceLockPreflight() -> Bool {
    switch applicationInstanceLockState {
    case .acquired:
      return true
    case .alreadyRunning:
      presentLaunchAlert(
        title: ApplicationInstanceLaunchCopy.alreadyRunningTitle,
        message: ApplicationInstanceLaunchCopy.alreadyRunningMessage
      )
      return false
    case .failed(let error):
      NSLog("Codex Echo instance lock failed: %@", error.localizedDescription)
      presentLaunchAlert(
        title: ApplicationInstanceLaunchCopy.lockFailureTitle,
        message: ApplicationInstanceLaunchCopy.lockFailureMessage
      )
      return false
    }
  }

  private func presentLaunchAlert(title: String, message: String) {
    let alert = NSAlert()
    alert.alertStyle = .informational
    alert.messageText = title
    alert.informativeText = message
    alert.addButton(withTitle: "OK")
    NSApplication.shared.activate(ignoringOtherApps: true)
    alert.runModal()
    NSApplication.shared.terminate(nil)
  }

  func previewSpokenAnnouncement(
    _ event: SpokenAnnouncementEvent
  ) {
    spokenUpdateCoordinator?.preview(event)
  }

  func previewSpokenVoice(_ voice: SpokenUpdateVoice) {
    spokenUpdateCoordinator?.preview(voice: voice)
  }

  func openProjectCustomizationSettings() {
    let windowController: NSWindowController
    if let projectCustomizationWindowController {
      windowController = projectCustomizationWindowController
    } else {
      windowController = ProjectCustomizationWindowFactory.make(
        customizations: taskCustomizations
      )
      projectCustomizationWindowController = windowController
    }

    NSApplication.shared.activate(ignoringOtherApps: true)
    windowController.showWindow(nil)
    windowController.window?.makeKeyAndOrderFront(nil)
    #if DEBUG
      captureWindowWhenRequested(
        window: windowController.window,
        captureEnvironmentKey: "CODEX_ECHO_CAPTURE_PROJECT_CUSTOMIZATIONS",
        delayEnvironmentKey:
          "CODEX_ECHO_DEBUG_PROJECT_CUSTOMIZATIONS_CAPTURE_DELAY",
        title: "Project Customizations",
        successMarker: "PROJECT_CUSTOMIZATIONS_CAPTURED"
      )
    #endif
  }

  func openCapacityHistory() {
    guard
      let model,
      let capacityHistoryRecorder
    else { return }
    let windowController: NSWindowController
    if let capacityHistoryWindowController {
      windowController = capacityHistoryWindowController
    } else {
      let contentView = NSHostingView(
        rootView: CapacityHistoryView(
          model: model,
          recorder: capacityHistoryRecorder,
          viewModel: capacityHistoryViewModel,
          clearCapacityHistory: { [weak self] in
            try await self?.clearCapacityHistory()
          }
        )
      )
      windowController = CapacityHistoryWindowFactory.make(
        contentView: contentView,
        savesFrame: {
          #if DEBUG
            !CapacityHistoryResizeCapturePolicy.isRequested()
          #else
            true
          #endif
        }()
      )
      capacityHistoryWindowController = windowController
    }

    NSApplication.shared.activate(ignoringOtherApps: true)
    windowController.showWindow(nil)
    windowController.window?.makeKeyAndOrderFront(nil)
    #if DEBUG
      captureWindowWhenRequested(
        window: windowController.window,
        captureEnvironmentKey: "CODEX_ECHO_CAPTURE_CAPACITY_HISTORY",
        delayEnvironmentKey: "CODEX_ECHO_DEBUG_CAPACITY_CAPTURE_DELAY",
        title: "Codex Capacity",
        successMarker: "CAPACITY_HISTORY_CAPTURED"
      )
      captureCapacityHistoryResizeSequenceWhenRequested(
        window: windowController.window
      )
    #endif
  }

  func clearCapacityHistory() async throws {
    guard let capacityHistoryRecorder else { return }
    try await capacityHistoryRecorder.clearHistory()
  }

  func openSpokenAnnouncementSettings() {
    let windowController: NSWindowController
    if let spokenAnnouncementWindowController {
      windowController = spokenAnnouncementWindowController
    } else {
      windowController = SpokenAnnouncementWindowFactory.make(
        settings: settings,
        previewSpokenAnnouncement: { [weak self] event in
          self?.previewSpokenAnnouncement(event)
        }
      )
      spokenAnnouncementWindowController = windowController
    }

    NSApplication.shared.activate(ignoringOtherApps: true)
    windowController.showWindow(nil)
    windowController.window?.makeKeyAndOrderFront(nil)
  }

  func openSupportDiagnostics() {
    guard let model else { return }

    let viewModel: SupportDiagnosticsViewModel
    let windowController: NSWindowController
    if
      let existingViewModel = supportDiagnosticsViewModel,
      let existingWindowController = supportDiagnosticsWindowController
    {
      viewModel = existingViewModel
      windowController = existingWindowController
      viewModel.refresh()
    } else {
      viewModel = SupportDiagnosticsViewModel { [weak model] in
        guard let model else {
          return "Codex Echo Diagnostics\n\nDiagnostics are unavailable."
        }
        return SupportDiagnosticsReportFactory.report(model: model)
      }
      windowController = SupportDiagnosticsWindowFactory.make(
        viewModel: viewModel
      )
      supportDiagnosticsViewModel = viewModel
      supportDiagnosticsWindowController = windowController
    }

    NSApplication.shared.activate(ignoringOtherApps: true)
    windowController.showWindow(nil)
    windowController.window?.makeKeyAndOrderFront(nil)
    #if DEBUG
      captureWindowWhenRequested(
        window: windowController.window,
        captureEnvironmentKey: "CODEX_ECHO_CAPTURE_DIAGNOSTICS",
        delayEnvironmentKey: "CODEX_ECHO_DEBUG_DIAGNOSTICS_CAPTURE_DELAY",
        title: "Codex Echo Diagnostics",
        successMarker: "DIAGNOSTICS_CAPTURED"
      )
    #endif
  }

  #if DEBUG
    private func captureCapacityHistoryResizeSequenceWhenRequested(
      window: NSWindow?
    ) {
      let environment = ProcessInfo.processInfo.environment
      guard
        CapacityHistoryResizeCapturePolicy.isRequested(
          environment: environment
        ),
        let captureDirectory = environment[
          CapacityHistoryResizeCapturePolicy.directoryEnvironmentKey
        ]
      else { return }

      let directoryURL = URL(
        fileURLWithPath: captureDirectory,
        isDirectory: true
      )
      do {
        try FileManager.default.createDirectory(
          at: directoryURL,
          withIntermediateDirectories: true
        )
      } catch {
        assertionFailure(
          "Could not create Capacity capture directory: \(error)"
        )
        return
      }

      let initialDelay = environment[
        "CODEX_ECHO_DEBUG_CAPACITY_CAPTURE_DELAY"
      ].flatMap(Double.init) ?? 1.5
      window?.ignoresMouseEvents = true
      capacityHistoryViewModel.selectedDate = nil
      DispatchQueue.main.asyncAfter(deadline: .now() + initialDelay) {
        self.captureCapacityHistory(
          window: window,
          directoryURL: directoryURL,
          sizeIndex: 0
        )
      }
    }

    private func captureCapacityHistory(
      window: NSWindow?,
      directoryURL: URL,
      sizeIndex: Int
    ) {
      guard
        let window,
        CapacityHistoryResizeCapturePolicy.sizes.indices.contains(sizeIndex)
      else {
        assertionFailure("Capacity resize capture lost its window")
        return
      }
      capacityHistoryViewModel.selectedDate = nil
      let captureSize = CapacityHistoryResizeCapturePolicy.sizes[sizeIndex]
      window.setContentSize(
        NSSize(
          width: captureSize.width,
          height: captureSize.height
        )
      )

      DispatchQueue.main.asyncAfter(
        deadline: .now() + CapacityHistoryResizeCapturePolicy.settleDelay
      ) {
        self.capacityHistoryViewModel.selectedDate = nil
        let fileURL = directoryURL.appendingPathComponent(
          captureSize.fileName
        )
        guard
          self.writeWindowCapture(
            window: window,
            to: fileURL,
            title: "Codex Capacity"
          )
        else {
          window.ignoresMouseEvents = false
          return
        }

        let nextIndex = sizeIndex + 1
        if CapacityHistoryResizeCapturePolicy.sizes.indices.contains(nextIndex) {
          self.captureCapacityHistory(
            window: window,
            directoryURL: directoryURL,
            sizeIndex: nextIndex
          )
        } else {
          let completionURL = directoryURL.appendingPathComponent(
            CapacityHistoryResizeCapturePolicy.completionFileName
          )
          do {
            try Data("complete\n".utf8).write(
              to: completionURL,
              options: .atomic
            )
          } catch {
            window.ignoresMouseEvents = false
            assertionFailure(
              "Could not write Capacity capture completion: \(error)"
            )
            return
          }
          window.ignoresMouseEvents = false
          print(
            "CAPACITY_HISTORY_RESIZE_CAPTURED directory=\(directoryURL.path)"
          )
        }
      }
    }

    private func captureWindowWhenRequested(
      window: NSWindow?,
      captureEnvironmentKey: String,
      delayEnvironmentKey: String,
      title: String,
      successMarker: String
    ) {
      guard
        let capturePath = ProcessInfo.processInfo.environment[
          captureEnvironmentKey
        ],
        !capturePath.isEmpty
      else { return }

      let captureDelay = ProcessInfo.processInfo.environment[
        delayEnvironmentKey
      ].flatMap(Double.init) ?? 1.5

      DispatchQueue.main.asyncAfter(deadline: .now() + captureDelay) {
        if self.writeWindowCapture(
          window: window,
          to: URL(fileURLWithPath: capturePath),
          title: title
        ) {
          print("\(successMarker) path=\(capturePath)")
        }
      }
    }

    private func writeWindowCapture(
      window: NSWindow?,
      to fileURL: URL,
      title: String
    ) -> Bool {
      guard let contentView = window?.contentView else {
        assertionFailure("\(title) window had no content view")
        return false
      }
      contentView.layoutSubtreeIfNeeded()
      contentView.displayIfNeeded()
      guard
        let bitmap = contentView.bitmapImageRepForCachingDisplay(
          in: contentView.bounds
        )
      else {
        assertionFailure("Could not allocate \(title) capture")
        return false
      }
      contentView.cacheDisplay(in: contentView.bounds, to: bitmap)
      guard
        let png = bitmap.representation(
          using: .png,
          properties: [:]
        )
      else {
        assertionFailure("Could not encode \(title) capture")
        return false
      }
      do {
        try png.write(to: fileURL, options: .atomic)
        return true
      } catch {
        assertionFailure(
          "Could not write \(title) capture: \(error)"
        )
        return false
      }
    }
  #endif
}
