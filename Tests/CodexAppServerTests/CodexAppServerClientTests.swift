import Foundation
import XCTest

@testable import CodexAppServer

final class CodexAppServerClientTests: XCTestCase {
  func testJSONLDecoderExtractsFragmentedLinesWithoutRetainingCompletedBytes() throws {
    var decoder = CodexAppServerJSONLDecoder(maximumLineByteCount: 5)

    XCTAssertEqual(try decoder.append(Data("abc".utf8)), [])
    XCTAssertEqual(decoder.bufferedByteCount, 3)
    XCTAssertEqual(
      try decoder.append(Data("de\nx\n".utf8)),
      [Data("abcde".utf8), Data("x".utf8)]
    )
    XCTAssertEqual(decoder.bufferedByteCount, 0)
  }

  func testJSONLDecoderRejectsAnUnterminatedOversizedLine() throws {
    var decoder = CodexAppServerJSONLDecoder(maximumLineByteCount: 5)

    XCTAssertEqual(try decoder.append(Data("1234".utf8)), [])
    XCTAssertThrowsError(try decoder.append(Data("56".utf8))) { error in
      XCTAssertEqual(error as? CodexAppServerJSONLDecoderError, .lineTooLong)
    }
    XCTAssertLessThanOrEqual(decoder.bufferedByteCount, 5)
  }

  func testExecutableFingerprintDetectsAReplacedCodexBinary() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }

    let executableURL = directory.appendingPathComponent("codex")
    try Data("old".utf8).write(to: executableURL)
    let launched = try XCTUnwrap(
      CodexAppServerExecutableFingerprint(executableURL: executableURL)
    )
    XCTAssertFalse(
      CodexAppServerClient.shouldRestartForExecutableChange(
        launched: nil,
        current: launched
      )
    )
    XCTAssertFalse(
      CodexAppServerClient.shouldRestartForExecutableChange(
        launched: launched,
        current: nil
      )
    )
    XCTAssertFalse(
      CodexAppServerClient.shouldRestartForExecutableChange(
        launched: launched,
        current: launched
      )
    )

    let replacementURL = directory.appendingPathComponent("codex-new")
    try Data("new version".utf8).write(to: replacementURL)
    try FileManager.default.removeItem(at: executableURL)
    try FileManager.default.moveItem(at: replacementURL, to: executableURL)
    let current = try XCTUnwrap(
      CodexAppServerExecutableFingerprint(executableURL: executableURL)
    )

    XCTAssertNotEqual(launched, current)
    XCTAssertTrue(
      CodexAppServerClient.shouldRestartForExecutableChange(
        launched: launched,
        current: current
      )
    )
  }

  @MainActor
  func testInvalidatedAppServerGenerationDropsPendingEvents() async {
    let gate = CodexAppServerEventDeliveryGate()
    let oldGeneration = gate.beginGeneration()
    var deliveredStates: [CodexAppServerConnectionState] = []

    gate.deliver(
      .connectionStateChanged(.running),
      generation: oldGeneration
    ) { event in
      guard case .connectionStateChanged(let state) = event else { return }
      deliveredStates.append(state)
    }

    let freshGeneration = gate.beginGeneration()
    await Task.yield()
    XCTAssertTrue(deliveredStates.isEmpty)

    gate.deliver(
      .connectionStateChanged(.starting),
      generation: freshGeneration
    ) { event in
      guard case .connectionStateChanged(let state) = event else { return }
      deliveredStates.append(state)
    }

    await Task.yield()
    XCTAssertEqual(deliveredStates, [.starting])
  }

  func testClientVersionUsesTheApplicationBundleVersion() {
    XCTAssertEqual(
      CodexAppServerClient.clientVersion(
        infoDictionary: ["CFBundleShortVersionString": "0.3.2"]
      ),
      "0.3.2"
    )
  }

  func testClientVersionFallsBackForAnUnbundledDevelopmentExecutable() {
    XCTAssertEqual(CodexAppServerClient.clientVersion(infoDictionary: nil), "development")
    XCTAssertEqual(
      CodexAppServerClient.clientVersion(
        infoDictionary: ["CFBundleShortVersionString": ""]
      ),
      "development"
    )
  }

  @MainActor
  func testMissingExecutableProducesSanitizedDiagnostics() async {
    let executableURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("missing-\(UUID().uuidString)")
    let client = CodexAppServerClient(executableURL: executableURL)
    let failed = expectation(description: "app-server failed")
    client.eventHandler = { event in
      guard case .connectionStateChanged(.failed) = event else { return }
      failed.fulfill()
    }

    client.start()
    await fulfillment(of: [failed], timeout: 1)
    let snapshot = client.diagnosticsSnapshot()
    client.stop()

    XCTAssertEqual(snapshot.state, .failed)
    XCTAssertEqual(snapshot.taskCatalogState, .notRequested)
    XCTAssertEqual(snapshot.capacityState, .notRequested)
    XCTAssertEqual(snapshot.connectionFailureCount, 1)
    XCTAssertEqual(
      snapshot.lastFailure,
      CodexAppServerDiagnosticsFailure(
        phase: .executableValidation,
        kind: .executableUnavailable
      )
    )
  }

  @MainActor
  func testDiagnosticsSeparateProcessReadinessFromCapabilityResponses() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }

    let executableURL = directory.appendingPathComponent("mock-codex")
    let script = """
      #!/bin/sh
      IFS= read -r initialize
      printf '%s\n' '{"id":1,"result":{}}'
      IFS= read -r initialized
      IFS= read -r thread_list
      IFS= read -r rate_limits
      sleep 1
      printf '%s\n' '{"id":2,"result":{"data":[]}}'
      printf '%s\n' '{"id":3,"result":{"rateLimits":{"primary":{"usedPercent":12}}}}'
      while IFS= read -r message; do :; done
      """
    try Data(script.utf8).write(to: executableURL)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: executableURL.path
    )

    let client = CodexAppServerClient(executableURL: executableURL)
    let running = expectation(description: "app-server running")
    let catalogAvailable = expectation(description: "task catalog available")
    let capacityAvailable = expectation(description: "capacity available")
    client.eventHandler = { event in
      switch event {
      case .connectionStateChanged(.running): running.fulfill()
      case .threadsChanged: catalogAvailable.fulfill()
      case .usageChanged: capacityAvailable.fulfill()
      default: break
      }
    }

    client.start()
    await fulfillment(of: [running], timeout: 1)
    var snapshot = client.diagnosticsSnapshot()
    XCTAssertEqual(snapshot.state, .running)
    XCTAssertEqual(snapshot.taskCatalogState, .awaitingFirstResponse)
    XCTAssertEqual(snapshot.capacityState, .awaitingFirstResponse)

    await fulfillment(
      of: [catalogAvailable, capacityAvailable],
      timeout: 2
    )
    snapshot = client.diagnosticsSnapshot()
    client.stop()

    XCTAssertEqual(snapshot.taskCatalogState, .available)
    XCTAssertEqual(snapshot.capacityState, .available)
    XCTAssertEqual(snapshot.connectionFailureCount, 0)
    XCTAssertNil(snapshot.lastFailure)
  }

  func testMalformedLineIsIsolatedBeforeValidResponses() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }

    let executableURL = directory.appendingPathComponent("mock-codex")
    let script = """
      #!/bin/sh
      IFS= read -r initialize
      printf '%s\\n' 'not-json'
      printf '%s\\n' '{"id":1,"result":{}}'
      IFS= read -r initialized
      IFS= read -r thread_list
      IFS= read -r rate_limits
      printf '%s\\n' '{"id":2,"result":{"data":[]}}'
      printf '%s\\n' '{"id":3,"result":{"rateLimits":{"primary":{"usedPercent":12}}}}'
      while IFS= read -r message; do :; done
      """
    try Data(script.utf8).write(to: executableURL)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: executableURL.path
    )

    let client = CodexAppServerClient(
      executableURL: executableURL,
      maximumResponseLineByteCount: 1_024,
      responseTimeout: 2,
      reconnectDelay: 1
    )
    client.start()
    let deadline = Date().addingTimeInterval(3)
    var snapshot = client.diagnosticsSnapshot()
    while Date() < deadline {
      snapshot = client.diagnosticsSnapshot()
      if snapshot.state == .running,
        snapshot.taskCatalogState == .available,
        snapshot.capacityState == .available
      {
        break
      }
      Thread.sleep(forTimeInterval: 0.01)
    }
    client.stop()

    XCTAssertEqual(snapshot.state, .running)
    XCTAssertEqual(snapshot.taskCatalogState, .available)
    XCTAssertEqual(snapshot.capacityState, .available)
    XCTAssertEqual(snapshot.connectionFailureCount, 0)
    XCTAssertNil(snapshot.lastFailure)
  }

  func testOversizedResponseReconnectsAndRecovers() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }

    let markerURL = directory.appendingPathComponent("reconnected")
    let executableURL = directory.appendingPathComponent("mock-codex")
    let script = """
      #!/bin/sh
      if [ -e '\(markerURL.path)' ]; then
        recovering=1
      else
        recovering=0
        touch '\(markerURL.path)'
      fi

      request_id() {
        printf '%s' "$1" | sed -E 's/.*"id":([0-9]+).*/\\1/'
      }

      IFS= read -r initialize
      if [ "$recovering" -eq 0 ]; then
        printf '%0160d' 0
      else
        initialize_id="$(request_id "$initialize")"
        printf '{"id":%s,"result":{}}\\n' "$initialize_id"
        IFS= read -r initialized
        IFS= read -r thread_list
        IFS= read -r rate_limits
        thread_list_id="$(request_id "$thread_list")"
        rate_limits_id="$(request_id "$rate_limits")"
        printf '{"id":%s,"result":{"data":[]}}\\n' "$thread_list_id"
        printf '{"id":%s,"result":{"rateLimits":{"primary":{"usedPercent":12}}}}\\n' "$rate_limits_id"
      fi

      while IFS= read -r message; do :; done
      """
    try Data(script.utf8).write(to: executableURL)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: executableURL.path
    )

    let client = CodexAppServerClient(
      executableURL: executableURL,
      maximumResponseLineByteCount: 128,
      responseTimeout: 2,
      reconnectDelay: 0.1
    )
    client.start()
    let deadline = Date().addingTimeInterval(4)
    var snapshot = client.diagnosticsSnapshot()
    while Date() < deadline {
      snapshot = client.diagnosticsSnapshot()
      if snapshot.state == .running,
        snapshot.taskCatalogState == .available,
        snapshot.capacityState == .available,
        snapshot.connectionFailureCount == 1
      {
        break
      }
      Thread.sleep(forTimeInterval: 0.01)
    }
    client.stop()

    XCTAssertEqual(snapshot.state, .running)
    XCTAssertEqual(snapshot.taskCatalogState, .available)
    XCTAssertEqual(snapshot.capacityState, .available)
    XCTAssertEqual(snapshot.connectionFailureCount, 1)
    XCTAssertEqual(
      snapshot.lastFailure,
      CodexAppServerDiagnosticsFailure(
        phase: .read,
        kind: .responseTooLarge
      )
    )
  }

  func testReconnectWaitsForATermIgnoringProcessToBeKilled() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }

    let firstProcessIdentifierURL = directory.appendingPathComponent("first-pid")
    let overlapURL = directory.appendingPathComponent("overlap")
    let executableURL = directory.appendingPathComponent("mock-codex")
    let script = """
      #!/bin/sh
      request_id() {
        printf '%s' "$1" | sed -E 's/.*"id":([0-9]+).*/\\1/'
      }

      if [ ! -e '\(firstProcessIdentifierURL.path)' ]; then
        printf '%s' "$$" > '\(firstProcessIdentifierURL.path)'
        trap '' TERM
        IFS= read -r initialize
        printf '%0160d' 0
        exec /usr/bin/tail -f /dev/null
      fi

      first_pid="$(cat '\(firstProcessIdentifierURL.path)')"
      if kill -0 "$first_pid" 2>/dev/null; then
        touch '\(overlapURL.path)'
      fi

      IFS= read -r initialize
      initialize_id="$(request_id "$initialize")"
      printf '{"id":%s,"result":{}}\\n' "$initialize_id"
      IFS= read -r initialized
      IFS= read -r thread_list
      IFS= read -r rate_limits
      thread_list_id="$(request_id "$thread_list")"
      rate_limits_id="$(request_id "$rate_limits")"
      printf '{"id":%s,"result":{"data":[]}}\\n' "$thread_list_id"
      printf '{"id":%s,"result":{"rateLimits":{"primary":{"usedPercent":12}}}}\\n' "$rate_limits_id"
      while IFS= read -r message; do :; done
      """
    try Data(script.utf8).write(to: executableURL)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: executableURL.path
    )

    let client = CodexAppServerClient(
      executableURL: executableURL,
      maximumResponseLineByteCount: 128,
      responseTimeout: 2,
      reconnectDelay: 0.05,
      terminationGracePeriod: 0.1
    )
    client.start()
    let deadline = Date().addingTimeInterval(4)
    var snapshot = client.diagnosticsSnapshot()
    while Date() < deadline {
      snapshot = client.diagnosticsSnapshot()
      if snapshot.state == .running,
        snapshot.taskCatalogState == .available,
        snapshot.capacityState == .available,
        snapshot.connectionFailureCount == 1
      {
        break
      }
      Thread.sleep(forTimeInterval: 0.01)
    }
    client.stop()

    let firstProcessIdentifier = try XCTUnwrap(
      Int32(String(contentsOf: firstProcessIdentifierURL, encoding: .utf8))
    )
    errno = 0
    XCTAssertEqual(Darwin.kill(firstProcessIdentifier, 0), -1)
    XCTAssertEqual(errno, ESRCH)
    XCTAssertFalse(FileManager.default.fileExists(atPath: overlapURL.path))
    XCTAssertEqual(snapshot.state, .running)
    XCTAssertEqual(snapshot.taskCatalogState, .available)
    XCTAssertEqual(snapshot.capacityState, .available)
    XCTAssertEqual(snapshot.connectionFailureCount, 1)
    XCTAssertEqual(
      snapshot.lastFailure,
      CodexAppServerDiagnosticsFailure(
        phase: .read,
        kind: .responseTooLarge
      )
    )
  }

  func testDeinitializationKillsAnActiveTermIgnoringProcess() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }

    let processIdentifierURL = directory.appendingPathComponent("pid")
    let executableURL = directory.appendingPathComponent("mock-codex")
    let script = """
      #!/bin/sh
      trap '' TERM
      printf '%s' "$$" > '\(processIdentifierURL.path)'
      exec /usr/bin/tail -f /dev/null
      """
    try Data(script.utf8).write(to: executableURL)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: executableURL.path
    )

    var client: CodexAppServerClient? = CodexAppServerClient(
      executableURL: executableURL,
      maximumResponseLineByteCount: 1_024,
      responseTimeout: 5,
      reconnectDelay: 1,
      terminationGracePeriod: 0.1
    )
    weak let weakClient = client
    client?.start()

    let launchDeadline = Date().addingTimeInterval(2)
    while Date() < launchDeadline,
      !FileManager.default.fileExists(atPath: processIdentifierURL.path)
    {
      Thread.sleep(forTimeInterval: 0.01)
    }
    let processIdentifier = try XCTUnwrap(
      Int32(String(contentsOf: processIdentifierURL, encoding: .utf8))
    )
    defer {
      if Darwin.kill(processIdentifier, 0) == 0 {
        _ = Darwin.kill(processIdentifier, SIGKILL)
      }
    }

    client = nil
    let terminationDeadline = Date().addingTimeInterval(2)
    while Date() < terminationDeadline {
      errno = 0
      if Darwin.kill(processIdentifier, 0) == -1, errno == ESRCH {
        break
      }
      Thread.sleep(forTimeInterval: 0.01)
    }

    XCTAssertNil(weakClient)
    errno = 0
    XCTAssertEqual(Darwin.kill(processIdentifier, 0), -1)
    XCTAssertEqual(errno, ESRCH)
  }

  func testWrongResponseIDsTimeOutThenReconnectAndRecover() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }

    let markerURL = directory.appendingPathComponent("reconnected")
    let executableURL = directory.appendingPathComponent("mock-codex")
    let script = """
      #!/bin/sh
      if [ -e '\(markerURL.path)' ]; then
        recovering=1
      else
        recovering=0
        touch '\(markerURL.path)'
      fi

      request_id() {
        printf '%s' "$1" | sed -E 's/.*"id":([0-9]+).*/\\1/'
      }

      IFS= read -r initialize
      initialize_id="$(request_id "$initialize")"
      printf '{"id":%s,"result":{}}\\n' "$initialize_id"
      IFS= read -r initialized
      IFS= read -r thread_list
      IFS= read -r rate_limits

      if [ "$recovering" -eq 0 ]; then
        printf '%s\\n' '{"id":999999,"result":{}}'
      else
        thread_list_id="$(request_id "$thread_list")"
        rate_limits_id="$(request_id "$rate_limits")"
        printf '{"id":%s,"result":{"data":[]}}\\n' "$thread_list_id"
        printf '{"id":%s,"result":{"rateLimits":{"primary":{"usedPercent":12}}}}\\n' "$rate_limits_id"
      fi

      while IFS= read -r message; do :; done
      """
    try Data(script.utf8).write(to: executableURL)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: executableURL.path
    )

    let client = CodexAppServerClient(
      executableURL: executableURL,
      maximumResponseLineByteCount: 1_024,
      responseTimeout: 0.75,
      reconnectDelay: 0.1
    )
    client.start()
    let deadline = Date().addingTimeInterval(4)
    var snapshot = client.diagnosticsSnapshot()
    while Date() < deadline {
      snapshot = client.diagnosticsSnapshot()
      if snapshot.state == .running,
        snapshot.taskCatalogState == .available,
        snapshot.capacityState == .available,
        snapshot.connectionFailureCount == 1
      {
        break
      }
      Thread.sleep(forTimeInterval: 0.01)
    }
    client.stop()

    XCTAssertEqual(snapshot.state, .running)
    XCTAssertEqual(snapshot.taskCatalogState, .available)
    XCTAssertEqual(snapshot.capacityState, .available)
    XCTAssertEqual(snapshot.connectionFailureCount, 1)
    XCTAssertEqual(
      snapshot.lastFailure,
      CodexAppServerDiagnosticsFailure(
        phase: .response,
        kind: .requestTimedOut
      )
    )
  }

  func testRateLimitResponseSelectsTheMainCodexBucket() {
    let result: [String: Any] = [
      "rateLimits": [
        "limitId": "codex_bengalfox",
        "primary": [
          "usedPercent": 0,
          "windowDurationMins": 10_080,
          "resetsAt": 1_785_480_227,
        ],
      ],
      "rateLimitsByLimitId": [
        "codex": [
          "limitId": "codex",
          "primary": [
            "usedPercent": 98,
            "windowDurationMins": 10_080,
            "resetsAt": 1_785_258_164,
          ],
        ],
        "codex_bengalfox": [
          "limitId": "codex_bengalfox",
          "primary": [
            "usedPercent": 0,
            "windowDurationMins": 10_080,
            "resetsAt": 1_785_480_227,
          ],
        ],
      ],
    ]

    XCTAssertEqual(
      CodexUsageSnapshot.readResult(result),
      CodexUsageSnapshot(
        limitID: "codex",
        usedPercent: 98,
        windowDurationMinutes: 10_080,
        resetsAt: Date(timeIntervalSince1970: 1_785_258_164)
      )
    )
    XCTAssertEqual(CodexUsageSnapshot.readResult(result)?.remainingPercent, 2)
  }

  func testRateLimitResponseProjectsEveryKnownTransportWindow() throws {
    let shortReset = Date(timeIntervalSince1970: 1_800_010_000)
    let longReset = Date(timeIntervalSince1970: 1_800_600_000)
    let snapshot = try XCTUnwrap(
      CodexUsageSnapshot.readResult([
        "rateLimitsByLimitId": [
          "codex": [
            "limitId": "codex",
            "primary": [
              "usedPercent": 35,
              "windowDurationMins": 300,
              "resetsAt": shortReset.timeIntervalSince1970,
            ],
            "secondary": [
              "usedPercent": 72,
              "windowDurationMins": 10_080,
              "resetsAt": longReset.timeIntervalSince1970,
            ],
          ]
        ]
      ])
    )

    XCTAssertEqual(snapshot.windows.count, 2)
    XCTAssertEqual(snapshot.window(durationMinutes: 300)?.remainingPercent, 65)
    XCTAssertEqual(snapshot.window(durationMinutes: 10_080)?.remainingPercent, 28)
    XCTAssertEqual(snapshot.remainingPercent, 28)
    XCTAssertEqual(snapshot.resetsAt, longReset)
    XCTAssertEqual(
      snapshot.nextResetAt(after: Date(timeIntervalSince1970: 1_800_000_000)),
      shortReset
    )
  }

  func testUsageSnapshotOwnsAnArbitraryWindowArray() throws {
    let burstSlot = CodexRateLimitWindowSlot(rawValue: "burst")
    let windows = [
      CodexRateLimitWindow(
        slot: .primary,
        usedPercent: 10,
        windowDurationMinutes: 37
      ),
      CodexRateLimitWindow(
        slot: .secondary,
        usedPercent: 20,
        windowDurationMinutes: 720
      ),
      CodexRateLimitWindow(
        slot: burstSlot,
        usedPercent: 30,
        windowDurationMinutes: 2_345
      ),
    ]

    let snapshot = CodexUsageSnapshot(windows: windows)

    XCTAssertEqual(snapshot.windows, windows)
    XCTAssertEqual(
      snapshot.window(durationMinutes: 2_345)?.slot.rawValue,
      "burst"
    )
    XCTAssertEqual(snapshot.remainingPercent, 70)
  }

  func testRateLimitResponseAdaptsAdditionalWindowShapedFields() throws {
    let snapshot = try XCTUnwrap(
      CodexUsageSnapshot.readResult([
        "rateLimitsByLimitId": [
          "codex": [
            "limitId": "codex",
            "primary": [
              "usedPercent": 10,
              "windowDurationMins": 37,
            ],
            "burst": [
              "usedPercent": 30,
              "windowDurationMins": 2_345,
            ],
            "invalid": [
              "usedPercent": 99,
              "windowDurationMins": 0,
            ],
          ]
        ]
      ])
    )

    XCTAssertEqual(
      snapshot.windows.map(\.windowDurationMinutes),
      [37, 2_345]
    )
    XCTAssertEqual(snapshot.windows.last?.slot.rawValue, "burst")
  }

  func testSecondaryOnlySparseRateLimitUpdateMergesIntoPreviousWindows() throws {
    let previous = CodexUsageSnapshot(
      primaryWindow: CodexRateLimitWindow(
        slot: .primary,
        usedPercent: 20,
        windowDurationMinutes: 300,
        resetsAt: Date(timeIntervalSince1970: 1_800_010_000)
      ),
      secondaryWindow: CodexRateLimitWindow(
        slot: .secondary,
        usedPercent: 60,
        windowDurationMinutes: 10_080,
        resetsAt: Date(timeIntervalSince1970: 1_800_600_000)
      )
    )
    let update = try XCTUnwrap(
      CodexUsageSnapshot.updatedNotification([
        "rateLimits": [
          "limitId": "codex",
          "secondary": ["usedPercent": 61],
        ]
      ])
    )

    let merged = update.mergingMissingMetadata(from: previous)
    XCTAssertEqual(merged.primaryWindow, previous.primaryWindow)
    XCTAssertEqual(merged.secondaryWindow?.usedPercent, 61)
    XCTAssertEqual(
      merged.secondaryWindow?.windowDurationMinutes,
      10_080
    )
    XCTAssertEqual(
      merged.secondaryWindow?.resetsAt,
      previous.secondaryWindow?.resetsAt
    )
  }

  func testFullRateLimitReadCanRemoveTheSecondaryWindow() throws {
    let snapshot = try XCTUnwrap(
      CodexUsageSnapshot.readResult([
        "rateLimitsByLimitId": [
          "codex": [
            "limitId": "codex",
            "primary": [
              "usedPercent": 25,
              "windowDurationMins": 300,
            ],
            "secondary": NSNull(),
          ]
        ]
      ])
    )

    XCTAssertEqual(snapshot.windows.count, 1)
    XCTAssertNil(snapshot.secondaryWindow)
  }

  func testRateLimitResponseProjectsAvailableResetCountAndReturnedExpirations() throws {
    let firstExpiration = Date(timeIntervalSince1970: 1_785_480_227)
    let secondExpiration = Date(timeIntervalSince1970: 1_785_580_227)
    let result: [String: Any] = [
      "rateLimitsByLimitId": [
        "codex": [
          "limitId": "codex",
          "primary": ["usedPercent": 11],
        ]
      ],
      "rateLimitResetCredits": [
        "availableCount": 3,
        "credits": [
          [
            "status": "available",
            "expiresAt": firstExpiration.timeIntervalSince1970,
          ],
          [
            "status": "unknown",
            "expiresAt": secondExpiration.timeIntervalSince1970,
          ],
          [
            "status": "available",
            "expiresAt": NSNull(),
          ],
        ],
      ],
    ]

    let credits = try XCTUnwrap(
      CodexUsageSnapshot.readResult(result)?.rateLimitResetCredits
    )

    XCTAssertEqual(credits.availableCount, 3)
    XCTAssertEqual(
      credits.expirationDates,
      [firstExpiration, secondExpiration]
    )
  }

  func testSparseRateLimitUpdatePreservesResetCreditsFromTheLatestRead() throws {
    let expiration = Date(timeIntervalSince1970: 1_785_480_227)
    let previous = CodexUsageSnapshot(
      usedPercent: 40,
      rateLimitResetCredits: CodexRateLimitResetCredits(
        availableCount: 2,
        expirationDates: [expiration]
      )
    )
    let update = try XCTUnwrap(
      CodexUsageSnapshot.updatedNotification([
        "rateLimits": [
          "limitId": "codex",
          "primary": ["usedPercent": 41],
        ]
      ])
    )

    XCTAssertEqual(
      update.mergingMissingMetadata(from: previous).rateLimitResetCredits,
      previous.rateLimitResetCredits
    )
  }

  func testFullRateLimitReadPreservesKnownResetCreditsWhenSummaryIsMissing()
    throws
  {
    let expiration = Date(timeIntervalSince1970: 1_785_480_227)
    let previous = CodexUsageSnapshot(
      primaryWindow: CodexRateLimitWindow(
        slot: .primary,
        usedPercent: 40,
        windowDurationMinutes: 300
      ),
      secondaryWindow: CodexRateLimitWindow(
        slot: .secondary,
        usedPercent: 60,
        windowDurationMinutes: 10_080
      ),
      rateLimitResetCredits: CodexRateLimitResetCredits(
        availableCount: 1,
        expirationDates: [expiration]
      )
    )
    let read = try XCTUnwrap(
      CodexUsageSnapshot.readResult([
        "rateLimitsByLimitId": [
          "codex": [
            "limitId": "codex",
            "primary": [
              "usedPercent": 41,
              "windowDurationMins": 300,
            ],
          ]
        ]
      ])
    )

    let reconciled = read.preservingKnownResetCredits(from: previous)

    XCTAssertEqual(reconciled.windows, read.windows)
    XCTAssertEqual(
      reconciled.rateLimitResetCredits,
      previous.rateLimitResetCredits
    )
  }

  func testFullRateLimitReadUsesAnExplicitZeroResetCreditCount() throws {
    let previous = CodexUsageSnapshot(
      usedPercent: 40,
      rateLimitResetCredits: CodexRateLimitResetCredits(
        availableCount: 1,
        expirationDates: []
      )
    )
    let read = try XCTUnwrap(
      CodexUsageSnapshot.readResult([
        "rateLimitsByLimitId": [
          "codex": [
            "limitId": "codex",
            "primary": ["usedPercent": 41],
          ]
        ],
        "rateLimitResetCredits": [
          "availableCount": 0,
          "credits": [],
        ],
      ])
    )

    XCTAssertEqual(
      read.preservingKnownResetCredits(from: previous).rateLimitResetCredits,
      CodexRateLimitResetCredits(availableCount: 0, expirationDates: [])
    )
  }

  func testFullRateLimitReadDoesNotInventResetCreditsOnColdStart() throws {
    let read = try XCTUnwrap(
      CodexUsageSnapshot.readResult([
        "rateLimitsByLimitId": [
          "codex": [
            "limitId": "codex",
            "primary": ["usedPercent": 41],
          ]
        ]
      ])
    )

    XCTAssertNil(read.preservingKnownResetCredits(from: nil).rateLimitResetCredits)
  }

  func testHistoricalRateLimitResponseStillAcceptsTheMainCodexBucket() {
    let result: [String: Any] = [
      "rateLimits": [
        "limitId": "codex",
        "primary": [
          "usedPercent": 12,
        ],
      ]
    ]

    XCTAssertEqual(CodexUsageSnapshot.readResult(result)?.remainingPercent, 88)
  }

  func testModelSpecificOrMalformedRateLimitUpdatesAreIgnored() {
    XCTAssertNil(
      CodexUsageSnapshot.updatedNotification([
        "rateLimits": [
          "limitId": "codex_bengalfox",
          "primary": ["usedPercent": 5],
        ]
      ])
    )
    XCTAssertNil(
      CodexUsageSnapshot.updatedNotification([
        "rateLimits": [
          "limitId": "codex"
        ]
      ])
    )
    XCTAssertNil(
      CodexUsageSnapshot.updatedNotification([
        "rateLimits": [
          "primary": ["usedPercent": 5]
        ]
      ])
    )
  }

  func testSparseRateLimitUpdatePreservesMetadataFromTheLatestRead() {
    let previous = CodexUsageSnapshot(
      usedPercent: 97,
      windowDurationMinutes: 10_080,
      resetsAt: Date(timeIntervalSince1970: 1_785_258_164)
    )
    let update = CodexUsageSnapshot.updatedNotification([
      "rateLimits": [
        "limitId": "codex",
        "primary": ["usedPercent": 98],
      ]
    ])

    XCTAssertEqual(
      update?.mergingMissingMetadata(from: previous),
      CodexUsageSnapshot(
        usedPercent: 98,
        windowDurationMinutes: 10_080,
        resetsAt: Date(timeIntervalSince1970: 1_785_258_164)
      )
    )
  }

  func testUsagePollingPolicyBurstsForTenMinutesAtFivePercentOrLess() {
    var policy = CodexUsagePollingPolicy()
    let observedAt = Date(timeIntervalSince1970: 1_000)

    policy.observe(remainingPercent: 5, at: observedAt)

    XCTAssertEqual(policy.pollInterval(at: observedAt), 30)
    XCTAssertEqual(
      policy.pollInterval(at: observedAt.addingTimeInterval(599)),
      30
    )
    XCTAssertEqual(
      policy.pollInterval(at: observedAt.addingTimeInterval(600)),
      300
    )
  }

  func testUsagePollingPolicyDoesNotExtendBurstForAnUnchangedValue() {
    var policy = CodexUsagePollingPolicy()
    let observedAt = Date(timeIntervalSince1970: 1_000)

    policy.observe(remainingPercent: 3, at: observedAt)
    policy.observe(
      remainingPercent: 3,
      at: observedAt.addingTimeInterval(590)
    )

    XCTAssertEqual(
      policy.pollInterval(at: observedAt.addingTimeInterval(600)),
      300
    )
  }

  func testUsagePollingPolicyRearmsBurstWhenThePercentageChanges() {
    var policy = CodexUsagePollingPolicy()
    let observedAt = Date(timeIntervalSince1970: 1_000)

    policy.observe(remainingPercent: 3, at: observedAt)
    policy.observe(
      remainingPercent: 2,
      at: observedAt.addingTimeInterval(601)
    )

    XCTAssertEqual(
      policy.pollInterval(at: observedAt.addingTimeInterval(1_200)),
      30
    )
  }

  func testUsagePollingPolicyKeepsHighAndDepletedCapacityAtFiveMinutes() {
    var policy = CodexUsagePollingPolicy()
    let observedAt = Date(timeIntervalSince1970: 1_000)

    policy.observe(remainingPercent: 6, at: observedAt)
    XCTAssertEqual(policy.pollInterval(at: observedAt), 300)

    policy.observe(remainingPercent: 0, at: observedAt)
    XCTAssertEqual(policy.pollInterval(at: observedAt), 300)
  }

  func testUsagePollingPolicyAlignsPollingToClockBoundaries() {
    let observedAt = Date(timeIntervalSince1970: 1_000)
    var standardPolicy = CodexUsagePollingPolicy()
    standardPolicy.observe(remainingPercent: 6, at: observedAt)
    XCTAssertEqual(
      standardPolicy.pollDelay(at: observedAt),
      200,
      accuracy: 0.001
    )
    XCTAssertEqual(
      standardPolicy.pollDelay(
        at: Date(timeIntervalSince1970: 1_200)
      ),
      300,
      accuracy: 0.001
    )

    var burstPolicy = CodexUsagePollingPolicy()
    burstPolicy.observe(remainingPercent: 5, at: observedAt)
    XCTAssertEqual(
      burstPolicy.pollDelay(at: observedAt),
      20,
      accuracy: 0.001
    )
  }

  func testUsagePollingPolicySchedulesOneRefreshJustAfterReset() {
    let now = Date(timeIntervalSince1970: 1_000)

    XCTAssertEqual(
      CodexUsagePollingPolicy.resetRefreshDelay(
        resetsAt: now.addingTimeInterval(60),
        now: now
      ),
      61
    )
    XCTAssertNil(
      CodexUsagePollingPolicy.resetRefreshDelay(
        resetsAt: now.addingTimeInterval(-1),
        now: now
      )
    )
  }
}
