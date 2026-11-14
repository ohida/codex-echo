import Foundation
import MCP
import XCTest

@testable import CodexAppServer
@testable import CodexEcho

final class CodexCapacityMCPResetCreditsTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)

  func testResetFreshnessIsIndependentOfWindowsAndPurchasedCredits() async throws {
    for (resetAge, windowAge, expectedReset, expectedWindow) in [
      (600.0, 0.0, "stale", "fresh"),
      (0.0, 600.0, "fresh", "stale"),
    ] {
      let root = try await response(
        resets: .init(availableCount: 2, expirationDates: [],
          observedAt: now.addingTimeInterval(-resetAge)),
        windowsObservedAt: now.addingTimeInterval(-windowAge)
      )
      XCTAssertEqual(root["source"]?.objectValue?["freshness"], .string(expectedWindow))
      XCTAssertEqual(root["credits"]?.objectValue?["freshness"], .string("fresh"))
      let resets = try XCTUnwrap(root["reset_credits"]?.objectValue)
      XCTAssertEqual(resets["freshness"], .string(expectedReset))
      XCTAssertEqual(resets["age_seconds"], .double(resetAge))
      XCTAssertEqual(resets["observed_at"], dateValue(now.addingTimeInterval(-resetAge)))
      try assertResetsMatchPublishedSchema(resets)
    }
    let withoutWindows = try await response(
      resets: .init(availableCount: 1, expirationDates: [], observedAt: now),
      windows: []
    )
    XCTAssertEqual(withoutWindows["source"]?.objectValue?["freshness"], .string("missing"))
    XCTAssertEqual(withoutWindows["reset_credits"]?.objectValue?["freshness"], .string("fresh"))
  }

  func testBoundaryFutureAndUnavailableResetObservationsAreNotFalselyFresh() async throws {
    for (age, availability, expected) in [
      (360.0, CapacityCurrentAvailabilityState.available, "fresh"),
      (361.0, .available, "stale"),
      (-1.0, .available, "stale"),
      (0.0, .unavailable, "stale"),
    ] {
      let root = try await response(
        resets: .init(availableCount: 1, expirationDates: [],
          observedAt: now.addingTimeInterval(-age)),
        availability: availability
      )
      let resets = try XCTUnwrap(root["reset_credits"]?.objectValue)
      XCTAssertEqual(resets["freshness"], .string(expected))
      XCTAssertEqual(resets["age_seconds"], .double(max(age, 0)))
    }
  }

  func testMissingSummaryObservedZeroAndUnknownReceiptRemainDistinct() async throws {
    let missing = try await response(resets: nil)
    XCTAssertNil(missing["reset_credits"])
    let zero = try await response(
      resets: .init(availableCount: 0, expirationDates: [], observedAt: now)
    )
    XCTAssertEqual(zero["reset_credits"]?.objectValue?["available_count"], .int(0))
    XCTAssertEqual(zero["reset_credits"]?.objectValue?["freshness"], .string("fresh"))
    for count in [0, 2] {
      let expiration = now.addingTimeInterval(86_400)
      let root = try await response(
        resets: .init(availableCount: count, expirationDates: [expiration])
      )
      let resets = try XCTUnwrap(root["reset_credits"]?.objectValue)
      XCTAssertEqual(resets["available_count"], .int(count))
      XCTAssertEqual(resets["expiration_dates"], .array(count == 0 ? [] : [dateValue(expiration)]))
      XCTAssertEqual(resets["observed_at"], .null)
      XCTAssertEqual(resets["age_seconds"], .null)
      XCTAssertEqual(resets["freshness"], .string("unknown"))
      try assertResetsMatchPublishedSchema(resets)
    }
  }

  @MainActor
  func testPartialMissingAndNullUpdatesPreserveReceiptThroughDiskAndMCP() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = CapacityCurrentSnapshotStore(fileURL: directory.appendingPathComponent("current-v1.json"))
    let reducer = CapacityCurrentSnapshotReducer(store: store, historyRecordingEnabled: false, now: now)
    let resetsAt = now.addingTimeInterval(-600)
    let expiration = now.addingTimeInterval(86_400)
    let initial = try read(summary: [
      "availableCount": 2, "credits": [["expiresAt": expiration.timeIntervalSince1970]],
    ], observedAt: resetsAt)
    reducer.observeUsageSnapshot(initial, observedAt: resetsAt)
    let partial = try XCTUnwrap(CodexUsageSnapshot.updatedNotification([
      "rateLimits": ["limitId": "codex", "primary": ["usedPercent": 46]],
    ], observedAt: now)).mergingMissingMetadata(from: initial)
    var previous = partial
    for usage in [partial, try read(summary: nil, observedAt: now),
      try read(summary: NSNull(), observedAt: now)] {
      let reconciled = usage.preservingKnownResetCredits(from: previous)
      reducer.observeUsageSnapshot(reconciled, observedAt: now)
      reducer.flushSynchronously()
      let restored = CapacityCurrentSnapshotReducer(
        store: store, historyRecordingEnabled: false, now: now
      ).snapshot
      XCTAssertEqual(restored.lastSuccess?.observedAt, now)
      XCTAssertEqual(restored.lastSuccess?.resetCredits?.observedAt, resetsAt)
      XCTAssertEqual(restored.lastSuccess?.resetCredits?.expirationDates, [expiration])
      let root = try await provider(store: store).getCodexCapacity(includeHistory: false)
        .structuredContent.objectValue
      XCTAssertEqual(root?["source"]?.objectValue?["freshness"], .string("fresh"))
      XCTAssertEqual(root?["reset_credits"]?.objectValue?["available_count"], .int(2))
      XCTAssertEqual(root?["reset_credits"]?.objectValue?["observed_at"], dateValue(resetsAt))
      XCTAssertEqual(root?["reset_credits"]?.objectValue?["freshness"], .string("stale"))
      previous = reconciled
    }

    let zero = try read(summary: ["availableCount": 0, "credits": []], observedAt: now)
      .preservingKnownResetCredits(from: previous)
    reducer.observeUsageSnapshot(zero, observedAt: now)
    reducer.flushSynchronously()
    let root = try await provider(store: store).getCodexCapacity(includeHistory: false)
      .structuredContent.objectValue
    XCTAssertEqual(root?["reset_credits"]?.objectValue?["available_count"], .int(0))
    XCTAssertEqual(root?["reset_credits"]?.objectValue?["expiration_dates"], .array([]))
    XCTAssertEqual(root?["reset_credits"]?.objectValue?["observed_at"], dateValue(now))
    XCTAssertEqual(root?["reset_credits"]?.objectValue?["freshness"], .string("fresh"))
  }

  private func read(summary: Any?, observedAt: Date) throws -> CodexUsageSnapshot {
    var result: [String: Any] = [
      "rateLimits": ["limitId": "codex", "primary": [
        "usedPercent": 45, "windowDurationMins": 300,
      ]],
    ]
    result["rateLimitResetCredits"] = summary
    return try XCTUnwrap(CodexUsageSnapshot.readResult(result, observedAt: observedAt))
  }

  private func response(
    resets: CodexRateLimitResetCredits?,
    windowsObservedAt: Date? = nil,
    availability: CapacityCurrentAvailabilityState = .available,
    windows: [CodexRateLimitWindow]? = nil
  ) async throws -> [String: Value] {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = CapacityCurrentSnapshotStore(fileURL: directory.appendingPathComponent("current-v1.json"))
    store.enqueue(.init(
      revision: 1,
      availability: .init(state: availability, reason: nil, changedAt: now),
      lastSuccess: .init(snapshot: .init(
        windows: windows ?? [.init(slot: .primary, usedPercent: 45, windowDurationMinutes: 300)],
        rateLimitResetCredits: resets,
        credits: .init(balance: "0", hasCredits: false, unlimited: false, observedAt: now),
        windowsObservedAt: windowsObservedAt
      ), observedAt: now), historyRecordingEnabled: false
    ))
    store.flushSynchronously()
    let response = try await provider(store: store).getCodexCapacity(includeHistory: false)
    return try XCTUnwrap(response.structuredContent.objectValue)
  }

  private func provider(store: CapacityCurrentSnapshotStore) -> CodexCapacityMCPFileDataProvider {
    let fixedNow = now
    return .init(snapshotFileURL: store.fileURL, now: { fixedNow })
  }

  private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("MCPResetTests-\(UUID().uuidString)")
  }

  private func dateValue(_ date: Date) -> Value {
    .string(ISO8601DateFormatter().string(from: date))
  }

  private func assertResetsMatchPublishedSchema(_ resets: [String: Value]) throws {
    let tool = try XCTUnwrap(CodexCapacityMCPServer.tools.first)
    let schema = try XCTUnwrap(tool.outputSchema?.objectValue?["oneOf"]?.arrayValue?.first?
      .objectValue?["properties"]?.objectValue?["reset_credits"]?.objectValue)
    let properties = try XCTUnwrap(schema["properties"]?.objectValue)
    let required = try XCTUnwrap(schema["required"]?.arrayValue?.compactMap(\.stringValue))
    XCTAssertEqual(Set(resets.keys), Set(properties.keys))
    XCTAssertEqual(Set(required), Set(properties.keys))
    XCTAssertEqual(schema["additionalProperties"], .bool(false))
    XCTAssertEqual(properties["observed_at"]?.objectValue?["type"],
      .array([.string("string"), .string("null")]))
    XCTAssertEqual(properties["age_seconds"]?.objectValue?["type"],
      .array([.string("number"), .string("null")]))
    XCTAssertEqual(properties["freshness"]?.objectValue?["enum"],
      .array([.string("fresh"), .string("stale"), .string("unknown")]))
  }
}
