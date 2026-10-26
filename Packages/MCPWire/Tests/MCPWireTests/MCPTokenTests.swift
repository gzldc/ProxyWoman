import Foundation
import Testing

@testable import MCPWire

@Suite struct MCPTokenTests {
    @Test func generatesDistinct64HexTokens() throws {
        var seen = Set<String>()
        for _ in 0..<64 {
            let token = try MCPToken.generate()
            #expect(token.utf8.count == 64)
            #expect(token.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) })
            seen.insert(token)
        }
        #expect(seen.count == 64)
    }

    @Test func constantTimeEqualBehaves() throws {
        let a = try MCPToken.generate()
        #expect(MCPToken.constantTimeEqual(a, a))
        #expect(MCPToken.constantTimeEqual(a, String(a)))
        var other = Array(a)
        other[63] = other[63] == "0" ? "1" : "0"
        #expect(!MCPToken.constantTimeEqual(a, String(other)))
        var first = Array(a)
        first[0] = first[0] == "0" ? "1" : "0"
        #expect(!MCPToken.constantTimeEqual(a, String(first)))
        #expect(!MCPToken.constantTimeEqual(a, String(a.dropLast())))
        #expect(!MCPToken.constantTimeEqual(a, a + "0"))
        #expect(!MCPToken.constantTimeEqual(a, ""))
        #expect(MCPToken.constantTimeEqual("", ""))
    }

    @Test func helloUsesTheWireFieldNames() throws {
        let hello = MCPHello(token: "t", client: "proxywoman-mcp", protocolVersion: 1)
        let json = try JSONValue.parse(JSONEncoder().encode(hello))
        #expect(json == .object([
            "token": .string("t"), "client": .string("proxywoman-mcp"), "protocolVersion": .int(1),
        ]))
        let back = try JSONDecoder().decode(MCPHello.self, from: JSONEncoder().encode(hello))
        #expect(back == hello)
    }

    @Test func helloLineIsOneWrappedLineWithoutNewline() throws {
        let hello = MCPHello(token: "t\nx", client: "proxywoman-mcp", protocolVersion: 1)
        let line = hello.line()
        #expect(!line.contains(0x0A) && !line.contains(0x0D))
        let json = try JSONValue.parse(line)
        #expect(json == .object([
            "hello": .object([
                "token": .string("t\nx"), "client": .string("proxywoman-mcp"), "protocolVersion": .int(1),
            ])
        ]))
    }

    @Test func helloLineRoundTrips() {
        let hello = MCPHello(token: String(repeating: "ab12", count: 16), client: "c \"q\" é", protocolVersion: 1)
        #expect(MCPHello.parse(line: hello.line()) == hello)
    }

    @Test func helloParseRejectsAnythingElse() {
        let bare = Data(#"{"token":"t","client":"c","protocolVersion":1}"#.utf8)
        #expect(MCPHello.parse(line: bare) == nil)
        #expect(MCPHello.parse(line: Data("garbage".utf8)) == nil)
        #expect(MCPHello.parse(line: Data()) == nil)
        #expect(MCPHello.parse(line: Data("[]".utf8)) == nil)
        #expect(MCPHello.parse(line: Data(#"{"hello":null}"#.utf8)) == nil)
        #expect(MCPHello.parse(line: Data(#"{"hello":{"token":"t","client":"c"}}"#.utf8)) == nil)
        #expect(MCPHello.parse(line: Data(#"{"hello":{"token":1,"client":"c","protocolVersion":1}}"#.utf8)) == nil)
        #expect(MCPHello.parse(line: Data(#"{"hello":{"token":"t","client":"c","protocolVersion":"1"}}"#.utf8)) == nil)
        let good = MCPHello(token: "t", client: "c", protocolVersion: 1).line()
        #expect(MCPHello.parse(line: good + Data("x".utf8)) == nil)
    }
}
