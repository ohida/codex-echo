import Foundation
import MCP

struct CodexCapacityMCPFileDataProvider: CodexCapacityMCPDataProviding {
  private let snapshotFileURL: URL
  private let historyFileURL: URL
  private let now: @Sendable () -> Date

  init(
    snapshotFileURL: URL? = nil,
    historyFileURL: URL? = nil,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    let environment = ProcessInfo.processInfo.environment
    self.snapshotFileURL = snapshotFileURL
      ?? environment["CODEX_ECHO_MCP_CURRENT_SNAPSHOT_FILE"].map(
        URL.init(fileURLWithPath:)
      )
      ?? CapacityCurrentSnapshotStore.defaultFileURL()
    self.historyFileURL = historyFileURL
      ?? environment["CODEX_ECHO_MCP_CAPACITY_HISTORY_FILE"].map(
        URL.init(fileURLWithPath:)
      )
      ?? CapacityHistoryStore.defaultFileURL()
    self.now = now
  }

  func getCodexCapacity() async throws -> CodexCapacityMCPToolResponse {
    try await getCodexCapacity(includeHistory: true)
  }

  func getCodexCapacity(includeHistory: Bool) async throws -> CodexCapacityMCPToolResponse {
    let snapshot = try CapacityCurrentSnapshotStore(
      fileURL: snapshotFileURL
    ).readSynchronously()
    return try await getCodexCapacity(snapshot: snapshot, includeHistory: includeHistory)
  }

  func getCodexCapacity(
    snapshot: CapacityCurrentSnapshot?, includeHistory: Bool
  ) async throws -> CodexCapacityMCPToolResponse {
    let now = now()

    guard let snapshot else {
      var missing: [String: Value] = [
        "source": .object([
          "freshness": .string("missing"),
          "availability": .string("unavailable"),
        ]),
        "windows": .array([]),
      ]
      if includeHistory {
        missing["history"] = historyEnvelope(context: .init(), now: now)
      }
      return CodexCapacityMCPToolResponse(
        structuredContent: .object(missing),
        text: "Codex Capacity has not been observed by Codex Echo yet."
      )
    }

    let lastSuccess = snapshot.lastSuccess
    let hasWindows = lastSuccess?.windows.isEmpty == false
    let age = hasWindows ? lastSuccess.map {
      now.timeIntervalSince($0.observedAt)
    } : nil
    let isFresh = snapshot.availability.state == .available
      && age.map { $0 >= 0 && $0 <= 6 * 60 } == true
    let freshness = !hasWindows ? "missing" : (isFresh ? "fresh" : "stale")
    let contexts: [CapacityMCPHistoryWindowContext] =
      lastSuccess?.windows.compactMap { window in
      guard let duration = window.windowDurationMinutes else { return nil }
      return CapacityMCPHistoryWindowContext(
        slot: window.slot,
        windowDurationMinutes: duration,
        remainingPercent: window.remainingPercent,
        observedAt: lastSuccess?.observedAt ?? now,
        resetsAt: window.resetsAt
      )
      } ?? []
    let context = CapacityMCPHistoryQueryContext(currentWindows: contexts)

    var source: [String: Value] = [
      "freshness": .string(freshness),
      "availability": .string(snapshot.availability.state.rawValue),
      "availability_changed_at": dateValue(snapshot.availability.changedAt),
      "revision": uintValue(snapshot.revision),
      "history_recording_enabled": .bool(snapshot.historyRecordingEnabled),
    ]
    if let reason = snapshot.availability.reason {
      source["availability_reason"] = .string(reason)
    }
    if hasWindows, let lastSuccess {
      source["current_observed_at"] = dateValue(lastSuccess.observedAt)
      source["age_seconds"] = .double(max(now.timeIntervalSince(lastSuccess.observedAt), 0))
    }

    let windows = try lastSuccess?.windows.map { window -> Value in
      var value: [String: Value] = [
        "slot": .string(window.slot),
        "remaining_percent": .int(window.remainingPercent),
      ]
      if let duration = window.windowDurationMinutes {
        value["window_duration_minutes"] = .int(duration)
        let arithmeticContext = CapacityMCPHistoryWindowContext(
          slot: window.slot,
          windowDurationMinutes: duration,
          remainingPercent: window.remainingPercent,
          observedAt: lastSuccess?.observedAt ?? now,
          resetsAt: window.resetsAt
        )
        if let arithmetic = CapacityMCPWindowArithmeticPolicy.make(
          context: arithmeticContext,
          now: now,
          isAvailable: snapshot.availability.state == .available
        ) {
          value["arithmetic"] = try codableValue(arithmetic)
        }
      }
      if let resetsAt = window.resetsAt {
        value["resets_at"] = dateValue(resetsAt)
      }
      return .object(value)
    } ?? []

    var root: [String: Value] = [
      "source": .object(source),
      "windows": .array(windows),
    ]
    if includeHistory {
      root["history"] = historyEnvelope(context: context, now: now)
    }
    if let resetCredits = lastSuccess?.resetCredits {
      root["reset_credits"] = .object([
        "available_count": .int(resetCredits.availableCount),
        "expiration_dates": .array(
          resetCredits.expirationDates.map(dateValue)
        ),
      ])
    }
    if let credits = lastSuccess?.credits {
      let creditsAge = now.timeIntervalSince(credits.observedAt)
      let creditsAreFresh = snapshot.availability.state == .available
        && creditsAge >= 0 && creditsAge <= 6 * 60
      root["credits"] = .object([
        "balance": credits.balance.map(Value.string) ?? .null,
        "has_credits": .bool(credits.hasCredits),
        "unlimited": .bool(credits.unlimited),
        "observed_at": dateValue(credits.observedAt),
        "age_seconds": .double(max(creditsAge, 0)),
        "freshness": .string(creditsAreFresh ? "fresh" : "stale"),
      ])
    }

    let summary = lastSuccess.flatMap { success -> String? in
      let summary = success.windows
        .map { "\($0.slot) \($0.remainingPercent)%" }
        .joined(separator: ", ")
      return summary.isEmpty ? nil : summary
    }
    let creditsSummary = lastSuccess?.credits.map { credits in
      let balance = credits.balance ?? "unknown"
      let status = credits.unlimited ? "unlimited" : balance
      let freshness = root["credits"]?.objectValue?["freshness"]?.stringValue ?? "stale"
      return " Credits: \(status) (\(freshness))."
    } ?? ""
    return CodexCapacityMCPToolResponse(
      structuredContent: .object(root),
      text: (summary.map { "Codex Capacity: \($0) (\(freshness))." }
        ?? "Codex Capacity windows have not been observed.") + creditsSummary
    )
  }

  func queryCodexCapacityHistory(
    arguments: [String: Value]
  ) async throws -> CodexCapacityMCPToolResponse {
    let snapshot = try? CapacityCurrentSnapshotStore(
      fileURL: snapshotFileURL
    ).readSynchronously()
    let context = CapacityMCPHistoryQueryContext(
      currentWindows: snapshot?.lastSuccess?.windows.compactMap { window in
        guard
          let duration = window.windowDurationMinutes,
          let observedAt = snapshot?.lastSuccess?.observedAt
        else { return nil }
        return CapacityMCPHistoryWindowContext(
          slot: window.slot,
          windowDurationMinutes: duration,
          remainingPercent: window.remainingPercent,
          observedAt: observedAt,
          resetsAt: window.resetsAt
        )
      } ?? []
    )
    let request = try queryRequest(from: arguments)

    do {
      let result = try CapacityMCPHistoryQueryEngine(
        fileURL: historyFileURL,
        context: context
      ).query(request, now: now())
      return CodexCapacityMCPToolResponse(
        structuredContent: try historyQueryValue(result),
        text: "Codex Capacity history: \(result.points.count) points across "
          + "\(result.windows.count) windows."
      )
    } catch let error as CapacityMCPHistoryQueryError {
      throw CodexCapacityMCPToolError(
        code: error.code,
        message: error.localizedDescription
      )
    }
  }

  private func historyEnvelope(
    context: CapacityMCPHistoryQueryContext,
    now: Date
  ) -> Value {
    let engine = CapacityMCPHistoryQueryEngine(
      fileURL: historyFileURL,
      context: context
    )
    return .object([
      "current_window": historyResultValue(
        engine: engine,
        request: .init(
          range: .currentWindow,
          resolution: .auto,
          maxPoints: 150
        ),
        now: now
      ),
      "last_24_hours": historyResultValue(
        engine: engine,
        request: .init(
          range: .twentyFourHours,
          resolution: .auto,
          maxPoints: 150
        ),
        now: now
      ),
    ])
  }

  private func historyResultValue(
    engine: CapacityMCPHistoryQueryEngine,
    request: CapacityMCPHistoryQueryRequest,
    now: Date
  ) -> Value {
    do {
      return try historyQueryValue(engine.query(request, now: now))
    } catch let error as CapacityMCPHistoryQueryError {
      return .object([
        "error": .object([
          "code": .string(error.code),
          "message": .string(error.localizedDescription),
        ])
      ])
    } catch {
      writeDiagnostic("Unexpected history summary failure: \(String(reflecting: error))")
      return .object([
        "error": .object([
          "code": .string("history_unavailable"),
          "message": .string("Capacity history could not be read."),
        ])
      ])
    }
  }

  private func queryRequest(
    from arguments: [String: Value]
  ) throws -> CapacityMCPHistoryQueryRequest {
    if let cursor = arguments["cursor"]?.stringValue {
      return .init(cursor: cursor)
    }
    guard
      let rangeRaw = arguments["range"]?.stringValue,
      let range = CapacityMCPHistoryRange(rawValue: rangeRaw),
      let resolutionRaw = arguments["resolution"]?.stringValue,
      let resolution = CapacityMCPHistoryResolution(rawValue: resolutionRaw)
    else {
      throw CodexCapacityMCPToolError.invalidArguments(
        "The normalized history query is invalid."
      )
    }
    return CapacityMCPHistoryQueryRequest(
      windowDurationMinutes: arguments["window_duration_minutes"]?.intValue,
      range: range,
      startAt: try date(from: arguments["start_at"]),
      endAt: try date(from: arguments["end_at"]),
      resolution: resolution,
      maxPoints: arguments["max_points"]?.intValue
    )
  }

  private func date(from value: Value?) throws -> Date? {
    guard let value else { return nil }
    guard let string = value.stringValue else {
      throw CodexCapacityMCPToolError.invalidArguments(
        "Date arguments must be ISO 8601 strings."
      )
    }
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let ordinary = ISO8601DateFormatter()
    ordinary.formatOptions = [.withInternetDateTime]
    guard let date = fractional.date(from: string) ?? ordinary.date(from: string)
    else {
      throw CodexCapacityMCPToolError.invalidArguments(
        "Date arguments must be ISO 8601 strings."
      )
    }
    return date
  }

  private func codableValue<T: Encodable>(_ value: T) throws -> Value {
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(value)
    return try JSONDecoder().decode(Value.self, from: data)
  }

  private func historyQueryValue(
    _ result: CapacityMCPHistoryQueryResult
  ) throws -> Value {
    guard case .object(var object) = try codableValue(result) else {
      throw CodexCapacityMCPToolError(
        code: "internal_error",
        message: "Capacity history could not be encoded."
      )
    }
    object["history_through"] = object["history_through"] ?? .null
    object["next_cursor"] = object["next_cursor"] ?? .null
    return .object(object)
  }

  private func dateValue(_ date: Date) -> Value {
    .string(ISO8601DateFormatter().string(from: date))
  }

  private func uintValue(_ value: UInt64) -> Value {
    value <= UInt64(Int.max) ? .int(Int(value)) : .string(String(value))
  }

  private func writeDiagnostic(_ message: String) {
    guard let data = "Codex Echo MCP: \(message)\n".data(using: .utf8)
    else { return }
    FileHandle.standardError.write(data)
  }
}
