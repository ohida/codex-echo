import AppKit
import CodexAppServer
import CodexIPC
import Foundation

enum SupportDiagnosticsCodexAppVersion: Equatable {
  case notInstalled
  case installed(version: String?, build: String?)
}

struct SupportDiagnosticsRuntimeSnapshot: Equatable {
  let desktopAppState: CodexDesktopAppState
  let ipc: CodexIPCDiagnosticsSnapshot
  let appServer: CodexAppServerDiagnosticsSnapshot
}

struct SupportDiagnosticsSnapshot: Equatable {
  let echoVersion: String
  let echoBuild: String
  let operatingSystemVersion: String
  let architecture: String
  let codexAppVersion: SupportDiagnosticsCodexAppVersion
  let desktopAppState: CodexDesktopAppState
  let ipc: CodexIPCDiagnosticsSnapshot
  let appServer: CodexAppServerDiagnosticsSnapshot
}

@MainActor
enum SupportDiagnosticsReportFactory {
  static func report(
    model: CodexActivityModel,
    bundle: Bundle = .main,
    workspace: NSWorkspace = .shared,
    processInfo: ProcessInfo = .processInfo
  ) -> String {
    let runtime = model.supportDiagnosticsRuntimeSnapshot()
    let snapshot = SupportDiagnosticsSnapshot(
      echoVersion: nonemptyBundleValue(
        "CFBundleShortVersionString",
        bundle: bundle
      ) ?? "Development",
      echoBuild: nonemptyBundleValue("CFBundleVersion", bundle: bundle)
        ?? "Unbundled",
      operatingSystemVersion: operatingSystemVersion(processInfo),
      architecture: architecture,
      codexAppVersion: codexAppVersion(
        workspace: workspace,
        desktopAppState: runtime.desktopAppState
      ),
      desktopAppState: runtime.desktopAppState,
      ipc: runtime.ipc,
      appServer: runtime.appServer
    )
    return SupportDiagnosticsFormatter.report(snapshot)
  }

  private static func nonemptyBundleValue(
    _ key: String,
    bundle: Bundle
  ) -> String? {
    guard
      let value = bundle.infoDictionary?[key] as? String,
      !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return nil }
    return value
  }

  private static func operatingSystemVersion(
    _ processInfo: ProcessInfo
  ) -> String {
    let version = processInfo.operatingSystemVersion
    return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
  }

  private static var architecture: String {
    #if arch(arm64)
      "arm64"
    #elseif arch(x86_64)
      "x86_64"
    #else
      "unknown"
    #endif
  }

  private static func codexAppVersion(
    workspace: NSWorkspace,
    desktopAppState: CodexDesktopAppState
  ) -> SupportDiagnosticsCodexAppVersion {
    guard
      let applicationURL = workspace.urlForApplication(
        withBundleIdentifier: CodexDesktopAppController.bundleIdentifier
      )
    else {
      return desktopAppState == .notInstalled
        ? .notInstalled
        : .installed(version: nil, build: nil)
    }
    let infoDictionary = Bundle(url: applicationURL)?.infoDictionary
    let version = nonemptyString(
      infoDictionary?["CFBundleShortVersionString"]
    )
    let build = nonemptyString(infoDictionary?["CFBundleVersion"])
    return .installed(version: version, build: build)
  }

  private static func nonemptyString(_ value: Any?) -> String? {
    guard
      let value = value as? String,
      !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return nil }
    return value
  }
}

enum SupportDiagnosticsFormatter {
  static func report(_ snapshot: SupportDiagnosticsSnapshot) -> String {
    var lines = [
      "Codex Echo Diagnostics",
      "",
      "Application",
      "Codex Echo: \(snapshot.echoVersion) (\(snapshot.echoBuild))",
      "macOS: \(snapshot.operatingSystemVersion) (\(snapshot.architecture))",
      "Codex App: "
        + codexAppDescription(
          version: snapshot.codexAppVersion,
          state: snapshot.desktopAppState
        ),
      "",
      "Desktop IPC",
      "State: \(ipcState(snapshot.ipc.state))",
    ]

    if snapshot.ipc.endpointAttempts.isEmpty {
      lines.append("Endpoints: Not Available")
    } else {
      lines.append(
        contentsOf: snapshot.ipc.endpointAttempts.map { attempt in
          "\(ipcEndpoint(attempt.endpoint)): \(ipcEndpointResult(attempt.result))"
        }
      )
    }
    lines.append(
      "Connection Failures This Launch: \(snapshot.ipc.connectionFailureCount)"
    )
    lines.append(
      "Last Failure This Launch: "
        + ipcFailure(snapshot.ipc.lastFailure)
    )
    lines.append(contentsOf: [
      "",
      "App Server",
      "State: \(appServerState(snapshot.appServer.state))",
    ])
    if snapshot.appServer.state == .running {
      lines.append(
        "Task Catalog: \(appServerCapability(snapshot.appServer.taskCatalogState))"
      )
      lines.append(
        "Codex Capacity: \(appServerCapability(snapshot.appServer.capacityState))"
      )
    }
    lines.append(
      "Connection Failures This Launch: "
        + String(snapshot.appServer.connectionFailureCount)
    )
    lines.append(
      "Last Failure This Launch: "
        + appServerFailure(snapshot.appServer.lastFailure)
    )
    return lines.joined(separator: "\n")
  }

  private static func codexAppVersion(
    _ version: SupportDiagnosticsCodexAppVersion
  ) -> String {
    return switch version {
    case .notInstalled:
      "Not Installed"
    case .installed(let version, let build):
      switch (version, build) {
      case (.some(let version), .some(let build)): "\(version) (\(build))"
      case (.some(let version), nil): version
      case (nil, .some(let build)): "Build \(build)"
      case (nil, nil): "Installed"
      }
    }
  }

  private static func codexAppDescription(
    version: SupportDiagnosticsCodexAppVersion,
    state: CodexDesktopAppState
  ) -> String {
    if version == .notInstalled || state == .notInstalled {
      return "Not Installed"
    }
    return "\(codexAppVersion(version)) — \(desktopAppState(state))"
  }

  private static func desktopAppState(_ state: CodexDesktopAppState) -> String {
    return switch state {
    case .notInstalled: "Not Installed"
    case .notRunning: "Not Running"
    case .launching: "Launching"
    case .running: "Running"
    case .launchFailed: "Launch Failed"
    }
  }

  private static func ipcState(_ state: CodexIPCDiagnosticsState) -> String {
    return switch state {
    case .stopped: "Stopped"
    case .connecting: "Connecting"
    case .connected: "Connected"
    case .disconnected: "Disconnected"
    case .incompatible: "Incompatible"
    }
  }

  private static func ipcEndpoint(
    _ endpoint: CodexIPCDiagnosticsEndpoint
  ) -> String {
    return switch endpoint {
    case .canonical: "Canonical Endpoint"
    case .legacy: "Legacy Endpoint"
    case .custom(let index): "Custom Endpoint \(index)"
    }
  }

  private static func ipcEndpointResult(
    _ result: CodexIPCDiagnosticsEndpointResult
  ) -> String {
    return switch result {
    case .notAttempted: "Not Attempted"
    case .unavailable: "Unavailable"
    case .untrusted: "Untrusted"
    case .pathTooLong: "Path Too Long"
    case .failed(let kind): ipcFailureKind(kind)
    case .connected: "Connected"
    }
  }

  private static func ipcFailure(
    _ failure: CodexIPCDiagnosticsFailure?
  ) -> String {
    guard let failure else { return "None" }
    return "\(ipcFailurePhase(failure.phase)) — \(ipcFailureKind(failure.kind))"
  }

  private static func ipcFailurePhase(
    _ phase: CodexIPCDiagnosticsFailurePhase
  ) -> String {
    return switch phase {
    case .endpointValidation: "Endpoint Validation"
    case .socketConnect: "Socket Connect"
    case .initializeWrite: "Initialize Write"
    case .initializeResponse: "Initialize Response"
    case .subscriptionWrite: "Subscription Write"
    case .streamRead: "Stream Read"
    case .streamDecode: "Stream Decode"
    case .streamVersion: "Stream Version"
    }
  }

  private static func ipcFailureKind(
    _ kind: CodexIPCDiagnosticsFailureKind
  ) -> String {
    return switch kind {
    case .socketUnavailable: "Socket Unavailable"
    case .untrustedSocket: "Untrusted Socket"
    case .socketPathTooLong: "Socket Path Too Long"
    case .notConnected: "Not Connected"
    case .invalidMessage: "Invalid Message"
    case .initializationRejected: "Initialization Rejected"
    case .connectionRefused: "Connection Refused"
    case .connectionReset: "Connection Reset"
    case .brokenPipe: "Broken Pipe"
    case .timedOut: "Timed Out"
    case .permissionDenied: "Permission Denied"
    case .connectionClosed: "Connection Closed"
    case .unsupportedVersion(let actual, let expected):
      "Unsupported Version \(actual) (Expected \(expected))"
    case .systemError(let code): "System Error (errno \(code))"
    }
  }

  private static func appServerState(
    _ state: CodexAppServerDiagnosticsState
  ) -> String {
    return switch state {
    case .stopped: "Stopped"
    case .starting: "Starting"
    case .running: "Running"
    case .failed: "Failed"
    }
  }

  private static func appServerCapability(
    _ state: CodexAppServerDiagnosticsCapabilityState
  ) -> String {
    return switch state {
    case .notRequested: "Not Requested"
    case .awaitingFirstResponse: "Awaiting First Response"
    case .available: "Available"
    case .unavailable: "Unavailable"
    }
  }

  private static func appServerFailure(
    _ failure: CodexAppServerDiagnosticsFailure?
  ) -> String {
    guard let failure else { return "None" }
    return "\(appServerFailurePhase(failure.phase)) — "
      + appServerFailureKind(failure.kind)
  }

  private static func appServerFailurePhase(
    _ phase: CodexAppServerDiagnosticsFailurePhase
  ) -> String {
    return switch phase {
    case .executableValidation: "Executable Validation"
    case .processLaunch: "Process Launch"
    case .initialize: "Initialize"
    case .read: "Read"
    case .response: "Response"
    case .write: "Write"
    case .processExit: "Process Exit"
    }
  }

  private static func appServerFailureKind(
    _ kind: CodexAppServerDiagnosticsFailureKind
  ) -> String {
    return switch kind {
    case .executableUnavailable: "Executable Unavailable"
    case .processLaunchFailed: "Process Launch Failed"
    case .initializationRejected: "Initialization Rejected"
    case .responseTooLarge: "Response Too Large"
    case .requestTimedOut: "Request Timed Out"
    case .writeFailed: "Write Failed"
    case .processExited: "Process Exited"
    }
  }
}
