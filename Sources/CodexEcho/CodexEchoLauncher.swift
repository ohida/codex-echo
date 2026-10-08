import Darwin
import Foundation

enum CodexEchoLaunchMode: Equatable {
  case app
  case mcpStdio
  case capacityJSON
  case capacityJSONRefresh
  case invalidCapacityArguments

  static func resolve(arguments: [String]) -> Self {
    if arguments.dropFirst().first == "--capacity-json" {
      if Array(arguments.dropFirst()) == ["--capacity-json", "--refresh"] {
        return .capacityJSONRefresh
      }
      return arguments.count == 2 ? .capacityJSON : .invalidCapacityArguments
    }
    return arguments.dropFirst().first == "--mcp-stdio" ? .mcpStdio : .app
  }
}

@main
enum CodexEchoLauncher {
  @MainActor
  static func main() async {
    switch CodexEchoLaunchMode.resolve(arguments: CommandLine.arguments) {
    case .app:
      CodexEchoApp.main()
    case .capacityJSON:
      do {
        FileHandle.standardOutput.write(try await CodexCapacityJSONCommand.read())
      } catch {
        FileHandle.standardOutput.write(CodexCapacityJSONCommand.error(code: "snapshot_unreadable"))
        exit(EXIT_FAILURE)
      }
    case .capacityJSONRefresh:
      do {
        let usage = try await CodexCapacityRefresh().read()
        FileHandle.standardOutput.write(try await CodexCapacityJSONCommand.readLive(usage: usage))
      } catch let error as CodexCapacityRefresh.Failure {
        FileHandle.standardOutput.write(CodexCapacityJSONCommand.error(code: error.rawValue))
        exit(EXIT_FAILURE)
      } catch {
        FileHandle.standardOutput.write(CodexCapacityJSONCommand.error(code: "refresh_failed"))
        exit(EXIT_FAILURE)
      }
    case .invalidCapacityArguments:
      FileHandle.standardOutput.write(CodexCapacityJSONCommand.error(code: "invalid_arguments"))
      exit(64)
    case .mcpStdio:
      do {
        try await CodexCapacityMCPServer.runStdio()
      } catch {
        writeDiagnostic("Codex Echo MCP server failed: \(error.localizedDescription)")
        exit(EXIT_FAILURE)
      }
    }
  }

  private static func writeDiagnostic(_ message: String) {
    guard let data = "\(message)\n".data(using: .utf8) else { return }
    FileHandle.standardError.write(data)
  }
}
