import CodexAppServer
import Foundation
import MCP
import XCTest

@testable import CodexEcho

@MainActor
final class CodexCapacityRefreshTests: XCTestCase {
  func testLiveObservationUsesExistingParserAndDoesNotClaimCacheProvenance() async throws {
    let (directory, client) = try fixture(mode: "success")
    defer { try? FileManager.default.removeItem(at: directory) }
    let usage = try await CodexCapacityRefresh(client: client).read()
    XCTAssertEqual(usage.primaryWindow?.remainingPercent, 73)
    XCTAssertEqual(usage.credits?.balance, "0")
    XCTAssertEqual(client.diagnosticsSnapshot().state, .stopped)
    let data = try await CodexCapacityJSONCommand.readLive(usage: usage)
    let root = try XCTUnwrap(JSONDecoder().decode(Value.self, from: data).objectValue)
    let source = try XCTUnwrap(root["source"]?.objectValue)
    XCTAssertEqual(source["kind"], .string("codex_app_server_live_observation"))
    XCTAssertEqual(source["refreshed_upstream"], .bool(true))
    XCTAssertEqual(source["freshness"], .string("fresh"))
    XCTAssertNil(source["revision"])
    XCTAssertNil(source["history_recording_enabled"])
    XCTAssertEqual(root["credits"]?.objectValue?["balance"], .string("0"))
    XCTAssertEqual(root["reset_credits"]?.objectValue?["status"], .string("observed"))
    XCTAssertEqual(root["reset_credits"]?.objectValue?["freshness"], .string("fresh"))
    XCTAssertEqual(root["reset_credits"]?.objectValue?["observation_source"], .string("app_server_response_received"))
    XCTAssertNotNil(usage.rateLimitResetCredits?.observedAt)
  }

  func testUnavailableUsageDoesNotFallBackToCache() async throws {
    let (directory, client) = try fixture(mode: "unavailable")
    defer { try? FileManager.default.removeItem(at: directory) }
    do {
      _ = try await CodexCapacityRefresh(client: client).read()
      XCTFail("Expected failure")
    } catch {
      XCTAssertEqual(error as? CodexCapacityRefresh.Failure, .unavailable)
    }
    XCTAssertEqual(client.diagnosticsSnapshot().state, .stopped)
  }

  func testDeadlineStopsOnlyOwnedClient() async throws {
    let (directory, client) = try fixture(mode: "silent")
    defer { try? FileManager.default.removeItem(at: directory) }
    do {
      _ = try await CodexCapacityRefresh(client: client, timeout: .milliseconds(100)).read()
      XCTFail("Expected timeout")
    } catch {
      XCTAssertEqual(error as? CodexCapacityRefresh.Failure, .timedOut)
    }
    XCTAssertEqual(client.diagnosticsSnapshot().state, .stopped)
  }

  func testCancellationStopsOwnedClient() async throws {
    let (directory, client) = try fixture(mode: "silent")
    defer { try? FileManager.default.removeItem(at: directory) }
    let task = Task { try await CodexCapacityRefresh(client: client).read() }
    try await Task.sleep(for: .milliseconds(50))
    task.cancel()
    do {
      _ = try await task.value
      XCTFail("Expected cancellation")
    } catch {
      XCTAssertTrue(error is CancellationError)
    }
    XCTAssertEqual(client.diagnosticsSnapshot().state, .stopped)
  }

  private func fixture(mode: String) throws -> (URL, CodexAppServerClient) {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("CapacityRefreshTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let executable = directory.appendingPathComponent("fake-codex")
    let script = """
      #!/usr/bin/python3
      import json, sys
      for line in sys.stdin:
          request = json.loads(line)
          method = request.get("method")
          if "id" not in request or "\(mode)" == "silent":
              continue
          if method == "initialize":
              result = {}
          elif method == "thread/list":
              result = {"data": [], "nextCursor": None}
          elif method == "account/rateLimits/read":
              result = {} if "\(mode)" == "unavailable" else {"rateLimits": {
                  "limitId": "codex",
                  "primary": {"usedPercent": 27, "windowDurationMins": 300},
                  "credits": {"balance": "0", "hasCredits": False, "unlimited": False}},
                  "rateLimitResetCredits": {"availableCount": 2, "credits": [{"expiresAt": 1792702918}, {"expiresAt": 1793301168}]}}
          else:
              continue
          print(json.dumps({"id": request["id"], "result": result}), flush=True)
      """
    try Data(script.utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    return (directory, CodexAppServerClient(executableURL: executable))
  }
}
