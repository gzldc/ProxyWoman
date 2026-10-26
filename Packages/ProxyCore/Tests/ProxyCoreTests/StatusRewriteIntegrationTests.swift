import FlowStore
import Foundation
import NIOCore
import NIOHTTP1
import Testing
@testable import ProxyCore
@testable import RulesEngine

/// Status code rewrite rules through the real proxy: what the client's wire carries, what each
/// flow boundary keeps, and what a response breakpoint shows (spec B8-B11).
@Suite(.serialized, .timeLimit(.minutes(3)), .productionChinese) struct StatusRewriteIntegrationTests {
    @Test func origin404BecomesClient200WithOkReason() async throws {
        let rule = TestRules.rewriteStatus(200)
        try await ProxyFixture.run(rules: TestRules.provider([rule])) { fx in
            let reply = try await statusRaw(fx, path: "/missing")
            #expect(reply.head.hasPrefix("HTTP/1.1 200 OK\r\n"))
            #expect(reply.body == Data("not found".utf8))
            #expect(reply.field("content-length") == ["9"])
            let flow = try await waitForFlow(fx.store) { $0.state == .completed }
            // Upstream boundary: what the origin sent. Downstream boundary: what the client got.
            #expect(flow.messages[.upstreamResponse]?.status == 404)
            #expect(flow.messages[.downstreamResponse]?.status == 200)
            #expect(flow.provenance.ruleMatches?.outcomes == [RuleOutcome(ruleID: rule.id, code: .applied)])
        }
    }

    @Test func http1WritesTheReasonPhraseTheRuleCarries() async throws {
        let rule = TestRules.rewriteStatus(200, reason: "Totally Fine")
        try await ProxyFixture.run(rules: TestRules.provider([rule])) { fx in
            let reply = try await statusRaw(fx, path: "/missing")
            #expect(reply.head.hasPrefix("HTTP/1.1 200 Totally Fine\r\n"))
            #expect(reply.body == Data("not found".utf8))
            let flow = try await waitForFlow(fx.store) { $0.state == .completed }
            #expect(flow.messages[.downstreamResponse]?.status == 200)
        }
    }

    @Test func http2IgnoresTheReasonPhrase() async throws {
        var response = HTTP2TestOrigin.Response()
        response.status = .notFound
        let rules = TestRules.provider([TestRules.rewriteStatus(200, reason: "Totally Fine")])
        try await HTTP2TestOrigin.withOrigin(protocols: ["h2", "http/1.1"], response: response) { origin in
            try await HTTP2ProxyFixture.withProxy(origin: origin, downstreamH2: true, rules: rules) { fixture, client in
                let reply = try await client.request(headers: HTTPHeaders([("host", "localhost:\(origin.port)")]), path: "/h2")
                #expect(reply.status == 200)
                #expect(reply.body == "fixture-body")
                try await waitForCompletedFlows(fixture.store, atLeast: 1)
                let flow = try #require(fixture.store.allFlows().first { $0.path == "/h2" })
                #expect(flow.messages[.downstreamResponse]?.status == 200)
                #expect(flow.messages[.downstreamResponse]?.wireVersion == .http2)
            }
        }
    }

    @Test func statusRangeConditionOnlyRewritesMatching() async throws {
        let rule = TestRules.rewriteStatus(404, matcher: RuleMatcher(statusRange: 500...599))
        try await ProxyFixture.run(rules: TestRules.provider([rule])) { fx in
            let failing = try await statusRaw(fx, path: "/status?code=503")
            #expect(failing.head.hasPrefix("HTTP/1.1 404 Not Found\r\n"))
            #expect(failing.body == Data("origin-body".utf8))
            let healthy = try await statusRaw(fx, path: "/hello")
            #expect(healthy.head.hasPrefix("HTTP/1.1 200 OK\r\n"))
            #expect(healthy.body == Data("hello".utf8))
            try await waitForCompletedFlows(fx.store, atLeast: 2)
            let flows = fx.store.allFlows()
            let rewritten = try #require(flows.first { $0.path == "/status?code=503" })
            let untouched = try #require(flows.first { $0.path == "/hello" })
            #expect(rewritten.messages[.downstreamResponse]?.status == 404)
            #expect(untouched.messages[.downstreamResponse]?.status == 200)
            #expect(untouched.provenance.ruleMatches == nil)
        }
    }

    @Test func rewriteTo204DropsBodyAndNoContentLengthSent() async throws {
        let rule = TestRules.rewriteStatus(204, matcher: RuleMatcher(statusRange: 404...404))
        try await ProxyFixture.run(rules: TestRules.provider([rule])) { fx in
            let reply = try await statusRaw(fx, path: "/missing")
            #expect(reply.head.hasPrefix("HTTP/1.1 204 No Content\r\n"))
            #expect(reply.field("content-length").isEmpty)
            #expect(reply.field("transfer-encoding").isEmpty)
            #expect(reply.body.isEmpty)
            try await waitForCompletedFlows(fx.store, atLeast: 1)

            // A kept-alive connection stays in step: the origin's body did not leak into the next reply.
            let client = try await RawClient.connect(port: fx.proxyPort)
            let host = "127.0.0.1:\(fx.origin.port)"
            try await client.send("GET http://\(host)/missing HTTP/1.1\r\nHost: \(host)\r\n\r\n")
            let first = try await client.receive(until: "\r\n\r\n")
            #expect(first.hasPrefix("HTTP/1.1 204 No Content\r\n"))
            try await client.send("GET http://\(host)/hello HTTP/1.1\r\nHost: \(host)\r\n\r\n")
            let second = try await client.receive(until: "hello")
            #expect(second.hasPrefix("HTTP/1.1 200 OK\r\n"))
            try await client.close()
        }
    }

    @Test func origin204Rewritten200HasZeroContentLength() async throws {
        let rule = TestRules.rewriteStatus(200)
        try await ProxyFixture.run(rules: TestRules.provider([rule])) { fx in
            let reply = try await statusRaw(fx, path: "/status?code=204")
            #expect(reply.head.hasPrefix("HTTP/1.1 200 OK\r\n"))
            #expect(reply.field("content-length") == ["0"])
            #expect(reply.body.isEmpty)
            let flow = try await waitForFlow(fx.store) { $0.state == .completed }
            #expect(flow.messages[.upstreamResponse]?.status == 204)
            #expect(flow.messages[.downstreamResponse]?.status == 200)
        }
    }

    @Test(arguments: [false, true])
    func http2ClientSeesRewrittenStatus(upstreamH2: Bool) async throws {
        var response = HTTP2TestOrigin.Response()
        response.status = .notFound
        let rules = TestRules.provider([TestRules.rewriteStatus(200)])
        try await HTTP2TestOrigin.withOrigin(protocols: upstreamH2 ? ["h2", "http/1.1"] : ["http/1.1"], response: response) { origin in
            try await HTTP2ProxyFixture.withProxy(origin: origin, downstreamH2: true, rules: rules) { fixture, client in
                let reply = try await client.request(headers: HTTPHeaders([("host", "localhost:\(origin.port)")]), path: "/h2")
                #expect(reply.status == 200)
                #expect(reply.body == "fixture-body")
                try await waitForCompletedFlows(fixture.store, atLeast: 1)
                let flow = try #require(fixture.store.allFlows().first { $0.path == "/h2" })
                #expect(flow.messages[.upstreamResponse]?.status == 404)
                #expect(flow.messages[.downstreamResponse]?.status == 200)
                #expect(flow.messages[.downstreamResponse]?.wireVersion == .http2)
            }
        }
    }

    @Test func mapLocalResponseNotRewrittenByDefault() async throws {
        let rewrite = TestRules.rewriteStatus(404)
        try await withLocalAsset(Data("local file".utf8)) { asset in
            // R1 intentional change class 1: a rule must rank above the Return File rule to act on its exchange.
            try await ProxyFixture.run(rules: asset.rules(higher: [rewrite]), assets: asset.store) { fx in
                let reply = try await statusRaw(fx, path: "/local")
                #expect(reply.head.hasPrefix("HTTP/1.1 200 OK\r\n"))
                #expect(reply.body == Data("local file".utf8))
                let flow = try await waitForFlow(fx.store) { $0.state == .completed }
                #expect(flow.messages[.downstreamResponse]?.status == 200)
            }
        }
        try await withMappedDirectory(["a.css": Data("body{}".utf8)]) { dir in
            // R1 intentional change class 1: a rule must rank above the Return File rule to act on its exchange.
            try await ProxyFixture.run(rules: dir.rules(higher: [rewrite]), assets: dir.store) { fx in
                let reply = try await statusRaw(fx, host: "app.test", path: "/static/a.css")
                #expect(reply.head.hasPrefix("HTTP/1.1 200 OK\r\n"))
                #expect(reply.body == Data("body{}".utf8))
                let flow = try await waitForFlow(fx.store) { $0.state == .completed }
                #expect(flow.messages[.downstreamResponse]?.status == 200)
            }
        }
    }

    /// Recording semantics, as for header edits: `generatedResponse` keeps the response the local
    /// source produced (200), `downstreamResponse` what the client received (the rewritten status).
    @Test func mapLocalResponseRewrittenWhenIncluded() async throws {
        let rewrite = TestRules.rewriteStatus(404, includeLocalResponses: true)
        try await withLocalAsset(Data("local file".utf8)) { asset in
            // R1 intentional change class 1: a rule must rank above the Return File rule to act on its exchange.
            try await ProxyFixture.run(rules: asset.rules(higher: [rewrite]), assets: asset.store) { fx in
                let reply = try await statusRaw(fx, path: "/local")
                #expect(reply.head.hasPrefix("HTTP/1.1 404 Not Found\r\n"))
                #expect(reply.body == Data("local file".utf8))
                #expect(reply.field("content-length") == ["10"])
                #expect(fx.origin.acceptedConnections == 0)
                let flow = try await waitForFlow(fx.store) { $0.state == .completed }
                #expect(flow.messages[.generatedResponse]?.status == 200)
                #expect(flow.messages[.downstreamResponse]?.status == 404)
                #expect(try flow.messages[.downstreamResponse]?.body?.load() == Data("local file".utf8))
            }
        }
        try await withMappedDirectory(["a.css": Data("body{}".utf8)]) { dir in
            // R1 intentional change class 1: a rule must rank above the Return File rule to act on its exchange.
            try await ProxyFixture.run(rules: dir.rules(higher: [rewrite]), assets: dir.store) { fx in
                let reply = try await statusRaw(fx, host: "app.test", path: "/static/a.css")
                #expect(reply.head.hasPrefix("HTTP/1.1 404 Not Found\r\n"))
                #expect(reply.body == Data("body{}".utf8))
                let flow = try await waitForFlow(fx.store) { $0.state == .completed }
                #expect(flow.messages[.generatedResponse]?.status == 200)
                #expect(flow.messages[.downstreamResponse]?.status == 404)
            }
        }
    }

    @Test func mapLocalResponseRewrittenTo204HasNoBody() async throws {
        let rewrite = TestRules.rewriteStatus(204, includeLocalResponses: true)
        try await withLocalAsset(Data("local file".utf8)) { asset in
            // R1 intentional change class 1: a rule must rank above the Return File rule to act on its exchange.
            try await ProxyFixture.run(rules: asset.rules(higher: [rewrite]), assets: asset.store) { fx in
                let reply = try await statusRaw(fx, path: "/local")
                #expect(reply.head.hasPrefix("HTTP/1.1 204 No Content\r\n"))
                #expect(reply.field("content-length").isEmpty)
                #expect(reply.body.isEmpty)
                let flow = try await waitForFlow(fx.store) { $0.state == .completed }
                #expect(flow.messages[.downstreamResponse]?.status == 204)
            }
        }
    }

    @Test func localStatusSkippedOutcomeRecorded() async throws {
        let rewrite = TestRules.rewriteStatus(404)
        try await withLocalAsset(Data("local file".utf8)) { asset in
            // R1 intentional change class 1: a rule must rank above the Return File rule to act on its exchange.
            try await ProxyFixture.run(rules: asset.rules(higher: [rewrite]), assets: asset.store) { fx in
                _ = try await statusRaw(fx, path: "/local")
                let flow = try await waitForFlow(fx.store) { $0.state == .completed }
                let matches = try #require(flow.provenance.ruleMatches)
                #expect(matches.ruleIDs.contains(rewrite.id))
                #expect(matches.outcomes.contains(RuleOutcome(ruleID: rewrite.id, code: .statusSkippedLocal)))
            }
        }
    }

    @Test func upgradeSwitchingProtocolsNotRewritten() async throws {
        let rewrite = TestRules.rewriteStatus(200)
        try await ProxyFixture.run(rules: TestRules.provider([rewrite])) { fx in
            let client = try await RawClient.connect(port: fx.proxyPort)
            let p = fx.origin.port
            try await client.send(
                "GET http://127.0.0.1:\(p)/ws HTTP/1.1\r\nHost: 127.0.0.1:\(p)\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n")
            let head = try await client.receive(until: "\r\n\r\n")
            #expect(head.hasPrefix("HTTP/1.1 101 Switching Protocols\r\n"))
            #expect(try await client.receive(until: TestOriginServer.wsGreeting) == TestOriginServer.wsGreeting)
            try await client.close()
            let flow = try await waitForFlow(fx.store) { $0.path == "/ws" && $0.state == .completed }
            #expect(flow.messages[.downstreamResponse]?.status == 101)
            #expect(flow.provenance.ruleMatches?.outcomes == [RuleOutcome(ruleID: rewrite.id, code: .unsupportedUpgradeAction)])
        }
    }

    @Test func twoStatusRulesRunInOrderAndTheSecondWins() async throws {
        let first = TestRules.rewriteStatus(404)
        let second = TestRules.rewriteStatus(500)
        try await ProxyFixture.run(rules: TestRules.provider([first, second])) { fx in
            let reply = try await statusRaw(fx, path: "/hello")
            // R1 intentional change class 3: both rewrites run in order; the second one's status wins.
            #expect(reply.head.hasPrefix("HTTP/1.1 500 Internal Server Error\r\n"))
            let flow = try await waitForFlow(fx.store) { $0.state == .completed }
            // R1 intentional change class 3: both rewrites run in order; the second one's status wins.
            #expect(flow.messages[.downstreamResponse]?.status == 500)
            let matches = try #require(flow.provenance.ruleMatches)
            #expect(matches.ruleIDs == [first.id, second.id])
            // R1 intentional change class 3: the second rewrite is applied, not shadowed.
            #expect(matches.outcomes == [RuleOutcome(ruleID: first.id, code: .applied),
                                         RuleOutcome(ruleID: second.id, code: .applied)])
        }
    }

    @Test func statusRewriteTogetherWithHeaderEditRule() async throws {
        let edit = TestRules.headers(.response, [.set(name: "X-Edited", value: "yes")])
        let rewrite = TestRules.rewriteStatus(418)
        try await ProxyFixture.run(rules: TestRules.provider([edit, rewrite])) { fx in
            let reply = try await statusRaw(fx, path: "/hello")
            #expect(reply.head.hasPrefix("HTTP/1.1 418 I'm a teapot\r\n"))
            #expect(reply.field("x-edited") == ["yes"])
            #expect(reply.body == Data("hello".utf8))
            let flow = try await waitForFlow(fx.store) { $0.state == .completed }
            #expect(flow.provenance.ruleMatches?.outcomes == [RuleOutcome(ruleID: edit.id, code: .applied),
                                                              RuleOutcome(ruleID: rewrite.id, code: .applied)])
            #expect(flow.messages[.upstreamResponse]?.status == 200)
            #expect(flow.messages[.downstreamResponse]?.status == 418)
        }
    }

    @Test func responseBreakpointSeesRewrittenEffectiveHeadAndOriginalUpstreamHead() async throws {
        try await withConnectionFixture { f in
            let b = BreakpointCoordinator(clock: EmbeddedBreakpointClock(now: f.loop.now))
            let rules = TestRules.provider([TestRules.rewriteStatus(200), TestRules.breakpoint(.response)])
            let c = f.context(rules: rules, breakpoints: b)
            let w = RecordingResponseWriter(channel: f.client)
            let x = f.admit("/rewritten-paused", writer: w, context: c)
            x.execute(); x.receiveRequest(.end(nil))
            defer { x.cancel(reason: "cleanup") }
            let upstream = try f.connect(0)
            try upstream.writeInbound(ByteBuffer(string: "HTTP/1.1 404 Not Found\r\nContent-Length: 5\r\n\r\nhello"))
            #expect(w.heads.isEmpty)
            let ticket = try #require(b.snapshot().first)
            guard case .response(let originalStatus, let originalReason, _) = ticket.originalHead,
                  case .response(let effectiveStatus, _, _) = ticket.effectiveHead else {
                Issue.record("expected response heads"); return
            }
            #expect(originalStatus == 404)
            #expect(originalReason == "Not Found")
            #expect(effectiveStatus == 200)
            // Continuing unchanged releases the rewritten status with its standard phrase.
            #expect(try breakpointPerform(b, .continue(token: ticket.token, edit: .init(head: ticket.effectiveHead)), f) == .accepted)
            #expect(w.heads.map(\.status.code) == [200])
            #expect(w.heads.first?.status.reasonPhrase == "OK")
            #expect(w.body == "hello")
            let flow = try f.flow("/rewritten-paused")
            #expect(flow.messages[.upstreamResponse]?.status == 404)
            #expect(flow.messages[.downstreamResponse]?.status == 200)
        }
    }

    @Test func noStatusRulesTrafficByteIdentical() async throws {
        let paths = ["/hello", "/missing", "/status?code=204", "/status?code=500", "/json"]
        var plain: [String: [UInt8]] = [:]
        try await ProxyFixture.run { fx in
            for path in paths { plain[path] = try await statusRaw(fx, path: path).raw }
        }
        // Rules exist but none matches any of these responses.
        let rules = TestRules.provider([
            TestRules.rewriteStatus(200, matcher: RuleMatcher(statusRange: 301...399)),
            TestRules.rewriteStatus(200, matcher: RuleMatcher(hostPattern: "no-such-host.test")),
        ])
        try await ProxyFixture.run(rules: rules) { fx in
            for path in paths {
                let reply = try await statusRaw(fx, path: path)
                #expect(reply.raw == plain[path], "\(path)")
            }
            try await waitForCompletedFlows(fx.store, atLeast: paths.count)
            #expect(fx.store.allFlows().allSatisfy { $0.provenance.ruleMatches == nil })
        }
    }
}

/// One plain-HTTP proxy request on its own `Connection: close` connection.
private struct StatusReply {
    let raw: [UInt8]
    let head: String
    let body: Data

    func field(_ name: String) -> [String] {
        head.components(separatedBy: "\r\n").dropFirst().compactMap { line in
            guard let colon = line.firstIndex(of: ":"), line[..<colon].lowercased() == name else { return nil }
            return line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
    }
}

private func statusRaw(_ fixture: ProxyFixture, host: String? = nil, path: String) async throws -> StatusReply {
    let host = host ?? "127.0.0.1:\(fixture.origin.port)"
    let client = try await RawClient.connect(port: fixture.proxyPort)
    do {
        try await client.send("GET http://\(host)\(path) HTTP/1.1\r\nHost: \(host)\r\nConnection: close\r\n\r\n")
        try await client.waitUntilClosed()
        let bytes = client.remainingBytes()
        try await client.close()
        let data = Data(bytes)
        let separator = try #require(data.range(of: Data("\r\n\r\n".utf8)))
        return StatusReply(raw: bytes, head: String(decoding: data[..<separator.lowerBound], as: UTF8.self),
                           body: Data(data[separator.upperBound...]))
    } catch { try? await client.close(); throw error }
}
