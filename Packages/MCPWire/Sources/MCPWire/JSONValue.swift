import Foundation

/// A minimal JSON value tree. Foundation-only; shared by the app-side server and the stdio helper.
public enum JSONValue: Sendable, Equatable, Hashable, Codable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    /// Object member lookup; nil for any non-object value or a missing key.
    public subscript(key: String) -> JSONValue? {
        guard case .object(let members) = self else { return nil }
        return members[key]
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var intValue: Int? {
        if case .int(let value) = self { return value }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    /// Compact, sorted-key, single-line UTF-8 JSON. Newlines inside strings are escaped, so the
    /// output never contains a raw `\n` or `\r`. Throws for non-finite doubles.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// Deepest array/object nesting `parse` accepts. The decoder recurses once per level, so a hostile
    /// peer must not be able to pick the depth.
    public static let maxDepth = 64

    public enum ParseError: Error, Sendable, Equatable {
        case tooDeep
    }

    /// Parses exactly one JSON value; trailing non-whitespace bytes are an error. Input nested deeper
    /// than `maxDepth` throws `ParseError.tooDeep` before any decoding happens.
    public static func parse(_ data: Data) throws -> JSONValue {
        guard nestingDepth(of: data) <= maxDepth else { throw ParseError.tooDeep }
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// Deepest `[`/`{` nesting in one linear pass that skips string literals (so brackets inside strings
    /// do not count). Malformed input is not diagnosed here; the decoder does that.
    static func nestingDepth(of data: Data) -> Int {
        var depth = 0
        var deepest = 0
        var inString = false
        var escaped = false
        for byte in data {
            if inString {
                if escaped {
                    escaped = false
                } else if byte == 0x5C {
                    escaped = true
                } else if byte == 0x22 {
                    inString = false
                }
                continue
            }
            switch byte {
            case 0x22:
                inString = true
            case 0x5B, 0x7B:
                depth += 1
                deepest = max(deepest, depth)
            case 0x5D, 0x7D:
                depth = max(0, depth - 1)
            default:
                break
            }
        }
        return deepest
    }
}
