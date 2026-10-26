import FlowStore
import Foundation
import Testing
@testable import ProxyCore
import RulesEngine

/// Rules 2.0 phase R4, end to end over real sockets: the URL, query and cookie actions change what the origin
/// and the client actually receive. Editing the URL rides the Map Remote route, so the credential and
/// self-target rules of Map Remote apply to it (D3).
@Suite(.productionChinese, .serialized, .timeLimit(.minutes(3))) struct RuleURLQueryCookieIntegrationTests {
    private static func rule(_ name: String, _ conditions: ConditionGroup, _ kind: ActionKind) -> Rule {
        Rule(name: name, conditions: conditions, actions: [RuleAction(kind)])
    }

    private static func rule(_ name: String, _ kind: ActionKind) -> Rule { rule(name, ConditionGroup(), kind) }

    private static func onPort(_ port: Int) -> ConditionGroup {
        ConditionGroup(rows: [ConditionRow(field: .port, op: .equals, value: String(port))])
    }

    /// The client's request in absolute form to `target`, with the extra header lines, and the whole answer.
    private static func fetch(_ fx: ProxyFixture, target: String, authority: String, headers: String = "") async throws -> String {
        let client = try await RawClient.connect(port: fx.proxyPort)
        do {
            try await client.send("GET http://\(authority)\(target) HTTP/1.1\r\nHost: \(authority)\r\n\(headers)Connection: close\r\n\r\n")
            try await client.waitUntilClosed()
            let text = String(decoding: client.remainingBytes(), as: UTF8.self)
            try await client.close()
            return text
        } catch { try? await client.close(); throw error }
    }

    @Test func urlEditChangesTheUpstreamTarget() async throws {
        let a = try await HTTP2TestOrigin.start(protocols: [], plaintext: true)
        let b = try await HTTP2TestOrigin.start(protocols: [], plaintext: true)
        do {
            let edit = URLEditAction(mode: .set, replacement: "http://127.0.0.1:\(b.port)/new/path?y=2&z=%2F")
            let rules = TestRules.provider([Self.rule("url", Self.onPort(a.port), .modifyURL(edit))])
            try await ProxyFixture.run(rules: rules) { fx in
                let text = try await Self.fetch(fx, target: "/old?x=1", authority: "127.0.0.1:\(a.port)")
                #expect(text.hasPrefix("HTTP/1.1 200 OK\r\n"), "\(text)")
                #expect(text.contains("fixture-body"))
                #expect(a.counts.requests == 0)
                #expect(b.counts.paths == ["/new/path?y=2&z=%2F"])
                #expect(b.counts.requestHeaders.first?["host"] == ["127.0.0.1:\(b.port)"])
                let flow = try await waitForFlow(fx.store) { $0.state == .completed }
                #expect(flow.path == "/old?x=1")
                #expect(flow.messages[.upstreamRequest]?.target?.port == b.port)
                #expect(flow.provenance.ruleMatches?.outcomes.map(\.code) == [.applied])
            }
            try await a.stop(); try await b.stop()
        } catch { try? await a.stop(); try? await b.stop(); throw error }
    }

    @Test(arguments: [false, true])
    func urlEditToOtherOriginDropsCookieAndAuthorizationUnlessPreserved(preserve: Bool) async throws {
        let a = try await HTTP2TestOrigin.start(protocols: [], plaintext: true)
        let b = try await HTTP2TestOrigin.start(protocols: [], plaintext: true)
        do {
            let edit = URLEditAction(
                mode: .set, replacement: "http://127.0.0.1:\(b.port)/other", preserveCredentials: preserve)
            let rules = TestRules.provider([Self.rule("url", Self.onPort(a.port), .modifyURL(edit))])
            try await ProxyFixture.run(rules: rules) { fx in
                _ = try await Self.fetch(fx, target: "/p", authority: "127.0.0.1:\(a.port)", headers:
                    "Authorization: Basic a\r\nCookie: s=1\r\nProxy-Authorization: Basic p\r\nX-Keep: 1\r\n")
                let seen = try #require(b.counts.requestHeaders.first)
                #expect(seen["x-keep"] == ["1"])
                #expect(seen["proxy-authorization"].isEmpty)
                #expect(seen["authorization"].isEmpty != preserve)
                #expect(seen["cookie"].isEmpty != preserve)
            }
            try await a.stop(); try await b.stop()
        } catch { try? await a.stop(); try? await b.stop(); throw error }
    }

    @Test func urlEditWithinTheSameOriginKeepsCookieAndAuthorization() async throws {
        let a = try await HTTP2TestOrigin.start(protocols: [], plaintext: true)
        do {
            let edit = URLEditAction(mode: .findReplace, find: "/old", replacement: "/new")
            let rules = TestRules.provider([Self.rule("url", Self.onPort(a.port), .modifyURL(edit))])
            try await ProxyFixture.run(rules: rules) { fx in
                _ = try await Self.fetch(fx, target: "/old", authority: "127.0.0.1:\(a.port)", headers:
                    "Authorization: Basic a\r\nCookie: s=1\r\n")
                #expect(a.counts.paths == ["/new"])
                let seen = try #require(a.counts.requestHeaders.first)
                #expect(seen["authorization"] == ["Basic a"])
                #expect(seen["cookie"] == ["s=1"])
            }
            try await a.stop()
        } catch { try? await a.stop(); throw error }
    }

    @Test func urlEditToOwnListenerFailsWithRuleSelfTarget() async throws {
        let rules = TestRules.provider([])
        try await ProxyFixture.run(rules: rules) { fx in
            let edit = URLEditAction(mode: .set, replacement: "http://127.0.0.1:\(fx.proxyPort)/loop")
            TestRules.publish([Self.rule("url", Self.onPort(fx.origin.port), .modifyURL(edit))], revision: 2, to: rules)
            let text = try await Self.fetch(fx, target: "/hello", authority: "127.0.0.1:\(fx.origin.port)")
            #expect(text.hasPrefix("HTTP/1.1 502 Bad Gateway\r\n"), "\(text)")
            #expect(text.contains("指向本代理"), "\(text)")
            let flow = try await waitForFlow(fx.store) {
                if case .failed = $0.state { return true }; return false
            }
            #expect(flow.path == "/hello")
            // No recursive exchange reached the listener, and the origin never saw the request.
            #expect(fx.store.allFlows().count == 1)
            #expect(fx.origin.receivedRequestCount == 0)
        }
    }

    @Test func queryEditSendsOnlyTheNewQuery() async throws {
        let a = try await HTTP2TestOrigin.start(protocols: [], plaintext: true)
        do {
            let edit = QueryEditAction(operations: [
                .set(name: "a", value: "9"), .remove(name: "debug"), .add(name: "c", value: "3"),
            ])
            let rules = TestRules.provider([Self.rule("query", Self.onPort(a.port), .modifyQuery(edit))])
            try await ProxyFixture.run(rules: rules) { fx in
                let text = try await Self.fetch(fx, target: "/q?a=1&b=2&debug=1", authority: "127.0.0.1:\(a.port)")
                #expect(text.hasPrefix("HTTP/1.1 200 OK\r\n"), "\(text)")
                #expect(a.counts.paths == ["/q?a=9&b=2&c=3"])
                let flow = try await waitForFlow(fx.store) { $0.state == .completed }
                #expect(flow.provenance.ruleMatches?.outcomes.map(\.code) == [.applied])
            }
            try await a.stop()
        } catch { try? await a.stop(); throw error }
    }

    @Test func requestCookieEditReachesOrigin() async throws {
        let a = try await HTTP2TestOrigin.start(protocols: [], plaintext: true)
        do {
            let edit: [CookieEdit] = [.set(name: "session", value: "r4"), .remove(name: "tracking")]
            let rules = TestRules.provider([Self.rule("cookie", Self.onPort(a.port), .editCookies(direction: .request, operations: edit))])
            try await ProxyFixture.run(rules: rules) { fx in
                _ = try await Self.fetch(fx, target: "/c", authority: "127.0.0.1:\(a.port)", headers: "Cookie: keep=1; tracking=x\r\n")
                #expect(a.counts.requestHeaders.first?["cookie"] == ["keep=1; session=r4"])
            }
            try await a.stop()
        } catch { try? await a.stop(); throw error }
    }

    @Test func responseCookieEditReachesClient() async throws {
        // The origin sets `a=1` and `b=2` (the fixture's default response).
        let a = try await HTTP2TestOrigin.start(protocols: [], plaintext: true)
        do {
            let edit: [CookieEdit] = [.set(name: "a", value: "9"), .remove(name: "b"), .set(name: "n", value: "1")]
            let rules = TestRules.provider([Self.rule("cookie", Self.onPort(a.port), .editCookies(direction: .response, operations: edit))])
            try await ProxyFixture.run(rules: rules) { fx in
                let text = try await Self.fetch(fx, target: "/c", authority: "127.0.0.1:\(a.port)")
                let head = String(text.components(separatedBy: "\r\n\r\n")[0])
                let cookies = head.components(separatedBy: "\r\n").filter { $0.lowercased().hasPrefix("set-cookie:") }
                    .map { $0.drop { $0 != ":" }.dropFirst().trimmingCharacters(in: .whitespaces) }
                #expect(cookies == ["a=9", "n=1"], "\(head)")
            }
            try await a.stop()
        } catch { try? await a.stop(); throw error }
    }

    @Test func websocketHandshakeKeepsCookieEditButSkipsURLEdit() async throws {
        let directory = WebSocketIntegrationTests.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let origin = try await WebSocketOrigin.start(tls: false, script: [.closeTransport], directory: directory)
        do {
            let rules = TestRules.provider([
                Self.rule("url", .modifyURL(URLEditAction(mode: .set, replacement: "http://127.0.0.1:1/elsewhere"))),
                Self.rule("cookie", .editCookies(direction: .request, operations: [.set(name: "session", value: "r4")])),
            ])
            try await RulesComposeServer.run(rules: rules) { fx in
                let client = try await RawClient.connect(port: try fx.port)
                do {
                    let key = WSWire.randomKey()
                    try await client.send(
                        "GET http://localhost:\(origin.port)/chat HTTP/1.1\r\nHost: localhost:\(origin.port)\r\nUpgrade: websocket\r\n"
                        + "Connection: Upgrade\r\nSec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\nCookie: keep=1\r\n\r\n")
                    let head = try await client.receive(until: "\r\n\r\n")
                    #expect(head.hasPrefix("HTTP/1.1 101 "), "\(head)")
                    try await client.waitUntilClosed()
                    try await origin.waitUntilFinished()
                    // The handshake reached the origin at its own address, with the edited cookie.
                    let sent = origin.transcript.requestHead
                    #expect(sent.hasPrefix("GET /chat HTTP/1.1\r\n"), "\(sent)")
                    #expect(sent.contains("Cookie: keep=1; session=r4\r\n"), "\(sent)")
                    let flow = try await waitForFlow(fx.store) { $0.statusCode == 101 }
                    #expect(flow.provenance.ruleMatches?.outcomes.map(\.code) == [.unsupportedUpgradeAction, .applied])
                    try await client.close()
                } catch { try? await client.close(); throw error }
            }
            try await origin.stop()
        } catch { try? await origin.stop(); throw error }
    }
}
