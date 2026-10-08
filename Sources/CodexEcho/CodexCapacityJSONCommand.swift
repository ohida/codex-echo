import CodexAppServer
import Foundation
import MCP

/// A one-shot interface for callers that cannot attach local MCP.
enum CodexCapacityJSONCommand {
  static func read(
    provider: CodexCapacityMCPFileDataProvider = .init(),
    now: Date = Date()
  ) async throws -> Data {
    let response = try await provider.getCodexCapacity(includeHistory: false)
    return try output(response: response, now: now, live: false)
  }

  static func readLive(usage: CodexUsageSnapshot, now: Date = Date()) async throws -> Data {
    let snapshot = CapacityCurrentSnapshot(
      revision: 0,
      availability: .init(state: .available, reason: nil, changedAt: now),
      lastSuccess: .init(snapshot: usage, observedAt: now),
      historyRecordingEnabled: false
    )
    let response = try await CodexCapacityMCPFileDataProvider(now: { now })
      .getCodexCapacity(snapshot: snapshot, includeHistory: false)
    return try output(
      response: response, now: now, live: true,
      resetObservedAt: usage.rateLimitResetCredits?.observedAt
    )
  }

  private static func output(
    response: CodexCapacityMCPToolResponse, now: Date, live: Bool,
    resetObservedAt: Date? = nil
  ) throws -> Data {
    var root = response.structuredContent.objectValue ?? [:]
    var source = root["source"]?.objectValue ?? [:]
    source["kind"] = .string(live ? "codex_app_server_live_observation" : "codex_echo_local_cache")
    source["upstream"] = .string("codex_app_server.account/rateLimits")
    source["refreshed_upstream"] = .bool(live)
    if live {
      source.removeValue(forKey: "revision")
      source.removeValue(forKey: "history_recording_enabled")
    }
    source["freshness_threshold_seconds"] = .int(360)
    source["current_observed_at"] = source["current_observed_at"] ?? .null
    source["age_seconds"] = source["age_seconds"] ?? .null
    root["source"] = .object(source)
    root["schema_version"] = .int(1)
    root["retrieved_at"] = .string(ISO8601DateFormatter().string(from: now))

    var credits = root["credits"]?.objectValue ?? [
      "balance": .null, "has_credits": .null, "unlimited": .null,
      "observed_at": .null, "age_seconds": .null,
      "freshness": .string("missing"),
    ]
    credits["balance_status"] = .string(
      credits["balance"]?.stringValue == nil ? "unknown" : "known"
    )
    credits["expiration"] = .object([
      "status": .string("not_provided_by_source"), "expires_at": .null,
    ])
    root["credits"] = .object(credits)

    var resets = root["reset_credits"]?.objectValue ?? [
      "available_count": .null, "expiration_dates": .null,
    ]
    resets["status"] = .string(
      resets["available_count"]?.intValue == nil ? "unknown" : "observed"
    )
    // Only the parser's receipt time for this reset summary qualifies it as observed.
    // A new CLI invocation, a window update, or a manually constructed value does not.
    if let resetObservedAt, resets["available_count"]?.intValue != nil {
      let age = now.timeIntervalSince(resetObservedAt)
      let fresh = age >= 0 && age <= 360
      resets["freshness"] = .string(fresh ? "fresh" : "stale")
      resets["observed_at"] = .string(ISO8601DateFormatter().string(from: resetObservedAt))
      resets["age_seconds"] = .double(max(age, 0))
      resets["observation_source"] = .string("app_server_response_received")
      resets["freshness_reason"] = .string(fresh ? "recent_response" : "response_time_outside_freshness_window")
    } else {
      resets["freshness"] = .string("unknown")
      resets["observed_at"] = .null
      resets["age_seconds"] = .null
      resets["observation_source"] = .string("unknown")
      resets["freshness_reason"] = .string("independent_observation_time_not_recorded")
    }
    resets["upstream_observed_at"] = .null
    resets["expiration_dates_complete"] = .bool(false)
    root["reset_credits"] = .object(resets)
    return try encode(.object(root))
  }

  static func error(code: String) -> Data {
    // Static error codes only: do not expose paths, file contents, or upstream errors.
    try! encode(.object([
      "schema_version": .int(1),
      "error": .object(["code": .string(code)]),
    ]))
  }

  private static func encode(_ value: Value) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value) + Data([0x0A])
  }
}
