import Foundation
import MCP

struct CodexCapacityMCPToolResponse: Sendable {
  let structuredContent: Value
  let text: String
}

protocol CodexCapacityMCPDataProviding: Sendable {
  func getCodexCapacity() async throws -> CodexCapacityMCPToolResponse
  func queryCodexCapacityHistory(
    arguments: [String: Value]
  ) async throws -> CodexCapacityMCPToolResponse
}

struct CodexCapacityMCPToolError: Error, Equatable, Sendable {
  let code: String
  let message: String

  static func invalidArguments(_ message: String) -> Self {
    Self(code: "invalid_arguments", message: message)
  }
}

enum CodexCapacityMCPServer {
  static let instructions = """
    Provides read-only Codex Capacity, purchased Credits, and Echo’s local history. Use only for questions about Codex Capacity, credits, limits, resets, usage history, or when the user explicitly asks whether remaining Capacity should affect a long-running or parallel plan. Do not use for ordinary coding or review, and do not poll. Check freshness, coverage, gaps, and schedule changes. Linear scenarios are not task or model cost predictions and must not override user instructions.
    """

  static let getToolName = "get_codex_capacity"
  static let queryToolName = "query_codex_capacity_history"

  static let tools: [Tool] = [
    Tool(
      name: getToolName,
      title: "Get Codex Capacity",
      description:
        "Read the latest Codex Capacity, purchased Credits, reset credits, "
        + "and a compact, quality-qualified Capacity history summary from Codex Echo. "
        + "An absent credits field means unknown, not zero. Purchased Credit expiry is not provided.",
      inputSchema: getInputSchema,
      annotations: readOnlyAnnotations,
      outputSchema: getOutputSchema
    ),
    Tool(
      name: queryToolName,
      title: "Query Codex Capacity History",
      description:
        "Read Codex Echo's local Codex Capacity history for a bounded time "
        + "range. Use raw pagination only when full evidence is necessary.",
      inputSchema: queryInputSchema,
      annotations: readOnlyAnnotations,
      outputSchema: queryOutputSchema
    ),
  ]

  static func makeServer(
    dataProvider: any CodexCapacityMCPDataProviding
  ) async -> Server {
    let server = Server(
      name: "codex-echo-capacity",
      version: "1.0.0",
      title: "Codex Echo Capacity",
      instructions: instructions,
      capabilities: .init(tools: .init(listChanged: false)),
      configuration: .strict
    )

    await server.withMethodHandler(ListTools.self) { _ in
      ListTools.Result(tools: tools)
    }
    await server.withMethodHandler(CallTool.self) { parameters in
      await callTool(parameters, dataProvider: dataProvider)
    }
    return server
  }

  static func runStdio(
    dataProvider: any CodexCapacityMCPDataProviding =
      CodexCapacityMCPFileDataProvider()
  ) async throws {
    let server = await makeServer(dataProvider: dataProvider)
    let transport = StdioTransport()
    try await server.start(transport: transport)
    await server.waitUntilCompleted()
  }

  static func validatedQueryArguments(
    _ arguments: [String: Value]?
  ) throws -> [String: Value] {
    let arguments = arguments ?? [:]
    let allowedKeys: Set<String> = [
      "cursor",
      "window_duration_minutes",
      "range",
      "start_at",
      "end_at",
      "resolution",
      "max_points",
    ]
    let unknownKeys = Set(arguments.keys).subtracting(allowedKeys)
    guard unknownKeys.isEmpty else {
      throw CodexCapacityMCPToolError.invalidArguments(
        "Unknown argument(s): \(unknownKeys.sorted().joined(separator: ", "))."
      )
    }

    if let cursorValue = arguments["cursor"] {
      guard arguments.count == 1 else {
        throw CodexCapacityMCPToolError.invalidArguments(
          "cursor must be the only argument when continuing a raw query."
        )
      }
      guard
        let cursor = cursorValue.stringValue,
        !cursor.isEmpty,
        cursor.utf8.count <= 16_384
      else {
        throw CodexCapacityMCPToolError.invalidArguments(
          "cursor must be a non-empty string of at most 16384 bytes."
        )
      }
      return ["cursor": .string(cursor)]
    }

    if let duration = arguments["window_duration_minutes"] {
      guard let minutes = duration.intValue, minutes > 0 else {
        throw CodexCapacityMCPToolError.invalidArguments(
          "window_duration_minutes must be a positive integer."
        )
      }
    }

    let range = arguments["range"]?.stringValue ?? "24h"
    guard ["current_window", "24h", "7d", "30d", "custom"].contains(range)
    else {
      throw CodexCapacityMCPToolError.invalidArguments(
        "range must be current_window, 24h, 7d, 30d, or custom."
      )
    }

    let resolution = arguments["resolution"]?.stringValue ?? "auto"
    guard ["auto", "raw"].contains(resolution) else {
      throw CodexCapacityMCPToolError.invalidArguments(
        "resolution must be auto or raw."
      )
    }

    if let maxPoints = arguments["max_points"] {
      guard let count = maxPoints.intValue, (10...1_000).contains(count) else {
        throw CodexCapacityMCPToolError.invalidArguments(
          "max_points must be an integer from 10 through 1000."
        )
      }
    }

    let startAt = try parseDateArgument("start_at", from: arguments)
    let endAt = try parseDateArgument("end_at", from: arguments)
    if range == "custom" {
      guard let startAt, let endAt else {
        throw CodexCapacityMCPToolError.invalidArguments(
          "custom range requires both start_at and end_at."
        )
      }
      guard startAt < endAt else {
        throw CodexCapacityMCPToolError.invalidArguments(
          "start_at must be earlier than end_at."
        )
      }
    } else if startAt != nil || endAt != nil {
      throw CodexCapacityMCPToolError.invalidArguments(
        "start_at and end_at are only valid with range custom."
      )
    }

    var normalized = arguments
    normalized["range"] = .string(range)
    normalized["resolution"] = .string(resolution)
    normalized["max_points"] = normalized["max_points"] ?? .int(300)
    return normalized
  }

  private static func callTool(
    _ parameters: CallTool.Parameters,
    dataProvider: any CodexCapacityMCPDataProviding
  ) async -> CallTool.Result {
    do {
      let response: CodexCapacityMCPToolResponse
      switch parameters.name {
      case getToolName:
        guard parameters.arguments?.isEmpty ?? true else {
          throw CodexCapacityMCPToolError.invalidArguments(
            "get_codex_capacity does not accept arguments."
          )
        }
        response = try await dataProvider.getCodexCapacity()
      case queryToolName:
        let arguments = try validatedQueryArguments(parameters.arguments)
        response = try await dataProvider.queryCodexCapacityHistory(
          arguments: arguments
        )
      default:
        throw CodexCapacityMCPToolError(
          code: "unknown_tool",
          message: "Unknown tool: \(parameters.name)."
        )
      }
      return CallTool.Result(
        content: [.text(text: response.text, annotations: nil, _meta: nil)],
        structuredContent: Optional<Value>.some(
          try addingSchemaVersion(to: response.structuredContent)
        )
      )
    } catch let error as CodexCapacityMCPToolError {
      return errorResult(error)
    } catch {
      writeDiagnostic("Unexpected tool failure: \(String(reflecting: error))")
      return errorResult(
        CodexCapacityMCPToolError(
          code: "internal_error",
          message: "Codex Capacity data could not be read."
        )
      )
    }
  }

  private static func addingSchemaVersion(to value: Value) throws -> Value {
    guard case .object(var object) = value else {
      throw MCPResponseEncodingError.expectedObject
    }
    object["schema_version"] = .int(1)
    return .object(object)
  }

  private static func errorResult(
    _ error: CodexCapacityMCPToolError
  ) -> CallTool.Result {
    let structuredContent: Value = .object([
      "schema_version": .int(1),
      "error": .object([
        "code": .string(error.code),
        "message": .string(error.message),
      ]),
    ])
    return CallTool.Result(
      content: [.text(text: error.message, annotations: nil, _meta: nil)],
      structuredContent: Optional<Value>.some(structuredContent),
      isError: true
    )
  }

  private static func parseDateArgument(
    _ name: String,
    from arguments: [String: Value]
  ) throws -> Date? {
    guard let value = arguments[name] else { return nil }
    guard let string = value.stringValue else {
      throw CodexCapacityMCPToolError.invalidArguments(
        "\(name) must be an ISO 8601 date-time string."
      )
    }
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let ordinary = ISO8601DateFormatter()
    ordinary.formatOptions = [.withInternetDateTime]
    guard fractional.date(from: string) != nil || ordinary.date(from: string) != nil
    else {
      throw CodexCapacityMCPToolError.invalidArguments(
        "\(name) must be an ISO 8601 date-time string."
      )
    }
    return fractional.date(from: string) ?? ordinary.date(from: string)
  }

  private static func writeDiagnostic(_ message: String) {
    guard let data = "Codex Echo MCP: \(message)\n".data(using: .utf8)
    else { return }
    FileHandle.standardError.write(data)
  }

  private static let readOnlyAnnotations = Tool.Annotations(
    readOnlyHint: true,
    destructiveHint: false,
    idempotentHint: true,
    openWorldHint: false
  )

  private static let getInputSchema: Value = .object([
    "type": .string("object"),
    "properties": .object([:]),
    "additionalProperties": .bool(false),
  ])

  private static let queryInputSchema: Value = .object([
    "type": .string("object"),
    "properties": .object([
      "cursor": .object([
        "type": .string("string"),
        "minLength": .int(1),
        "maxLength": .int(16_384),
      ]),
      "window_duration_minutes": .object([
        "type": .string("integer"),
        "minimum": .int(1),
      ]),
      "range": .object([
        "type": .string("string"),
        "enum": .array(
          ["current_window", "24h", "7d", "30d", "custom"].map(
            Value.string
          )
        ),
        "default": .string("24h"),
      ]),
      "start_at": .object([
        "type": .string("string"),
        "format": .string("date-time"),
      ]),
      "end_at": .object([
        "type": .string("string"),
        "format": .string("date-time"),
      ]),
      "resolution": .object([
        "type": .string("string"),
        "enum": .array([.string("auto"), .string("raw")]),
        "default": .string("auto"),
      ]),
      "max_points": .object([
        "type": .string("integer"),
        "minimum": .int(10),
        "maximum": .int(1_000),
        "default": .int(300),
      ]),
    ]),
    "additionalProperties": .bool(false),
    "oneOf": .array([
      .object([
        "required": .array([.string("cursor")]),
        "maxProperties": .int(1),
      ]),
      .object([
        "not": .object([
          "required": .array([.string("cursor")])
        ])
      ]),
    ]),
    "allOf": .array([
      .object([
        "if": .object([
          "properties": .object([
            "range": .object(["const": .string("custom")])
          ]),
          "required": .array([.string("range")]),
        ]),
        "then": .object([
          "required": .array([.string("start_at"), .string("end_at")])
        ]),
        "else": .object([
          "not": .object([
            "anyOf": .array([
              .object(["required": .array([.string("start_at")])]),
              .object(["required": .array([.string("end_at")])]),
            ])
          ])
        ]),
      ])
    ]),
  ])

  private static let errorOutputVariant: Value = .object([
    "type": .string("object"),
    "properties": .object([
      "schema_version": .object(["const": .int(1)]),
      "error": .object([
        "type": .string("object"),
        "properties": .object([
          "code": .object(["type": .string("string")]),
          "message": .object(["type": .string("string")]),
        ]),
        "required": .array([.string("code"), .string("message")]),
        "additionalProperties": .bool(false),
      ]),
    ]),
    "required": .array([.string("schema_version"), .string("error")]),
    "additionalProperties": .bool(false),
  ])

  private static let sourceSchema: Value = .object([
    "type": .string("object"),
    "properties": .object([
      "freshness": .object([
        "type": .string("string"),
        "enum": .array(["fresh", "stale", "missing"].map(Value.string)),
      ]),
      "availability": .object([
        "type": .string("string"),
        "enum": .array(["available", "unavailable"].map(Value.string)),
      ]),
      "availability_changed_at": dateTimeSchema,
      "availability_reason": .object(["type": .string("string")]),
      "current_observed_at": dateTimeSchema,
      "age_seconds": .object([
        "type": .string("number"),
        "minimum": .int(0),
      ]),
      "revision": .object([
        "type": .array([.string("integer"), .string("string")])
      ]),
      "history_recording_enabled": .object(["type": .string("boolean")]),
    ]),
    "required": .array([.string("freshness"), .string("availability")]),
    "additionalProperties": .bool(false),
  ])

  private static let arithmeticSchema: Value = .object([
    "type": .string("object"),
    "properties": .object([
      "window_started_at": dateTimeSchema,
      "progress_ratio": .object(["type": .string("number")]),
      "expected_remaining_percent": .object(["type": .string("number")]),
      "remaining_vs_even_pace_points": .object(["type": .string("number")]),
      "linear_scenario": .object([
        "type": .string("object"),
        "properties": .object([
          "basis": .object([
            "const": .string("net_consumption_since_inferred_window_start")
          ]),
          "assumption": .object([
            "const": .string("same_average_net_consumption_continues")
          ]),
          "depletion_at": nullableDateTimeSchema,
          "remaining_at_reset": .object([
            "type": .array([.string("number"), .string("null")])
          ]),
        ]),
        "required": .array([.string("basis"), .string("assumption")]),
        "additionalProperties": .bool(false),
      ]),
    ]),
    "required": .array([
      .string("window_started_at"),
      .string("progress_ratio"),
      .string("expected_remaining_percent"),
      .string("remaining_vs_even_pace_points"),
    ]),
    "additionalProperties": .bool(false),
  ])

  private static let currentWindowSchema: Value = .object([
    "type": .string("object"),
    "properties": .object([
      "slot": .object(["type": .string("string")]),
      "window_duration_minutes": .object([
        "type": .string("integer"),
        "minimum": .int(1),
      ]),
      "remaining_percent": .object([
        "type": .string("integer"),
        "minimum": .int(0),
        "maximum": .int(100),
      ]),
      "resets_at": dateTimeSchema,
      "arithmetic": arithmeticSchema,
    ]),
    "required": .array([.string("slot"), .string("remaining_percent")]),
    "additionalProperties": .bool(false),
  ])

  private static let historySummarySchema: Value = .object([
    "type": .string("object"),
    "properties": .object([
      "observed_decrease_points": .object(["type": .string("integer")]),
      "observed_increase_points": .object(["type": .string("integer")]),
      "observed_seconds": .object(["type": .string("number")]),
      "requested_seconds": .object(["type": .string("number")]),
      "coverage_ratio": .object(["type": .string("number")]),
      "gap_count": .object(["type": .string("integer")]),
      "reset_schedule_change_count": .object(["type": .string("integer")]),
      "source_point_count": .object(["type": .string("integer")]),
      "returned_point_count": .object(["type": .string("integer")]),
    ]),
    "required": .array([
      .string("observed_decrease_points"), .string("observed_increase_points"),
      .string("observed_seconds"), .string("requested_seconds"),
      .string("coverage_ratio"), .string("gap_count"),
      .string("reset_schedule_change_count"), .string("source_point_count"),
      .string("returned_point_count"),
    ]),
    "additionalProperties": .bool(false),
  ])

  private static let historyWindowSchema: Value = .object([
    "type": .string("object"),
    "properties": .object([
      "slot": .object([
        "type": .array([.string("string"), .string("null")])
      ]),
      "window_duration_minutes": .object(["type": .string("integer")]),
      "identity_status": .object([
        "type": .string("string"),
        "enum": .array(
          [
            "matched_slot", "legacy_duration_only", "ambiguous_window_identity",
          ].map(Value.string)
        ),
      ]),
      "range_start": dateTimeSchema,
      "range_end": dateTimeSchema,
      "summary": historySummarySchema,
    ]),
    "required": .array([
      .string("window_duration_minutes"), .string("identity_status"),
      .string("range_start"), .string("range_end"), .string("summary"),
    ]),
    "additionalProperties": .bool(false),
  ])

  private static let historyPointSchema: Value = .object([
    "type": .string("object"),
    "properties": .object([
      "observed_at": dateTimeSchema,
      "remaining_percent": .object(["type": .string("integer")]),
      "window_duration_minutes": .object(["type": .string("integer")]),
      "gap_before": .object(["type": .string("boolean")]),
      "is_increase": .object(["type": .string("boolean")]),
      "reset_schedule_changed": .object(["type": .string("boolean")]),
    ]),
    "required": .array([
      .string("observed_at"), .string("remaining_percent"),
      .string("window_duration_minutes"), .string("gap_before"),
      .string("is_increase"), .string("reset_schedule_changed"),
    ]),
    "additionalProperties": .bool(false),
  ])

  private static let querySuccessVariant: Value = .object([
    "type": .string("object"),
    "properties": .object([
      "schema_version": .object(["const": .int(1)]),
      "history_status": .object([
        "type": .string("string"),
        "enum": .array([.string("available"), .string("missing")]),
      ]),
      "history_through": nullableDateTimeSchema,
      "analysis_cutoff": dateTimeSchema,
      "windows": .object([
        "type": .string("array"),
        "items": historyWindowSchema,
      ]),
      "points": .object([
        "type": .string("array"),
        "items": historyPointSchema,
      ]),
      "truncated": .object(["type": .string("boolean")]),
      "omitted_event_points": .object(["type": .string("integer")]),
      "next_cursor": .object([
        "type": .array([.string("string"), .string("null")])
      ]),
    ]),
    "required": .array([
      .string("schema_version"), .string("history_status"),
      .string("history_through"), .string("analysis_cutoff"),
      .string("windows"), .string("points"), .string("truncated"),
      .string("omitted_event_points"), .string("next_cursor"),
    ]),
    "additionalProperties": .bool(false),
  ])

  private static let historyEnvelopeResultSchema: Value = .object([
    "oneOf": .array([
      querySuccessVariant,
      .object([
        "type": .string("object"),
        "properties": .object([
          "error": errorOutputVariant.objectValue?["properties"]?
            .objectValue?["error"] ?? .object([:])
        ]),
        "required": .array([.string("error")]),
        "additionalProperties": .bool(false),
      ]),
    ])
  ])

  private static let getSuccessVariant: Value = .object([
    "type": .string("object"),
    "properties": .object([
      "schema_version": .object(["const": .int(1)]),
      "source": sourceSchema,
      "credits": .object([
        "type": .string("object"),
        "description": .string(
          "Purchased Credits, separate from reset_credits. Balance is an exact "
            + "upstream string or null when unknown; expiry is not provided. "
            + "Check this object's freshness independently of Capacity windows."
        ),
        "properties": .object([
          "balance": .object(["type": .array([.string("string"), .string("null")])]),
          "has_credits": .object(["type": .string("boolean")]),
          "unlimited": .object(["type": .string("boolean")]),
          "observed_at": dateTimeSchema,
          "age_seconds": .object(["type": .string("number"), "minimum": .int(0)]),
          "freshness": .object(["enum": .array([.string("fresh"), .string("stale")])]),
        ]),
        "required": .array([
          .string("balance"), .string("has_credits"), .string("unlimited"),
          .string("observed_at"), .string("age_seconds"), .string("freshness"),
        ]),
        "additionalProperties": .bool(false),
      ]),
      "reset_credits": .object([
        "type": .string("object"),
        "properties": .object([
          "available_count": .object(["type": .string("integer")]),
          "expiration_dates": .object([
            "type": .string("array"),
            "items": dateTimeSchema,
          ]),
        ]),
        "required": .array([
          .string("available_count"), .string("expiration_dates")
        ]),
        "additionalProperties": .bool(false),
      ]),
      "windows": .object([
        "type": .string("array"),
        "items": currentWindowSchema,
      ]),
      "history": .object([
        "type": .string("object"),
        "properties": .object([
          "current_window": historyEnvelopeResultSchema,
          "last_24_hours": historyEnvelopeResultSchema,
        ]),
        "required": .array([
          .string("current_window"), .string("last_24_hours")
        ]),
        "additionalProperties": .bool(false),
      ]),
    ]),
    "required": .array([
      .string("schema_version"), .string("source"), .string("windows"),
      .string("history"),
    ]),
    "additionalProperties": .bool(false),
  ])

  private static let getOutputSchema: Value = .object([
    "oneOf": .array([getSuccessVariant, errorOutputVariant])
  ])

  private static let queryOutputSchema: Value = .object([
    "oneOf": .array([querySuccessVariant, errorOutputVariant])
  ])

  private static let dateTimeSchema: Value = .object([
    "type": .string("string"),
    "format": .string("date-time"),
  ])

  private static let nullableDateTimeSchema: Value = .object([
    "type": .array([.string("string"), .string("null")]),
    "format": .string("date-time"),
  ])
}

private enum MCPResponseEncodingError: Error {
  case expectedObject
}
