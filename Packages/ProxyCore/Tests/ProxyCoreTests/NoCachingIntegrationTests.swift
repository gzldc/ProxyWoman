import FlowStore
import Foundation
import NIOCore
import NIOEmbedded
import NIOHTTP1
import Testing
@testable import ProxyCore
@testable import RulesEngine

/// The global No Caching tool in the HTTP exchange: the request side is the last step before the
/// wire (no validator ever leaves), the response side runs ahead of the response rules (a rule or
/// breakpoint may still override it), handshakes are untouched, and a switched-off tool changes
/// no byte.
@Suite(.serialized, .timeLimit(.minutes(2)), .productionChinese) struct NoCachingIntegrationTests {
    private static func provider(noCaching: Bool = true, allow: [String]? = nil) -> TrafficPolicyProvider {
        var policy = TrafficPolicy()
        policy.noCaching = noCaching
        if let allow {
            policy.allowEnabled = true
            policy.allowEntries = allow.map { TrafficFilterEntry(matcher: RuleMatcher(hostPattern: $0)) }
        }
        return TrafficPolicyProvider(policy)
    }

    private static let conditional: HTTPHeaders = [
        "If-None-Match": "\"v1\"", "If-Modified-Since": "Tue, 20 Oct 2026 00:00:00 GMT", "X-Keep": "yes",
    ]

    private static let validatorResponse = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nETag: \"v1\"\r\n"
        + "Last-Modified: Tue, 20 Oct 2026 00:00:00 GMT\r\nExpires: Wed, 21 Oct 2026\r\nCache-Control: max-age=3600\r\n\r\n"

    private static func lines(_ text: String) -> [String] { text.components(separatedBy: "\r\n") }
    private static func hasHeader(_ text: String, _ name: String) -> Bool {
        lines(text).contains { $0.lowercased().hasPrefix(name.lowercased() + ":") }
    }

    @Test func requestValidatorsAreStrippedAndNoCacheHeadersAdded() async throws {
        try await withConnectionFixture { fixture in
            let writer = RecordingResponseWriter(channel: fixture.client)
            let exchange = fixture.admit("/req", headers: Self.conditional, writer: writer,
                                         context: fixture.context(traffic: Self.provider()))
            exchange.receiveRequest(.end(nil))
            exchange.execute()
            guard !fixture.connections.isEmpty else { Issue.record("the request must be forwarded"); return }
            let upstream = try fixture.connect(0)
            let sent = try fixture.written(upstream)
            #expect(!Self.hasHeader(sent, "If-None-Match"))
            #expect(!Self.hasHeader(sent, "If-Modified-Since"))
            #expect(sent.contains("Cache-Control: no-cache\r\n"))
            #expect(sent.contains("Pragma: no-cache\r\n"))
            #expect(sent.contains("X-Keep: yes\r\n"))
            try upstream.writeInbound(ByteBuffer(string: "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"))
            fixture.loop.run()
            #expect(writer.heads.map(\.status.code) == [200])
            let flow = try fixture.flow("/req")
            #expect(flow.state == .completed)
            #expect(flow.messages[.downstreamRequest]?.headers.value(for: "if-none-match") == "\"v1\"")
            #expect(flow.messages[.downstreamRequest]?.headers.value(for: "cache-control") == nil)
            #expect(flow.messages[.upstreamRequest]?.headers.value(for: "if-none-match") == nil)
            #expect(flow.messages[.upstreamRequest]?.headers.value(for: "cache-control") == "no-cache")
            #expect(flow.provenance.tools.noCaching)
        }
    }

    @Test func responseValidatorsAreStrippedBeforeResponseRules() async throws {
        try await withConnectionFixture { fixture in
            let writer = RecordingResponseWriter(channel: fixture.client)
            let exchange = fixture.admit("/resp", writer: writer, context: fixture.context(traffic: Self.provider()))
            exchange.receiveRequest(.end(nil))
            exchange.execute()
            let upstream = try fixture.connect(0)
            _ = try fixture.written(upstream)
            try upstream.writeInbound(ByteBuffer(string: Self.validatorResponse))
            fixture.loop.run()
            let head = try #require(writer.heads.first)
            #expect(head.headers["cache-control"] == ["no-cache, no-store"])
            #expect(head.headers["expires"] == ["0"])
            #expect(head.headers["etag"].isEmpty)
            #expect(head.headers["last-modified"].isEmpty)
            let flow = try fixture.flow("/resp")
            #expect(flow.state == .completed)
            #expect(flow.messages[.upstreamResponse]?.headers.value(for: "etag") == "\"v1\"")
            #expect(flow.messages[.upstreamResponse]?.headers.value(for: "cache-control") == "max-age=3600")
            #expect(flow.provenance.tools.noCaching)
        }
    }

    @Test func responseRuleOverridesNoCaching() async throws {
        try await withConnectionFixture { fixture in
            let rule = TestRules.headers(.response, [.set(name: "Cache-Control", value: "public")])
            let writer = RecordingResponseWriter(channel: fixture.client)
            let exchange = fixture.admit("/rule", writer: writer,
                context: fixture.context(rules: TestRules.provider([rule]), traffic: Self.provider()))
            exchange.receiveRequest(.end(nil))
            exchange.execute()
            let upstream = try fixture.connect(0)
            _ = try fixture.written(upstream)
            try upstream.writeInbound(ByteBuffer(string: Self.validatorResponse))
            fixture.loop.run()
            let head = try #require(writer.heads.first)
            #expect(head.headers["cache-control"] == ["public"])
            #expect(head.headers["expires"] == ["0"])
            #expect(head.headers["etag"].isEmpty)
            let flow = try fixture.flow("/rule")
            #expect(flow.messages[.upstreamResponse]?.headers.value(for: "etag") == "\"v1\"")
            #expect(flow.provenance.ruleMatches?.ruleIDs == [rule.id])
        }
    }

    @Test func userRuleAddingConditionalHeaderIsStillStrippedOnRequests() async throws {
        try await withConnectionFixture { fixture in
            let rule = TestRules.headers(.request, [.set(name: "If-None-Match", value: "\"from-rule\""),
                                                    .set(name: "Cache-Control", value: "max-age=60")])
            let writer = RecordingResponseWriter(channel: fixture.client)
            let exchange = fixture.admit("/last", writer: writer,
                context: fixture.context(rules: TestRules.provider([rule]), traffic: Self.provider()))
            exchange.receiveRequest(.end(nil))
            exchange.execute()
            guard !fixture.connections.isEmpty else { Issue.record("the request must be forwarded"); return }
            let sent = try fixture.written(try fixture.connect(0))
            #expect(!Self.hasHeader(sent, "If-None-Match"))
            #expect(sent.contains("Cache-Control: no-cache\r\n"))
            #expect(!sent.contains("max-age=60"))
            let flow = try fixture.flow("/last")
            #expect(flow.provenance.ruleMatches?.ruleIDs == [rule.id])
        }
    }

    @Test func upgradeHandshakeIsUntouched() async throws {
        try await withConnectionFixture { fixture in
            var headers = Self.conditional
            headers.add(name: "Connection", value: "Upgrade")
            headers.add(name: "Upgrade", value: "websocket")
            headers.add(name: "Sec-WebSocket-Key", value: "dGhlIHNhbXBsZSBub25jZQ==")
            headers.add(name: "Sec-WebSocket-Version", value: "13")
            let writer = RecordingResponseWriter(channel: fixture.client)
            let exchange = fixture.admit("/ws", headers: headers, writer: writer,
                                         context: fixture.context(traffic: Self.provider()))
            exchange.receiveRequest(.end(nil))
            exchange.execute()
            guard !fixture.connections.isEmpty else { Issue.record("the handshake must be forwarded"); return }
            let upstream = try fixture.connect(0)
            let sent = try fixture.written(upstream)
            #expect(sent.contains("If-None-Match: \"v1\"\r\n"))
            #expect(sent.contains("If-Modified-Since: Tue, 20 Oct 2026 00:00:00 GMT\r\n"))
            #expect(!Self.hasHeader(sent, "Cache-Control"))
            #expect(!Self.hasHeader(sent, "Pragma"))
            // A refusal of the handshake keeps its validators too: the candidate flag covers both sides.
            try upstream.writeInbound(ByteBuffer(string: Self.validatorResponse))
            fixture.loop.run()
            let head = try #require(writer.heads.first)
            #expect(head.headers["etag"] == ["\"v1\""])
            #expect(head.headers["cache-control"] == ["max-age=3600"])
            let flow = try fixture.flow("/ws")
            #expect(!flow.provenance.tools.noCaching)
        }
    }

    @Test func oversizedHeaderBlockFailsLocallyNotSilently() async throws {
        try await withConnectionFixture { fixture in
            var headers = HTTPHeaders()
            for index in 0..<255 { headers.add(name: "X-Wide-\(index)", value: "v") }
            let writer = RecordingResponseWriter(channel: fixture.client)
            let exchange = fixture.admit("/wide", headers: headers, writer: writer,
                                         context: fixture.context(traffic: Self.provider()))
            exchange.receiveRequest(.end(nil))
            exchange.execute()
            #expect(fixture.connections.isEmpty)
            #expect(writer.heads.map(\.status.code) == [502])
            #expect(writer.ends == 1)
            #expect(exchange.localFailure == .ruleRejected)
            let flow = try fixture.flow("/wide")
            if case .failed = flow.state {} else { Issue.record("expected a failed flow, got \(flow.state)") }
            #expect(!flow.provenance.tools.noCaching)
        }
    }

    @Test func responseSideRejectionFailsTheExchange() async throws {
        try await withConnectionFixture { fixture in
            let writer = RecordingResponseWriter(channel: fixture.client)
            let exchange = fixture.admit("/resp-reject", writer: writer, context: fixture.context(traffic: Self.provider()))
            exchange.receiveRequest(.end(nil))
            exchange.execute()
            let upstream = try fixture.connect(0)
            _ = try fixture.written(upstream)
            // Connection nominates Cache-Control as hop-by-hop: setting it would change the nomination.
            try upstream.writeInbound(ByteBuffer(string:
                "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: Cache-Control\r\nCache-Control: max-age=5\r\n\r\n"))
            fixture.loop.run()
            #expect(writer.heads.map(\.status.code) == [502])
            #expect(writer.ends == 1)
            #expect(exchange.localFailure == .ruleRejected)
        }
    }

    @Test func offIsByteIdentical() async throws {
        var sentBytes: [String] = []
        var clientHeads: [[String]] = []
        for traffic in [nil, Self.provider(noCaching: false)] as [TrafficPolicyProvider?] {
            try await withConnectionFixture { fixture in
                let writer = RecordingResponseWriter(channel: fixture.client)
                let exchange = fixture.admit("/off", headers: Self.conditional, writer: writer,
                                             context: fixture.context(traffic: traffic))
                exchange.receiveRequest(.end(nil))
                exchange.execute()
                let upstream = try fixture.connect(0)
                sentBytes.append(try fixture.written(upstream))
                try upstream.writeInbound(ByteBuffer(string: Self.validatorResponse))
                fixture.loop.run()
                clientHeads.append(try #require(writer.heads.first).headers.map { "\($0.name): \($0.value)" })
                #expect(!(try fixture.flow("/off")).provenance.tools.noCaching)
            }
        }
        #expect(sentBytes.count == 2 && sentBytes[0] == sentBytes[1])
        #expect(sentBytes[0].contains("If-None-Match: \"v1\"\r\n"))
        #expect(clientHeads.count == 2 && clientHeads[0] == clientHeads[1])
        #expect(clientHeads[0].contains("ETag: \"v1\""))
    }

    @Test func allowMissBypassSkipsNoCaching() async throws {
        try await withConnectionFixture { fixture in
            let writer = RecordingResponseWriter(channel: fixture.client)
            let exchange = fixture.admit("/bypass", headers: Self.conditional, writer: writer,
                                         context: fixture.context(traffic: Self.provider(allow: ["only.test"])))
            exchange.receiveRequest(.end(nil))
            exchange.execute()
            guard !fixture.connections.isEmpty else { Issue.record("an Allow miss must still be forwarded"); return }
            let upstream = try fixture.connect(0)
            let sent = try fixture.written(upstream)
            #expect(sent.contains("If-None-Match: \"v1\"\r\n"))
            #expect(!Self.hasHeader(sent, "Cache-Control"))
            try upstream.writeInbound(ByteBuffer(string: Self.validatorResponse))
            fixture.loop.run()
            let head = try #require(writer.heads.first)
            #expect(head.headers["etag"] == ["\"v1\""])
            #expect(head.headers["cache-control"] == ["max-age=3600"])
        }
    }

    @Test func composeSendIsAlsoUncached() async throws {
        let traffic = Self.provider()
        try await ComposeFixture.run(traffic: traffic) { fx in
            let headers = [HeaderField(name: "If-None-Match", value: "\"v1\""), HeaderField(name: "X-Keep", value: "yes")]
            let sent = await fx.compose.send(ComposeRequest(method: "GET", url: fx.url("/hello"), headers: headers))
            #expect(sent.failure == nil)
            let seen = try #require(fx.origin.state.withLock { $0.heads.last })
            #expect(seen.headers["if-none-match"].isEmpty)
            #expect(seen.headers["cache-control"] == ["no-cache"])
            #expect(seen.headers["pragma"] == ["no-cache"])
            #expect(seen.headers["x-keep"] == ["yes"])
            let flowID = try #require(sent.flowID)
            let flow = try await waitForFlow(fx.store) { $0.id == flowID && $0.state == .completed }
            #expect(flow.provenance.tools.noCaching)
            #expect(flow.provenance.isCompose)
            fx.expectIdle()
        }
    }

    @Test func realServerForwardsUncachedHeadsAndCleansResponse() async throws {
        let origin = try await ComposeOrigin.start(tls: nil)
        do {
            try await RulesComposeServer.run(traffic: Self.provider()) { fx in
                let raw = try await RawClient.connect(port: try fx.port)
                do {
                    try await raw.send("GET http://127.0.0.1:\(origin.port)/hello HTTP/1.1\r\nHost: 127.0.0.1:\(origin.port)\r\n"
                        + "If-None-Match: \"v1\"\r\nConnection: close\r\n\r\n")
                    try await raw.waitUntilClosed()
                    let text = String(decoding: raw.remainingBytes(), as: UTF8.self)
                    try await raw.close()
                    #expect(text.hasPrefix("HTTP/1.1 200"), "\(text)")
                    #expect(text.contains("Cache-Control: no-cache, no-store\r\n"))
                } catch { try? await raw.close(); throw error }
                let seen = try #require(origin.state.withLock { $0.heads.last })
                #expect(seen.headers["if-none-match"].isEmpty)
                #expect(seen.headers["cache-control"] == ["no-cache"])
                let flow = try await waitForFlow(fx.store) { $0.path == "/hello" && $0.state == .completed }
                #expect(flow.provenance.tools.noCaching)
            }
            try await origin.stop()
        } catch { try? await origin.stop(); throw error }
    }
}
