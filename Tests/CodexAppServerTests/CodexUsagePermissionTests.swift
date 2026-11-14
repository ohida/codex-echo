import Foundation
import XCTest

@testable import CodexAppServer

final class CodexUsagePermissionTests: XCTestCase {
  func testFullReadKeepsPermissionSeparateFromRoundedPercent() throws {
    for allowed in [true, false] {
      let snapshot = try XCTUnwrap(CodexUsageSnapshot.readResult(response(allowed)))
      XCTAssertEqual(snapshot.ordinaryUsageAllowed, allowed)
      XCTAssertEqual(snapshot.usedPercent, 100)
      XCTAssertEqual(snapshot.remainingPercent, 0)
    }
  }

  func testPermissionAcceptsOnlyAnAuthoritativeBoolean() throws {
    for value: Any in [NSNull(), 0, 1, "true", "false"] {
      let snapshot = try XCTUnwrap(CodexUsageSnapshot.readResult(response(value)))
      XCTAssertNil(snapshot.ordinaryUsageAllowed)
    }
    let snapshot = try XCTUnwrap(CodexUsageSnapshot.readResult(response(nil)))
    XCTAssertNil(snapshot.ordinaryUsageAllowed)
  }

  func testSparseUpdateDoesNotInheritPermissionFromAnOlderRead() throws {
    let previous = try XCTUnwrap(CodexUsageSnapshot.readResult(response(false)))
    let update = try XCTUnwrap(
      CodexUsageSnapshot.updatedNotification([
        "rateLimits": ["limitId": "codex", "primary": ["usedPercent": 100]]
      ])
    )
    let merged = update.mergingMissingMetadata(from: previous)
    XCTAssertNil(merged.ordinaryUsageAllowed)
    XCTAssertEqual(merged.windowDurationMinutes, 10_080)
    XCTAssertEqual(merged.remainingPercent, 0)
  }

  func testMissingOrNullPermissionOnAFullReadClearsEarlierPermission() throws {
    let previous = try XCTUnwrap(CodexUsageSnapshot.readResult(response(false)))
    for value: Any? in [nil, NSNull()] {
      let current = try XCTUnwrap(CodexUsageSnapshot.readResult(response(value)))
      XCTAssertNil(current.mergingMissingMetadata(from: previous).ordinaryUsageAllowed)
    }
  }

  func testResetCreditPreservationKeepsOnlyTheCurrentPermission() throws {
    let previous = CodexUsageSnapshot(
      usedPercent: 100,
      rateLimitResetCredits: .init(availableCount: 2, expirationDates: []),
      ordinaryUsageAllowed: true
    )
    let current = try XCTUnwrap(CodexUsageSnapshot.readResult(response(false)))
    let preserved = current.preservingKnownResetCredits(from: previous)
    XCTAssertEqual(preserved.ordinaryUsageAllowed, false)
    XCTAssertEqual(preserved.rateLimitResetCredits?.availableCount, 2)
  }

  private func response(_ permission: Any?) -> [String: Any] {
    var result: [String: Any] = [
      "rateLimits": [
        "limitId": "codex",
        "primary": ["usedPercent": 100, "windowDurationMins": 10_080],
      ]
    ]
    if let permission { result["ordinaryUsageAllowed"] = permission }
    return result
  }
}
