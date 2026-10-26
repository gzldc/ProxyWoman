import FlowStore
import Foundation
import NIOCore
import NIOEmbedded
import NIOHTTP1
import Testing
@testable import ProxyCore
import RulesEngine

@Suite(.productionChinese) struct LegPair: Sendable, CustomTestStringConvertible {
    let downstreamH2: Bool
    let upstreamH2: Bool
    var origin: [String] { upstreamH2 ? ["h2", "http/1.1"] : ["http/1.1"] }
    var testDescription: String { "\(downstreamH2 ? "h2" : "h1")->\(upstreamH2 ? "h2" : "h1")" }
    static let all = [false, true].flatMap { down in [false, true].map { LegPair(downstreamH2: down, upstreamH2: $0) } }
}

/// Header rules change what the real writers put on each wire, while every boundary snapshot
/// keeps what crossed that boundary. Plain-HTTP forward proxying is HTTP/1 only, so protocol pairs
/// run through MITM.
@Suite(.productionChinese, .serialized, .timeLimit(.minutes(2))) struct RuleHeaderIntegrationTests {
    @Test func rulesEnabledWithoutMatchPassOverLimitResponseUnchanged() async throws {
        try await withConnectionFixture { fixture in
            let writer = RecordingResponseWriter(channel: fixture.client)
            let exchange = fixture.admit("/wide-response", writer: writer,
                                         context: fixture.context(rules: TestRules.provider([])))
            exchange.receiveRequest(.end(nil))
            exchange.execute()
            guard !fixture.connections.isEmpty else { Issue.record("unchanged request was rejected before connecting"); return }
            let upstream = try fixture.connect(0)
            _ = try fixture.written(upstream)
            let fields = (0..<300).map { "X-Wide-\($0): value-\($0)\r\n" }.joined()
            try upstream.writeInbound(ByteBuffer(string: "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n" + fields + "\r\n"))
            fixture.loop.run()
            #expect(writer.heads.map(\.status.code) == [200])
            let forwarded = try #require(writer.heads.first)
            #expect(forwarded.headers.filter { $0.name.lowercased().hasPrefix("x-wide-") }.count == 300)
            #expect(forwarded.headers["x-wide-0"] == ["value-0"])
            #expect(forwarded.headers["x-wide-299"] == ["value-299"])
            let flow = try fixture.flow("/wide-response")
            #expect(flow.statusCode == 200)
            #expect(flow.state == .completed)
        }
    }

    @Test func rulesEnabledWithoutMatchPassOverLimitRequestUnchanged() async throws {
        try await withConnectionFixture { fixture in
            var headers = HTTPHeaders()
            for index in 0..<300 { headers.add(name: "X-Wide-\(index)", value: "value-\(index)") }
            let writer = RecordingResponseWriter(channel: fixture.client)
            let exchange = fixture.admit("/wide-request", headers: headers, writer: writer,
                                         context: fixture.context(rules: TestRules.provider([])))
            exchange.receiveRequest(.end(nil))
            exchange.execute()
            guard !fixture.connections.isEmpty else { Issue.record("unchanged request was rejected before connecting"); return }
            let upstream = try fixture.connect(0)
            let sent = try fixture.written(upstream)
            #expect(sent.hasPrefix("GET /wide-request HTTP/1.1\r\n"))
            #expect(sent.components(separatedBy: "\r\n").filter { $0.hasPrefix("X-Wide-") }.count == 300)
            #expect(sent.contains("X-Wide-0: value-0\r\n"))
            #expect(sent.contains("X-Wide-299: value-299\r\n"))
            try upstream.writeInbound(ByteBuffer(string: "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"))
            fixture.loop.run()
            #expect(writer.heads.map(\.status.code) == [200])
            let flow = try fixture.flow("/wide-request")
            #expect(flow.statusCode == 200)
            #expect(flow.state == .completed)
        }
    }

    @Test func matchingEditOnOverLimitHeadIsRejectedOnce() async throws {
        try await withConnectionFixture { fixture in
            var headers = HTTPHeaders()
            for index in 0..<300 { headers.add(name: "X-Wide-\(index)", value: "value-\(index)") }
            let rule = TestRules.headers(.request, [.set(name: "X-Edited", value: "new")])
            let writer = RecordingResponseWriter(channel: fixture.client)
            let exchange = fixture.admit("/edited-wide", headers: headers, writer: writer,
                                         context: fixture.context(rules: TestRules.provider([rule])))
            exchange.receiveRequest(.end(nil))
            exchange.execute()
            #expect(fixture.connections.isEmpty)
            #expect(writer.heads.map(\.status.code) == [502])
            #expect(writer.ends == 1)
            #expect(exchange.localFailure == .ruleRejected)
            let flow = try fixture.flow("/edited-wide")
            #expect(flow.provenance.ruleMatches?.ruleIDs == [rule.id])
            if case .failed = flow.state {} else { Issue.record("expected failed flow") }
        }
    }

    @Test func rejectedEditStillRecordsMatchedRules() async throws {
        try await withConnectionFixture { fixture in
            let first = TestRules.headers(.request, [.set(name: "X-First", value: "ok")])
            let rejected = TestRules.headers(.request, [.set(name: "Content-Length", value: "1")])
            let writer = RecordingResponseWriter(channel: fixture.client)
            let exchange = fixture.admit("/rejected-match", writer: writer,
                                         context: fixture.context(rules: TestRules.provider([first, rejected], revision: 23)))
            exchange.receiveRequest(.end(nil))
            exchange.execute()
            #expect(writer.heads.map(\.status.code) == [502])
            #expect(exchange.localFailure == .ruleRejected)
            let flow = try fixture.flow("/rejected-match")
            let matches = try #require(flow.provenance.ruleMatches)
            #expect(matches.revision == 23)
            #expect(matches.ruleIDs == [first.id, rejected.id])
            #expect(matches.total == 2)
            #expect(matches.outcomes.map(\.ruleID) == [first.id, rejected.id])
            // Phase fix I2b: the rejected edit is recorded and exported as rejected, never applied.
            #expect(matches.outcomes.map(\.code) == [.applied, .rejected])
            #expect(try harRuleOutcomes(flow) == [[first.id.uuidString, "applied"], [rejected.id.uuidString, "rejected"]])
            if case .failed = flow.state {} else { Issue.record("expected failed flow") }
        }
    }

    @Test func noMatchDoesNotWriteProvenance() async throws {
        try await withConnectionFixture { fixture in
            let writer = RecordingResponseWriter(channel: fixture.client)
            let exchange = fixture.admit("/no-match", writer: writer,
                                         context: fixture.context(rules: TestRules.provider([])))
            exchange.receiveRequest(.end(nil))
            exchange.execute()
            let upstream = try fixture.connect(0)
            _ = try fixture.written(upstream)
            try upstream.writeInbound(ByteBuffer(string: "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"))
            fixture.loop.run()
            let flow = try fixture.flow("/no-match")
            #expect(flow.provenance.ruleMatches == nil)
            #expect(flow.provenance.source == .passive)
            #expect(flow.messages[.downstreamRequest] != nil)
            #expect(flow.messages[.downstreamResponse] != nil)
        }
    }

    @Test func requestMatchWithoutResponseMatchKeepsOneSummary() async throws {
        try await withConnectionFixture { fixture in
            let rule = TestRules.headers(.request, [.set(name: "X-Request", value: "edited")])
            let writer = RecordingResponseWriter(channel: fixture.client)
            let exchange = fixture.admit("/request-only", writer: writer,
                                         context: fixture.context(rules: TestRules.provider([rule])))
            exchange.receiveRequest(.end(nil))
            exchange.execute()
            let upstream = try fixture.connect(0)
            #expect(try fixture.written(upstream).contains("X-Request: edited\r\n"))
            let fields = (0..<300).map { "X-Wide-\($0): value-\($0)\r\n" }.joined()
            try upstream.writeInbound(ByteBuffer(string: "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n" + fields + "\r\n"))
            fixture.loop.run()
            #expect(writer.heads.map(\.status.code) == [200])
            let flow = try fixture.flow("/request-only")
            #expect(flow.state == .completed)
            #expect(flow.provenance.ruleMatches?.ruleIDs == [rule.id])
            #expect(flow.provenance.ruleMatches?.total == 1)
        }
    }

    @Test func rejectedResponseEditStillRecordsRequestAndResponseMatches() async throws {
        try await withConnectionFixture { fixture in
            let requestRule = TestRules.headers(.request, [.set(name: "X-Request", value: "ok")])
            let responseRule = TestRules.headers(.response, [.set(name: "Content-Length", value: "9")])
            let writer = RecordingResponseWriter(channel: fixture.client)
            let exchange = fixture.admit("/rejected-response", writer: writer,
                                         context: fixture.context(rules: TestRules.provider([requestRule, responseRule])))
            exchange.receiveRequest(.end(nil))
            exchange.execute()
            let upstream = try fixture.connect(0)
            _ = try fixture.written(upstream)
            try upstream.writeInbound(ByteBuffer(string: "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"))
            fixture.loop.run()
            #expect(writer.heads.map(\.status.code) == [502])
            #expect(exchange.localFailure == .ruleRejected)
            let flow = try fixture.flow("/rejected-response")
            let matches = try #require(flow.provenance.ruleMatches)
            #expect(matches.ruleIDs == [requestRule.id, responseRule.id])
            #expect(matches.total == 2)
            #expect(matches.outcomes.map(\.code) == [.applied, .rejected])
            #expect(try harRuleOutcomes(flow) == [[requestRule.id.uuidString, "applied"], [responseRule.id.uuidString, "rejected"]])
            if case .failed = flow.state {} else { Issue.record("expected failed flow") }
        }
    }

    @Test func optionsAsteriskWithPreservePathRemapIsRejected() async throws {
        try await HTTP2TestOrigin.withOrigin(protocols: ["h2", "http/1.1"]) { origin in
            let map = TestRules.mapRemote(scheme: "https", host: "localhost", port: origin.port)
            try await HTTP2ProxyFixture.withProxy(origin: origin, downstreamH2: true,
                                                 rules: TestRules.provider([map])) { fixture, client in
                let reply = try await client.request(headers: HTTPHeaders([("host", "localhost:\(origin.port)")]),
                                                     path: "*", method: .OPTIONS)
                #expect(reply.status == 502)
                #expect(reply.body.contains("规则修改后的消息无效"), "\(reply.body)")
                let flow = try await waitForFlow(fixture.store) { flow in
                    if case .failed = flow.state { return true }
                    return false
                }
                #expect(flow.messages[.generatedResponse]?.status == 502)
                #expect(flow.messages[.upstreamRequest] == nil)
                #expect(flow.provenance.ruleMatches?.ruleIDs == [map.id])
                #expect(origin.counts.requests == 0)
            }
        }
    }

    @Test func optionsAsteriskWithReplacedPathRemapCanReachOrigin() async throws {
        try await HTTP2TestOrigin.withOrigin(protocols: ["h2", "http/1.1"]) { origin in
            let map = TestRules.mapRemote(scheme: "https", host: "localhost", port: origin.port,
                                          path: .replace("/options"))
            try await HTTP2ProxyFixture.withProxy(origin: origin, downstreamH2: true,
                                                 rules: TestRules.provider([map])) { fixture, client in
                let reply = try await client.request(headers: HTTPHeaders([("host", "localhost:\(origin.port)")]),
                                                     path: "*", method: .OPTIONS)
                #expect(reply.status == 200)
                #expect(origin.counts.paths == ["/options"])
                let flow = try await waitForFlow(fixture.store) { $0.path == "*" && $0.state == .completed }
                #expect(flow.provenance.ruleMatches?.ruleIDs == [map.id])
            }
        }
    }

    @Test(arguments: LegPair.all)
    func requestAndResponseEditsReachEachWireAndEveryBoundaryKeepsItsOwnView(pair: LegPair) async throws {
        var response = HTTP2TestOrigin.Response()
        response.headers.add(name: "x-strip", value: "gone")
        response.headers.add(name: "x-origin", value: "kept")
        let rules = TestRules.provider([
            TestRules.headers(.request, [.remove(name: "X-Drop"), .set(name: "X-Edited", value: "new"),
                                         .append(name: "X-Added", value: "1")]),
            TestRules.headers(.response, [.append(name: "Set-Cookie", value: "c=3"), .remove(name: "X-Strip"),
                                          .set(name: "X-Served", value: "proxy")]),
        ], revision: 7)
        try await HTTP2TestOrigin.withOrigin(protocols: pair.origin, response: response) { origin in
            try await HTTP2ProxyFixture.withProxy(origin: origin, downstreamH2: pair.downstreamH2, rules: rules) { fixture, client in
                let reply = try await client.request(headers: HTTPHeaders([
                    ("host", "localhost:\(origin.port)"), ("x-edited", "old"), ("x-drop", "1"), ("x-keep", "k"),
                ]), path: "/edit?q=1")
                #expect(reply.status == 200)
                #expect(reply.body == "fixture-body")
                #expect(reply.headers["set-cookie"] == ["a=1", "b=2", "c=3"])
                #expect(reply.headers["x-served"] == ["proxy"])
                #expect(reply.headers["x-strip"].isEmpty)
                #expect(reply.headers["x-origin"] == ["kept"])
                #expect(reply.trailers?["x-finish"] == ["done"])

                let seen = try #require(origin.counts.requestHeaders.last)
                #expect(seen["x-edited"] == ["new"])
                #expect(seen["x-drop"].isEmpty)
                #expect(seen["x-added"] == ["1"])
                #expect(seen["x-keep"] == ["k"])

                try await waitForCompletedFlows(fixture.store, atLeast: 1)
                let flow = try #require(fixture.store.allFlows().first { $0.path == "/edit?q=1" })
                let client = try #require(flow.messages[.downstreamRequest])
                #expect(client.headers.values(for: "x-edited") == ["old"])
                #expect(client.headers.values(for: "x-drop") == ["1"])
                let sent = try #require(flow.messages[.upstreamRequest])
                #expect(sent.headers.values(for: "x-edited") == ["new"])
                #expect(sent.headers.values(for: "x-drop").isEmpty)
                #expect(sent.wireVersion == (pair.upstreamH2 ? .http2 : .http1_1))
                let received = try #require(flow.messages[.upstreamResponse])
                #expect(received.headers.values(for: "x-strip") == ["gone"])
                #expect(received.headers.values(for: "x-served").isEmpty)
                #expect(received.headers.values(for: "set-cookie") == ["a=1", "b=2"])
                let delivered = try #require(flow.messages[.downstreamResponse])
                #expect(delivered.headers.values(for: "x-served") == ["proxy"])
                #expect(delivered.headers.values(for: "x-strip").isEmpty)
                #expect(delivered.headers.values(for: "set-cookie") == ["a=1", "b=2", "c=3"])
                #expect(delivered.wireVersion == (pair.downstreamH2 ? .http2 : .http1_1))
                // The legacy projection stays the client request and the origin response.
                #expect(flow.requestHeaders.values(for: "x-edited") == ["old"])
                #expect(flow.responseHeaders.values(for: "x-served").isEmpty)
                let matches = try #require(flow.provenance.ruleMatches)
                #expect(matches.revision == 7)
                #expect(matches.total == 2)
                #expect(matches.outcomes.map(\.code) == [.applied, .applied])
            }
        }
    }

    /// An HTTP/1.0 client keeps its own framing, and a bodyless HEAD response is edited without a body.
    @Test(arguments: ["GET", "HEAD"])
    func http10ClientAndBodylessResponsesKeepTheirFramingAfterEdits(method: String) async throws {
        let origin = try await HTTP2TestOrigin.start(protocols: [], plaintext: true)
        do {
            let rules = TestRules.provider([
                TestRules.headers(.request, [.set(name: "X-Edited", value: "new")]),
                TestRules.headers(.response, [.set(name: "X-Served", value: "proxy")]),
            ])
            try await ProxyFixture.run(rules: rules) { fx in
                let client = try await RawClient.connect(port: fx.proxyPort)
                try await client.send("\(method) http://127.0.0.1:\(origin.port)/ten HTTP/1.0\r\nHost: 127.0.0.1:\(origin.port)\r\nX-Edited: old\r\n\r\n")
                try await client.waitUntilClosed()
                let text = String(decoding: client.remainingBytes(), as: UTF8.self)
                try await client.close()
                #expect(text.hasPrefix("HTTP/1.0 200 OK\r\n"), "\(text)")
                #expect(text.contains("X-Served: proxy\r\n"), "\(text)")
                #expect(!text.lowercased().contains("transfer-encoding"), "\(text)")
                if method == "HEAD" { #expect(text.hasSuffix("\r\n\r\n"), "\(text)") }
                else { #expect(text.hasSuffix("\r\n\r\nfixture-body"), "\(text)") }
                #expect(origin.counts.requestHeaders.last?["x-edited"] == ["new"])
                let flow = try await waitForFlow(fx.store) { $0.path == "/ten" && $0.state == .completed }
                #expect(flow.messages[.downstreamResponse]?.wireVersion == .http1_0)
                #expect(flow.messages[.downstreamResponse]?.headers.values(for: "X-Served") == ["proxy"])
            }
            try await origin.stop()
        } catch { try? await origin.stop(); throw error }
    }

    struct InvalidEdit: Sendable, CustomTestStringConvertible {
        let name: String
        let direction: HTTPMessageDirection
        let operation: HeaderEdit
        var testDescription: String { name }
        static let all = [
            InvalidEdit(name: "request CRLF", direction: .request, operation: .set(name: "X-Bad", value: "a\r\nInjected: 1")),
            InvalidEdit(name: "request length", direction: .request, operation: .set(name: "Content-Length", value: "1")),
            InvalidEdit(name: "request block limit", direction: .request,
                        operation: .append(name: "X-Big", value: String(repeating: "a", count: 70_000))),
            InvalidEdit(name: "response CRLF", direction: .response, operation: .append(name: "X-Bad", value: "a\nb")),
            InvalidEdit(name: "response length", direction: .response, operation: .set(name: "Content-Length", value: "9")),
            InvalidEdit(name: "response block limit", direction: .response,
                        operation: .append(name: "X-Big", value: String(repeating: "a", count: 70_000))),
        ]
    }

    /// Edits loaded from a rule file are validated again at execution: a rejected edit is one local
    /// 502 with a stable code, written before anything of the edited message.
    @Test(arguments: InvalidEdit.all)
    func invalidEditsFailBeforeTheEditedMessageIsWritten(edit: InvalidEdit) async throws {
        try await withConnectionFixture { fixture in
            let rules = TestRules.provider([TestRules.headers(edit.direction, [edit.operation])])
            let writer = RecordingResponseWriter(channel: fixture.client)
            let exchange = fixture.admit("/invalid", writer: writer, context: fixture.context(rules: rules))
            exchange.receiveRequest(.end(nil))
            exchange.execute()
            if edit.direction == .request {
                #expect(fixture.connections.isEmpty)
            } else {
                let upstream = try fixture.connect(0)
                #expect(try fixture.written(upstream).hasPrefix("GET /invalid HTTP/1.1\r\n"))
                try upstream.writeInbound(ByteBuffer(string: "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nX-Origin: 1\r\n\r\nok"))
                fixture.loop.run()
            }
            #expect(writer.heads.map(\.status.code) == [502])
            #expect(writer.heads.first?.headers["x-origin"].isEmpty == true)
            #expect(writer.body.hasPrefix("ProxyWoman：规则修改后的消息无效"), "\(writer.body)")
            #expect(writer.ends == 1)
            #expect(exchange.localFailure == .ruleRejected)
            let flow = try fixture.flow("/invalid")
            if case .failed = flow.state {} else { Issue.record("rejected edit must fail the flow: \(flow.state)") }
            #expect(flow.messages[.generatedResponse]?.status == 502)
        }
    }

    @Test func executionPolicyCanTurnRulesOffForOneExchange() async throws {
        try await withConnectionFixture { fixture in
            let rules = TestRules.provider([TestRules.headers(.request, [.set(name: "X-Edited", value: "new")])])
            let writer = RecordingResponseWriter(channel: fixture.client)
            let exchange = fixture.admit("/off", headers: HTTPHeaders([("X-Edited", "old")]), writer: writer,
                                         context: fixture.context(rules: rules), policy: HTTPExecutionPolicy(rulesEnabled: false))
            exchange.receiveRequest(.end(nil))
            exchange.execute()
            let upstream = try fixture.connect(0)
            #expect(try fixture.written(upstream).contains("\r\nX-Edited: old\r\n"))
            try upstream.writeInbound(ByteBuffer(string: "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"))
            fixture.loop.run()
            #expect(writer.heads.map(\.status.code) == [200])
            #expect(try fixture.flow("/off").provenance.ruleMatches == nil)
        }
    }

    /// Until their executors land, Map Local and breakpoint matches end the exchange explicitly
    /// instead of silently forwarding.
    @Test(arguments: ["mapLocal", "requestBreakpoint", "responseBreakpoint"])
    func unsupportedActionsFailExplicitly(action: String) async throws {
        try await withConnectionFixture { fixture in
            let rule = switch action {
            case "mapLocal": TestRules.mapLocal()
            case "requestBreakpoint": TestRules.breakpoint(.request)
            default: TestRules.breakpoint(.response)
            }
            let writer = RecordingResponseWriter(channel: fixture.client)
            let exchange = fixture.admit("/unsupported", writer: writer, context: fixture.context(rules: TestRules.provider([rule])))
            exchange.receiveRequest(.end(nil))
            exchange.execute()
            if action == "responseBreakpoint" {
                let upstream = try fixture.connect(0)
                try upstream.writeInbound(ByteBuffer(string: "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"))
                fixture.loop.run()
            } else {
                #expect(fixture.connections.isEmpty)
            }
            #expect(writer.heads.map(\.status.code) == [502])
            #expect(exchange.localFailure == .ruleActionUnsupported)
        }
    }

    /// The final-response stage includes 101: non-handshake fields can be edited, handshake fields
    /// stay protected, and a rejected edit replaces the 101 with one local failure.
    @Test(arguments: [false, true])
    func switchingProtocolsRunsTheResponseStageWithHandshakeFieldsProtected(editsHandshake: Bool) async throws {
        try await withConnectionFixture { fixture in
            let operation: HeaderEdit = editsHandshake
                ? .set(name: "Sec-WebSocket-Protocol", value: "chat") : .set(name: "X-Resp", value: "1")
            let rules = TestRules.provider([TestRules.headers(.response, [operation])])
            let writer = RecordingResponseWriter(channel: fixture.client)
            let exchange = fixture.admit("/ws", headers: HTTPHeaders([
                ("Upgrade", "websocket"), ("Connection", "Upgrade"), ("Sec-WebSocket-Key", "k"), ("Sec-WebSocket-Version", "13"),
            ]), writer: writer, context: fixture.context(rules: rules))
            exchange.receiveRequest(.end(nil))
            exchange.execute()
            let upstream = try fixture.connect(0)
            try upstream.writeInbound(ByteBuffer(string:
                "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: a\r\n\r\n"))
            fixture.loop.run()
            let head = try #require(writer.heads.first)
            #expect(writer.heads.count == 1)
            if editsHandshake {
                #expect(head.status == .badGateway)
                #expect(exchange.localFailure == .ruleRejected)
            } else {
                #expect(head.status == .switchingProtocols)
                #expect(head.headers["X-Resp"] == ["1"])
                #expect(head.headers["Upgrade"] == ["websocket"])
                #expect(head.headers["Sec-WebSocket-Accept"] == ["a"])
            }
        }
    }

    /// An Upgrade after a normal h2 request still takes the dedicated HTTP/1 route; Map and
    /// breakpoint rules are skipped with a recorded reason while ordinary edits apply and the
    /// handshake and frames stay byte-identical.
    @Test func upgradeSkipsMapAndBreakpointsButAppliesOrdinaryEdits() async throws {
        var response = HTTP2TestOrigin.Response()
        response.supportsUpgrade = true
        response.trailers = nil
        let ws = RuleMatcher(path: .prefix("/ws"))
        let rules = TestRules.provider([
            TestRules.mapRemote(scheme: "https", host: "127.0.0.1", port: 1, matcher: ws),
            TestRules.breakpoint(.request, matcher: ws),
            TestRules.headers(.request, [.set(name: "X-Ws", value: "1")], matcher: ws),
            TestRules.headers(.response, [.set(name: "X-Resp101", value: "1")], matcher: ws),
            TestRules.breakpoint(.response, matcher: ws),
        ])
        let origin = try await HTTP2TestOrigin.start(protocols: ["h2", "http/1.1"], response: response)
        var fixture: HTTP2ProxyFixture?
        var client: HTTP2UpgradeClient?
        do {
            let proxy = try await HTTP2ProxyFixture.start(origin: origin, rules: rules); fixture = proxy
            let connected = try await HTTP2UpgradeClient.connect(fixture: proxy, origin: origin, tls: true); client = connected
            try await connected.send(Array("GET /prime HTTP/1.1\r\nHost: localhost:\(origin.port)\r\n\r\n".utf8))
            #expect(try await connected.receive(until: "0\r\n\r\n").hasPrefix("HTTP/1.1 200"))
            try await connected.send(HTTP2UpgradeWire.request(target: "/ws", port: origin.port))
            let head = try await connected.receive(until: "\r\n\r\n")
            #expect(head.hasPrefix("HTTP/1.1 101 Switching Protocols\r\n"), "\(head)")
            #expect(head.contains("X-Resp101: 1\r\n"), "\(head)")
            #expect(head.contains("Sec-WebSocket-Accept: " + HTTP2UpgradeWire.accept + "\r\n"))
            #expect(try await connected.receive(count: HTTP2UpgradeWire.greeting.count) == HTTP2UpgradeWire.greeting)
            try await connected.send(HTTP2UpgradeWire.clientFrame)
            #expect(try await connected.receive(count: HTTP2UpgradeWire.serverFrame.count) == HTTP2UpgradeWire.serverFrame)
            #expect(origin.counts.upgradeBytes == HTTP2UpgradeWire.clientFrame)
            #expect(origin.counts.negotiated == [.http2, .http1])
            let seen = try #require(origin.counts.requestHeaders.last)
            #expect(seen["x-ws"] == ["1"])
            #expect(seen["sec-websocket-key"] == [HTTP2UpgradeWire.key])
            let flow = try await waitForFlow(proxy.store) { $0.path == "/ws" && $0.state == .completed }
            #expect(flow.statusCode == 101)
            #expect(flow.provenance.ruleMatches?.outcomes.map(\.code)
                == [.unsupportedUpgradeAction, .unsupportedUpgradeAction, .applied, .applied, .unsupportedUpgradeAction])
            try await connected.stop(); try await proxy.stop(); try await origin.stop()
        } catch {
            if let client { try? await client.stop() }
            if let fixture { try? await fixture.stop() }
            try? await origin.stop(); throw error
        }
    }
}

/// `_proxywoman.provenance.ruleOutcomes` of the flow's HAR entry as [ruleID, code] pairs.
func harRuleOutcomes(_ flow: Flow) throws -> [[String]] {
    let data = try HARExporter.export([flow], creatorName: "Test", creatorVersion: "1")
    let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let entry = try #require(((root["log"] as? [String: Any])?["entries"] as? [[String: Any]])?.first)
    let provenance = try #require((entry["_proxywoman"] as? [String: Any])?["provenance"] as? [String: Any])
    let outcomes = try #require(provenance["ruleOutcomes"] as? [[String: Any]])
    return outcomes.map { [($0["ruleID"] as? String) ?? "", ($0["code"] as? String) ?? ""] }
}
