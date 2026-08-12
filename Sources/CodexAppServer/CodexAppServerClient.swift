import Darwin
import Dispatch
import Foundation
import os

public enum CodexAppServerConnectionState: Equatable, Sendable {
  case stopped
  case starting
  case running
  case failed(message: String)
}

public enum CodexAppServerEvent: Sendable {
  case connectionStateChanged(CodexAppServerConnectionState)
  case threadsChanged(
    [CodexThreadDescriptor],
    projectPathAliases: [CodexProjectPathAlias] = []
  )
  case taskCatalogUnavailable
  case usageChanged(CodexUsageSnapshot)
  case usageUnavailable
}

struct CodexAppServerExecutableFingerprint: Equatable, Sendable {
  let device: UInt64
  let inode: UInt64
  let size: Int64
  let modifiedSeconds: Int64
  let modifiedNanoseconds: Int64

  init?(executableURL: URL) {
    var info = stat()
    guard lstat(executableURL.path, &info) == 0 else { return nil }
    device = UInt64(info.st_dev)
    inode = UInt64(info.st_ino)
    size = Int64(info.st_size)
    modifiedSeconds = Int64(info.st_mtimespec.tv_sec)
    modifiedNanoseconds = Int64(info.st_mtimespec.tv_nsec)
  }
}

final class CodexAppServerEventDeliveryGate: Sendable {
  private let currentGeneration = OSAllocatedUnfairLock(initialState: UInt64(0))

  func beginGeneration() -> UInt64 {
    currentGeneration.withLock { generation in
      generation &+= 1
      return generation
    }
  }

  func deliver(
    _ event: CodexAppServerEvent,
    generation: UInt64,
    to eventHandler: @escaping @MainActor @Sendable (CodexAppServerEvent) -> Void
  ) {
    Task { @MainActor [weak self] in
      guard let self, isCurrent(generation) else { return }
      eventHandler(event)
    }
  }

  private func isCurrent(_ generation: UInt64) -> Bool {
    currentGeneration.withLock { generation == $0 }
  }
}

enum CodexAppServerJSONLDecoderError: Error, Equatable {
  case lineTooLong
}

struct CodexAppServerJSONLDecoder {
  private let maximumLineByteCount: Int
  private var buffer = Data()

  init(maximumLineByteCount: Int) {
    precondition(maximumLineByteCount > 0)
    self.maximumLineByteCount = maximumLineByteCount
  }

  var bufferedByteCount: Int { buffer.count }

  mutating func append(_ data: Data) throws -> [Data] {
    var lines: [Data] = []
    var fragmentStart = data.startIndex

    while let newline = data[fragmentStart...].firstIndex(of: 0x0A) {
      try appendFragment(data[fragmentStart..<newline])
      if !buffer.isEmpty {
        lines.append(buffer)
        buffer.removeAll(keepingCapacity: true)
      }
      fragmentStart = data.index(after: newline)
    }

    try appendFragment(data[fragmentStart...])
    return lines
  }

  mutating func reset() {
    buffer.removeAll(keepingCapacity: false)
  }

  private mutating func appendFragment(_ fragment: Data.SubSequence) throws {
    guard fragment.count <= maximumLineByteCount - buffer.count else {
      throw CodexAppServerJSONLDecoderError.lineTooLong
    }
    buffer.append(contentsOf: fragment)
  }
}

private enum CodexAppServerRequestSlot: Hashable {
  case initialize
  case threadList
  case rateLimits
}

enum CodexAppServerExecutableLocation: Equatable {
  case unavailable
  case available(URL)

  init(
    codexApplicationURL: URL?,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) {
    if let override = environment["CODEX_EXECUTABLE"], !override.isEmpty {
      self = .available(URL(fileURLWithPath: override))
    } else if let codexApplicationURL {
      self = .available(
        codexApplicationURL.appendingPathComponent(
          "Contents/Resources/codex",
          isDirectory: false
        )
      )
    } else {
      self = .unavailable
    }
  }

  var executableURL: URL? {
    switch self {
    case .unavailable: nil
    case .available(let executableURL): executableURL
    }
  }
}

enum CodexAppServerExecutableSource: Sendable {
  case fixed(URL)
  case codexApplication(@Sendable () -> URL?)

  func resolve(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> URL? {
    switch self {
    case .fixed(let executableURL):
      return executableURL
    case .codexApplication(let applicationURLResolver):
      if let override = environment["CODEX_EXECUTABLE"], !override.isEmpty {
        return URL(fileURLWithPath: override)
      }
      return CodexAppServerExecutableLocation(
        codexApplicationURL: applicationURLResolver(),
        environment: [:]
      ).executableURL
    }
  }
}

// SAFETY: Mutable process and request state is confined to `queue`. Process and
// file-handle callbacks re-enter that queue, while the event handler uses its
// own lock-backed storage.
public final class CodexAppServerClient: @unchecked Sendable {
  private typealias EventHandler = @MainActor @Sendable (CodexAppServerEvent) -> Void
  private static let maximumThreadListPageCount = 100
  private static let maximumThreadDescriptorCount = 10_000

  private let eventHandlerStorage = OSAllocatedUnfairLock<EventHandler?>(initialState: nil)

  public var eventHandler: (@MainActor @Sendable (CodexAppServerEvent) -> Void)? {
    get { eventHandlerStorage.withLock { $0 } }
    set { eventHandlerStorage.withLock { $0 = newValue } }
  }

  private let executableSource: CodexAppServerExecutableSource
  private let responseTimeout: TimeInterval
  private let reconnectDelay: TimeInterval
  private let terminationGracePeriod: TimeInterval
  private let desktopProjectStateReader = CodexDesktopProjectStateReader()
  private let queue = DispatchQueue(label: "app.ohida.codex-echo.app-server")
  private let eventDeliveryGate = CodexAppServerEventDeliveryGate()
  private var process: Process?
  private var standardInput: Pipe?
  private var standardOutput: Pipe?
  private var standardError: Pipe?
  private var outputDecoder: CodexAppServerJSONLDecoder
  private var nextRequestID = 1
  private var initializeRequestID: Int?
  private var listRequestID: Int?
  private var rateLimitsRequestID: Int?
  private var responseTimeoutWorkItems:
    [CodexAppServerRequestSlot: DispatchWorkItem] = [:]
  private var running = false
  private var catalogRefreshRequested = false
  private var usageRefreshRequested = false
  private var latestUsageSnapshot: CodexUsageSnapshot?
  private var pendingThreadDescriptors: [CodexThreadDescriptor] = []
  private var pendingThreadProjectState: CodexDesktopProjectStateSnapshot?
  private var seenThreadListCursors = Set<String>()
  private var threadListPageCount = 0
  private var usagePollingPolicy = CodexUsagePollingPolicy()
  private var pollWorkItem: DispatchWorkItem?
  private var usagePollWorkItem: DispatchWorkItem?
  private var usageResetWorkItem: DispatchWorkItem?
  private var reconnectWorkItem: DispatchWorkItem?
  private var terminatingProcesses: [Int32: Process] = [:]
  private var terminationKillWorkItems: [Int32: DispatchWorkItem] = [:]
  private var diagnosticsState = CodexAppServerDiagnosticsState.stopped
  private var diagnosticsTaskCatalogState =
    CodexAppServerDiagnosticsCapabilityState.notRequested
  private var diagnosticsCapacityState =
    CodexAppServerDiagnosticsCapabilityState.notRequested
  private var diagnosticsConnectionFailureCount = 0
  private var diagnosticsLastFailure: CodexAppServerDiagnosticsFailure?
  private var launchedExecutableFingerprint: CodexAppServerExecutableFingerprint?
  private var activeEventGeneration: UInt64 = 0

  public convenience init(executableURL: URL) {
    self.init(
      executableSource: .fixed(executableURL),
      maximumResponseLineByteCount: 8 * 1_024 * 1_024,
      responseTimeout: 15,
      reconnectDelay: 2,
      terminationGracePeriod: 1
    )
  }

  public convenience init(
    codexApplicationURLResolver: @escaping @Sendable () -> URL?
  ) {
    self.init(
      executableSource: .codexApplication(codexApplicationURLResolver),
      maximumResponseLineByteCount: 8 * 1_024 * 1_024,
      responseTimeout: 15,
      reconnectDelay: 2,
      terminationGracePeriod: 1
    )
  }

  convenience init(
    executableURL: URL,
    maximumResponseLineByteCount: Int,
    responseTimeout: TimeInterval,
    reconnectDelay: TimeInterval,
    terminationGracePeriod: TimeInterval = 1
  ) {
    self.init(
      executableSource: .fixed(executableURL),
      maximumResponseLineByteCount: maximumResponseLineByteCount,
      responseTimeout: responseTimeout,
      reconnectDelay: reconnectDelay,
      terminationGracePeriod: terminationGracePeriod
    )
  }

  private init(
    executableSource: CodexAppServerExecutableSource,
    maximumResponseLineByteCount: Int,
    responseTimeout: TimeInterval,
    reconnectDelay: TimeInterval,
    terminationGracePeriod: TimeInterval
  ) {
    precondition(responseTimeout > 0)
    precondition(reconnectDelay >= 0)
    precondition(terminationGracePeriod > 0)
    self.executableSource = executableSource
    self.responseTimeout = responseTimeout
    self.reconnectDelay = reconnectDelay
    self.terminationGracePeriod = terminationGracePeriod
    outputDecoder = CodexAppServerJSONLDecoder(
      maximumLineByteCount: maximumResponseLineByteCount
    )
  }

  deinit {
    standardOutput?.fileHandleForReading.readabilityHandler = nil
    standardError?.fileHandleForReading.readabilityHandler = nil
    standardInput?.fileHandleForWriting.closeFile()
    guard let process else { return }
    process.terminationHandler = nil
    Self.terminateDetached(
      process,
      after: terminationGracePeriod
    )
  }

  static func clientVersion(infoDictionary: [String: Any]?) -> String {
    guard
      let version = infoDictionary?["CFBundleShortVersionString"] as? String,
      !version.isEmpty
    else { return "development" }
    return version
  }

  static func shouldRestartForExecutableChange(
    launched: CodexAppServerExecutableFingerprint?,
    current: CodexAppServerExecutableFingerprint?
  ) -> Bool {
    guard let launched, let current else { return false }
    return launched != current
  }

  public func start() {
    queue.async { [weak self] in
      guard let self, !self.running else { return }
      self.running = true
      self.startProcessLocked()
    }
  }

  public func stop() {
    queue.sync {
      self.running = false
      self.pollWorkItem?.cancel()
      self.usagePollWorkItem?.cancel()
      self.usageResetWorkItem?.cancel()
      self.reconnectWorkItem?.cancel()
      self.pollWorkItem = nil
      self.usagePollWorkItem = nil
      self.usageResetWorkItem = nil
      self.reconnectWorkItem = nil
      self.activeEventGeneration = self.eventDeliveryGate.beginGeneration()
      self.stopProcessLocked()
      self.diagnosticsState = .stopped
      self.emit(.connectionStateChanged(.stopped))
    }
  }

  public func diagnosticsSnapshot() -> CodexAppServerDiagnosticsSnapshot {
    queue.sync {
      CodexAppServerDiagnosticsSnapshot(
        state: diagnosticsState,
        taskCatalogState: diagnosticsTaskCatalogState,
        capacityState: diagnosticsCapacityState,
        connectionFailureCount: diagnosticsConnectionFailureCount,
        lastFailure: diagnosticsLastFailure
      )
    }
  }

  public func restartIfExecutableChanged() {
    queue.async { [weak self] in
      self?.restartIfExecutableChangedLocked()
    }
  }

  public func requestCatalogRefresh() {
    queue.async { [weak self] in
      guard let self, self.running else { return }
      self.pollWorkItem?.cancel()
      self.pollWorkItem = nil

      if self.listRequestID != nil || self.initializeRequestID != nil {
        self.catalogRefreshRequested = true
        return
      }

      self.catalogRefreshRequested = false
      self.requestThreadListLocked()
    }
  }

  public func requestUsageRefresh() {
    queue.async { [weak self] in
      self?.requestUsageRefreshLocked()
    }
  }

  private func requestUsageRefreshLocked() {
    guard running else { return }
    usagePollWorkItem?.cancel()
    usagePollWorkItem = nil

    if rateLimitsRequestID != nil || initializeRequestID != nil {
      usageRefreshRequested = true
      return
    }

    usageRefreshRequested = false
    requestRateLimitsLocked()
  }

  private func startProcessLocked() {
    guard running, process == nil else { return }
    guard terminatingProcesses.isEmpty else {
      scheduleProcessStartLocked(after: 0.05)
      return
    }
    activeEventGeneration = eventDeliveryGate.beginGeneration()
    diagnosticsState = .starting
    emit(.connectionStateChanged(.starting))
    guard let executableURL = executableSource.resolve(),
      FileManager.default.isExecutableFile(atPath: executableURL.path)
    else {
      failAndReconnectLocked(
        CodexAppServerDiagnosticsFailure(
          phase: .executableValidation,
          kind: .executableUnavailable
        )
      )
      return
    }

    let processGeneration = activeEventGeneration
    let executableFingerprint = CodexAppServerExecutableFingerprint(
      executableURL: executableURL
    )
    let process = Process()
    let input = Pipe()
    let output = Pipe()
    let error = Pipe()
    process.executableURL = executableURL
    process.arguments = ["app-server", "--listen", "stdio://"]
    process.standardInput = input
    process.standardOutput = output
    process.standardError = error

    output.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      guard !data.isEmpty, let client = self else { return }
      client.queue.async {
        client.consumeOutputLocked(data, generation: processGeneration)
      }
    }
    error.fileHandleForReading.readabilityHandler = { handle in
      _ = handle.availableData
    }
    process.terminationHandler = { [weak self] _ in
      guard let client = self else { return }
      client.queue.async {
        client.processTerminatedLocked(generation: processGeneration)
      }
    }

    do {
      try process.run()
      self.process = process
      launchedExecutableFingerprint = executableFingerprint
      standardInput = input
      standardOutput = output
      standardError = error
      outputDecoder.reset()
      initializeRequestID = sendRequestLocked(
        method: "initialize",
        params: [
          "clientInfo": [
            "name": "codex-echo",
            "title": "Codex Echo",
            "version": Self.clientVersion(infoDictionary: Bundle.main.infoDictionary),
          ],
          "capabilities": ["experimentalApi": true],
        ])
      scheduleResponseTimeoutLocked(
        requestID: initializeRequestID,
        slot: .initialize,
        phase: .initialize
      )
    } catch {
      self.process = nil
      failAndReconnectLocked(
        CodexAppServerDiagnosticsFailure(
          phase: .processLaunch,
          kind: .processLaunchFailed
        )
      )
    }
  }

  private func stopProcessLocked() {
    standardOutput?.fileHandleForReading.readabilityHandler = nil
    standardError?.fileHandleForReading.readabilityHandler = nil
    standardInput?.fileHandleForWriting.closeFile()
    if let process { terminateProcessLocked(process) }
    process = nil
    launchedExecutableFingerprint = nil
    standardInput = nil
    standardOutput = nil
    standardError = nil
    initializeRequestID = nil
    listRequestID = nil
    rateLimitsRequestID = nil
    cancelAllResponseTimeoutsLocked()
    catalogRefreshRequested = false
    usageRefreshRequested = false
    diagnosticsTaskCatalogState = .notRequested
    diagnosticsCapacityState = .notRequested
    latestUsageSnapshot = nil
    resetPendingThreadListLocked()
    usagePollingPolicy.reset()
    usagePollWorkItem?.cancel()
    usageResetWorkItem?.cancel()
    usagePollWorkItem = nil
    usageResetWorkItem = nil
    outputDecoder.reset()
  }

  private func terminateProcessLocked(_ process: Process) {
    let processIdentifier = process.processIdentifier
    guard processIdentifier > 0 else { return }

    terminatingProcesses[processIdentifier] = process
    process.terminationHandler = { [weak self] terminatedProcess in
      guard let self else { return }
      self.queue.async {
        self.finishTerminatingProcessLocked(
          terminatedProcess,
          processIdentifier: processIdentifier
        )
      }
    }

    guard process.isRunning else {
      finishTerminatingProcessLocked(
        process,
        processIdentifier: processIdentifier
      )
      return
    }

    process.terminate()
    let killWorkItem = DispatchWorkItem { [weak self, process] in
      if process.isRunning {
        _ = Darwin.kill(processIdentifier, SIGKILL)
      }
      guard let self, !process.isRunning else { return }
      self.finishTerminatingProcessLocked(
        process,
        processIdentifier: processIdentifier
      )
    }
    terminationKillWorkItems[processIdentifier] = killWorkItem
    queue.asyncAfter(
      deadline: .now() + terminationGracePeriod,
      execute: killWorkItem
    )
  }

  private static func terminateDetached(
    _ process: Process,
    after gracePeriod: TimeInterval
  ) {
    let processIdentifier = process.processIdentifier
    guard processIdentifier > 0, process.isRunning else { return }
    process.terminate()
    let killWorkItem = DispatchWorkItem { [process] in
      if process.isRunning {
        _ = Darwin.kill(processIdentifier, SIGKILL)
      }
    }
    DispatchQueue.global(qos: .utility).asyncAfter(
      deadline: .now() + gracePeriod,
      execute: killWorkItem
    )
  }

  private func finishTerminatingProcessLocked(
    _ process: Process,
    processIdentifier: Int32
  ) {
    guard terminatingProcesses[processIdentifier] === process else { return }
    terminationKillWorkItems.removeValue(forKey: processIdentifier)?.cancel()
    terminatingProcesses.removeValue(forKey: processIdentifier)
  }

  private func scheduleProcessStartLocked(after delay: TimeInterval) {
    reconnectWorkItem?.cancel()
    let workItem = DispatchWorkItem { [weak self] in
      self?.startProcessLocked()
    }
    reconnectWorkItem = workItem
    queue.asyncAfter(deadline: .now() + delay, execute: workItem)
  }

  private func processTerminatedLocked(generation: UInt64) {
    guard generation == activeEventGeneration, process != nil else { return }
    standardOutput?.fileHandleForReading.readabilityHandler = nil
    standardError?.fileHandleForReading.readabilityHandler = nil
    process = nil
    launchedExecutableFingerprint = nil
    standardInput = nil
    standardOutput = nil
    standardError = nil
    initializeRequestID = nil
    listRequestID = nil
    rateLimitsRequestID = nil
    catalogRefreshRequested = false
    usageRefreshRequested = false
    latestUsageSnapshot = nil
    resetPendingThreadListLocked()
    usagePollingPolicy.reset()
    usagePollWorkItem?.cancel()
    usageResetWorkItem?.cancel()
    usagePollWorkItem = nil
    usageResetWorkItem = nil
    guard running else { return }
    failAndReconnectLocked(
      CodexAppServerDiagnosticsFailure(
        phase: .processExit,
        kind: .processExited
      )
    )
  }

  @discardableResult
  private func sendRequestLocked(method: String, params: Any) -> Int? {
    let requestID = nextRequestID
    nextRequestID += 1
    guard sendLocked(["id": requestID, "method": method, "params": params]) else { return nil }
    return requestID
  }

  @discardableResult
  private func sendLocked(_ message: [String: Any]) -> Bool {
    guard let writer = standardInput?.fileHandleForWriting else { return false }
    do {
      var data = try JSONSerialization.data(withJSONObject: message)
      data.append(0x0A)
      try writer.write(contentsOf: data)
      return true
    } catch {
      failAndReconnectLocked(
        CodexAppServerDiagnosticsFailure(
          phase: .write,
          kind: .writeFailed
        )
      )
      return false
    }
  }

  private func consumeOutputLocked(_ data: Data, generation: UInt64) {
    guard generation == activeEventGeneration else { return }
    let lines: [Data]
    do {
      lines = try outputDecoder.append(data)
    } catch {
      failAndReconnectLocked(
        CodexAppServerDiagnosticsFailure(
          phase: .read,
          kind: .responseTooLarge
        )
      )
      return
    }

    for line in lines {
      guard
        let message = try? JSONSerialization.jsonObject(with: line)
          as? [String: Any]
      else {
        // A malformed line is isolated; a missing response still hits its deadline.
        continue
      }
      handleMessageLocked(message)
    }
  }

  private func handleMessageLocked(_ message: [String: Any]) {
    if let method = message["method"] as? String {
      handleNotificationLocked(method: method, message: message)
      return
    }
    guard let requestID = (message["id"] as? NSNumber)?.intValue else {
      return
    }
    if requestID == initializeRequestID {
      handleInitializeResponseLocked(message)
    } else if requestID == listRequestID {
      handleListResponseLocked(message)
    } else if requestID == rateLimitsRequestID {
      handleRateLimitsResponseLocked(message)
    }
  }

  private func handleNotificationLocked(method: String, message: [String: Any]) {
    guard method == "account/rateLimits/updated",
      let params = message["params"] as? [String: Any],
      let update = CodexUsageSnapshot.updatedNotification(params)
    else { return }
    let usage = update.mergingMissingMetadata(from: latestUsageSnapshot)
    acceptUsageLocked(usage)
    if rateLimitsRequestID == nil {
      scheduleUsagePollLocked()
    }
  }

  private func handleInitializeResponseLocked(_ message: [String: Any]) {
    cancelResponseTimeoutLocked(for: .initialize)
    initializeRequestID = nil
    guard message["error"] == nil else {
      failAndReconnectLocked(
        CodexAppServerDiagnosticsFailure(
          phase: .initialize,
          kind: .initializationRejected
        )
      )
      return
    }
    guard sendLocked(["method": "initialized", "params": [:]]) else { return }
    diagnosticsState = .running
    emit(.connectionStateChanged(.running))
    catalogRefreshRequested = false
    usageRefreshRequested = false
    requestThreadListLocked()
    requestRateLimitsLocked()
  }

  private func requestThreadListLocked(cursor: String? = nil) {
    guard running, process?.isRunning == true, listRequestID == nil else { return }
    if restartIfExecutableChangedLocked() { return }
    if cursor == nil {
      resetPendingThreadListLocked()
      pendingThreadProjectState = desktopProjectStateReader.snapshot()
    }
    var params: [String: Any] = [
      "limit": 100,
      "sortKey": "recency_at",
      "sortDirection": "desc",
      "modelProviders": [],
      "sourceKinds": ["cli", "vscode", "appServer"],
      "archived": false,
    ]
    if let cursor {
      params["cursor"] = cursor
    }
    listRequestID = sendRequestLocked(
      method: "thread/list",
      params: params
    )
    scheduleResponseTimeoutLocked(
      requestID: listRequestID,
      slot: .threadList,
      phase: .response
    )
    if listRequestID != nil, diagnosticsTaskCatalogState != .available {
      diagnosticsTaskCatalogState = .awaitingFirstResponse
    }
  }

  private func handleListResponseLocked(_ message: [String: Any]) {
    cancelResponseTimeoutLocked(for: .threadList)
    listRequestID = nil
    guard let result = message["result"] as? [String: Any],
      let data = result["data"] as? [Any],
      let desktopProjectState = pendingThreadProjectState
    else {
      markTaskCatalogUnavailableLocked()
      return
    }

    var pageDescriptors: [CodexThreadDescriptor] = []
    pageDescriptors.reserveCapacity(data.count)
    for value in data {
      guard let object = value as? [String: Any],
        let threadID = object["id"] as? String,
        let descriptor = CodexThreadDescriptor(
          object: object,
          projectContext: desktopProjectState.projectContext(for: threadID)
        )
      else {
        markTaskCatalogUnavailableLocked()
        return
      }
      pageDescriptors.append(descriptor)
    }
    guard
      pageDescriptors.count
        <= Self.maximumThreadDescriptorCount - pendingThreadDescriptors.count
    else {
      markTaskCatalogUnavailableLocked()
      return
    }
    pendingThreadDescriptors.append(contentsOf: pageDescriptors)
    threadListPageCount += 1

    let nextCursor: String?
    switch result["nextCursor"] {
    case nil, is NSNull:
      nextCursor = nil
    case let cursor as String:
      nextCursor = cursor
    default:
      markTaskCatalogUnavailableLocked()
      return
    }

    if let nextCursor {
      guard threadListPageCount < Self.maximumThreadListPageCount,
        seenThreadListCursors.insert(nextCursor).inserted
      else {
        markTaskCatalogUnavailableLocked()
        return
      }
      requestThreadListLocked(cursor: nextCursor)
      return
    }

    let threads = pendingThreadDescriptors
    let projectPathAliases = desktopProjectState.projectPathAliases
    resetPendingThreadListLocked()
    emit(
      .threadsChanged(
        threads,
        projectPathAliases: projectPathAliases
      )
    )
    diagnosticsTaskCatalogState = .available
    if catalogRefreshRequested {
      catalogRefreshRequested = false
      requestThreadListLocked()
    } else {
      schedulePollLocked()
    }
  }

  private func requestRateLimitsLocked() {
    guard running, process?.isRunning == true, rateLimitsRequestID == nil else { return }
    rateLimitsRequestID = sendRequestLocked(
      method: "account/rateLimits/read",
      params: NSNull()
    )
    scheduleResponseTimeoutLocked(
      requestID: rateLimitsRequestID,
      slot: .rateLimits,
      phase: .response
    )
    if rateLimitsRequestID != nil, diagnosticsCapacityState != .available {
      diagnosticsCapacityState = .awaitingFirstResponse
    }
  }

  private func handleRateLimitsResponseLocked(_ message: [String: Any]) {
    cancelResponseTimeoutLocked(for: .rateLimits)
    rateLimitsRequestID = nil
    guard let result = message["result"] as? [String: Any],
      let usage = CodexUsageSnapshot.readResult(result)
    else {
      latestUsageSnapshot = nil
      usagePollingPolicy.reset()
      usageResetWorkItem?.cancel()
      usageResetWorkItem = nil
      diagnosticsCapacityState = .unavailable
      emit(.usageUnavailable)
      if usageRefreshRequested {
        usageRefreshRequested = false
        requestRateLimitsLocked()
      } else {
        scheduleUsagePollLocked()
      }
      return
    }
    acceptUsageLocked(
      usage.preservingKnownResetCredits(from: latestUsageSnapshot)
    )
    if usageRefreshRequested {
      usageRefreshRequested = false
      requestRateLimitsLocked()
    } else {
      scheduleUsagePollLocked()
    }
  }

  private func schedulePollLocked() {
    pollWorkItem?.cancel()
    let workItem = DispatchWorkItem { [weak self] in self?.requestThreadListLocked() }
    pollWorkItem = workItem
    queue.asyncAfter(deadline: .now() + 5, execute: workItem)
  }

  private func scheduleResponseTimeoutLocked(
    requestID: Int?,
    slot: CodexAppServerRequestSlot,
    phase: CodexAppServerDiagnosticsFailurePhase
  ) {
    cancelResponseTimeoutLocked(for: slot)
    guard let requestID else { return }

    let workItem = DispatchWorkItem { [weak self] in
      guard let self, self.requestIDLocked(for: slot) == requestID else {
        return
      }
      self.failAndReconnectLocked(
        CodexAppServerDiagnosticsFailure(
          phase: phase,
          kind: .requestTimedOut
        )
      )
    }
    responseTimeoutWorkItems[slot] = workItem
    queue.asyncAfter(deadline: .now() + responseTimeout, execute: workItem)
  }

  private func cancelResponseTimeoutLocked(for slot: CodexAppServerRequestSlot) {
    responseTimeoutWorkItems.removeValue(forKey: slot)?.cancel()
  }

  private func cancelAllResponseTimeoutsLocked() {
    for workItem in responseTimeoutWorkItems.values {
      workItem.cancel()
    }
    responseTimeoutWorkItems.removeAll(keepingCapacity: false)
  }

  private func resetPendingThreadListLocked() {
    pendingThreadDescriptors.removeAll(keepingCapacity: false)
    pendingThreadProjectState = nil
    seenThreadListCursors.removeAll(keepingCapacity: false)
    threadListPageCount = 0
  }

  private func markTaskCatalogUnavailableLocked() {
    resetPendingThreadListLocked()
    diagnosticsTaskCatalogState = .unavailable
    emit(.taskCatalogUnavailable)
    if catalogRefreshRequested {
      catalogRefreshRequested = false
      requestThreadListLocked()
    } else {
      schedulePollLocked()
    }
  }

  private func requestIDLocked(for slot: CodexAppServerRequestSlot) -> Int? {
    switch slot {
    case .initialize: initializeRequestID
    case .threadList: listRequestID
    case .rateLimits: rateLimitsRequestID
    }
  }

  private func scheduleUsagePollLocked() {
    usagePollWorkItem?.cancel()
    let workItem = DispatchWorkItem { [weak self] in self?.requestRateLimitsLocked() }
    usagePollWorkItem = workItem
    let now = Date()
    queue.asyncAfter(
      deadline: .now() + usagePollingPolicy.pollDelay(at: now),
      execute: workItem
    )
  }

  private func acceptUsageLocked(_ usage: CodexUsageSnapshot) {
    let now = Date()
    latestUsageSnapshot = usage
    diagnosticsCapacityState = .available
    usagePollingPolicy.observe(
      remainingPercent: usage.remainingPercent,
      at: now
    )
    scheduleUsageResetLocked(resetsAt: usage.nextResetAt(after: now))
    emit(.usageChanged(usage))
  }

  private func scheduleUsageResetLocked(resetsAt: Date?) {
    usageResetWorkItem?.cancel()
    usageResetWorkItem = nil
    guard
      let delay = CodexUsagePollingPolicy.resetRefreshDelay(
        resetsAt: resetsAt,
        now: Date()
      )
    else { return }

    let workItem = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.usageResetWorkItem = nil
      self.requestUsageRefreshLocked()
    }
    usageResetWorkItem = workItem
    queue.asyncAfter(deadline: .now() + delay, execute: workItem)
  }

  private func failAndReconnectLocked(
    _ failure: CodexAppServerDiagnosticsFailure
  ) {
    activeEventGeneration = eventDeliveryGate.beginGeneration()
    diagnosticsState = .failed
    diagnosticsConnectionFailureCount += 1
    diagnosticsLastFailure = failure
    emit(
      .connectionStateChanged(
        .failed(message: Self.connectionFailureMessage(for: failure))
      )
    )
    stopProcessLocked()
    guard running else { return }
    scheduleProcessStartLocked(after: reconnectDelay)
  }

  private static func connectionFailureMessage(
    for failure: CodexAppServerDiagnosticsFailure
  ) -> String {
    return switch failure.kind {
    case .executableUnavailable:
      "Codex executable unavailable"
    case .processLaunchFailed:
      "Codex app-server could not start"
    case .initializationRejected:
      "Codex app-server initialization failed"
    case .responseTooLarge, .requestTimedOut:
      "Codex app-server communication failed"
    case .writeFailed:
      "Codex app-server communication failed"
    case .processExited:
      "Codex app-server exited"
    }
  }

  @discardableResult
  private func restartIfExecutableChangedLocked() -> Bool {
    guard running, process != nil else { return false }
    guard let executableURL = executableSource.resolve() else { return false }
    let currentFingerprint = CodexAppServerExecutableFingerprint(
      executableURL: executableURL
    )
    guard
      Self.shouldRestartForExecutableChange(
        launched: launchedExecutableFingerprint,
        current: currentFingerprint
      )
    else { return false }

    activeEventGeneration = eventDeliveryGate.beginGeneration()
    reconnectWorkItem?.cancel()
    reconnectWorkItem = nil
    stopProcessLocked()
    startProcessLocked()
    return true
  }

  private func emit(_ event: CodexAppServerEvent) {
    guard let eventHandler else { return }
    eventDeliveryGate.deliver(
      event,
      generation: activeEventGeneration,
      to: eventHandler
    )
  }
}
