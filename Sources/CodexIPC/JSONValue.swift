import CoreFoundation
import Foundation

public enum JSONValue: Equatable, Sendable {
  case object([String: JSONValue])
  case array([JSONValue])
  case string(String)
  case number(Double)
  case bool(Bool)
  case null

  public init(any value: Any) throws {
    switch value {
    case is NSNull:
      self = .null
    case let value as String:
      self = .string(value)
    case let value as NSNumber:
      if CFGetTypeID(value) == CFBooleanGetTypeID() {
        self = .bool(value.boolValue)
      } else {
        self = .number(value.doubleValue)
      }
    case let value as [Any]:
      self = .array(try value.map(JSONValue.init(any:)))
    case let value as [String: Any]:
      self = .object(try value.mapValues(JSONValue.init(any:)))
    default:
      throw JSONValueError.unsupportedType(String(describing: type(of: value)))
    }
  }

  public var objectValue: [String: JSONValue]? {
    guard case .object(let value) = self else { return nil }
    return value
  }

  public var arrayValue: [JSONValue]? {
    guard case .array(let value) = self else { return nil }
    return value
  }

  public var stringValue: String? {
    guard case .string(let value) = self else { return nil }
    return value
  }

  public var numberValue: Double? {
    guard case .number(let value) = self else { return nil }
    return value
  }

  public var boolValue: Bool? {
    guard case .bool(let value) = self else { return nil }
    return value
  }

  public subscript(key: String) -> JSONValue? {
    objectValue?[key]
  }

  public func value(at keys: String...) -> JSONValue? {
    keys.reduce(Optional(self)) { value, key in value?[key] }
  }
}

public enum JSONValueError: Error, Equatable, Sendable {
  case unsupportedType(String)
}
