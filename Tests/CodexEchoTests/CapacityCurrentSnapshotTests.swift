import CodexAppServer
import Foundation
import XCTest

@testable import CodexEcho

final class CapacityCurrentSnapshotTests: XCTestCase {
  func testDefaultURLIsSiblingOfHistoryWithoutChangingHistoryPath() {
    let historyURL = URL(fileURLWithPath: "/tmp/example/CapacityHistory/v1.jsonl")

    XCTAssertEqual(
      CapacityCurrentSnapshotStore.defaultFileURL(
        historyFileURL: historyURL
      ),
      URL(fileURLWithPath: "/tmp/example/CapacityHistory/current-v1.json")
    )
    XCTAssertEqual(historyURL.lastPathComponent, "v1.jsonl")
  }

  func testSnapshotJSONUsesVersionedReadModelSchema() throws {
    let observedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let resetAt = observedAt.addingTimeInterval(300 * 60)
    let expiration = observedAt.addingTimeInterval(24 * 60 * 60)
    let snapshot = CapacityCurrentSnapshot(
      revision: 12,
      availability: CapacityCurrentAvailability(
        state: .available,
        reason: nil,
        changedAt: observedAt
      ),
      lastSuccess: CapacityCurrentLastSuccess(
        observedAt: observedAt,
        windows: [
          CapacityCurrentWindow(
            slot: "primary",
            windowDurationMinutes: 300,
            remainingPercent: 57,
            resetsAt: resetAt
          )
        ],
        resetCredits: CapacityCurrentResetCredits(
          availableCount: 1,
          expirationDates: [expiration]
        ),
        credits: CapacityCurrentCredits(
          credits: CodexCreditsSnapshot(
            balance: "62500.012300",
            hasCredits: true,
            unlimited: false,
            observedAt: observedAt.addingTimeInterval(-60)
          )
        )
      ),
      historyRecordingEnabled: false
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(snapshot)
    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    let lastSuccess = try XCTUnwrap(
      object["last_success"] as? [String: Any]
    )
    let windows = try XCTUnwrap(lastSuccess["windows"] as? [[String: Any]])

    XCTAssertEqual(object["schema_version"] as? Int, 1)
    XCTAssertEqual(object["revision"] as? Int, 12)
    XCTAssertEqual(object["history_recording_enabled"] as? Bool, false)
    XCTAssertNil(object["limit_id"])
    XCTAssertEqual(windows.first?["slot"] as? String, "primary")
    XCTAssertEqual(windows.first?["window_duration_minutes"] as? Int, 300)
    XCTAssertEqual(windows.first?["remaining_percent"] as? Int, 57)
    let credits = try XCTUnwrap(lastSuccess["credits"] as? [String: Any])
    XCTAssertEqual(credits["balance"] as? String, "62500.012300")
    XCTAssertEqual(credits["has_credits"] as? Bool, true)
    XCTAssertEqual(credits["unlimited"] as? Bool, false)
    XCTAssertNotNil(credits["observed_at"])
    XCTAssertNil(credits["expires_at"])
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    XCTAssertEqual(try decoder.decode(CapacityCurrentSnapshot.self, from: data), snapshot)

    var legacyLastSuccess = lastSuccess
    legacyLastSuccess.removeValue(forKey: "credits")
    var legacyObject = object
    legacyObject["last_success"] = legacyLastSuccess
    let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
    XCTAssertNil(
      try decoder.decode(CapacityCurrentSnapshot.self, from: legacyData).lastSuccess?.credits
    )
  }

  @MainActor
  func testReducerHydratesRevisionAndSerializesDelayedWritesInEventOrder()
    throws
  {
    let fileURL = temporarySnapshotURL()
    defer {
      try? FileManager.default.removeItem(
        at: fileURL.deletingLastPathComponent()
      )
    }
    let initialDate = Date(timeIntervalSince1970: 1_800_000_000)
    let firstStore = CapacityCurrentSnapshotStore(fileURL: fileURL)
    firstStore.enqueue(
      CapacityCurrentSnapshot(
        revision: 7,
        availability: CapacityCurrentAvailability(
          state: .unavailable,
          reason: "app_server_stopped",
          changedAt: initialDate
        ),
        lastSuccess: nil,
        historyRecordingEnabled: true
      )
    )
    firstStore.flushSynchronously()

    let store = CapacityCurrentSnapshotStore(
      fileURL: fileURL,
      writeDelay: { snapshot in
        snapshot.revision == 9 ? 0.1 : 0
      }
    )
    let reducer = CapacityCurrentSnapshotReducer(
      store: store,
      historyRecordingEnabled: false,
      now: initialDate
    )
    let observedAt = initialDate.addingTimeInterval(60)
    let usage = CodexUsageSnapshot(
      primaryWindow: CodexRateLimitWindow(
        slot: .primary,
        usedPercent: 43,
        windowDurationMinutes: 300,
        resetsAt: observedAt.addingTimeInterval(240 * 60)
      ),
      secondaryWindow: CodexRateLimitWindow(
        slot: .secondary,
        usedPercent: 21,
        windowDurationMinutes: 10_080,
        resetsAt: observedAt.addingTimeInterval(6 * 24 * 60 * 60)
      ),
      rateLimitResetCredits: CodexRateLimitResetCredits(
        availableCount: 1,
        expirationDates: [observedAt.addingTimeInterval(24 * 60 * 60)]
      ),
      credits: CodexCreditsSnapshot(
        balance: "62500", hasCredits: true, unlimited: false,
        observedAt: initialDate
      )
    )

    reducer.observeUsageSnapshot(usage, observedAt: observedAt)
    reducer.observeConnectionState(
      .failed(message: "offline"),
      observedAt: observedAt.addingTimeInterval(1)
    )
    store.flushSynchronously()

    let persisted = try XCTUnwrap(store.readSynchronously())
    XCTAssertEqual(persisted.revision, 10)
    XCTAssertEqual(persisted.availability.state, .unavailable)
    XCTAssertEqual(persisted.availability.reason, "app_server_failed")
    XCTAssertEqual(persisted.lastSuccess?.observedAt, observedAt)
    XCTAssertEqual(persisted.lastSuccess?.windows.map(\.slot), [
      "primary", "secondary",
    ])
    XCTAssertEqual(
      persisted.lastSuccess?.resetCredits?.availableCount,
      1
    )
    XCTAssertFalse(persisted.historyRecordingEnabled)
    XCTAssertEqual(persisted.lastSuccess?.credits?.balance, "62500")
    XCTAssertEqual(persisted.lastSuccess?.credits?.observedAt, initialDate)
  }

  @MainActor
  func testRecorderWritesCurrentSnapshotWhileHistoryRecordingIsDisabled()
    throws
  {
    let suiteName = "CapacityCurrentSnapshotTests-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(false, forKey: "recordsCapacityHistory")
    let settings = MenuBarSettings(userDefaults: defaults)
    let appServerClient = CodexAppServerClient(
      executableURL: URL(fileURLWithPath: "/usr/bin/false")
    )
    let model = CodexActivityModel(
      appServerClient: appServerClient,
      settings: settings,
      userDefaults: defaults,
      debugTaskFixtureName: "idle"
    )
    let historyURL = temporarySnapshotURL()
      .deletingLastPathComponent()
      .appendingPathComponent("v1.jsonl")
    defer {
      try? FileManager.default.removeItem(
        at: historyURL.deletingLastPathComponent()
      )
    }
    let currentStore = CapacityCurrentSnapshotStore(
      fileURL: CapacityCurrentSnapshotStore.defaultFileURL(
        historyFileURL: historyURL
      )
    )
    let observedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let recorder = CapacityHistoryRecorder(
      model: model,
      store: CapacityHistoryStore(fileURL: historyURL),
      currentSnapshotStore: currentStore,
      now: { observedAt }
    )

    appServerClient.eventHandler?(.connectionStateChanged(.running))
    appServerClient.eventHandler?(
      .usageChanged(
        CodexUsageSnapshot(
          usedPercent: 43,
          windowDurationMinutes: 300,
          resetsAt: observedAt.addingTimeInterval(240 * 60)
        )
      )
    )
    currentStore.flushSynchronously()

    let available = try XCTUnwrap(currentStore.readSynchronously())
    XCTAssertFalse(recorder.isRecordingEnabled)
    XCTAssertEqual(available.availability.state, .available)
    XCTAssertEqual(available.lastSuccess?.windows.first?.remainingPercent, 57)
    XCTAssertFalse(available.historyRecordingEnabled)
    XCTAssertFalse(FileManager.default.fileExists(atPath: historyURL.path))

    appServerClient.eventHandler?(
      .connectionStateChanged(.failed(message: "offline"))
    )
    currentStore.flushSynchronously()

    let unavailable = try XCTUnwrap(currentStore.readSynchronously())
    XCTAssertEqual(unavailable.availability.state, .unavailable)
    XCTAssertEqual(unavailable.lastSuccess, available.lastSuccess)
    XCTAssertGreaterThan(unavailable.revision, available.revision)
  }

  @MainActor
  func testCreditsOnlyUpdatePersistsWithoutRefreshingWindowHistory() async throws {
    let suiteName = "CapacityCreditsRecorderTests-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let settings = MenuBarSettings(userDefaults: defaults)
    let client = CodexAppServerClient(executableURL: URL(fileURLWithPath: "/usr/bin/false"))
    let model = CodexActivityModel(
      appServerClient: client, settings: settings, userDefaults: defaults,
      debugTaskFixtureName: "idle"
    )
    let fileURL = temporarySnapshotURL()
    defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
    let currentStore = CapacityCurrentSnapshotStore(fileURL: fileURL)
    let historyStore = CapacityHistoryStore(
      fileURL: fileURL.deletingLastPathComponent().appendingPathComponent("v1.jsonl")
    )
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let windowsAt = now.addingTimeInterval(-600)
    let recorder = CapacityHistoryRecorder(
      model: model, store: historyStore, currentSnapshotStore: currentStore, now: { now }
    )
    client.eventHandler?(.connectionStateChanged(.running))
    for (balance, creditsAt) in [("62500", windowsAt), ("62490", now)] {
      client.eventHandler?(.usageChanged(.init(
        usedPercent: 45, windowDurationMinutes: 300,
        credits: .init(balance: balance, hasCredits: true, unlimited: false,
          observedAt: creditsAt),
        windowsObservedAt: windowsAt
      )))
    }
    currentStore.flushSynchronously()
    let saved = try XCTUnwrap(currentStore.readSynchronously()?.lastSuccess)
    XCTAssertEqual(saved.observedAt, windowsAt)
    XCTAssertEqual(saved.credits?.observedAt, now)
    XCTAssertEqual(saved.credits?.balance, "62490")
    XCTAssertEqual(recorder.liveObservedAt, windowsAt)
    let history = try await historyStore.readAll()
    XCTAssertEqual(history.count, 1)
    XCTAssertEqual(history.first?.observedAt, windowsAt)
  }

  @MainActor
  func testTerminationFlushesUnavailableBeforeAnImmediateMCPRead() async throws {
    let suiteName = "CapacityTerminationTests-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(false, forKey: "recordsCapacityHistory")
    let settings = MenuBarSettings(userDefaults: defaults)
    let client = CodexAppServerClient(executableURL: URL(fileURLWithPath: "/usr/bin/false"))
    let model = CodexActivityModel(
      appServerClient: client, settings: settings, userDefaults: defaults,
      debugTaskFixtureName: "idle"
    )
    let fileURL = temporarySnapshotURL()
    defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
    let currentStore = CapacityCurrentSnapshotStore(
      fileURL: fileURL,
      writeDelay: { $0.availability.state == .available ? 0.05 : 0 }
    )
    let historyURL = fileURL.deletingLastPathComponent().appendingPathComponent("v1.jsonl")
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let recorder = CapacityHistoryRecorder(
      model: model, store: CapacityHistoryStore(fileURL: historyURL),
      currentSnapshotStore: currentStore, now: { now }
    )
    client.eventHandler?(.connectionStateChanged(.running))
    client.eventHandler?(.usageChanged(.init(
      usedPercent: 45, windowDurationMinutes: 300,
      credits: .init(balance: "62500", hasCredits: true, unlimited: false, observedAt: now)
    )))
    recorder.prepareForTermination()
    // A queued event delivered after termination must not make the file available again.
    client.eventHandler?(.usageChanged(.init(usedPercent: 44)))
    let saved = try XCTUnwrap(currentStore.readSynchronously())
    XCTAssertEqual(saved.availability.state, .unavailable)
    XCTAssertEqual(saved.availability.reason, "app_server_stopped")
    XCTAssertEqual(saved.lastSuccess?.windows.first?.remainingPercent, 55)
    let response = try await CodexCapacityMCPFileDataProvider(
      snapshotFileURL: fileURL, historyFileURL: historyURL, now: { now }
    ).getCodexCapacity()
    let root = try XCTUnwrap(response.structuredContent.objectValue)
    XCTAssertEqual(root["source"]?.objectValue?["freshness"]?.stringValue, "stale")
    XCTAssertEqual(root["credits"]?.objectValue?["freshness"]?.stringValue, "stale")
  }

  private func temporarySnapshotURL() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "CapacityCurrentSnapshotTests-\(UUID().uuidString)",
        isDirectory: true
      )
      .appendingPathComponent("current-v1.json")
  }
}
