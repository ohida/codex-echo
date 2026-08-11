import AppKit
import XCTest

@testable import CodexAppServer
@testable import CodexEcho
@testable import CodexIPC

final class SupportDiagnosticsTests: XCTestCase {
  func testReportIsDeterministicAndContainsOnlySupportMetadata() {
    let snapshot = SupportDiagnosticsSnapshot(
      echoVersion: "0.5.2",
      echoBuild: "42",
      operatingSystemVersion: "15.6",
      architecture: "arm64",
      codexAppVersion: .installed(version: "1.2.3", build: "456"),
      desktopAppState: .running,
      ipc: CodexIPCDiagnosticsSnapshot(
        state: .disconnected,
        endpointAttempts: [
          .init(endpoint: .canonical, result: .unavailable),
          .init(
            endpoint: .legacy,
            result: .failed(.connectionRefused)
          ),
        ],
        connectionFailureCount: 12,
        lastFailure: .init(
          phase: .socketConnect,
          kind: .connectionRefused
        )
      ),
      appServer: CodexAppServerDiagnosticsSnapshot(
        state: .running,
        taskCatalogState: .available,
        capacityState: .awaitingFirstResponse,
        connectionFailureCount: 0,
        lastFailure: nil
      )
    )

    XCTAssertEqual(
      SupportDiagnosticsFormatter.report(snapshot),
      """
      Codex Echo Diagnostics

      Application
      Codex Echo: 0.5.2 (42)
      macOS: 15.6 (arm64)
      Codex App: 1.2.3 (456) — Running

      Desktop IPC
      State: Disconnected
      Canonical Endpoint: Unavailable
      Legacy Endpoint: Connection Refused
      Connection Failures This Launch: 12
      Last Failure This Launch: Socket Connect — Connection Refused

      App Server
      State: Running
      Task Catalog: Available
      Codex Capacity: Awaiting First Response
      Connection Failures This Launch: 0
      Last Failure This Launch: None
      """
    )
  }

  func testReportCannotContainTaskOrPathDetails() {
    let sensitiveValues = [
      "secret-task-title",
      "thread_123456",
      "/Users/alice/PrivateProject",
      "alice@example.com",
      "Capacity: 37%",
      "raw stderr payload",
    ]
    let snapshot = SupportDiagnosticsSnapshot.fixture
    let report = SupportDiagnosticsFormatter.report(snapshot)

    XCTAssertFalse(report.contains("Privacy"))
    XCTAssertFalse(report.contains("Software Updates"))
    XCTAssertFalse(report.contains("Overall"))
    for sensitiveValue in sensitiveValues {
      XCTAssertFalse(report.contains(sensitiveValue))
    }
  }

  @MainActor
  func testViewModelCopiesExactlyTheVisibleFrozenSnapshot() {
    let clipboard = RecordingDiagnosticsClipboard()
    var reports = ["first report", "second report"]
    let viewModel = SupportDiagnosticsViewModel(
      makeReport: { reports.removeFirst() },
      clipboard: clipboard
    )

    XCTAssertEqual(viewModel.report, "first report")
    viewModel.copy()
    XCTAssertEqual(clipboard.strings, ["first report"])

    viewModel.refresh()
    XCTAssertEqual(viewModel.report, "second report")
    XCTAssertEqual(clipboard.strings, ["first report"])

    viewModel.copy()
    XCTAssertEqual(clipboard.strings, ["first report", "second report"])
  }

  @MainActor
  func testDiagnosticsWindowIsSinglePurposeMovableAndResizable() throws {
    let viewModel = SupportDiagnosticsViewModel(
      makeReport: { "diagnostics" },
      clipboard: RecordingDiagnosticsClipboard()
    )
    let controller = SupportDiagnosticsWindowFactory.make(viewModel: viewModel)
    let window = try XCTUnwrap(controller.window)

    XCTAssertEqual(window.title, "Codex Echo Diagnostics")
    XCTAssertTrue(window.styleMask.contains(.titled))
    XCTAssertTrue(window.styleMask.contains(.closable))
    XCTAssertTrue(window.styleMask.contains(.miniaturizable))
    XCTAssertTrue(window.styleMask.contains(.resizable))
    XCTAssertFalse(window.isReleasedWhenClosed)
    XCTAssertEqual(window.tabbingMode, .disallowed)
  }

  @MainActor
  func testDiagnosticsWindowStartsCompactWithoutRestrictingResize() throws {
    let viewModel = SupportDiagnosticsViewModel(
      makeReport: { "diagnostics" },
      clipboard: RecordingDiagnosticsClipboard()
    )
    let controller = SupportDiagnosticsWindowFactory.make(
      viewModel: viewModel,
      savesFrame: false
    )
    let window = try XCTUnwrap(controller.window)

    XCTAssertEqual(
      window.contentRect(forFrameRect: window.frame).size,
      SupportDiagnosticsWindowFactory.defaultContentSize
    )
    XCTAssertEqual(window.contentMinSize, NSSize(width: 500, height: 340))
  }
}

private final class RecordingDiagnosticsClipboard: DiagnosticsClipboardWriting {
  private(set) var strings: [String] = []

  @discardableResult
  func write(_ string: String) -> Bool {
    strings.append(string)
    return true
  }
}

private extension SupportDiagnosticsSnapshot {
  static let fixture = SupportDiagnosticsSnapshot(
    echoVersion: "0.5.2",
    echoBuild: "42",
    operatingSystemVersion: "15.6",
    architecture: "arm64",
    codexAppVersion: .installed(version: "1.2.3", build: "456"),
    desktopAppState: .running,
    ipc: CodexIPCDiagnosticsSnapshot(
      state: .connected,
      endpointAttempts: [
        .init(endpoint: .canonical, result: .connected),
        .init(endpoint: .legacy, result: .notAttempted),
      ],
      connectionFailureCount: 0,
      lastFailure: nil
    ),
    appServer: CodexAppServerDiagnosticsSnapshot(
      state: .running,
      taskCatalogState: .available,
      capacityState: .available,
      connectionFailureCount: 0,
      lastFailure: nil
    )
  )
}
