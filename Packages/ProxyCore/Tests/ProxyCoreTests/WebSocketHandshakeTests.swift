import Foundation
import Testing
import NIOHTTP1
import FlowStore
@testable import ProxyCore

@Suite(.productionChinese) struct WebSocketHandshakeTests {
    private func heads(_ offer: [String] = [], _ selection: [String] = []) -> (HTTPRequestHead, HTTPResponseHead) {
        var request = HTTPRequestHead(version: .http1_1, method: .GET, uri: "http://example.com/chat", headers: ["Host": "example.com", "Connection": " keep-alive, UpGrade ", "Upgrade": "WebSocket", "Sec-WebSocket-Version": "13", "Sec-WebSocket-Key": "dGhlIHNhbXBsZSBub25jZQ=="])
        var response = HTTPResponseHead(version: .http1_1, status: .switchingProtocols, headers: ["Connection": "Upgrade", "Upgrade": "websocket", "Sec-WebSocket-Accept": "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="])
        for value in offer { request.headers.add(name: "Sec-WebSocket-Extensions", value: value) }
        for value in selection { response.headers.add(name: "Sec-WebSocket-Extensions", value: value) }
        return (request, response)
    }

    @Test func canonicalAndInvalidHandshakeTable() {
        let (request, response) = heads()
        #expect(WebSocketHandshakeAssessment.evaluate(request: request, response: response).handshake.assessment == .verified)
        for variant in 0..<18 {
            var q = request; var r = response
            switch variant {
            case 0: q.method = .POST
            case 1: q.version = .http1_0
            case 2: q.headers.replaceOrAdd(name: "Sec-WebSocket-Version", value: "12")
            case 3: q.headers.add(name: "Sec-WebSocket-Version", value: "13")
            case 4: q.headers.add(name: "Sec-WebSocket-Key", value: "dGhlIHNhbXBsZSBub25jZQ==")
            case 5: q.headers.replaceOrAdd(name: "Sec-WebSocket-Key", value: "YQ==")
            case 6: q.headers.replaceOrAdd(name: "Sec-WebSocket-Key", value: "not base64")
            case 7: q.headers.remove(name: "Host")
            case 8: q.headers.add(name: "Host", value: "second")
            case 9: q.headers.replaceOrAdd(name: "Host", value: " \t")
            case 10: r.status = .ok
            case 11: r.headers.replaceOrAdd(name: "Sec-WebSocket-Accept", value: "wrong")
            case 12: r.headers.add(name: "Sec-WebSocket-Accept", value: "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
            case 13: r.headers.add(name: "Sec-WebSocket-Protocol", value: "unoffered")
            case 14: q.headers.replaceOrAdd(name: "Upgrade", value: "x-websocket")
            case 15: r.headers.replaceOrAdd(name: "Connection", value: "x-upgrade")
            case 16: r.version = .http1_0
            default: q.headers.remove(name: "Connection")
            }
            let actual = WebSocketHandshakeAssessment.evaluate(request: q, response: r)
            #expect(actual.handshake.assessment == .invalid, "handshake variant \(variant)")
            #expect(actual.mode == .disabled)
        }
    }

    @Test func headerTokensAreASCIIAndOWSIsOnlySpaceOrTab() {
        for value in ["websocKet", "webſocket", "\u{00A0}websocket\u{00A0}"] {
            var (q, r) = heads()
            q.headers.replaceOrAdd(name: "Upgrade", value: value)
            #expect(WebSocketHandshakeAssessment.evaluate(request: q, response: r).mode == .disabled)
            (q, r) = heads()
            r.headers.replaceOrAdd(name: "Upgrade", value: value)
            #expect(WebSocketHandshakeAssessment.evaluate(request: q, response: r).mode == .disabled)
        }
        var (q, r) = heads()
        q.headers.replaceOrAdd(name: "Sec-WebSocket-Key", value: "\u{00A0}dGhlIHNhbXBsZSBub25jZQ==\u{00A0}")
        #expect(WebSocketHandshakeAssessment.evaluate(request: q, response: r).mode == .disabled)
        (q, r) = heads()
        r.headers.replaceOrAdd(name: "Connection", value: "\u{00A0}upgrade\u{00A0}")
        #expect(WebSocketHandshakeAssessment.evaluate(request: q, response: r).mode == .disabled)
        #expect(throws: (any Error).self) { try WebSocketExtensionParser.parse(["\u{00A0}permessage-deflate"]) }
    }

    @Test func keyUsesOriginalTrimmedValueForAccept() {
        var (q, r) = heads()
        // The supported profile requires 16 decoded bytes, not re-encoding equality.
        q.headers.replaceOrAdd(name: "Sec-WebSocket-Key", value: " \tdGhlIHNhbXBsZSBub25jZR== ")
        r.headers.replaceOrAdd(name: "Sec-WebSocket-Accept", value: "Zgw8jYXtqX5qJr7MJ1Q/MqzeSRI=")
        #expect(WebSocketHandshakeAssessment.evaluate(request: q, response: r).handshake.assessment == .verified)
    }

    @Test func protocolCardinalityAndExactCase() {
        var (q, r) = heads()
        q.headers.add(name: "Sec-WebSocket-Protocol", value: "chat, superchat")
        q.headers.add(name: "Sec-WebSocket-Protocol", value: "another")
        r.headers.add(name: "Sec-WebSocket-Protocol", value: "chat")
        #expect(WebSocketHandshakeAssessment.evaluate(request: q, response: r).handshake.offeredProtocols == ["chat", "superchat", "another"])
        #expect(WebSocketHandshakeAssessment.evaluate(request: q, response: r).handshake.assessment == .verified)
        r.headers.replaceOrAdd(name: "Sec-WebSocket-Protocol", value: "Chat")
        #expect(WebSocketHandshakeAssessment.evaluate(request: q, response: r).mode == .disabled)
        r.headers.replaceOrAdd(name: "Sec-WebSocket-Protocol", value: "chat")
        r.headers.add(name: "Sec-WebSocket-Protocol", value: "another")
        #expect(WebSocketHandshakeAssessment.evaluate(request: q, response: r).mode == .disabled)
    }

    // Independent literal RFC7692 cases: expected windows never derived from offers.
    @Test(arguments: [
        ("permessage-deflate", "permessage-deflate", 15, 15, false, false, true),
        ("permessage-deflate; server_no_context_takeover", "permessage-deflate; server_no_context_takeover", 15, 15, false, true, true),
        ("permessage-deflate; client_no_context_takeover", "permessage-deflate; client_no_context_takeover", 15, 15, true, false, true),
        ("permessage-deflate; server_no_context_takeover=1", "permessage-deflate", 15, 15, false, false, false),
        ("permessage-deflate; client_no_context_takeover=1", "permessage-deflate", 15, 15, false, false, false),
        ("permessage-deflate; server_max_window_bits", "permessage-deflate", 15, 15, false, false, false),
        ("permessage-deflate; server_max_window_bits=7", "permessage-deflate", 15, 15, false, false, false),
        ("permessage-deflate; server_max_window_bits=16", "permessage-deflate", 15, 15, false, false, false),
        ("permessage-deflate; server_max_window_bits=08", "permessage-deflate", 15, 15, false, false, false),
        ("permessage-deflate; client_max_window_bits=7", "permessage-deflate", 15, 15, false, false, false),
        ("permessage-deflate; client_max_window_bits=16", "permessage-deflate", 15, 15, false, false, false),
        ("permessage-deflate; client_max_window_bits=08", "permessage-deflate", 15, 15, false, false, false),
        ("permessage-deflate; client_max_window_bits=8", "permessage-deflate; client_max_window_bits=7", 7, 15, false, false, false),
        ("permessage-deflate; client_max_window_bits=8", "permessage-deflate; client_max_window_bits=16", 16, 15, false, false, false),
        ("permessage-deflate; client_max_window_bits=8", "permessage-deflate; client_max_window_bits=08", 8, 15, false, false, false),
        ("permessage-deflate; server_max_window_bits=15", "permessage-deflate; server_max_window_bits=15", 15, 15, false, false, true),
        ("permessage-deflate; client_max_window_bits=15", "permessage-deflate; client_max_window_bits=15", 15, 15, false, false, true),
        ("permessage-deflate; client_max_window_bits; client_max_window_bits", "permessage-deflate", 15, 15, false, false, false),
        ("permessage-deflate; unknown", "permessage-deflate", 15, 15, false, false, false),

        ("permessage-deflate", "permessage-deflate; server_no_context_takeover; client_no_context_takeover", 15, 15, true, true, true),
        ("permessage-deflate; server_no_context_takeover", "permessage-deflate", 15, 15, false, false, false),
        ("permessage-deflate; client_no_context_takeover", "permessage-deflate", 15, 15, false, false, true),
        ("permessage-deflate; server_max_window_bits=10", "permessage-deflate; server_max_window_bits=10", 15, 10, false, false, true),
        ("permessage-deflate; server_max_window_bits=10", "permessage-deflate; server_max_window_bits=8", 15, 8, false, false, true),
        ("permessage-deflate; server_max_window_bits=10", "permessage-deflate", 15, 15, false, false, false),
        ("permessage-deflate; server_max_window_bits=10", "permessage-deflate; server_max_window_bits=11", 15, 11, false, false, false),
        ("permessage-deflate", "permessage-deflate; server_max_window_bits=8", 15, 8, false, false, true),
        ("permessage-deflate", "permessage-deflate; client_max_window_bits=15", 15, 15, false, false, false),
        ("permessage-deflate; client_max_window_bits=10", "permessage-deflate; client_max_window_bits=15", 15, 15, false, false, true),
        ("permessage-deflate; client_max_window_bits=10", "permessage-deflate", 15, 15, false, false, true),
        ("permessage-deflate; client_max_window_bits", "permessage-deflate; client_max_window_bits=8", 8, 15, false, false, true),
        ("permessage-deflate; client_max_window_bits", "permessage-deflate; client_max_window_bits", 15, 15, false, false, false),
        ("permessage-deflate", "permessage-deflate; server_max_window_bits=\"15\"", 15, 15, false, false, true),
        ("permessage-deflate", "permessage-deflate; server_max_window_bits=7", 15, 7, false, false, false),
        ("permessage-deflate", "permessage-deflate; server_max_window_bits=16", 15, 16, false, false, false),
        ("permessage-deflate", "permessage-deflate; server_max_window_bits=08", 15, 8, false, false, false),
        ("permessage-deflate", "permessage-deflate; server_max_window_bits", 15, 15, false, false, false),
        ("permessage-deflate", "permessage-deflate; server_no_context_takeover=1", 15, 15, false, false, false),
        ("permessage-deflate", "permessage-deflate; client_no_context_takeover=1", 15, 15, false, false, false),
        ("permessage-deflate", "permessage-deflate; unknown", 15, 15, false, false, false),
        ("permessage-deflate", "permessage-deflate; server_no_context_takeover; server_no_context_takeover", 15, 15, false, false, false),
        ("permessage-deflate; unknown, permessage-deflate", "permessage-deflate", 15, 15, false, false, true),
        ("permessage-deflate; server_max_window_bits, permessage-deflate; client_max_window_bits", "permessage-deflate; client_max_window_bits=15", 15, 15, false, false, true)
    ]) func compressionTable(_ offer: String, _ selection: String, _ client: Int, _ server: Int, _ clientNo: Bool, _ serverNo: Bool, _ valid: Bool) throws {
        let (q, r) = heads([offer], [selection])
        let result = WebSocketHandshakeAssessment.evaluate(request: q, response: r)
        var actual: [String: Any] = ["status": result.handshake.assessment.rawValue, "mode": "disabled"]
        if case .messages(let compression) = result.mode, let compression {
            actual["mode"] = "messages"
            actual["clientWindow"] = compression.parameters(for: .clientToServer).windowBits
            actual["serverWindow"] = compression.parameters(for: .serverToClient).windowBits
            actual["clientNoContextTakeover"] = compression.client.noContextTakeover
            actual["serverNoContextTakeover"] = compression.server.noContextTakeover
        }
        var expected: [String: Any] = ["status": valid ? "verified" : "negotiationUnverified", "mode": valid ? "messages" : "disabled"]
        if valid {
            expected["clientWindow"] = client; expected["serverWindow"] = server
            expected["clientNoContextTakeover"] = clientNo; expected["serverNoContextTakeover"] = serverNo
        }
        let evidence: [String: Any] = ["offer": offer, "selection": selection, "expected": expected, "actual": actual]
        print("WS_NEGOTIATION " + String(decoding: try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys]), as: UTF8.self))
        #expect(result.handshake.assessment == (valid ? .verified : .negotiationUnverified))
        if valid {
            #expect(result.mode == .messages(WebSocketCompression(client: .init(windowBits: client, noContextTakeover: clientNo), server: .init(windowBits: server, noContextTakeover: serverNo))))
        } else { #expect(result.mode == .disabled) }
    }

    @Test func extensionGrammarAndOpaquePolicy() throws {
        let parsed = try WebSocketExtensionParser.parse(["x; a=\"15\", permessage-deflate", "x; flag"])
        #expect(parsed.map(\.name) == ["x", "permessage-deflate", "x"])
        #expect(parsed[0].parameters[0].value == "15")
        #expect(parsed[2].parameters[0].value == nil)
        for malformed in ["x; a=\"a,b\"", "x; a=\"a\\\"b\"", "x; a=", "x,", "", "x; a=\"unterminated", "x; a=\"a b\""] {
            #expect(throws: (any Error).self) { try WebSocketExtensionParser.parse([malformed]) }
        }
        let (q, r) = heads(["x, permessage-deflate"], ["x", "permessage-deflate"])
        let result = WebSocketHandshakeAssessment.evaluate(request: q, response: r)
        #expect(result.handshake.assessment == .opaqueExtension)
        #expect(result.mode == .opaqueFrames)
        #expect(result.handshake.selectedExtensions == ["x", "permessage-deflate"])
        let (q2, r2) = heads([], ["x"])
        #expect(WebSocketHandshakeAssessment.evaluate(request: q2, response: r2).mode == .disabled)
    }

    @Test func diagnosticsNeverInterpolateUnboundedInput() {
        var (q, r) = heads()
        let hostile = String(repeating: "💥", count: 10_000)
        q.headers.replaceOrAdd(name: "Sec-WebSocket-Key", value: hostile)
        r.headers.add(name: "Sec-WebSocket-Extensions", value: hostile)
        let result = WebSocketHandshakeAssessment.evaluate(request: q, response: r)
        #expect(!result.handshake.diagnostics.isEmpty)
        #expect(result.handshake.diagnostics.count <= 8)
        #expect(result.handshake.diagnostics.allSatisfy { $0.code.utf8.count <= 128 && ($0.detail?.utf8.count ?? 0) <= 128 })
        #expect(!result.handshake.diagnostics.contains { $0.detail?.contains("💥") == true })
    }
}
