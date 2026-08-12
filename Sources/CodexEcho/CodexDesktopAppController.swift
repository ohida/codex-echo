import AppKit

enum CodexDesktopAppState: Equatable {
  case notInstalled
  case notRunning
  case launching
  case running
  case launchFailed
}

enum CodexDesktopAppStatePolicy {
  static func resolve(isInstalled: Bool, isRunning: Bool) -> CodexDesktopAppState {
    if isRunning { return .running }
    return isInstalled ? .notRunning : .notInstalled
  }
}

@MainActor
protocol CodexDesktopAppControlling: AnyObject {
  var state: CodexDesktopAppState { get }
  var stateDidChange: ((CodexDesktopAppState) -> Void)? { get set }

  func start()
  func stop()
  func openCodex()
}

@MainActor
protocol CodexDesktopAppWorkspace: AnyObject {
  var notificationCenter: NotificationCenter { get }

  func applicationURL(withBundleIdentifier bundleIdentifier: String) -> URL?
  func isApplicationRunning(withBundleIdentifier bundleIdentifier: String) -> Bool
  func launchApplication(at applicationURL: URL) async throws
}

@MainActor
private final class SystemCodexDesktopAppWorkspace: CodexDesktopAppWorkspace {
  private let workspace: NSWorkspace

  init(workspace: NSWorkspace = .shared) {
    self.workspace = workspace
  }

  var notificationCenter: NotificationCenter {
    workspace.notificationCenter
  }

  func applicationURL(withBundleIdentifier bundleIdentifier: String) -> URL? {
    workspace.urlForApplication(withBundleIdentifier: bundleIdentifier)
  }

  func isApplicationRunning(withBundleIdentifier bundleIdentifier: String) -> Bool {
    !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
  }

  func launchApplication(at applicationURL: URL) async throws {
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, any Error>) in
      workspace.openApplication(
        at: applicationURL,
        configuration: configuration
      ) { _, error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume()
        }
      }
    }
  }
}

@MainActor
final class CodexDesktopAppController: NSObject, CodexDesktopAppControlling {
  nonisolated static let bundleIdentifier = "com.openai.codex"

  private let workspace: any CodexDesktopAppWorkspace
  private var isStarted = false
  private var launchTask: Task<Void, Never>?

  private(set) var state: CodexDesktopAppState = .notRunning
  var stateDidChange: ((CodexDesktopAppState) -> Void)?

  convenience override init() {
    self.init(workspace: SystemCodexDesktopAppWorkspace())
  }

  init(workspace: any CodexDesktopAppWorkspace) {
    self.workspace = workspace
    super.init()
  }

  func start() {
    guard !isStarted else { return }
    isStarted = true
    workspace.notificationCenter.addObserver(
      self,
      selector: #selector(workspaceApplicationLifecycleDidChange(_:)),
      name: NSWorkspace.didLaunchApplicationNotification,
      object: nil
    )
    workspace.notificationCenter.addObserver(
      self,
      selector: #selector(workspaceApplicationLifecycleDidChange(_:)),
      name: NSWorkspace.didTerminateApplicationNotification,
      object: nil
    )
    reconcileState()
  }

  func reconcileState() {
    reconcileState(installedButNotRunningState: .notRunning)
  }

  func stop() {
    guard isStarted else { return }
    isStarted = false
    workspace.notificationCenter.removeObserver(self)
    launchTask?.cancel()
    launchTask = nil
  }

  func openCodex() {
    guard state != .launching else { return }
    guard
      let applicationURL = workspace.applicationURL(
        withBundleIdentifier: Self.bundleIdentifier
      )
    else {
      transition(to: .notInstalled)
      return
    }

    transition(to: .launching)
    launchTask?.cancel()
    launchTask = Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        try await workspace.launchApplication(at: applicationURL)
      } catch {
        // Reconcile below so a concurrent successful launch wins over this failure.
      }
      guard !Task.isCancelled, state == .launching else { return }
      reconcileState(installedButNotRunningState: .launchFailed)
    }
  }

  @objc
  private func workspaceApplicationLifecycleDidChange(_ notification: Notification) {
    guard
      let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
        as? NSRunningApplication,
      application.bundleIdentifier == Self.bundleIdentifier
    else { return }

    // Re-query instead of trusting notification order because multiple app instances can overlap.
    reconcileState()
  }

  private func reconcileState(
    installedButNotRunningState: CodexDesktopAppState
  ) {
    let resolved = CodexDesktopAppStatePolicy.resolve(
      isInstalled: workspace.applicationURL(
        withBundleIdentifier: Self.bundleIdentifier
      ) != nil,
      isRunning: workspace.isApplicationRunning(
        withBundleIdentifier: Self.bundleIdentifier
      )
    )
    if resolved == .notRunning {
      transition(to: installedButNotRunningState)
    } else {
      transition(to: resolved)
    }
  }

  private func transition(to newState: CodexDesktopAppState) {
    guard state != newState else { return }
    state = newState
    stateDidChange?(newState)
  }
}

struct CodexDesktopAppRecoveryMenu: Equatable {
  let statusTitle: String
  let statusSymbolName: String
  let actionTitle: String?
  let actionSymbolName: String?
}

enum CodexStatusPresentation: Equatable {
  case desktopAppNotInstalled
  case desktopAppNotRunning
  case desktopAppLaunching
  case desktopAppLaunchFailed
  case connection(CodexConnectionHealth)

  var desktopAppRecoveryMenu: CodexDesktopAppRecoveryMenu? {
    switch self {
    case .desktopAppNotInstalled:
      CodexDesktopAppRecoveryMenu(
        statusTitle: "Codex App Not Found",
        statusSymbolName: "exclamationmark.circle",
        actionTitle: nil,
        actionSymbolName: nil
      )
    case .desktopAppNotRunning:
      CodexDesktopAppRecoveryMenu(
        statusTitle: "Codex App Isn’t Running",
        statusSymbolName: "exclamationmark.circle",
        actionTitle: "Open Codex",
        actionSymbolName: "arrow.up.forward.app"
      )
    case .desktopAppLaunching:
      CodexDesktopAppRecoveryMenu(
        statusTitle: "Opening Codex…",
        statusSymbolName: "ellipsis.circle",
        actionTitle: nil,
        actionSymbolName: nil
      )
    case .desktopAppLaunchFailed:
      CodexDesktopAppRecoveryMenu(
        statusTitle: "Couldn’t Open Codex",
        statusSymbolName: "exclamationmark.circle",
        actionTitle: "Try Again",
        actionSymbolName: "arrow.clockwise"
      )
    case .connection:
      nil
    }
  }

  var fallbackSymbolName: String? {
    switch self {
    case .connection:
      menuStatusSymbolName
    case .desktopAppNotInstalled, .desktopAppNotRunning, .desktopAppLaunching,
      .desktopAppLaunchFailed:
      desktopAppRecoveryMenu?.statusSymbolName
    }
  }

  var showsTaskSignals: Bool {
    if case .connection = self { return true }
    return false
  }

  var requiresStatusBadge: Bool {
    guard case .connection(let health) = self else { return false }
    return health.requiresStatusBadge
  }

  var showsMenuStatus: Bool {
    switch self {
    case .connection(.live): false
    case .connection, .desktopAppNotInstalled, .desktopAppNotRunning,
      .desktopAppLaunching, .desktopAppLaunchFailed: true
    }
  }

  var showsAuthoritativeEmptyTaskState: Bool {
    self == .connection(.live)
  }

  var accessibilityLabel: String {
    switch self {
    case .desktopAppNotInstalled: "Codex App not found"
    case .desktopAppNotRunning: "Codex App isn’t running"
    case .desktopAppLaunching: "Opening Codex"
    case .desktopAppLaunchFailed: "Couldn’t open Codex"
    case .connection(let health): health.accessibilityLabel
    }
  }

  var menuStatusTitle: String {
    switch self {
    case .desktopAppNotInstalled, .desktopAppNotRunning, .desktopAppLaunching,
      .desktopAppLaunchFailed:
      desktopAppRecoveryMenu?.statusTitle ?? "Codex Unavailable"
    case .connection(.live): "Connected to Codex"
    case .connection(.connecting): "Connecting to Codex…"
    case .connection(.degraded(.taskCatalogUnavailable)):
      "Codex Task List Unavailable"
    case .connection(.degraded(.liveActivityUnavailable)):
      "Codex Live Status Unavailable"
    case .connection(.incompatible): "Codex Version Incompatible"
    case .connection(.offline): "Waiting for Codex"
    }
  }

  var menuStatusSymbolName: String {
    switch self {
    case .desktopAppNotInstalled, .desktopAppNotRunning, .desktopAppLaunchFailed:
      "exclamationmark.circle"
    case .desktopAppLaunching: "ellipsis.circle"
    case .connection(.live): "checkmark.circle"
    case .connection(.connecting): "ellipsis.circle"
    case .connection(.degraded): "exclamationmark.triangle"
    case .connection(.incompatible): "exclamationmark.triangle.fill"
    case .connection(.offline): "bolt.horizontal.circle"
    }
  }
}

enum CodexStatusPresentationPolicy {
  static func resolve(
    desktopAppState: CodexDesktopAppState,
    connectionHealth: CodexConnectionHealth
  ) -> CodexStatusPresentation {
    switch desktopAppState {
    case .notInstalled: .desktopAppNotInstalled
    case .notRunning: .desktopAppNotRunning
    case .launching: .desktopAppLaunching
    case .launchFailed: .desktopAppLaunchFailed
    case .running: .connection(connectionHealth)
    }
  }
}
