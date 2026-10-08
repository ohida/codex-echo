import Darwin
import Foundation
import XCTest

@testable import CodexEcho

@MainActor
final class CodexCapacityMCPRegistrationTests: XCTestCase {
  func testInspectionUsesFreshGlobalListFromNeutralApplicationSupportDirectory() async
    throws
  {
    let fixture = try RegistrationFixture(
      results: [.success(.init(terminationStatus: 0, standardOutput: Data("[]".utf8)))]
    )

    let inspection = await fixture.service.inspect()

    XCTAssertEqual(inspection, .notConfigured)
    let invocations = await fixture.runner.invocations
    XCTAssertEqual(invocations.count, 1)
    XCTAssertEqual(invocations[0].executableURL, fixture.codexExecutableURL)
    XCTAssertEqual(invocations[0].arguments, ["mcp", "list", "--json"])
    XCTAssertEqual(
      invocations[0].currentDirectoryURL,
      fixture.applicationSupportURL
    )
    XCTAssertEqual(invocations[0].limits, .list)
  }

  func testExactEnabledStdioRegistrationIsConfigured() async throws {
    let fixture = try RegistrationFixture(
      results: [.success(.init(
        terminationStatus: 0,
        standardOutput: registrationJSON(
          enabled: true,
          command: "__ECHO_EXECUTABLE__",
          args: ["--mcp-stdio"]
        )
      ))]
    )
    await fixture.replaceEchoPlaceholder()

    let inspection = await fixture.service.inspect()
    let invocations = await fixture.runner.invocations
    XCTAssertEqual(inspection, .configured)
    XCTAssertEqual(invocations.count, 1)
  }

  func testExistingDisabledOrMismatchedRegistrationIsNeverReplaced() async throws {
    let cases: [(Bool, String, [String], String)] = [
      (false, "__ECHO_EXECUTABLE__", ["--mcp-stdio"], "disabled"),
      (true, "/Applications/Old Codex Echo.app/Contents/MacOS/CodexEcho", ["--mcp-stdio"], "old path"),
      (true, "__ECHO_EXECUTABLE__", ["--other"], "other args"),
    ]

    for (enabled, command, args, label) in cases {
      let fixture = try RegistrationFixture(
        results: [.success(.init(
          terminationStatus: 0,
          standardOutput: registrationJSON(
            enabled: enabled,
            command: command,
            args: args
          )
        ))]
      )
      await fixture.replaceEchoPlaceholder()

      let inspection = await fixture.service.setUp()
      XCTAssertEqual(
        inspection,
        .existingRegistrationNeedsReview,
        label
      )
      let invocations = await fixture.runner.invocations
      XCTAssertEqual(invocations.map(\.arguments), [["mcp", "list", "--json"]], label)
    }
  }

  func testSetupUsesArgvWithoutShellAndRequiresMatchingPostflight() async throws {
    let fixture = try RegistrationFixture(
      echoExecutableName: "Codex Echo With Spaces",
      results: [
        .success(.init(terminationStatus: 0, standardOutput: Data("[]".utf8))),
        .success(.init(terminationStatus: 0, standardOutput: Data())),
        .success(.init(
          terminationStatus: 0,
          standardOutput: registrationJSON(
            enabled: true,
            command: "__ECHO_EXECUTABLE__",
            args: ["--mcp-stdio"]
          )
        )),
      ]
    )
    await fixture.replaceEchoPlaceholder()

    let inspection = await fixture.service.setUp()
    XCTAssertEqual(inspection, .configured)
    let invocations = await fixture.runner.invocations
    XCTAssertEqual(invocations.count, 3)
    XCTAssertEqual(invocations[0].arguments, ["mcp", "list", "--json"])
    XCTAssertEqual(
      invocations[1].arguments,
      [
        "mcp", "add", "codex-echo", "--",
        fixture.echoExecutableURL.path, "--mcp-stdio",
      ]
    )
    XCTAssertEqual(invocations[1].limits, .add)
    XCTAssertEqual(invocations[2].arguments, ["mcp", "list", "--json"])
    XCTAssertTrue(invocations.allSatisfy {
      $0.executableURL == fixture.codexExecutableURL
        && $0.currentDirectoryURL == fixture.applicationSupportURL
    })
  }

  func testPostflightMismatchIsNotReportedAsConfigured() async throws {
    let fixture = try RegistrationFixture(
      results: [
        .success(.init(terminationStatus: 0, standardOutput: Data("[]".utf8))),
        .success(.init(terminationStatus: 0, standardOutput: Data())),
        .success(.init(
          terminationStatus: 0,
          standardOutput: registrationJSON(
            enabled: true,
            command: "/tmp/not-echo",
            args: ["--mcp-stdio"]
          )
        )),
      ]
    )

    let inspection = await fixture.service.setUp()
    XCTAssertEqual(inspection, .existingRegistrationNeedsReview)
  }

  func testRemoveUsesFreshExactPreflightAndRequiresMissingPostflight() async throws {
    let fixture = try RegistrationFixture(
      results: [
        .success(.init(
          terminationStatus: 0,
          standardOutput: registrationJSON(
            enabled: true,
            command: "__ECHO_EXECUTABLE__",
            args: ["--mcp-stdio"]
          )
        )),
        .success(.init(terminationStatus: 0, standardOutput: Data())),
        .success(.init(terminationStatus: 0, standardOutput: Data("[]".utf8))),
      ]
    )
    await fixture.replaceEchoPlaceholder()

    let inspection = await fixture.service.remove()

    XCTAssertEqual(inspection, .notConfigured)
    let invocations = await fixture.runner.invocations
    XCTAssertEqual(invocations.count, 3)
    XCTAssertEqual(invocations[0].arguments, ["mcp", "list", "--json"])
    XCTAssertEqual(invocations[1].arguments, ["mcp", "remove", "codex-echo"])
    XCTAssertEqual(invocations[1].limits, .remove)
    XCTAssertEqual(invocations[2].arguments, ["mcp", "list", "--json"])
    XCTAssertTrue(invocations.allSatisfy {
      $0.currentDirectoryURL == fixture.applicationSupportURL
    })
  }

  func testRemoveNeverTouchesAMissingOrMismatchedRegistration() async throws {
    let cases: [(Data, CodexCapacityMCPRegistrationInspection, String)] = [
      (Data("[]".utf8), .notConfigured, "missing"),
      (
        registrationJSON(
          enabled: false,
          command: "__ECHO_EXECUTABLE__",
          args: ["--mcp-stdio"]
        ),
        .existingRegistrationNeedsReview,
        "disabled"
      ),
      (
        registrationJSON(
          enabled: true,
          command: "/tmp/other-echo",
          args: ["--mcp-stdio"]
        ),
        .existingRegistrationNeedsReview,
        "other command"
      ),
    ]

    for (output, expected, label) in cases {
      let fixture = try RegistrationFixture(
        results: [.success(.init(terminationStatus: 0, standardOutput: output))]
      )
      await fixture.replaceEchoPlaceholder()

      let inspection = await fixture.service.remove()

      XCTAssertEqual(inspection, expected, label)
      let invocations = await fixture.runner.invocations
      XCTAssertEqual(invocations.map(\.arguments), [["mcp", "list", "--json"]])
    }
  }

  func testRemoveDoesNotClaimSuccessWhileExactRegistrationRemains() async throws {
    let configured = registrationJSON(
      enabled: true,
      command: "__ECHO_EXECUTABLE__",
      args: ["--mcp-stdio"]
    )
    let fixture = try RegistrationFixture(
      results: [
        .success(.init(terminationStatus: 0, standardOutput: configured)),
        .success(.init(terminationStatus: 1, standardOutput: Data())),
        .success(.init(terminationStatus: 0, standardOutput: configured)),
      ]
    )
    await fixture.replaceEchoPlaceholder()

    let inspection = await fixture.service.remove()

    XCTAssertEqual(inspection, .checkFailed)
    let invocations = await fixture.runner.invocations
    XCTAssertEqual(invocations.count, 3)
  }

  func testListFailuresRemainRetryableCheckFailures() async throws {
    let results: [Result<CodexCapacityMCPCommandResult, CodexCapacityMCPCommandFailure>] = [
      .failure(.timedOut),
      .failure(.standardOutputTooLarge),
      .success(.init(terminationStatus: 1, standardOutput: Data("[]".utf8))),
      .success(.init(terminationStatus: 0, standardOutput: Data("not json".utf8))),
    ]

    for result in results {
      let fixture = try RegistrationFixture(results: [result])
      let inspection = await fixture.service.inspect()
      XCTAssertEqual(inspection, .checkFailed)
    }
  }

  func testDiskImageAndAppTranslocationAreRejectedBeforeRunningCodex() async throws {
    for bundlePath in [
      "/Volumes/Codex Echo/Codex Echo.app",
      "/private/var/folders/example/AppTranslocation/Codex Echo.app",
    ] {
      let fixture = try RegistrationFixture(
        bundleURL: URL(fileURLWithPath: bundlePath),
        results: []
      )

      let inspection = await fixture.service.inspect()
      let invocations = await fixture.runner.invocations
      XCTAssertEqual(inspection, .unsupportedInstallation)
      XCTAssertEqual(invocations.count, 0)
    }
  }

  func testCanonicalPathComparisonAcceptsASymlinkedCommand() async throws {
    let fixture = try RegistrationFixture(results: [])
    let symlinkURL = fixture.temporaryDirectory
      .appendingPathComponent("echo-symlink")
    try FileManager.default.createSymbolicLink(
      at: symlinkURL,
      withDestinationURL: fixture.echoExecutableURL
    )
    await fixture.runner.append(
      .success(.init(
        terminationStatus: 0,
        standardOutput: registrationJSON(
          enabled: true,
          command: symlinkURL.path,
          args: ["--mcp-stdio"]
        )
      ))
    )

    let inspection = await fixture.service.inspect()
    XCTAssertEqual(inspection, .configured)
  }

  func testSystemRunnerEnforcesStandardOutputLimit() async throws {
    let directory = FileManager.default.temporaryDirectory
    let result = await SystemCodexCapacityMCPCommandRunner().run(
      executableURL: URL(fileURLWithPath: "/usr/bin/yes"),
      arguments: [],
      currentDirectoryURL: directory,
      limits: CodexCapacityMCPCommandLimits(
        timeout: 2,
        maximumStandardOutputByteCount: 1_024,
        maximumStandardErrorByteCount: 1_024
      )
    )

    XCTAssertEqual(result, .failure(.standardOutputTooLarge))
  }

  func testSystemRunnerEnforcesStandardErrorLimit() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let executableURL = directory.appendingPathComponent("write-stderr")
    try Data("#!/bin/sh\nwhile :; do echo error >&2; done\n".utf8)
      .write(to: executableURL)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: executableURL.path
    )

    let result = await SystemCodexCapacityMCPCommandRunner().run(
      executableURL: executableURL,
      arguments: [],
      currentDirectoryURL: directory,
      limits: CodexCapacityMCPCommandLimits(
        timeout: 2,
        maximumStandardOutputByteCount: 1_024,
        maximumStandardErrorByteCount: 1_024
      )
    )

    XCTAssertEqual(result, .failure(.standardErrorTooLarge))
  }

  func testSystemRunnerEnforcesTimeout() async {
    let result = await SystemCodexCapacityMCPCommandRunner().run(
      executableURL: URL(fileURLWithPath: "/bin/sleep"),
      arguments: ["5"],
      currentDirectoryURL: FileManager.default.temporaryDirectory,
      limits: CodexCapacityMCPCommandLimits(
        timeout: 0.05,
        maximumStandardOutputByteCount: 1_024,
        maximumStandardErrorByteCount: 1_024
      )
    )

    XCTAssertEqual(result, .failure(.timedOut))
  }

  func testSystemRunnerBoundsInheritedPipeAfterParentExits() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let childPIDFile = directory.appendingPathComponent("child-pid")
    defer {
      if let contents = try? String(contentsOf: childPIDFile, encoding: .utf8),
        let childPID = Int32(contents.trimmingCharacters(in: .whitespacesAndNewlines))
      {
        _ = Darwin.kill(childPID, SIGKILL)
      }
    }
    let script = directory.appendingPathComponent("spawn-inheriting-child")
    try Data("#!/bin/sh\nsleep 5 &\nprintf '%s' \"$!\" > \"$1\"\nexit 0\n".utf8)
      .write(to: script)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

    let startedAt = ProcessInfo.processInfo.systemUptime
    let result = await SystemCodexCapacityMCPCommandRunner().run(
      executableURL: script,
      arguments: [childPIDFile.path],
      currentDirectoryURL: directory,
      limits: .init(timeout: 1, maximumStandardOutputByteCount: 1_024,
        maximumStandardErrorByteCount: 1_024)
    )

    XCTAssertEqual(result, .failure(.timedOut))
    XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - startedAt, 2)
    XCTAssertTrue(FileManager.default.fileExists(atPath: childPIDFile.path))
  }

  func testCancelledQueuedCommandNeverLaunches() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let marker = directory.appendingPathComponent("launched")
    let runner = SystemCodexCapacityMCPCommandRunner()
    let first = Task {
      await runner.run(executableURL: URL(fileURLWithPath: "/bin/sleep"),
        arguments: ["0.3"], currentDirectoryURL: directory,
        limits: .init(timeout: 1, maximumStandardOutputByteCount: 1_024,
          maximumStandardErrorByteCount: 1_024))
    }
    try await Task.sleep(for: .milliseconds(50))
    let queued = Task {
      await runner.run(executableURL: URL(fileURLWithPath: "/usr/bin/touch"),
        arguments: [marker.path], currentDirectoryURL: directory,
        limits: .init(timeout: 1, maximumStandardOutputByteCount: 1_024,
          maximumStandardErrorByteCount: 1_024))
    }
    try await Task.sleep(for: .milliseconds(50))
    queued.cancel()

    let queuedResult = await queued.value
    XCTAssertEqual(queuedResult, .failure(.cancelled))
    _ = await first.value
    XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
  }

  func testCancelledPreflightDoesNotStartSetupOrRemoval() async throws {
    for removing in [false, true] {
      let fixture = try RegistrationFixture(results: [])
      let preflight = removing
        ? registrationJSON(enabled: true, command: fixture.echoExecutableURL.path,
          args: ["--mcp-stdio"])
        : Data("[]".utf8)
      let runner = PausingRegistrationCommandRunner(
        result: .success(.init(terminationStatus: 0, standardOutput: preflight))
      )
      let service = CodexCapacityMCPRegistrationService(
        commandRunner: runner,
        codexExecutableURL: { [fixture] in fixture.codexExecutableURL },
        echoExecutableURL: { [fixture] in fixture.echoExecutableURL },
        echoBundleURL: { URL(fileURLWithPath: "/Applications/Codex Echo.app") },
        applicationSupportURL: { [fixture] in fixture.applicationSupportURL }
      )
      let operation = Task { @MainActor in
        if removing { return await service.remove() }
        return await service.setUp()
      }
      while await runner.invocationCount == 0 { await Task.yield() }
      operation.cancel()
      await runner.resume()
      _ = await operation.value
      let invocationCount = await runner.invocationCount
      XCTAssertEqual(invocationCount, 1)
    }
  }

  func testCancelledPaneInspectionCannotReplaceNewerInspection() async {
    let service = PausingRegistrationServiceSpy()
    let controller = CodexCapacityMCPRegistrationController(service: service)
    controller.setCapacityPaneVisible(true)
    while service.inspectCallCount < 1 { await Task.yield() }
    controller.setCapacityPaneVisible(false)
    controller.setCapacityPaneVisible(true)
    while service.inspectCallCount < 2 { await Task.yield() }

    service.resumeInspection(at: 1, with: .configured)
    await settleMainActorTasks()
    XCTAssertEqual(controller.status, .configured)
    service.resumeInspection(at: 0, with: .notConfigured)
    await settleMainActorTasks()
    XCTAssertEqual(controller.status, .configured)
  }

  func testControllerDoesNothingUntilCapacityPaneIsVisible() async {
    let service = RegistrationServiceSpy(result: .notConfigured)
    let controller = CodexCapacityMCPRegistrationController(service: service)

    controller.refreshIfVisible()
    controller.setUp()
    await settleMainActorTasks()
    XCTAssertEqual(service.inspectCallCount, 0)
    XCTAssertEqual(service.setupCallCount, 0)

    controller.setCapacityPaneVisible(true)
    await settleMainActorTasks()
    XCTAssertEqual(service.inspectCallCount, 1)
    XCTAssertEqual(controller.status, .notConfigured)

    controller.setCapacityPaneVisible(false)
    controller.refreshIfVisible()
    controller.tryAgain()
    controller.setUp()
    await settleMainActorTasks()
    XCTAssertEqual(service.inspectCallCount, 1)
    XCTAssertEqual(service.setupCallCount, 0)
  }

  func testControllerSetupAndRetryAreExplicitVisiblePaneActions() async {
    let service = RegistrationServiceSpy(result: .notConfigured)
    let controller = CodexCapacityMCPRegistrationController(service: service)
    controller.setCapacityPaneVisible(true)
    await settleMainActorTasks()

    service.result = .configured
    controller.setUp()
    await settleMainActorTasks()
    XCTAssertEqual(service.setupCallCount, 1)
    XCTAssertEqual(controller.status, .configured)

    service.result = .checkFailed
    controller.refreshIfVisible()
    await settleMainActorTasks()
    XCTAssertEqual(controller.status, .checkFailed)

    service.result = .notConfigured
    controller.tryAgain()
    await settleMainActorTasks()
    XCTAssertEqual(service.inspectCallCount, 3)
    XCTAssertEqual(controller.status, .notConfigured)
  }

  func testControllerRemovesOnlyAVisibleConfiguredRegistration() async {
    let service = RegistrationServiceSpy(result: .configured)
    let controller = CodexCapacityMCPRegistrationController(service: service)

    controller.remove()
    await settleMainActorTasks()
    XCTAssertEqual(service.removeCallCount, 0)

    controller.setCapacityPaneVisible(true)
    await settleMainActorTasks()
    XCTAssertEqual(controller.status, .configured)

    service.result = .notConfigured
    controller.remove()
    await settleMainActorTasks()
    XCTAssertEqual(service.removeCallCount, 1)
    XCTAssertEqual(controller.status, .removed)

    service.result = .configured
    controller.setUp()
    await settleMainActorTasks()
    XCTAssertEqual(service.setupCallCount, 1)
    XCTAssertEqual(controller.status, .configured)
  }

  func testControllerKeepsRemovalFailureDistinctAndRetriesRemoval() async {
    let service = RegistrationServiceSpy(result: .configured)
    let controller = CodexCapacityMCPRegistrationController(service: service)
    controller.setCapacityPaneVisible(true)
    await settleMainActorTasks()

    service.result = .checkFailed
    controller.remove()
    await settleMainActorTasks()
    XCTAssertEqual(controller.status, .removeFailed)

    service.result = .notConfigured
    controller.retryRemove()
    await settleMainActorTasks()
    XCTAssertEqual(service.removeCallCount, 2)
    XCTAssertEqual(controller.status, .removed)
  }

  private func registrationJSON(
    enabled: Bool,
    command: String,
    args: [String]
  ) -> Data {
    let object: [[String: Any]] = [[
      "name": "codex-echo",
      "enabled": enabled,
      "disabled_reason": enabled ? NSNull() : "disabled",
      "transport": [
        "type": "stdio",
        "command": command,
        "args": args,
        "env": NSNull(),
        "env_vars": [],
        "cwd": NSNull(),
      ],
    ]]
    return try! JSONSerialization.data(withJSONObject: object)
  }

  private func settleMainActorTasks() async {
    for _ in 0..<4 { await Task.yield() }
  }
}

private actor RegistrationCommandRunnerSpy: CodexCapacityMCPCommandRunning {
  struct Invocation: Equatable, Sendable {
    let executableURL: URL
    let arguments: [String]
    let currentDirectoryURL: URL
    let limits: CodexCapacityMCPCommandLimits
  }

  private(set) var invocations: [Invocation] = []
  private var results:
    [Result<CodexCapacityMCPCommandResult, CodexCapacityMCPCommandFailure>]

  init(
    results: [Result<CodexCapacityMCPCommandResult, CodexCapacityMCPCommandFailure>]
  ) {
    self.results = results
  }

  func append(
    _ result: Result<CodexCapacityMCPCommandResult, CodexCapacityMCPCommandFailure>
  ) {
    results.append(result)
  }

  func replaceEchoPlaceholder(with path: String) {
    results = results.map { result in
      result.map { commandResult in
        guard
          let string = String(data: commandResult.standardOutput, encoding: .utf8)
        else { return commandResult }
        return CodexCapacityMCPCommandResult(
          terminationStatus: commandResult.terminationStatus,
          standardOutput: Data(
            string.replacingOccurrences(of: "__ECHO_EXECUTABLE__", with: path).utf8
          )
        )
      }
    }
  }

  func run(
    executableURL: URL,
    arguments: [String],
    currentDirectoryURL: URL,
    limits: CodexCapacityMCPCommandLimits
  ) async -> Result<CodexCapacityMCPCommandResult, CodexCapacityMCPCommandFailure> {
    invocations.append(
      Invocation(
        executableURL: executableURL,
        arguments: arguments,
        currentDirectoryURL: currentDirectoryURL,
        limits: limits
      )
    )
    guard !results.isEmpty else { return .failure(.launchFailed) }
    return results.removeFirst()
  }
}

private actor PausingRegistrationCommandRunner: CodexCapacityMCPCommandRunning {
  private let result: Result<CodexCapacityMCPCommandResult, CodexCapacityMCPCommandFailure>
  private var continuation: CheckedContinuation<Void, Never>?
  private(set) var invocationCount = 0

  init(result: Result<CodexCapacityMCPCommandResult, CodexCapacityMCPCommandFailure>) {
    self.result = result
  }

  func run(
    executableURL: URL, arguments: [String], currentDirectoryURL: URL,
    limits: CodexCapacityMCPCommandLimits
  ) async -> Result<CodexCapacityMCPCommandResult, CodexCapacityMCPCommandFailure> {
    invocationCount += 1
    if invocationCount == 1 {
      await withCheckedContinuation { continuation = $0 }
    }
    return result
  }

  func resume() {
    continuation?.resume()
    continuation = nil
  }
}

@MainActor
private final class RegistrationServiceSpy: CodexCapacityMCPRegistrationServicing {
  var result: CodexCapacityMCPRegistrationInspection
  private(set) var inspectCallCount = 0
  private(set) var setupCallCount = 0
  private(set) var removeCallCount = 0

  init(result: CodexCapacityMCPRegistrationInspection) {
    self.result = result
  }

  func inspect() async -> CodexCapacityMCPRegistrationInspection {
    inspectCallCount += 1
    return result
  }

  func setUp() async -> CodexCapacityMCPRegistrationInspection {
    setupCallCount += 1
    return result
  }

  func remove() async -> CodexCapacityMCPRegistrationInspection {
    removeCallCount += 1
    return result
  }
}

@MainActor
private final class PausingRegistrationServiceSpy: CodexCapacityMCPRegistrationServicing {
  private(set) var inspectCallCount = 0
  private var inspections:
    [CheckedContinuation<CodexCapacityMCPRegistrationInspection, Never>] = []

  func inspect() async -> CodexCapacityMCPRegistrationInspection {
    inspectCallCount += 1
    return await withCheckedContinuation { inspections.append($0) }
  }

  func resumeInspection(
    at index: Int, with result: CodexCapacityMCPRegistrationInspection
  ) {
    inspections[index].resume(returning: result)
  }

  func setUp() async -> CodexCapacityMCPRegistrationInspection { .checkFailed }
  func remove() async -> CodexCapacityMCPRegistrationInspection { .checkFailed }
}

@MainActor
private final class RegistrationFixture {
  let temporaryDirectory: URL
  let codexExecutableURL: URL
  let echoExecutableURL: URL
  let applicationSupportURL: URL
  let runner: RegistrationCommandRunnerSpy
  let service: CodexCapacityMCPRegistrationService

  init(
    bundleURL: URL = URL(fileURLWithPath: "/Applications/Codex Echo.app"),
    echoExecutableName: String = "CodexEcho",
    results: [Result<CodexCapacityMCPCommandResult, CodexCapacityMCPCommandFailure>]
  ) throws {
    temporaryDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: temporaryDirectory,
      withIntermediateDirectories: true
    )
    codexExecutableURL = temporaryDirectory.appendingPathComponent("codex")
    echoExecutableURL = temporaryDirectory.appendingPathComponent(echoExecutableName)
    applicationSupportURL = temporaryDirectory
      .appendingPathComponent("Application Support", isDirectory: true)
    for executableURL in [codexExecutableURL, echoExecutableURL] {
      try Data().write(to: executableURL)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: executableURL.path
      )
    }
    runner = RegistrationCommandRunnerSpy(results: results)
    service = CodexCapacityMCPRegistrationService(
      commandRunner: runner,
      codexExecutableURL: { [codexExecutableURL] in codexExecutableURL },
      echoExecutableURL: { [echoExecutableURL] in echoExecutableURL },
      echoBundleURL: { bundleURL },
      applicationSupportURL: { [applicationSupportURL] in applicationSupportURL }
    )
  }

  deinit {
    try? FileManager.default.removeItem(at: temporaryDirectory)
  }

  func replaceEchoPlaceholder() async {
    await runner.replaceEchoPlaceholder(with: echoExecutableURL.path)
  }
}
