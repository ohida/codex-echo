import Foundation

enum CapacityHistoryStoreError: Error, LocalizedError, Equatable {
  case malformedLine(Int)

  var errorDescription: String? {
    switch self {
    case .malformedLine(let line):
      "Capacity history is damaged near line \(line)."
    }
  }
}

private enum JSONLAppendRecovery {
  static func repairUnterminatedTail<Value: Decodable>(
    at fileURL: URL,
    as _: Value.Type,
    decoder: JSONDecoder
  ) throws {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
    let data = try Data(contentsOf: fileURL)
    guard !data.isEmpty, data.last != 0x0A else { return }

    let lineStart =
      data.lastIndex(of: 0x0A).map(data.index(after:))
      ?? data.startIndex
    let trailingLine = Data(data[lineStart...])
    let handle = try FileHandle(forUpdating: fileURL)
    defer { try? handle.close() }

    if (try? decoder.decode(Value.self, from: trailingLine)) != nil {
      try handle.seekToEnd()
      try handle.write(contentsOf: Data([0x0A]))
    } else {
      try handle.truncate(atOffset: UInt64(lineStart))
    }
  }
}

final class CapacityHistoryStore: Sendable {
  let fileURL: URL

  private let queue = DispatchQueue(
    label: "app.ohida.codex-echo.capacity-history"
  )

  init(fileURL: URL = CapacityHistoryStore.defaultFileURL()) {
    self.fileURL = fileURL
  }

  static func defaultFileURL(
    fileManager: FileManager = .default,
    bundleIdentifier: String? = Bundle.main.bundleIdentifier
  ) -> URL {
    let applicationSupport = fileManager.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first ?? fileManager.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support", isDirectory: true)
    return applicationSupport
      .appendingPathComponent(
        bundleIdentifier ?? "app.ohida.codex-echo",
        isDirectory: true
      )
      .appendingPathComponent("CapacityHistory", isDirectory: true)
      .appendingPathComponent("v1.jsonl")
  }

  func append(_ observation: CapacityObservation) async throws {
    try await withCheckedThrowingContinuation { continuation in
      enqueueAppend(observation) { result in
        continuation.resume(with: result)
      }
    }
  }

  #if DEBUG
    func appendSynchronouslyForDebug(
      _ observation: CapacityObservation
    ) throws {
      try queue.sync {
        try Self.append(observation, to: fileURL)
      }
    }
  #endif

  func enqueueAppend(
    _ observation: CapacityObservation,
    completion: @escaping @Sendable (Result<Void, Error>) -> Void
  ) {
    queue.async { [fileURL] in
      do {
        try Self.append(observation, to: fileURL)
        completion(.success(()))
      } catch {
        completion(.failure(error))
      }
    }
  }

  private static func append(
    _ observation: CapacityObservation,
    to fileURL: URL
  ) throws {
    let fileManager = FileManager.default
    try fileManager.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    var data = try encoder.encode(observation)
    data.append(0x0A)

    if !fileManager.fileExists(atPath: fileURL.path) {
      try data.write(to: fileURL, options: .atomic)
      return
    }

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    try JSONLAppendRecovery.repairUnterminatedTail(
      at: fileURL,
      as: CapacityObservation.self,
      decoder: decoder
    )
    let handle = try FileHandle(forWritingTo: fileURL)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: data)
  }

  func readAll() async throws -> [CapacityObservation] {
    try await withCheckedThrowingContinuation { continuation in
      queue.async { [fileURL] in
        continuation.resume(
          with: Result {
            try Self.readAll(from: fileURL)
          }
        )
      }
    }
  }

  private static func readAll(
    from fileURL: URL
  ) throws -> [CapacityObservation] {
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
      return []
    }
    let data = try Data(contentsOf: fileURL)
    guard !data.isEmpty else { return [] }

    let lines = data.split(
      separator: 0x0A,
      omittingEmptySubsequences: false
    )
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    var observations: [CapacityObservation] = []
    for (index, line) in lines.enumerated() where !line.isEmpty {
      do {
        observations.append(
          try decoder.decode(CapacityObservation.self, from: Data(line))
        )
      } catch {
        let isIncompleteTrailingLine =
          index == lines.count - 1 && data.last != 0x0A
        if isIncompleteTrailingLine { break }
        throw CapacityHistoryStoreError.malformedLine(index + 1)
      }
    }
    return observations.sorted { $0.observedAt < $1.observedAt }
  }

  func clear() async throws {
    try await withCheckedThrowingContinuation { continuation in
      queue.async { [fileURL] in
        continuation.resume(
          with: Result {
            try Self.clear(fileURL: fileURL)
          }
        )
      }
    }
  }

  func clearSynchronously() throws {
    try queue.sync {
      try Self.clear(fileURL: fileURL)
    }
  }

  private static func clear(fileURL: URL) throws {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
    try FileManager.default.removeItem(at: fileURL)
  }

  func csv() async throws -> String {
    let observations = try await readAll()
    return try csv(from: observations)
  }

  func csv(for limit: CapacityHistoryLimit) async throws -> String {
    let observations = try await readAll()
    return try csv(from: observations.filter(limit.matches))
  }

  private func csv(from observations: [CapacityObservation]) throws -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    formatter.timeZone = TimeZone(secondsFromGMT: 0)

    let rows = observations
      .sorted { $0.observedAt < $1.observedAt }
      .map {
        "\(formatter.string(from: $0.observedAt)),\($0.remainingPercent)"
      }
    return (
      ["observedAt,remainingPercent"] + rows
    ).joined(separator: "\n") + "\n"
  }

  func flushSynchronously() {
    queue.sync {}
  }
}
