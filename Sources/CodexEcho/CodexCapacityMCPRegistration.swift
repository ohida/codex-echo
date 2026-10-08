import Darwin
import Foundation

enum CodexCapacityMCPRegistrationStatus: Equatable, Sendable {
  case checking
  case notConfigured
  case settingUp
  case configured
  case removing
  case removed
  case existingRegistrationNeedsReview
  case checkFailed
  case removeFailed
  case unsupportedInstallation
}

enum CodexCapacityMCPRegistrationInspection: Equatable, Sendable {
  case notConfigured
  case configured
  case existingRegistrationNeedsReview
  case checkFailed
  case unsupportedInstallation
}

struct CodexCapacityMCPCommandLimits: Equatable, Sendable {
  let timeout: TimeInterval
  let maximumStandardOutputByteCount: Int
  let maximumStandardErrorByteCount: Int

  static let list = Self(
    timeout: 5,
    maximumStandardOutputByteCount: 4 * 1_024 * 1_024,
    maximumStandardErrorByteCount: 64 * 1_024
  )
  static let add = Self(
    timeout: 10,
    maximumStandardOutputByteCount: 256 * 1_024,
    maximumStandardErrorByteCount: 64 * 1_024
  )
  static let remove = Self(
    timeout: 10,
    maximumStandardOutputByteCount: 256 * 1_024,
    maximumStandardErrorByteCount: 64 * 1_024
  )
}

enum CodexCapacityMCPCommandFailure: Error, Equatable, Sendable {
  case launchFailed
  case cancelled
  case timedOut
  case standardOutputTooLarge
  case standardErrorTooLarge
}

struct CodexCapacityMCPCommandResult: Equatable, Sendable {
  let terminationStatus: Int32
  let standardOutput: Data
}

protocol CodexCapacityMCPCommandRunning: Sendable {
  func run(
    executableURL: URL,
    arguments: [String],
    currentDirectoryURL: URL,
    limits: CodexCapacityMCPCommandLimits
  ) async -> Result<CodexCapacityMCPCommandResult, CodexCapacityMCPCommandFailure>
}

final class SystemCodexCapacityMCPCommandRunner: CodexCapacityMCPCommandRunning,
  @unchecked Sendable
{
  private final class ProcessTerminationController: @unchecked Sendable {
    private let process: Process

    init(process: Process) {
      self.process = process
    }

    func requestTermination() {
      guard process.isRunning else { return }
      process.terminate()
      let processIdentifier = process.processIdentifier
      DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) {
        if self.process.isRunning, processIdentifier > 0 {
          _ = Darwin.kill(processIdentifier, SIGKILL)
        }
      }
    }
  }

  private final class OutputState: @unchecked Sendable {
    private let lock = NSLock()
    private var standardOutput = Data()
    private var standardErrorByteCount = 0
    private var failure: CodexCapacityMCPCommandFailure?

    func appendStandardOutput(
      _ data: Data,
      maximumByteCount: Int
    ) -> Bool {
      lock.withLock {
        guard failure == nil else { return false }
        guard data.count <= maximumByteCount - standardOutput.count else {
          failure = .standardOutputTooLarge
          return true
        }
        standardOutput.append(data)
        return false
      }
    }

    func appendStandardError(
      _ data: Data,
      maximumByteCount: Int
    ) -> Bool {
      lock.withLock {
        guard failure == nil else { return false }
        guard data.count <= maximumByteCount - standardErrorByteCount else {
          failure = .standardErrorTooLarge
          return true
        }
        standardErrorByteCount += data.count
        return false
      }
    }

    func markTimedOut() -> Bool {
      lock.withLock {
        guard failure == nil else { return false }
        failure = .timedOut
        return true
      }
    }

    func snapshot() -> (
      failure: CodexCapacityMCPCommandFailure?,
      standardOutput: Data
    ) {
      lock.withLock { (failure, standardOutput) }
    }
  }

  private final class CancellationState: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool { lock.withLock { cancelled } }

    func cancel() {
      lock.withLock { cancelled = true }
    }
  }

  private let queue = DispatchQueue(
    label: "app.ohida.codex-echo.capacity-mcp-registration"
  )

  func run(
    executableURL: URL,
    arguments: [String],
    currentDirectoryURL: URL,
    limits: CodexCapacityMCPCommandLimits
  ) async -> Result<CodexCapacityMCPCommandResult, CodexCapacityMCPCommandFailure> {
    let cancellation = CancellationState()
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        queue.async {
          continuation.resume(
            returning: cancellation.isCancelled ? .failure(.cancelled) : Self.runSynchronously(
              executableURL: executableURL,
              arguments: arguments,
              currentDirectoryURL: currentDirectoryURL,
              limits: limits
            )
          )
        }
      }
    } onCancel: {
      cancellation.cancel()
    }
  }

  private static func runSynchronously(
    executableURL: URL,
    arguments: [String],
    currentDirectoryURL: URL,
    limits: CodexCapacityMCPCommandLimits
  ) -> Result<CodexCapacityMCPCommandResult, CodexCapacityMCPCommandFailure> {
    let process = Process()
    let standardOutput = Pipe()
    let standardError = Pipe()
    let outputState = OutputState()
    let terminationController = ProcessTerminationController(process: process)

    process.executableURL = executableURL
    process.arguments = arguments
    process.currentDirectoryURL = currentDirectoryURL
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = standardOutput
    process.standardError = standardError

    do {
      try process.run()
    } catch {
      return .failure(.launchFailed)
    }
    let outputDescriptor = standardOutput.fileHandleForReading.fileDescriptor
    let errorDescriptor = standardError.fileHandleForReading.fileDescriptor
    guard setNonblocking(outputDescriptor), setNonblocking(errorDescriptor) else {
      terminationController.requestTermination()
      process.waitUntilExit()
      return .failure(.launchFailed)
    }
    let deadline = ProcessInfo.processInfo.systemUptime + max(limits.timeout, 0)
    var outputOpen = true
    var errorOpen = true
    var terminating = false
    while true {
      if outputOpen && outputState.snapshot().failure == nil {
        outputOpen = drain(outputDescriptor) { data in
          outputState.appendStandardOutput(
            data, maximumByteCount: limits.maximumStandardOutputByteCount
          )
        }
      }
      if errorOpen && outputState.snapshot().failure == nil {
        errorOpen = drain(errorDescriptor) { data in
          outputState.appendStandardError(
            data, maximumByteCount: limits.maximumStandardErrorByteCount
          )
        }
      }
      let running = process.isRunning
      if !running && ((!outputOpen && !errorOpen) || terminating) { break }
      if ProcessInfo.processInfo.systemUptime >= deadline {
        _ = outputState.markTimedOut()
        if !terminating {
          terminating = true
          terminationController.requestTermination()
        }
        if !running { break }
      } else if outputState.snapshot().failure != nil && !terminating {
        terminating = true
        terminationController.requestTermination()
      }
      Thread.sleep(forTimeInterval: 0.01)
    }
    process.waitUntilExit()

    let output = outputState.snapshot()
    if let failure = output.failure {
      return .failure(failure)
    }
    return .success(
      CodexCapacityMCPCommandResult(
        terminationStatus: process.terminationStatus,
        standardOutput: output.standardOutput
      )
    )
  }

  private static func setNonblocking(_ descriptor: Int32) -> Bool {
    let flags = Darwin.fcntl(descriptor, F_GETFL)
    return flags >= 0 && Darwin.fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0
  }

  // Returns false on EOF or a read error. No background reader can outlive the deadline.
  private static func drain(
    _ descriptor: Int32,
    append: (Data) -> Bool
  ) -> Bool {
    var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
    while true {
      let count = buffer.withUnsafeMutableBytes {
        Darwin.read(descriptor, $0.baseAddress, $0.count)
      }
      if count > 0 {
        if append(Data(buffer.prefix(count))) { return true }
      } else if count == 0 {
        return false
      } else if errno == EINTR {
        continue
      } else {
        return errno == EAGAIN || errno == EWOULDBLOCK
      }
    }
  }
}

@MainActor
protocol CodexCapacityMCPRegistrationServicing {
  func inspect() async -> CodexCapacityMCPRegistrationInspection
  func setUp(
    onMutationStarting: @escaping @MainActor () -> Void
  ) async -> CodexCapacityMCPRegistrationInspection
  func remove(
    onMutationStarting: @escaping @MainActor () -> Void
  ) async -> CodexCapacityMCPRegistrationInspection
}

extension CodexCapacityMCPRegistrationServicing {
  func setUp() async -> CodexCapacityMCPRegistrationInspection {
    await setUp(onMutationStarting: {})
  }

  func remove() async -> CodexCapacityMCPRegistrationInspection {
    await remove(onMutationStarting: {})
  }
}

@MainActor
final class CodexCapacityMCPRegistrationService:
  CodexCapacityMCPRegistrationServicing
{
  static let serverName = "codex-echo"
  static let serverArguments = ["--mcp-stdio"]

  private struct Server: Decodable {
    struct Transport: Decodable {
      let type: String
      let command: String?
      let args: [String]?
    }

    let name: String
    let enabled: Bool
    let transport: Transport
  }

  private enum ListResult {
    case missing
    case configured
    case needsReview
    case failed
  }

  private let commandRunner: any CodexCapacityMCPCommandRunning
  private let codexExecutableURL: () -> URL?
  private let echoExecutableURL: () -> URL?
  private let echoBundleURL: () -> URL
  private let userApplicationsURL: () -> URL
  private let applicationSupportURL: () -> URL
  private let fileManager: FileManager

  init(
    commandRunner: any CodexCapacityMCPCommandRunning =
      SystemCodexCapacityMCPCommandRunner(),
    codexExecutableURL: @escaping () -> URL?,
    echoExecutableURL: @escaping () -> URL?,
    echoBundleURL: @escaping () -> URL,
    userApplicationsURL: @escaping () -> URL = {
      FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Applications", isDirectory: true)
    },
    applicationSupportURL: @escaping () -> URL,
    fileManager: FileManager = .default
  ) {
    self.commandRunner = commandRunner
    self.codexExecutableURL = codexExecutableURL
    self.echoExecutableURL = echoExecutableURL
    self.echoBundleURL = echoBundleURL
    self.userApplicationsURL = userApplicationsURL
    self.applicationSupportURL = applicationSupportURL
    self.fileManager = fileManager
  }

  func inspect() async -> CodexCapacityMCPRegistrationInspection {
    guard let context = resolveContext() else { return .checkFailed }
    let result = await listRegistration(in: context)
    if case .missing = result,
      !Self.isSupportedInstallation(
        bundleURL: echoBundleURL(), userApplicationsURL: userApplicationsURL()
      )
    {
      return .unsupportedInstallation
    }
    return inspection(from: result)
  }

  func setUp(
    onMutationStarting: @escaping @MainActor () -> Void
  ) async -> CodexCapacityMCPRegistrationInspection {
    guard Self.isSupportedInstallation(
      bundleURL: echoBundleURL(), userApplicationsURL: userApplicationsURL()
    ) else {
      return .unsupportedInstallation
    }
    guard let context = resolveContext() else { return .checkFailed }

    switch await listRegistration(in: context) {
    case .configured:
      return .configured
    case .needsReview:
      return .existingRegistrationNeedsReview
    case .failed:
      return .checkFailed
    case .missing:
      break
    }

    guard !Task.isCancelled else { return .checkFailed }
    onMutationStarting()

    _ = await commandRunner.run(
      executableURL: context.codexExecutableURL,
      arguments: [
        "mcp", "add", Self.serverName, "--",
        context.echoExecutableURL.path,
      ] + Self.serverArguments,
      currentDirectoryURL: context.applicationSupportURL,
      limits: .add
    )

    return inspection(from: await listRegistration(in: context))
  }

  func remove(
    onMutationStarting: @escaping @MainActor () -> Void
  ) async -> CodexCapacityMCPRegistrationInspection {
    guard let context = resolveContext() else { return .checkFailed }

    switch await listRegistration(in: context) {
    case .missing:
      return .notConfigured
    case .configured:
      break
    case .needsReview:
      return .existingRegistrationNeedsReview
    case .failed:
      return .checkFailed
    }

    guard !Task.isCancelled else { return .checkFailed }
    onMutationStarting()

    _ = await commandRunner.run(
      executableURL: context.codexExecutableURL,
      arguments: ["mcp", "remove", Self.serverName],
      currentDirectoryURL: context.applicationSupportURL,
      limits: .remove
    )

    switch await listRegistration(in: context) {
    case .missing:
      return .notConfigured
    case .needsReview:
      return .existingRegistrationNeedsReview
    case .configured, .failed:
      return .checkFailed
    }
  }

  static func isSupportedInstallation(
    bundleURL: URL,
    userApplicationsURL: URL = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Applications", isDirectory: true)
  ) -> Bool {
    let canonicalPath = bundleURL.standardizedFileURL
      .resolvingSymlinksInPath().path
    let userApplicationsPath = userApplicationsURL.standardizedFileURL.path
    return bundleURL.pathExtension.lowercased() == "app"
      && URL(fileURLWithPath: canonicalPath).pathExtension.lowercased() == "app"
      && (canonicalPath.hasPrefix("/Applications/")
        || canonicalPath.hasPrefix(userApplicationsPath + "/"))
  }

  private struct Context {
    let codexExecutableURL: URL
    let echoExecutableURL: URL
    let applicationSupportURL: URL
  }

  private func resolveContext() -> Context? {
    guard let codexExecutableURL = codexExecutableURL(),
      fileManager.isExecutableFile(atPath: codexExecutableURL.path),
      let echoExecutableURL = echoExecutableURL(),
      fileManager.isExecutableFile(atPath: echoExecutableURL.path)
    else { return nil }

    let applicationSupportURL = applicationSupportURL()
    do {
      try fileManager.createDirectory(
        at: applicationSupportURL,
        withIntermediateDirectories: true
      )
    } catch {
      return nil
    }
    return Context(
      codexExecutableURL: codexExecutableURL,
      echoExecutableURL: echoExecutableURL,
      applicationSupportURL: applicationSupportURL
    )
  }

  private func listRegistration(in context: Context) async -> ListResult {
    let result = await commandRunner.run(
      executableURL: context.codexExecutableURL,
      arguments: ["mcp", "list", "--json"],
      currentDirectoryURL: context.applicationSupportURL,
      limits: .list
    )
    guard case .success(let commandResult) = result,
      commandResult.terminationStatus == 0,
      let servers = try? JSONDecoder().decode(
        [Server].self,
        from: commandResult.standardOutput
      )
    else { return .failed }

    let matchingName = servers.filter { $0.name == Self.serverName }
    guard !matchingName.isEmpty else { return .missing }
    guard matchingName.count == 1,
      let server = matchingName.first,
      server.enabled,
      server.transport.type == "stdio",
      server.transport.args == Self.serverArguments,
      let command = server.transport.command,
      Self.canonicalPath(command) == Self.canonicalPath(
        context.echoExecutableURL.path
      )
    else { return .needsReview }
    return .configured
  }

  private func inspection(
    from listResult: ListResult
  ) -> CodexCapacityMCPRegistrationInspection {
    switch listResult {
    case .missing: .notConfigured
    case .configured: .configured
    case .needsReview: .existingRegistrationNeedsReview
    case .failed: .checkFailed
    }
  }

  private static func canonicalPath(_ path: String) -> String {
    URL(fileURLWithPath: path).standardizedFileURL
      .resolvingSymlinksInPath().path
  }
}

@MainActor
final class CodexCapacityMCPRegistrationController: ObservableObject {
  @Published private(set) var status: CodexCapacityMCPRegistrationStatus = .checking

  private let service: (any CodexCapacityMCPRegistrationServicing)?
  private var task: Task<Void, Never>?
  private var isCapacityPaneVisible = false
  private var mutationIsRunning = false
  private var generation: UInt64 = 0

  init(service: any CodexCapacityMCPRegistrationServicing) {
    self.service = service
  }

  init(staticStatus: CodexCapacityMCPRegistrationStatus) {
    service = nil
    status = staticStatus
  }

  deinit {
    task?.cancel()
  }

  func setCapacityPaneVisible(_ isVisible: Bool) {
    guard isCapacityPaneVisible != isVisible else { return }
    isCapacityPaneVisible = isVisible
    if isVisible {
      if !mutationIsRunning { refresh() }
    } else if !mutationIsRunning {
      generation &+= 1
      task?.cancel()
      task = nil
    }
  }

  func refreshIfVisible() {
    guard isCapacityPaneVisible,
      status != .settingUp,
      status != .removing
    else { return }
    refresh()
  }

  func setUp() {
    guard isCapacityPaneVisible,
      status == .notConfigured || status == .removed,
      let service
    else { return }
    start(status: .settingUp) { [service] onMutationStarting in
      await service.setUp(onMutationStarting: onMutationStarting)
    }
  }

  func remove() {
    guard isCapacityPaneVisible, status == .configured,
      let service
    else { return }
    start(status: .removing, checkFailureStatus: .removeFailed) {
      [service] onMutationStarting in
      await service.remove(onMutationStarting: onMutationStarting)
    }
  }

  func retryRemove() {
    guard isCapacityPaneVisible, status == .removeFailed,
      let service
    else { return }
    start(status: .removing, checkFailureStatus: .removeFailed) {
      [service] onMutationStarting in
      await service.remove(onMutationStarting: onMutationStarting)
    }
  }

  func tryAgain() {
    guard isCapacityPaneVisible else { return }
    refresh()
  }

  private func refresh() {
    guard let service, !mutationIsRunning else { return }
    start(status: .checking) { [service] _ in
      await service.inspect()
    }
  }

  private func start(
    status pendingStatus: CodexCapacityMCPRegistrationStatus,
    checkFailureStatus: CodexCapacityMCPRegistrationStatus = .checkFailed,
    operation: @escaping (
      @escaping @MainActor () -> Void
    ) async -> CodexCapacityMCPRegistrationInspection
  ) {
    guard !mutationIsRunning else { return }
    generation &+= 1
    let operationGeneration = generation
    task?.cancel()
    status = pendingStatus
    task = Task { [weak self] in
      let inspection = await operation { [weak self] in
        guard let self, self.generation == operationGeneration else { return }
        self.mutationIsRunning = true
      }
      guard let self, self.generation == operationGeneration else { return }
      let completedMutation = self.mutationIsRunning
      self.mutationIsRunning = false
      self.task = nil
      guard !Task.isCancelled,
        self.isCapacityPaneVisible || completedMutation
      else { return }
      self.status = switch inspection {
      case .notConfigured:
        pendingStatus == .removing ? .removed : .notConfigured
      case .configured: .configured
      case .existingRegistrationNeedsReview: .existingRegistrationNeedsReview
      case .checkFailed: checkFailureStatus
      case .unsupportedInstallation: .unsupportedInstallation
      }
    }
  }
}
