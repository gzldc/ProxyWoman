import FlowStore
import Foundation
import NIOCore
import NIOHPACK
import NIOHTTP1
import Testing
@testable import ProxyCore
@testable import RulesEngine

/// A handwritten or preset response (spec 5.5.8, 6.9, D17) answers the client through the same local
/// response pipeline as Return File: no upstream connection, HEAD / HTTP/1.0 / HTTP/2 framing, the upload
/// disposed of, and the response point (P2) still running for the higher-priority rules.
@Suite(.serialized, .timeLimit(.minutes(3)), .productionChinese) struct RuleGeneratedResponseIntegrationTests {
    @Test func presetForbiddenAnswersWithoutTouchingTheOrigin() async throws {
        let forbidden = rule("forbidden", [preset(.forbidden403, body: "nope")])
        try await ProxyFixture.run(rules: TestRules.provider([forbidden])) { fx in
            let reply = try await directoryRaw(fx, host: "127.0.0.1:\(fx.origin.port)", path: "/secret")
            #expect(reply.head.hasPrefix("HTTP/1.1 403 Forbidden\r\n"))
            #expect(reply.field("content-type") == ["text/plain; charset=utf-8"])
            #expect(reply.field("content-length") == ["4"])
            #expect(reply.body == Data("nope".utf8))
            #expect(fx.origin.acceptedConnections == 0)
            #expect(fx.origin.receivedRequestCount == 0)
            let flow = try await waitForFlow(fx.store) { $0.state == .completed }
            #expect(flow.messages[.upstreamRequest] == nil)
            #expect(flow.messages[.upstreamResponse] == nil)
            #expect(flow.messages[.downstreamResponse]?.status == 403)
        }
    }

    @Test func handwrittenResponseBytesOnTheWire() async throws {
        let text = "HTTP/1.1 201 Created\r\nX-Custom: a b\r\nContent-Type: text/plain\r\n\r\nhello"
        let written = rule("handwritten", [handwritten(text)])
        try await ProxyFixture.run(rules: TestRules.provider([written])) { fx in
            let reply = try await directoryRaw(fx, host: "127.0.0.1:\(fx.origin.port)", path: "/made")
            // The Content-Length the parser added, then the transport's own Connection field.
            #expect(reply.raw == "HTTP/1.1 201 Created\r\nX-Custom: a b\r\nContent-Type: text/plain\r\nContent-Length: 5\r\n"
                + "Connection: close\r\n\r\nhello")
            #expect(fx.origin.acceptedConnections == 0)
        }
    }

    @Test func handwrittenReasonOfAnUnusualStatusIsKept() async throws {
        let written = rule("handwritten", [handwritten("HTTP/1.1 299 Fine Thanks\n\nok")])
        try await ProxyFixture.run(rules: TestRules.provider([written])) { fx in
            let reply = try await directoryRaw(fx, host: "127.0.0.1:\(fx.origin.port)", path: "/unusual")
            #expect(reply.head.hasPrefix("HTTP/1.1 299 Fine Thanks\r\n"))
            #expect(reply.body == Data("ok".utf8))
        }
    }

    @Test func headRequestGetsHeadersOnly() async throws {
        let forbidden = rule("forbidden", [preset(.forbidden403, body: "nope")])
        try await ProxyFixture.run(rules: TestRules.provider([forbidden])) { fx in
            let reply = try await directoryRaw(fx, method: "HEAD", host: "127.0.0.1:\(fx.origin.port)", path: "/head")
            #expect(reply.head.hasPrefix("HTTP/1.1 403 Forbidden\r\n"))
            #expect(reply.field("content-length") == ["4"])
            #expect(reply.field("transfer-encoding").isEmpty)
            #expect(reply.body.isEmpty)
            #expect(fx.origin.acceptedConnections == 0)
        }
    }

    @Test func noContentAndNotModifiedCarryNoBody() async throws {
        for (preset, status) in [(PresetResponse.Preset.noContent204, "204 No Content"), (.notModified304, "304 Not Modified")] {
            try await ProxyFixture.run(rules: TestRules.provider([rule("bodyless", [Self.presetAction(preset)])])) { fx in
                let reply = try await directoryRaw(fx, host: "127.0.0.1:\(fx.origin.port)", path: "/bodyless")
                #expect(reply.head.hasPrefix("HTTP/1.1 \(status)\r\n"))
                #expect(reply.field("transfer-encoding").isEmpty)
                #expect(reply.field("content-length") == (preset == .noContent204 ? [] : ["0"]))
                #expect(reply.body.isEmpty)
            }
        }
    }

    @Test func http10ClientGetsHTTP10Head() async throws {
        let forbidden = rule("forbidden", [preset(.forbidden403, body: "nope")])
        try await ProxyFixture.run(rules: TestRules.provider([forbidden])) { fx in
            let host = "127.0.0.1:\(fx.origin.port)"
            let client = try await RawClient.connect(port: fx.proxyPort)
            do {
                try await client.send("GET http://\(host)/old HTTP/1.0\r\nHost: \(host)\r\n\r\n")
                try await client.waitUntilClosed()
                let raw = String(decoding: client.remainingBytes(), as: UTF8.self)
                try await client.close()
                #expect(raw.hasPrefix("HTTP/1.0 403 Forbidden\r\n"))
                #expect(raw.hasSuffix("\r\n\r\nnope"))
                #expect(fx.origin.acceptedConnections == 0)
            } catch { try? await client.close(); throw error }
        }
    }

    @Test func http2ClientGetsGeneratedResponse() async throws {
        let forbidden = rule("forbidden", [preset(.forbidden403, body: "nope")])
        try await HTTP2TestOrigin.withOrigin(protocols: ["h2"]) { origin in
            try await HTTP2ProxyFixture.withProxy(origin: origin, downstreamH2: true, rules: TestRules.provider([forbidden])) { fx, client in
                let reply = try await client.rawRequest(headers: h2Headers(origin, path: "/h2"))
                #expect(reply.status == 403)
                #expect(reply.headers["content-length"] == ["4"])
                #expect(reply.body == "nope")
                #expect(origin.counts.connections == 0)
                let flow = try await waitForFlow(fx.store) { $0.path == "/h2" && $0.state == .completed }
                #expect(flow.messages[.upstreamRequest] == nil)
                // The parent connection stays usable.
                let second = try await client.rawRequest(headers: h2Headers(origin, path: "/again"))
                #expect(second.status == 403)
            }
        }
    }

    // MARK: the response point

    /// Spec 5.5.4: A (higher, a response header) still runs on the response B (lower) returned.
    @Test func higherPriorityResponseRuleEditsGeneratedResponse() async throws {
        let higher = rule("A", [setHeader(.response, "X-A")])
        let returning = rule("B", [preset(.forbidden403, body: "nope")])
        try await ProxyFixture.run(rules: TestRules.provider([higher, returning])) { fx in
            let reply = try await directoryRaw(fx, host: "127.0.0.1:\(fx.origin.port)", path: "/ab")
            #expect(reply.head.hasPrefix("HTTP/1.1 403 Forbidden\r\n"))
            #expect(reply.field("x-a") == ["1"])
            #expect(reply.body == Data("nope".utf8))
            let flow = try await waitForFlow(fx.store) { $0.state == .completed }
            #expect(flow.provenance.rulesModified)
            #expect(flow.messages[.generatedResponse]?.headers.contains { $0.name.lowercased() == "x-a" } == false)
            #expect(flow.messages[.downstreamResponse]?.headers.contains { $0.name.lowercased() == "x-a" } == true)
            #expect(flow.provenance.ruleMatches?.outcomes == [
                RuleOutcome(ruleID: returning.id, code: .applied), RuleOutcome(ruleID: higher.id, code: .applied),
            ])
        }
    }

    @Test func lowerPriorityRuleStaysSilentAfterReturn() async throws {
        let returning = rule("return", [preset(.forbidden403, body: "nope")])
        let lowerRequest = rule("lower request", [setHeader(.request, "X-Lower")])
        let lowerResponse = rule("lower response", [setHeader(.response, "X-Lower-Response")])
        try await ProxyFixture.run(rules: TestRules.provider([returning, lowerRequest, lowerResponse])) { fx in
            let reply = try await directoryRaw(fx, host: "127.0.0.1:\(fx.origin.port)", path: "/lower")
            #expect(reply.head.hasPrefix("HTTP/1.1 403 Forbidden\r\n"))
            #expect(reply.field("x-lower-response").isEmpty)
            let flow = try await waitForFlow(fx.store) { $0.state == .completed }
            #expect(flow.provenance.ruleMatches?.ruleIDs == [returning.id])
            #expect(flow.provenance.ruleMatches?.outcomes == [
                RuleOutcome(ruleID: returning.id, code: .applied), RuleOutcome(ruleID: returning.id, code: .finalStop, actionIndex: 0),
            ])
        }
    }

    @Test func statusRewriteSkipsGeneratedUnlessOptedIn() async throws {
        let returning = rule("return", [preset(.forbidden403, body: "nope")])
        let skipping = rule("status", [RuleAction(.rewriteStatus(RewriteStatusAction(status: 200)))])
        try await ProxyFixture.run(rules: TestRules.provider([skipping, returning])) { fx in
            let reply = try await directoryRaw(fx, host: "127.0.0.1:\(fx.origin.port)", path: "/skipped")
            #expect(reply.head.hasPrefix("HTTP/1.1 403 Forbidden\r\n"))
            let flow = try await waitForFlow(fx.store) { $0.state == .completed }
            #expect(flow.provenance.ruleMatches?.outcomes.contains(RuleOutcome(ruleID: skipping.id, code: .statusSkippedLocal)) == true)
        }
        let opted = rule("status", [RuleAction(.rewriteStatus(RewriteStatusAction(status: 200, includeLocalResponses: true)))])
        try await ProxyFixture.run(rules: TestRules.provider([opted, returning])) { fx in
            let reply = try await directoryRaw(fx, host: "127.0.0.1:\(fx.origin.port)", path: "/opted")
            #expect(reply.head.hasPrefix("HTTP/1.1 200 OK\r\n"))
            #expect(reply.body == Data("nope".utf8))
            let flow = try await waitForFlow(fx.store) { $0.state == .completed }
            #expect(flow.messages[.generatedResponse]?.status == 403)
            #expect(flow.messages[.downstreamResponse]?.status == 200)
        }
    }

    // MARK: upload, record and outcomes

    /// Like Return File: the answer goes out at once, the unread upload is discarded and the connection
    /// closes; nothing of it reaches an origin.
    @Test func uploadIsDisposedLikeMapLocal() async throws {
        let returning = rule("return", [preset(.forbidden403, body: "nope")])
        try await ProxyFixture.run(rules: TestRules.provider([returning])) { fx in
            let host = "127.0.0.1:\(fx.origin.port)"
            let client = try await RawClient.connect(port: fx.proxyPort)
            do {
                try await client.send("POST http://\(host)/upload HTTP/1.1\r\nHost: \(host)\r\nContent-Length: 1000000\r\n\r\npartial upload")
                try await client.waitUntilClosed()
                let raw = String(decoding: client.remainingBytes(), as: UTF8.self)
                try await client.close()
                #expect(raw.hasPrefix("HTTP/1.1 403 Forbidden\r\n"))
                #expect(raw.hasSuffix("\r\n\r\nnope"))
            } catch { try? await client.close(); throw error }
            #expect(fx.origin.acceptedConnections == 0)
            let flow = try await waitForFlow(fx.store) { $0.path == "/upload" && $0.completedAt != nil }
            #expect(flow.state == .completed)
            #expect(flow.messages[.upstreamRequest] == nil)
            #expect(flow.messages[.downstreamRequest]?.bodyState == .incomplete)
        }
    }

    @Test func generatedResponseIsRecordedAsGenerated() async throws {
        let returning = rule("return", [preset(.forbidden403, body: "nope")])
        try await ProxyFixture.run(rules: TestRules.provider([returning])) { fx in
            _ = try await directoryRaw(fx, host: "127.0.0.1:\(fx.origin.port)", path: "/recorded")
            let flow = try await waitForFlow(fx.store) { $0.state == .completed }
            let source = try #require(flow.provenance.generatedResponse)
            #expect(source.assetID == nil)
            #expect(source.size == 4)
            #expect(flow.messages[.generatedResponse]?.status == 403)
            #expect(try flow.messages[.generatedResponse]?.body?.load() == Data("nope".utf8))
            #expect(try flow.messages[.downstreamResponse]?.body?.load() == Data("nope".utf8))
            // The list row shows the generated answer.
            #expect(flow.statusCode == 403)
            #expect(try flow.responseBody?.load() == Data("nope".utf8))
            #expect(flow.provenance.rulesModified)
        }
    }

    @Test func ruleOutcomesNameTheAction() async throws {
        let several = rule("several", [setHeader(.request, "X-Before"), preset(.forbidden403, body: "nope"), setHeader(.response, "X-After")])
        try await ProxyFixture.run(rules: TestRules.provider([several])) { fx in
            let reply = try await directoryRaw(fx, host: "127.0.0.1:\(fx.origin.port)", path: "/several")
            #expect(reply.head.hasPrefix("HTTP/1.1 403 Forbidden\r\n"))
            #expect(reply.field("x-after").isEmpty)
            let flow = try await waitForFlow(fx.store) { $0.state == .completed }
            #expect(flow.provenance.ruleMatches?.outcomes == [
                RuleOutcome(ruleID: several.id, code: .applied, actionIndex: 0),
                RuleOutcome(ruleID: several.id, code: .applied, actionIndex: 1),
                RuleOutcome(ruleID: several.id, code: .finalStop, actionIndex: 1),
                RuleOutcome(ruleID: several.id, code: .skippedAfterFinal, actionIndex: 2),
            ])
        }
    }

    /// A WebSocket handshake cannot be answered by a rule: the action is recorded as unsupported and
    /// the handshake goes on to the origin with the lower rules applied.
    @Test func upgradeRequestGetsUnsupportedUpgradeActionAndFlowsThrough() async throws {
        try await withConnectionFixture { fixture in
            let returning = rule("return", [preset(.forbidden403, body: "nope")])
            let lower = rule("lower", [setHeader(.request, "X-Ws")])
            let writer = RecordingResponseWriter(channel: fixture.client)
            let exchange = fixture.admit("/ws", headers: HTTPHeaders([
                ("Upgrade", "websocket"), ("Connection", "Upgrade"), ("Sec-WebSocket-Key", "k"), ("Sec-WebSocket-Version", "13"),
            ]), writer: writer, context: fixture.context(rules: TestRules.provider([returning, lower])))
            exchange.receiveRequest(.end(nil))
            exchange.execute()
            let upstream = try fixture.connect(0)
            #expect(try fixture.written(upstream).contains("\r\nX-Ws: 1\r\n"))
            try upstream.writeInbound(ByteBuffer(string:
                "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: a\r\n\r\n"))
            fixture.loop.run()
            #expect(writer.heads.first?.status == .switchingProtocols)
            let flow = try fixture.flow("/ws")
            #expect(flow.provenance.generatedResponse == nil)
            #expect(flow.provenance.ruleMatches?.outcomes == [
                RuleOutcome(ruleID: returning.id, code: .unsupportedUpgradeAction), RuleOutcome(ruleID: lower.id, code: .applied),
            ])
        }
    }

    @Test func bodyRewriteAboveIsSkippedOnGeneratedRoute() async throws {
        let body = rule("body", [RuleAction(.rewriteBody(direction: .request, BodyRewriteAction(find: "a", replacement: "b")))])
        let returning = rule("return", [preset(.forbidden403, body: "nope")])
        try await ProxyFixture.run(rules: TestRules.provider([body, returning])) { fx in
            let reply = try await directoryRaw(fx, method: "POST", host: "127.0.0.1:\(fx.origin.port)", path: "/body", body: "aaa")
            #expect(reply.head.hasPrefix("HTTP/1.1 403 Forbidden\r\n"))
            #expect(fx.origin.acceptedConnections == 0)
            let flow = try await waitForFlow(fx.store) { $0.state == .completed }
            #expect(flow.provenance.ruleMatches?.outcomes == [
                RuleOutcome(ruleID: body.id, code: .bodySkippedLocalRoute), RuleOutcome(ruleID: returning.id, code: .applied),
            ])
        }
    }

    /// A Map Remote above the return does not send the request anywhere: the generated route wins.
    @Test func mapRemoteAboveTheReturnOpensNoConnection() async throws {
        let provider = TestRules.provider([])
        try await ProxyFixture.run(rules: provider) { fx in
            let map = rule("map", [RuleAction(.mapRemote(MapRemoteAction(
                targetScheme: "http", targetHost: "127.0.0.1", targetPort: fx.origin.port, path: .preserve)))])
            let returning = rule("return", [preset(.forbidden403, body: "nope")])
            TestRules.publish([map, returning], revision: 2, to: provider)
            let reply = try await directoryRaw(fx, host: "localhost:1", path: "/mapped")
            #expect(reply.head.hasPrefix("HTTP/1.1 403 Forbidden\r\n"))
            #expect(fx.origin.acceptedConnections == 0)
            let flow = try await waitForFlow(fx.store) { $0.state == .completed }
            #expect(flow.messages[.upstreamRequest] == nil)
        }
    }

    @Test func composeSendWithRulesAppliesGenerated() async throws {
        let returning = rule("return", [preset(.forbidden403, body: "nope")])
        try await ComposeFixture.run(rules: TestRules.provider([returning])) { fx in
            let on = await fx.compose.send(ComposeRequest(method: "GET", url: fx.url("/hello"), policy: ComposePolicy(applyRules: true)))
            #expect(on.failure == nil)
            #expect(on.response?.status == 403)
            #expect(on.response?.body == Data("nope".utf8))
            #expect(fx.origin.state.withLock { $0.connections } == 0)
            let flowID = try #require(on.flowID)
            let flow = try await waitForFlow(fx.store) { $0.id == flowID && $0.state == .completed }
            #expect(flow.provenance.generatedResponse?.assetID == nil)
            #expect(flow.messages[.upstreamRequest] == nil)
            let off = await fx.compose.send(ComposeRequest(method: "GET", url: fx.url("/hello"), policy: ComposePolicy(applyRules: false)))
            #expect(off.response?.status == 200)
            #expect(fx.origin.state.withLock { $0.connections } == 1)
            fx.expectIdle()
        }
    }

    private static func presetAction(_ preset: PresetResponse.Preset) -> RuleAction {
        RuleAction(.returnPreset(PresetResponse(preset: preset)))
    }
}

// MARK: rule building

private func rule(_ name: String, _ actions: [RuleAction]) -> Rule {
    Rule(name: name, conditions: ConditionGroup(rows: []), actions: actions)
}

private func preset(_ preset: PresetResponse.Preset, body: String? = nil) -> RuleAction {
    RuleAction(.returnPreset(PresetResponse(preset: preset, body: body)))
}

private func handwritten(_ text: String) -> RuleAction {
    RuleAction(.returnHandwritten(HandwrittenResponse(text: text)))
}

private func setHeader(_ direction: HTTPMessageDirection, _ name: String, _ value: String = "1") -> RuleAction {
    RuleAction(.editHeaders(direction: direction, operations: [.set(name: name, value: value)]))
}

private func h2Headers(_ origin: HTTP2TestOrigin, method: String = "GET", path: String) -> HPACKHeaders {
    HPACKHeaders([(":method", method), (":scheme", "https"), (":authority", "localhost:\(origin.port)"), (":path", path)])
}
