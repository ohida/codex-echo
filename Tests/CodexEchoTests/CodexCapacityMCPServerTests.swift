import Foundation
import CodexAppServer
import MCP
@testable import CodexEcho
import XCTest

final class CodexCapacityMCPServerTests: XCTestCase {
  func testLaunchModeSelectsMCPBeforeCreatingTheApp() {
    XCTAssertEqual(
      CodexEchoLaunchMode.resolve(arguments: ["CodexEcho", "--mcp-stdio"]),
      .mcpStdio
    )
    XCTAssertEqual(
      CodexEchoLaunchMode.resolve(arguments: ["CodexEcho"]),
      .app
    )
  }

  func testToolsPublishClosedReadOnlySchemas() throws {
    XCTAssertLessThanOrEqual(
      CodexCapacityMCPServer.instructions.utf8.count,
      512
    )
    XCTAssertEqual(
      CodexCapacityMCPServer.tools.map(\.name),
      ["get_codex_capacity", "query_codex_capacity_history"]
    )

    for tool in CodexCapacityMCPServer.tools {
      XCTAssertEqual(tool.annotations.readOnlyHint, true)
      XCTAssertEqual(tool.annotations.destructiveHint, false)
      XCTAssertEqual(tool.annotations.idempotentHint, true)
      XCTAssertEqual(tool.annotations.openWorldHint, false)
      XCTAssertNotNil(tool.outputSchema)
      XCTAssertEqual(
        tool.inputSchema.objectValue?["additionalProperties"]?.boolValue,
        false
      )
      XCTAssertEqual(tool.outputSchema?.objectValue?["oneOf"]?.arrayValue?.count, 2)
      XCTAssertEqual(
        tool.outputSchema?.objectValue?["oneOf"]?.arrayValue?.first?
          .objectValue?["additionalProperties"]?.boolValue,
        false
      )
    }

    let query = try XCTUnwrap(CodexCapacityMCPServer.tools.last)
    let queryProperties = try XCTUnwrap(
      query.inputSchema.objectValue?["properties"]?.objectValue
    )
    XCTAssertEqual(
      Set(queryProperties.keys),
      [
        "cursor", "window_duration_minutes", "range", "start_at", "end_at",
        "resolution", "max_points",
      ]
    )
    XCTAssertNotNil(query.inputSchema.objectValue?["oneOf"])
  }

  func testQueryValidationDefaultsAndEnforcesCursorExclusivity() throws {
    let normalized = try CodexCapacityMCPServer.validatedQueryArguments([:])
    XCTAssertEqual(normalized["range"], .string("24h"))
    XCTAssertEqual(normalized["resolution"], .string("auto"))
    XCTAssertEqual(normalized["max_points"], .int(300))

    XCTAssertThrowsError(
      try CodexCapacityMCPServer.validatedQueryArguments([
        "cursor": .string("next"),
        "range": .string("24h"),
      ])
    )
    XCTAssertThrowsError(
      try CodexCapacityMCPServer.validatedQueryArguments([
        "range": .string("custom"),
        "start_at": .string("2026-08-20T00:00:00Z"),
      ])
    )
    XCTAssertThrowsError(
      try CodexCapacityMCPServer.validatedQueryArguments([
        "unknown": .bool(true)
      ])
    )
    let invalidQueries: [[String: Value]] = [
      ["cursor": .string("")],
      ["cursor": .string(String(repeating: "x", count: 16_385))],
      ["cursor": .int(1)],
      ["window_duration_minutes": .int(0)],
      ["range": .string("cycle")],
      ["resolution": .string("full")],
      ["max_points": .int(9)],
      ["max_points": .int(1_001)],
      ["range": .string("24h"), "start_at": .string("2026-08-20T00:00:00Z")],
      [
        "range": .string("custom"),
        "start_at": .string("2026-08-21T00:00:00Z"),
        "end_at": .string("2026-08-20T00:00:00Z"),
      ],
      [
        "range": .string("custom"),
        "start_at": .string("not-a-date"),
        "end_at": .string("2026-08-20T00:00:00Z"),
      ],
    ]
    for invalid in invalidQueries {
      XCTAssertThrowsError(
        try CodexCapacityMCPServer.validatedQueryArguments(invalid)
      )
    }
  }

  func testServerRoundTripReturnsStructuredContentAndStableErrors() async throws {
    let provider = StubProvider()
    let server = await CodexCapacityMCPServer.makeServer(
      dataProvider: provider
    )
    let transports = await InMemoryTransport.createConnectedPair()
    try await server.start(transport: transports.server)
    let client = Client(name: "CodexEchoTests", version: "1.0.0")
    _ = try await client.connect(transport: transports.client)
    defer {
      Task {
        await client.disconnect()
        await server.stop()
      }
    }

    let listed = try await client.listTools()
    XCTAssertEqual(listed.tools.map(\.name), CodexCapacityMCPServer.tools.map(\.name))

    let getContext: RequestContext<CallTool.Result> = try await client.callTool(
      name: CodexCapacityMCPServer.getToolName
    )
    let getResult = try await getContext.value
    XCTAssertNotEqual(getResult.isError, true)
    XCTAssertEqual(
      getResult.structuredContent?.objectValue?["schema_version"],
      .int(1)
    )
    XCTAssertEqual(
      getResult.structuredContent?.objectValue?["source"]?
        .objectValue?["freshness"],
      .string("fresh")
    )

    let invalidContext: RequestContext<CallTool.Result> = try await client.callTool(
      name: CodexCapacityMCPServer.getToolName,
      arguments: ["unexpected": .bool(true)]
    )
    let invalidResult = try await invalidContext.value
    XCTAssertEqual(invalidResult.isError, true)
    XCTAssertEqual(
      invalidResult.structuredContent?.objectValue?["error"]?
        .objectValue?["code"],
      .string("invalid_arguments")
    )
  }

  func testStdioProcessServesToolsAndExitsOnlyAfterEOF() throws {
    let executableURL = try codexEchoExecutableURL()
    let temporaryDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: temporaryDirectory,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

    let observedAt = Date()
    let snapshotStore = CapacityCurrentSnapshotStore(
      fileURL: temporaryDirectory.appendingPathComponent("current-v1.json")
    )
    snapshotStore.enqueue(.init(
      revision: 1,
      availability: .init(state: .available, reason: nil, changedAt: observedAt),
      lastSuccess: .init(snapshot: .init(
        usedPercent: 45,
        credits: .init(balance: "62500.25", hasCredits: true, unlimited: false,
          observedAt: observedAt)
      ), observedAt: observedAt),
      historyRecordingEnabled: false
    ))
    snapshotStore.flushSynchronously()

    let process = Process()
    let input = Pipe()
    let output = Pipe()
    let diagnostics = Pipe()
    process.executableURL = executableURL
    process.arguments = ["--mcp-stdio"]
    process.standardInput = input
    process.standardOutput = output
    process.standardError = diagnostics
    var environment = ProcessInfo.processInfo.environment
    environment["CODEX_ECHO_MCP_CURRENT_SNAPSHOT_FILE"] = temporaryDirectory
      .appendingPathComponent("current-v1.json").path
    environment["CODEX_ECHO_MCP_CAPACITY_HISTORY_FILE"] = temporaryDirectory
      .appendingPathComponent("v1.jsonl").path
    process.environment = environment
    try process.run()

    try writeJSONLine(
      [
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": [
          "protocolVersion": Version.latest,
          "capabilities": [:],
          "clientInfo": ["name": "process-test", "version": "1.0"],
        ],
      ],
      to: input.fileHandleForWriting
    )
    let initialize = try readJSONLine(from: output.fileHandleForReading)
    XCTAssertEqual(initialize["id"] as? Int, 1)
    XCTAssertEqual(
      ((initialize["result"] as? [String: Any])?["serverInfo"]
        as? [String: Any])?["name"] as? String,
      "codex-echo-capacity"
    )
    XCTAssertEqual(
      (initialize["result"] as? [String: Any])?["instructions"] as? String,
      CodexCapacityMCPServer.instructions
    )

    try writeJSONLine(
      ["jsonrpc": "2.0", "method": "notifications/initialized"],
      to: input.fileHandleForWriting
    )
    try writeJSONLine(
      ["jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": [:]],
      to: input.fileHandleForWriting
    )
    let list = try readJSONLine(from: output.fileHandleForReading)
    let listedTools = ((list["result"] as? [String: Any])?["tools"]
      as? [[String: Any]]) ?? []
    XCTAssertEqual(
      listedTools.compactMap { $0["name"] as? String },
      ["get_codex_capacity", "query_codex_capacity_history"]
    )

    try writeJSONLine(
      [
        "jsonrpc": "2.0",
        "id": 3,
        "method": "tools/call",
        "params": ["name": "get_codex_capacity", "arguments": [:]],
      ],
      to: input.fileHandleForWriting
    )
    let call = try readJSONLine(from: output.fileHandleForReading)
    let structured = (call["result"] as? [String: Any])?["structuredContent"]
      as? [String: Any]
    XCTAssertEqual(structured?["schema_version"] as? Int, 1)
    let credits = try XCTUnwrap(structured?["credits"] as? [String: Any])
    XCTAssertEqual(credits["balance"] as? String, "62500.25")
    XCTAssertEqual(credits["has_credits"] as? Bool, true)
    XCTAssertEqual(credits["unlimited"] as? Bool, false)
    XCTAssertEqual(credits["freshness"] as? String, "fresh")
    XCTAssertTrue(process.isRunning)

    try writeJSONLine(
      [
        "jsonrpc": "2.0",
        "id": 4,
        "method": "tools/call",
        "params": [
          "name": "get_codex_capacity",
          "arguments": ["unexpected": true],
        ],
      ],
      to: input.fileHandleForWriting
    )
    let invalidCall = try readJSONLine(from: output.fileHandleForReading)
    XCTAssertEqual(
      (invalidCall["result"] as? [String: Any])?["isError"] as? Bool,
      true
    )
    XCTAssertTrue(process.isRunning)

    try writeJSONLine(
      [
        "jsonrpc": "2.0",
        "id": 5,
        "method": "tools/call",
        "params": ["name": "get_codex_capacity", "arguments": [:]],
      ],
      to: input.fileHandleForWriting
    )
    let recoveredCall = try readJSONLine(from: output.fileHandleForReading)
    XCTAssertEqual(recoveredCall["id"] as? Int, 5)
    XCTAssertNil((recoveredCall["result"] as? [String: Any])?["isError"])
    XCTAssertTrue(process.isRunning)

    let exited = expectation(description: "MCP process exits on stdin EOF")
    process.terminationHandler = { _ in exited.fulfill() }
    try input.fileHandleForWriting.close()
    wait(for: [exited], timeout: 5)
    XCTAssertEqual(process.terminationStatus, 0)
    XCTAssertEqual(
      diagnostics.fileHandleForReading.readDataToEndOfFile().count,
      0
    )
  }

  private func codexEchoExecutableURL() throws -> URL {
    let productsDirectory = Bundle(for: Self.self).bundleURL
      .deletingLastPathComponent()
    let executableURL = productsDirectory.appendingPathComponent("CodexEcho")
    guard FileManager.default.isExecutableFile(atPath: executableURL.path)
    else {
      throw XCTSkip("CodexEcho executable is unavailable at \(executableURL.path)")
    }
    return executableURL
  }

  private func writeJSONLine(
    _ object: [String: Any],
    to handle: FileHandle
  ) throws {
    var data = try JSONSerialization.data(withJSONObject: object)
    data.append(0x0A)
    try handle.write(contentsOf: data)
  }

  private func readJSONLine(from handle: FileHandle) throws -> [String: Any] {
    var line = Data()
    while true {
      guard let next = try handle.read(upToCount: 1), !next.isEmpty else {
        XCTFail("MCP process closed stdout before returning a response")
        return [:]
      }
      if next.first == 0x0A { break }
      line.append(next)
    }
    return try XCTUnwrap(
      JSONSerialization.jsonObject(with: line) as? [String: Any]
    )
  }
}

private struct StubProvider: CodexCapacityMCPDataProviding {
  func getCodexCapacity() async throws -> CodexCapacityMCPToolResponse {
    CodexCapacityMCPToolResponse(
      structuredContent: .object([
        "source": .object([
          "freshness": .string("fresh"),
          "availability": .string("available"),
        ]),
        "windows": .array([]),
        "history": .object([
          "current_window": emptyHistory,
          "last_24_hours": emptyHistory,
        ]),
      ]),
      text: "Codex Capacity is fresh."
    )
  }

  func queryCodexCapacityHistory(
    arguments: [String: Value]
  ) async throws -> CodexCapacityMCPToolResponse {
    CodexCapacityMCPToolResponse(
      structuredContent: emptyHistory,
      text: "No Capacity history points."
    )
  }

  private var emptyHistory: Value {
    .object([
      "schema_version": .int(1),
      "history_status": .string("missing"),
      "history_through": .null,
      "analysis_cutoff": .string("2026-08-20T00:00:00Z"),
      "windows": .array([]),
      "points": .array([]),
      "truncated": .bool(false),
      "omitted_event_points": .int(0),
      "next_cursor": .null,
    ])
  }
}
