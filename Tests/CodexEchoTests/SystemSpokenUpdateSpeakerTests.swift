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
