import Darwin
import Foundation
import XCTest

@testable import CodexIPC

final class CodexIPCEndpointTests: XCTestCase {
  func testDefaultEndpointsPreferCanonicalSocketAndIncludeLegacyRouterSocket() {
    let userID = getuid()
    let legacySocketName = userID == 0 ? "ipc.sock" : "ipc-\(userID).sock"
    let expectedLegacySocketURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("codex-ipc", isDirectory: true)
      .appendingPathComponent(legacySocketName)

    XCTAssertEqual(
      CodexIPCClient.defaultSocketURLs,
      [CodexIPCClient.defaultSocketURL, expectedLegacySocketURL]
    )
  }

  func testConnectionFallsBackToTheNextTrustedEndpoint() throws {
    let canonicalSocketURL = URL(fileURLWithPath: "/private/tmp/canonical.sock")
    let legacySocketURL = URL(fileURLWithPath: "/private/tmp/legacy.sock")
    var attemptedSocketURLs: [URL] = []

    let descriptor = try CodexIPCClient.firstAvailableSocketDescriptor(
      from: [canonicalSocketURL, legacySocketURL]
    ) { socketURL in
      attemptedSocketURLs.append(socketURL)
      if socketURL == canonicalSocketURL {
        throw IPCClientError.socketUnavailable
      }
      return 42
    }

    XCTAssertEqual(descriptor, 42)
    XCTAssertEqual(attemptedSocketURLs, [canonicalSocketURL, legacySocketURL])
  }

  func testMalformedFrameIsClassifiedAsAnInvalidMessage() {
    XCTAssertEqual(
      CodexIPCDiagnosticsFailureKind.classify(
        IPCFrameCodecError.invalidPayloadLength(0)
      ),
      .invalidMessage
    )
  }

  @MainActor
  func testUnavailableEndpointProducesSanitizedDiagnostics() async {
    let socketURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("missing-\(UUID().uuidString).sock")
    let client = CodexIPCClient(socketURL: socketURL)
    let disconnected = expectation(description: "IPC disconnected")
    client.eventHandler = { event in
      guard case .connectionStateChanged(.disconnected) = event else { return }
      disconnected.fulfill()
    }

    client.start()
    await fulfillment(of: [disconnected], timeout: 1)
    let snapshot = client.diagnosticsSnapshot()
    client.stop()

    XCTAssertEqual(snapshot.state, .disconnected)
    XCTAssertEqual(
      snapshot.endpointAttempts,
      [
        CodexIPCDiagnosticsEndpointAttempt(
          endpoint: .custom(1),
          result: .unavailable
        )
      ]
    )
    XCTAssertEqual(snapshot.connectionFailureCount, 1)
    XCTAssertEqual(
      snapshot.lastFailure,
      CodexIPCDiagnosticsFailure(
        phase: .endpointValidation,
        kind: .socketUnavailable
      )
    )
  }
}
