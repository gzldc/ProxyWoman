import FlowStore
import Foundation
import NIOCore
import NIOConcurrencyHelpers
import NIOHPACK
import NIOHTTP2
import NIOSSL
import Testing
@testable import ProxyCore
@testable import RulesEngine

/// Spec 12.7 (final review): Return File / manual / predefined response, close and delay work at either point. A rule
/// judged at the response (here: the status is 200) answers in place of the origin's response, closes the client's
/// connection or stream, or holds the response head. The origin is contacted and answers first in every case.
@Suite(.serialized, .timeLimit(.minutes(3)), .productionChinese) struct RuleResponsePointIntegrationTests {
    // MARK: Return

    @Test func presetReplacesTheOriginsResponse() async throws {
        let answer = judged("answer", [preset(.forbidden403, body: "nope")])
        try await ProxyFixture.run(rules: TestRules.provider([answer])) { fx in
            let reply = try await directoryRaw(fx, host: "127.0.0.1:\(fx.origin.port)", path: "/hello")
            #expect(reply.head.hasPrefix("HTTP/1.1 403 Forbidden\r\n"))
            #expect(reply.field("content-length") == ["4"])
            #expect(reply.body == Data("nope".utf8))
            // The origin answered first; its response is discarded.
            #expect(fx.origin.receivedRequestCount == 1)
            let flow = try await waitForFlow(fx.store) { $0.path == "/hello" && $0.state == .completed }
            #expect(flow.messages[.upstreamResponse]?.status == 200)
            #expect(flow.messages[.downstreamResponse]?.status == 403)
            #expect(flow.provenance.generatedResponse != nil)
            #expect(flow.provenance.rulesModified)
            #expect(flow.provenance.ruleMatches?.outcomes == [RuleOutcome(ruleID: answer.id, code: .applied)])
        }
    }

    /// The flow shows what the client got: the replacement's status, headers, body and byte count, not the origin's.
    @Test func replacedFlowRecordsWhatTheClientReceived() async throws {
        let answer = judged("answer", [preset(.forbidden403, body: "nope")])
        try await ProxyFixture.run(rules: TestRules.provider([answer])) { fx in
            _ = try await directoryRaw(fx, host: "127.0.0.1:\(fx.origin.port)", path: "/json")
            let flow = try await waitForFlow(fx.store) { $0.path == "/json" && $0.state == .completed }
            #expect(flow.statusCode == 403)
            #expect(flow.responseHeaders.contains { $0.name.lowercased() == "content-length" && $0.value == "4" })
            #expect(try flow.responseBody?.load() == Data("nope".utf8))
            #expect(flow.bytesReceived == 4)
            // The origin's response stays as a record of what was dropped, ended incomplete.
            let origin = try #require(flow.messages[.upstreamResponse])
            #expect(origin.status == 200)
            #expect(origin.transferState == .failed)
        }
    }

    /// A rule judged at completion reads the replacement's status.
    @Test func completionRuleSeesTheReplacementStatus() async throws {
        let seen = Rule(
            name: "seen",
            conditions: ConditionGroup(rows: [
                ConditionRow(field: .statusCode, op: .equals, value: "403"),
                ConditionRow(field: .durationMs, op: .greaterOrEqual, value: "0"),
            ]),
            actions: [RuleAction(.mark(MarkAction(background: "#FF3B30")))])
        let answer = judged("answer", [preset(.forbidden403, body: "nope")])
        try await ProxyFixture.run(rules: TestRules.provider([seen, answer])) { fx in
            _ = try await directoryRaw(fx, host: "127.0.0.1:\(fx.origin.port)", path: "/hello")
            let flow = try await waitForFlow(fx.store) { $0.path == "/hello" && $0.state == .completed }
            #expect(flow.provenance.ruleMatches?.outcomes.contains { $0.ruleID == seen.id && $0.code == .applied } == true)
        }
    }

    @Test func manualResponseReplacesTheOriginsResponseByteForByte() async throws {
        let text = "HTTP/1.1 201 Created\r\nX-Custom: a b\r\nContent-Type: text/plain\r\n\r\nhello"
        let answer = judged("manual", [RuleAction(.returnHandwritten(HandwrittenResponse(text: text)))])
        try await ProxyFixture.run(rules: TestRules.provider([answer])) { fx in
            let reply = try await directoryRaw(fx, host: "127.0.0.1:\(fx.origin.port)", path: "/json")
            #expect(reply.raw == "HTTP/1.1 201 Created\r\nX-Custom: a b\r\nContent-Type: text/plain\r\nContent-Length: 5\r\n"
                + "Connection: close\r\n\r\nhello")
            #expect(fx.origin.receivedRequestCount == 1)
        }
    }

    @Test func returnFileReplacesTheOriginsResponse() async throws {
        try await withLocalAsset(Data("local-bytes".utf8)) { asset in
            let answer = judged("file", [
                RuleAction(.returnFile(MapLocalAction(
                    assetID: asset.asset.id, headers: [HeaderField(name: "Content-Type", value: "application/octet-stream")])))
            ])
            try await ProxyFixture.run(rules: TestRules.provider([answer]), assets: asset.store) { fx in
                let reply = try await directoryRaw(fx, host: "127.0.0.1:\(fx.origin.port)", path: "/hello")
                #expect(reply.head.hasPrefix("HTTP/1.1 200 OK\r\n"))
                #expect(reply.body == Data("local-bytes".utf8))
                #expect(fx.origin.receivedRequestCount == 1)
                let flow = try await waitForFlow(fx.store) { $0.path == "/hello" && $0.state == .completed }
                #expect(flow.messages[.upstreamResponse]?.status == 200)
                #expect(flow.provenance.generatedResponse?.assetID == asset.asset.id)
            }
        }
    }

    /// The origin's response had its headers edited by a rule above; none of that reaches the client.
    @Test func theReplacementIsNotTouchedByTheRulesThatRanOnTheOriginsResponse() async throws {
        let above = judged("above", [RuleAction(.editHeaders(direction: .response, operations: [.set(name: "X-Above", value: "1")]))])
        let answer = judged("answer", [preset(.forbidden403, body: "nope")])
        let below = judged("below", [RuleAction(.editHeaders(direction: .response, operations: [.set(name: "X-Below", value: "1")]))])
        try await ProxyFixture.run(rules: TestRules.provider([above, answer, below])) { fx in
            let reply = try await directoryRaw(fx, host: "127.0.0.1:\(fx.origin.port)", path: "/hello")
            #expect(reply.head.hasPrefix("HTTP/1.1 403 Forbidden\r\n"))
            #expect(reply.field("x-above").isEmpty)
            #expect(reply.field("x-below").isEmpty)
            let flow = try await waitForFlow(fx.store) { $0.path == "/hello" && $0.state == .completed }
            #expect(flow.provenance.ruleMatches?.ruleIDs == [above.id, answer.id])
        }
    }

    /// A Return File of the request point already answered: the response rule cannot replace the proxy's own response.
    @Test func aRequestPointReturnIsNotReplacedAgain() async throws {
        try await withLocalAsset(Data("local-bytes".utf8)) { asset in
            let again = judged("again", [preset(.forbidden403, body: "nope")])
            let file = Rule(name: "file", conditions: ConditionGroup(rows: []), actions: [
                RuleAction(.returnFile(MapLocalAction(assetID: asset.asset.id, headers: [])))
            ])
            try await ProxyFixture.run(rules: TestRules.provider([again, file]), assets: asset.store) { fx in
                let reply = try await directoryRaw(fx, host: "127.0.0.1:\(fx.origin.port)", path: "/hello")
                #expect(reply.head.hasPrefix("HTTP/1.1 200 OK\r\n"))
                #expect(reply.body == Data("local-bytes".utf8))
                #expect(fx.origin.acceptedConnections == 0)
                let flow = try await waitForFlow(fx.store) { $0.path == "/hello" && $0.state == .completed }
                #expect(flow.provenance.ruleMatches?.outcomes.contains(RuleOutcome(ruleID: again.id, code: .responseAlreadyLocal)) == true)
            }
        }
    }

    // MARK: Close

    @Test func gracefulCloseDropsTheOriginsResponse() async throws {
        let close = judged("close", [RuleAction(.closeConnection(.graceful))])
        try await ProxyFixture.run(rules: TestRules.provider([close])) { fx in
            let reply = try await wireExchange(port: fx.proxyPort, get(fx, "/hello"))
            #expect(reply.bytes.isEmpty, "\(String(decoding: reply.bytes, as: UTF8.self))")
            #expect(reply.ending == .fin)
            let flow = try await waitForFlow(fx.store) { $0.path == "/hello" && $0.completedAt != nil }
            #expect(flow.state == .failed(HTTPLocalFailureText.ruleClosed(ruleName: "close")))
            #expect(flow.messages[.downstreamResponse] == nil)
            #expect(fx.origin.receivedRequestCount == 1)
            #expect(flow.provenance.ruleMatches?.outcomes == [RuleOutcome(ruleID: close.id, code: .applied)])
        }
    }

    @Test func resetCloseDropsTheOriginsResponse() async throws {
        let close = judged("close", [RuleAction(.closeConnection(.reset))])
        try await ProxyFixture.run(rules: TestRules.provider([close])) { fx in
            let reply = try await wireExchange(port: fx.proxyPort, get(fx, "/hello"))
            #expect(reply.bytes.isEmpty, "\(String(decoding: reply.bytes, as: UTF8.self))")
            #expect(reply.ending == .reset)
            let flow = try await waitForFlow(fx.store) { $0.path == "/hello" && $0.completedAt != nil }
            #expect(flow.state == .failed(HTTPLocalFailureText.ruleClosed(ruleName: "close")))
        }
    }

    // MARK: Delay

    @Test func delayHoldsTheResponseHeadUntilTheTimerFires() async throws {
        let probe = ResponseDelayProbe()
        let delay = judged("delay", [RuleAction(.delay(milliseconds: 300))])
        try await ProxyFixture.run(rules: TestRules.provider([delay]), ruleDelayHook: probe.hook) { fx in
            let client = try await RawClient.connect(port: fx.proxyPort)
            let host = "127.0.0.1:\(fx.origin.port)"
            try await client.send("GET http://\(host)/hello HTTP/1.1\r\nHost: \(host)\r\n\r\n")
            try await waitUntil("the delay to be requested") { probe.delays.count == 1 }
            #expect(probe.delays == [.milliseconds(300)])
            // The request went upstream; its response is held.
            #expect(fx.origin.receivedRequestCount == 1)
            #expect(client.remainingBytes().isEmpty)
            probe.fireDirectly()
            let reply = try await client.receive(until: "hello")
            #expect(reply.hasPrefix("HTTP/1.1 200 OK\r\n"))
            let flow = try await waitForFlow(fx.store) { $0.path == "/hello" && $0.state == .completed }
            #expect(flow.provenance.ruleMatches?.outcomes == [RuleOutcome(ruleID: delay.id, code: .applied)])
            #expect(!flow.provenance.rulesModified)
            try await client.close()
        }
    }

    @Test func delayThenReturnHoldsTheReplacementToo() async throws {
        let probe = ResponseDelayProbe()
        let both = judged("both", [RuleAction(.delay(milliseconds: 200)), preset(.forbidden403, body: "nope")])
        try await ProxyFixture.run(rules: TestRules.provider([both]), ruleDelayHook: probe.hook) { fx in
            let client = try await RawClient.connect(port: fx.proxyPort)
            let host = "127.0.0.1:\(fx.origin.port)"
            try await client.send("GET http://\(host)/hello HTTP/1.1\r\nHost: \(host)\r\n\r\n")
            try await waitUntil("the delay to be requested") { probe.delays.count == 1 }
            #expect(client.remainingBytes().isEmpty)
            probe.fireDirectly()
            let reply = try await client.receive(until: "nope")
            #expect(reply.hasPrefix("HTTP/1.1 403 Forbidden\r\n"))
            try await client.close()
        }
    }

    /// The origin keeps sending while the head is held: reading pauses, so a body past the pending cap is not a failure.
    @Test func delayedResponseWithABodyOverThePendingCapIsDelivered() async throws {
        let probe = ResponseDelayProbe()
        let delay = judged("delay", [RuleAction(.delay(milliseconds: 100))])
        try await ProxyFixture.run(rules: TestRules.provider([delay]), ruleDelayHook: probe.hook) { fx in
            let client = try await RawClient.connect(port: fx.proxyPort)
            let host = "127.0.0.1:\(fx.origin.port)"
            try await client.send("GET http://\(host)/big?mb=1 HTTP/1.1\r\nHost: \(host)\r\n\r\n")
            try await waitUntil("the delay to be requested") { probe.delays.count == 1 }
            probe.fireDirectly()
            let bytes = try await client.receive(count: 1 << 20)
            #expect(String(decoding: bytes.prefix(15), as: UTF8.self) == "HTTP/1.1 200 OK")
            let flow = try await waitForFlow(fx.store) { $0.path == "/big?mb=1" && $0.completedAt != nil }
            #expect(flow.state == .completed)
            #expect(flow.messages[.downstreamResponse]?.status == 200)
            try await client.close()
        }
    }

    /// The delay timer dies with the exchange.
    @Test func aClientThatLeavesDuringTheDelayEndsTheExchange() async throws {
        let probe = ResponseDelayProbe()
        let delay = judged("delay", [RuleAction(.delay(milliseconds: 300))])
        try await ProxyFixture.run(rules: TestRules.provider([delay]), ruleDelayHook: probe.hook) { fx in
            let client = try await RawClient.connect(port: fx.proxyPort)
            let host = "127.0.0.1:\(fx.origin.port)"
            try await client.send("GET http://\(host)/hello HTTP/1.1\r\nHost: \(host)\r\n\r\n")
            try await waitUntil("the delay to be requested") { probe.delays.count == 1 }
            try await client.close()
            let flow = try await waitForFlow(fx.store) { $0.path == "/hello" && $0.completedAt != nil }
            _ = flow
            // A late timer does nothing and does not crash.
            probe.fireDirectly()
        }
    }

    // MARK: HTTP/2

    @Test func http2PresetReplacesTheOriginsResponse() async throws {
        let answer = judged("answer", [preset(.forbidden403, body: "nope")])
        try await HTTP2TestOrigin.withOrigin(protocols: ["h2"]) { origin in
            try await HTTP2ProxyFixture.withProxy(origin: origin, downstreamH2: true, rules: TestRules.provider([answer])) { fx, client in
                let reply = try await client.rawRequest(headers: h2Headers(origin, path: "/h2"))
                #expect(reply.status == 403)
                #expect(reply.body == "nope")
                let flow = try await waitForFlow(fx.store) { $0.path == "/h2" && $0.state == .completed }
                #expect(flow.messages[.upstreamResponse]?.status == 200)
                #expect(flow.messages[.downstreamResponse]?.status == 403)
                // The parent connection stays usable.
                let second = try await client.rawRequest(headers: h2Headers(origin, path: "/again"))
                #expect(second.status == 403)
                try await RulesComposeBarriers.expectIdle(fx)
            }
        }
    }

    @Test func http2CloseResetsOnlyThatStream() async throws {
        try await expectH2Reset(.graceful, code: .noError)
        try await expectH2Reset(.reset, code: .internalError)
    }

    private func expectH2Reset(_ mode: RulesEngine.CloseMode, code: HTTP2ErrorCode) async throws {
        let close = judged("close", [RuleAction(.closeConnection(mode))])
        try await HTTP2TestOrigin.withOrigin(protocols: ["h2"]) { origin in
            try await HTTP2ProxyFixture.withProxy(origin: origin, downstreamH2: true, rules: TestRules.provider([close])) { fx, client in
                let probe = try await ResetProbe.install(on: client.channel)
                await #expect(throws: (any Error).self) { try await client.rawRequest(headers: h2Headers(origin, path: "/close")) }
                let resets = try await probe.resets()
                #expect(Array(resets.values) == [code], "\(resets)")
                #expect(try await probe.heads().isEmpty)
                let flow = try await waitForFlow(fx.store) { $0.path == "/close" && $0.completedAt != nil }
                #expect(flow.state == .failed(HTTPLocalFailureText.ruleClosed(ruleName: "close")))
                // The connection stays: a request no rule matches (not 200) would pass, so only check it is still open.
                #expect(client.channel.isActive)
                try await RulesComposeBarriers.expectIdle(fx)
            }
        }
    }

    @Test func http2DelayHoldsTheResponseHead() async throws {
        let probe = ResponseDelayProbe()
        let delay = judged("delay", [RuleAction(.delay(milliseconds: 300))])
        try await HTTP2TestOrigin.withOrigin(protocols: ["h2"]) { origin in
            try await HTTP2ProxyFixture.withProxy(
                origin: origin, downstreamH2: true, rules: TestRules.provider([delay]), ruleDelayHook: probe.hook
            ) { fx, client in
                let pending = try await client.startRawRequest(headers: h2Headers(origin, method: "POST", path: "/held"))
                try await pending.body("x", endStream: true)
                try await waitUntil("the delay to be requested") { probe.delays.count == 1 }
                #expect(probe.delays == [.milliseconds(300)])
                probe.fireDirectly()
                let reply = try await pending.response.get()
                #expect(reply.status == 200)
            }
        }
    }

    @Test func http2DelayedResponseWithABodyOverThePendingCapIsDelivered() async throws {
        let probe = ResponseDelayProbe()
        let delay = judged("delay", [RuleAction(.delay(milliseconds: 100))])
        var response = HTTP2TestOrigin.Response()
        response.rawBody = [UInt8](repeating: 0x61, count: 200 * 1024)
        response.trailers = nil
        try await HTTP2TestOrigin.withOrigin(protocols: ["h2"], response: response) { origin in
            try await HTTP2ProxyFixture.withProxy(
                origin: origin, downstreamH2: true, rules: TestRules.provider([delay]), ruleDelayHook: probe.hook
            ) { fx, client in
                let pending = try await client.startRawRequest(headers: h2Headers(origin, method: "POST", path: "/held"))
                try await pending.body("x", endStream: true)
                try await waitUntil("the delay to be requested") { probe.delays.count == 1 }
                probe.fireDirectly()
                let reply = try await pending.response.get()
                #expect(reply.status == 200)
                #expect(reply.body.utf8.count == 200 * 1024)
            }
        }
    }

    // MARK: Decrypted HTTPS (HTTP/1.1 inside the tunnel)

    @Test func interceptedHTTPSReturnReplacesTheOriginsResponse() async throws {
        try await HTTP2TestOrigin.withOrigin(protocols: ["http/1.1"]) { origin in
            let answer = judged("answer", [preset(.forbidden403, body: "nope")])
            let fixture = try await HTTP2ProxyFixture.start(origin: origin, rules: TestRules.provider([answer]))
            do {
                let client = try await RawClient.connect(port: try #require(fixture.channel.localAddress?.port))
                do {
                    try await client.send("CONNECT localhost:\(origin.port) HTTP/1.1\r\nHost: localhost:\(origin.port)\r\n\r\n")
                    #expect(try await client.receive(until: "\r\n\r\n").hasPrefix("HTTP/1.1 200 "))
                    try await client.startTLS(trustRoots: .certificates([
                        NIOSSLCertificate(bytes: fixture.ca.rootCertificateDER, format: .der)
                    ]), serverName: "localhost")
                    try await client.send("GET /secret HTTP/1.1\r\nHost: localhost:\(origin.port)\r\n\r\n")
                    let reply = try await client.receive(until: "nope")
                    #expect(reply.hasPrefix("HTTP/1.1 403 Forbidden\r\n"))
                    try await client.close()
                } catch { try? await client.close(); throw error }
                try await fixture.stop()
            } catch { try? await fixture.stop(); throw error }
        }
    }
}

// MARK: helpers

/// A rule judged at the response: the origin answered 200.
private func judged(_ name: String, _ actions: [RuleAction]) -> Rule {
    Rule(name: name, conditions: ConditionGroup(rows: [ConditionRow(field: .statusCode, op: .equals, value: "200")]), actions: actions)
}

private func preset(_ preset: PresetResponse.Preset, body: String? = nil) -> RuleAction {
    RuleAction(.returnPreset(PresetResponse(preset: preset, body: body)))
}

private func get(_ fx: ProxyFixture, _ path: String) -> String {
    let host = "127.0.0.1:\(fx.origin.port)"
    return "GET http://\(host)\(path) HTTP/1.1\r\nHost: \(host)\r\n\r\n"
}

private func h2Headers(_ origin: HTTP2TestOrigin, method: String = "GET", path: String) -> HPACKHeaders {
    HPACKHeaders([(":method", method), (":scheme", "https"), (":authority", "localhost:\(origin.port)"), (":path", path)])
}

/// Takes the rule delay timer over: the test fires it by hand, nothing sleeps.
private final class ResponseDelayProbe: Sendable {
    private let state = NIOLockedValueBox<(delays: [TimeAmount], callbacks: [@Sendable () -> Void])>(([], []))
    var delays: [TimeAmount] { state.withLockedValue { $0.delays } }
    var hook: RuleDelayHook {
        { [self] delay, callback in
            state.withLockedValue { $0.delays.append(delay); $0.callbacks.append(callback) }
            return true
        }
    }
    func fireDirectly() { state.withLockedValue { $0.callbacks }.forEach { $0() } }
}
