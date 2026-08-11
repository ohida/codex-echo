@preconcurrency import AVFoundation
import Foundation

let startupAnnouncementFollowUpDelay: TimeInterval = 0.5

struct StartupExclusivePlaybackGate<Item> {
  private enum Phase {
    case open
    case waitingForStartup
    case playingStartup
    case waitingForFollowUpGap
  }

  private var phase = Phase.open
  private var queuedStartups: [Item] = []
  private var deferredItems: [Item] = []

  mutating func enqueue(
    _ item: Item,
    isStartup: Bool,
    playbackIsIdle: Bool
  ) -> [Item] {
    switch phase {
    case .open:
      guard isStartup else { return [item] }
      if playbackIsIdle {
        phase = .playingStartup
        return [item]
      }
      phase = .waitingForStartup
      queuedStartups.append(item)
      return []
    case .waitingForStartup, .playingStartup, .waitingForFollowUpGap:
      if isStartup {
        queuedStartups.append(item)
      } else {
        deferredItems.append(item)
      }
      return []
    }
  }

  mutating func playbackDidBecomeIdle() -> [Item] {
    switch phase {
    case .open:
      return []
    case .waitingForStartup, .playingStartup:
      if !queuedStartups.isEmpty {
        phase = .playingStartup
        return [queuedStartups.removeFirst()]
      }
      phase = .waitingForFollowUpGap
      return []
    case .waitingForFollowUpGap:
      return []
    }
  }

  mutating func startupFollowUpGapDidElapse() -> [Item] {
    guard phase == .waitingForFollowUpGap else { return [] }
    if !queuedStartups.isEmpty {
      phase = .playingStartup
      return [queuedStartups.removeFirst()]
    }
    phase = .open
    let releasedItems = deferredItems
    deferredItems.removeAll()
    return releasedItems
  }

  var isWaitingForFollowUpGap: Bool {
    phase == .waitingForFollowUpGap
  }

  mutating func removeDeferred(
    where shouldRemove: (Item) -> Bool
  ) {
    deferredItems.removeAll(where: shouldRemove)
  }

  mutating func cancelStartup() -> [Item] {
    phase = .open
    queuedStartups.removeAll()
    let releasedItems = deferredItems
    deferredItems.removeAll()
    return releasedItems
  }

  mutating func reset() {
    phase = .open
    queuedStartups.removeAll()
    deferredItems.removeAll()
  }
}

@MainActor
private protocol SpokenUpdateCuePlaying: AnyObject {
  func play(_ cue: SpokenUpdateCue) -> TimeInterval
  func stopAll()
}

struct ImportantAnnouncementCueWaveform {
  private struct Tone {
    let startTime: TimeInterval
    let duration: TimeInterval
    let frequency: Double
  }

  private struct Harmonic {
    let multiple: Int
    let amplitude: Double
  }

  static let sampleRate = 48_000.0
  static let duration: TimeInterval = 0.18
  static let speechDelay: TimeInterval = 0.22
  static let attentionDuration: TimeInterval = 0.07
  static let attentionSpeechDelay: TimeInterval = 0.11
  static let attackTime: TimeInterval = 0.001_5
  static let releaseTime: TimeInterval = 0.006

  private static let tones = [
    Tone(startTime: 0, duration: 0.055, frequency: 1_040),
    Tone(startTime: 0.09, duration: 0.065, frequency: 1_040),
  ]

  private static let harmonics = [
    Harmonic(multiple: 1, amplitude: 0.075),
    Harmonic(multiple: 3, amplitude: 0.03),
    Harmonic(multiple: 5, amplitude: 0.018),
    Harmonic(multiple: 7, amplitude: 0.012),
  ]

  static func samples() -> [Float] {
    let frameCount = Int(duration * sampleRate)
    return (0..<frameCount).map { frame in
      sample(
        at: Double(frame) / sampleRate,
        tones: tones
      )
    }
  }

  static func attentionSamples() -> [Float] {
    let frameCount = Int(attentionDuration * sampleRate)
    return (0..<frameCount).map { frame in
      sample(
        at: Double(frame) / sampleRate,
        tones: Array(tones.prefix(1))
      )
    }
  }

  private static func sample(
    at time: TimeInterval,
    tones: [Tone]
  ) -> Float {
    let value = tones.reduce(0.0) { result, tone in
      let localTime = time - tone.startTime
      guard localTime >= 0, localTime < tone.duration else {
        return result
      }

      let envelope = max(
        0,
        min(
          min(localTime / attackTime, 1),
          (tone.duration - localTime) / releaseTime
        )
      )
      let toneValue = harmonics.reduce(0.0) { partialResult, harmonic in
        partialResult
          + harmonic.amplitude
          * sin(
            2 * Double.pi
              * tone.frequency
              * Double(harmonic.multiple)
              * localTime
          )
      }
      return result + toneValue * envelope
    }
    return Float(value)
  }
}

@MainActor
private final class SystemSpokenUpdateCuePlayer: SpokenUpdateCuePlaying {
  private let engine = AVAudioEngine()
  private let player = AVAudioPlayerNode()
  private let attentionBuffer: AVAudioPCMBuffer?
  private let importantBuffer: AVAudioPCMBuffer?
  private var shutdownTask: Task<Void, Never>?

  init() {
    attentionBuffer = Self.makeBuffer(
      samples: ImportantAnnouncementCueWaveform.attentionSamples()
    )
    importantBuffer = Self.makeBuffer(
      samples: ImportantAnnouncementCueWaveform.samples()
    )
    engine.attach(player)
    if let importantBuffer {
      engine.connect(
        player,
        to: engine.mainMixerNode,
        format: importantBuffer.format
      )
    }
  }

  func play(_ cue: SpokenUpdateCue) -> TimeInterval {
    let buffer: AVAudioPCMBuffer?
    let speechDelay: TimeInterval
    switch cue {
    case .none:
      return 0
    case .attention:
      buffer = attentionBuffer
      speechDelay = ImportantAnnouncementCueWaveform.attentionSpeechDelay
    case .important:
      buffer = importantBuffer
      speechDelay = ImportantAnnouncementCueWaveform.speechDelay
    }
    guard let buffer else { return 0 }
    guard !player.isPlaying else {
      return speechDelay
    }

    player.scheduleBuffer(buffer, at: nil, options: .interrupts)
    if !engine.isRunning {
      engine.prepare()
      do {
        try engine.start()
      } catch {
        player.stop()
        return 0
      }
    }
    player.play()
    scheduleShutdown()
    return speechDelay
  }

  func stopAll() {
    shutdownTask?.cancel()
    shutdownTask = nil
    player.stop()
    engine.stop()
  }

  private func scheduleShutdown() {
    shutdownTask?.cancel()
    shutdownTask = Task { @MainActor [weak self] in
      do {
        try await Task.sleep(for: .milliseconds(250))
      } catch {
        return
      }
      self?.player.stop()
      self?.engine.stop()
      self?.shutdownTask = nil
    }
  }

  private static func makeBuffer(
    samples: [Float]
  ) -> AVAudioPCMBuffer? {
    guard
      let format = AVAudioFormat(
        standardFormatWithSampleRate:
          ImportantAnnouncementCueWaveform.sampleRate,
        channels: 1
      )
    else { return nil }

    guard
      let buffer = AVAudioPCMBuffer(
        pcmFormat: format,
        frameCapacity: AVAudioFrameCount(samples.count)
      ),
      let channel = buffer.floatChannelData?[0]
    else { return nil }

    buffer.frameLength = AVAudioFrameCount(samples.count)
    for (index, sample) in samples.enumerated() {
      channel[index] = sample
    }
    return buffer
  }
}

@MainActor
final class SystemSpokenUpdateSpeaker: NSObject, SpokenUpdateSpeaking,
  AVSpeechSynthesizerDelegate
{
  static let rateMultiplier: Float = 1.08

  private struct ActiveChannel {
    let synthesizer: AVSpeechSynthesizer
    var pendingUtteranceCount: Int
  }

  private struct PlaybackRequest {
    let text: String
    let channel: SpokenUpdateChannel
    let voice: SpokenUpdateVoice
    let cue: SpokenUpdateCue
  }

  private var activeChannels: [SpokenUpdateChannel: ActiveChannel] = [:]
  private var channelsBySynthesizerID: [ObjectIdentifier: SpokenUpdateChannel] = [:]
  private var startupGate = StartupExclusivePlaybackGate<PlaybackRequest>()
  private var startupFollowUpTask: Task<Void, Never>?
  private let cuePlayer: any SpokenUpdateCuePlaying

  override init() {
    cuePlayer = SystemSpokenUpdateCuePlayer()
    super.init()
  }

  func speak(
    _ text: String,
    channel: SpokenUpdateChannel,
    voice: SpokenUpdateVoice,
    cue: SpokenUpdateCue
  ) {
    dispatch(
      startupGate.enqueue(
        PlaybackRequest(
          text: text,
          channel: channel,
          voice: voice,
          cue: cue
        ),
        isStartup: channel == .startup,
        playbackIsIdle: activeChannels.isEmpty
      )
    )
  }

  private func start(_ request: PlaybackRequest) {
    let utterance = AVSpeechUtterance(string: request.text)
    utterance.voice = Self.resolvedVoice(request.voice)
    utterance.rate = AVSpeechUtteranceDefaultSpeechRate * Self.rateMultiplier
    utterance.preUtteranceDelay = cuePlayer.play(request.cue)

    let synthesizer: AVSpeechSynthesizer
    if var activeChannel = activeChannels[request.channel] {
      activeChannel.pendingUtteranceCount += 1
      activeChannels[request.channel] = activeChannel
      synthesizer = activeChannel.synthesizer
    } else {
      synthesizer = AVSpeechSynthesizer()
      synthesizer.delegate = self
      activeChannels[request.channel] = ActiveChannel(
        synthesizer: synthesizer,
        pendingUtteranceCount: 1
      )
      channelsBySynthesizerID[ObjectIdentifier(synthesizer)] =
        request.channel
    }
    synthesizer.speak(utterance)
  }

  private func dispatch(_ requests: [PlaybackRequest]) {
    for request in requests {
      start(request)
    }
  }

  func stopAll() {
    cuePlayer.stopAll()
    startupFollowUpTask?.cancel()
    startupFollowUpTask = nil
    startupGate.reset()
    let synthesizers = activeChannels.values.map(\.synthesizer)
    activeChannels.removeAll()
    channelsBySynthesizerID.removeAll()
    for synthesizer in synthesizers {
      synthesizer.stopSpeaking(at: .immediate)
    }
  }

  func stop(_ channel: SpokenUpdateChannel) {
    startupGate.removeDeferred { $0.channel == channel }
    let activeChannel = activeChannels.removeValue(forKey: channel)
    if let activeChannel {
      channelsBySynthesizerID.removeValue(
        forKey: ObjectIdentifier(activeChannel.synthesizer)
      )
      activeChannel.synthesizer.stopSpeaking(at: .immediate)
    }

    if channel == .startup {
      startupFollowUpTask?.cancel()
      startupFollowUpTask = nil
      dispatch(startupGate.cancelStartup())
    } else if activeChannel != nil, activeChannels.isEmpty {
      advanceStartupGateAfterPlaybackBecameIdle()
    }
  }

  nonisolated func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer,
    didFinish utterance: AVSpeechUtterance
  ) {
    release(synthesizer)
  }

  nonisolated func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer,
    didCancel utterance: AVSpeechUtterance
  ) {
    release(synthesizer)
  }

  nonisolated private func release(_ synthesizer: AVSpeechSynthesizer) {
    let identifier = ObjectIdentifier(synthesizer)
    Task { @MainActor [weak self] in
      self?.finishUtterance(identifier: identifier)
    }
  }

  private func finishUtterance(identifier: ObjectIdentifier) {
    guard let channel = channelsBySynthesizerID[identifier],
      var activeChannel = activeChannels[channel]
    else { return }

    activeChannel.pendingUtteranceCount -= 1
    if activeChannel.pendingUtteranceCount == 0 {
      activeChannels.removeValue(forKey: channel)
      channelsBySynthesizerID.removeValue(forKey: identifier)
      if activeChannels.isEmpty {
        advanceStartupGateAfterPlaybackBecameIdle()
      }
    } else {
      activeChannels[channel] = activeChannel
    }
  }

  private func advanceStartupGateAfterPlaybackBecameIdle() {
    dispatch(startupGate.playbackDidBecomeIdle())
    guard startupGate.isWaitingForFollowUpGap,
      startupFollowUpTask == nil
    else { return }

    startupFollowUpTask = Task { @MainActor [weak self] in
      do {
        try await Task<Never, Never>.sleep(
          nanoseconds: UInt64(
            startupAnnouncementFollowUpDelay * 1_000_000_000
          )
        )
      } catch {
        return
      }
      guard let self else { return }
      self.startupFollowUpTask = nil
      self.dispatch(self.startupGate.startupFollowUpGapDidElapse())
    }
  }

  private static func resolvedVoice(
    _ voice: SpokenUpdateVoice
  ) -> AVSpeechSynthesisVoice? {
    AVSpeechSynthesisVoice.speechVoices().first {
      $0.identifier == voice.identifier
    } ?? AVSpeechSynthesisVoice.speechVoices().first {
      $0.name == voice.displayName && $0.language == "en-US"
    } ?? AVSpeechSynthesisVoice.speechVoices().first {
      $0.identifier == SpokenUpdateVoice.defaultVoice.identifier
    } ?? AVSpeechSynthesisVoice(language: "en-US")
  }
}
