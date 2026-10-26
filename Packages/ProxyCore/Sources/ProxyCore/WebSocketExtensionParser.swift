import Foundation

public struct WebSocketExtensionParameter: Sendable, Equatable {
    public let name: String
    public let value: String?
    public init(name: String, value: String? = nil) { self.name = name; self.value = value }
}

public struct WebSocketExtensionOffer: Sendable, Equatable {
    public let name: String
    public let parameters: [WebSocketExtensionParameter]
    public init(name: String, parameters: [WebSocketExtensionParameter] = []) {
        self.name = name; self.parameters = parameters
    }
}

/// RFC6455 extension-list grammar. Field order and duplicate parameters are retained;
/// negotiation, rather than syntax parsing, decides whether duplicates are legal.
public enum WebSocketExtensionParser {
    public enum ParseError: Error { case invalidSyntax }

    public static func parse(_ fields: [String]) throws -> [WebSocketExtensionOffer] {
        var result: [WebSocketExtensionOffer] = []
        for field in fields {
            var cursor = Cursor(bytes: Array(field.utf8))
            cursor.ows()
            guard !cursor.atEnd else { throw ParseError.invalidSyntax }
            while true {
                let name = try cursor.token()
                var parameters: [WebSocketExtensionParameter] = []
                cursor.ows()
                while cursor.take(59) {
                    cursor.ows()
                    let parameter = try cursor.token()
                    cursor.ows()
                    var value: String?
                    if cursor.take(61) {
                        cursor.ows()
                        value = try cursor.value()
                        cursor.ows()
                    }
                    parameters.append(.init(name: parameter, value: value))
                }
                result.append(.init(name: name, parameters: parameters))
                if cursor.atEnd { break }
                guard cursor.take(44) else { throw ParseError.invalidSyntax }
                cursor.ows()
                guard !cursor.atEnd else { throw ParseError.invalidSyntax }
            }
        }
        return result
    }

    static func isTokenByte(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
            || [33, 35, 36, 37, 38, 39, 42, 43, 45, 46, 94, 95, 96, 124, 126].contains(byte)
    }

    private struct Cursor {
        let bytes: [UInt8]
        var index = 0
        var atEnd: Bool { index == bytes.count }
        mutating func ows() { while !atEnd && (bytes[index] == 32 || bytes[index] == 9) { index += 1 } }
        mutating func take(_ byte: UInt8) -> Bool {
            guard !atEnd, bytes[index] == byte else { return false }
            index += 1; return true
        }
        mutating func token() throws -> String {
            let start = index
            while !atEnd && isTokenByte(bytes[index]) { index += 1 }
            guard index > start else { throw ParseError.invalidSyntax }
            return String(decoding: bytes[start..<index], as: UTF8.self)
        }
        mutating func value() throws -> String {
            guard take(34) else { return try token() }
            var decoded: [UInt8] = []
            while !atEnd {
                if take(34) {
                    // RFC6455 §9.1: unescaped quoted value MUST conform to token.
                    guard !decoded.isEmpty, decoded.allSatisfy(isTokenByte) else { throw ParseError.invalidSyntax }
                    return String(decoding: decoded, as: UTF8.self)
                }
                let escaped = take(92)
                guard !atEnd else { throw ParseError.invalidSyntax }
                let byte = bytes[index]; index += 1
                guard escaped ? (byte == 9 || byte >= 32 && byte != 127) : (byte == 9 || byte == 32 || byte == 33 || byte >= 35 && byte != 92 && byte != 127) else {
                    throw ParseError.invalidSyntax
                }
                decoded.append(byte)
            }
            throw ParseError.invalidSyntax
        }
    }
}
