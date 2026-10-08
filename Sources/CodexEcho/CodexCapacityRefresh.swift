import AppKit
import CodexAppServer
import Foundation

/// Owns only the short-lived app-server created for this explicit read.
@MainActor
final class CodexCapacityRefresh {
  enum Failure: String, Error {
    case unavailable = "refresh_unavailable"
    case timedOut = "refresh_timed_out"
  }

  private let client: CodexAppServerClient
  private let timeout: Duration
  private var continuation: CheckedContinuation<CodexUsageSnapshot, any Error>?
  private var deadline: Task<Void, Never>?

  init(client: CodexAppServerClient? = nil, timeout: Duration = .seconds(20)) {
    self.client = client ?? CodexAppServerClient(codexApplicationURLResolver: {
      NSWorkspace.shared.urlForApplication(
        withBundleIdentifier: CodexDesktopAppController.bundleIdentifier
      )
    })
    self.timeout = timeout
  }

  func read() async throws -> CodexUsageSnapshot {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        self.continuation = continuation
        client.eventHandler = { [weak self] event in
          switch event {
          case .usageChanged(let usage): self?.finish(.success(usage))
          case .usageUnavailable, .connectionStateChanged(.failed):
            self?.finish(.failure(Failure.unavailable))
          default: break
          }
        }
        deadline = Task { [weak self, timeout] in
          do { try await Task.sleep(for: timeout) } catch { return }
          self?.finish(.failure(Failure.timedOut))
        }
        if Task.isCancelled {
          finish(.failure(CancellationError()))
        } else {
          client.start()
        }
      }
    } onCancel: {
      Task { @MainActor [weak self] in self?.finish(.failure(CancellationError())) }
    }
  }

  private func finish(_ result: Result<CodexUsageSnapshot, any Error>) {
    guard let continuation else { return }
    self.continuation = nil
    deadline?.cancel()
    deadline = nil
    client.eventHandler = nil
    client.stop()
    continuation.resume(with: result)
  }
}
