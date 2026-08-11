import Foundation
import XCTest

@testable import CodexEcho

private extension CapacityHistoryLimit {
  static let shortWindow = Self(windowDurationMinutes: 5 * 60)
  static let weeklyWindow = Self(windowDurationMinutes: 7 * 24 * 60)
}

final class CapacityHistoryStoreTests: XCTestCase {
  func testRoundTripsJSONLAndExportsChronologicalTwoColumnCSV() async throws {
    let fileURL = temporaryHistoryURL()
    defer { removeTemporaryHistory(at: fileURL) }
    let store = CapacityHistoryStore(fileURL: fileURL)
    let sessionID = UUID()
    let later = observation(
      at: 1_800_000_300,
      remainingPercent: 47,
      sessionID: sessionID
    )
    let earlier = observation(
      at: 1_800_000_000,
      remainingPercent: 52,
      sessionID: sessionID
    )

    try await store.append(later)
    try await store.append(earlier)

    let restored = try await store.readAll()
    XCTAssertEqual(restored, [earlier, later])
    let csv = try await store.csv()
    XCTAssertTrue(csv.hasPrefix("observedAt,remainingPercent\n"))
    XCTAssertLessThan(
      try XCTUnwrap(csv.range(of: ",52")).lowerBound,
      try XCTUnwrap(csv.range(of: ",47")).lowerBound
    )
    XCTAssertFalse(csv.contains(sessionID.uuidString))
    XCTAssertTrue(
      csv.split(separator: "\n").allSatisfy {
        $0.split(separator: ",").count == 2
      }
    )
  }

  func testMigratesLegacyRowsWithoutWindowDurationToWeeklyLimit() async throws {
    struct LegacyObservation: Encodable {
      let observedAt: Date
      let remainingPercent: Int
      let sessionID: UUID
    }

    let fileURL = temporaryHistoryURL()
    defer { removeTemporaryHistory(at: fileURL) }
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let observedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let sessionID = UUID()
    let legacy = LegacyObservation(
      observedAt: observedAt,
      remainingPercent: 52,
      sessionID: sessionID
    )
    var data = try encodedData(for: legacy)
    data.append(0x0A)
    try data.write(to: fileURL)

    let restored = try await CapacityHistoryStore(fileURL: fileURL).readAll()

    XCTAssertEqual(
      restored,
      [
        CapacityObservation(
          observedAt: observedAt,
          remainingPercent: 52,
          sessionID: sessionID,
          windowDurationMinutes: 7 * 24 * 60
        )
      ]
    )
  }

  func testSelectedLimitCSVKeepsTwoColumnsWithoutMixingWindows() async throws {
    let fileURL = temporaryHistoryURL()
    defer { removeTemporaryHistory(at: fileURL) }
    let store = CapacityHistoryStore(fileURL: fileURL)
    let sessionID = UUID()
    try await store.append(
      observation(
        at: 1_800_000_000,
        remainingPercent: 80,
        sessionID: sessionID,
        windowDurationMinutes: 300
      )
    )
    try await store.append(
      observation(
        at: 1_800_000_001,
        remainingPercent: 40,
        sessionID: sessionID,
        windowDurationMinutes: 10_080
      )
    )
    try await store.append(
      observation(
        at: 1_800_000_002,
        remainingPercent: 35,
        sessionID: sessionID
      )
    )

    let fiveHourCSV = try await store.csv(for: .shortWindow)
    XCTAssertTrue(fiveHourCSV.contains(",80"))
    XCTAssertFalse(fiveHourCSV.contains(",40"))
    XCTAssertFalse(fiveHourCSV.contains(",35"))

    let weeklyCSV = try await store.csv(for: .weeklyWindow)
    XCTAssertFalse(weeklyCSV.contains(",80"))
    XCTAssertTrue(weeklyCSV.contains(",40"))
    XCTAssertTrue(weeklyCSV.contains(",35"))
    XCTAssertTrue(
      weeklyCSV.split(separator: "\n").allSatisfy {
        $0.split(separator: ",").count == 2
      }
    )
  }

  func testIgnoresOnlyAnIncompleteTrailingJSONLine() async throws {
    let fileURL = temporaryHistoryURL()
    defer { removeTemporaryHistory(at: fileURL) }
    let store = CapacityHistoryStore(fileURL: fileURL)
    let stored = observation(
      at: 1_800_000_000,
      remainingPercent: 52
    )
    try await store.append(stored)
    let handle = try FileHandle(forWritingTo: fileURL)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(#"{"observedAt":"#.utf8))
    try handle.close()

    let restored = try await store.readAll()
    XCTAssertEqual(restored, [stored])
  }

  func testRepairsAnIncompleteTailBeforeTheNextAppend() async throws {
    let fileURL = temporaryHistoryURL()
    defer { removeTemporaryHistory(at: fileURL) }
    let store = CapacityHistoryStore(fileURL: fileURL)
    let sessionID = UUID()
    let first = observation(
      at: 1_800_000_000,
      remainingPercent: 52,
      sessionID: sessionID
    )
    let second = observation(
      at: 1_800_000_300,
      remainingPercent: 47,
      sessionID: sessionID
    )
    try await store.append(first)
    let handle = try FileHandle(forWritingTo: fileURL)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(#"{"observedAt":"#.utf8))
    try handle.close()

    try await store.append(second)

    let restored = try await store.readAll()
    XCTAssertEqual(restored, [first, second])
  }

  func testPreservesAValidUnterminatedTailBeforeTheNextAppend() async throws {
    let fileURL = temporaryHistoryURL()
    defer { removeTemporaryHistory(at: fileURL) }
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let store = CapacityHistoryStore(fileURL: fileURL)
    let sessionID = UUID()
    let first = observation(
      at: 1_800_000_000,
      remainingPercent: 52,
      sessionID: sessionID
    )
    let second = observation(
      at: 1_800_000_300,
      remainingPercent: 47,
      sessionID: sessionID
    )
    try encodedData(for: first).write(to: fileURL)

    try await store.append(second)

    let restored = try await store.readAll()
    XCTAssertEqual(restored, [first, second])
  }

  func testReportsTheFirstCompleteMalformedLine() async throws {
    let fileURL = temporaryHistoryURL()
    defer { removeTemporaryHistory(at: fileURL) }
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data("{}\n".utf8).write(to: fileURL)

    do {
      _ = try await CapacityHistoryStore(fileURL: fileURL).readAll()
      XCTFail("Expected malformed complete JSONL row to fail")
    } catch {
      XCTAssertEqual(error as? CapacityHistoryStoreError, .malformedLine(1))
    }
  }

  func testSerializesConcurrentAppendsBeforeClear() async throws {
    let fileURL = temporaryHistoryURL()
    defer { removeTemporaryHistory(at: fileURL) }
    let store = CapacityHistoryStore(fileURL: fileURL)
    let sessionID = UUID()
    let observations = (0..<32).map { offset in
      observation(
        at: 1_800_000_000 + TimeInterval(offset),
        remainingPercent: 100 - offset,
        sessionID: sessionID
      )
    }

    try await withThrowingTaskGroup(of: Void.self) { group in
      for observation in observations {
        group.addTask {
          try await store.append(observation)
        }
      }
      try await group.waitForAll()
    }

    let restored = try await store.readAll()
    XCTAssertEqual(restored.count, 32)
    XCTAssertEqual(restored.map(\.remainingPercent), Array((69...100).reversed()))

    try await store.clear()
    let afterClear = try await store.readAll()
    XCTAssertTrue(afterClear.isEmpty)
  }

  private func observation(
    at timestamp: TimeInterval,
    remainingPercent: Int,
    sessionID: UUID = UUID(),
    windowDurationMinutes: Int = 7 * 24 * 60
  ) -> CapacityObservation {
    CapacityObservation(
      observedAt: Date(timeIntervalSince1970: timestamp),
      remainingPercent: remainingPercent,
      sessionID: sessionID,
      windowDurationMinutes: windowDurationMinutes
    )
  }

  private func encodedData<Value: Encodable>(for value: Value) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(value)
  }

  private func temporaryHistoryURL() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "CapacityHistoryStoreTests-\(UUID().uuidString)",
        isDirectory: true
      )
      .appendingPathComponent("v1.jsonl")
  }

  private func removeTemporaryHistory(at fileURL: URL) {
    try? FileManager.default.removeItem(
      at: fileURL.deletingLastPathComponent()
    )
  }
}
