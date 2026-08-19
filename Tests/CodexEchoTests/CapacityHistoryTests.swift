import AppKit
import Accessibility
import CodexAppServer
import CodexIPC
import Foundation
import SwiftUI
import XCTest

@testable import CodexEcho

private extension CapacityHistoryLimit {
  static let shortWindow = Self(windowDurationMinutes: 5 * 60)
  static let weeklyWindow = Self(windowDurationMinutes: 7 * 24 * 60)
}

final class CapacityHistoryTests: XCTestCase {
  private let minute: TimeInterval = 60

  func testHistoryHeartbeatScheduleAlignsToFiveMinuteClockBoundaries() {
    XCTAssertEqual(
      HistoryHeartbeatSchedule.firstFireDate(
        startedAt: Date(timeIntervalSince1970: 1_800_000_123)
      ),
      Date(timeIntervalSince1970: 1_800_000_600)
    )
    XCTAssertEqual(
      HistoryHeartbeatSchedule.firstFireDate(
        startedAt: Date(timeIntervalSince1970: 1_800_000_300)
      ),
      Date(timeIntervalSince1970: 1_800_000_600)
    )
    XCTAssertEqual(
      HistoryHeartbeatSchedule.publisherAlignmentDelay(
        startedAt: Date(timeIntervalSince1970: 1_800_000_123)
      ),
      177,
      accuracy: 0.001
    )
    XCTAssertEqual(
      HistoryHeartbeatSchedule.publisherAlignmentDelay(
        startedAt: Date(timeIntervalSince1970: 1_800_000_300)
      ),
      0,
      accuracy: 0.001
    )
  }

  func testRecordingPolicyRecordsFirstChangeAndFiveMinuteHeartbeat() throws {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    var policy = CapacityHistoryRecordingPolicy()

    policy.handleConnectionState(.running)
    let first = try XCTUnwrap(
      policy.observation(remainingPercent: 82, observedAt: start)
    )
    XCTAssertNil(
      policy.observation(
        remainingPercent: 82,
        observedAt: start.addingTimeInterval(4 * minute)
      )
    )

    let change = try XCTUnwrap(
      policy.observation(
        remainingPercent: 79,
        observedAt: start.addingTimeInterval(4.5 * minute)
      )
    )
    let heartbeat = try XCTUnwrap(
      policy.observation(
        remainingPercent: 79,
        observedAt: start.addingTimeInterval(9.5 * minute)
      )
    )

    XCTAssertEqual(first.remainingPercent, 82)
    XCTAssertEqual(change.remainingPercent, 79)
    XCTAssertEqual(heartbeat.remainingPercent, 79)
    XCTAssertEqual(first.sessionID, change.sessionID)
    XCTAssertEqual(change.sessionID, heartbeat.sessionID)
  }

  func testRecordingPolicyCanUseADeterministicFixtureSession() throws {
    let sessionID = try XCTUnwrap(
      UUID(uuidString: "5A1D0000-0000-0000-0000-000000000001")
    )
    var policy = CapacityHistoryRecordingPolicy(
      makeSessionID: { sessionID }
    )
    policy.handleConnectionState(.running)

    let observation = try XCTUnwrap(
      policy.observation(
        remainingPercent: 65,
        observedAt: Date(timeIntervalSince1970: 1_800_000_000)
      )
    )

    XCTAssertEqual(observation.sessionID, sessionID)
  }

  func testRecordingPolicyRecordsAResetBoundaryEvenWhenPercentIsUnchanged() throws {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let firstReset = start.addingTimeInterval(5 * 60 * 60)
    let secondReset = firstReset.addingTimeInterval(5 * 60 * 60)
    var policy = CapacityHistoryRecordingPolicy()
    policy.handleConnectionState(.running)

    let first = try XCTUnwrap(
      policy.observation(
        remainingPercent: 80,
        observedAt: start,
        windowDurationMinutes: 300,
        resetsAt: firstReset
      )
    )
    let resetBoundary = try XCTUnwrap(
      policy.observation(
        remainingPercent: 80,
        observedAt: start.addingTimeInterval(minute),
        windowDurationMinutes: 300,
        resetsAt: secondReset
      )
    )

    XCTAssertEqual(first.resetsAt, firstReset)
    XCTAssertEqual(resetBoundary.resetsAt, secondReset)
    let projection = CapacityHistoryProjection(
      observations: [first, resetBoundary],
      period: .twentyFourHours,
      now: start.addingTimeInterval(2 * minute)
    )
    XCTAssertEqual(projection.segments.map(\.observations.count), [1, 1])
    XCTAssertTrue(projection.changes.isEmpty)
  }

  func testCurrentWindowViewportRunsFromDerivedStartThroughReset() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let reset = now.addingTimeInterval(2 * 60 * 60)
    let window = CodexRateLimitWindow(
      slot: .primary,
      usedPercent: 25,
      windowDurationMinutes: 300,
      resetsAt: reset
    )

    let viewport = try XCTUnwrap(
      CapacityHistoryViewport.make(
        selection: .currentWindow,
        window: window,
        now: now
      )
    )

    XCTAssertEqual(
      viewport.rangeStart,
      reset.addingTimeInterval(-5 * 60 * 60)
    )
    XCTAssertEqual(viewport.rangeEnd, reset)
    XCTAssertEqual(viewport.axisStyle, .hourlyWindow)
    XCTAssertEqual(viewport.title, "Current Cycle")
    XCTAssertTrue(viewport.includesFuture)
  }

  func testArbitraryCurrentWindowChoosesAxisDensityFromItsDuration() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let reset = now.addingTimeInterval(6 * 60 * 60)
    let viewport = try XCTUnwrap(
      CapacityHistoryViewport.make(
        selection: .currentWindow,
        window: CodexRateLimitWindow(
          slot: .primary,
          usedPercent: 25,
          windowDurationMinutes: 12 * 60,
          resetsAt: reset
        ),
        now: now
      )
    )

    XCTAssertEqual(viewport.axisStyle, .hourlyWindow)
    XCTAssertEqual(viewport.title, "Current Cycle")
  }

  func testCurrentWindowViewportRejectsMissingOrExpiredResetMetadata() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    XCTAssertNil(
      CapacityHistoryViewport.make(
        selection: .currentWindow,
        window: CodexRateLimitWindow(
          slot: .primary,
          usedPercent: 25,
          windowDurationMinutes: 300
        ),
        now: now
      )
    )
    XCTAssertNil(
      CapacityHistoryViewport.make(
        selection: .currentWindow,
        window: CodexRateLimitWindow(
          slot: .primary,
          usedPercent: 25,
          windowDurationMinutes: 300,
          resetsAt: now.addingTimeInterval(-1)
        ),
        now: now
      )
    )
  }

  func testSinceResetTrendPassesThroughCycleStartAndCurrentValue() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let reset = now.addingTimeInterval(3 * 60 * 60)
    let trend = try XCTUnwrap(
      CapacityHistoryTrendLine.makeSinceReset(
        activeContext: currentCycleContext(
          remainingPercent: 60,
          observedAt: now,
          windowDurationMinutes: 300,
          resetsAt: reset
        ),
        now: now
      )
    )

    let cycleStart = reset.addingTimeInterval(-5 * 60 * 60)
    XCTAssertEqual(trend.kind, .sinceReset)
    XCTAssertEqual(trend.startsAt, cycleStart)
    XCTAssertEqual(trend.startRemainingPercent, 100)
    XCTAssertEqual(
      try XCTUnwrap(trend.remainingPercent(at: now)),
      60,
      accuracy: 0.001
    )
    XCTAssertEqual(trend.endsAt, reset)
    XCTAssertEqual(trend.endRemainingPercent, 0, accuracy: 0.001)
  }

  func testSinceResetTrendUsesNowWhenTheActiveContextIsFreshButOlder() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let reset = now.addingTimeInterval(3 * 60 * 60)
    let trend = try XCTUnwrap(
      CapacityHistoryTrendLine.makeSinceReset(
        activeContext: currentCycleContext(
          remainingPercent: 60,
          observedAt: now.addingTimeInterval(-5 * minute),
          windowDurationMinutes: 300,
          resetsAt: reset
        ),
        now: now
      )
    )

    XCTAssertEqual(
      try XCTUnwrap(trend.remainingPercent(at: now)),
      60,
      accuracy: 0.001
    )
  }

  func testSinceResetTrendRequiresFiveElapsedCycleMinutes() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let reset = now.addingTimeInterval((5 * 60 - 4) * minute)

    XCTAssertNil(
      CapacityHistoryTrendLine.makeSinceReset(
        activeContext: currentCycleContext(
          remainingPercent: 99,
          observedAt: now,
          windowDurationMinutes: 300,
          resetsAt: reset
        ),
        now: now
      )
    )
  }

  func testEvenPaceRunsFromOneHundredPercentToZeroAtReset() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let reset = now.addingTimeInterval(3 * 60 * 60)
    let trend = try XCTUnwrap(
      CapacityHistoryTrendLine.makeEvenPace(
        context: currentCycleContext(
          remainingPercent: 60,
          observedAt: now,
          windowDurationMinutes: 300,
          resetsAt: reset
        ),
        now: now
      )
    )

    XCTAssertEqual(trend.kind, .evenPace)
    XCTAssertEqual(trend.startRemainingPercent, 100)
    XCTAssertEqual(trend.endRemainingPercent, 0)
    XCTAssertEqual(trend.endsAt, reset)
  }

  func testTrendProjectionRequiresAFreshActiveContext() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let reset = now.addingTimeInterval(2 * 60 * 60)
    let staleContext = currentCycleContext(
      remainingPercent: 50,
      observedAt: now.addingTimeInterval(
        -CapacityHistoryProjection.gapThreshold - 1
      ),
      windowDurationMinutes: 300,
      resetsAt: reset
    )

    XCTAssertNil(
      CapacityHistoryTrendLine.makeSinceReset(
        activeContext: staleContext,
        now: now
      )
    )
    XCTAssertNil(
      CapacityHistoryTrendLine.makeSinceReset(
        activeContext: nil,
        now: now
      )
    )
  }

  func testFiveSecondResetJitterDoesNotCreateARecordingBoundary() throws {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let reset = start.addingTimeInterval(5 * 60 * 60)
    var policy = CapacityHistoryRecordingPolicy()
    policy.handleConnectionState(.running)

    XCTAssertNotNil(
      policy.observation(
        remainingPercent: 80,
        observedAt: start,
        windowDurationMinutes: 300,
        resetsAt: reset
      )
    )
    XCTAssertNil(
      policy.observation(
        remainingPercent: 80,
        observedAt: start.addingTimeInterval(minute),
        windowDurationMinutes: 300,
        resetsAt: reset.addingTimeInterval(5)
      )
    )
  }

  func testRecordingPolicyStartsANewSessionAfterReconnect() throws {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    var policy = CapacityHistoryRecordingPolicy()

    policy.handleConnectionState(.running)
    let beforeDisconnect = try XCTUnwrap(
      policy.observation(remainingPercent: 70, observedAt: start)
    )
    policy.handleConnectionState(.failed(message: "offline"))
    XCTAssertNil(
      policy.observation(
        remainingPercent: 69,
        observedAt: start.addingTimeInterval(minute)
      )
    )

    policy.handleConnectionState(.running)
    let afterReconnect = try XCTUnwrap(
      policy.observation(
        remainingPercent: 69,
        observedAt: start.addingTimeInterval(2 * minute)
      )
    )

    XCTAssertNotEqual(beforeDisconnect.sessionID, afterReconnect.sessionID)
  }

  func testProjectionBreaksSessionsAndLongGapsWithoutInventingChanges() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let firstSession = UUID()
    let secondSession = UUID()
    let observations = [
      CapacityObservation(
        observedAt: now.addingTimeInterval(-30 * minute),
        remainingPercent: 90,
        sessionID: firstSession
      ),
      CapacityObservation(
        observedAt: now.addingTimeInterval(-25 * minute),
        remainingPercent: 85,
        sessionID: firstSession
      ),
      CapacityObservation(
        observedAt: now.addingTimeInterval(-10 * minute),
        remainingPercent: 80,
        sessionID: firstSession
      ),
      CapacityObservation(
        observedAt: now.addingTimeInterval(-5 * minute),
        remainingPercent: 100,
        sessionID: secondSession
      ),
      CapacityObservation(
        observedAt: now,
        remainingPercent: 97,
        sessionID: secondSession
      ),
    ]

    let projection = CapacityHistoryProjection(
      observations: observations,
      period: .twentyFourHours,
      now: now
    )

    XCTAssertEqual(projection.segments.map(\.observations.count), [2, 1, 2])
    XCTAssertEqual(projection.gaps.count, 2)
    XCTAssertEqual(projection.changes.map(\.delta), [-5, -3])
    XCTAssertEqual(projection.observedDecrease, 8)
    XCTAssertEqual(projection.observedIncrease, 0)
  }

  func testProjectionUsesPreviousObservationAsRangeContext() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let sessionID = UUID()
    let observations = [
      CapacityObservation(
        observedAt: now.addingTimeInterval(-24 * 60 * minute - minute),
        remainingPercent: 60,
        sessionID: sessionID
      ),
      CapacityObservation(
        observedAt: now.addingTimeInterval(-24 * 60 * minute + minute),
        remainingPercent: 55,
        sessionID: sessionID
      ),
    ]

    let projection = CapacityHistoryProjection(
      observations: observations,
      period: .twentyFourHours,
      now: now
    )

    XCTAssertEqual(projection.segments.map(\.observations.count), [2])
    XCTAssertEqual(projection.changes.map(\.delta), [-5])
    XCTAssertEqual(projection.observedDecrease, 5)
  }

  func testProjectionCountsAnIncreaseWithoutCallingItAReset() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let sessionID = UUID()
    let projection = CapacityHistoryProjection(
      observations: [
        CapacityObservation(
          observedAt: now.addingTimeInterval(-10 * minute),
          remainingPercent: 35,
          sessionID: sessionID
        ),
        CapacityObservation(
          observedAt: now.addingTimeInterval(-5 * minute),
          remainingPercent: 62,
          sessionID: sessionID
        ),
      ],
      period: .twentyFourHours,
      now: now
    )

    XCTAssertEqual(projection.changes.map(\.delta), [27])
    XCTAssertEqual(projection.observedDecrease, 0)
    XCTAssertEqual(projection.observedIncrease, 27)
  }

  func testMonitoringStateRequiresARecentObservationFromAConnectedSource() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let recent = now.addingTimeInterval(-5 * minute)
    let stale = now.addingTimeInterval(-12 * minute)

    XCTAssertEqual(
      CapacityHistoryMonitoringState.resolve(
        isConnected: true,
        liveObservedAt: recent,
        latestStoredObservedAt: stale,
        now: now
      ),
      .recording(observedAt: recent)
    )
    XCTAssertEqual(
      CapacityHistoryMonitoringState.resolve(
        isConnected: true,
        liveObservedAt: stale,
        latestStoredObservedAt: stale,
        now: now
      ),
      .notRecording(lastObservedAt: stale)
    )
    XCTAssertEqual(
      CapacityHistoryMonitoringState.resolve(
        isConnected: false,
        liveObservedAt: recent,
        latestStoredObservedAt: stale,
        now: now
      ),
      .notRecording(lastObservedAt: recent)
    )
  }

  func testLiveTailExtendsTheLatestFreshValueWithoutBridgingAGap() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let sessionID = UUID()
    let latest = CapacityObservation(
      observedAt: now.addingTimeInterval(-5 * minute),
      remainingPercent: 82,
      sessionID: sessionID
    )
    let recentLiveObservedAt = now.addingTimeInterval(-minute)
    let recording = CapacityHistoryMonitoringState.recording(
      observedAt: recentLiveObservedAt
    )

    let continuousTail = try XCTUnwrap(
      CapacityHistoryLiveTail(
        latestObservation: latest,
        liveRemainingPercent: 82,
        liveSessionID: sessionID,
        monitoringState: recording,
        now: now
      )
    )
    XCTAssertEqual(continuousTail.startsAt, latest.observedAt)
    XCTAssertEqual(continuousTail.endsAt, now)
    XCTAssertEqual(continuousTail.remainingPercent, 82)

    let oldObservation = CapacityObservation(
      observedAt: now.addingTimeInterval(-30 * minute),
      remainingPercent: 82,
      sessionID: sessionID
    )
    let afterGapTail = try XCTUnwrap(
      CapacityHistoryLiveTail(
        latestObservation: oldObservation,
        liveRemainingPercent: 82,
        liveSessionID: sessionID,
        monitoringState: recording,
        now: now
      )
    )
    XCTAssertEqual(afterGapTail.startsAt, recentLiveObservedAt)
    XCTAssertEqual(afterGapTail.endsAt, now)

    XCTAssertNil(
      CapacityHistoryLiveTail(
        latestObservation: latest,
        liveRemainingPercent: 82,
        liveSessionID: sessionID,
        monitoringState: .notRecording(lastObservedAt: recentLiveObservedAt),
        now: now
      )
    )
  }

  func testLiveTailDoesNotBridgeAReconnectSessionWithTheSameValue() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let latest = CapacityObservation(
      observedAt: now.addingTimeInterval(-5 * minute),
      remainingPercent: 82,
      sessionID: UUID()
    )
    let liveObservedAt = now.addingTimeInterval(-minute)
    let tail = try XCTUnwrap(
      CapacityHistoryLiveTail(
        latestObservation: latest,
        liveRemainingPercent: 82,
        liveSessionID: UUID(),
        monitoringState: .recording(observedAt: liveObservedAt),
        now: now
      )
    )

    XCTAssertEqual(tail.startsAt, liveObservedAt)
  }

  func testInspectionUsesTheValueAtTheCursorWithoutBridgingAGap() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let firstSession = UUID()
    let secondSession = UUID()
    let projection = CapacityHistoryProjection(
      observations: [
        CapacityObservation(
          observedAt: now.addingTimeInterval(-60 * minute),
          remainingPercent: 90,
          sessionID: firstSession
        ),
        CapacityObservation(
          observedAt: now.addingTimeInterval(-50 * minute),
          remainingPercent: 80,
          sessionID: firstSession
        ),
        CapacityObservation(
          observedAt: now.addingTimeInterval(-20 * minute),
          remainingPercent: 70,
          sessionID: secondSession
        ),
        CapacityObservation(
          observedAt: now.addingTimeInterval(-10 * minute),
          remainingPercent: 60,
          sessionID: secondSession
        ),
      ],
      period: .twentyFourHours,
      now: now
    )
    let monitoringState = CapacityHistoryMonitoringState.recording(
      observedAt: now.addingTimeInterval(-minute)
    )
    let liveTail = try XCTUnwrap(
      CapacityHistoryLiveTail(
        latestObservation: projection.latestObservation,
        liveRemainingPercent: 60,
        liveSessionID: secondSession,
        monitoringState: monitoringState,
        now: now
      )
    )

    XCTAssertEqual(
      projection.remainingPercent(
        at: now.addingTimeInterval(-55 * minute),
        liveTail: liveTail
      ),
      90
    )
    XCTAssertEqual(
      projection.remainingPercent(
        at: now.addingTimeInterval(-50 * minute),
        liveTail: liveTail
      ),
      80
    )
    XCTAssertNil(
      projection.remainingPercent(
        at: now.addingTimeInterval(-35 * minute),
        liveTail: liveTail
      )
    )
    XCTAssertEqual(
      projection.remainingPercent(
        at: now.addingTimeInterval(-5 * minute),
        liveTail: liveTail
      ),
      60
    )
  }

  func testHistoryAxisUsesPeriodSpecificClockBoundariesAndNow() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
    calendar.firstWeekday = 2
    let now = try XCTUnwrap(
      calendar.date(
        from: DateComponents(
          year: 2026,
          month: 7,
          day: 30,
          hour: 13,
          minute: 47
        )
      )
    )

    let dayTicks = CapacityHistoryAxisPolicy.tickDates(
      period: .twentyFourHours,
      rangeEnd: now,
      calendar: calendar
    )
    XCTAssertEqual(
      dayTicks.dropLast().map {
        calendar.dateComponents([.hour, .minute], from: $0)
      },
      [
        DateComponents(hour: 18, minute: 0),
        DateComponents(hour: 0, minute: 0),
        DateComponents(hour: 6, minute: 0),
        DateComponents(hour: 12, minute: 0),
      ]
    )
    XCTAssertEqual(dayTicks.last, now)

    let weekTicks = CapacityHistoryAxisPolicy.tickDates(
      period: .sevenDays,
      rangeEnd: now,
      calendar: calendar
    )
    XCTAssertTrue(
      weekTicks.dropLast().allSatisfy {
        calendar.component(.hour, from: $0) == 0
          && calendar.component(.minute, from: $0) == 0
      }
    )
    XCTAssertEqual(weekTicks.last, now)

    let monthTicks = CapacityHistoryAxisPolicy.tickDates(
      period: .thirtyDays,
      rangeEnd: now,
      calendar: calendar
    )
    XCTAssertTrue(
      monthTicks.dropLast().allSatisfy {
        calendar.component(.weekday, from: $0) == calendar.firstWeekday
          && calendar.component(.hour, from: $0) == 0
      }
    )
    XCTAssertEqual(monthTicks.last, now)
  }

  func testHistoryAxisOmitsTheLastNaturalTickWhenItCrowdsReset() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
    let rangeStart = try XCTUnwrap(
      calendar.date(
        from: DateComponents(
          year: 2026,
          month: 8,
          day: 2,
          hour: 8,
          minute: 40
        )
      )
    )
    let rangeEnd = try XCTUnwrap(
      calendar.date(
        from: DateComponents(
          year: 2026,
          month: 8,
          day: 2,
          hour: 13,
          minute: 40
        )
      )
    )

    let compactTicks = CapacityHistoryAxisPolicy.displayTickDates(
      style: .hourlyWindow,
      rangeStart: rangeStart,
      rangeEnd: rangeEnd,
      plotWidth: 518,
      calendar: calendar
    )
    XCTAssertEqual(
      compactTicks.dropLast().map {
        calendar.component(.hour, from: $0)
      },
      [9, 10, 11, 12]
    )
    XCTAssertEqual(compactTicks.last, rangeEnd)

    let roomyTicks = CapacityHistoryAxisPolicy.displayTickDates(
      style: .hourlyWindow,
      rangeStart: rangeStart,
      rangeEnd: rangeEnd,
      plotWidth: 680,
      calendar: calendar
    )
    XCTAssertEqual(
      roomyTicks.dropLast().map {
        calendar.component(.hour, from: $0)
      },
      [9, 10, 11, 12, 13]
    )
    XCTAssertEqual(roomyTicks.last, rangeEnd)
  }

  func testHistoryAxisKeepsNaturalGridlineWhenItsLabelWouldCrowdReset() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
    let rangeStart = try XCTUnwrap(
      calendar.date(
        from: DateComponents(
          year: 2026,
          month: 8,
          day: 1,
          hour: 12,
          minute: 57
        )
      )
    )
    let rangeEnd = try XCTUnwrap(
      calendar.date(
        from: DateComponents(
          year: 2026,
          month: 8,
          day: 8,
          hour: 12,
          minute: 57
        )
      )
    )

    let gridlineDates = CapacityHistoryAxisPolicy.tickDates(
      style: .sevenDays,
      rangeStart: rangeStart,
      rangeEnd: rangeEnd,
      calendar: calendar
    )
    let labelDates = CapacityHistoryAxisPolicy.displayTickDates(
      style: .sevenDays,
      rangeStart: rangeStart,
      rangeEnd: rangeEnd,
      plotWidth: 680,
      calendar: calendar
    )

    XCTAssertEqual(
      calendar.dateComponents([.month, .day, .hour], from: gridlineDates.dropLast().last!),
      DateComponents(month: 8, day: 8, hour: 0)
    )
    XCTAssertEqual(
      calendar.dateComponents([.month, .day, .hour], from: labelDates.dropLast().last!),
      DateComponents(month: 8, day: 7, hour: 0)
    )
    XCTAssertEqual(gridlineDates.last, rangeEnd)
    XCTAssertEqual(labelDates.last, rangeEnd)
  }

  func testHistoryFreshnessCopyExplainsWhetherTheValueIsCurrent() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    XCTAssertEqual(
      CapacityHistoryFreshnessCopy.label(
        observedAt: now.addingTimeInterval(-30),
        now: now
      ),
      "Updated just now"
    )
    XCTAssertEqual(
      CapacityHistoryFreshnessCopy.label(
        observedAt: now.addingTimeInterval(-125),
        now: now
      ),
      "Updated 2 min ago"
    )
    XCTAssertEqual(
      CapacityHistoryFreshnessCopy.label(
        observedAt: now.addingTimeInterval(-(3 * 60 * 60 + 10)),
        now: now
      ),
      "Updated 3 hr ago"
    )
  }

  func testHistoryMonitoringDistinguishesARecordingPreferenceFromConnectionLoss() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let storedAt = now.addingTimeInterval(-10 * minute)

    XCTAssertEqual(
      CapacityHistoryMonitoringState.resolve(
        isRecordingEnabled: false,
        isConnected: true,
        liveObservedAt: now,
        latestStoredObservedAt: storedAt,
        now: now
      ),
      .disabled(lastRecordedAt: storedAt)
    )
    XCTAssertEqual(
      CapacityHistoryMonitoringState.resolve(
        isRecordingEnabled: true,
        isConnected: false,
        liveObservedAt: nil,
        latestStoredObservedAt: storedAt,
        now: now
      ),
      .notRecording(lastObservedAt: storedAt)
    )
  }

  func testHistoryRecordingOffCopyKeepsViewingSeparateFromPersistence() {
    XCTAssertEqual(CapacityHistoryRecordingCopy.offStatus, "Recording Off")
    XCTAssertEqual(CapacityHistoryRecordingCopy.offSystemImage, "circle.slash")
    XCTAssertEqual(
      CapacityHistoryRecordingCopy.offEmptyTitle,
      "Capacity history recording is off"
    )
    XCTAssertEqual(
      CapacityHistoryRecordingCopy.offEmptyDescription,
      "Turn on Record Capacity History in Capacity settings to save new observations locally."
    )
  }

  func testHistoryClearCopyDescribesLocalHistoryRemoval() {
    XCTAssertEqual(CapacityHistoryClearCopy.title, "Clear Capacity History?")
    XCTAssertEqual(CapacityHistoryClearCopy.actionTitle, "Clear History")
    XCTAssertEqual(
      CapacityHistoryClearCopy.message,
      "This permanently removes every locally recorded Capacity observation. Capacity display, history recording, and current monitoring continue unchanged."
    )
  }

  @MainActor
  func testHistoryViewModelOwnsClearAvailabilityAndTheSharedClearPath()
    async throws
  {
    let capacityURL = temporaryHistoryURL()
    defer {
      try? FileManager.default.removeItem(
        at: capacityURL.deletingLastPathComponent()
      )
    }
    let capacityStore = CapacityHistoryStore(fileURL: capacityURL)
    let viewModel = CapacityHistoryViewModel(store: capacityStore)

    await viewModel.refresh()
    XCTAssertFalse(viewModel.hasStoredHistory)
    XCTAssertFalse(viewModel.canClearHistory)

    try await capacityStore.append(
      CapacityObservation(
        observedAt: Date(timeIntervalSince1970: 1_800_000_000),
        remainingPercent: 52,
        sessionID: UUID()
      )
    )
    await viewModel.refresh()
    XCTAssertTrue(viewModel.hasStoredHistory)
    XCTAssertTrue(viewModel.canClearHistory)

    var clearCallCount = 0
    try await viewModel.clear {
      clearCallCount += 1
      try await capacityStore.clear()
    }

    XCTAssertEqual(clearCallCount, 1)
    XCTAssertFalse(viewModel.hasStoredHistory)
    XCTAssertFalse(viewModel.canClearHistory)
  }

  func testObservedCapacityLineWidthUsesThePrimaryChartMetric() {
    XCTAssertEqual(CapacityHistoryChartMetrics.lineWidth, 2.5)
  }

  func testHistorySelectionMovesAcrossCapacityTimes() {
    let first = Date(timeIntervalSince1970: 1_800_000_000)
    let second = first.addingTimeInterval(5 * minute)
    let third = second.addingTimeInterval(5 * minute)

    XCTAssertEqual(
      CapacityHistorySelectionPolicy.movedDate(
        from: nil,
        direction: 1,
        availableDates: [third, first, second, second]
      ),
      first
    )
    XCTAssertEqual(
      CapacityHistorySelectionPolicy.movedDate(
        from: second,
        direction: 1,
        availableDates: [third, first, second]
      ),
      third
    )
    XCTAssertEqual(
      CapacityHistorySelectionPolicy.movedDate(
        from: second,
        direction: -1,
        availableDates: [third, first, second]
      ),
      first
    )
  }

  func testHistoryInspectionCopyChangesWithVoiceOverAdjustment() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let first = now.addingTimeInterval(-10 * minute)
    let second = now.addingTimeInterval(-5 * minute)
    let sessionID = UUID()
    let capacityProjection = CapacityHistoryProjection(
      observations: [
        CapacityObservation(
          observedAt: first,
          remainingPercent: 80,
          sessionID: sessionID
        ),
        CapacityObservation(
          observedAt: second,
          remainingPercent: 70,
          sessionID: sessionID
        ),
      ],
      period: .twentyFourHours,
      now: now
    )
    let adjustedDate = try XCTUnwrap(
      CapacityHistorySelectionPolicy.movedDate(
        from: first,
        direction: 1,
        availableDates: [first, second]
      )
    )

    let firstValue = CapacityHistoryInspectionCopy.description(
      at: first,
      projection: capacityProjection,
      liveTail: nil
    )
    let adjustedValue = CapacityHistoryInspectionCopy.description(
      at: adjustedDate,
      projection: capacityProjection,
      liveTail: nil
    )

    XCTAssertNotEqual(firstValue, adjustedValue)
    XCTAssertTrue(firstValue.contains("80% remaining"))
    XCTAssertTrue(adjustedValue.contains("70% remaining"))
  }

  func testHistoryInspectionAndChartDescriptorKeepEnglishDateCopy() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.locale = Locale(identifier: "ja_JP")
    calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
    let observedAt = try XCTUnwrap(
      calendar.date(
        from: DateComponents(
          year: 2026,
          month: 8,
          day: 3,
          hour: 13
        )
      )
    )
    let projection = CapacityHistoryProjection(
      observations: [
        CapacityObservation(
          observedAt: observedAt,
          remainingPercent: 70,
          sessionID: UUID()
        )
      ],
      period: .twentyFourHours,
      now: observedAt.addingTimeInterval(60)
    )

    let inspection = CapacityHistoryInspectionCopy.description(
      at: observedAt,
      projection: projection,
      liveTail: nil,
      calendar: calendar
    )
    let descriptor = CapacityHistoryChartAccessibilityDescriptor(
      projection: projection,
      liveTail: nil,
      calendar: calendar
    ).makeChartDescriptor()

    XCTAssertTrue(inspection.contains("Aug 3, 2026 at 13:00"))
    XCTAssertTrue(
      try XCTUnwrap(descriptor.series.first?.dataPoints.first?.label)
        .contains("Aug 3, 2026 at 13:00")
    )
  }

  func testHistoryInspectionListsEveryVisibleTrendWithoutCallingItObserved()
    throws
  {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let future = now.addingTimeInterval(30 * minute)
    let end = now.addingTimeInterval(60 * minute)
    let capacityProjection = CapacityHistoryProjection(
      observations: [],
      period: .twentyFourHours,
      viewport: CapacityHistoryViewport(
        rangeStart: now.addingTimeInterval(-60 * minute),
        rangeEnd: end,
        axisStyle: .hourlyWindow,
        title: "Current Cycle",
        includesFuture: true
      ),
      observedThrough: now
    )
    let trendLines = [
      CapacityHistoryTrendLine(
        kind: .sinceReset,
        startsAt: now,
        endsAt: end,
        startRemainingPercent: 80,
        endRemainingPercent: 40,
        predictedDepletionAt: nil
      ),
      CapacityHistoryTrendLine(
        kind: .evenPace,
        startsAt: now,
        endsAt: end,
        startRemainingPercent: 60,
        endRemainingPercent: 0,
        predictedDepletionAt: nil
      ),
    ]

    let copy = CapacityHistoryInspectionCopy.description(
      at: future,
      projection: capacityProjection,
      liveTail: nil,
      trendLines: trendLines
    )

    XCTAssertTrue(copy.contains("Capacity not observed"))
    XCTAssertTrue(copy.contains("Since Reset 60%"))
    XCTAssertTrue(copy.contains("Even Pace 30%"))
    XCTAssertFalse(copy.contains("Estimated"))
  }

  func testHistoryChartDescriptorIncludesExactCapacityObservations() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let sessionID = UUID()
    let capacityProjection = CapacityHistoryProjection(
      observations: [
        CapacityObservation(
          observedAt: now.addingTimeInterval(-5 * minute),
          remainingPercent: 75,
          sessionID: sessionID
        )
      ],
      period: .twentyFourHours,
      now: now
    )
    let descriptor = CapacityHistoryChartAccessibilityDescriptor(
      projection: capacityProjection,
      liveTail: nil
    ).makeChartDescriptor()

    XCTAssertEqual(descriptor.title, "Codex Capacity over time")
    XCTAssertEqual(
      descriptor.series.compactMap(\.name),
      ["Capacity remaining"]
    )
    XCTAssertEqual(descriptor.series.first?.dataPoints.count, 1)
  }

  func testCurrentCycleDataPolicyExcludesRowsOutsideTheActiveCycle() {
    let cycleStart = Date(timeIntervalSince1970: 1_800_000_000)
    let now = cycleStart.addingTimeInterval(4.5 * 60)
    let reset = cycleStart.addingTimeInterval(7 * 24 * 60 * 60)
    let sessionID = UUID()
    let current = CapacityObservation(
      observedAt: now,
      remainingPercent: 58,
      sessionID: sessionID,
      resetsAt: reset
    )
    let observations = [
      CapacityObservation(
        observedAt: cycleStart.addingTimeInterval(-30),
        remainingPercent: 60,
        sessionID: sessionID,
        resetsAt: reset
      ),
      CapacityObservation(
        observedAt: now.addingTimeInterval(-120),
        remainingPercent: 12,
        sessionID: sessionID,
        resetsAt: reset.addingTimeInterval(-7 * 24 * 60 * 60)
      ),
      CapacityObservation(
        observedAt: now.addingTimeInterval(-60),
        remainingPercent: 20,
        sessionID: sessionID,
        resetsAt: nil
      ),
      current,
    ]
    let context = CapacityHistoryCurrentCycleContext(
      windowDurationMinutes: 7 * 24 * 60,
      resetsAt: reset,
      endpoint: CapacityHistoryCurrentCycleEndpoint(
        observedAt: now,
        remainingPercent: 58
      )
    )

    let matching = CapacityHistoryCurrentCycleDataPolicy.observations(
      observations,
      matching: context
    )
    XCTAssertEqual(matching, [current])

    let projection = CapacityHistoryProjection(
      observations: matching,
      period: context.viewport.axisStyle.projectionPeriod,
      viewport: context.viewport,
      observedThrough: now
    )
    XCTAssertNil(projection.remainingPercent(at: cycleStart, liveTail: nil))
    XCTAssertTrue(projection.changes.isEmpty)
    XCTAssertEqual(projection.observedDecrease, 0)
    XCTAssertEqual(projection.observedIncrease, 0)
  }

  func testRetainedEndpointRequiresNewerProvenanceThanStoredHistory() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let reset = now.addingTimeInterval(4 * 24 * 60 * 60)
    let context = CapacityHistoryCurrentCycleContext(
      windowDurationMinutes: 7 * 24 * 60,
      resetsAt: reset,
      endpoint: CapacityHistoryCurrentCycleEndpoint(
        observedAt: now,
        remainingPercent: 58
      )
    )
    let presentation = CapacityHistoryCurrentCyclePresentation.retained(context)

    XCTAssertEqual(
      CapacityHistoryCurrentCycleDataPolicy.retainedEndpoint(
        presentation: presentation,
        matchingObservations: []
      ),
      context.endpoint
    )
    for observedAt in [now, now.addingTimeInterval(1)] {
      XCTAssertNil(
        CapacityHistoryCurrentCycleDataPolicy.retainedEndpoint(
          presentation: presentation,
          matchingObservations: [
            CapacityObservation(
              observedAt: observedAt,
              remainingPercent: 58,
              sessionID: UUID(),
              resetsAt: reset
            ),
          ]
        )
      )
    }
    XCTAssertNil(
      CapacityHistoryCurrentCycleDataPolicy.retainedEndpoint(
        presentation: presentation,
        matchingObservations: [
          CapacityObservation(
            observedAt: now.addingTimeInterval(1),
            remainingPercent: 57,
            sessionID: UUID(),
            resetsAt: reset
          ),
          CapacityObservation(
            observedAt: now.addingTimeInterval(-1),
            remainingPercent: 59,
            sessionID: UUID(),
            resetsAt: reset
          ),
        ]
      )
    )
  }

  func testActiveEndpointFillsOnlyTheVisualSummaryWithoutALiveTail()
    throws
  {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let reset = now.addingTimeInterval(4 * 24 * 60 * 60)
    let context = CapacityHistoryCurrentCycleContext(
      windowDurationMinutes: 7 * 24 * 60,
      resetsAt: reset,
      endpoint: CapacityHistoryCurrentCycleEndpoint(
        observedAt: now,
        remainingPercent: 58
      )
    )
    let presentation = CapacityHistoryCurrentCyclePresentation.active(context)

    let summaryEndpoint = try XCTUnwrap(
      CapacityHistoryCurrentCycleDataPolicy.activeSummaryEndpoint(
        presentation: presentation,
        hasLiveTail: false,
        matchingObservations: []
      )
    )
    XCTAssertEqual(summaryEndpoint, context.endpoint)
    XCTAssertNil(
      CapacityHistoryCurrentCycleDataPolicy.activeSummaryEndpoint(
        presentation: presentation,
        hasLiveTail: true,
        matchingObservations: []
      )
    )
    XCTAssertNil(
      CapacityHistoryCurrentCycleDataPolicy.retainedEndpoint(
        presentation: presentation,
        matchingObservations: []
      )
    )

    let viewport = context.viewport
    let series = try XCTUnwrap(
      CapacityHistoryCurrentCycleRenderPolicy.series(
        [],
        rangeStart: viewport.rangeStart,
        rangeEnd: viewport.rangeEnd,
        activeResetsAt: context.resetsAt,
        summaryEndpoint: summaryEndpoint,
        plotWidth: 600
      )
    )
    XCTAssertEqual(series.samples.last?.observedAt, context.endpoint.observedAt)
    XCTAssertEqual(
      series.samples.last?.remainingPercent,
      Double(context.endpoint.remainingPercent)
    )

    let projection = CapacityHistoryProjection(
      observations: [],
      period: viewport.axisStyle.projectionPeriod,
      viewport: viewport,
      observedThrough: now
    )
    let descriptor = CapacityHistoryChartAccessibilityDescriptor(
      projection: projection,
      liveTail: nil
    ).makeChartDescriptor()
    XCTAssertFalse(
      descriptor.series.contains { $0.name == "Last received Capacity" }
    )
  }

  func testLastReceivedEndpointHasSeparateInspectionAndAXProvenance() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let reset = now.addingTimeInterval(4 * 24 * 60 * 60)
    let endpoint = CapacityHistoryCurrentCycleEndpoint(
      observedAt: now,
      remainingPercent: 58
    )
    let projection = CapacityHistoryProjection(
      observations: [],
      period: .sevenDays,
      viewport: CapacityHistoryViewport(
        rangeStart: reset.addingTimeInterval(-7 * 24 * 60 * 60),
        rangeEnd: reset,
        axisStyle: .sevenDays,
        title: "Current Cycle",
        includesFuture: true
      ),
      observedThrough: now
    )

    let endpointCopy = CapacityHistoryInspectionCopy.description(
      at: now,
      projection: projection,
      liveTail: nil,
      lastReceivedEndpoint: endpoint
    )
    let laterCopy = CapacityHistoryInspectionCopy.description(
      at: now.addingTimeInterval(60),
      projection: projection,
      liveTail: nil,
      lastReceivedEndpoint: endpoint
    )
    XCTAssertTrue(endpointCopy.contains("Last received Capacity 58%"))
    XCTAssertFalse(endpointCopy.contains("Capacity not observed"))
    XCTAssertTrue(laterCopy.contains("Capacity not observed"))

    let descriptor = CapacityHistoryChartAccessibilityDescriptor(
      projection: projection,
      liveTail: nil,
      lastReceivedEndpoint: endpoint
    ).makeChartDescriptor()
    let endpointSeries = try XCTUnwrap(
      descriptor.series.first { $0.name == "Last received Capacity" }
    )
    XCTAssertFalse(endpointSeries.isContinuous)
    XCTAssertEqual(endpointSeries.dataPoints.count, 1)
    XCTAssertFalse(
      descriptor.series.contains { $0.name == "Capacity remaining" }
    )
    XCTAssertFalse(
      descriptor.series.contains { $0.name == "Current Capacity" }
    )
  }

  func testHistoryChartDescriptorKeepsObservationSegmentsSeparate() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let firstSession = UUID()
    let secondSession = UUID()
    let observations = [
      CapacityObservation(
        observedAt: now.addingTimeInterval(-30 * minute),
        remainingPercent: 80,
        sessionID: firstSession
      ),
      CapacityObservation(
        observedAt: now.addingTimeInterval(-29 * minute),
        remainingPercent: 79,
        sessionID: firstSession
      ),
      CapacityObservation(
        observedAt: now.addingTimeInterval(-5 * minute),
        remainingPercent: 70,
        sessionID: secondSession
      ),
      CapacityObservation(
        observedAt: now.addingTimeInterval(-4 * minute),
        remainingPercent: 69,
        sessionID: secondSession
      ),
    ]
    let projection = CapacityHistoryProjection(
      observations: observations,
      period: .twentyFourHours,
      now: now
    )

    let descriptor = CapacityHistoryChartAccessibilityDescriptor(
      projection: projection,
      liveTail: nil
    ).makeChartDescriptor()
    let capacitySeries = descriptor.series.filter {
      $0.name?.hasPrefix("Capacity remaining") == true
    }

    XCTAssertEqual(capacitySeries.count, 2)
    XCTAssertEqual(capacitySeries.map(\.dataPoints.count), [2, 2])
    let labels = capacitySeries.flatMap(\.dataPoints).compactMap(\.label)
    XCTAssertEqual(labels.count, 4)
    for (label, remainingPercent) in zip(labels, [80, 79, 70, 69]) {
      XCTAssertTrue(label.contains("\(remainingPercent) percent remaining"))
    }
  }

  func testHistoryChartDescriptorKeepsAContinuousLiveTailInItsSegment()
    throws
  {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let sessionID = UUID()
    let observations = [
      CapacityObservation(
        observedAt: now.addingTimeInterval(-5 * minute),
        remainingPercent: 70,
        sessionID: sessionID
      ),
      CapacityObservation(
        observedAt: now.addingTimeInterval(-4 * minute),
        remainingPercent: 69,
        sessionID: sessionID
      ),
    ]
    let projection = CapacityHistoryProjection(
      observations: observations,
      period: .twentyFourHours,
      now: now
    )
    let liveTail = try XCTUnwrap(
      CapacityHistoryLiveTail(
        latestObservation: observations.last,
        liveRemainingPercent: 69,
        liveSessionID: sessionID,
        monitoringState: .recording(
          observedAt: now.addingTimeInterval(-3 * minute)
        ),
        now: now
      )
    )

    let descriptor = CapacityHistoryChartAccessibilityDescriptor(
      projection: projection,
      liveTail: liveTail
    ).makeChartDescriptor()
    let capacitySeries = descriptor.series.filter {
      $0.name?.hasPrefix("Capacity remaining") == true
    }

    XCTAssertEqual(capacitySeries.count, 1)
    XCTAssertEqual(capacitySeries.first?.dataPoints.count, 3)
    XCTAssertFalse(
      descriptor.series.contains { $0.name == "Current Capacity" }
    )
  }

  func testHistoryChartDescriptorNamesEveryVisibleTrendSeries() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let sessionID = UUID()
    let projection = CapacityHistoryProjection(
      observations: [
        CapacityObservation(
          observedAt: now,
          remainingPercent: 80,
          sessionID: sessionID
        )
      ],
      period: .twentyFourHours,
      now: now
    )
    let descriptor = CapacityHistoryChartAccessibilityDescriptor(
      projection: projection,
      liveTail: nil,
      trendLines: [
        CapacityHistoryTrendLine(
          kind: .sinceReset,
          startsAt: now.addingTimeInterval(-60 * minute),
          endsAt: now,
          startRemainingPercent: 100,
          endRemainingPercent: 80,
          predictedDepletionAt: nil
        ),
        CapacityHistoryTrendLine(
          kind: .evenPace,
          startsAt: now.addingTimeInterval(-60 * minute),
          endsAt: now,
          startRemainingPercent: 100,
          endRemainingPercent: 0,
          predictedDepletionAt: nil
        ),
      ]
    ).makeChartDescriptor()

    XCTAssertEqual(
      descriptor.series.compactMap(\.name),
      ["Capacity remaining", "Since Reset", "Even Pace"]
    )
  }

  func testLoadGenerationRejectsAnOlderCompletion() {
    var generation = CapacityHistoryLoadGeneration()
    let first = generation.begin()
    let second = generation.begin()

    XCTAssertFalse(generation.isCurrent(first))
    XCTAssertTrue(generation.isCurrent(second))
  }

  func testHistoryWindowLabelsUseKnownAndGenericDurations() {
    XCTAssertEqual(
      [
        CapacityHistoryLimit.shortWindow.title,
        CapacityHistoryLimit(
          windowDurationMinutes: 12 * 60
        ).title,
        CapacityHistoryLimit.weeklyWindow.title,
      ],
      ["5-Hour", "12-Hour", "7-Day"]
    )
    XCTAssertEqual(CapacityHistoryLimit.shortWindow.pickerTitle, "5-Hour Limit")
    XCTAssertEqual(CapacityHistoryLimit.weeklyWindow.pickerTitle, "7-Day Limit")
    XCTAssertEqual(
      CapacityHistoryLimit(windowDurationMinutes: 1_043).pickerTitle,
      "17-Hour 23-Minute Limit"
    )
    XCTAssertEqual(
      CapacityHistoryLimit(windowDurationMinutes: 2_345).pickerTitle,
      "1-Day 15-Hour 5-Minute Limit"
    )
    XCTAssertEqual(
      CapacityHistoryRangeSelection.currentWindow.title,
      "Current Cycle"
    )
  }

  @MainActor
  func testAvailableHistoryWindowsAreDynamicAndSortedShortestFirst()
    async throws
  {
    let fileURL = temporaryHistoryURL()
    defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
    let store = CapacityHistoryStore(fileURL: fileURL)
    try await store.append(
      CapacityObservation(
        observedAt: Date(timeIntervalSince1970: 1_800_000_000),
        remainingPercent: 60,
        sessionID: UUID(),
        windowDurationMinutes: 12 * 60
      )
    )
    let viewModel = CapacityHistoryViewModel(store: store)
    await viewModel.refresh()
    let snapshot = CodexUsageSnapshot(
      primaryWindow: CodexRateLimitWindow(
        slot: .primary,
        usedPercent: 40,
        windowDurationMinutes: 10_080
      ),
      secondaryWindow: CodexRateLimitWindow(
        slot: .secondary,
        usedPercent: 20,
        windowDurationMinutes: 300
      )
    )

    let limits = viewModel.availableLimits(snapshot: snapshot)
    XCTAssertEqual(limits.map(\.windowDurationMinutes), [300, 720, 10_080])
    XCTAssertEqual(limits.map(\.title), ["5-Hour", "12-Hour", "7-Day"])
  }

  @MainActor
  func testAvailableHistoryWindowsUseEveryServerProvidedDuration() {
    let fileURL = temporaryHistoryURL()
    defer {
      try? FileManager.default.removeItem(
        at: fileURL.deletingLastPathComponent()
      )
    }
    let viewModel = CapacityHistoryViewModel(
      store: CapacityHistoryStore(fileURL: fileURL)
    )
    let snapshot = CodexUsageSnapshot(
      windows: [
        CodexRateLimitWindow(
          slot: .primary,
          usedPercent: 10,
          windowDurationMinutes: 37
        ),
        CodexRateLimitWindow(
          slot: .secondary,
          usedPercent: 20,
          windowDurationMinutes: 720
        ),
        CodexRateLimitWindow(
          slot: CodexRateLimitWindowSlot(rawValue: "burst"),
          usedPercent: 30,
          windowDurationMinutes: 2_345
        ),
      ]
    )

    let limits = viewModel.availableLimits(snapshot: snapshot)

    XCTAssertEqual(limits.map(\.windowDurationMinutes), [37, 720, 2_345])
    XCTAssertEqual(
      limits.map(\.pickerTitle),
      [
        "37-Minute Limit",
        "12-Hour Limit",
        "1-Day 15-Hour 5-Minute Limit",
      ]
    )
  }

  @MainActor
  func testExplicitHistoryWindowSelectionPersistsAndRestores() throws {
    let suiteName = "CapacityWindowSelectionTests-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let fileURL = temporaryHistoryURL()
    defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
    let snapshot = CodexUsageSnapshot(
      primaryWindow: CodexRateLimitWindow(
        slot: .primary,
        usedPercent: 20,
        windowDurationMinutes: 300
      ),
      secondaryWindow: CodexRateLimitWindow(
        slot: .secondary,
        usedPercent: 60,
        windowDurationMinutes: 10_080
      )
    )
    let store = CapacityHistoryStore(fileURL: fileURL)
    let first = CapacityHistoryViewModel(
      store: store,
      userDefaults: defaults
    )
    first.reconcileLimitSelection(snapshot: snapshot)
    XCTAssertEqual(first.selectedLimit, .weeklyWindow)

    first.selectLimit(.shortWindow, snapshot: snapshot)
    XCTAssertEqual(
      defaults.integer(
        forKey: CapacityHistoryViewModel.selectedLimitDurationDefaultsKey
      ),
      300
    )

    let restored = CapacityHistoryViewModel(
      store: store,
      userDefaults: defaults
    )
    restored.reconcileLimitSelection(snapshot: snapshot)
    XCTAssertEqual(restored.selectedLimit, .shortWindow)
  }

  func testTrendKindsContainOnlyCurrentCycleFeatures() {
    XCTAssertEqual(
      CapacityHistoryTrendKind.allCases,
      [.sinceReset, .evenPace]
    )
  }

  @MainActor
  func testAutomaticHistoryWindowFallbackDoesNotPersist() throws {
    let suiteName = "AutomaticCapacityWindowTests-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let fileURL = temporaryHistoryURL()
    defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
    let viewModel = CapacityHistoryViewModel(
      store: CapacityHistoryStore(fileURL: fileURL),
      userDefaults: defaults
    )
    let snapshot = CodexUsageSnapshot(
      primaryWindow: CodexRateLimitWindow(
        slot: .primary,
        usedPercent: 20,
        windowDurationMinutes: 300
      ),
      secondaryWindow: CodexRateLimitWindow(
        slot: .secondary,
        usedPercent: 60,
        windowDurationMinutes: 10_080
      )
    )

    viewModel.reconcileLimitSelection(snapshot: snapshot)

    XCTAssertEqual(viewModel.selectedLimit, .weeklyWindow)
    XCTAssertNil(
      defaults.object(
        forKey: CapacityHistoryViewModel.selectedLimitDurationDefaultsKey
      )
    )
  }

  @MainActor
  func testCurrentCycleIntentSurvivesWhenLiveSnapshotDisappears() async throws {
    let fileURL = temporaryHistoryURL()
    defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
    let store = CapacityHistoryStore(fileURL: fileURL)
    try await store.append(
      CapacityObservation(
        observedAt: .now.addingTimeInterval(-60),
        remainingPercent: 58,
        sessionID: UUID(),
        windowDurationMinutes: 7 * 24 * 60
      )
    )
    let viewModel = CapacityHistoryViewModel(store: store)
    await viewModel.refresh()
    let snapshot = CodexUsageSnapshot(
      usedPercent: 42,
      windowDurationMinutes: 7 * 24 * 60,
      resetsAt: .now.addingTimeInterval(24 * 60 * 60)
    )

    viewModel.reconcileLimitSelection(snapshot: snapshot)
    XCTAssertEqual(viewModel.selectedRange, .currentWindow)

    viewModel.reconcileLimitSelection(snapshot: nil)

    XCTAssertEqual(viewModel.selectedRange, .currentWindow)
  }

  @MainActor
  func testCurrentCycleKeepsIntentWhileWaitingForTheInitialLiveSnapshot() {
    let fileURL = temporaryHistoryURL()
    defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
    let viewModel = CapacityHistoryViewModel(
      store: CapacityHistoryStore(fileURL: fileURL)
    )

    viewModel.reconcileLimitSelection(snapshot: nil)

    XCTAssertEqual(viewModel.selectedRange, .currentWindow)
  }

  @MainActor
  func testCurrentCycleIntentSurvivesWhenInitialUsageReadIsUnavailable() {
    let fileURL = temporaryHistoryURL()
    defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
    let viewModel = CapacityHistoryViewModel(
      store: CapacityHistoryStore(fileURL: fileURL)
    )

    viewModel.reconcileLimitSelection(snapshot: nil)

    XCTAssertEqual(viewModel.selectedRange, .currentWindow)
  }

  @MainActor
  func testSelectingAHistoryOnlyLimitPreservesCurrentCycleIntent() async throws {
    let fileURL = temporaryHistoryURL()
    defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
    let store = CapacityHistoryStore(fileURL: fileURL)
    try await store.append(
      CapacityObservation(
        observedAt: .now.addingTimeInterval(-60),
        remainingPercent: 72,
        sessionID: UUID(),
        windowDurationMinutes: 300
      )
    )
    let viewModel = CapacityHistoryViewModel(store: store)
    await viewModel.refresh()
    let snapshot = CodexUsageSnapshot(
      usedPercent: 42,
      windowDurationMinutes: 7 * 24 * 60,
      resetsAt: .now.addingTimeInterval(24 * 60 * 60)
    )
    viewModel.reconcileLimitSelection(snapshot: snapshot)
    XCTAssertEqual(viewModel.selectedRange, .currentWindow)

    viewModel.selectLimit(.shortWindow, snapshot: snapshot)

    XCTAssertEqual(viewModel.selectedLimit, .shortWindow)
    XCTAssertEqual(viewModel.selectedRange, .currentWindow)
  }

  @MainActor
  func testLoadedHistoryReconcilesAStoredHistoryOnlyLimitWithTheLiveWindow()
    async throws
  {
    let suiteName = "LoadedCapacityWindowTests-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(
      300,
      forKey: CapacityHistoryViewModel.selectedLimitDurationDefaultsKey
    )
    let fileURL = temporaryHistoryURL()
    defer {
      try? FileManager.default.removeItem(
        at: fileURL.deletingLastPathComponent()
      )
    }
    let store = CapacityHistoryStore(fileURL: fileURL)
    try await store.append(
      CapacityObservation(
        observedAt: .now.addingTimeInterval(-4 * 24 * 60 * 60),
        remainingPercent: 78,
        sessionID: UUID(),
        windowDurationMinutes: 300,
        resetsAt: .now.addingTimeInterval(-4 * 24 * 60 * 60 + 2 * 60 * 60)
      )
    )
    let viewModel = CapacityHistoryViewModel(
      store: store,
      userDefaults: defaults
    )
    let liveSnapshot = CodexUsageSnapshot(
      usedPercent: 3,
      windowDurationMinutes: 10_080,
      resetsAt: .now.addingTimeInterval(7 * 24 * 60 * 60)
    )

    await viewModel.refreshAndReconcile {
      (snapshot: liveSnapshot, retainedLimits: [])
    }

    XCTAssertEqual(viewModel.selectedLimit, .shortWindow)
    XCTAssertEqual(viewModel.selectedRange, .currentWindow)
    XCTAssertEqual(
      defaults.integer(
        forKey: CapacityHistoryViewModel.selectedLimitDurationDefaultsKey
      ),
      300
    )
  }

  @MainActor
  func testHistoryRefreshClearsAStaleLimitUsingTheLatestLiveState()
    async throws
  {
    let suiteName = "StaleCapacityWindowTests-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let key = CapacityHistoryViewModel.selectedLimitDurationDefaultsKey
    defaults.set(300, forKey: key)
    let fileURL = temporaryHistoryURL()
    defer {
      try? FileManager.default.removeItem(
        at: fileURL.deletingLastPathComponent()
      )
    }
    let store = CapacityHistoryStore(fileURL: fileURL)
    try await store.append(
      CapacityObservation(
        observedAt: .now.addingTimeInterval(-60),
        remainingPercent: 97,
        sessionID: UUID(),
        windowDurationMinutes: 10_080,
        resetsAt: .now.addingTimeInterval(7 * 24 * 60 * 60)
      )
    )
    let viewModel = CapacityHistoryViewModel(
      store: store,
      userDefaults: defaults
    )
    let liveSnapshot = CodexUsageSnapshot(
      usedPercent: 3,
      windowDurationMinutes: 10_080,
      resetsAt: .now.addingTimeInterval(7 * 24 * 60 * 60)
    )
    var historyCountWhenLiveStateWasRead = 0

    await viewModel.refreshAndReconcile {
      historyCountWhenLiveStateWasRead = viewModel.observations.count
      return (snapshot: liveSnapshot, retainedLimits: [])
    }

    XCTAssertEqual(historyCountWhenLiveStateWasRead, 1)
    XCTAssertEqual(viewModel.selectedLimit, .weeklyWindow)
    XCTAssertEqual(viewModel.selectedRange, .currentWindow)
    XCTAssertNil(defaults.object(forKey: key))
  }

  func testSyntheticCapacityFixturesNeverUseTheDefaultHistoryFile() {
    let defaultURL = URL(fileURLWithPath: "/history/default/v1.jsonl")
    let temporaryDirectory = URL(fileURLWithPath: "/tmp/codex-echo-tests")

    let usageFixtureURL = CapacityHistoryDebugStorePolicy.fileURL(
      environment: ["CODEX_ECHO_DEBUG_USAGE_REMAINING_PERCENT": "43"],
      defaultFileURL: defaultURL,
      temporaryDirectory: temporaryDirectory,
      makeIdentifier: { "usage-fixture" }
    )
    let historyFixtureURL = CapacityHistoryDebugStorePolicy.fileURL(
      environment: ["CODEX_ECHO_DEBUG_CAPACITY_HISTORY_FIXTURE": "story"],
      defaultFileURL: defaultURL,
      temporaryDirectory: temporaryDirectory,
      makeIdentifier: { "history-fixture" }
    )
    let normalDebugURL = CapacityHistoryDebugStorePolicy.fileURL(
      environment: [:],
      defaultFileURL: defaultURL,
      temporaryDirectory: temporaryDirectory,
      makeIdentifier: { "unused" }
    )
    let explicitURL = CapacityHistoryDebugStorePolicy.fileURL(
      environment: [
        "CODEX_ECHO_DEBUG_USAGE_REMAINING_PERCENT": "43",
        "CODEX_ECHO_DEBUG_CAPACITY_HISTORY_FILE": "/explicit/v1.jsonl",
      ],
      defaultFileURL: defaultURL,
      temporaryDirectory: temporaryDirectory,
      makeIdentifier: { "unused" }
    )

    XCTAssertEqual(
      usageFixtureURL.path,
      "/tmp/codex-echo-tests/CodexEchoCapacityFixtures/usage-fixture/v1.jsonl"
    )
    XCTAssertEqual(
      historyFixtureURL.path,
      "/tmp/codex-echo-tests/CodexEchoCapacityFixtures/history-fixture/v1.jsonl"
    )
    XCTAssertEqual(normalDebugURL, defaultURL)
    XCTAssertEqual(explicitURL.path, "/explicit/v1.jsonl")
  }

  @MainActor
  func testMissingSavedHistoryWindowClearsOnlyAfterHistoryLoads()
    async throws
  {
    let suiteName = "MissingCapacityWindowTests-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let key = CapacityHistoryViewModel.selectedLimitDurationDefaultsKey
    defaults.set(12 * 60, forKey: key)
    let fileURL = temporaryHistoryURL()
    defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
    let viewModel = CapacityHistoryViewModel(
      store: CapacityHistoryStore(fileURL: fileURL),
      userDefaults: defaults
    )
    let snapshot = CodexUsageSnapshot(
      usedPercent: 40,
      windowDurationMinutes: 10_080
    )

    viewModel.reconcileLimitSelection(snapshot: snapshot)
    XCTAssertEqual(defaults.integer(forKey: key), 12 * 60)

    await viewModel.refresh()
    viewModel.reconcileLimitSelection(snapshot: snapshot)

    XCTAssertNil(defaults.object(forKey: key))
    XCTAssertEqual(viewModel.selectedLimit, .weeklyWindow)
  }

  func testExportDefaultsToDownloadsUntilTheFirstSuccessfulSave() throws {
    let suiteName = "CapacityHistoryExportTests-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let downloadsURL = URL(fileURLWithPath: "/Users/example/Downloads")

    XCTAssertEqual(
      CapacityHistoryExportDestinationPolicy.initialDirectoryURL(
        userDefaults: defaults,
        downloadsDirectoryURL: downloadsURL
      ),
      downloadsURL
    )

    CapacityHistoryExportDestinationPolicy.recordSuccessfulExport(
      in: defaults
    )

    XCTAssertNil(
      CapacityHistoryExportDestinationPolicy.initialDirectoryURL(
        userDefaults: defaults,
        downloadsDirectoryURL: downloadsURL
      )
    )
  }

  @MainActor
  func testExportReadsTheStoreAfterTheSaveDestinationIsChosen() async throws {
    let capacityURL = temporaryHistoryURL()
    defer {
      try? FileManager.default.removeItem(
        at: capacityURL.deletingLastPathComponent()
      )
    }
    let store = CapacityHistoryStore(fileURL: capacityURL)
    let viewModel = CapacityHistoryViewModel(store: store)
    let first = CapacityObservation(
      observedAt: Date(timeIntervalSince1970: 1_800_000_000),
      remainingPercent: 52,
      sessionID: UUID()
    )
    let appendedWhilePanelIsOpen = CapacityObservation(
      observedAt: Date(timeIntervalSince1970: 1_800_000_300),
      remainingPercent: 47,
      sessionID: first.sessionID
    )
    try await store.append(first)
    try await store.append(appendedWhilePanelIsOpen)

    let csv = try await viewModel.csvForExport()

    XCTAssertTrue(csv.contains(",52"))
    XCTAssertTrue(csv.contains(",47"))
  }

  func testCommonMenuOrdersFrequentActionsBeforeTaskLayoutConfiguration() {
    XCTAssertEqual(
      MenuBarConfigurationPolicy.elements,
      [
        .codexCapacity,
        .speakAnnouncements,
        .tasksOnMenuBar,
      ]
    )
  }

  @MainActor
  func testActivityModelTracksUsageAvailabilityAcrossReadAndReconnect()
    throws
  {
    let suiteName = "CapacityUsageAvailabilityTests-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let appServerClient = CodexAppServerClient(
      executableURL: URL(fileURLWithPath: "/usr/bin/false")
    )
    let model = CodexActivityModel(
      appServerClient: appServerClient,
      settings: MenuBarSettings(userDefaults: defaults),
      userDefaults: defaults,
      debugTaskFixtureName: "idle"
    )

    appServerClient.eventHandler?(.connectionStateChanged(.running))
    XCTAssertEqual(model.codexUsageAvailability, .pending)

    appServerClient.eventHandler?(.usageUnavailable)
    XCTAssertEqual(model.codexUsageAvailability, .unavailable)

    appServerClient.eventHandler?(
      .usageChanged(
        CodexUsageSnapshot(
          usedPercent: 40,
          windowDurationMinutes: 10_080
        )
      )
    )
    XCTAssertEqual(model.codexUsageAvailability, .available)

    appServerClient.eventHandler?(.connectionStateChanged(.starting))
    XCTAssertEqual(model.codexUsageAvailability, .pending)
    XCTAssertNil(model.codexUsageSnapshot)

    appServerClient.eventHandler?(
      .connectionStateChanged(.failed(message: "Unavailable"))
    )
    XCTAssertEqual(model.codexUsageAvailability, .unavailable)
  }

  @MainActor
  func testDisabledCapacityRecordingKeepsLiveUsageWithoutPersistingAndResumesFromCurrentUsage()
    async throws
  {
    let suiteName = "CapacityUsageRecordingTests-\(UUID().uuidString)"
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
    let fileURL = temporaryHistoryURL()
    defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
    let store = CapacityHistoryStore(fileURL: fileURL)
    let recorder = CapacityHistoryRecorder(model: model, store: store)

    appServerClient.eventHandler?(.connectionStateChanged(.running))
    appServerClient.eventHandler?(
      .usageChanged(
        CodexUsageSnapshot(
          usedPercent: 40,
          windowDurationMinutes: 10_080,
          resetsAt: nil
        )
      )
    )

    XCTAssertFalse(recorder.isRecordingEnabled)
    XCTAssertEqual(model.appServerConnectionState, .running)
    XCTAssertEqual(model.codexUsageSnapshot?.remainingPercent, 60)
    XCTAssertTrue(recorder.isConnected)
    XCTAssertEqual(recorder.liveRemainingPercent, 60)
    XCTAssertNil(recorder.liveSessionID)
    let storedWhileDisabled = try await store.readAll()
    XCTAssertTrue(storedWhileDisabled.isEmpty)

    settings.recordsCapacityHistory = true
    XCTAssertTrue(recorder.isRecordingEnabled)
    XCTAssertNotNil(recorder.liveSessionID)
    let firstSession = try await store.readAll()
    let firstObservation = try XCTUnwrap(firstSession.last)

    XCTAssertEqual(firstSession.count, 1)
    XCTAssertEqual(firstObservation.remainingPercent, 60)
    XCTAssertEqual(recorder.liveSessionID, firstObservation.sessionID)

    settings.recordsCapacityHistory = false
    appServerClient.eventHandler?(
      .usageChanged(
        CodexUsageSnapshot(
          usedPercent: 42,
          windowDurationMinutes: 10_080,
          resetsAt: nil
        )
      )
    )

    XCTAssertEqual(recorder.liveRemainingPercent, 58)
    XCTAssertNil(recorder.liveSessionID)
    let storedAfterDisabledUpdate = try await store.readAll()
    XCTAssertEqual(storedAfterDisabledUpdate, firstSession)

    settings.recordsCapacityHistory = true
    let resumed = try await store.readAll()
    let resumedObservation = try XCTUnwrap(resumed.last)

    XCTAssertEqual(resumed.count, 2)
    XCTAssertEqual(resumedObservation.remainingPercent, 58)
    XCTAssertNotEqual(resumedObservation.sessionID, firstObservation.sessionID)
  }

  @MainActor
  func testCapacityRecorderPersistsFiveHourAndWeeklyWindowsIndependently()
    async throws
  {
    let suiteName = "CapacityMultiWindowTests-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
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
    let fileURL = temporaryHistoryURL()
    defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
    let store = CapacityHistoryStore(fileURL: fileURL)
    let recorder = CapacityHistoryRecorder(model: model, store: store)
    let fiveHourReset = Date(timeIntervalSince1970: 1_800_010_000)
    let weeklyReset = Date(timeIntervalSince1970: 1_800_600_000)

    appServerClient.eventHandler?(.connectionStateChanged(.running))
    appServerClient.eventHandler?(
      .usageChanged(
        CodexUsageSnapshot(
          primaryWindow: CodexRateLimitWindow(
            slot: .primary,
            usedPercent: 20,
            windowDurationMinutes: 300,
            resetsAt: fiveHourReset
          ),
          secondaryWindow: CodexRateLimitWindow(
            slot: .secondary,
            usedPercent: 60,
            windowDurationMinutes: 10_080,
            resetsAt: weeklyReset
          )
        )
      )
    )

    let stored = try await store.readAll()
    XCTAssertEqual(stored.count, 2)
    XCTAssertEqual(
      Set(stored.compactMap(\.windowDurationMinutes)),
      Set([300, 10_080])
    )
    XCTAssertNotEqual(stored[0].sessionID, stored[1].sessionID)
    XCTAssertEqual(recorder.liveValue(for: .shortWindow)?.remainingPercent, 80)
    XCTAssertEqual(recorder.liveValue(for: .weeklyWindow)?.remainingPercent, 40)
  }

  @MainActor
  func testClearingWhileHistoryRecordingIsOffDoesNotSeedANewCapacityObservation()
    async throws
  {
    let suiteName = "CapacityHistoryClearTests-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(false, forKey: "recordsCapacityHistory")
    let settings = MenuBarSettings(userDefaults: defaults)
    let model = CodexActivityModel(
      settings: settings,
      userDefaults: defaults,
      debugTaskFixtureName: "idle"
    )
    let fileURL = temporaryHistoryURL()
    defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
    let store = CapacityHistoryStore(fileURL: fileURL)
    try await store.append(
      CapacityObservation(
        observedAt: Date(timeIntervalSince1970: 1_800_000_000),
        remainingPercent: 42,
        sessionID: UUID()
      )
    )
    let recorder = CapacityHistoryRecorder(model: model, store: store)

    try await recorder.clearHistory()

    XCTAssertFalse(recorder.isRecordingEnabled)
    let afterClear = try await store.readAll()
    XCTAssertTrue(afterClear.isEmpty)
  }

  func testHistoryMinimumWindowUsesCompactVerticalLayoutMetrics() {
    XCTAssertEqual(CapacityHistoryWindowMetrics.minimumHeight, 380)
    XCTAssertEqual(CapacityHistoryWindowMetrics.verticalPadding, 16)
    XCTAssertEqual(CapacityHistoryWindowMetrics.sectionSpacing, 12)
    XCTAssertEqual(CapacityHistoryWindowMetrics.minimumChartHeight, 140)
  }

  func testCapacityChartSamplingAdaptsToPlotScaleWithoutChangingStoredData() {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let sessionID = UUID()
    let observations = [
      (0, 100),
      (1, 99),
      (2, 98),
      (9, 97),
      (10, 96),
      (11, 96),
      (100, 90),
    ].map { offset, remainingPercent in
      CapacityObservation(
        observedAt: start.addingTimeInterval(TimeInterval(offset)),
        remainingPercent: remainingPercent,
        sessionID: sessionID
      )
    }
    let segment = CapacityHistorySegment(observations: observations)
    let rangeEnd = start.addingTimeInterval(100)

    let compact = CapacityHistoryVisualSamplingPolicy.segments(
      [segment],
      rangeStart: start,
      rangeEnd: rangeEnd,
      plotWidth: 100,
      minimumHorizontalSpacing: 10
    )
    let expanded = CapacityHistoryVisualSamplingPolicy.segments(
      [segment],
      rangeStart: start,
      rangeEnd: rangeEnd,
      plotWidth: 1_000,
      minimumHorizontalSpacing: 4
    )

    XCTAssertEqual(
      compact[0].observations.map {
        Int($0.observedAt.timeIntervalSince(start))
      },
      [0, 9, 10, 100]
    )
    XCTAssertEqual(
      expanded[0].observations.map {
        Int($0.observedAt.timeIntervalSince(start))
      },
      [0, 1, 2, 9, 10, 100]
    )
    XCTAssertEqual(segment.observations, observations)
  }

  func testCapacityChartSamplingPreservesAChangeBeforeItsFinalHeartbeat() {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let sessionID = UUID()
    let observations = [
      (0, 100),
      (10, 90),
      (11, 90),
    ].map { offset, remainingPercent in
      CapacityObservation(
        observedAt: start.addingTimeInterval(TimeInterval(offset)),
        remainingPercent: remainingPercent,
        sessionID: sessionID
      )
    }

    let sampled = CapacityHistoryVisualSamplingPolicy.segments(
      [CapacityHistorySegment(observations: observations)],
      rangeStart: start,
      rangeEnd: start.addingTimeInterval(100),
      plotWidth: 10,
      minimumHorizontalSpacing: 10
    )

    XCTAssertEqual(
      sampled[0].observations.map {
        Int($0.observedAt.timeIntervalSince(start))
      },
      [0, 10, 11]
    )
  }

  func testCapacityAxisUsesEnglishCalendarCopyUnderAJapaneseLocale() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 9 * 60 * 60))
    calendar.locale = Locale(identifier: "ja_JP")
    let monday = try XCTUnwrap(
      calendar.date(
        from: DateComponents(year: 2026, month: 8, day: 3, hour: 0)
      )
    )
    let afternoon = try XCTUnwrap(
      calendar.date(
        from: DateComponents(year: 2026, month: 8, day: 3, hour: 13)
      )
    )

    XCTAssertEqual(
      CapacityHistoryAxisLabelPolicy.label(
        for: monday,
        style: .sevenDays,
        calendar: calendar
      ),
      "Mon, Aug 3"
    )
    XCTAssertEqual(
      CapacityHistoryAxisLabelPolicy.label(
        for: monday,
        style: .thirtyDays,
        calendar: calendar
      ),
      "Aug 3"
    )
    XCTAssertEqual(
      CapacityHistoryAxisLabelPolicy.label(
        for: afternoon,
        style: .hourlyWindow,
        calendar: calendar
      ),
      "13:00"
    )
    XCTAssertEqual(
      CapacityHistoryAxisLabelPolicy.label(
        for: afternoon,
        style: .twentyFourHours,
        calendar: calendar
      ),
      "13"
    )
  }

  func testCapacityOverviewUsesConciseLabelsAndSortableLocalTime() throws {
    let timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 9 * 60 * 60))
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let nextReset = try XCTUnwrap(
      calendar.date(
        from: DateComponents(
          year: 2026,
          month: 8,
          day: 5,
          hour: 13,
          minute: 9
        )
      )
    )
    let earlierExpiration = try XCTUnwrap(
      calendar.date(
        from: DateComponents(
          year: 2026,
          month: 8,
          day: 16,
          hour: 8,
          minute: 30
        )
      )
    )
    let laterExpiration = try XCTUnwrap(
      calendar.date(
        from: DateComponents(
          year: 2026,
          month: 8,
          day: 23,
          hour: 18,
          minute: 45
        )
      )
    )
    let snapshot = CodexUsageSnapshot(
      usedPercent: 11,
      windowDurationMinutes: 10_080,
      resetsAt: nextReset,
      rateLimitResetCredits: CodexRateLimitResetCredits(
        availableCount: 2,
        expirationDates: [laterExpiration, earlierExpiration]
      )
    )

    XCTAssertEqual(
      CodexCapacityOverviewPresentation.make(
        snapshot: snapshot,
        timeZone: timeZone
      ),
      CodexCapacityOverviewPresentation(
        remainingPercent: 89,
        nextReset: CodexCapacityLimitResetPresentation(
          resetsAt: nextReset,
          label: "Next Reset",
          text: "2026-08-05 13:09"
        ),
        availableResetCount: 2,
        expirations: [
          CodexCapacityExpirationPresentation(
            expiresAt: earlierExpiration,
            text: "2026-08-16 08:30"
          ),
          CodexCapacityExpirationPresentation(
            expiresAt: laterExpiration,
            text: "2026-08-23 18:45"
          ),
        ]
      )
    )
    XCTAssertEqual(CodexCapacityOverviewCopy.nextReset, "Next Reset")
    XCTAssertEqual(CodexCapacityOverviewCopy.resetCredits, "Reset Credits")
    XCTAssertEqual(CodexCapacityOverviewCopy.nextExpiration, "Next Expiration")
    XCTAssertEqual(
      CodexCapacityOverviewCopy.showResetExpirations,
      "Show Reset Expirations"
    )
  }

  func testCapacityOverviewUsesTheExplicitlySelectedUsageWindow() throws {
    let fiveHourReset = Date(timeIntervalSince1970: 1_800_010_000)
    let weeklyReset = Date(timeIntervalSince1970: 1_800_600_000)
    let snapshot = CodexUsageSnapshot(
      primaryWindow: CodexRateLimitWindow(
        slot: .primary,
        usedPercent: 35,
        windowDurationMinutes: 300,
        resetsAt: fiveHourReset
      ),
      secondaryWindow: CodexRateLimitWindow(
        slot: .secondary,
        usedPercent: 72,
        windowDurationMinutes: 10_080,
        resetsAt: weeklyReset
      )
    )

    let fiveHour = CodexCapacityOverviewPresentation.make(
      snapshot: snapshot,
      windowDurationMinutes: 300
    )
    let weekly = CodexCapacityOverviewPresentation.make(
      snapshot: snapshot,
      windowDurationMinutes: 10_080
    )

    XCTAssertEqual(fiveHour.remainingPercent, 65)
    XCTAssertEqual(fiveHour.nextReset?.label, "Next Reset")
    XCTAssertEqual(fiveHour.nextReset?.resetsAt, fiveHourReset)
    XCTAssertEqual(weekly.remainingPercent, 28)
    XCTAssertEqual(weekly.nextReset?.label, "Next Reset")
    XCTAssertEqual(weekly.nextReset?.resetsAt, weeklyReset)
  }

  func testCapacityOverviewUsesConstrainingWindowForUnresolvedDuration() {
    let reset = Date(timeIntervalSince1970: 1_800_010_000)
    let snapshot = CodexUsageSnapshot(
      usedPercent: 40,
      windowDurationMinutes: nil,
      resetsAt: reset
    )

    let presentation = CodexCapacityOverviewPresentation.make(
      snapshot: snapshot,
      windowDurationMinutes: CapacityHistoryLimit.unresolved.windowDurationMinutes
    )

    XCTAssertEqual(presentation.remainingPercent, 60)
    XCTAssertEqual(presentation.nextReset?.resetsAt, reset)
  }

  func testResetExpirationPopoverScrollsOnlyWhenRowsExceedItsMaximumHeight() {
    XCTAssertFalse(
      CodexCapacityExpirationPopoverMetrics.requiresScrolling(rowCount: 2)
    )
    XCTAssertFalse(
      CodexCapacityExpirationPopoverMetrics.requiresScrolling(rowCount: 7)
    )
    XCTAssertTrue(
      CodexCapacityExpirationPopoverMetrics.requiresScrolling(rowCount: 8)
    )
  }

  func testCapacityOverviewListsEveryExpirationAndExplainsPartialDetails()
    throws
  {
    let timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 9 * 60 * 60))
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let firstExpiration = try XCTUnwrap(
      calendar.date(
        from: DateComponents(
          year: 2026,
          month: 8,
          day: 16,
          hour: 8,
          minute: 30,
          second: 10
        )
      )
    )
    let sameMinuteExpiration = firstExpiration.addingTimeInterval(40)
    let laterExpiration = firstExpiration.addingTimeInterval(75 * 60)
    let presentation = CodexCapacityOverviewPresentation.make(
      snapshot: CodexUsageSnapshot(
        usedPercent: 11,
        rateLimitResetCredits: CodexRateLimitResetCredits(
          availableCount: 100,
          expirationDates: [
            laterExpiration,
            sameMinuteExpiration,
            firstExpiration,
          ]
        )
      ),
      timeZone: timeZone
    )

    XCTAssertEqual(
      presentation.expirations,
      [
        CodexCapacityExpirationPresentation(
          expiresAt: firstExpiration,
          text: "2026-08-16 08:30"
        ),
        CodexCapacityExpirationPresentation(
          expiresAt: sameMinuteExpiration,
          text: "2026-08-16 08:30"
        ),
        CodexCapacityExpirationPresentation(
          expiresAt: laterExpiration,
          text: "2026-08-16 09:45"
        ),
      ]
    )
    XCTAssertEqual(presentation.nextExpiration, presentation.expirations.first)
    XCTAssertTrue(presentation.showsExpirationDetails)
    XCTAssertEqual(
      presentation.expirationReportingNote,
      "3 of 100 expiration dates reported."
    )
  }

  func testCapacityOverviewExplainsWhenNoExpirationDetailsWereReturned() {
    let presentation = CodexCapacityOverviewPresentation.make(
      snapshot: CodexUsageSnapshot(
        usedPercent: 11,
        rateLimitResetCredits: CodexRateLimitResetCredits(
          availableCount: 3,
          expirationDates: []
        )
      )
    )

    XCTAssertTrue(presentation.showsExpirationDetails)
    XCTAssertEqual(
      presentation.expirationReportingNote,
      "0 of 3 expiration dates reported."
    )
  }

  func testCapacityOverviewKeepsOneCompleteExpirationInlineWithoutDetails()
    throws
  {
    let expiration = Date(timeIntervalSince1970: 1_786_840_200)
    let presentation = CodexCapacityOverviewPresentation.make(
      snapshot: CodexUsageSnapshot(
        usedPercent: 11,
        rateLimitResetCredits: CodexRateLimitResetCredits(
          availableCount: 1,
          expirationDates: [expiration]
        )
      )
    )

    XCTAssertEqual(presentation.nextExpiration?.expiresAt, expiration)
    XCTAssertFalse(presentation.showsExpirationDetails)
    XCTAssertNil(presentation.expirationReportingNote)
  }

  func testCapacityOverviewOmitsUnavailableResetInformation() {
    XCTAssertEqual(
      CodexCapacityOverviewPresentation.make(
        snapshot: CodexUsageSnapshot(
          usedPercent: 20,
          rateLimitResetCredits: CodexRateLimitResetCredits(
            availableCount: 0,
            expirationDates: []
          )
        )
      ),
      CodexCapacityOverviewPresentation(
        remainingPercent: 80,
        nextReset: nil,
        availableResetCount: nil,
        expirations: []
      )
    )
  }

  @MainActor
  func testHistoryUsesAnIndependentMovableResizableWindow() throws {
    let controller = CapacityHistoryWindowFactory.make(
      contentView: NSView(),
      savesFrame: false
    )
    let window = try XCTUnwrap(controller.window)
    defer { window.close() }

    XCTAssertEqual(window.title, "Codex Capacity")
    XCTAssertNil(window.sheetParent)
    XCTAssertTrue(window.isMovable)
    XCTAssertTrue(window.styleMask.contains(.titled))
    XCTAssertTrue(window.styleMask.contains(.closable))
    XCTAssertTrue(window.styleMask.contains(.miniaturizable))
    XCTAssertTrue(window.styleMask.contains(.resizable))
    XCTAssertEqual(
      window.contentMinSize,
      NSSize(
        width: CapacityHistoryWindowMetrics.minimumWidth,
        height: CapacityHistoryWindowMetrics.minimumHeight
      )
    )
    XCTAssertFalse(window.isReleasedWhenClosed)
  }

  private func currentCycleContext(
    remainingPercent: Int,
    observedAt: Date,
    windowDurationMinutes: Int,
    resetsAt: Date
  ) -> CapacityHistoryCurrentCycleContext {
    CapacityHistoryCurrentCycleContext(
      windowDurationMinutes: windowDurationMinutes,
      resetsAt: resetsAt,
      endpoint: CapacityHistoryCurrentCycleEndpoint(
        observedAt: observedAt,
        remainingPercent: remainingPercent
      )
    )
  }

  private func temporaryHistoryURL() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("CodexEchoTests-\(UUID().uuidString)", isDirectory: true)
      .appendingPathComponent("v1.jsonl")
  }

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

private extension CapacityHistoryRecordingPolicy {
  mutating func observation(
    remainingPercent: Int,
    observedAt: Date,
    resetsAt: Date? = nil
  ) -> CapacityObservation? {
    observation(
      remainingPercent: remainingPercent,
      observedAt: observedAt,
      windowDurationMinutes: 7 * 24 * 60,
      resetsAt: resetsAt
    )
  }
}

private final class CapacityHistoryTestFileManager: FileManager {
  private let applicationSupportURL: URL

  init(applicationSupportURL: URL) {
    self.applicationSupportURL = applicationSupportURL
    super.init()
  }

  override func urls(
    for directory: FileManager.SearchPathDirectory,
    in domainMask: FileManager.SearchPathDomainMask
  ) -> [URL] {
    if directory == .applicationSupportDirectory, domainMask == .userDomainMask {
      return [applicationSupportURL]
    }
    return super.urls(for: directory, in: domainMask)
  }
}
