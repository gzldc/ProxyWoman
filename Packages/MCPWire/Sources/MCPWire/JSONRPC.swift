import Foundation

public enum JSONRPCID: Sendable, Hashable, Codable {
    case int(Int)
    case string(String)

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "JSON-RPC id must be an integer or a string")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .int(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        }
    }

    var jsonValue: JSONValue {
        switch self {
        case .int(let value): .int(value)
        case .string(let value): .string(value)
        }
    }
}

public struct JSONRPCError: Error, Sendable, Equatable {
    public var code: Int
    public var message: String
    public var data: JSONValue?

    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    public static func parseError(_ message: String = "Parse error") -> Self {
        Self(code: -32700, message: message)
    }

    public static func invalidRequest(_ message: String = "Invalid Request") -> Self {
        Self(code: -32600, message: message)
    }

    public static func methodNotFound(_ message: String) -> Self {
        Self(code: -32601, message: message)
    }

    public static func invalidParams(_ message: String) -> Self {
        Self(code: -32602, message: message)
    }

    public static func internalError(_ message: String) -> Self {
        Self(code: -32603, message: message)
    }

    /// Server-defined: the app is not running or MCP is switched off.
    public static func appUnavailable(_ message: String) -> Self {
        Self(code: -32000, message: message)
    }
}

public enum JSONRPCInbound: Sendable, Equatable {
    case request(id: JSONRPCID, method: String, params: JSONValue?)
    case notification(method: String, params: JSONValue?)
    /// Malformed JSON, a batch array, a missing/non-string method, a wrong `jsonrpc` version, or a
    /// bad `id`/`params` type. `id` is kept when it could be read, so the error reply can echo it.
    case invalid(id: JSONRPCID?, JSONRPCError)

    /// Largest request line `parse` looks at (the transport frames lines at this size already).
    public static let maxMessageBytes = 1 << 20

    public static func parse(line: Data) -> JSONRPCInbound {
        guard line.count <= maxMessageBytes else { return .invalid(id: nil, .invalidRequest()) }
        let value: JSONValue
        do {
            value = try JSONValue.parse(line)
        } catch JSONValue.ParseError.tooDeep {
            return .invalid(id: nil, .invalidRequest())
        } catch {
            return .invalid(id: nil, .parseError())
        }
        guard case .object(let members) = value else {
            // Batch arrays and scalars are not supported (MCP 2025-06-18 removed batching).
            return .invalid(id: nil, .invalidRequest())
        }

        // `id`: absent => notification; int/string => request; anything else (null, float, bool,
        // object, array) is invalid and cannot be echoed.
        var id: JSONRPCID?
        if let rawID = members["id"] {
            switch rawID {
            case .int(let value): id = .int(value)
            case .string(let value): id = .string(value)
            default: return .invalid(id: nil, .invalidRequest())
            }
        }

        guard members["jsonrpc"]?.stringValue == "2.0" else {
            return .invalid(id: id, .invalidRequest())
        }
        guard let method = members["method"]?.stringValue else {
            return .invalid(id: id, .invalidRequest())
        }

        var params: JSONValue?
        if let rawParams = members["params"] {
            switch rawParams {
            case .object, .array: params = rawParams
            default: return .invalid(id: id, .invalidRequest())
            }
        }

        if let id {
            return .request(id: id, method: method, params: params)
        }
        return .notification(method: method, params: params)
    }
}

public enum JSONRPCOutbound {
    /// One compact line, no trailing newline.
    public static func result(id: JSONRPCID, _ result: JSONValue) -> Data {
        let message: JSONValue = .object([
            "jsonrpc": .string("2.0"),
            "id": id.jsonValue,
            "result": result,
        ])
        if let data = try? message.encoded() { return data }
        // A result that cannot be encoded (e.g. a non-finite number) must not drop the reply.
        return error(id: id, .internalError("Result could not be encoded"))
    }

    /// One compact line, no trailing newline. `id` is JSON null when unknown.
    public static func error(id: JSONRPCID?, _ error: JSONRPCError) -> Data {
        var body: [String: JSONValue] = [
            "code": .int(error.code),
            "message": .string(error.message),
        ]
        if let data = error.data { body["data"] = data }
        let message: JSONValue = .object([
            "jsonrpc": .string("2.0"),
            "id": id?.jsonValue ?? .null,
            "error": .object(body),
        ])
        if let data = try? message.encoded() { return data }
        // Last resort when error.data itself is unencodable: drop it.
        let fallback: JSONValue = .object([
            "jsonrpc": .string("2.0"),
            "id": id?.jsonValue ?? .null,
            "error": .object(["code": .int(-32603), "message": .string("Error could not be encoded")]),
        ])
        return (try? fallback.encoded())
            ?? Data(#"{"error":{"code":-32603,"message":"Error could not be encoded"},"id":null,"jsonrpc":"2.0"}"#.utf8)
    }
}
