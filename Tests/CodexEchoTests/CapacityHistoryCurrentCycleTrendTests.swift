import Foundation
import XCTest

@testable import CodexEcho

final class CapacityHistoryCurrentCycleTrendTests: XCTestCase {
  func testCurrentCycleTrendAnchorsAtFullCapacityAndEndsAtLatestValue() throws {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let reset = start.addingTimeInterval(7 * 24 * 60 * 60)
    let previousCycle = CapacityObservation(
      observedAt: start.addingTimeInterval(5),
      remainingPercent: 8,
      sessionID: UUID(),
      resetsAt: reset.addingTimeInterval(-60)
    )
    let currentCycle = [
      CapacityObservation(
        observedAt: start.addingTimeInterval(25),
        remainingPercent: 99,
        sessionID: UUID(),
        resetsAt: reset
      ),
      CapacityObservation(
        observedAt: start.addingTimeInterval(100),
        remainingPercent: 96,
        sessionID: UUID(),
        resetsAt: reset
      ),
    ]

    let trend = try XCTUnwrap(
      CapacityHistoryCurrentCycleTrendPolicy.trend(
        [
          CapacityHistorySegment(observations: [previousCycle]),
          CapacityHistorySegment(observations: currentCycle),
        ],
        rangeStart: start,
        rangeEnd: reset
      )
    )

    XCTAssertEqual(trend.knots.count, 5)
    XCTAssertEqual(trend.knots.first?.observedAt, start)
    XCTAssertEqual(trend.knots.first?.remainingPercent, 100)
    XCTAssertEqual(trend.knots.last?.observedAt, currentCycle.last?.observedAt)
    XCTAssertEqual(trend.knots.last?.remainingPercent, 96)
    XCTAssertFalse(trend.knots.contains { $0.remainingPercent < 96 })
  }

  func testCurrentCycleTrendKeepsIntermediateShapeAcrossFiveSecondResetJitter()
    throws
  {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let reset = start.addingTimeInterval(7 * 24 * 60 * 60)
    let sessionID = UUID()
    let samples: [(TimeInterval, Int, TimeInterval)] = [
      (8 * 60 * 60, 99, 0),
      (16 * 60 * 60, 95, 0),
      (24 * 60 * 60, 85, 0),
      (32 * 60 * 60, 72, 5),
    ]
    let observations = samples.map {
      observedOffset,
      remainingPercent,
      resetOffset in
      CapacityObservation(
        observedAt: start.addingTimeInterval(observedOffset),
        remainingPercent: remainingPercent,
        sessionID: sessionID,
        resetsAt: reset.addingTimeInterval(resetOffset)
      )
    }

    let trend = try XCTUnwrap(
      CapacityHistoryCurrentCycleTrendPolicy.trend(
        [CapacityHistorySegment(observations: observations)],
        rangeStart: start,
        rangeEnd: reset,
        activeResetsAt: reset
      )
    )

    XCTAssertEqual(trend.knots.count, 5)
    XCTAssertEqual(trend.knots[1].remainingPercent, 99, accuracy: 0.000_001)
    XCTAssertEqual(trend.knots.last?.remainingPercent, 72)
  }

  func testAuthoritativeResetExcludesOldCycleWhenOnlySummaryEndpointIsCurrent()
    throws
  {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let reset = start.addingTimeInterval(7 * 24 * 60 * 60)
    let oldCycle = CapacityObservation(
      observedAt: start.addingTimeInterval(120),
      remainingPercent: 8,
      sessionID: UUID(),
      resetsAt: reset.addingTimeInterval(-7 * 24 * 60 * 60)
    )
    let summaryEndpoint = CapacityHistoryCurrentCycleEndpoint(
      observedAt: start.addingTimeInterval(90),
      remainingPercent: 97
    )

    let trend = try XCTUnwrap(
      CapacityHistoryCurrentCycleTrendPolicy.trend(
        [CapacityHistorySegment(observations: [oldCycle])],
        rangeStart: start,
        rangeEnd: reset,
        activeResetsAt: reset,
        summaryEndpoint: summaryEndpoint
      )
    )

    XCTAssertEqual(trend.knots.first?.remainingPercent, 100)
    XCTAssertEqual(trend.knots.last?.observedAt, summaryEndpoint.observedAt)
    XCTAssertEqual(trend.knots.last?.remainingPercent, 97)
    XCTAssertTrue(trend.knots.allSatisfy { $0.remainingPercent >= 97 })
  }

  func testCurrentCycleTrendAbsorbsAnObservedIncreaseWithoutTurningUp() throws {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let reset = start.addingTimeInterval(7 * 24 * 60 * 60)
    let sessionID = UUID()
    let observations = [
      (0.0, 100),
      (30.0, 85),
      (60.0, 83),
      (100.0, 84),
    ].map { offset, remainingPercent in
      CapacityObservation(
        observedAt: start.addingTimeInterval(offset),
        remainingPercent: remainingPercent,
        sessionID: sessionID,
        resetsAt: reset
      )
    }
    let trend = try XCTUnwrap(
      CapacityHistoryCurrentCycleTrendPolicy.trend(
        [CapacityHistorySegment(observations: observations)],
        rangeStart: start,
        rangeEnd: reset
      )
    )
    let samples = trend.samples(plotWidth: 760, rangeEnd: reset)

    XCTAssertEqual(samples.first?.remainingPercent, 100)
    XCTAssertEqual(samples.last?.remainingPercent, 84)
    XCTAssertTrue(
      zip(samples, samples.dropFirst()).allSatisfy {
        $0.remainingPercent >= $1.remainingPercent
      }
    )
    XCTAssertTrue(
      samples.allSatisfy { (0...100).contains($0.remainingPercent) }
    )
  }

  func testCurrentCycleTrendUsesFreshLiveValueAsItsExactEndpoint() throws {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let reset = start.addingTimeInterval(7 * 24 * 60 * 60)
    let sessionID = UUID()
    let latest = CapacityObservation(
      observedAt: start.addingTimeInterval(60),
      remainingPercent: 98,
      sessionID: sessionID,
      resetsAt: reset
    )
    let liveObservedAt = start.addingTimeInterval(90)
    let now = start.addingTimeInterval(120)
    let liveTail = try XCTUnwrap(
      CapacityHistoryLiveTail(
        latestObservation: latest,
        liveRemainingPercent: 97,
        liveSessionID: sessionID,
        monitoringState: .recording(observedAt: liveObservedAt),
        now: now
      )
    )
    let trend = try XCTUnwrap(
      CapacityHistoryCurrentCycleTrendPolicy.trend(
        [CapacityHistorySegment(observations: [latest])],
        rangeStart: start,
        rangeEnd: reset,
        activeResetsAt: reset,
        liveTail: liveTail,
        summaryEndpoint: CapacityHistoryCurrentCycleEndpoint(
          observedAt: now.addingTimeInterval(30),
          remainingPercent: 50
        )
      )
    )

    XCTAssertEqual(trend.knots.last?.observedAt, now)
    XCTAssertEqual(trend.knots.last?.remainingPercent, 97)
  }

  func testSummaryEndpointIsUsedOnlyWhenNewerThanMatchingStoredLatest()
    throws
  {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let reset = start.addingTimeInterval(7 * 24 * 60 * 60)
    let latestDate = start.addingTimeInterval(60)
    let latest = CapacityObservation(
      observedAt: latestDate,
      remainingPercent: 96,
      sessionID: UUID(),
      resetsAt: reset
    )
    let segment = CapacityHistorySegment(observations: [latest])

    let newer = try XCTUnwrap(
      CapacityHistoryCurrentCycleTrendPolicy.trend(
        [segment],
        rangeStart: start,
        rangeEnd: reset,
        activeResetsAt: reset,
        summaryEndpoint: CapacityHistoryCurrentCycleEndpoint(
          observedAt: latestDate.addingTimeInterval(30),
          remainingPercent: 94
        )
      )
    )
    XCTAssertEqual(
      newer.knots.last?.observedAt,
      latestDate.addingTimeInterval(30)
    )
    XCTAssertEqual(newer.knots.last?.remainingPercent, 94)

    let same = try XCTUnwrap(
      CapacityHistoryCurrentCycleTrendPolicy.trend(
        [segment],
        rangeStart: start,
        rangeEnd: reset,
        activeResetsAt: reset,
        summaryEndpoint: CapacityHistoryCurrentCycleEndpoint(
          observedAt: latestDate,
          remainingPercent: 40
        )
      )
    )
    XCTAssertEqual(same.knots.last?.observedAt, latestDate)
    XCTAssertEqual(same.knots.last?.remainingPercent, 96)

    let older = try XCTUnwrap(
      CapacityHistoryCurrentCycleTrendPolicy.trend(
        [segment],
        rangeStart: start,
        rangeEnd: reset,
        activeResetsAt: reset,
        summaryEndpoint: CapacityHistoryCurrentCycleEndpoint(
          observedAt: latestDate.addingTimeInterval(-30),
          remainingPercent: 20
        )
      )
    )
    XCTAssertEqual(older.knots.last?.observedAt, latestDate)
    XCTAssertEqual(older.knots.last?.remainingPercent, 96)
  }

  func testSummaryEndpointStopsAtItsOriginalObservationTime() throws {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let reset = start.addingTimeInterval(7 * 24 * 60 * 60)
    let summaryEndpoint = CapacityHistoryCurrentCycleEndpoint(
      observedAt: start.addingTimeInterval(2 * 60 * 60),
      remainingPercent: 91
    )
    let series = try XCTUnwrap(
      CapacityHistoryCurrentCycleRenderPolicy.series(
        [],
        rangeStart: start,
        rangeEnd: reset,
        activeResetsAt: reset,
        summaryEndpoint: summaryEndpoint,
        plotWidth: 600
      )
    )

    XCTAssertEqual(series.trend.knots.last?.observedAt, summaryEndpoint.observedAt)
    XCTAssertEqual(series.samples.last?.observedAt, summaryEndpoint.observedAt)
    XCTAssertLessThan(summaryEndpoint.observedAt, reset)
  }

  func testSummaryEndpointOutsideCurrentCycleDoesNotProduceTrend() {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let reset = start.addingTimeInterval(7 * 24 * 60 * 60)

    XCTAssertNil(
      CapacityHistoryCurrentCycleTrendPolicy.trend(
        [],
        rangeStart: start,
        rangeEnd: reset,
        activeResetsAt: reset,
        summaryEndpoint: CapacityHistoryCurrentCycleEndpoint(
          observedAt: reset.addingTimeInterval(1),
          remainingPercent: 80
        )
      )
    )
  }

  func testCurrentCycleTrendHasFiniteBoundedTangentsAndNoOvershoot() throws {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let reset = start.addingTimeInterval(7 * 24 * 60 * 60)
    let sessionID = UUID()
    let observations = [
      (0.0, 100),
      (60.0, 100),
      (120.0, 99),
      (180.0, 99),
      (240.0, 94),
    ].map { offset, remainingPercent in
      CapacityObservation(
        observedAt: start.addingTimeInterval(offset),
        remainingPercent: remainingPercent,
        sessionID: sessionID,
        resetsAt: reset
      )
    }
    let trend = try XCTUnwrap(
      CapacityHistoryCurrentCycleTrendPolicy.trend(
        [CapacityHistorySegment(observations: observations)],
        rangeStart: start,
        rangeEnd: reset
      )
    )
    let globalSlope = try XCTUnwrap(trend.knots.last).remainingPercent
      - (try XCTUnwrap(trend.knots.first).remainingPercent)

    XCTAssertTrue(trend.tangents.allSatisfy(\.isFinite))
    XCTAssertTrue(trend.tangents.allSatisfy { $0 <= 0 })
    XCTAssertTrue(
      trend.tangents.allSatisfy {
        abs($0) <= (2 * abs(globalSlope)) + 0.000_001
      }
    )

    let values = (0...200).map {
      trend.remainingPercent(atNormalizedTime: Double($0) / 200)
    }
    XCTAssertTrue(zip(values, values.dropFirst()).allSatisfy(>=))
    XCTAssertTrue(values.allSatisfy { (94...100).contains($0) })
  }

  func testConsumingTrendKeepsEndpointTangentPointingDownAfterRecentPlateau()
    throws
  {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let reset = start.addingTimeInterval(7 * 24 * 60 * 60)
    let sessionID = UUID()
    let observations = [
      (0.0, 100),
      (10.0, 90),
      (40.0, 90),
      (100.0, 90),
    ].map { offset, remainingPercent in
      CapacityObservation(
        observedAt: start.addingTimeInterval(offset),
        remainingPercent: remainingPercent,
        sessionID: sessionID,
        resetsAt: reset
      )
    }
    let trend = try XCTUnwrap(
      CapacityHistoryCurrentCycleTrendPolicy.trend(
        [CapacityHistorySegment(observations: observations)],
        rangeStart: start,
        rangeEnd: reset
      )
    )

    XCTAssertLessThan(try XCTUnwrap(trend.tangents.last), 0)
    let values = (0...200).map {
      trend.remainingPercent(atNormalizedTime: Double($0) / 200)
    }
    XCTAssertTrue(zip(values, values.dropFirst()).allSatisfy(>=))
    XCTAssertEqual(values.last, 90)
  }

  func testCurrentCycleTrendShapeDoesNotDependOnPlotWidth() throws {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let reset = start.addingTimeInterval(7 * 24 * 60 * 60)
    let sessionID = UUID()
    let samples: [(TimeInterval, Int)] = [
      (0.0, 100),
      (2 * 60 * 60, 99),
      (4 * 60 * 60, 97),
      (8 * 60 * 60, 96),
    ]
    let observations = samples.map { offset, remainingPercent in
      CapacityObservation(
        observedAt: start.addingTimeInterval(offset),
        remainingPercent: remainingPercent,
        sessionID: sessionID,
        resetsAt: reset
      )
    }
    let trend = try XCTUnwrap(
      CapacityHistoryCurrentCycleTrendPolicy.trend(
        [CapacityHistorySegment(observations: observations)],
        rangeStart: start,
        rangeEnd: reset
      )
    )
    let compact = trend.samples(plotWidth: 600, rangeEnd: reset)
    let spacious = trend.samples(plotWidth: 1_400, rangeEnd: reset)

    XCTAssertNotEqual(compact.count, spacious.count)
    XCTAssertEqual(compact.first, spacious.first)
    XCTAssertEqual(compact.last, spacious.last)
    let observedDuration = try XCTUnwrap(trend.knots.last?.observedAt)
      .timeIntervalSince(start)
    for sample in compact + spacious {
      let normalizedTime = sample.observedAt.timeIntervalSince(start)
        / observedDuration
      XCTAssertEqual(
        sample.remainingPercent,
        trend.remainingPercent(atNormalizedTime: normalizedTime),
        accuracy: 0.000_001
      )
    }
  }

  func testCurrentCycleTrendUsesFiveTimeNormalizedKnots() throws {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let sessionID = UUID()
    let samples: [(TimeInterval, Int)] = [
      (0.0, 100),
      (4 * 60 * 60, 99),
      (5 * 60 * 60, 98),
      (7.5 * 60 * 60, 97),
      (8.25 * 60 * 60, 96),
    ]
    let observations = samples.map { offset, remainingPercent in
      CapacityObservation(
        observedAt: start.addingTimeInterval(offset),
        remainingPercent: remainingPercent,
        sessionID: sessionID
      )
    }
    let rangeEnd = start.addingTimeInterval(7 * 24 * 60 * 60)
    let trend = try XCTUnwrap(
      CapacityHistoryCurrentCycleTrendPolicy.trend(
        [CapacityHistorySegment(observations: observations)],
        rangeStart: start,
        rangeEnd: rangeEnd
      )
    )
    let elapsed = try XCTUnwrap(trend.knots.last?.observedAt)
      .timeIntervalSince(start)

    XCTAssertEqual(trend.knots.count, 5)
    for (index, knot) in trend.knots.enumerated() {
      XCTAssertEqual(
        knot.observedAt.timeIntervalSince(start),
        elapsed * Double(index) / 4,
        accuracy: 0.000_001
      )
    }
  }

  func testRenderPolicyKeepsCanonicalShapeStableAcrossWidths() throws {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let reset = start.addingTimeInterval(7 * 24 * 60 * 60)
    let sessionID = UUID()
    let fixture: [(TimeInterval, Int)] = [
      (0.0, 100),
      (2 * 60 * 60, 99),
      (4 * 60 * 60, 97),
      (8 * 60 * 60, 96),
    ]
    let observations = fixture.map { offset, remainingPercent in
      CapacityObservation(
        observedAt: start.addingTimeInterval(offset),
        remainingPercent: remainingPercent,
        sessionID: sessionID,
        resetsAt: reset
      )
    }
    let segment = CapacityHistorySegment(observations: observations)
    let summaryEndpoint = CapacityHistoryCurrentCycleEndpoint(
      observedAt: start.addingTimeInterval(10 * 60 * 60),
      remainingPercent: 95
    )

    let compact = try XCTUnwrap(
      CapacityHistoryCurrentCycleRenderPolicy.series(
        [segment],
        rangeStart: start,
        rangeEnd: reset,
        activeResetsAt: reset,
        summaryEndpoint: summaryEndpoint,
        plotWidth: 600
      )
    )
    let spacious = try XCTUnwrap(
      CapacityHistoryCurrentCycleRenderPolicy.series(
        [segment],
        rangeStart: start,
        rangeEnd: reset,
        activeResetsAt: reset,
        summaryEndpoint: summaryEndpoint,
        plotWidth: 1_400
      )
    )

    XCTAssertEqual(compact.trend, spacious.trend)
    XCTAssertEqual(compact.samples.last?.observedAt, summaryEndpoint.observedAt)
    XCTAssertEqual(compact.samples.last?.remainingPercent, 95)
    XCTAssertNotEqual(compact.samples.count, spacious.samples.count)
    XCTAssertEqual(compact.lineSamples, compact.bandSamples)
    XCTAssertEqual(spacious.lineSamples, spacious.bandSamples)
    for normalizedTime in stride(from: 0.0, through: 1.0, by: 0.025) {
      XCTAssertEqual(
        compact.trend.remainingPercent(atNormalizedTime: normalizedTime),
        spacious.trend.remainingPercent(atNormalizedTime: normalizedTime),
        accuracy: 0.000_001
      )
    }

    _ = CapacityHistoryVisualSamplingPolicy.segments(
      [segment],
      rangeStart: start,
      rangeEnd: reset,
      plotWidth: 600
    )
    XCTAssertEqual(segment.observations, observations)
  }

  #if DEBUG
    func testTrendCaptureFixtureIncludesGapHeartbeatAndCorrection() async throws {
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
      let fileURL = directory.appendingPathComponent("trend.jsonl")
      defer { try? FileManager.default.removeItem(at: directory) }
      let store = CapacityHistoryStore(fileURL: fileURL)
      let now = Date(timeIntervalSince1970: 1_800_000_000)

      CapacityHistoryDebugFixture.seedIfRequested(
        store: store,
        environment: [
          "CODEX_ECHO_DEBUG_CAPACITY_HISTORY_FIXTURE": "trend",
          "CODEX_ECHO_DEBUG_CAPACITY_HISTORY_FILE": fileURL.path,
        ],
        now: now
      )
      let observations = try await store.readAll()

      XCTAssertEqual(observations.count, 8)
      XCTAssertEqual(Set(observations.map(\.sessionID)).count, 2)
      XCTAssertTrue(
        zip(observations, observations.dropFirst()).contains {
          $0.remainingPercent == $1.remainingPercent
        }
      )
      XCTAssertTrue(
        zip(observations, observations.dropFirst()).contains {
          $0.remainingPercent < $1.remainingPercent
        }
      )
      XCTAssertEqual(Set(observations.compactMap(\.resetsAt)).count, 1)
    }

    func testResizeCapturePolicyUsesCanonicalReviewSizes() {
      XCTAssertEqual(
        CapacityHistoryResizeCapturePolicy.sizes,
        [
          .init(width: 600, height: 380, fileName: "compact-600x380.png"),
          .init(width: 1_400, height: 380, fileName: "spacious-1400x380.png"),
          .init(width: 600, height: 500, fileName: "compact-600x500.png"),
          .init(width: 1_400, height: 500, fileName: "spacious-1400x500.png"),
        ]
      )
      XCTAssertEqual(
        CapacityHistoryResizeCapturePolicy.completionFileName,
        "capture-complete"
      )
      XCTAssertTrue(
        CapacityHistoryResizeCapturePolicy.isRequested(
          environment: [
            CapacityHistoryResizeCapturePolicy.directoryEnvironmentKey:
              "/tmp/capacity-capture",
          ]
        )
      )
      XCTAssertFalse(
        CapacityHistoryResizeCapturePolicy.isRequested(environment: [:])
      )
    }
  #endif
}

private extension CapacityObservation {
  init(
    observedAt: Date,
    remainingPercent: Int,
    sessionID: UUID,
    resetsAt: Date? = nil
  ) {
    self.init(
      observedAt: observedAt,
      remainingPercent: remainingPercent,
      sessionID: sessionID,
      windowDurationMinutes: 7 * 24 * 60,
      resetsAt: resetsAt
    )
  }
}
