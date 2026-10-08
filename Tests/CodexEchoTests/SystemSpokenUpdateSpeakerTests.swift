import XCTest

@testable import CodexEcho

final class SystemSpokenUpdateSpeakerTests: XCTestCase {
  @MainActor
  func testSystemSpeakerUsesSlightlyAcceleratedSpeechRate() {
    XCTAssertEqual(SystemSpokenUpdateSpeaker.rateMultiplier, 1.08)
  }

  func testImportantCueWaveformProducesTwoSeparatedSafePips() {
    let samples = ImportantAnnouncementCueWaveform.samples()
    XCTAssertEqual(samples.count, 8_640)
    XCTAssertTrue(samples.allSatisfy(\.isFinite))
    XCTAssertGreaterThan(
      peakAmplitude(
        in: samples,
        from: 0,
        through: 0.055,
        sampleRate: ImportantAnnouncementCueWaveform.sampleRate
      ),
      0.05
    )
    XCTAssertLessThan(
      peakAmplitude(
        in: samples,
        from: 0.065,
        through: 0.08,
        sampleRate: ImportantAnnouncementCueWaveform.sampleRate
      ),
      0.000_1
    )
    XCTAssertGreaterThan(
      peakAmplitude(
        in: samples,
        from: 0.09,
        through: 0.155,
        sampleRate: ImportantAnnouncementCueWaveform.sampleRate
      ),
      0.05
    )
    XCTAssertLessThanOrEqual(samples.map(abs).max() ?? 0, 0.15)
    XCTAssertGreaterThan(
      ImportantAnnouncementCueWaveform.speechDelay,
      ImportantAnnouncementCueWaveform.duration
    )
  }

  func testAttentionCueWaveformProducesOneSafePip() {
    let samples = ImportantAnnouncementCueWaveform.attentionSamples()
    XCTAssertEqual(samples.count, 3_360)
    XCTAssertTrue(samples.allSatisfy(\.isFinite))
    XCTAssertGreaterThan(
      peakAmplitude(
        in: samples,
        from: 0,
        through: 0.055,
        sampleRate: ImportantAnnouncementCueWaveform.sampleRate
      ),
      0.05
    )
    XCTAssertLessThan(
      peakAmplitude(
        in: samples,
        from: 0.06,
        through: ImportantAnnouncementCueWaveform.attentionDuration,
        sampleRate: ImportantAnnouncementCueWaveform.sampleRate
      ),
      0.000_1
    )
    XCTAssertLessThanOrEqual(samples.map(abs).max() ?? 0, 0.15)
    XCTAssertGreaterThan(
      ImportantAnnouncementCueWaveform.attentionSpeechDelay,
      ImportantAnnouncementCueWaveform.attentionDuration
    )
  }

  func testCuePlaybackScheduleSerializesDifferentCuesWithoutDroppingEither() {
    var schedule = SpokenUpdateCuePlaybackSchedule()

    let attention = schedule.plan(
      now: 10,
      cueDuration: ImportantAnnouncementCueWaveform.attentionDuration,
      completionDelay:
        ImportantAnnouncementCueWaveform.attentionSpeechDelay
    )
    let important = schedule.plan(
      now: 10,
      cueDuration: ImportantAnnouncementCueWaveform.duration,
      completionDelay: ImportantAnnouncementCueWaveform.speechDelay
    )

    XCTAssertFalse(attention.resetsPendingPlayback)
    XCTAssertEqual(
      attention.completionDelay,
      ImportantAnnouncementCueWaveform.attentionSpeechDelay,
      accuracy: 0.000_1
    )
    XCTAssertFalse(important.resetsPendingPlayback)
    XCTAssertEqual(
      important.completionDelay,
      ImportantAnnouncementCueWaveform.attentionDuration
        + ImportantAnnouncementCueWaveform.speechDelay,
      accuracy: 0.000_1
    )
  }

  func testCuePlaybackScheduleBoundsBacklogAndKeepsTheNewestCue() {
    var schedule = SpokenUpdateCuePlaybackSchedule()
    for _ in 0..<4 {
      let plan = schedule.plan(
        now: 10,
        cueDuration: ImportantAnnouncementCueWaveform.duration,
        completionDelay: ImportantAnnouncementCueWaveform.speechDelay
      )
      XCTAssertFalse(plan.resetsPendingPlayback)
    }

    let newest = schedule.plan(
      now: 10,
      cueDuration: ImportantAnnouncementCueWaveform.duration,
      completionDelay: ImportantAnnouncementCueWaveform.speechDelay
    )

    XCTAssertTrue(newest.resetsPendingPlayback)
    XCTAssertEqual(
      newest.completionDelay,
      ImportantAnnouncementCueWaveform.speechDelay,
      accuracy: 0.000_1
    )
  }

  func testCuePlaybackScheduleResetClearsPendingAudio() {
    var schedule = SpokenUpdateCuePlaybackSchedule()
    _ = schedule.plan(
      now: 10,
      cueDuration: ImportantAnnouncementCueWaveform.duration,
      completionDelay: ImportantAnnouncementCueWaveform.speechDelay
    )

    schedule.reset()
    let next = schedule.plan(
      now: 10,
      cueDuration: ImportantAnnouncementCueWaveform.attentionDuration,
      completionDelay:
        ImportantAnnouncementCueWaveform.attentionSpeechDelay
    )

    XCTAssertFalse(next.resetsPendingPlayback)
    XCTAssertEqual(
      next.completionDelay,
      ImportantAnnouncementCueWaveform.attentionSpeechDelay,
      accuracy: 0.000_1
    )
  }

  func testStartupPlaybackDefersOtherAudioUntilStartupFinishes() {
    var gate = StartupExclusivePlaybackGate<String>()

    XCTAssertEqual(startupAnnouncementFollowUpDelay, 0.5)
    XCTAssertEqual(
      gate.enqueue(
        "startup",
        isStartup: true,
        playbackIsIdle: true
      ),
      ["startup"]
    )
    XCTAssertEqual(
      gate.enqueue(
        "task",
        isStartup: false,
        playbackIsIdle: false
      ),
      []
    )
    XCTAssertEqual(
      gate.enqueue(
        "usage",
        isStartup: false,
        playbackIsIdle: false
      ),
      []
    )
    XCTAssertEqual(gate.playbackDidBecomeIdle(), [])
    XCTAssertEqual(
      gate.enqueue(
        "connection",
        isStartup: false,
        playbackIsIdle: true
      ),
      []
    )
    XCTAssertEqual(
      gate.startupFollowUpGapDidElapse(),
      ["task", "usage", "connection"]
    )
  }

  func testStartupPlaybackWaitsForExistingAudioBeforeBecomingExclusive() {
    var gate = StartupExclusivePlaybackGate<String>()

    XCTAssertEqual(
      gate.enqueue(
        "preview",
        isStartup: false,
        playbackIsIdle: true
      ),
      ["preview"]
    )
    XCTAssertEqual(
      gate.enqueue(
        "startup",
        isStartup: true,
        playbackIsIdle: false
      ),
      []
    )
    XCTAssertEqual(
      gate.enqueue(
        "task",
        isStartup: false,
        playbackIsIdle: false
      ),
      []
    )
    XCTAssertEqual(gate.playbackDidBecomeIdle(), ["startup"])
    XCTAssertEqual(gate.playbackDidBecomeIdle(), [])
    XCTAssertEqual(gate.startupFollowUpGapDidElapse(), ["task"])
  }

  func testStoppingAllAudioClearsItemsDeferredByStartup() {
    var gate = StartupExclusivePlaybackGate<String>()
    _ = gate.enqueue(
      "startup",
      isStartup: true,
      playbackIsIdle: true
    )
    _ = gate.enqueue(
      "task",
      isStartup: false,
      playbackIsIdle: false
    )

    gate.reset()

    XCTAssertEqual(gate.playbackDidBecomeIdle(), [])
  }

  @MainActor
  func testCueOnlyStartupDefersOtherCuesUntilPlaybackAndFollowUpGapFinish()
    async throws
  {
    let cuePlayer = TestSpokenUpdateCuePlayer(
      attentionDuration: 0.01,
      importantDuration: 0.01
    )
    let speaker = SystemSpokenUpdateSpeaker(
      cuePlayer: cuePlayer,
      startupFollowUpDelay: 0.01
    )
    let deferredCuePlayed = expectation(description: "Deferred cue plays after Startup")
    cuePlayer.onPlay = { cue in
      if cue == .important { deferredCuePlayed.fulfill() }
    }

    speaker.playCue(.attention, channel: .startup)
    speaker.playCue(.important, channel: .system)

    XCTAssertEqual(cuePlayer.playedCues, [.attention])
    await fulfillment(of: [deferredCuePlayed], timeout: 2)
    XCTAssertEqual(cuePlayer.playedCues, [.attention, .important])
    speaker.stopAll()
  }

  @MainActor
  func testCueOnlyEventsFromTheSameObservationBothReachTheCuePlayer() {
    let cuePlayer = TestSpokenUpdateCuePlayer(
      attentionDuration: 0.1,
      importantDuration: 0.1
    )
    let speaker = SystemSpokenUpdateSpeaker(cuePlayer: cuePlayer)

    speaker.playCue(.attention, channel: .task("completed"))
    speaker.playCue(.important, channel: .task("approval"))

    XCTAssertEqual(cuePlayer.playedCues, [.attention, .important])
    speaker.stopAll()
  }

  @MainActor
  func testStoppingCueOnlyChannelCancelsItsLateCompletion() async throws {
    let cuePlayer = TestSpokenUpdateCuePlayer(
      attentionDuration: 0.02,
      importantDuration: 0.08
    )
    let speaker = SystemSpokenUpdateSpeaker(
      cuePlayer: cuePlayer,
      startupFollowUpDelay: 0.005
    )

    speaker.playCue(.attention, channel: .preview)
    XCTAssertEqual(speaker.activeCueOnlyPlaybackCount, 1)
    speaker.stop(.preview)
    XCTAssertEqual(speaker.activeCueOnlyPlaybackCount, 0)
    speaker.playCue(.important, channel: .startup)
    speaker.playCue(.attention, channel: .system)

    let deferredCuePlayed = expectation(description: "Cancelled completion does not strand Startup")
    cuePlayer.onPlay = { cue in
      if cue == .attention { deferredCuePlayed.fulfill() }
    }

    XCTAssertEqual(cuePlayer.playedCues, [.attention, .important])
    await fulfillment(of: [deferredCuePlayed], timeout: 2)
    XCTAssertEqual(
      cuePlayer.playedCues,
      [.attention, .important, .attention]
    )
    speaker.stopAll()
  }

  @MainActor
  func testStoppingAllCueOnlyPlaybackDropsDeferredCuesWithoutLateReplay()
    async throws
  {
    let cuePlayer = TestSpokenUpdateCuePlayer(
      attentionDuration: 0.01,
      importantDuration: 0.05
    )
    let speaker = SystemSpokenUpdateSpeaker(
      cuePlayer: cuePlayer,
      startupFollowUpDelay: 0.005
    )

    speaker.playCue(.important, channel: .startup)
    speaker.playCue(.attention, channel: .system)
    speaker.stopAll()

    XCTAssertEqual(speaker.activeCueOnlyPlaybackCount, 0)
    try await Task<Never, Never>.sleep(nanoseconds: 80_000_000)
    XCTAssertEqual(cuePlayer.playedCues, [.important])
    XCTAssertEqual(cuePlayer.stopAllCallCount, 1)
  }

  private func peakAmplitude(
    in samples: [Float],
    from startTime: TimeInterval,
    through endTime: TimeInterval,
    sampleRate: Double
  ) -> Float {
    let start = Int(startTime * sampleRate)
    let end = min(Int(endTime * sampleRate), samples.count)
    return samples[start..<end].map(abs).max() ?? 0
  }
}

@MainActor
private final class TestSpokenUpdateCuePlayer: SpokenUpdateCuePlaying {
  private let attentionDuration: TimeInterval
  private let importantDuration: TimeInterval
  private(set) var playedCues: [SpokenUpdateCue] = []
  private(set) var stopAllCallCount = 0
  var onPlay: ((SpokenUpdateCue) -> Void)?

  init(
    attentionDuration: TimeInterval,
    importantDuration: TimeInterval
  ) {
    self.attentionDuration = attentionDuration
    self.importantDuration = importantDuration
  }

  func play(_ cue: SpokenUpdateCue) -> TimeInterval {
    playedCues.append(cue)
    onPlay?(cue)
    return switch cue {
    case .none: 0
    case .attention: attentionDuration
    case .important: importantDuration
    }
  }

  func stopAll() {
    stopAllCallCount += 1
  }
}
