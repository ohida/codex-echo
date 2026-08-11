import CoreFoundation
import Foundation

public enum JSONPathComponent: Equatable, Sendable {
  case key(String)
  case index(Int)
}

public enum JSONPatchOperation: String, Equatable, Sendable {
  case add
  case replace
  case remove
}

public struct JSONPatch: Equatable, Sendable {
  public let operation: JSONPatchOperation
  public let path: [JSONPathComponent]
  public let value: JSONValue?

  public init(operation: JSONPatchOperation, path: [JSONPathComponent], value: JSONValue? = nil) {
    self.operation = operation
    self.path = path
    self.value = value
  }

  public init(any value: Any) throws {
    guard let object = value as? [String: Any],
      let operationName = object["op"] as? String,
      let operation = JSONPatchOperation(rawValue: operationName),
      let rawPath = object["path"] as? [Any]
    else {
      throw JSONPatchError.invalidPatch
    }

    self.operation = operation
    self.path = try rawPath.map { component in
      if let key = component as? String { return .key(key) }
      if let number = component as? NSNumber,
        CFGetTypeID(number) != CFBooleanGetTypeID()
      {
        return .index(number.intValue)
      }
      throw JSONPatchError.invalidPathComponent
    }
    self.value = try object["value"].map(JSONValue.init(any:))
  }
}

extension JSONValue {
  public mutating func apply(_ patches: [JSONPatch]) throws {
    for patch in patches {
      try apply(patch, depth: 0)
    }
  }

  private mutating func apply(_ patch: JSONPatch, depth: Int) throws {
    guard !patch.path.isEmpty else {
      switch patch.operation {
      case .add, .replace:
        guard let value = patch.value else { throw JSONPatchError.missingValue }
        self = value
      case .remove:
        self = .null
      }
      return
    }

    let component = patch.path[depth]
    let isLeaf = depth == patch.path.count - 1
    switch (self, component) {
    case (let .object(current), let .key(key)):
      var object = current
      if isLeaf {
        try object.applyLeaf(patch, key: key)
      } else {
        guard var child = object[key] else { throw JSONPatchError.pathNotFound }
        try child.apply(patch, depth: depth + 1)
        object[key] = child
      }
      self = .object(object)

    case (let .array(current), let .index(index)):
      var array = current
      if isLeaf {
        try array.applyLeaf(patch, index: index)
      } else {
        guard array.indices.contains(index) else { throw JSONPatchError.pathNotFound }
        var child = array[index]
        try child.apply(patch, depth: depth + 1)
        array[index] = child
      }
      self = .array(array)

    default:
      throw JSONPatchError.containerTypeMismatch
    }
  }
}

extension Dictionary where Key == String, Value == JSONValue {
  fileprivate mutating func applyLeaf(_ patch: JSONPatch, key: String) throws {
    switch patch.operation {
    case .add:
      guard let value = patch.value else { throw JSONPatchError.missingValue }
      self[key] = value
    case .replace:
      guard self[key] != nil else { throw JSONPatchError.pathNotFound }
      guard let value = patch.value else { throw JSONPatchError.missingValue }
      self[key] = value
    case .remove:
      guard removeValue(forKey: key) != nil else { throw JSONPatchError.pathNotFound }
    }
  }
}

extension Array where Element == JSONValue {
  fileprivate mutating func applyLeaf(_ patch: JSONPatch, index: Int) throws {
    switch patch.operation {
    case .add:
      guard index >= 0, index <= count else { throw JSONPatchError.pathNotFound }
      guard let value = patch.value else { throw JSONPatchError.missingValue }
      insert(value, at: index)
    case .replace:
      guard indices.contains(index) else { throw JSONPatchError.pathNotFound }
      guard let value = patch.value else { throw JSONPatchError.missingValue }
      self[index] = value
    case .remove:
      guard indices.contains(index) else { throw JSONPatchError.pathNotFound }
      remove(at: index)
    }
  }
}

public enum JSONPatchError: Error, Equatable, Sendable {
  case invalidPatch
  case invalidPathComponent
  case missingValue
  case pathNotFound
  case containerTypeMismatch
}
