import Darwin
import Foundation
import XCTest

@testable import CodexIPC

final class CodexIPCTransportTests: XCTestCase {
  @MainActor
  func testWrongInitializeResponseIDTimesOutThenReconnects() async throws {
    let server = try IPCUnixSocketTestServer()
    defer { server.stop() }
    let wrongResponseSent = expectation(description: "Server sent a wrong initialize response")
    let recoveredHandshake = expectation(description: "Second connection initialized")
    let connected = expectation(description: "Client recovered after initialize timeout")
    let keepRecoveredConnectionOpen = DispatchSemaphore(value: 0)
    let serverFailure = LockedValue<String?>(nil)

    server.accept { descriptor in
      do {
        _ = try server.readFrame(on: descriptor)
        try server.writeFrame(
          [
            "type": "response",
            "requestId": "wrong-request-id",
            "resultType": "success",
            "method": "initialize",
            "result": ["clientId": "ignored-client"],
          ],
          on: descriptor
        )
        wrongResponseSent.fulfill()
        Thread.sleep(forTimeInterval: 0.3)
      } catch {
        serverFailure.set(String(describing: error))
        wrongResponseSent.fulfill()
      }
    }
    server.accept { descriptor in
      do {
        try server.completeInitializeHandshake(on: descriptor)
        recoveredHandshake.fulfill()
        _ = keepRecoveredConnectionOpen.wait(timeout: .now() + 3)
      } catch {
        serverFailure.set(String(describing: error))
        recoveredHandshake.fulfill()
      }
    }

    let client = CodexIPCClient(
      socketURLs: [server.socketURL],
      initializeResponseTimeout: 0.1
    )
    client.eventHandler = { event in
      if case .connectionStateChanged(.connected) = event {
        connected.fulfill()
      }
    }
    client.start()

    await fulfillment(of: [wrongResponseSent, recoveredHandshake, connected], timeout: 3)
    let diagnostics = client.diagnosticsSnapshot()
    client.stop()
    keepRecoveredConnectionOpen.signal()

    XCTAssertNil(serverFailure.value)
    XCTAssertEqual(diagnostics.state, .connected)
    XCTAssertEqual(diagnostics.connectionFailureCount, 1)
    XCTAssertEqual(
      diagnostics.lastFailure,
      CodexIPCDiagnosticsFailure(
        phase: .initializeResponse,
        kind: .timedOut
      )
    )
  }

  @MainActor
  func testSubscriptionConfirmsInitialSnapshotAcrossOwnerHandoff() async throws {
    let server = try IPCUnixSocketTestServer()
    defer { server.stop() }
    let confirmationReceived = expectation(
      description: "Server received a confirming subscription after the initial snapshot"
    )
    let extraSubscriptionCheckFinished = expectation(
      description: "Server checked that the confirmed subscription settled"
    )
    let serverFailure = LockedValue<String?>(nil)
    let checkForExtraSubscription = DispatchSemaphore(value: 0)
    server.accept { descriptor in
      do {
        try server.completeInitializeHandshake(on: descriptor)
        _ = try server.readFrame(on: descriptor)
        try server.writeFrame(
          [
            "type": "broadcast",
            "method": "thread-stream-state-changed",
            "sourceClientId": "owner-before-handoff",
            "version": 11,
            "params": [
              "hostId": "local",
              "conversationId": "thread-1",
              "change": [
                "type": "snapshot",
                "revision": 1,
                "conversationState": ["id": "thread-1"],
              ],
            ],
          ],
          on: descriptor
        )
        _ = try server.readFrame(on: descriptor)
        confirmationReceived.fulfill()
        try server.writeFrame(
          [
            "type": "broadcast",
            "method": "thread-stream-state-changed",
            "sourceClientId": "owner-after-handoff",
            "version": 11,
            "params": [
              "hostId": "local",
              "conversationId": "thread-1",
              "change": [
                "type": "snapshot",
                "revision": 2,
                "conversationState": ["id": "thread-1"],
              ],
            ],
          ],
          on: descriptor
        )
        _ = checkForExtraSubscription.wait(timeout: .now() + 2)
        if try server.hasReadableData(on: descriptor, timeoutMilliseconds: 300) {
          serverFailure.set("Received another subscription after confirmation")
        }
        extraSubscriptionCheckFinished.fulfill()
      } catch {
        serverFailure.set(String(describing: error))
        confirmationReceived.fulfill()
        extraSubscriptionCheckFinished.fulfill()
      }
    }

    let client = CodexIPCClient(socketURL: server.socketURL)
    let initialSnapshotReceived = expectation(description: "Client received initial snapshot")
    let confirmingSnapshotReceived = expectation(description: "Client received confirming snapshot")
    client.eventHandler = { event in
      switch event {
      case .snapshot(conversationID: "thread-1", revision: 1, state: _):
        initialSnapshotReceived.fulfill()
      case .snapshot(conversationID: "thread-1", revision: 2, state: _):
        confirmingSnapshotReceived.fulfill()
      default:
        break
      }
    }
    client.setSubscriptions(["thread-1"])
    client.start()

    await fulfillment(of: [initialSnapshotReceived], timeout: 2)
    client.setSubscriptions(["thread-1"])
    await fulfillment(of: [confirmationReceived, confirmingSnapshotReceived], timeout: 2)
    client.setSubscriptions(["thread-1"])
    checkForExtraSubscription.signal()
    await fulfillment(of: [extraSubscriptionCheckFinished], timeout: 2)
    client.stop()

    XCTAssertNil(serverFailure.value)
  }

  func testPendingSubscriptionQueueCoalescesOnlyTheLatestStatePerConversation() {
    let firstFollowing = CodexIPCPendingSubscription(
      conversationID: "thread-1",
      following: true
    )
    let otherConversation = CodexIPCPendingSubscription(
      conversationID: "thread-2",
      following: false
    )
    let stoppedFollowing = CodexIPCPendingSubscription(
      conversationID: "thread-1",
      following: false
    )

    XCTAssertFalse(
      CodexIPCPendingSubscriptionQueuePolicy.shouldEnqueue(
        firstFollowing,
        after: [firstFollowing, otherConversation]
      )
    )
    XCTAssertTrue(
      CodexIPCPendingSubscriptionQueuePolicy.shouldEnqueue(
        stoppedFollowing,
        after: [firstFollowing, otherConversation]
      )
    )
    XCTAssertFalse(
      CodexIPCPendingSubscriptionQueuePolicy.shouldEnqueue(
        stoppedFollowing,
        after: [firstFollowing, stoppedFollowing]
      )
    )
    XCTAssertTrue(
      CodexIPCPendingSubscriptionQueuePolicy.shouldEnqueue(
        firstFollowing,
        after: [firstFollowing, stoppedFollowing]
      )
    )
  }

  @MainActor
  func testSubscriptionWriteFailureIsNotOverwrittenByReadFromClosedDescriptor() async throws {
    let server = try IPCUnixSocketTestServer()
    defer { server.stop() }
    let handshakeFinished = expectation(description: "Server completed initialize handshake")
    server.accept { descriptor in
      defer { handshakeFinished.fulfill() }
      try server.completeInitializeHandshake(on: descriptor)
    }

    let writes = ScriptedSocketWriter(failure: EPIPE, onCall: 2)
    let client = CodexIPCClient(
      socketURLs: [server.socketURL],
      socketWriter: writes.write
    )
    let disconnected = expectation(description: "IPC disconnected")
    var didObserveDisconnect = false
    client.eventHandler = { event in
      guard case .connectionStateChanged(.disconnected) = event,
        !didObserveDisconnect
      else { return }
      didObserveDisconnect = true
      disconnected.fulfill()
    }

    client.setSubscriptions(["thread-1"])
    client.start()
    await fulfillment(of: [handshakeFinished, disconnected], timeout: 2)
    let diagnostics = client.diagnosticsSnapshot()
    client.stop()

    XCTAssertEqual(diagnostics.connectionFailureCount, 1)
    XCTAssertEqual(
      diagnostics.lastFailure,
      CodexIPCDiagnosticsFailure(
        phase: .subscriptionWrite,
        kind: .brokenPipe
      )
    )
  }

  @MainActor
  func testWouldBlockQueuesSubscriptionUntilSocketIsWritable() async throws {
    let server = try IPCUnixSocketTestServer()
    defer { server.stop() }
    let subscriptionReceived = expectation(description: "Server received subscription")
    let receivedMethod = LockedValue<String?>(nil)
    let serverFailure = LockedValue<String?>(nil)
    let keepConnectionOpen = DispatchSemaphore(value: 0)
    server.accept { descriptor in
      do {
        try server.completeInitializeHandshake(on: descriptor)
        let message = try server.readFrame(on: descriptor)
        receivedMethod.set(message["method"] as? String)
        subscriptionReceived.fulfill()
        _ = keepConnectionOpen.wait(timeout: .now() + 2)
      } catch {
        serverFailure.set(String(describing: error))
        subscriptionReceived.fulfill()
      }
    }

    let writes = ScriptedSocketWriter(failure: EAGAIN, onCall: 2)
    let client = CodexIPCClient(
      socketURLs: [server.socketURL],
      socketWriter: writes.write
    )
    client.setSubscriptions(["thread-1"])
    client.start()
    await fulfillment(of: [subscriptionReceived], timeout: 2)
    let diagnostics = client.diagnosticsSnapshot()
    client.stop()
    keepConnectionOpen.signal()

    XCTAssertNil(serverFailure.value)
    XCTAssertEqual(receivedMethod.value, "thread-stream-following-changed")
    XCTAssertEqual(diagnostics.state, .connected)
    XCTAssertEqual(diagnostics.connectionFailureCount, 0)
    XCTAssertNil(diagnostics.lastFailure)
  }
}

private final class ScriptedSocketWriter: @unchecked Sendable {
  private let lock = NSLock()
  private let failure: Int32
  private let failingCall: Int
  private var callCount = 0

  init(failure: Int32, onCall failingCall: Int) {
    self.failure = failure
    self.failingCall = failingCall
  }

  func write(
    descriptor: Int32,
    pointer: UnsafeRawPointer?,
    count: Int
  ) -> Int {
    lock.lock()
    callCount += 1
    let shouldFail = callCount == failingCall
    lock.unlock()
    if shouldFail {
      errno = failure
      return -1
    }
    return Darwin.write(descriptor, pointer, count)
  }
}

private final class IPCUnixSocketTestServer: @unchecked Sendable {
  let socketURL: URL

  private let queue = DispatchQueue(label: "app.ohida.codex-echo.ipc-tests.server")
  private let lock = NSLock()
  private var listenerDescriptor: Int32
  private var hasStopped = false

  init() throws {
    let directoryURL = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
      .appendingPathComponent(
        "codex-echo-ipc-\(UUID().uuidString.prefix(8))",
        isDirectory: true
      )
    try FileManager.default.createDirectory(
      at: directoryURL,
      withIntermediateDirectories: false
    )
    socketURL = directoryURL.appendingPathComponent("ipc.sock")

    let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else {
      throw IPCUnixSocketTestError.systemCall("socket", errno)
    }
    listenerDescriptor = descriptor
    do {
      try Self.bind(descriptor: descriptor, to: socketURL.path)
      guard Darwin.listen(descriptor, 1) == 0 else {
        throw IPCUnixSocketTestError.systemCall("listen", errno)
      }
    } catch {
      Darwin.close(descriptor)
      try? FileManager.default.removeItem(at: directoryURL)
      throw error
    }
  }

  deinit {
    stop()
  }

  func accept(_ handler: @escaping @Sendable (Int32) throws -> Void) {
    let descriptor = listenerDescriptor
    queue.async {
      let acceptedDescriptor = Darwin.accept(descriptor, nil, nil)
      guard acceptedDescriptor >= 0 else { return }
      defer { Darwin.close(acceptedDescriptor) }
      try? handler(acceptedDescriptor)
    }
  }

  func completeInitializeHandshake(on descriptor: Int32) throws {
    let request = try readFrame(on: descriptor)
    guard let requestID = request["requestId"] as? String else {
      throw IPCUnixSocketTestError.invalidFrame
    }
    try writeFrame(
      [
        "type": "response",
        "requestId": requestID,
        "resultType": "success",
        "method": "initialize",
        "result": ["clientId": "test-client"],
      ],
      on: descriptor
    )
  }

  func readFrame(on descriptor: Int32) throws -> [String: Any] {
    let header = try readExactly(4, from: descriptor)
    let payloadLength = header.enumerated().reduce(0) { result, pair in
      result | (Int(pair.element) << (pair.offset * 8))
    }
    guard payloadLength > 0 else { throw IPCUnixSocketTestError.invalidFrame }
    let payload = try readExactly(payloadLength, from: descriptor)
    guard
      let message = try JSONSerialization.jsonObject(with: payload) as? [String: Any]
    else {
      throw IPCUnixSocketTestError.invalidFrame
    }
    return message
  }

  func hasReadableData(on descriptor: Int32, timeoutMilliseconds: Int32) throws -> Bool {
    var descriptorState = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
    let result = Darwin.poll(&descriptorState, 1, timeoutMilliseconds)
    if result < 0 { throw IPCUnixSocketTestError.systemCall("poll", errno) }
    return result > 0
  }

  func stop() {
    lock.lock()
    guard !hasStopped else {
      lock.unlock()
      return
    }
    hasStopped = true
    let descriptor = listenerDescriptor
    listenerDescriptor = -1
    lock.unlock()

    if descriptor >= 0 { Darwin.close(descriptor) }
    try? FileManager.default.removeItem(
      at: socketURL.deletingLastPathComponent()
    )
  }

  private func readExactly(_ count: Int, from descriptor: Int32) throws -> Data {
    var data = Data(count: count)
    var offset = 0
    while offset < count {
      let bytesRead = data.withUnsafeMutableBytes { buffer in
        Darwin.read(
          descriptor,
          buffer.baseAddress?.advanced(by: offset),
          count - offset
        )
      }
      if bytesRead > 0 {
        offset += bytesRead
        continue
      }
      if bytesRead < 0, errno == EINTR { continue }
      if bytesRead == 0 { throw IPCUnixSocketTestError.connectionClosed }
      throw IPCUnixSocketTestError.systemCall("read", errno)
    }
    return data
  }

  func writeFrame(_ object: [String: Any], on descriptor: Int32) throws {
    let frame = try IPCFrameCodec.encode(jsonObject: object)
    try frame.withUnsafeBytes { buffer in
      guard var pointer = buffer.baseAddress else { return }
      var remaining = buffer.count
      while remaining > 0 {
        let bytesWritten = Darwin.write(descriptor, pointer, remaining)
        if bytesWritten > 0 {
          pointer = pointer.advanced(by: bytesWritten)
          remaining -= bytesWritten
          continue
        }
        if bytesWritten < 0, errno == EINTR { continue }
        throw IPCUnixSocketTestError.systemCall("write", errno)
      }
    }
  }

  private static func bind(descriptor: Int32, to path: String) throws {
    var address = sockaddr_un()
    let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
    guard path.utf8.count + 1 <= pathCapacity else {
      throw IPCUnixSocketTestError.invalidPath
    }
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    address.sun_family = sa_family_t(AF_UNIX)
    _ = withUnsafeMutablePointer(to: &address.sun_path.0) { destination in
      path.withCString { source in
        strlcpy(destination, source, pathCapacity)
      }
    }
    let result = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(
          descriptor,
          $0,
          socklen_t(MemoryLayout<sockaddr_un>.size)
        )
      }
    }
    guard result == 0 else {
      throw IPCUnixSocketTestError.systemCall("bind", errno)
    }
  }
}

private final class LockedValue<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var storedValue: Value

  init(_ value: Value) {
    storedValue = value
  }

  var value: Value {
    lock.lock()
    defer { lock.unlock() }
    return storedValue
  }

  func set(_ value: Value) {
    lock.lock()
    storedValue = value
    lock.unlock()
  }
}

private enum IPCUnixSocketTestError: Error {
  case connectionClosed
  case invalidFrame
  case invalidPath
  case systemCall(String, Int32)
}
