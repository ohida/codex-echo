import Foundation
import XCTest

@testable import CodexAppServer

final class CodexCreditsSnapshotTests: XCTestCase {
  private let observedAt = Date(timeIntervalSince1970: 1_800_000_000)

  func testReadProjectsExactPurchasedBalanceSeparatelyFromResetCredits() throws {
    let snapshot = try read(credits: [
      "balance": "62500.012300", "hasCredits": true, "unlimited": false,
    ])
    XCTAssertEqual(snapshot.credits?.balance, "62500.012300")
    XCTAssertEqual(snapshot.credits?.hasCredits, true)
    XCTAssertEqual(snapshot.credits?.unlimited, false)
    XCTAssertEqual(snapshot.credits?.observedAt, observedAt)
    XCTAssertEqual(snapshot.windowsObservedAt, observedAt)
    XCTAssertEqual(snapshot.rateLimitResetCredits?.availableCount, 2)
  }

  func testLegacyBucketAlsoProjectsPurchasedCredits() throws {
    let snapshot = try XCTUnwrap(CodexUsageSnapshot.readResult([
      "rateLimits": [
        "primary": ["usedPercent": 45],
        "credits": ["balance": "62500", "hasCredits": true, "unlimited": false],
      ]
    ], observedAt: observedAt))
    XCTAssertEqual(snapshot.credits?.balance, "62500")
  }

  func testUnknownBalanceIsNotZeroAndUnlimitedDoesNotInventBalance() throws {
    for balance in [nil, NSNull()] as [Any?] {
      var credits: [String: Any] = ["hasCredits": true, "unlimited": true]
      credits["balance"] = balance
      let snapshot = try read(credits: credits)
      XCTAssertNil(snapshot.credits?.balance)
      XCTAssertEqual(snapshot.credits?.unlimited, true)
    }
    let zero = try read(credits: [
      "balance": "0", "hasCredits": false, "unlimited": false,
    ])
    XCTAssertEqual(zero.credits?.balance, "0")
    XCTAssertEqual(zero.credits?.hasCredits, false)
  }

  func testMissingNullOrMalformedCreditsDoNotInventValues() throws {
    let invalid: [Any?] = [
      nil, NSNull(),
      ["hasCredits": true],
      ["hasCredits": 1, "unlimited": false],
      ["hasCredits": true, "unlimited": "false"],
      ["hasCredits": true, "unlimited": false, "balance": 62500],
    ]
    for credits in invalid {
      XCTAssertNil(try read(credits: credits).credits)
    }
  }

  func testSparseWindowUpdatePreservesCreditObservationTime() throws {
    let previous = try read(credits: [
      "balance": "62500", "hasCredits": true, "unlimited": false,
    ])
    let later = observedAt.addingTimeInterval(600)
    let update = try XCTUnwrap(CodexUsageSnapshot.updatedNotification([
      "rateLimits": ["limitId": "codex", "primary": ["usedPercent": 46]]
    ], observedAt: later))
    let merged = update.mergingMissingMetadata(from: previous)
    XCTAssertEqual(merged.credits, previous.credits)
    XCTAssertEqual(merged.windowsObservedAt, later)
  }

  func testCreditsOnlyUpdateDoesNotRefreshPreviousWindows() throws {
    let previous = try read(credits: [
      "balance": "62500", "hasCredits": true, "unlimited": false,
    ])
    let later = observedAt.addingTimeInterval(600)
    let update = try XCTUnwrap(CodexUsageSnapshot.updatedNotification([
      "rateLimits": [
        "limitId": "codex",
        "credits": ["balance": "62490", "hasCredits": true, "unlimited": false],
      ]
    ], observedAt: later))
    let merged = update.mergingMissingMetadata(from: previous)
    XCTAssertEqual(merged.windows, previous.windows)
    XCTAssertEqual(merged.windowsObservedAt, observedAt)
    XCTAssertEqual(merged.credits?.observedAt, later)
    XCTAssertEqual(merged.credits?.balance, "62490")
  }

  func testExplicitNullClearsCreditsButFullReadNeverCarriesMissingCreditsForward() throws {
    let previous = try read(credits: [
      "balance": "62500", "hasCredits": true, "unlimited": false,
    ])
    let update = try XCTUnwrap(CodexUsageSnapshot.updatedNotification([
      "rateLimits": ["limitId": "codex", "credits": NSNull()]
    ], observedAt: observedAt.addingTimeInterval(1)))
    XCTAssertNil(update.mergingMissingMetadata(from: previous).credits)
    XCTAssertEqual(update.mergingMissingMetadata(from: previous).windows, previous.windows)
    let fullRead = try read(credits: nil)
    XCTAssertNil(fullRead.preservingKnownResetCredits(from: previous).credits)
  }

  func testCreditsOnlyFullReadDoesNotRequireCapacityWindows() throws {
    let snapshot = try XCTUnwrap(CodexUsageSnapshot.readResult([
      "rateLimitsByLimitId": [
        "codex": [
          "limitId": "codex", "primary": NSNull(), "secondary": NSNull(),
          "credits": ["hasCredits": true, "unlimited": true],
        ]
      ]
    ], observedAt: observedAt))
    XCTAssertTrue(snapshot.windows.isEmpty)
    XCTAssertNil(snapshot.remainingPercent)
    XCTAssertEqual(snapshot.credits?.unlimited, true)
  }

  private func read(credits: Any?) throws -> CodexUsageSnapshot {
    var bucket: [String: Any] = [
      "limitId": "codex", "primary": ["usedPercent": 45, "windowDurationMins": 300],
    ]
    bucket["credits"] = credits
    return try XCTUnwrap(CodexUsageSnapshot.readResult([
      "rateLimitsByLimitId": ["codex": bucket],
      "rateLimitResetCredits": ["availableCount": 2, "credits": []],
    ], observedAt: observedAt))
  }
}
