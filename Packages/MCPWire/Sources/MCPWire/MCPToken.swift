import Foundation
import Security

public enum MCPToken {
    public enum Failure: Error, Equatable {
        case randomSourceUnavailable(Int32)
    }

    /// 32 random bytes from `SecRandomCopyBytes`, hex encoded (64 lowercase characters).
    /// Throws if the system source fails; there is deliberately no weaker fallback.
    public static func generate() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = bytes.withUnsafeMutableBytes { raw in
            SecRandomCopyBytes(kSecRandomDefault, raw.count, raw.baseAddress!)
        }
        guard status == errSecSuccess else { throw Failure.randomSourceUnavailable(status) }
        return hexString(bytes)
    }

    /// Compares without an early exit on the first differing byte. Different lengths are never
    /// equal (the length of a token is not secret).
    public static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let left = Array(a.utf8)
        let right = Array(b.utf8)
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for index in left.indices { difference |= left[index] ^ right[index] }
        return difference == 0
    }

    static func hexString(_ bytes: [UInt8]) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var out = [UInt8]()
        out.reserveCapacity(bytes.count * 2)
        for byte in bytes {
            out.append(digits[Int(byte >> 4)])
            out.append(digits[Int(byte & 0x0F)])
        }
        return String(decoding: out, as: UTF8.self)
    }
}

/// First line a client sends on the socket, in the form `{"hello":{...}}`.
public struct MCPHello: Codable, Equatable, Sendable {
    public var token: String
    public var client: String
    public var protocolVersion: Int

    public init(token: String, client: String, protocolVersion: Int) {
        self.token = token
        self.client = client
        self.protocolVersion = protocolVersion
    }
}

extension MCPHello {
    private struct Envelope: Decodable {
        var hello: MCPHello
    }

    /// The wire form: one compact line `{"hello":{"client":...,"protocolVersion":...,"token":...}}`
    /// without a trailing newline (the sender appends `\n`).
    public func line() -> Data {
        let value: JSONValue = .object([
            "hello": .object([
                "token": .string(token),
                "client": .string(client),
                "protocolVersion": .int(protocolVersion),
            ])
        ])
        return (try? value.encoded()) ?? Data()
    }

    /// Parses one hello line (without its newline). Nil for anything that is not exactly the wrapped
    /// form with a string `token`, a string `client` and an integer `protocolVersion`.
    public static func parse(line: Data) -> MCPHello? {
        try? JSONDecoder().decode(Envelope.self, from: line).hello
    }
}
