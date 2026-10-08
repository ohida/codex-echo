import Foundation
import MCP
import XCTest

@testable import CodexAppServer
@testable import CodexEcho

final class CodexResetObservationTests: XCTestCase {
  private let receivedAt = Date(timeIntervalSince1970: 1_800_000_000)

  func testExplicitResponseRecordsReceiptTimeIncludingZero() async throws {
    for count in [0, 2] {
      let usage = try parse(count: count)
      XCTAssertEqual(usage.rateLimitResetCredits?.observedAt, receivedAt)
      let resets = try await output(usage, at: receivedAt)
      XCTAssertEqual(resets["available_count"], .int(count))
      XCTAssertEqual(resets["freshness"], .string("fresh"))
      XCTAssertEqual(resets["observed_at"], .string("2027-01-15T08:00:00Z"))
      XCTAssertEqual(resets["observation_source"], .string("app_server_response_received"))
      XCTAssertEqual(resets["upstream_observed_at"], .null)
    }
  }

  func testSparseAndMissingUpdatesDoNotRefreshOldResetSummary() async throws {
    let old = try parse(count: 2)
    let later = receivedAt.addingTimeInterval(600)
    let sparse = try XCTUnwrap(CodexUsageSnapshot.updatedNotification([
      "rateLimits": ["limitId": "codex", "primary": ["usedPercent": 20]]
    ], observedAt: later)).mergingMissingMetadata(from: old)
    let missing = try XCTUnwrap(CodexUsageSnapshot.readResult([
      "rateLimits": ["limitId": "codex", "primary": ["usedPercent": 20]]
    ], observedAt: later)).preservingKnownResetCredits(from: old)
    for usage in [sparse, missing] {
      XCTAssertEqual(usage.rateLimitResetCredits?.observedAt, receivedAt)
      let resets = try await output(usage, at: later)
      XCTAssertEqual(resets["freshness"], .string("stale"))
      XCTAssertEqual(resets["observed_at"], .string("2027-01-15T08:00:00Z"))
      XCTAssertEqual(resets["age_seconds"]?.intValue, 600)
    }
  }

  func testNoReceiptEvidenceStaysUnknownAndFutureReceiptIsNotFresh() async throws {
    let manual = CodexUsageSnapshot(
      usedPercent: 20,
      rateLimitResetCredits: .init(availableCount: 2, expirationDates: [receivedAt])
    )
    let unknown = try await output(manual, at: receivedAt)
    XCTAssertEqual(unknown["freshness"], .string("unknown"))
    XCTAssertEqual(unknown["observed_at"], .null)
    XCTAssertEqual(unknown["expiration_dates"]?.arrayValue?.count, 1)
    let future = try await output(parse(count: 2), at: receivedAt.addingTimeInterval(-1))
    XCTAssertEqual(future["freshness"], .string("stale"))
  }

  private func parse(count: Int) throws -> CodexUsageSnapshot {
    try XCTUnwrap(CodexUsageSnapshot.readResult([
      "rateLimits": ["limitId": "codex", "primary": ["usedPercent": 20]],
      "rateLimitResetCredits": ["availableCount": count, "credits": [
        ["expiresAt": receivedAt.addingTimeInterval(86400).timeIntervalSince1970]
      ]],
    ], observedAt: receivedAt))
  }

  private func output(_ usage: CodexUsageSnapshot, at now: Date) async throws -> [String: Value] {
    let data = try await CodexCapacityJSONCommand.readLive(usage: usage, now: now)
    let root = try JSONDecoder().decode(Value.self, from: data)
    return try XCTUnwrap(root.objectValue?["reset_credits"]?.objectValue)
  }
}
