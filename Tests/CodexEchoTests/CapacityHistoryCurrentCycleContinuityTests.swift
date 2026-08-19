import CodexAppServer
import Combine
import Foundation
import XCTest

@testable import CodexEcho

final class CapacityHistoryCurrentCycleContinuityTests: XCTestCase {
  private let weeklyLimit = CapacityHistoryLimit(
    windowDurationMinutes: 7 * 24 * 60
  )

  func testResolverMovesFromActiveToRetainedToAwaitingAndAcceptsANewCycle() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let reset = now.addingTimeInterval(4 * 24 * 60 * 60)
    let context = makeContext(now: now, reset: reset)
    let snapshot = makeSnapshot(reset: reset)
    let liveValue = CapacityHistoryLiveValue(
      remainingPercent: 58,
      observedAt: now,
      sessionID: UUID(),
      windowDurationMinutes: weeklyLimit.windowDurationMinutes,
      resetsAt: reset
    )

    XCTAssertEqual(
      CapacityHistoryCurrentCyclePresentation.resolve(
        limit: weeklyLimit,
        receivedLiveValue: liveValue,
        context: context,
        snapshot: snapshot,
        isConnected: true,
        now: now
      ),
      .active(context)
    )
    XCTAssertEqual(
      CapacityHistoryCurrentCyclePresentation.resolve(
        limit: weeklyLimit,
        receivedLiveValue: nil,
        context: context,
        snapshot: nil,
        isConnected: false,
        now: now.addingTimeInterval(60)
      ),
      .retained(context)
    )
    XCTAssertEqual(
      CapacityHistoryCurrentCyclePresentation.resolve(
        limit: weeklyLimit,
        receivedLiveValue: nil,
        context: context,
        snapshot: nil,
        isConnected: false,
        now: reset
      ),
      .unavailable(.awaiting)
    )

    let newReset = reset.addingTimeInterval(7 * 24 * 60 * 60)
    let newContext = makeContext(
      now: reset,
      reset: newReset,
      remainingPercent: 100
    )
    let newLiveValue = CapacityHistoryLiveValue(
      remainingPercent: 100,
      observedAt: reset,
      sessionID: UUID(),
      windowDurationMinutes: weeklyLimit.windowDurationMinutes,
      resetsAt: newReset
    )
    XCTAssertEqual(
      CapacityHistoryCurrentCyclePresentation.resolve(
        limit: weeklyLimit,
        receivedLiveValue: newLiveValue,
        context: newContext,
        snapshot: makeSnapshot(usedPercent: 0, reset: newReset),
        isConnected: true,
        now: reset
      ),
      .active(newContext)
    )
  }

  func testResolverRequiresMatchingResetAndExplainsFreshMissingLimit() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let reset = now.addingTimeInterval(4 * 24 * 60 * 60)
    let context = makeContext(now: now, reset: reset)
    let mismatchedLiveValue = CapacityHistoryLiveValue(
      remainingPercent: 58,
      observedAt: now,
      sessionID: UUID(),
      windowDurationMinutes: weeklyLimit.windowDurationMinutes,
      resetsAt: reset.addingTimeInterval(
        CapacityHistoryResetBoundary.timestampTolerance + 1
      )
    )

    XCTAssertEqual(
      CapacityHistoryCurrentCyclePresentation.resolve(
        limit: weeklyLimit,
        receivedLiveValue: mismatchedLiveValue,
        context: context,
        snapshot: makeSnapshot(reset: reset),
        isConnected: true,
        now: now
      ),
      .retained(context)
    )

    let fiveHourSnapshot = CodexUsageSnapshot(
      usedPercent: 20,
      windowDurationMinutes: 300,
      resetsAt: now.addingTimeInterval(2 * 60 * 60)
    )
    XCTAssertEqual(
      CapacityHistoryCurrentCyclePresentation.resolve(
        limit: weeklyLimit,
        receivedLiveValue: nil,
        context: nil,
        snapshot: fiveHourSnapshot,
        isConnected: true,
        now: now
      ),
      .unavailable(.unavailableForLimit)
    )
    XCTAssertEqual(
      CapacityHistoryCurrentCyclePresentation.resolve(
        limit: weeklyLimit,
        receivedLiveValue: nil,
        context: nil,
        snapshot: nil,
        isConnected: false,
        now: now
      ),
      .unavailable(.awaiting)
    )
  }

  func testResolverNeverRetainsAContextThatDisagreesWithFreshCycleState() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let oldReset = now.addingTimeInterval(4 * 24 * 60 * 60)
    let oldContext = makeContext(now: now, reset: oldReset)
    let oldLiveValue = CapacityHistoryLiveValue(
      remainingPercent: oldContext.endpoint.remainingPercent,
      observedAt: oldContext.endpoint.observedAt,
      sessionID: UUID(),
      windowDurationMinutes: weeklyLimit.windowDurationMinutes,
      resetsAt: oldReset
    )
    let newReset = oldReset.addingTimeInterval(7 * 24 * 60 * 60)

    XCTAssertEqual(
      CapacityHistoryCurrentCyclePresentation.resolve(
        limit: weeklyLimit,
        receivedLiveValue: oldLiveValue,
        context: oldContext,
        snapshot: makeSnapshot(reset: newReset),
        isConnected: true,
        now: now
      ),
      .unavailable(.awaiting)
    )

    let invalidWindows = [
      CodexRateLimitWindow(
        slot: .primary,
        usedPercent: 42,
        windowDurationMinutes: weeklyLimit.windowDurationMinutes,
        resetsAt: nil
      ),
      CodexRateLimitWindow(
        slot: .primary,
        usedPercent: 42,
        windowDurationMinutes: weeklyLimit.windowDurationMinutes,
        resetsAt: now
      ),
      CodexRateLimitWindow(
        slot: .primary,
        usedPercent: 42,
        windowDurationMinutes: weeklyLimit.windowDurationMinutes,
        resetsAt: now.addingTimeInterval(8 * 24 * 60 * 60)
      ),
    ]
    for window in invalidWindows {
      XCTAssertEqual(
        CapacityHistoryCurrentCyclePresentation.resolve(
          limit: weeklyLimit,
          receivedLiveValue: oldLiveValue,
          context: oldContext,
          snapshot: CodexUsageSnapshot(windows: [window]),
          isConnected: true,
          now: now
        ),
        .unavailable(.awaiting)
      )
    }
  }

  @MainActor
  func testRecorderRetainsContextsAcrossDisconnectBeforeWindowOpens()
    throws
  {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let clock = CapacityContinuityTestClock(now)
    let harness = try makeRecorder(clock: clock)
    defer { harness.cleanup() }
    let reset = now.addingTimeInterval(4 * 24 * 60 * 60)

    harness.client.eventHandler?(.connectionStateChanged(.running))
    harness.client.eventHandler?(
      .usageChanged(makeSnapshot(reset: reset))
    )

    let received = try XCTUnwrap(
      harness.recorder.currentCycleContext(for: weeklyLimit, now: now)
    )
    XCTAssertEqual(received.endpoint.observedAt, now)
    XCTAssertEqual(received.endpoint.remainingPercent, 58)

    harness.client.eventHandler?(.connectionStateChanged(.starting))

    XCTAssertFalse(harness.recorder.isConnected)
    XCTAssertNil(harness.recorder.liveValue(for: weeklyLimit))
    XCTAssertEqual(
      harness.recorder.currentCycleContext(
        for: weeklyLimit,
        now: now.addingTimeInterval(60)
      ),
      received
    )
    XCTAssertEqual(
      harness.recorder.retainedCurrentCycleLimits(
        now: now.addingTimeInterval(60)
      ),
      [weeklyLimit]
    )
    XCTAssertNil(
      harness.recorder.currentCycleContext(for: weeklyLimit, now: reset)
    )
  }

  @MainActor
  func testRecorderCapturesSnapshotAlreadyHeldByModelBeforeItStarts() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let clock = CapacityContinuityTestClock(now)
    let reset = now.addingTimeInterval(4 * 24 * 60 * 60)
    let harness = try makeRecorder(
      clock: clock,
      initialSnapshot: makeSnapshot(reset: reset)
    )
    defer { harness.cleanup() }

    let context = try XCTUnwrap(
      harness.recorder.currentCycleContext(for: weeklyLimit, now: now)
    )
    XCTAssertEqual(context.endpoint.observedAt, now)
    XCTAssertEqual(context.endpoint.remainingPercent, 58)
    XCTAssertEqual(
      harness.recorder.liveValue(for: weeklyLimit)?.observedAt,
      now
    )
  }

  @MainActor
  func testRecorderPublishesContextExpiryAtTheKnownReset() async throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let clock = CapacityContinuityTestClock(now)
    let sleeper = CapacityContinuityTestExpirySleeper()
    let harness = try makeRecorder(
      clock: clock,
      sleepForCurrentCycleExpiry: { milliseconds in
        await sleeper.sleep(milliseconds: milliseconds)
      }
    )
    defer { harness.cleanup() }
    let reset = now.addingTimeInterval(80)

    harness.client.eventHandler?(.connectionStateChanged(.running))
    harness.client.eventHandler?(
      .usageChanged(makeSnapshot(reset: reset))
    )
    XCTAssertEqual(
      harness.recorder.retainedCurrentCycleLimits(now: now),
      [weeklyLimit]
    )

    let expiryPublished = expectation(description: "current cycle expiry")
    var didPublishExpiry = false
    let expiryCancellable = harness.recorder.objectWillChange.sink {
      Task { @MainActor in
        guard
          !didPublishExpiry,
          harness.recorder.retainedCurrentCycleLimits(now: clock.value).isEmpty
        else { return }
        didPublishExpiry = true
        expiryPublished.fulfill()
      }
    }
    let scheduledMilliseconds = await sleeper.waitUntilScheduled()
    XCTAssertEqual(scheduledMilliseconds, 80_000)
    clock.value = reset
    await sleeper.resume()
    await fulfillment(of: [expiryPublished], timeout: 1)

    XCTAssertTrue(
      harness.recorder.retainedCurrentCycleLimits(now: clock.value).isEmpty
    )
    withExtendedLifetime(expiryCancellable) {}
  }

  @MainActor
  func testFreshSnapshotFullyReplacesMultipleDurationContexts() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let clock = CapacityContinuityTestClock(now)
    let harness = try makeRecorder(clock: clock)
    defer { harness.cleanup() }
    let fiveHourLimit = CapacityHistoryLimit(windowDurationMinutes: 300)
    let fiveHourReset = now.addingTimeInterval(2 * 60 * 60)
    let weeklyReset = now.addingTimeInterval(4 * 24 * 60 * 60)

    harness.client.eventHandler?(.connectionStateChanged(.running))
    harness.client.eventHandler?(
      .usageChanged(
        CodexUsageSnapshot(
          windows: [
            CodexRateLimitWindow(
              slot: .primary,
              usedPercent: 20,
              windowDurationMinutes: 300,
              resetsAt: fiveHourReset
            ),
            CodexRateLimitWindow(
              slot: .secondary,
              usedPercent: 42,
              windowDurationMinutes: weeklyLimit.windowDurationMinutes,
              resetsAt: weeklyReset
            ),
          ]
        )
      )
    )
    XCTAssertEqual(
      harness.recorder.retainedCurrentCycleLimits(now: now),
      [fiveHourLimit, weeklyLimit]
    )

    clock.value = now.addingTimeInterval(60)
    let newWeeklyReset = weeklyReset.addingTimeInterval(60)
    harness.client.eventHandler?(
      .usageChanged(
        CodexUsageSnapshot(
          windows: [
            CodexRateLimitWindow(
              slot: .primary,
              usedPercent: 21,
              windowDurationMinutes: 300,
              resetsAt: clock.value.addingTimeInterval(300 * 60 + 1)
            ),
            CodexRateLimitWindow(
              slot: .secondary,
              usedPercent: 43,
              windowDurationMinutes: weeklyLimit.windowDurationMinutes,
              resetsAt: newWeeklyReset
            ),
          ]
        )
      )
    )

    XCTAssertNil(
      harness.recorder.currentCycleContext(
        for: fiveHourLimit,
        now: clock.value
      )
    )
    XCTAssertEqual(
      harness.recorder.retainedCurrentCycleLimits(now: clock.value),
      [weeklyLimit]
    )
    let weekly = try XCTUnwrap(
      harness.recorder.currentCycleContext(
        for: weeklyLimit,
        now: clock.value
      )
    )
    XCTAssertEqual(weekly.resetsAt, newWeeklyReset)
    XCTAssertEqual(weekly.endpoint.observedAt, clock.value)
    XCTAssertEqual(weekly.endpoint.remainingPercent, 57)

    harness.client.eventHandler?(
      .usageChanged(CodexUsageSnapshot(windows: []))
    )
    XCTAssertTrue(
      harness.recorder.retainedCurrentCycleLimits(now: clock.value).isEmpty
    )
  }

  @MainActor
  func testAdministrativeCapturesPreserveReceivedCurrentCycleState()
    async throws
  {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let clock = CapacityContinuityTestClock(now)
    let harness = try makeRecorder(
      clock: clock,
      recordingEnabled: false
    )
    defer { harness.cleanup() }
    let reset = now.addingTimeInterval(4 * 24 * 60 * 60)

    harness.client.eventHandler?(.connectionStateChanged(.running))
    harness.client.eventHandler?(
      .usageChanged(makeSnapshot(reset: reset))
    )
    let original = try XCTUnwrap(
      harness.recorder.currentCycleContext(for: weeklyLimit, now: now)
    )
    let historyWhileDisabled = try await harness.store.readAll()
    XCTAssertTrue(historyWhileDisabled.isEmpty)

    func assertActivePresentation(at date: Date) {
      let receivedLiveValue = harness.recorder.receivedLiveValue(
        for: weeklyLimit
      )
      XCTAssertEqual(receivedLiveValue?.observedAt, original.endpoint.observedAt)
      XCTAssertEqual(
        CapacityHistoryCurrentCyclePresentation.resolve(
          limit: weeklyLimit,
          receivedLiveValue: receivedLiveValue,
          context: harness.recorder.currentCycleContext(
            for: weeklyLimit,
            now: date
          ),
          snapshot: makeSnapshot(reset: reset),
          isConnected: harness.recorder.isConnected,
          now: date
        ),
        .active(original)
      )
    }

    assertActivePresentation(at: now)

    clock.value = now.addingTimeInterval(120)
    harness.settings.recordsCapacityHistory = true
    XCTAssertEqual(
      harness.recorder.currentCycleContext(
        for: weeklyLimit,
        now: clock.value
      ),
      original
    )
    XCTAssertEqual(
      harness.recorder.liveValue(for: weeklyLimit)?.observedAt,
      clock.value
    )
    assertActivePresentation(at: clock.value)
    let enabledHistory = try await harness.store.readAll()
    XCTAssertEqual(enabledHistory.count, 1)
    XCTAssertEqual(enabledHistory[0].observedAt, clock.value)

    clock.value = now.addingTimeInterval(240)
    try await harness.recorder.clearHistory()
    XCTAssertEqual(
      harness.recorder.currentCycleContext(
        for: weeklyLimit,
        now: clock.value
      ),
      original
    )
    XCTAssertEqual(
      harness.recorder.liveValue(for: weeklyLimit)?.observedAt,
      clock.value
    )
    assertActivePresentation(at: clock.value)
    let afterClear = try await harness.store.readAll()
    XCTAssertEqual(afterClear.count, 1)
    XCTAssertEqual(afterClear[0].observedAt, clock.value)

    clock.value = now.addingTimeInterval(360)
    harness.settings.recordsCapacityHistory = false
    harness.settings.recordsCapacityHistory = true
    XCTAssertEqual(
      harness.recorder.currentCycleContext(
        for: weeklyLimit,
        now: clock.value
      ),
      original
    )
    XCTAssertEqual(
      harness.recorder.liveValue(for: weeklyLimit)?.observedAt,
      clock.value
    )
    assertActivePresentation(at: clock.value)
  }

  private func makeContext(
    now: Date,
    reset: Date,
    remainingPercent: Int = 58
  ) -> CapacityHistoryCurrentCycleContext {
    CapacityHistoryCurrentCycleContext(
      windowDurationMinutes: weeklyLimit.windowDurationMinutes,
      resetsAt: reset,
      endpoint: CapacityHistoryCurrentCycleEndpoint(
        observedAt: now,
        remainingPercent: remainingPercent
      )
    )
  }

  private func makeSnapshot(
    usedPercent: Int = 42,
    reset: Date
  ) -> CodexUsageSnapshot {
    CodexUsageSnapshot(
      usedPercent: usedPercent,
      windowDurationMinutes: weeklyLimit.windowDurationMinutes,
      resetsAt: reset
    )
  }

  @MainActor
  private func makeRecorder(
    clock: CapacityContinuityTestClock,
    recordingEnabled: Bool = true,
    initialSnapshot: CodexUsageSnapshot? = nil,
    sleepForCurrentCycleExpiry: @escaping @Sendable (
      _ milliseconds: Int64
    ) async -> Void = { milliseconds in
      try? await Task.sleep(for: .milliseconds(milliseconds))
    }
  ) throws -> CapacityContinuityRecorderHarness {
    let suiteName = "CapacityContinuityTests-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defaults.set(recordingEnabled, forKey: "recordsCapacityHistory")
    let settings = MenuBarSettings(userDefaults: defaults)
    let client = CodexAppServerClient(
      executableURL: URL(fileURLWithPath: "/usr/bin/false")
    )
    let model = CodexActivityModel(
      appServerClient: client,
      settings: settings,
      userDefaults: defaults,
      debugTaskFixtureName: "idle"
    )
    if let initialSnapshot {
      client.eventHandler?(.connectionStateChanged(.running))
      client.eventHandler?(.usageChanged(initialSnapshot))
    }
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "CapacityContinuityTests-\(UUID().uuidString)",
        isDirectory: true
      )
    let store = CapacityHistoryStore(
      fileURL: directory.appendingPathComponent("v1.jsonl")
    )
    let recorder = CapacityHistoryRecorder(
      model: model,
      store: store,
      now: { clock.value },
      sleepForCurrentCycleExpiry: sleepForCurrentCycleExpiry
    )
    return CapacityContinuityRecorderHarness(
      suiteName: suiteName,
      defaults: defaults,
      settings: settings,
      client: client,
      store: store,
      recorder: recorder,
      directory: directory
    )
  }
}

private final class CapacityContinuityTestClock: @unchecked Sendable {
  var value: Date

  init(_ value: Date) {
    self.value = value
  }
}

private actor CapacityContinuityTestExpirySleeper {
  private var scheduledMilliseconds: Int64?
  private var scheduleWaiters: [CheckedContinuation<Int64, Never>] = []
  private var sleepContinuation: CheckedContinuation<Void, Never>?

  func sleep(milliseconds: Int64) async {
    scheduledMilliseconds = milliseconds
    let waiters = scheduleWaiters
    scheduleWaiters = []
    waiters.forEach { $0.resume(returning: milliseconds) }
    await withCheckedContinuation { continuation in
      sleepContinuation = continuation
    }
  }

  func waitUntilScheduled() async -> Int64 {
    if let scheduledMilliseconds { return scheduledMilliseconds }
    return await withCheckedContinuation { continuation in
      scheduleWaiters.append(continuation)
    }
  }

  func resume() {
    sleepContinuation?.resume()
    sleepContinuation = nil
  }
}

@MainActor
private struct CapacityContinuityRecorderHarness {
  let suiteName: String
  let defaults: UserDefaults
  let settings: MenuBarSettings
  let client: CodexAppServerClient
  let store: CapacityHistoryStore
  let recorder: CapacityHistoryRecorder
  let directory: URL

  func cleanup() {
    defaults.removePersistentDomain(forName: suiteName)
    try? FileManager.default.removeItem(at: directory)
  }
}
