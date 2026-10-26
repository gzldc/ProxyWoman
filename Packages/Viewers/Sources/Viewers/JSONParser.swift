import Foundation

public struct JSONParseError: Error, Equatable {
    /// 0-based byte offset into the UTF-8 input where the error was detected.
    public var offset: Int
    public var message: String

    public init(offset: Int, message: String) {
        self.offset = offset
        self.message = message
    }
}

/// Order-preserving JSON parser working on UTF-8 bytes. Iterative (explicit container stack), so
/// nesting depth is bounded only by `maxDepth`, never by the thread's stack size.
public enum JSONParser {
    /// Maximum nesting depth of arrays plus objects.
    static let maxDepth = 512

    public static func parse(_ data: Data) throws(JSONParseError) -> JSONNode {
        var parser = Parser(bytes: [UInt8](data))
        return try parser.parseDocument()
    }
}

private struct Parser {
    let bytes: [UInt8]
    var pos = 0

    init(bytes: [UInt8]) { self.bytes = bytes }

    /// An open container. Mutated in place on the stack so appends never copy the buffer.
    private struct Frame {
        var isObject: Bool
        var items: [JSONNode] = []
        var members: [(key: String, value: JSONNode)] = []
        var pendingKey = ""
    }

    mutating func parseDocument() throws(JSONParseError) -> JSONNode {
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { pos = 3 }
        let value = try parseValue()
        skipWhitespace()
        if pos < bytes.count { throw fail("Unexpected trailing content") }
        return value
    }

    private func fail(_ message: String, at offset: Int? = nil) -> JSONParseError {
        JSONParseError(offset: offset ?? pos, message: message)
    }

    private mutating func skipWhitespace() {
        while pos < bytes.count {
            switch bytes[pos] {
            case 0x20, 0x09, 0x0A, 0x0D: pos += 1
            default: return
            }
        }
    }

    /// Parses one value with an explicit container stack instead of recursion,
    /// so nesting depth never depends on the thread's stack size.
    private mutating func parseValue() throws(JSONParseError) -> JSONNode {
        var stack: [Frame] = []
        while true {
            // Phase 1: read the start of a value; containers push a frame and loop.
            skipWhitespace()
            guard pos < bytes.count else { throw fail("Unexpected end of input") }
            var completed: JSONNode
            switch bytes[pos] {
            case UInt8(ascii: "{"):
                try checkDepth(stack.count)
                pos += 1
                skipWhitespace()
                guard pos < bytes.count else { throw fail("Unexpected end of input in object") }
                if bytes[pos] == UInt8(ascii: "}") {
                    pos += 1
                    completed = .object([])
                } else {
                    stack.append(Frame(isObject: true, pendingKey: try parseKeyAndColon()))
                    continue
                }
            case UInt8(ascii: "["):
                try checkDepth(stack.count)
                pos += 1
                skipWhitespace()
                guard pos < bytes.count else { throw fail("Unexpected end of input in array") }
                if bytes[pos] == UInt8(ascii: "]") {
                    pos += 1
                    completed = .array([])
                } else {
                    stack.append(Frame(isObject: false))
                    continue
                }
            case UInt8(ascii: "\""): completed = .string(try parseString())
            case UInt8(ascii: "t"):
                try expectLiteral("true")
                completed = .bool(true)
            case UInt8(ascii: "f"):
                try expectLiteral("false")
                completed = .bool(false)
            case UInt8(ascii: "n"):
                try expectLiteral("null")
                completed = .null
            case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"):
                completed = .number(try parseNumber())
            default: throw fail("Unexpected character")
            }

            // Phase 2: attach the finished value to its parent, closing containers as they end.
            attach: while true {
                guard !stack.isEmpty else { return completed }
                let last = stack.count - 1
                if stack[last].isObject {
                    let key = stack[last].pendingKey
                    stack[last].members.append((key: key, value: completed))
                    skipWhitespace()
                    guard pos < bytes.count else { throw fail("Unexpected end of input in object") }
                    switch bytes[pos] {
                    case UInt8(ascii: ","):
                        pos += 1
                        skipWhitespace()
                        stack[last].pendingKey = try parseKeyAndColon()
                        break attach
                    case UInt8(ascii: "}"):
                        pos += 1
                        completed = .object(stack.removeLast().members)
                    default: throw fail("Expected ',' or '}' in object")
                    }
                } else {
                    stack[last].items.append(completed)
                    skipWhitespace()
                    guard pos < bytes.count else { throw fail("Unexpected end of input in array") }
                    switch bytes[pos] {
                    case UInt8(ascii: ","):
                        pos += 1
                        break attach
                    case UInt8(ascii: "]"):
                        pos += 1
                        completed = .array(stack.removeLast().items)
                    default: throw fail("Expected ',' or ']' in array")
                    }
                }
            }
        }
    }

    private func checkDepth(_ current: Int) throws(JSONParseError) {
        if current >= JSONParser.maxDepth {
            throw fail("Exceeds maximum nesting depth of \(JSONParser.maxDepth)")
        }
    }

    /// Reads `"key" :` and leaves `pos` at the start of the value (whitespace not yet skipped).
    private mutating func parseKeyAndColon() throws(JSONParseError) -> String {
        guard pos < bytes.count else { throw fail("Unexpected end of input in object") }
        guard bytes[pos] == UInt8(ascii: "\"") else { throw fail("Expected string key") }
        let key = try parseString()
        skipWhitespace()
        guard pos < bytes.count else { throw fail("Unexpected end of input in object") }
        guard bytes[pos] == UInt8(ascii: ":") else { throw fail("Expected ':' after key") }
        pos += 1
        return key
    }

    private mutating func expectLiteral(_ literal: StaticString) throws(JSONParseError) {
        let start = pos
        let count = literal.utf8CodeUnitCount
        let expected = UnsafeBufferPointer(start: literal.utf8Start, count: count)
        for i in 0..<count {
            guard pos < bytes.count, bytes[pos] == expected[i] else {
                throw fail("Invalid literal", at: pos < bytes.count ? pos : start)
            }
            pos += 1
        }
    }

    private mutating func parseNumber() throws(JSONParseError) -> String {
        let start = pos
        if bytes[pos] == UInt8(ascii: "-") { pos += 1 }
        guard pos < bytes.count, isDigit(bytes[pos]) else { throw fail("Invalid number") }
        if bytes[pos] == UInt8(ascii: "0") {
            pos += 1
        } else {
            while pos < bytes.count, isDigit(bytes[pos]) { pos += 1 }
        }
        if pos < bytes.count, bytes[pos] == UInt8(ascii: ".") {
            pos += 1
            guard pos < bytes.count, isDigit(bytes[pos]) else { throw fail("Invalid number: digit expected after '.'") }
            while pos < bytes.count, isDigit(bytes[pos]) { pos += 1 }
        }
        if pos < bytes.count, bytes[pos] == UInt8(ascii: "e") || bytes[pos] == UInt8(ascii: "E") {
            pos += 1
            if pos < bytes.count, bytes[pos] == UInt8(ascii: "+") || bytes[pos] == UInt8(ascii: "-") { pos += 1 }
            guard pos < bytes.count, isDigit(bytes[pos]) else { throw fail("Invalid number: digit expected in exponent") }
            while pos < bytes.count, isDigit(bytes[pos]) { pos += 1 }
        }
        // The grammar above only admits ASCII, so this is always valid UTF-8.
        return String(decoding: bytes[start..<pos], as: UTF8.self)
    }

    private func isDigit(_ b: UInt8) -> Bool { b >= 0x30 && b <= 0x39 }

    private mutating func parseString() throws(JSONParseError) -> String {
        let start = pos
        pos += 1  // opening quote
        var buf: [UInt8] = []
        while true {
            guard pos < bytes.count else { throw fail("Unterminated string", at: start) }
            let b = bytes[pos]
            switch b {
            case UInt8(ascii: "\""):
                pos += 1
                // Raw bytes are copied verbatim, so validate UTF-8 once at the end.
                guard let s = String(bytes: buf, encoding: .utf8) else {
                    throw fail("Invalid UTF-8 in string", at: start)
                }
                return s
            case UInt8(ascii: "\\"):
                try parseEscape(into: &buf)
            case 0..<0x20:
                throw fail("Unescaped control character in string")
            default:
                buf.append(b)
                pos += 1
            }
        }
    }

    private mutating func parseEscape(into buf: inout [UInt8]) throws(JSONParseError) {
        let escapeStart = pos
        pos += 1  // backslash
        guard pos < bytes.count else { throw fail("Unterminated string") }
        let c = bytes[pos]
        pos += 1
        switch c {
        case UInt8(ascii: "\""): buf.append(0x22)
        case UInt8(ascii: "\\"): buf.append(0x5C)
        case UInt8(ascii: "/"): buf.append(0x2F)
        case UInt8(ascii: "b"): buf.append(0x08)
        case UInt8(ascii: "f"): buf.append(0x0C)
        case UInt8(ascii: "n"): buf.append(0x0A)
        case UInt8(ascii: "r"): buf.append(0x0D)
        case UInt8(ascii: "t"): buf.append(0x09)
        case UInt8(ascii: "u"):
            var code = try parseHex4()
            if (0xD800...0xDBFF).contains(code) {
                guard pos + 1 < bytes.count, bytes[pos] == UInt8(ascii: "\\"), bytes[pos + 1] == UInt8(ascii: "u")
                else { throw fail("Unpaired high surrogate escape", at: escapeStart) }
                pos += 2
                let low = try parseHex4()
                guard (0xDC00...0xDFFF).contains(low) else {
                    throw fail("High surrogate not followed by low surrogate", at: escapeStart)
                }
                code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
            } else if (0xDC00...0xDFFF).contains(code) {
                throw fail("Unpaired low surrogate escape", at: escapeStart)
            }
            // Surrogates are excluded above, so the scalar is always valid.
            buf.append(contentsOf: Array(String(Unicode.Scalar(code)!).utf8))
        default:
            throw fail("Invalid escape sequence", at: escapeStart)
        }
    }

    private mutating func parseHex4() throws(JSONParseError) -> UInt32 {
        var value: UInt32 = 0
        for _ in 0..<4 {
            guard pos < bytes.count else { throw fail("Unterminated \\u escape") }
            let b = bytes[pos]
            let digit: UInt32
            switch b {
            case 0x30...0x39: digit = UInt32(b - 0x30)
            case 0x41...0x46: digit = UInt32(b - 0x41 + 10)
            case 0x61...0x66: digit = UInt32(b - 0x61 + 10)
            default: throw fail("Invalid hex digit in \\u escape")
            }
            value = value << 4 | digit
            pos += 1
        }
        return value
    }
}
