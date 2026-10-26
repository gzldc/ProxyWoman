import Foundation
import Testing

@testable import MCPWire

@Suite struct JSONRPCTests {
    private func parse(_ text: String) -> JSONRPCInbound {
        JSONRPCInbound.parse(line: Data(text.utf8))
    }

    private func decodeOutbound(_ data: Data) throws -> JSONValue {
        try JSONValue.parse(data)
    }

    @Test func requestWithIntAndStringIDs() {
        let a = parse(#"{"jsonrpc":"2.0","id":7,"method":"tools/list","params":{"cursor":"x"}}"#)
        #expect(a == .request(id: .int(7), method: "tools/list", params: .object(["cursor": .string("x")])))
        let b = parse(#"{"jsonrpc":"2.0","id":"abc","method":"ping"}"#)
        #expect(b == .request(id: .string("abc"), method: "ping", params: nil))
        let c = parse(#"{"jsonrpc":"2.0","id":1,"method":"m","params":[1,2]}"#)
        #expect(c == .request(id: .int(1), method: "m", params: .array([.int(1), .int(2)])))
    }

    private func nested(_ depth: Int) -> String {
        String(repeating: "[", count: depth) + String(repeating: "]", count: depth)
    }

    @Test func absurdlyDeepNestingIsRejectedAsInvalidRequestWithoutCrashing() {
        for depth in [10_000, 100_000] {
            let line = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"arguments":"# + nested(depth) + "}}"
            #expect(parse(line) == .invalid(id: nil, .invalidRequest()), "depth \(depth)")
        }
        #expect(throws: (any Error).self) { try JSONValue.parse(Data(nested(10_000).utf8)) }
        // Objects count too, and brackets inside strings do not.
        let objects = String(repeating: #"{"a":"#, count: 5_000) + "1" + String(repeating: "}", count: 5_000)
        #expect(parse(objects) == .invalid(id: nil, .invalidRequest()))
        let inString = #"{"jsonrpc":"2.0","id":2,"method":"ping","params":{"s":"\#(String(repeating: "[", count: 5_000))\\\"[["}}"#
        if case .request(let id, _, _) = parse(inString) { #expect(id == .int(2)) } else { Issue.record("brackets in strings must not count") }
    }

    @Test func nestingLimitIsSixtyFourLevels() throws {
        #expect(JSONValue.maxDepth == 64)
        _ = try JSONValue.parse(Data(nested(64).utf8))
        #expect(throws: (any Error).self) { try JSONValue.parse(Data(nested(65).utf8)) }
        // The request object itself is level 1, so `params` may add 63 more.
        let ok = #"{"jsonrpc":"2.0","id":1,"method":"m","params":"# + nested(63) + "}"
        if case .request = parse(ok) {} else { Issue.record("63 nested levels inside params must parse") }
        let tooDeep = #"{"jsonrpc":"2.0","id":1,"method":"m","params":"# + nested(64) + "}"
        #expect(parse(tooDeep) == .invalid(id: nil, .invalidRequest()))
    }

    @Test func oversizedMessagesAreInvalidRequests() {
        let padding = String(repeating: "a", count: JSONRPCInbound.maxMessageBytes)
        let line = #"{"jsonrpc":"2.0","id":1,"method":"ping","params":{"p":"\#(padding)"}}"#
        #expect(parse(line) == .invalid(id: nil, .invalidRequest()))
        let small = #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#
        #expect(parse(small) == .request(id: .int(1), method: "ping", params: nil))
    }

    @Test func notificationHasNoID() {
        let n = parse(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        #expect(n == .notification(method: "notifications/initialized", params: nil))
        let p = parse(#"{"jsonrpc":"2.0","method":"notifications/x","params":{"a":1}}"#)
        #expect(p == .notification(method: "notifications/x", params: .object(["a": .int(1)])))
    }

    @Test func batchArrayIsInvalidRequest() {
        let r = parse(#"[{"jsonrpc":"2.0","id":1,"method":"ping"}]"#)
        #expect(r == .invalid(id: nil, .invalidRequest()))
        #expect(parse("[]") == .invalid(id: nil, .invalidRequest()))
        #expect(parse("42") == .invalid(id: nil, .invalidRequest()))
        #expect(parse(#""text""#) == .invalid(id: nil, .invalidRequest()))
    }

    @Test func missingMethodIsInvalidRequestKeepingID() {
        #expect(parse(#"{"jsonrpc":"2.0","id":5}"#) == .invalid(id: .int(5), .invalidRequest()))
        #expect(parse(#"{"jsonrpc":"2.0","id":"s","method":3}"#) == .invalid(id: .string("s"), .invalidRequest()))
        // A response-shaped message has no method either.
        #expect(parse(#"{"jsonrpc":"2.0","id":9,"result":{}}"#) == .invalid(id: .int(9), .invalidRequest()))
    }

    @Test func wrongVersionIsInvalidRequest() {
        #expect(parse(#"{"jsonrpc":"1.0","id":2,"method":"ping"}"#) == .invalid(id: .int(2), .invalidRequest()))
        #expect(parse(#"{"id":2,"method":"ping"}"#) == .invalid(id: .int(2), .invalidRequest()))
        #expect(parse(#"{"jsonrpc":2,"id":2,"method":"ping"}"#) == .invalid(id: .int(2), .invalidRequest()))
    }

    @Test func malformedIDAndParamsAreInvalidRequest() {
        #expect(parse(#"{"jsonrpc":"2.0","id":null,"method":"ping"}"#) == .invalid(id: nil, .invalidRequest()))
        #expect(parse(#"{"jsonrpc":"2.0","id":1.5,"method":"ping"}"#) == .invalid(id: nil, .invalidRequest()))
        #expect(parse(#"{"jsonrpc":"2.0","id":true,"method":"ping"}"#) == .invalid(id: nil, .invalidRequest()))
        #expect(parse(#"{"jsonrpc":"2.0","id":3,"method":"m","params":"scalar"}"#) == .invalid(id: .int(3), .invalidRequest()))
    }

    @Test func garbageIsParseError() {
        #expect(parse("not json") == .invalid(id: nil, .parseError()))
        #expect(parse(#"{"jsonrpc":"2.0","id":1,"method":"ping""#) == .invalid(id: nil, .parseError()))
        #expect(parse(#"{"jsonrpc":"2.0","id":1,"method":"ping"} trailing"#) == .invalid(id: nil, .parseError()))
        #expect(JSONRPCInbound.parse(line: Data([0xFF, 0xFE, 0x00])) == .invalid(id: nil, .parseError()))
        #expect(JSONRPCInbound.parse(line: Data()) == .invalid(id: nil, .parseError()))
    }

    @Test func errorFactoriesUseStandardCodes() {
        #expect(JSONRPCError.parseError().code == -32700)
        #expect(JSONRPCError.invalidRequest().code == -32600)
        #expect(JSONRPCError.methodNotFound("m").code == -32601)
        #expect(JSONRPCError.invalidParams("p").code == -32602)
        #expect(JSONRPCError.internalError("i").code == -32603)
        #expect(JSONRPCError.appUnavailable("a").code == -32000)
        #expect(JSONRPCError.methodNotFound("m").message == "m")
        #expect(JSONRPCError.parseError().data == nil)
    }

    @Test func outboundResultCarriesIDAndResult() throws {
        let line = JSONRPCOutbound.result(id: .string("r1"), .object(["ok": .bool(true)]))
        let json = try decodeOutbound(line)
        #expect(json["jsonrpc"]?.stringValue == "2.0")
        #expect(json["id"]?.stringValue == "r1")
        #expect(json["result"] == .object(["ok": .bool(true)]))
        #expect(json["error"] == nil)
        let intLine = JSONRPCOutbound.result(id: .int(12), .null)
        let intJSON = try decodeOutbound(intLine)
        #expect(intJSON["id"]?.intValue == 12)
        #expect(intJSON["result"] == .null)
    }

    @Test func outboundErrorUsesNullIDWhenUnknown() throws {
        let line = JSONRPCOutbound.error(id: nil, .parseError())
        let json = try decodeOutbound(line)
        #expect(json["id"] == .null)
        #expect(json["error"]?["code"]?.intValue == -32700)
        #expect(json["error"]?["message"]?.stringValue == "Parse error")
        #expect(json["result"] == nil)
        let known = try decodeOutbound(JSONRPCOutbound.error(id: .int(4), .invalidParams("bad")))
        #expect(known["id"]?.intValue == 4)
        #expect(known["error"]?["code"]?.intValue == -32602)
    }

    @Test func outboundErrorKeepsStructuredData() throws {
        var error = JSONRPCError.appUnavailable("down")
        error.data = .object(["hint": .string("start the app")])
        let json = try decodeOutbound(JSONRPCOutbound.error(id: .int(1), error))
        #expect(json["error"]?["data"] == .object(["hint": .string("start the app")]))
    }

    @Test func outboundHasNoRawNewline() {
        let multi = "line one\nline two\r\nthree"
        let result = JSONRPCOutbound.result(id: .string("a\nb"), .string(multi))
        #expect(!result.contains(0x0A))
        #expect(!result.contains(0x0D))
        let error = JSONRPCOutbound.error(id: .int(1), .internalError(multi))
        #expect(!error.contains(0x0A))
        #expect(!error.contains(0x0D))
    }

    @Test func unencodableResultBecomesInternalError() throws {
        let line = JSONRPCOutbound.result(id: .int(3), .double(.nan))
        #expect(!line.contains(0x0A))
        let json = try decodeOutbound(line)
        #expect(json["id"]?.intValue == 3)
        #expect(json["error"]?["code"]?.intValue == -32603)
        #expect(json["result"] == nil)
    }
}
