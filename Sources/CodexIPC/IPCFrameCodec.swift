import Foundation

public enum IPCFrameCodec {
  public static let maximumPayloadSize = 256 * 1024 * 1024

  public static func encode(payload: Data) throws -> Data {
    guard !payload.isEmpty, payload.count <= maximumPayloadSize else {
      throw IPCFrameCodecError.invalidPayloadLength(payload.count)
    }
    var length = UInt32(payload.count).littleEndian
    var frame = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
    frame.append(payload)
    return frame
  }

  public static func encode(jsonObject: Any) throws -> Data {
    try encode(payload: JSONSerialization.data(withJSONObject: jsonObject))
  }
}

public struct IPCFrameDecoder: Sendable {
  private var buffer = Data()

  public init() {}

  public mutating func append(_ data: Data) throws -> [Data] {
    buffer.append(data)
    var frames: [Data] = []

    while buffer.count >= MemoryLayout<UInt32>.size {
      let start = buffer.startIndex
      let length =
        Int(buffer[start])
        | Int(buffer[start + 1]) << 8
        | Int(buffer[start + 2]) << 16
        | Int(buffer[start + 3]) << 24
      guard length > 0, length <= IPCFrameCodec.maximumPayloadSize else {
        throw IPCFrameCodecError.invalidPayloadLength(length)
      }
      let frameLength = MemoryLayout<UInt32>.size + length
      guard buffer.count >= frameLength else { break }
      frames.append(buffer.subdata(in: (start + 4)..<(start + frameLength)))
      buffer.removeFirst(frameLength)
    }

    return frames
  }

  public mutating func reset() {
    buffer.removeAll(keepingCapacity: false)
  }
}

public enum IPCFrameCodecError: Error, Equatable, Sendable {
  case invalidPayloadLength(Int)
}
