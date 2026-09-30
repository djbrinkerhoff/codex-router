import Foundation

/// A JSON document as the router wrote it.
///
/// The Control Center renders snapshots produced by a router that may be newer
/// or older than this app. A strict `Codable` model fails a whole page on one
/// unexpected field, so pages read through this value and its lenient
/// accessors instead: a missing or mistyped field reads as `nil`, and the page
/// shows "not reported" for that one value.
public enum JSONValue: Equatable, Sendable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])

  // MARK: Parsing

  public static func parse(_ data: Data) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: data)
  }

  public static func parse(_ text: String) throws -> JSONValue {
    try parse(Data(text.utf8))
  }

  public func encoded() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(self)
  }

  // MARK: Access

  public subscript(key: String) -> JSONValue? {
    if case .object(let object) = self { return object[key] }
    return nil
  }

  public subscript(index: Int) -> JSONValue? {
    if case .array(let array) = self, array.indices.contains(index) { return array[index] }
    return nil
  }

  /// Follows a key path; `nil` as soon as one step is missing.
  public func value(at path: String...) -> JSONValue? {
    value(atPath: path)
  }

  public func value(atPath path: [String]) -> JSONValue? {
    var current: JSONValue? = self
    for key in path { current = current?[key] }
    return current
  }

  public var isNull: Bool {
    if case .null = self { return true }
    return false
  }

  public var string: String? {
    if case .string(let value) = self { return value }
    return nil
  }

  /// A non-empty, trimmed string.
  public var text: String? {
    guard let value = string?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
    return value
  }

  public var bool: Bool? {
    if case .bool(let value) = self { return value }
    return nil
  }

  /// A finite number. Numeric strings are accepted, matching `Number(value)`
  /// in the renderer this replaces.
  public var double: Double? {
    switch self {
    case .number(let value): return value.isFinite ? value : nil
    case .string(let value):
      guard let parsed = Double(value.trimmingCharacters(in: .whitespaces)), parsed.isFinite else { return nil }
      return parsed
    default: return nil
    }
  }

  public var int: Int? {
    guard let value = double, value >= Double(Int.min), value <= Double(Int.max) else { return nil }
    return Int(value.rounded(.towardZero))
  }

  public var array: [JSONValue]? {
    if case .array(let value) = self { return value }
    return nil
  }

  public var object: [String: JSONValue]? {
    if case .object(let value) = self { return value }
    return nil
  }

  /// Array elements, or an empty array for anything else.
  public var items: [JSONValue] { array ?? [] }

  /// Object keys, sorted for stable rendering.
  public var keys: [String] { object?.keys.sorted() ?? [] }

  /// String elements of an array, skipping anything that is not a string.
  public var strings: [String] { items.compactMap(\.string) }

  /// JavaScript truthiness, for porting `Boolean(value)` checks faithfully.
  public var truthy: Bool {
    switch self {
    case .null: return false
    case .bool(let value): return value
    case .number(let value): return value != 0 && !value.isNaN
    case .string(let value): return !value.isEmpty
    case .array, .object: return true
    }
  }
}

extension Optional where Wrapped == JSONValue {
  /// `nil` reads as JavaScript `undefined`: falsy.
  public var truthy: Bool { self?.truthy ?? false }
}

// MARK: Codable

extension JSONValue: Codable {
  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([JSONValue].self) {
      self = .array(value)
    } else if let value = try? container.decode([String: JSONValue].self) {
      self = .object(value)
    } else {
      throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value.")
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null: try container.encodeNil()
    case .bool(let value): try container.encode(value)
    case .number(let value): try container.encode(value)
    case .string(let value): try container.encode(value)
    case .array(let value): try container.encode(value)
    case .object(let value): try container.encode(value)
    }
  }
}

// MARK: Literals

extension JSONValue: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
  ExpressibleByFloatLiteral, ExpressibleByStringLiteral, ExpressibleByArrayLiteral,
  ExpressibleByDictionaryLiteral
{
  public init(nilLiteral: ()) { self = .null }
  public init(booleanLiteral value: Bool) { self = .bool(value) }
  public init(integerLiteral value: Int) { self = .number(Double(value)) }
  public init(floatLiteral value: Double) { self = .number(value) }
  public init(stringLiteral value: String) { self = .string(value) }
  public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
  public init(dictionaryLiteral elements: (String, JSONValue)...) {
    self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
  }
}

extension JSONValue {
  public init(_ value: Int) { self = .number(Double(value)) }
  public init(_ value: Double) { self = .number(value) }
  public init(_ value: String) { self = .string(value) }
  public init(_ value: Bool) { self = .bool(value) }
  public init(_ values: [String]) { self = .array(values.map(JSONValue.string)) }
}

// MARK: Updating

extension JSONValue {
  /// A copy with `value` stored at `path`, creating objects along the way.
  /// Used to merge a polled sub-snapshot (download progress) into the one
  /// the page already renders without refetching the whole snapshot.
  public func setting(_ value: JSONValue, at path: [String]) -> JSONValue {
    guard let key = path.first else { return value }
    var object = self.object ?? [:]
    object[key] = (object[key] ?? .object([:])).setting(value, at: Array(path.dropFirst()))
    return .object(object)
  }
}
