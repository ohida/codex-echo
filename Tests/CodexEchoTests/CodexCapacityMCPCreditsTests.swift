import CodexAppServer
import Foundation
import MCP
import XCTest

@testable import CodexEcho

final class CodexCapacityMCPCreditsTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)

  func testMCPReturnsExactBalanceAndIndependentCreditFreshness() async throws {
    let creditsAt = now.addingTimeInterval(-600)
    let root = try await response(
      credits: .init(balance: "62500.012300", hasCredits: true, unlimited: false,
        observedAt: creditsAt)
    )
    XCTAssertEqual(root["source"]?.objectValue?["freshness"], .string("fresh"))
    let credits = try XCTUnwrap(root["credits"]?.objectValue)
    XCTAssertEqual(credits["balance"], .string("62500.012300"))
    XCTAssertEqual(credits["has_credits"], .bool(true))
    XCTAssertEqual(credits["unlimited"], .bool(false))
    XCTAssertEqual(credits["freshness"], .string("stale"))
    XCTAssertEqual(credits["age_seconds"], .double(600))
    XCTAssertEqual(credits["observed_at"], .string("2027-01-15T07:50:00Z"))
    XCTAssertEqual(root["reset_credits"]?.objectValue?["available_count"], .int(2))
    try assertCreditsMatchPublishedSchema(credits)
  }

  func testCreditsCanBeFreshWhileWindowsAreStale() async throws {
    let root = try await response(
      credits: .init(balance: "62490", hasCredits: true, unlimited: false, observedAt: now),
      windowsObservedAt: now.addingTimeInterval(-600)
    )
    XCTAssertEqual(root["source"]?.objectValue?["freshness"], .string("stale"))
    XCTAssertEqual(root["credits"]?.objectValue?["freshness"], .string("fresh"))
  }

  func testBoundaryFutureAndDisconnectedCreditsAreNotFalselyFresh() async throws {
    for (age, availability, expected) in [
      (360.0, CapacityCurrentAvailabilityState.available, "fresh"),
      (361.0, .available, "stale"),
      (-1.0, .available, "stale"),
      (0.0, .unavailable, "stale"),
    ] {
      let root = try await response(
        credits: .init(balance: "62500", hasCredits: true, unlimited: false,
          observedAt: now.addingTimeInterval(-age)),
        availability: availability
      )
      XCTAssertEqual(root["credits"]?.objectValue?["freshness"], .string(expected))
    }
  }

  func testMCPDistinguishesMissingUnknownZeroAndUnlimitedCredits() async throws {
    let missing = try await response(credits: nil)
    XCTAssertNil(missing["credits"])
    for (balance, hasCredits, unlimited) in [
      (nil, true, true), (nil, false, false), ("0", false, false),
    ] as [(String?, Bool, Bool)] {
      let root = try await response(
        credits: .init(balance: balance, hasCredits: hasCredits, unlimited: unlimited,
          observedAt: now)
      )
      let credits = try XCTUnwrap(root["credits"]?.objectValue)
      XCTAssertEqual(credits["balance"], balance.map(Value.string) ?? .null)
      XCTAssertEqual(credits["has_credits"], .bool(hasCredits))
      XCTAssertEqual(credits["unlimited"], .bool(unlimited))
      try assertCreditsMatchPublishedSchema(credits)
    }
  }

  func testCreditsOnlyObservationDoesNotClaimCapacityIsFresh() async throws {
    let root = try await response(
      credits: .init(balance: nil, hasCredits: true, unlimited: true, observedAt: now),
      windows: []
    )
    let source = try XCTUnwrap(root["source"]?.objectValue)
    XCTAssertEqual(source["freshness"], .string("missing"))
    XCTAssertNil(source["current_observed_at"])
    XCTAssertNil(source["age_seconds"])
    XCTAssertEqual(root["windows"], .array([]))
    XCTAssertEqual(root["credits"]?.objectValue?["freshness"], .string("fresh"))
  }

  private func response(
    credits: CodexCreditsSnapshot?,
    windowsObservedAt: Date? = nil,
    availability: CapacityCurrentAvailabilityState = .available,
    windows: [CodexRateLimitWindow]? = nil
  ) async throws -> [String: Value] {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("MCPCreditsTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = CapacityCurrentSnapshotStore(fileURL: directory.appendingPathComponent("current-v1.json"))
    store.enqueue(.init(
      revision: 1,
      availability: .init(state: availability, reason: nil, changedAt: now),
      lastSuccess: .init(snapshot: .init(
        windows: windows ?? [.init(slot: .primary, usedPercent: 45, windowDurationMinutes: 300)],
        rateLimitResetCredits: .init(availableCount: 2, expirationDates: []),
        credits: credits, windowsObservedAt: windowsObservedAt
      ), observedAt: now),
      historyRecordingEnabled: false
    ))
    store.flushSynchronously()
    let fixedNow = now
    let response = try await CodexCapacityMCPFileDataProvider(
      snapshotFileURL: store.fileURL,
      historyFileURL: directory.appendingPathComponent("v1.jsonl"),
      now: { fixedNow }
    ).getCodexCapacity()
    return try XCTUnwrap(response.structuredContent.objectValue)
  }

  private func assertCreditsMatchPublishedSchema(_ credits: [String: Value]) throws {
    let tool = try XCTUnwrap(CodexCapacityMCPServer.tools.first)
    let schema = try XCTUnwrap(tool.outputSchema?.objectValue?["oneOf"]?.arrayValue?.first?
      .objectValue?["properties"]?.objectValue?["credits"]?.objectValue)
    let properties = try XCTUnwrap(schema["properties"]?.objectValue)
    let required = try XCTUnwrap(schema["required"]?.arrayValue?.compactMap(\.stringValue))
    XCTAssertEqual(Set(credits.keys), Set(properties.keys))
    XCTAssertEqual(Set(required), Set(properties.keys))
    XCTAssertEqual(schema["additionalProperties"], .bool(false))
    XCTAssertEqual(properties["balance"]?.objectValue?["type"], .array([.string("string"), .string("null")]))
    XCTAssertNil(properties["expires_at"])
  }
}
