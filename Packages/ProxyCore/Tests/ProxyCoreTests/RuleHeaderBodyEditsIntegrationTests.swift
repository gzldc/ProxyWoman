import FlowStore
import Foundation
import Testing
@testable import ProxyCore
import RulesEngine

/// Rules 2.0 phase R5, end to end over real sockets: the new header edit methods change what the
/// origin and the client actually receive.
@Suite(.serialized, .timeLimit(.minutes(3)), .productionChinese) struct RuleHeaderBodyEditsIntegrationTests {
    private static func rule(_ name: String, _ port: Int, _ kind: ActionKind) -> Rule {
        Rule(
            name: name, conditions: ConditionGroup(rows: [ConditionRow(field: .port, op: .equals, value: String(port))]),
            actions: [RuleAction(kind)])
    }

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

    @Test func headerFindReplaceReachesTheOrigin() async throws {
        let a = try await HTTP2TestOrigin.start(protocols: [], plaintext: true)
        do {
            let edits: [HeaderEdit] = [
                .findReplace(name: "X-Token", find: "SECRET", replacement: "masked", caseSensitive: false),
                .addIfMissing(name: "X-Added", value: "1"),
                .appendToValue(name: "X-Tail", text: "-end"),
            ]
            let rules = TestRules.provider([Self.rule("header", a.port, .editHeaders(direction: .request, operations: edits))])
            try await ProxyFixture.run(rules: rules) { fx in
                _ = try await Self.fetch(
                    fx, target: "/h", authority: "127.0.0.1:\(a.port)", headers: "X-Token: a-secret-b\r\nX-Tail: t\r\n")
                let seen = try #require(a.counts.requestHeaders.first)
                #expect(seen["x-token"] == ["a-masked-b"])
                #expect(seen["x-added"] == ["1"])
                #expect(seen["x-tail"] == ["t-end"])
                let flow = try await waitForFlow(fx.store) { $0.state == .completed }
                #expect(flow.provenance.ruleMatches?.outcomes.map(\.code) == [.applied])
            }
            try await a.stop()
        } catch { try? await a.stop(); throw error }
    }

    @Test func responseAppendToValueReachesTheClient() async throws {
        // The origin sets `a=1` and `b=2` (the fixture's default response).
        let a = try await HTTP2TestOrigin.start(protocols: [], plaintext: true)
        do {
            let edit = HeaderEdit.appendToValue(name: "Set-Cookie", text: "; Path=/x")
            let rules = TestRules.provider([Self.rule("append", a.port, .editHeaders(direction: .response, operations: [edit]))])
            try await ProxyFixture.run(rules: rules) { fx in
                let text = try await Self.fetch(fx, target: "/c", authority: "127.0.0.1:\(a.port)")
                let head = String(text.components(separatedBy: "\r\n\r\n")[0])
                let cookies = head.components(separatedBy: "\r\n").filter { $0.lowercased().hasPrefix("set-cookie:") }
                    .map { $0.drop { $0 != ":" }.dropFirst().trimmingCharacters(in: .whitespaces) }
                #expect(cookies == ["a=1; Path=/x", "b=2; Path=/x"], "\(head)")
            }
            try await a.stop()
        } catch { try? await a.stop(); throw error }
    }

    @Test func noMatchIsRecordedAndTrafficIsUntouched() async throws {
        let a = try await HTTP2TestOrigin.start(protocols: [], plaintext: true)
        do {
            let edit = HeaderEdit.regex(name: "X-Missing", pattern: "a", replacement: "b", caseSensitive: true)
            let rules = TestRules.provider([Self.rule("none", a.port, .editHeaders(direction: .request, operations: [edit]))])
            try await ProxyFixture.run(rules: rules) { fx in
                _ = try await Self.fetch(fx, target: "/n", authority: "127.0.0.1:\(a.port)", headers: "X-Keep: 1\r\n")
                #expect(a.counts.requestHeaders.first?["x-keep"] == ["1"])
                let flow = try await waitForFlow(fx.store) { $0.state == .completed }
                #expect(flow.provenance.ruleMatches?.outcomes.map(\.code) == [.editNoMatch])
            }
            try await a.stop()
        } catch { try? await a.stop(); throw error }
    }

    // MARK: body set-value and clear

    private static func bodyRule(_ name: String, _ port: Int, _ direction: HTTPMessageDirection, _ operation: BodyRewriteOperation, _ text: String) -> Rule {
        rule(name, port, .rewriteBody(direction: direction, BodyRewriteAction(find: "", replacement: text, operation: operation)))
    }

    @Test func bodySetValueReplacesTheRequestBody() async throws {
        let limits = RulesLimits(minimumFreeDiskBytes: 0)
        let runtime = BreakpointBodyRuntime(budgets: OwnedFileBudgets(limits: limits), limits: limits)
        let set = Rule(
            name: "set", conditions: ConditionGroup(),
            actions: [RuleAction(.rewriteBody(direction: .request, BodyRewriteAction(find: "", replacement: "replaced body", operation: .setValue)))])
        try await ProxyFixture.run(rules: TestRules.provider([set]), bodyRuntime: runtime) { fx in
            let authority = "127.0.0.1:\(fx.origin.port)"
            let client = try await RawClient.connect(port: fx.proxyPort)
            try await client.send(
                "POST http://\(authority)/b HTTP/1.1\r\nHost: \(authority)\r\nContent-Type: text/plain\r\nContent-Length: 3\r\nConnection: close\r\n\r\nold")
            try await client.waitUntilClosed()
            try await client.close()
            let received = try #require(fx.origin.receivedRequests.last)
            #expect(received.body == Array("replaced body".utf8))
            #expect(received.head.headers.first(name: "content-length") == "13")
            let flow = try await waitForFlow(fx.store) { $0.state == .completed }
            #expect(try flow.messages[.downstreamRequest]?.body?.load() == Data("old".utf8))
            #expect(try flow.messages[.upstreamRequest]?.body?.load() == Data("replaced body".utf8))
            #expect(flow.provenance.ruleMatches?.outcomes.map(\.code) == [.applied])
        }
    }

    @Test func bodyClearEmptiesTheResponseBody() async throws {
        let limits = RulesLimits(minimumFreeDiskBytes: 0)
        let runtime = BreakpointBodyRuntime(budgets: OwnedFileBudgets(limits: limits), limits: limits)
        try await withScriptedOrigin { origin in
            origin.route("/c", [.send(Array("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 5\r\n\r\nhello".utf8))])
            let rules = TestRules.provider([Self.bodyRule("clear", origin.port, .response, .clear, "")])
            try await ProxyFixture.run(rules: rules, bodyRuntime: runtime) { fx in
                let text = try await Self.fetch(fx, target: "/c", authority: "127.0.0.1:\(origin.port)")
                let parts = text.components(separatedBy: "\r\n\r\n")
                #expect(parts.count == 2 && parts[1].isEmpty, "\(text)")
                #expect(parts[0].lowercased().contains("content-length: 0"), "\(text)")
                let flow = try await waitForFlow(fx.store) { $0.state == .completed }
                #expect(flow.provenance.ruleMatches?.outcomes.map(\.code) == [.applied])
            }
        }
    }
}
