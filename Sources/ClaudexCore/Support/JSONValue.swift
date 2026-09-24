import Foundation

/// A lenient, Sendable JSON tree for fields whose shape varies between tool versions.
public enum JSONValue: Sendable, Hashable, Decodable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let d = try? c.decode(Double.self) { self = .number(d); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
        if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON value")
    }

    public subscript(key: String) -> JSONValue? {
        if case let .object(o) = self { return o[key] }
        return nil
    }

    public subscript(index: Int) -> JSONValue? {
        if case let .array(a) = self, a.indices.contains(index) { return a[index] }
        return nil
    }

    public var string: String? {
        if case let .string(s) = self { return s }
        return nil
    }

    public var double: Double? {
        switch self {
        case let .number(d): return d
        case let .string(s): return Double(s)
        default: return nil
        }
    }

    public var int: Int? { double.flatMap { $0.isFinite ? Int(exactly: $0.rounded()) : nil } }

    public var bool: Bool? {
        if case let .bool(b) = self { return b }
        return nil
    }

    public var array: [JSONValue]? {
        if case let .array(a) = self { return a }
        return nil
    }

    public var object: [String: JSONValue]? {
        if case let .object(o) = self { return o }
        return nil
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }
}

extension KeyedDecodingContainer {
    /// Decodes a value if present and well-typed; a wrong type yields nil instead of failing.
    func lenient<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        (try? decodeIfPresent(type, forKey: key)) ?? nil
    }
}
