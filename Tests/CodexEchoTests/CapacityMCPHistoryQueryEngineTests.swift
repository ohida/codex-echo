import CryptoKit
import Foundation
import XCTest

@testable import CodexEcho

final class CapacityMCPHistoryQueryEngineTests: XCTestCase {
  func testResetScheduleChangeCountsAdjacentIncreaseAndDecreaseWithoutGap()
    throws
  {
    let fixture = try Fixture()
    let now = Date(timeIntervalSince1970: 2_000_000)
    let session = UUID()
    let firstReset = now.addingTimeInterval(2_000)
    let changedReset = firstReset.addingTimeInterval(60)
    try fixture.write([
      observation(now.addingTimeInterval(-600), 57, session, firstReset),
      observation(now.addingTimeInterval(-300), 100, session, changedReset),
      observation(now, 98, session, changedReset),
    ])

    let result = try fixture.engine.query(
      .init(range: .twentyFourHours),
      now: now
    )
    let summary = try XCTUnwrap(result.windows.first?.summary)
    XCTAssertEqual(summary.observedIncreasePoints, 43)
    XCTAssertEqual(summary.observedDecreasePoints, 2)
    XCTAssertEqual(summary.gapCount, 0)
    XCTAssertEqual(summary.resetScheduleChangeCount, 1)
    XCTAssertEqual(summary.observedSeconds, 600)
    XCTAssertTrue(result.points[1].resetScheduleChanged)
    XCTAssertTrue(result.points[1].isIncrease)
    XCTAssertFalse(result.points[1].gapBefore)
  }

  func testSessionAndLongObservationBreaksAreGapsAndDoNotInferDelta() throws {
    let fixture = try Fixture()
    let now = Date(timeIntervalSince1970: 2_000_000)
    let firstSession = UUID()
    let secondSession = UUID()
    let reset = now.addingTimeInterval(2_000)
    try fixture.write([
      observation(now.addingTimeInterval(-1_800), 90, firstSession, reset),
      observation(now.addingTimeInterval(-1_500), 80, secondSession, reset),
      observation(now.addingTimeInterval(-600), 50, secondSession, reset),
      observation(now.addingTimeInterval(-300), 45, secondSession, reset),
    ])

    let result = try fixture.engine.query(
      .init(range: .twentyFourHours),
      now: now
    )
    let summary = try XCTUnwrap(result.windows.first?.summary)
    XCTAssertEqual(summary.observedDecreasePoints, 5)
    XCTAssertEqual(summary.observedIncreasePoints, 0)
    XCTAssertEqual(summary.gapCount, 2)
    XCTAssertEqual(summary.observedSeconds, 300)
  }

  func testIncompleteTailIsIgnoredButMalformedCompleteLineIsCorrupt() throws {
    let fixture = try Fixture()
    let now = Date(timeIntervalSince1970: 2_000_000)
    let value = observation(now, 75, UUID(), now.addingTimeInterval(1_000))
    try fixture.write([value])
    try fixture.appendRaw(Data(#"{"observedAt":"partial""#.utf8))

    let partialResult = try fixture.engine.query(
      .init(range: .twentyFourHours),
      now: now
    )
    XCTAssertEqual(partialResult.windows.first?.summary.sourcePointCount, 1)

    try fixture.write([value])
    try fixture.appendRaw(Data("{bad json}\n".utf8))
    XCTAssertThrowsError(
      try fixture.engine.query(.init(range: .twentyFourHours), now: now)
    ) { error in
      guard case CapacityMCPHistoryQueryError.malformedLine = error else {
        return XCTFail("Unexpected error: \(error)")
      }
    }
  }

  func testRawCursorKeepsInitialCompleteLineCutoffAcrossAppend() throws {
    let fixture = try Fixture()
    let now = Date(timeIntervalSince1970: 2_000_000.123_456)
    let session = UUID()
    let initial = (0..<25).map {
      observation(
        now.addingTimeInterval(TimeInterval(-25 + $0) * 60),
        100 - $0,
        session,
        now.addingTimeInterval(1_000)
      )
    }
    try fixture.write(initial)

    var result = try fixture.engine.query(
      .init(range: .twentyFourHours, resolution: .raw, maxPoints: 10),
      now: now
    )
    var observed = result.points.map(\.observedAt)
    XCTAssertEqual(result.windows.first?.summary.sourcePointCount, 25)
    XCTAssertEqual(result.windows.first?.summary.returnedPointCount, 10)
    try fixture.append(
      (0..<5).map {
        observation(
          now.addingTimeInterval(TimeInterval($0 + 1) * 60),
          70 - $0,
          session,
          now.addingTimeInterval(1_000)
        )
      }
    )

    while let cursor = result.nextCursor {
      result = try fixture.engine.query(.init(cursor: cursor), now: now)
      observed.append(contentsOf: result.points.map(\.observedAt))
    }
    XCTAssertEqual(observed.count, initial.count)
    for (actual, expected) in zip(observed, initial.map(\.observedAt)) {
      XCTAssertEqual(
        actual.timeIntervalSince1970,
        expected.timeIntervalSince1970,
        accuracy: 1
      )
    }
    XCTAssertEqual(Set(observed).count, 25)
  }

  func testRawCursorInvalidatesAfterHistoryReplacement() throws {
    let fixture = try Fixture()
    let now = Date(timeIntervalSince1970: 2_000_000)
    let session = UUID()
    try fixture.write(
      (0..<20).map {
        observation(
          now.addingTimeInterval(TimeInterval(-20 + $0) * 60),
          100 - $0,
          session,
          now.addingTimeInterval(1_000)
        )
      }
    )
    let first = try fixture.engine.query(
      .init(range: .twentyFourHours, resolution: .raw, maxPoints: 10),
      now: now
    )
    let cursor = try XCTUnwrap(first.nextCursor)
    try FileManager.default.removeItem(at: fixture.fileURL)
    try fixture.write([
      observation(now, 100, UUID(), now.addingTimeInterval(10_000))
    ])

    XCTAssertThrowsError(try fixture.engine.query(.init(cursor: cursor))) {
      XCTAssertEqual(
        $0 as? CapacityMCPHistoryQueryError,
        .cursorInvalidated
      )
    }
  }

  func testAutoSamplingHonorsTotalBudgetAndReportsOmittedEvents() throws {
    let fixture = try Fixture()
    let now = Date(timeIntervalSince1970: 3_000_000)
    let session = UUID()
    let records = (0..<1_200).map { index in
      observation(
        now.addingTimeInterval(TimeInterval(-1_200 + index) * 30),
        index.isMultiple(of: 2) ? 10 : 90,
        session,
        now.addingTimeInterval(TimeInterval(index * 30))
      )
    }
    try fixture.write(records)

    let request = CapacityMCPHistoryQueryRequest(
      range: .twentyFourHours,
      resolution: .auto,
      maxPoints: 300
    )
    let first = try fixture.engine.query(request, now: now)
    let second = try fixture.engine.query(request, now: now)
    XCTAssertEqual(first, second)
    XCTAssertEqual(first.points.count, 300)
    XCTAssertEqual(first.windows.first?.summary.sourcePointCount, 1_200)
    XCTAssertEqual(first.windows.first?.summary.returnedPointCount, 300)
    XCTAssertTrue(first.truncated)
    XCTAssertGreaterThan(first.omittedEventPoints, 0)
  }

  func testCurrentWindowRejectsDuplicateDurationIdentity() throws {
    let fixture = try Fixture()
    let now = Date(timeIntervalSince1970: 2_000_000)
    let contexts = ["primary", "secondary"].map {
      CapacityMCPHistoryWindowContext(
        slot: $0,
        windowDurationMinutes: 300,
        remainingPercent: 50,
        observedAt: now,
        resetsAt: now.addingTimeInterval(2 * 60 * 60)
      )
    }
    let engine = CapacityMCPHistoryQueryEngine(
      fileURL: fixture.fileURL,
      context: .init(currentWindows: contexts)
    )
    try fixture.write([
      observation(now, 50, UUID(), now.addingTimeInterval(7_200))
    ])

    XCTAssertThrowsError(
      try engine.query(.init(range: .currentWindow), now: now)
    ) {
      XCTAssertEqual(
        $0 as? CapacityMCPHistoryQueryError,
        .ambiguousWindowIdentity(durationMinutes: 300)
      )
    }
  }

  func testFixedRangeAlsoRejectsDuplicateDurationIdentity() throws {
    let fixture = try Fixture()
    let now = Date(timeIntervalSince1970: 2_000_000)
    let contexts = ["primary", "secondary"].map {
      CapacityMCPHistoryWindowContext(
        slot: $0,
        windowDurationMinutes: 300,
        remainingPercent: 50,
        observedAt: now,
        resetsAt: now.addingTimeInterval(2 * 60 * 60)
      )
    }
    let engine = CapacityMCPHistoryQueryEngine(
      fileURL: fixture.fileURL,
      context: .init(currentWindows: contexts)
    )
    try fixture.write([
      observation(now, 50, UUID(), now.addingTimeInterval(7_200))
    ])

    XCTAssertThrowsError(
      try engine.query(.init(range: .twentyFourHours), now: now)
    ) {
      XCTAssertEqual(
        $0 as? CapacityMCPHistoryQueryError,
        .ambiguousWindowIdentity(durationMinutes: 300)
      )
    }
  }

  func testHistoricalSameDurationWindowsAreAmbiguousWithoutDuplicateCurrentWindows()
    throws
  {
    let fixture = try Fixture()
    let now = Date(timeIntervalSince1970: 2_000_000)
    let reset = now.addingTimeInterval(7_200)
    try fixture.write([
      observation(now, 80, UUID(), reset),
      observation(now, 40, UUID(), reset),
    ])
    let context = CapacityMCPHistoryWindowContext(
      slot: "primary",
      windowDurationMinutes: 300,
      remainingPercent: 80,
      observedAt: now,
      resetsAt: reset
    )
    let engine = CapacityMCPHistoryQueryEngine(
      fileURL: fixture.fileURL,
      context: .init(currentWindows: [context])
    )

    for resolution in [
      CapacityMCPHistoryResolution.auto,
      .raw,
    ] {
      XCTAssertThrowsError(
        try engine.query(
          .init(range: .twentyFourHours, resolution: resolution),
          now: now
        )
      ) {
        XCTAssertEqual(
          $0 as? CapacityMCPHistoryQueryError,
          .ambiguousWindowIdentity(durationMinutes: 300)
        )
      }
    }
  }

  func testUnrelatedDurationIdentityConflictDoesNotBlockTargetWindow() throws {
    let fixture = try Fixture()
    let now = Date(timeIntervalSince1970: 2_000_000)
    let reset = now.addingTimeInterval(7_200)
    let session = UUID()
    try fixture.write([
      observation(now.addingTimeInterval(-120), 80, session, reset),
      observation(now.addingTimeInterval(-60), 75, session, reset),
      observation(now, 60, UUID(), reset, duration: 10_080),
      observation(now, 40, UUID(), reset, duration: 10_080),
    ])

    for resolution in [CapacityMCPHistoryResolution.auto, .raw] {
      let result = try fixture.engine.query(
        .init(
          windowDurationMinutes: 300,
          range: .twentyFourHours,
          resolution: resolution
        ),
        now: now
      )
      XCTAssertEqual(result.windows.count, 1)
      XCTAssertEqual(result.windows.first?.summary.observedDecreasePoints, 5)
      XCTAssertEqual(result.points.count, 2)
    }
  }

  func testRawCursorIgnoresInjectedCachedFactsAndRebuildsFromFile() throws {
    let fixture = try Fixture()
    let now = Date(timeIntervalSince1970: 2_000_000.123_456)
    let session = UUID()
    let reset = now.addingTimeInterval(7_200)
    try fixture.write((0..<25).map { index in
      observation(
        now.addingTimeInterval(TimeInterval(-25 + index) * 60),
        100 - index,
        session,
        reset
      )
    })
    let first = try fixture.engine.query(
      .init(range: .twentyFourHours, resolution: .raw, maxPoints: 10),
      now: now
    )
    let cursor = try XCTUnwrap(first.nextCursor)
    let expected = try fixture.engine.query(.init(cursor: cursor))
    let forged = try modifiedCursor(cursor) { object in
      object["summaries"] = [[
        "observedDecreasePoints": 99_999,
        "observedIncreasePoints": 99_999,
        "observedSeconds": 99_999,
        "requestedSeconds": 99_999,
        "coverageRatio": 1,
        "gapCount": 0,
        "resetScheduleChangeCount": 0,
        "sourcePointCount": 99_999,
        "returnedPointCount": 0,
      ]]
      object["historyThrough"] = 0
      object["continuationState"] = [
        "previousByDuration": [:],
        "identityEvidenceByDuration": [:],
      ]
    }
    let actual = try fixture.engine.query(.init(cursor: forged))
    XCTAssertEqual(actual.windows, expected.windows)
    XCTAssertEqual(actual.points, expected.points)
    XCTAssertEqual(actual.historyThrough, expected.historyThrough)
    XCTAssertEqual(actual.analysisCutoff, first.analysisCutoff)
  }

  func testRawCursorSelectedLineOffsetUsesFileDerivedPriorState() throws {
    let fixture = try Fixture()
    let now = Date(timeIntervalSince1970: 2_000_000)
    let session = UUID()
    try fixture.write((0..<25).map { index in
      observation(
        now.addingTimeInterval(TimeInterval(-25 + index) * 60),
        100 - index,
        session,
        now.addingTimeInterval(7_200)
      )
    })
    let first = try fixture.engine.query(
      .init(range: .twentyFourHours, resolution: .raw, maxPoints: 10),
      now: now
    )
    let cursor = try XCTUnwrap(first.nextCursor)
    let data = try Data(contentsOf: fixture.fileURL)
    let starts = [0] + data.enumerated().compactMap { offset, byte in
      byte == 0x0A ? offset + 1 : nil
    }
    let forged = try modifiedCursor(cursor) { object in
      object["nextOffset"] = starts[15]
    }

    let page = try fixture.engine.query(.init(cursor: forged))
    XCTAssertEqual(page.points.count, 10)
    XCTAssertEqual(page.points.first?.remainingPercent, 85)
    XCTAssertEqual(page.points.first?.gapBefore, false)
    XCTAssertEqual(page.windows.first?.summary.observedDecreasePoints, 24)
    XCTAssertEqual(page.windows.first?.summary.sourcePointCount, 25)
  }

  func testRawCursorRejectsNonLineEndHorizon() throws {
    let fixture = try Fixture()
    let now = Date(timeIntervalSince1970: 2_000_000)
    let session = UUID()
    try fixture.write((0..<20).map { index in
      observation(
        now.addingTimeInterval(TimeInterval(-20 + index) * 60),
        100 - index,
        session,
        now.addingTimeInterval(7_200)
      )
    })
    let first = try fixture.engine.query(
      .init(range: .twentyFourHours, resolution: .raw, maxPoints: 10),
      now: now
    )
    let cursor = try XCTUnwrap(first.nextCursor)
    let forged = try modifiedCursor(cursor) { object in
      object["endOffset"] = (object["endOffset"] as! NSNumber).uint64Value - 1
    }
    XCTAssertThrowsError(try fixture.engine.query(.init(cursor: forged))) {
      XCTAssertEqual($0 as? CapacityMCPHistoryQueryError, .invalidCursor)
    }
  }

  func testForgedDuplicateRangeCursorIsRejectedBeforeAccumulatorCreation()
    throws
  {
    let fixture = try Fixture()
    let now = Date(timeIntervalSince1970: 2_000_000)
    let session = UUID()
    try fixture.write(
      (0..<20).map {
        observation(
          now.addingTimeInterval(TimeInterval(-20 + $0) * 60),
          100 - $0,
          session,
          now.addingTimeInterval(7_200)
        )
      }
    )
    let first = try fixture.engine.query(
      .init(range: .twentyFourHours, resolution: .raw, maxPoints: 10),
      now: now
    )
    let cursor = try XCTUnwrap(first.nextCursor)
    let forged = try forgedDuplicateRangeCursor(cursor)

    XCTAssertThrowsError(try fixture.engine.query(.init(cursor: forged))) {
      XCTAssertEqual($0 as? CapacityMCPHistoryQueryError, .invalidCursor)
    }
  }

  func testRawContinuationRejectsCorruptionBeforeCursorByteOffset() throws {
    let fixture = try Fixture()
    let now = Date(timeIntervalSince1970: 2_000_000)
    let session = UUID()
    try fixture.write(
      (0..<25).map {
        observation(
          now.addingTimeInterval(TimeInterval(-25 + $0) * 60),
          100 - $0,
          session,
          now.addingTimeInterval(7_200)
        )
      }
    )
    let first = try fixture.engine.query(
      .init(range: .twentyFourHours, resolution: .raw, maxPoints: 10),
      now: now
    )
    let cursor = try XCTUnwrap(first.nextCursor)
    let handle = try FileHandle(forUpdating: fixture.fileURL)
    try handle.seek(toOffset: 0)
    try handle.write(contentsOf: Data([0x21]))
    try handle.close()

    XCTAssertThrowsError(try fixture.engine.query(.init(cursor: cursor))) {
      XCTAssertEqual(
        $0 as? CapacityMCPHistoryQueryError,
        .malformedLine(byteOffset: 0)
      )
    }
  }

  func testCurrentWindowRequiresFutureReset() throws {
    let fixture = try Fixture()
    let now = Date(timeIntervalSince1970: 2_000_000)
    let context = CapacityMCPHistoryWindowContext(
      slot: "primary",
      windowDurationMinutes: 300,
      remainingPercent: 50,
      observedAt: now,
      resetsAt: now
    )
    let engine = CapacityMCPHistoryQueryEngine(
      fileURL: fixture.fileURL,
      context: .init(currentWindows: [context])
    )
    try fixture.write([
      observation(now, 50, UUID(), now)
    ])

    XCTAssertThrowsError(
      try engine.query(.init(range: .currentWindow), now: now)
    ) { error in
      guard case CapacityMCPHistoryQueryError.invalidArguments = error else {
        return XCTFail("Unexpected error: \(error)")
      }
    }
  }

  func testEvenPaceAndLinearScenarioArePureFreshArithmetic() throws {
    let now = Date(timeIntervalSince1970: 2_000_000)
    let duration = 300
    let reset = now.addingTimeInterval(TimeInterval(duration * 60) * 0.5)
    let context = CapacityMCPHistoryWindowContext(
      slot: "primary",
      windowDurationMinutes: duration,
      remainingPercent: 25,
      observedAt: now,
      resetsAt: reset
    )
    let arithmetic = try XCTUnwrap(
      CapacityMCPWindowArithmeticPolicy.make(
        context: context,
        now: now,
        isAvailable: true
      )
    )
    XCTAssertEqual(arithmetic.progressRatio, 0.5, accuracy: 0.0001)
    XCTAssertEqual(arithmetic.expectedRemainingPercent, 50, accuracy: 0.0001)
    XCTAssertEqual(arithmetic.remainingVsEvenPacePoints, -25, accuracy: 0.0001)
    XCTAssertNotNil(arithmetic.linearScenario?.depletionAt)
    XCTAssertNil(arithmetic.linearScenario?.remainingAtReset)

    let stale = CapacityMCPWindowArithmeticPolicy.make(
      context: context,
      now: now.addingTimeInterval(361),
      isAvailable: true
    )
    XCTAssertNil(stale?.linearScenario)

    let expired = CapacityMCPWindowArithmeticPolicy.make(
      context: CapacityMCPHistoryWindowContext(
        slot: "primary",
        windowDurationMinutes: duration,
        remainingPercent: 25,
        observedAt: reset.addingTimeInterval(-60),
        resetsAt: reset
      ),
      now: reset.addingTimeInterval(1),
      isAvailable: true
    )
    XCTAssertNil(expired)
  }
}

private extension CapacityMCPHistoryQueryEngineTests {
  func modifiedCursor(
    _ cursor: String,
    mutate: (inout [String: Any]) -> Void
  ) throws -> String {
    let data = try XCTUnwrap(Data(base64URLString: cursor))
    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    mutate(&object)
    return try JSONSerialization.data(
      withJSONObject: object,
      options: [.sortedKeys]
    ).base64URLEncodedString()
  }

  func forgedDuplicateRangeCursor(_ cursor: String) throws -> String {
    let data = try XCTUnwrap(Data(base64URLString: cursor))
    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    var query = try XCTUnwrap(object["query"] as? [String: Any])
    let ranges = try XCTUnwrap(query["ranges"] as? [[String: Any]])
    XCTAssertEqual(try queryHash(query), object["queryHash"] as? String)
    query["ranges"] = [try XCTUnwrap(ranges.first), try XCTUnwrap(ranges.first)]
    object["query"] = query
    object["queryHash"] = try queryHash(query)
    let forged = try JSONSerialization.data(
      withJSONObject: object,
      options: [.sortedKeys]
    )
    return forged.base64URLEncodedString()
  }

  func queryHash(_ query: [String: Any]) throws -> String {
    let data = try JSONSerialization.data(
      withJSONObject: query,
      options: [.sortedKeys]
    )
    return SHA256.hash(data: data).map {
      String(format: "%02x", $0)
    }.joined()
  }

  final class Fixture {
    let directory: URL
    let fileURL: URL
    var engine: CapacityMCPHistoryQueryEngine {
      CapacityMCPHistoryQueryEngine(fileURL: fileURL)
    }

    init() throws {
      directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
      try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
      )
      fileURL = directory.appendingPathComponent("v1.jsonl")
    }

    deinit {
      try? FileManager.default.removeItem(at: directory)
    }

    func write(_ observations: [CapacityObservation]) throws {
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      var data = Data()
      for observation in observations {
        data.append(try encoder.encode(observation))
        data.append(0x0A)
      }
      try data.write(to: fileURL, options: .atomic)
    }

    func append(_ observations: [CapacityObservation]) throws {
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      let handle = try FileHandle(forWritingTo: fileURL)
      defer { try? handle.close() }
      try handle.seekToEnd()
      for observation in observations {
        try handle.write(contentsOf: try encoder.encode(observation))
        try handle.write(contentsOf: Data([0x0A]))
      }
    }

    func appendRaw(_ data: Data) throws {
      let handle = try FileHandle(forWritingTo: fileURL)
      defer { try? handle.close() }
      try handle.seekToEnd()
      try handle.write(contentsOf: data)
    }
  }

  func observation(
    _ date: Date,
    _ remaining: Int,
    _ session: UUID,
    _ reset: Date,
    duration: Int = 300
  ) -> CapacityObservation {
    CapacityObservation(
      observedAt: date,
      remainingPercent: remaining,
      sessionID: session,
      windowDurationMinutes: duration,
      resetsAt: reset
    )
  }
}

private extension Data {
  init?(base64URLString value: String) {
    var base64 = value
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
    self.init(base64Encoded: base64)
  }

  func base64URLEncodedString() -> String {
    base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
}
