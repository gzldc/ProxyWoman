import FlowStore
import Foundation
import NIOCore
import NIOEmbedded
import NIOHTTP1
import Testing
@testable import ProxyCore
import RulesEngine

/// Spec R8F2-6: a request-side action of a rule judged at the response edits the recorded request (what the
/// session list shows) and never the request already written upstream.
@Suite(.serialized, .timeLimit(.minutes(2)), .productionChinese) struct RuleRecordedRequestIntegrationTests {
    private static let ok = ConditionRow(field: .statusCode, op: .inRange, value: "200-299")

    private static func rule(_ actions: ActionKind...) -> Rule {
        Rule(name: "copy", conditions: ConditionGroup(rows: [ok]), actions: actions.map { RuleAction($0) })
    }

    private struct Result {
        var sent: String
        var flow: Flow
    }

    /// One exchange through `rules`; the origin answers 200.
    private func exchange(_ path: String, rules: [Rule]) async throws -> Result {
        var result: Result?
        try await withConnectionFixture { fixture in
            var headers = HTTPHeaders()
            headers.add(name: "Accept", value: "*/*")
            let writer = RecordingResponseWriter(channel: fixture.client)
            let exchange = fixture.admit(
                path, headers: headers, writer: writer, context: fixture.context(rules: TestRules.provider(rules)))
            exchange.receiveRequest(.end(nil))
            exchange.execute()
            let upstream = try fixture.connect(0)
            let sent = try fixture.written(upstream)
            try upstream.writeInbound(ByteBuffer(string: "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"))
            fixture.loop.run()
            #expect(writer.heads.map(\.status.code) == [200])
            // The recorded path may have been edited; the flow is the only one.
            let flow = try #require(fixture.store.allFlows().first)
            result = Result(sent: sent, flow: flow)
        }
        return try #require(result)
    }

    @Test func requestHeaderEditChangesOnlyTheRecordedRequest() async throws {
        let rule = Self.rule(.editHeaders(direction: .request, operations: [.set(name: "X-Copy", value: "1")]))
        let plain = try await exchange("/copy", rules: [])
        let edited = try await exchange("/copy", rules: [rule])
        // The bytes on the wire are those of an exchange without the rule.
        #expect(edited.sent == plain.sent)
        #expect(!edited.sent.contains("X-Copy"))
        // The record shows the edit; both wire boundaries keep what really crossed them.
        #expect(edited.flow.requestHeaders.contains(HeaderField(name: "X-Copy", value: "1")))
        #expect(edited.flow.messages[.downstreamRequest]?.headers.contains { $0.name == "X-Copy" } == false)
        #expect(edited.flow.messages[.upstreamRequest]?.headers.contains { $0.name == "X-Copy" } == false)
        #expect(edited.flow.state == .completed)
        #expect(edited.flow.statusCode == 200)
        #expect(edited.flow.provenance.ruleMatches?.outcomes == [RuleOutcome(ruleID: rule.id, code: .requestActionVisibleOnly)])
        #expect(edited.flow.provenance.rulesModified == false)
        // Without the rule the record is as it always was.
        #expect(!plain.flow.requestHeaders.contains { $0.name == "X-Copy" })
        #expect(plain.flow.provenance.ruleMatches == nil)
    }

    @Test func urlEditMovesTheRecordedRequestButNotTheWireOne() async throws {
        let rule = Self.rule(.modifyQuery(QueryEditAction(operations: [.set(name: "seen", value: "1")])))
        let plain = try await exchange("/q?a=1", rules: [])
        let edited = try await exchange("/q?a=1", rules: [rule])
        #expect(edited.sent == plain.sent)
        #expect(edited.sent.hasPrefix("GET /q?a=1 HTTP/1.1\r\n"))
        #expect(edited.flow.path == "/q?a=1&seen=1")
        #expect(edited.flow.messages[.downstreamRequest]?.target?.pathAndQuery == "/q?a=1")
        #expect(edited.flow.messages[.upstreamRequest]?.target?.pathAndQuery == "/q?a=1")
    }

    @Test(arguments: [
        ActionKind.breakpoint(direction: .request, mode: .headers),
        .mapRemote(MapRemoteAction(targetScheme: "https", targetHost: "b.test", targetPort: 443, path: .preserve)),
        .rewriteBody(direction: .request, BodyRewriteAction(find: "a", replacement: "b")),
    ])
    func skippedKindsRecordTheSkipAndLeaveEverythingElse(kind: ActionKind) async throws {
        let rule = Self.rule(kind)
        let plain = try await exchange("/skip", rules: [])
        let skipped = try await exchange("/skip", rules: [rule])
        #expect(skipped.sent == plain.sent)
        #expect(skipped.flow.requestHeaders == plain.flow.requestHeaders)
        #expect(skipped.flow.path == "/skip")
        #expect(skipped.flow.provenance.ruleMatches?.outcomes == [RuleOutcome(ruleID: rule.id, code: .requestActionSkippedAtResponse)])
        #expect(skipped.flow.state == .completed)
        #expect(skipped.flow.statusCode == 200)
    }

    @Test func responseSideActionsOfTheSameRuleStillRun() async throws {
        let rule = Self.rule(
            .editHeaders(direction: .request, operations: [.set(name: "X-Copy", value: "1")]),
            .editHeaders(direction: .response, operations: [.set(name: "X-Seen", value: "1")]))
        let edited = try await exchange("/both", rules: [rule])
        #expect(edited.flow.requestHeaders.contains(HeaderField(name: "X-Copy", value: "1")))
        #expect(edited.flow.messages[.downstreamResponse]?.headers.contains(HeaderField(name: "X-Seen", value: "1")) == true)
        #expect(
            edited.flow.provenance.ruleMatches?.outcomes == [
                RuleOutcome(ruleID: rule.id, code: .requestActionVisibleOnly, actionIndex: 0),
                RuleOutcome(ruleID: rule.id, code: .applied, actionIndex: 1),
            ])
        #expect(edited.flow.provenance.rulesModified)
    }
}
