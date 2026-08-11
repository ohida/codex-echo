import Foundation

public enum CodexAppServerDiagnosticsState: Equatable, Sendable {
  case stopped
  case starting
  case running
  case failed
}

public enum CodexAppServerDiagnosticsFailurePhase: Equatable, Sendable {
  case executableValidation
  case processLaunch
  case initialize
  case read
  case response
  case write
  case processExit
}

public enum CodexAppServerDiagnosticsFailureKind: Equatable, Sendable {
  case executableUnavailable
  case processLaunchFailed
  case initializationRejected
  case responseTooLarge
  case requestTimedOut
  case writeFailed
  case processExited
}

public enum CodexAppServerDiagnosticsCapabilityState: Equatable, Sendable {
  case notRequested
  case awaitingFirstResponse
  case available
  case unavailable
}

public struct CodexAppServerDiagnosticsFailure: Equatable, Sendable {
  public let phase: CodexAppServerDiagnosticsFailurePhase
  public let kind: CodexAppServerDiagnosticsFailureKind

  public init(
    phase: CodexAppServerDiagnosticsFailurePhase,
    kind: CodexAppServerDiagnosticsFailureKind
  ) {
    self.phase = phase
    self.kind = kind
  }
}

public struct CodexAppServerDiagnosticsSnapshot: Equatable, Sendable {
  public let state: CodexAppServerDiagnosticsState
  public let taskCatalogState: CodexAppServerDiagnosticsCapabilityState
  public let capacityState: CodexAppServerDiagnosticsCapabilityState
  public let connectionFailureCount: Int
  public let lastFailure: CodexAppServerDiagnosticsFailure?

  public init(
    state: CodexAppServerDiagnosticsState,
    taskCatalogState: CodexAppServerDiagnosticsCapabilityState,
    capacityState: CodexAppServerDiagnosticsCapabilityState,
    connectionFailureCount: Int,
    lastFailure: CodexAppServerDiagnosticsFailure?
  ) {
    self.state = state
    self.taskCatalogState = taskCatalogState
    self.capacityState = capacityState
    self.connectionFailureCount = connectionFailureCount
    self.lastFailure = lastFailure
  }
}
