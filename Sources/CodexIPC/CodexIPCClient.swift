import Darwin
import Dispatch
import Foundation
import os

public enum CodexIPCConnectionState: Equatable, Sendable {
  case disconnected
  case connecting
  case connected
  case incompatible(reason: String)
}

public enum CodexIPCEvent: Sendable {
  case connectionStateChanged(CodexIPCConnectionState)
  case queuedFollowUpsChanged(conversationID: String, queuedCount: Int)
  case readStateChanged(conversationID: String, hasUnreadTurn: Bool)
  case threadArchived(conversationID: String)
  case threadUnarchived(conversationID: String)
  case snapshot(conversationID: String, revision: Int, state: JSONValue)
  case patches(conversationID: String, baseRevision: Int, revision: Int, patches: [JSONPatch])
}

final class CodexIPCEventDeliveryGate: Sendable {
  private let currentGeneration = OSAllocatedUnfairLock(initialState: UInt64(0))

  func beginConnection() -> UInt64 {
    currentGeneration.withLock { generation in
      generation &+= 1
      return generation
    }
  }

  func invalidateCurrentConnection() {
    currentGeneration.withLock { generation in
      generation &+= 1
    }
  }

  func deliver(
    _ event: CodexIPCEvent,
    generation: UInt64,
    to eventHandler: @escaping @MainActor @Sendable (CodexIPCEvent) -> Void
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

struct CodexIPCReadStateChange: Equatable, Sendable {
  let conversationID: String
  let hasUnreadTurn: Bool

  init?(
    broadcast message: [String: Any],
    subscribedConversationIDs: Set<String>
  ) {
    guard message["method"] as? String == "thread-read-state-changed",
      (message["version"] as? NSNumber)?.intValue == 2,
      let params = message["params"] as? [String: Any],
      params["hostId"] as? String == "local",
      let conversationID = params["conversationId"] as? String,
      subscribedConversationIDs.contains(conversationID),
      let hasUnreadTurn = params["hasUnreadTurn"] as? Bool
    else { return nil }
    self.conversationID = conversationID
    self.hasUnreadTurn = hasUnreadTurn
  }
}

struct CodexIPCQueuedFollowUpsChange: Equatable, Sendable {
  let conversationID: String
  let queuedCount: Int

  init(conversationID: String, queuedCount: Int) {
    self.conversationID = conversationID
    self.queuedCount = queuedCount
  }

  init?(
    broadcast message: [String: Any],
    subscribedConversationIDs: Set<String>
  ) {
    guard message["method"] as? String == "thread-queued-followups-changed",
      (message["version"] as? NSNumber)?.intValue == 1,
      let params = message["params"] as? [String: Any],
      let conversationID = params["conversationId"] as? String,
      subscribedConversationIDs.contains(conversationID),
      let messages = params["messages"] as? [Any]
    else { return nil }
    self.init(
      conversationID: conversationID,
      queuedCount: messages.count
    )
  }
}

enum CodexIPCThreadCatalogChange: Equatable, Sendable {
  case archived(conversationID: String)
  case unarchived(conversationID: String)

  init?(broadcast message: [String: Any]) {
    guard let method = message["method"] as? String,
      let version = (message["version"] as? NSNumber)?.intValue,
      let params = message["params"] as? [String: Any],
      params["hostId"] as? String == "local",
      let conversationID = params["conversationId"] as? String
    else { return nil }

    switch (method, version) {
    case ("thread-archived", 2):
      self = .archived(conversationID: conversationID)
    case ("thread-unarchived", 1):
      self = .unarchived(conversationID: conversationID)
    default:
      return nil
    }
  }
}

struct CodexIPCPendingSubscription: Equatable {
  let conversationID: String
  let following: Bool
}

enum CodexIPCPendingSubscriptionQueuePolicy {
  static func shouldEnqueue(
    _ candidate: CodexIPCPendingSubscription,
    after pending: [CodexIPCPendingSubscription]
  ) -> Bool {
    guard
      let latestForConversation = pending.last(where: {
        $0.conversationID == candidate.conversationID
      })
    else { return true }
    return latestForConversation.following != candidate.following
  }
}

private struct CodexIPCPendingWrite {
  let frame: Data
  var offset: Int
  let failurePhase: CodexIPCDiagnosticsFailurePhase
  let subscription: CodexIPCPendingSubscription?
}

private struct CodexIPCWriteFailure: Error {
  let diagnosticsFailure: CodexIPCDiagnosticsFailure
}

// SAFETY: Mutable transport state is confined to `queue`. The event handler has
// separate lock-backed storage because callers install it outside that queue.
public final class CodexIPCClient: @unchecked Sendable {
  typealias SocketWriter = @Sendable (Int32, UnsafeRawPointer?, Int) -> Int
  private typealias EventHandler = @MainActor @Sendable (CodexIPCEvent) -> Void

  public static let defaultSocketURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".codex/ipc/ipc.sock")
  static let legacySocketURL: URL = {
    let userID = getuid()
    let socketName = userID == 0 ? "ipc.sock" : "ipc-\(userID).sock"
    return FileManager.default.temporaryDirectory
      .appendingPathComponent("codex-ipc", isDirectory: true)
      .appendingPathComponent(socketName)
  }()
  static let defaultSocketURLs = [defaultSocketURL, legacySocketURL]

  private let eventHandlerStorage = OSAllocatedUnfairLock<EventHandler?>(initialState: nil)

  public var eventHandler: (@MainActor @Sendable (CodexIPCEvent) -> Void)? {
    get { eventHandlerStorage.withLock { $0 } }
    set { eventHandlerStorage.withLock { $0 = newValue } }
  }

  private let socketURLs: [URL]
  private let socketWriter: SocketWriter
  private let initializeResponseTimeout: TimeInterval
  private let queue = DispatchQueue(label: "app.ohida.codex-echo.ipc")
  private let eventDeliveryGate = CodexIPCEventDeliveryGate()
  private var socketDescriptor: Int32 = -1
  private var readSource: DispatchSourceRead?
  private var writeSource: DispatchSourceWrite?
  private var pendingWrites: [CodexIPCPendingWrite] = []
  private var decoder = IPCFrameDecoder()
  private var clientID = "initializing-client"
  private var initializeRequestID: String?
  private var initializeTimeoutWorkItem: DispatchWorkItem?
  private var desiredSubscriptions = Set<String>()
  private var subscriptionsWithSnapshots = Set<String>()
  private var subscriptionsNeedingSnapshotConfirmation = Set<String>()
  private var subscriptionsAwaitingSnapshotConfirmation = Set<String>()
  private var running = false
  private var reconnectWorkItem: DispatchWorkItem?
  private var activeEventGeneration: UInt64 = 0
  private var diagnosticsState = CodexIPCDiagnosticsState.stopped
  private var diagnosticsEndpointAttempts: [CodexIPCDiagnosticsEndpointAttempt] = []
  private var diagnosticsConnectionFailureCount = 0
  private var diagnosticsLastFailure: CodexIPCDiagnosticsFailure?

  public convenience init() {
    self.init(socketURLs: Self.defaultSocketURLs)
  }

  public convenience init(socketURL: URL) {
    self.init(socketURLs: [socketURL])
  }

  init(
    socketURLs: [URL],
    socketWriter: @escaping SocketWriter = { descriptor, pointer, count in
      Darwin.write(descriptor, pointer, count)
    },
    initializeResponseTimeout: TimeInterval = 15
  ) {
    precondition(initializeResponseTimeout > 0)
    self.socketURLs = socketURLs
    self.socketWriter = socketWriter
    self.initializeResponseTimeout = initializeResponseTimeout
    diagnosticsEndpointAttempts = Self.initialDiagnosticsEndpointAttempts(
      for: socketURLs
    )
  }

  deinit {
    reconnectWorkItem?.cancel()
    if socketDescriptor >= 0 { Darwin.close(socketDescriptor) }
  }

  public func start() {
    queue.async { [weak self] in
      guard let self, !self.running else { return }
      self.running = true
      self.connectLocked()
    }
  }

  public func stop() {
    eventDeliveryGate.invalidateCurrentConnection()
    queue.sync {
      // Work queued before this sync can begin a fresh generation after the
      // caller-side invalidation above. Invalidate again at the serialization
      // boundary so none of those events can escape stop().
      self.eventDeliveryGate.invalidateCurrentConnection()
      self.running = false
      self.reconnectWorkItem?.cancel()
      self.reconnectWorkItem = nil
      _ = try? self.sendFollowingLocked(self.desiredSubscriptions, following: false)
      self.disconnectLocked(failure: nil, scheduleReconnect: false)
    }
  }

  public func resetAfterDesktopProcessBoundary() {
    // Invalidate synchronously so a snapshot already queued for MainActor cannot
    // outlive the desktop process that produced it.
    eventDeliveryGate.invalidateCurrentConnection()
    queue.async { [weak self] in
      guard let self, self.running else { return }
      self.reconnectWorkItem?.cancel()
      self.reconnectWorkItem = nil
      self.disconnectLocked(failure: nil, scheduleReconnect: false)
      self.connectLocked()
    }
  }

  public func setSubscriptions(_ conversationIDs: Set<String>) {
    queue.async { [weak self] in
      guard let self else { return }
      let removed = self.desiredSubscriptions.subtracting(conversationIDs)
      self.desiredSubscriptions = conversationIDs
      self.subscriptionsWithSnapshots.subtract(removed)
      self.subscriptionsNeedingSnapshotConfirmation.subtract(removed)
      self.subscriptionsAwaitingSnapshotConfirmation.subtract(removed)
      do {
        try self.sendFollowingLocked(removed, following: false)

        // A Codex window can hand ownership to another window immediately after
        // the first snapshot. Confirm once on the next catalog reconciliation so
        // the current owner must answer, while still retrying tasks with no owner.
        let awaitingSnapshot = conversationIDs.subtracting(self.subscriptionsWithSnapshots)
        let needingConfirmation = self.subscriptionsNeedingSnapshotConfirmation
          .intersection(conversationIDs)
        let didSend = try self.sendFollowingLocked(
          awaitingSnapshot.union(needingConfirmation),
          following: true
        )
        if didSend {
          self.subscriptionsNeedingSnapshotConfirmation.subtract(needingConfirmation)
          self.subscriptionsAwaitingSnapshotConfirmation.formUnion(needingConfirmation)
        }
      } catch {
        self.disconnectLocked(
          failure: Self.diagnosticsFailure(
            for: error,
            defaultPhase: .subscriptionWrite
          ),
          scheduleReconnect: true
        )
      }
    }
  }

  public func requestSnapshot(for conversationID: String) {
    queue.async { [weak self] in
      guard let self else { return }
      guard self.desiredSubscriptions.contains(conversationID) else { return }
      self.subscriptionsWithSnapshots.remove(conversationID)
      self.subscriptionsNeedingSnapshotConfirmation.remove(conversationID)
      self.subscriptionsAwaitingSnapshotConfirmation.remove(conversationID)
      do {
        try self.sendFollowingLocked([conversationID], following: true)
      } catch {
        self.disconnectLocked(
          failure: Self.diagnosticsFailure(
            for: error,
            defaultPhase: .subscriptionWrite
          ),
          scheduleReconnect: true
        )
      }
    }
  }

  public func diagnosticsSnapshot() -> CodexIPCDiagnosticsSnapshot {
    queue.sync {
      CodexIPCDiagnosticsSnapshot(
        state: diagnosticsState,
        endpointAttempts: diagnosticsEndpointAttempts,
        connectionFailureCount: diagnosticsConnectionFailureCount,
        lastFailure: diagnosticsLastFailure
      )
    }
  }

  private func connectLocked() {
    guard running, socketDescriptor < 0 else { return }
    activeEventGeneration = eventDeliveryGate.beginConnection()
    diagnosticsState = .connecting
    diagnosticsEndpointAttempts = Self.initialDiagnosticsEndpointAttempts(
      for: socketURLs
    )
    emit(.connectionStateChanged(.connecting))

    do {
      let descriptor = try Self.firstAvailableSocketDescriptor(from: socketURLs) {
        socketURL in
        do {
          try validateSocketOwnership(at: socketURL)
          let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
          guard descriptor >= 0 else {
            throw IPCClientError.posix("socket", errno)
          }
          var noSignal: Int32 = 1
          setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSignal,
            socklen_t(MemoryLayout<Int32>.size)
          )

          do {
            try connect(descriptor: descriptor, to: socketURL.path)
          } catch {
            Darwin.close(descriptor)
            throw error
          }
          setDiagnosticsEndpointResult(.connected, for: socketURL)
          return descriptor
        } catch {
          setDiagnosticsEndpointResult(
            Self.diagnosticsEndpointResult(for: error),
            for: socketURL
          )
          throw error
        }
      }

      _ = fcntl(descriptor, F_SETFL, O_NONBLOCK)
      socketDescriptor = descriptor
      decoder.reset()
      clientID = "initializing-client"
      subscriptionsWithSnapshots.removeAll()
      subscriptionsNeedingSnapshotConfirmation.removeAll()
      subscriptionsAwaitingSnapshotConfirmation.removeAll()
      pendingWrites.removeAll(keepingCapacity: true)

      let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
      let generation = activeEventGeneration
      source.setEventHandler { [weak self] in
        self?.readAvailableLocked(
          descriptor: descriptor,
          generation: generation
        )
      }
      readSource = source
      source.resume()
      do {
        try sendInitializeLocked()
      } catch {
        disconnectLocked(
          failure: Self.diagnosticsFailure(
            for: error,
            defaultPhase: .initializeWrite
          ),
          scheduleReconnect: true
        )
      }
    } catch {
      disconnectLocked(
        failure: CodexIPCDiagnosticsFailure(
          phase: Self.diagnosticsConnectionPhase(for: error),
          kind: .classify(error)
        ),
        scheduleReconnect: true
      )
    }
  }

  static func firstAvailableSocketDescriptor(
    from socketURLs: [URL],
    connect: (URL) throws -> Int32
  ) throws -> Int32 {
    var lastError: any Error = IPCClientError.socketUnavailable
    for socketURL in socketURLs {
      do {
        return try connect(socketURL)
      } catch {
        lastError = error
      }
    }
    throw lastError
  }

  private func validateSocketOwnership(at socketURL: URL) throws {
    var socketInfo = stat()
    guard lstat(socketURL.path, &socketInfo) == 0 else {
      throw IPCClientError.socketUnavailable
    }
    guard (socketInfo.st_mode & S_IFMT) == S_IFSOCK,
      socketInfo.st_uid == getuid()
    else {
      throw IPCClientError.untrustedSocket
    }

    var directoryInfo = stat()
    let directoryPath = socketURL.deletingLastPathComponent().path
    let unsafeWriteBits = mode_t(S_IWGRP | S_IWOTH)
    guard lstat(directoryPath, &directoryInfo) == 0,
      (directoryInfo.st_mode & S_IFMT) == S_IFDIR,
      directoryInfo.st_uid == getuid(),
      (directoryInfo.st_mode & unsafeWriteBits) == 0
    else {
      throw IPCClientError.untrustedSocket
    }
  }

  private func connect(descriptor: Int32, to path: String) throws {
    var address = sockaddr_un()
    let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
    guard path.utf8.count + 1 <= pathCapacity else { throw IPCClientError.socketPathTooLong }
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    address.sun_family = sa_family_t(AF_UNIX)
    _ = withUnsafeMutablePointer(to: &address.sun_path.0) { destination in
      path.withCString { source in
        strlcpy(destination, source, pathCapacity)
      }
    }
    let result = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard result == 0 else { throw IPCClientError.posix("connect", errno) }
  }

  private func sendInitializeLocked() throws {
    let requestID = UUID().uuidString
    initializeRequestID = requestID
    try sendLocked(
      [
        "type": "request",
        "requestId": requestID,
        "sourceClientId": clientID,
        "version": 0,
        "method": "initialize",
        "params": ["clientType": "codex-echo"],
      ],
      failurePhase: .initializeWrite
    )
    scheduleInitializeTimeoutLocked(requestID: requestID)
  }

  private func scheduleInitializeTimeoutLocked(requestID: String) {
    initializeTimeoutWorkItem?.cancel()
    let descriptor = socketDescriptor
    let generation = activeEventGeneration
    let workItem = DispatchWorkItem { [weak self] in
      guard let self,
        self.initializeRequestID == requestID,
        self.isCurrentConnection(
          descriptor: descriptor,
          generation: generation
        )
      else { return }
      self.initializeTimeoutWorkItem = nil
      self.disconnectLocked(
        failure: CodexIPCDiagnosticsFailure(
          phase: .initializeResponse,
          kind: .timedOut
        ),
        scheduleReconnect: true
      )
    }
    initializeTimeoutWorkItem = workItem
    queue.asyncAfter(
      deadline: .now() + initializeResponseTimeout,
      execute: workItem
    )
  }

  @discardableResult
  private func sendFollowingLocked(
    _ conversationIDs: Set<String>,
    following: Bool
  ) throws -> Bool {
    guard clientID != "initializing-client", socketDescriptor >= 0 else { return false }
    for conversationID in conversationIDs {
      try sendLocked(
        [
          "type": "broadcast",
          "method": "thread-stream-following-changed",
          "sourceClientId": clientID,
          "version": 1,
          "params": [
            "conversationId": conversationID,
            "hostId": "local",
            "following": following,
          ],
        ],
        failurePhase: .subscriptionWrite,
        subscription: CodexIPCPendingSubscription(
          conversationID: conversationID,
          following: following
        )
      )
    }
    return true
  }

  private func sendLocked(
    _ object: [String: Any],
    failurePhase: CodexIPCDiagnosticsFailurePhase,
    subscription: CodexIPCPendingSubscription? = nil
  ) throws {
    let descriptor = socketDescriptor
    let generation = activeEventGeneration
    guard isCurrentConnection(descriptor: descriptor, generation: generation) else {
      throw Self.writeFailure(
        phase: failurePhase,
        error: IPCClientError.notConnected
      )
    }

    if let subscription {
      let pendingSubscriptions = pendingWrites.compactMap(\.subscription)
      guard
        CodexIPCPendingSubscriptionQueuePolicy.shouldEnqueue(
          subscription,
          after: pendingSubscriptions
        )
      else { return }
    }

    let frame: Data
    do {
      frame = try IPCFrameCodec.encode(jsonObject: object)
    } catch {
      throw Self.writeFailure(phase: failurePhase, error: error)
    }
    pendingWrites.append(
      CodexIPCPendingWrite(
        frame: frame,
        offset: 0,
        failurePhase: failurePhase,
        subscription: subscription
      )
    )
    guard writeSource == nil else { return }
    try flushPendingWritesLocked(
      descriptor: descriptor,
      generation: generation
    )
    if !pendingWrites.isEmpty {
      armWriteSourceLocked(
        descriptor: descriptor,
        generation: generation
      )
    }
  }

  private func flushPendingWritesLocked(
    descriptor: Int32,
    generation: UInt64
  ) throws {
    guard isCurrentConnection(descriptor: descriptor, generation: generation) else {
      return
    }

    while !pendingWrites.isEmpty {
      let pendingWrite = pendingWrites[0]
      let count = pendingWrite.frame.withUnsafeBytes { bytes in
        socketWriter(
          descriptor,
          bytes.baseAddress?.advanced(by: pendingWrite.offset),
          bytes.count - pendingWrite.offset
        )
      }
      let errorCode = errno
      if count > 0 {
        let nextOffset = pendingWrite.offset + count
        if nextOffset == pendingWrite.frame.count {
          pendingWrites.removeFirst()
        } else {
          pendingWrites[0].offset = nextOffset
        }
        continue
      }
      if count < 0, errorCode == EINTR { continue }
      if count < 0, errorCode == EAGAIN || errorCode == EWOULDBLOCK { return }
      throw Self.writeFailure(
        phase: pendingWrite.failurePhase,
        error: IPCClientError.posix("write", count == 0 ? EIO : errorCode)
      )
    }
  }

  private func armWriteSourceLocked(
    descriptor: Int32,
    generation: UInt64
  ) {
    guard writeSource == nil, !pendingWrites.isEmpty else { return }
    guard isCurrentConnection(descriptor: descriptor, generation: generation) else { return }
    let source = DispatchSource.makeWriteSource(fileDescriptor: descriptor, queue: queue)
    source.setEventHandler { [weak self] in
      self?.writeAvailableLocked(
        descriptor: descriptor,
        generation: generation
      )
    }
    writeSource = source
    source.resume()
  }

  private func writeAvailableLocked(
    descriptor: Int32,
    generation: UInt64
  ) {
    guard isCurrentConnection(descriptor: descriptor, generation: generation) else { return }
    do {
      try flushPendingWritesLocked(
        descriptor: descriptor,
        generation: generation
      )
      if pendingWrites.isEmpty {
        writeSource?.setEventHandler {}
        writeSource?.cancel()
        writeSource = nil
      }
    } catch {
      disconnectLocked(
        failure: Self.diagnosticsFailure(
          for: error,
          defaultPhase: .subscriptionWrite
        ),
        scheduleReconnect: true
      )
    }
  }

  private func readAvailableLocked(
    descriptor: Int32,
    generation: UInt64
  ) {
    guard isCurrentConnection(descriptor: descriptor, generation: generation) else { return }
    var bytes = [UInt8](repeating: 0, count: 64 * 1024)

    while true {
      let count = bytes.withUnsafeMutableBytes { buffer in
        Darwin.read(descriptor, buffer.baseAddress, buffer.count)
      }
      if count > 0 {
        do {
          for payload in try decoder.append(Data(bytes.prefix(count))) {
            try handlePayloadLocked(payload)
            guard
              isCurrentConnection(
                descriptor: descriptor,
                generation: generation
              )
            else { return }
          }
        } catch {
          disconnectLocked(
            failure: Self.diagnosticsFailure(
              for: error,
              defaultPhase: Self.diagnosticsPayloadPhase(for: error)
            ),
            scheduleReconnect: true
          )
          return
        }
        continue
      }
      if count == 0 {
        disconnectLocked(
          failure: CodexIPCDiagnosticsFailure(
            phase: .streamRead,
            kind: .connectionClosed
          ),
          scheduleReconnect: true
        )
        return
      }
      if errno == EINTR { continue }
      if errno == EAGAIN || errno == EWOULDBLOCK { return }
      disconnectLocked(
        failure: CodexIPCDiagnosticsFailure(
          phase: .streamRead,
          kind: .classify(IPCClientError.posix("read", errno))
        ),
        scheduleReconnect: true
      )
      return
    }
  }

  private func handlePayloadLocked(_ payload: Data) throws {
    guard let message = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
      let type = message["type"] as? String
    else {
      throw IPCClientError.invalidMessage
    }

    if type == "response" {
      try handleResponseLocked(message)
    } else if type == "broadcast" {
      try handleBroadcastLocked(message)
    }
  }

  private func handleResponseLocked(_ message: [String: Any]) throws {
    guard message["requestId"] as? String == initializeRequestID else { return }
    guard message["resultType"] as? String == "success",
      message["method"] as? String == "initialize",
      let result = message["result"] as? [String: Any],
      let assignedClientID = result["clientId"] as? String
    else {
      throw IPCClientError.initializeFailed(message["error"] as? String ?? "unknown error")
    }
    initializeTimeoutWorkItem?.cancel()
    initializeTimeoutWorkItem = nil
    initializeRequestID = nil
    clientID = assignedClientID
    diagnosticsState = .connected
    emit(.connectionStateChanged(.connected))
    try sendFollowingLocked(desiredSubscriptions, following: true)
  }

  private func handleBroadcastLocked(_ message: [String: Any]) throws {
    guard let method = message["method"] as? String else { return }
    if method == "thread-stream-following-status-requested" {
      guard (message["version"] as? NSNumber)?.intValue == 1,
        let params = message["params"] as? [String: Any],
        params["hostId"] as? String == "local",
        let conversationID = params["conversationId"] as? String,
        desiredSubscriptions.contains(conversationID)
      else { return }
      subscriptionsWithSnapshots.remove(conversationID)
      subscriptionsNeedingSnapshotConfirmation.remove(conversationID)
      subscriptionsAwaitingSnapshotConfirmation.remove(conversationID)
      try sendFollowingLocked([conversationID], following: true)
      return
    }
    if method == "thread-read-state-changed" {
      guard
        let change = CodexIPCReadStateChange(
          broadcast: message,
          subscribedConversationIDs: desiredSubscriptions
        )
      else { return }
      emit(
        .readStateChanged(
          conversationID: change.conversationID,
          hasUnreadTurn: change.hasUnreadTurn
        ))
      return
    }
    if method == "thread-queued-followups-changed" {
      guard
        let change = CodexIPCQueuedFollowUpsChange(
          broadcast: message,
          subscribedConversationIDs: desiredSubscriptions
        )
      else { return }
      emit(
        .queuedFollowUpsChanged(
          conversationID: change.conversationID,
          queuedCount: change.queuedCount
        ))
      return
    }
    if method == "thread-archived" || method == "thread-unarchived" {
      guard let change = CodexIPCThreadCatalogChange(broadcast: message) else { return }
      switch change {
      case .archived(let conversationID):
        emit(.threadArchived(conversationID: conversationID))
      case .unarchived(let conversationID):
        emit(.threadUnarchived(conversationID: conversationID))
      }
      return
    }
    guard method == "thread-stream-state-changed" else { return }
    let version = (message["version"] as? NSNumber)?.intValue ?? 0
    guard version == 11 else {
      let reason = "thread-stream-state-changed version \(version), expected 11"
      diagnosticsState = .incompatible
      diagnosticsLastFailure = CodexIPCDiagnosticsFailure(
        phase: .streamVersion,
        kind: .unsupportedVersion(actual: version, expected: 11)
      )
      emit(.connectionStateChanged(.incompatible(reason: reason)))
      return
    }
    guard let params = message["params"] as? [String: Any],
      params["hostId"] as? String == "local",
      let conversationID = params["conversationId"] as? String,
      let change = params["change"] as? [String: Any],
      let changeType = change["type"] as? String
    else {
      throw IPCClientError.invalidMessage
    }

    if changeType == "snapshot" {
      guard let revision = (change["revision"] as? NSNumber)?.intValue,
        let rawState = change["conversationState"]
      else { throw IPCClientError.invalidMessage }
      let state = try JSONValue(any: rawState)
      if subscriptionsAwaitingSnapshotConfirmation.remove(conversationID) == nil,
        !subscriptionsWithSnapshots.contains(conversationID)
      {
        subscriptionsNeedingSnapshotConfirmation.insert(conversationID)
      }
      subscriptionsWithSnapshots.insert(conversationID)
      emit(.snapshot(conversationID: conversationID, revision: revision, state: state))
      return
    }

    if changeType == "patches" {
      guard let baseRevision = (change["baseRevision"] as? NSNumber)?.intValue,
        let revision = (change["revision"] as? NSNumber)?.intValue,
        let rawPatches = change["patches"] as? [Any]
      else { throw IPCClientError.invalidMessage }
      let patches = try rawPatches.map(JSONPatch.init(any:))
      emit(
        .patches(
          conversationID: conversationID,
          baseRevision: baseRevision,
          revision: revision,
          patches: patches
        ))
    }
  }

  private func disconnectLocked(
    failure: CodexIPCDiagnosticsFailure?,
    scheduleReconnect: Bool
  ) {
    readSource?.setEventHandler {}
    readSource?.cancel()
    readSource = nil
    writeSource?.setEventHandler {}
    writeSource?.cancel()
    writeSource = nil
    if socketDescriptor >= 0 {
      Darwin.close(socketDescriptor)
      socketDescriptor = -1
    }
    pendingWrites.removeAll(keepingCapacity: true)
    decoder.reset()
    clientID = "initializing-client"
    initializeTimeoutWorkItem?.cancel()
    initializeTimeoutWorkItem = nil
    initializeRequestID = nil
    subscriptionsWithSnapshots.removeAll()
    subscriptionsNeedingSnapshotConfirmation.removeAll()
    subscriptionsAwaitingSnapshotConfirmation.removeAll()
    if let failure {
      diagnosticsState = .disconnected
      diagnosticsConnectionFailureCount += 1
      diagnosticsLastFailure = failure
      emit(.connectionStateChanged(.disconnected))
    } else {
      diagnosticsState = .stopped
    }
    guard running, scheduleReconnect else { return }
    reconnectWorkItem?.cancel()
    let workItem = DispatchWorkItem { [weak self] in self?.connectLocked() }
    reconnectWorkItem = workItem
    queue.asyncAfter(deadline: .now() + 1, execute: workItem)
  }

  private static func initialDiagnosticsEndpointAttempts(
    for socketURLs: [URL]
  ) -> [CodexIPCDiagnosticsEndpointAttempt] {
    socketURLs.enumerated().map { index, socketURL in
      CodexIPCDiagnosticsEndpointAttempt(
        endpoint: diagnosticsEndpoint(for: socketURL, index: index),
        result: .notAttempted
      )
    }
  }

  private static func diagnosticsEndpoint(
    for socketURL: URL,
    index: Int
  ) -> CodexIPCDiagnosticsEndpoint {
    if socketURL == defaultSocketURL { return .canonical }
    if socketURL == legacySocketURL { return .legacy }
    return .custom(index + 1)
  }

  private func setDiagnosticsEndpointResult(
    _ result: CodexIPCDiagnosticsEndpointResult,
    for socketURL: URL
  ) {
    guard let index = socketURLs.firstIndex(of: socketURL) else { return }
    diagnosticsEndpointAttempts[index] = CodexIPCDiagnosticsEndpointAttempt(
      endpoint: Self.diagnosticsEndpoint(for: socketURL, index: index),
      result: result
    )
  }

  private static func diagnosticsEndpointResult(
    for error: any Error
  ) -> CodexIPCDiagnosticsEndpointResult {
    let kind = CodexIPCDiagnosticsFailureKind.classify(error)
    return switch kind {
    case .socketUnavailable: .unavailable
    case .untrustedSocket: .untrusted
    case .socketPathTooLong: .pathTooLong
    default: .failed(kind)
    }
  }

  private static func diagnosticsConnectionPhase(
    for error: any Error
  ) -> CodexIPCDiagnosticsFailurePhase {
    return switch CodexIPCDiagnosticsFailureKind.classify(error) {
    case .socketUnavailable, .untrustedSocket, .socketPathTooLong:
      .endpointValidation
    default:
      .socketConnect
    }
  }

  private static func diagnosticsPayloadPhase(
    for error: any Error
  ) -> CodexIPCDiagnosticsFailurePhase {
    guard let error = error as? IPCClientError else {
      return .streamDecode
    }
    if case .initializeFailed = error {
      return .initializeResponse
    }
    return .streamDecode
  }

  private func isCurrentConnection(
    descriptor: Int32,
    generation: UInt64
  ) -> Bool {
    descriptor >= 0
      && descriptor == socketDescriptor
      && generation == activeEventGeneration
  }

  private static func writeFailure(
    phase: CodexIPCDiagnosticsFailurePhase,
    error: any Error
  ) -> CodexIPCWriteFailure {
    CodexIPCWriteFailure(
      diagnosticsFailure: CodexIPCDiagnosticsFailure(
        phase: phase,
        kind: .classify(error)
      )
    )
  }

  private static func diagnosticsFailure(
    for error: any Error,
    defaultPhase: CodexIPCDiagnosticsFailurePhase
  ) -> CodexIPCDiagnosticsFailure {
    if let writeFailure = error as? CodexIPCWriteFailure {
      return writeFailure.diagnosticsFailure
    }
    return CodexIPCDiagnosticsFailure(
      phase: defaultPhase,
      kind: .classify(error)
    )
  }

  private func emit(_ event: CodexIPCEvent) {
    guard let eventHandler else { return }
    eventDeliveryGate.deliver(
      event,
      generation: activeEventGeneration,
      to: eventHandler
    )
  }
}

public enum IPCClientError: Error, Equatable, Sendable {
  case socketUnavailable
  case untrustedSocket
  case socketPathTooLong
  case notConnected
  case invalidMessage
  case initializeFailed(String)
  case posix(String, Int32)
}
