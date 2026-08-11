import Darwin
import Foundation

public enum CodexIPCDiagnosticsState: Equatable, Sendable {
  case stopped
  case connecting
  case connected
  case disconnected
  case incompatible
}

public enum CodexIPCDiagnosticsEndpoint: Equatable, Sendable {
  case canonical
  case legacy
  case custom(Int)
}

public enum CodexIPCDiagnosticsFailureKind: Equatable, Sendable {
  case socketUnavailable
  case untrustedSocket
  case socketPathTooLong
  case notConnected
  case invalidMessage
  case initializationRejected
  case connectionRefused
  case connectionReset
  case brokenPipe
  case timedOut
  case permissionDenied
  case connectionClosed
  case unsupportedVersion(actual: Int, expected: Int)
  case systemError(code: Int32)
}

public enum CodexIPCDiagnosticsEndpointResult: Equatable, Sendable {
  case notAttempted
  case unavailable
  case untrusted
  case pathTooLong
  case failed(CodexIPCDiagnosticsFailureKind)
  case connected
}

public enum CodexIPCDiagnosticsFailurePhase: Equatable, Sendable {
  case endpointValidation
  case socketConnect
  case initializeWrite
  case initializeResponse
  case subscriptionWrite
  case streamRead
  case streamDecode
  case streamVersion
}

public struct CodexIPCDiagnosticsFailure: Equatable, Sendable {
  public let phase: CodexIPCDiagnosticsFailurePhase
  public let kind: CodexIPCDiagnosticsFailureKind

  public init(
    phase: CodexIPCDiagnosticsFailurePhase,
    kind: CodexIPCDiagnosticsFailureKind
  ) {
    self.phase = phase
    self.kind = kind
  }
}

public struct CodexIPCDiagnosticsEndpointAttempt: Equatable, Sendable {
  public let endpoint: CodexIPCDiagnosticsEndpoint
  public let result: CodexIPCDiagnosticsEndpointResult

  public init(
    endpoint: CodexIPCDiagnosticsEndpoint,
    result: CodexIPCDiagnosticsEndpointResult
  ) {
    self.endpoint = endpoint
    self.result = result
  }
}

public struct CodexIPCDiagnosticsSnapshot: Equatable, Sendable {
  public let state: CodexIPCDiagnosticsState
  public let endpointAttempts: [CodexIPCDiagnosticsEndpointAttempt]
  public let connectionFailureCount: Int
  public let lastFailure: CodexIPCDiagnosticsFailure?

  public init(
    state: CodexIPCDiagnosticsState,
    endpointAttempts: [CodexIPCDiagnosticsEndpointAttempt],
    connectionFailureCount: Int,
    lastFailure: CodexIPCDiagnosticsFailure?
  ) {
    self.state = state
    self.endpointAttempts = endpointAttempts
    self.connectionFailureCount = connectionFailureCount
    self.lastFailure = lastFailure
  }
}

extension CodexIPCDiagnosticsFailureKind {
  static func classify(_ error: any Error) -> Self {
    guard let error = error as? IPCClientError else {
      return .invalidMessage
    }
    return switch error {
    case .socketUnavailable: .socketUnavailable
    case .untrustedSocket: .untrustedSocket
    case .socketPathTooLong: .socketPathTooLong
    case .notConnected: .notConnected
    case .invalidMessage: .invalidMessage
    case .initializeFailed: .initializationRejected
    case .posix(_, let code): Self.classifyPOSIX(code)
    }
  }

  private static func classifyPOSIX(_ code: Int32) -> Self {
    return switch code {
    case ECONNREFUSED: .connectionRefused
    case ECONNRESET: .connectionReset
    case EPIPE: .brokenPipe
    case ETIMEDOUT: .timedOut
    case EACCES, EPERM: .permissionDenied
    default: .systemError(code: code)
    }
  }
}
