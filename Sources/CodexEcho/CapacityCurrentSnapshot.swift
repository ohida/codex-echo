import CodexAppServer
import Foundation

enum CapacityCurrentAvailabilityState: String, Codable, Equatable, Sendable {
  case available
  case unavailable
}

struct CapacityCurrentAvailability: Codable, Equatable, Sendable {
  private enum CodingKeys: String, CodingKey {
    case state
    case reason
    case changedAt = "changed_at"
  }

  let state: CapacityCurrentAvailabilityState
  let reason: String?
  let changedAt: Date
}

struct CapacityCurrentWindow: Codable, Equatable, Sendable {
  private enum CodingKeys: String, CodingKey {
    case slot
    case windowDurationMinutes = "window_duration_minutes"
    case remainingPercent = "remaining_percent"
    case resetsAt = "resets_at"
  }

  let slot: String
  let windowDurationMinutes: Int?
  let remainingPercent: Int
  let resetsAt: Date?

  init(window: CodexRateLimitWindow) {
    slot = window.slot.rawValue
    windowDurationMinutes = window.windowDurationMinutes
    remainingPercent = window.remainingPercent
    resetsAt = window.resetsAt
  }

  init(
    slot: String,
    windowDurationMinutes: Int?,
    remainingPercent: Int,
    resetsAt: Date?
  ) {
    self.slot = slot
    self.windowDurationMinutes = windowDurationMinutes
    self.remainingPercent = min(max(remainingPercent, 0), 100)
    self.resetsAt = resetsAt
  }
}

struct CapacityCurrentResetCredits: Codable, Equatable, Sendable {
  private enum CodingKeys: String, CodingKey {
    case availableCount = "available_count"
    case expirationDates = "expiration_dates"
  }

  let availableCount: Int
  let expirationDates: [Date]

  init(resetCredits: CodexRateLimitResetCredits) {
    availableCount = resetCredits.availableCount
    expirationDates = resetCredits.expirationDates
  }

  init(availableCount: Int, expirationDates: [Date]) {
    self.availableCount = max(availableCount, 0)
    self.expirationDates = Array(
      expirationDates.prefix(self.availableCount)
    )
  }
}

struct CapacityCurrentCredits: Codable, Equatable, Sendable {
  private enum CodingKeys: String, CodingKey {
    case balance
    case hasCredits = "has_credits"
    case unlimited
    case observedAt = "observed_at"
  }

  let balance: String?
  let hasCredits: Bool
  let unlimited: Bool
  let observedAt: Date

  init(credits: CodexCreditsSnapshot) {
    balance = credits.balance
    hasCredits = credits.hasCredits
    unlimited = credits.unlimited
    observedAt = credits.observedAt
  }
}

struct CapacityCurrentLastSuccess: Codable, Equatable, Sendable {
  private enum CodingKeys: String, CodingKey {
    case observedAt = "observed_at"
    case windows
    case resetCredits = "reset_credits"
    case credits
  }

  let observedAt: Date
  let windows: [CapacityCurrentWindow]
  let resetCredits: CapacityCurrentResetCredits?
  let credits: CapacityCurrentCredits?

  init(snapshot: CodexUsageSnapshot, observedAt: Date) {
    self.observedAt = snapshot.windowsObservedAt ?? observedAt
    windows = snapshot.windows.map(CapacityCurrentWindow.init(window:))
    resetCredits = snapshot.rateLimitResetCredits.map(
      CapacityCurrentResetCredits.init(resetCredits:)
    )
    credits = snapshot.credits.map(CapacityCurrentCredits.init(credits:))
  }

  init(
    observedAt: Date,
    windows: [CapacityCurrentWindow],
    resetCredits: CapacityCurrentResetCredits?,
    credits: CapacityCurrentCredits? = nil
  ) {
    self.observedAt = observedAt
    self.windows = windows
    self.resetCredits = resetCredits
    self.credits = credits
  }
}

struct CapacityCurrentSnapshot: Codable, Equatable, Sendable {
  static let currentSchemaVersion = 1

  private enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case revision
    case availability
    case lastSuccess = "last_success"
    case historyRecordingEnabled = "history_recording_enabled"
  }

  let schemaVersion: Int
  let revision: UInt64
  let availability: CapacityCurrentAvailability
  let lastSuccess: CapacityCurrentLastSuccess?
  let historyRecordingEnabled: Bool

  init(
    schemaVersion: Int = Self.currentSchemaVersion,
    revision: UInt64,
    availability: CapacityCurrentAvailability,
    lastSuccess: CapacityCurrentLastSuccess?,
    historyRecordingEnabled: Bool
  ) {
    self.schemaVersion = schemaVersion
    self.revision = revision
    self.availability = availability
    self.lastSuccess = lastSuccess
    self.historyRecordingEnabled = historyRecordingEnabled
  }
}

enum CapacityCurrentSnapshotStoreError: Error, Equatable {
  case unsupportedSchemaVersion(Int)
}

final class CapacityCurrentSnapshotStore: Sendable {
  let fileURL: URL

  private let queue = DispatchQueue(
    label: "app.ohida.codex-echo.capacity-current-snapshot"
  )
  private let writeDelay: @Sendable (CapacityCurrentSnapshot) -> TimeInterval

  init(
    fileURL: URL = CapacityCurrentSnapshotStore.defaultFileURL(),
    writeDelay: @escaping @Sendable (CapacityCurrentSnapshot) -> TimeInterval = {
      _ in 0
    }
  ) {
    self.fileURL = fileURL
    self.writeDelay = writeDelay
  }

  static func defaultFileURL(
    historyFileURL: URL = CapacityHistoryStore.defaultFileURL()
  ) -> URL {
    historyFileURL.deletingLastPathComponent()
      .appendingPathComponent("current-v1.json")
  }

  func readSynchronously() throws -> CapacityCurrentSnapshot? {
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
      return nil
    }
    let data = try Data(contentsOf: fileURL)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let snapshot = try decoder.decode(CapacityCurrentSnapshot.self, from: data)
    guard snapshot.schemaVersion == CapacityCurrentSnapshot.currentSchemaVersion
    else {
      throw CapacityCurrentSnapshotStoreError.unsupportedSchemaVersion(
        snapshot.schemaVersion
      )
    }
    return snapshot
  }

  func enqueue(_ snapshot: CapacityCurrentSnapshot) {
    queue.async { [fileURL, writeDelay] in
      let delay = max(writeDelay(snapshot), 0)
      if delay > 0 {
        Thread.sleep(forTimeInterval: delay)
      }
      do {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
          at: fileURL.deletingLastPathComponent(),
          withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(snapshot)
        try data.write(to: fileURL, options: .atomic)
      } catch {
        fputs(
          "Codex Echo: failed to write Capacity current snapshot: \(error)\n",
          stderr
        )
      }
    }
  }

  func flushSynchronously() {
    queue.sync {}
  }
}

@MainActor
final class CapacityCurrentSnapshotReducer {
  private(set) var snapshot: CapacityCurrentSnapshot

  private let store: CapacityCurrentSnapshotStore

  init(
    store: CapacityCurrentSnapshotStore,
    historyRecordingEnabled: Bool,
    now: Date = Date()
  ) {
    self.store = store
    if let stored = try? store.readSynchronously() {
      snapshot = stored
    } else {
      snapshot = CapacityCurrentSnapshot(
        revision: 0,
        availability: CapacityCurrentAvailability(
          state: .unavailable,
          reason: "not_observed",
          changedAt: now
        ),
        lastSuccess: nil,
        historyRecordingEnabled: historyRecordingEnabled
      )
    }
    if snapshot.historyRecordingEnabled != historyRecordingEnabled {
      persist(
        availability: snapshot.availability,
        lastSuccess: snapshot.lastSuccess,
        historyRecordingEnabled: historyRecordingEnabled
      )
    }
  }

  func observeConnectionState(
    _ state: CodexAppServerConnectionState,
    observedAt: Date
  ) {
    switch state {
    case .running:
      // A running transport is not enough to make an old usage value current.
      // A successful usage snapshot transitions availability back to available.
      return
    case .stopped:
      recordUnavailable(reason: "app_server_stopped", observedAt: observedAt)
    case .starting:
      recordUnavailable(reason: "app_server_starting", observedAt: observedAt)
    case .failed:
      recordUnavailable(reason: "app_server_failed", observedAt: observedAt)
    }
  }

  func observeUsageSnapshot(
    _ usage: CodexUsageSnapshot,
    observedAt: Date
  ) {
    let availability = availability(
      state: .available,
      reason: nil,
      observedAt: observedAt
    )
    persist(
      availability: availability,
      lastSuccess: CapacityCurrentLastSuccess(
        snapshot: usage,
        observedAt: observedAt
      ),
      historyRecordingEnabled: snapshot.historyRecordingEnabled
    )
  }

  func observeUsageUnavailable(observedAt: Date) {
    recordUnavailable(reason: "usage_unavailable", observedAt: observedAt)
  }

  func setHistoryRecordingEnabled(_ isEnabled: Bool) {
    guard snapshot.historyRecordingEnabled != isEnabled else { return }
    persist(
      availability: snapshot.availability,
      lastSuccess: snapshot.lastSuccess,
      historyRecordingEnabled: isEnabled
    )
  }

  func flushSynchronously() {
    store.flushSynchronously()
  }

  private func recordUnavailable(reason: String, observedAt: Date) {
    let availability = availability(
      state: .unavailable,
      reason: reason,
      observedAt: observedAt
    )
    guard availability != snapshot.availability else { return }
    persist(
      availability: availability,
      lastSuccess: snapshot.lastSuccess,
      historyRecordingEnabled: snapshot.historyRecordingEnabled
    )
  }

  private func availability(
    state: CapacityCurrentAvailabilityState,
    reason: String?,
    observedAt: Date
  ) -> CapacityCurrentAvailability {
    guard
      snapshot.availability.state == state,
      snapshot.availability.reason == reason
    else {
      return CapacityCurrentAvailability(
        state: state,
        reason: reason,
        changedAt: observedAt
      )
    }
    return snapshot.availability
  }

  private func persist(
    availability: CapacityCurrentAvailability,
    lastSuccess: CapacityCurrentLastSuccess?,
    historyRecordingEnabled: Bool
  ) {
    precondition(snapshot.revision < .max, "Capacity snapshot revision exhausted")
    let nextRevision = snapshot.revision + 1
    snapshot = CapacityCurrentSnapshot(
      revision: nextRevision,
      availability: availability,
      lastSuccess: lastSuccess,
      historyRecordingEnabled: historyRecordingEnabled
    )
    store.enqueue(snapshot)
  }
}
