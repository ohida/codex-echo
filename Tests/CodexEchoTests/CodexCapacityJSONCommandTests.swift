import CodexAppServer
import Foundation
import MCP
import XCTest

@testable import CodexEcho

final class CodexCapacityJSONCommandTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)

  func testJSONModeNeverFallsThroughToUIWithExtraArguments() {
    XCTAssertEqual(CodexEchoLaunchMode.resolve(arguments: ["Echo", "--capacity-json"]), .capacityJSON)
    XCTAssertEqual(CodexEchoLaunchMode.resolve(arguments: ["Echo", "--capacity-json", "--refresh"]), .capacityJSONRefresh)
    XCTAssertEqual(CodexEchoLaunchMode.resolve(arguments: ["Echo", "--capacity-json", "--refresh", "extra"]), .invalidCapacityArguments)
    XCTAssertEqual(CodexEchoLaunchMode.resolve(arguments: ["Echo", "--capacity-json", "--unknown"]), .invalidCapacityArguments)
  }

  func testMissingCacheIsUnknownAndDoesNotCreateFiles() async throws {
    let directory = temporaryDirectory()
    let root = try await read(directory: directory)
    XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    XCTAssertEqual(root["windows"], .array([]))
    XCTAssertEqual(root["source"]?.objectValue?["freshness"], .string("missing"))
    XCTAssertEqual(root["credits"]?.objectValue?["balance"], .null)
    XCTAssertEqual(root["credits"]?.objectValue?["balance_status"], .string("unknown"))
    XCTAssertEqual(root["reset_credits"]?.objectValue?["available_count"], .null)
    XCTAssertEqual(root["reset_credits"]?.objectValue?["status"], .string("unknown"))
    XCTAssertNil(root["history"])
  }

  func testReadPreservesZeroAndIndependentStaleCreditsWithoutChangingCache() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("current-v1.json")
    let store = CapacityCurrentSnapshotStore(fileURL: file)
    store.enqueue(.init(
      revision: 1,
      availability: .init(state: .available, reason: nil, changedAt: now),
      lastSuccess: .init(snapshot: .init(
        windows: [.init(slot: .primary, usedPercent: 100, windowDurationMinutes: 300,
          resetsAt: now.addingTimeInterval(120))],
        rateLimitResetCredits: .init(availableCount: 0, expirationDates: []),
        credits: .init(balance: "0", hasCredits: false, unlimited: false,
          observedAt: now.addingTimeInterval(-600)), windowsObservedAt: now
      ), observedAt: now), historyRecordingEnabled: false
    ))
    store.flushSynchronously()
    let before = try Data(contentsOf: file)
    let root = try await read(directory: directory)
    XCTAssertEqual(try Data(contentsOf: file), before)
    XCTAssertEqual(root["retrieved_at"], .string("2027-01-15T08:00:00Z"))
    let source = try XCTUnwrap(root["source"]?.objectValue)
    XCTAssertEqual(source["freshness"], .string("fresh"))
    XCTAssertEqual(source["kind"], .string("codex_echo_local_cache"))
    XCTAssertEqual(source["refreshed_upstream"], .bool(false))
    XCTAssertEqual(root["windows"]?.arrayValue?.first?.objectValue?["remaining_percent"], .int(0))
    let credits = try XCTUnwrap(root["credits"]?.objectValue)
    XCTAssertEqual(credits["balance"], .string("0"))
    XCTAssertEqual(credits["balance_status"], .string("known"))
    XCTAssertEqual(credits["freshness"], .string("stale"))
    XCTAssertEqual(credits["expiration"]?.objectValue?["status"], .string("not_provided_by_source"))
    let resets = try XCTUnwrap(root["reset_credits"]?.objectValue)
    XCTAssertEqual(resets["available_count"], .int(0))
    XCTAssertEqual(resets["status"], .string("observed"))
    XCTAssertEqual(resets["freshness"], .string("unknown"))
    XCTAssertEqual(resets["observed_at"], .null)
    XCTAssertEqual(resets["expiration_dates_complete"], .bool(false))
    XCTAssertNil(root["history"])
  }

  func testUnreadableSnapshotFailsWithoutLeakingItsContentOrRepairingIt() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("current-v1.json")
    let content = Data("invalid private-looking input".utf8)
    try content.write(to: file)
    do {
      _ = try await read(directory: directory)
      XCTFail("Malformed snapshot must fail")
    } catch {
      let errorJSON = CodexCapacityJSONCommand.error(code: "snapshot_unreadable")
      let root = try JSONDecoder().decode(Value.self, from: errorJSON)
      XCTAssertEqual(root.objectValue?["error"]?.objectValue?["code"], .string("snapshot_unreadable"))
      XCTAssertFalse(String(decoding: errorJSON, as: UTF8.self).contains("private-looking"))
    }
    XCTAssertEqual(try Data(contentsOf: file), content)
  }

  private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("CapacityJSONTests-\(UUID().uuidString)")
  }

  private func read(directory: URL) async throws -> [String: Value] {
    let fixedNow = now
    let data = try await CodexCapacityJSONCommand.read(
      provider: .init(snapshotFileURL: directory.appendingPathComponent("current-v1.json"),
        historyFileURL: directory.appendingPathComponent("v1.jsonl"), now: { fixedNow }),
      now: fixedNow
    )
    XCTAssertEqual(data.last, 0x0A)
    return try XCTUnwrap(JSONDecoder().decode(Value.self, from: data).objectValue)
  }
}
