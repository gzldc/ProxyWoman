import FlowStore
import Foundation
import os
import RulesEngine
import Testing
@testable import ProxyCore

@Suite("ExchangeRuleSessionRewrite", .productionChinese) struct ExchangeRuleSessionRewriteTests {
    private static let target = HTTPMessageTarget(scheme: "http", host: "example.test", port: 80, method: "GET", pathAndQuery: "/")

    private func bodyRule(_ direction: HTTPMessageDirection) -> Rule {
        Rule(id: UUID(), name: "b", enabled: true, order: 0, matcher: RuleMatcher(),
             action: .rewriteBody(direction: direction, BodyRewriteAction(find: "a", replacement: "b")))
    }

    private func response(_ status: Int = 200) -> HTTPMessageHead {
        .response(status: status, reason: nil, headers: [HeaderField(name: "Content-Type", value: "text/plain")])
    }

    private func session(_ rules: [Rule], target: HTTPMessageTarget = Self.target) -> ExchangeRuleSession {
        ExchangeRuleSession(snapshot: RuleSnapshot(revision: 3, rules: rules), hits: nil,
                            originalRequest: .request(target, headers: [HeaderField(name: "Content-Type", value: "text/plain")]),
                            provenance: .init())
    }

    @Test func sessionRecordsBodyRewriteOutcomesReplacingApplied() throws {
        let requestRule = bodyRule(.request)
        let responseRule = bodyRule(.response)
        let session = session([requestRule, responseRule])
        let request = try session.prepareRequest()
        #expect(request.bodyRewrites.map(\.ruleID) == [requestRule.id])
        let decision = try session.prepareResponse(response())
        #expect(decision.bodyRewrites.map(\.ruleID) == [responseRule.id])
        #expect(session.provenance.ruleMatches?.outcomes.map(\.code) == [.applied, .applied])

        session.recordBodyRewriteOutcomes([RuleOutcome(ruleID: responseRule.id, code: .bodyNoMatch)], direction: .response)
        #expect(session.provenance.ruleMatches?.outcomes == [
            RuleOutcome(ruleID: requestRule.id, code: .applied), RuleOutcome(ruleID: responseRule.id, code: .bodyNoMatch)])
        #expect(session.provenance.ruleMatches?.ruleIDs == [requestRule.id, responseRule.id])
        #expect(session.provenance.ruleMatches?.total == 2)

        // A rule of the other direction, or an unknown rule, is not touched by this direction's record.
        session.recordBodyRewriteOutcomes([RuleOutcome(ruleID: requestRule.id, code: .bodySkippedTooLarge),
                                           RuleOutcome(ruleID: UUID(), code: .bodySkippedTooLarge)], direction: .response)
        #expect(session.provenance.ruleMatches?.outcomes.map(\.code) == [.applied, .bodyNoMatch])
        session.recordBodyRewriteOutcomes([RuleOutcome(ruleID: requestRule.id, code: .bodySkippedUndecodable)], direction: .request)
        #expect(session.provenance.ruleMatches?.outcomes.map(\.code) == [.bodySkippedUndecodable, .bodyNoMatch])
    }

    @Test func sessionRecordingIsPerRuleAndOnce() throws {
        let rule = bodyRule(.response)
        let session = session([rule])
        _ = try session.prepareRequest()
        _ = try session.prepareResponse(response())
        session.recordBodyRewriteOutcomes([RuleOutcome(ruleID: rule.id, code: .bodyNoMatch)], direction: .response)
        session.recordBodyRewriteOutcomes([RuleOutcome(ruleID: rule.id, code: .applied)], direction: .response)
        session.recordBodyRewriteOutcomes([RuleOutcome(ruleID: rule.id, code: .bodyNoMatch)], direction: .response)
        #expect(session.provenance.ruleMatches?.outcomes == [RuleOutcome(ruleID: rule.id, code: .bodyNoMatch)])
    }

    @Test func sessionPassesLocalFlagAndStatusRewriteThrough() throws {
        let rule = Rule(id: UUID(), name: "s", enabled: true, order: 0, matcher: RuleMatcher(),
                        action: .rewriteStatus(RewriteStatusAction(status: 404)))
        let origin = session([rule])
        _ = try origin.prepareRequest()
        #expect(try origin.prepareResponse(response()).statusRewrite == 404)
        let local = session([rule])
        _ = try local.prepareRequest()
        let decision = try local.prepareResponse(response(), isLocalResponse: true)
        #expect(decision.statusRewrite == nil)
        #expect(local.provenance.ruleMatches?.outcomes == [RuleOutcome(ruleID: rule.id, code: .statusSkippedLocal)])
    }

    // MARK: per-action records (rules 2.0)

    private func ruleWith(_ actions: [RuleAction]) -> Rule {
        Rule(name: "n", actions: actions)
    }

    private func body(_ direction: HTTPMessageDirection, _ find: String = "a") -> RuleAction {
        RuleAction(.rewriteBody(direction: direction, BodyRewriteAction(find: find, replacement: "b")))
    }

    @Test func bodyOutcomesSettleEachActionOfAMultiActionRule() throws {
        let rule = ruleWith([body(.request), body(.response), body(.response, "c")])
        let session = session([rule])
        let request = try session.prepareRequest()
        #expect(request.bodyRewrites.map(\.actionIndex) == [0])
        let decision = try session.prepareResponse(response())
        #expect(decision.bodyRewrites.map(\.actionIndex) == [1, 2])
        #expect(session.provenance.ruleMatches?.ruleIDs == [rule.id])
        #expect(session.provenance.ruleMatches?.total == 1)

        // The second response action settles without touching the first one or the request one.
        session.recordBodyRewriteOutcomes([RuleOutcome(ruleID: rule.id, code: .bodyNoMatch, actionIndex: 2)], direction: .response)
        // The request action's key is not one the response handed out.
        session.recordBodyRewriteOutcomes([RuleOutcome(ruleID: rule.id, code: .bodyNoMatch, actionIndex: 0)], direction: .response)
        #expect(session.provenance.ruleMatches?.outcomes == [
            RuleOutcome(ruleID: rule.id, code: .applied, actionIndex: 0), RuleOutcome(ruleID: rule.id, code: .applied, actionIndex: 1),
            RuleOutcome(ruleID: rule.id, code: .bodyNoMatch, actionIndex: 2),
        ])
        #expect(!session.provenance.rulesModified)
        session.recordBodyRewriteOutcomes([RuleOutcome(ruleID: rule.id, code: .applied, actionIndex: 1)], direction: .response)
        #expect(session.provenance.rulesModified)
        session.recordBodyRewriteOutcomes([RuleOutcome(ruleID: rule.id, code: .bodySkippedTooLarge, actionIndex: 0)], direction: .request)
        #expect(session.provenance.ruleMatches?.outcomes.map(\.code) == [.bodySkippedTooLarge, .applied, .bodyNoMatch])
    }

    @Test func breakpointBodyOutcomesNameTheBreakpointAction() throws {
        let rule = ruleWith([
            RuleAction(.editHeaders(direction: .request, operations: [.set(name: "X-A", value: "1")])),
            RuleAction(.breakpoint(direction: .request, mode: .fullBody)),
        ])
        let session = session([rule])
        _ = try session.prepareRequest()
        session.recordBodyOutcomes([.breakpointLengthCorrected], direction: .request)
        #expect(session.provenance.ruleMatches?.outcomes == [
            RuleOutcome(ruleID: rule.id, code: .applied, actionIndex: 0), RuleOutcome(ruleID: rule.id, code: .applied, actionIndex: 1),
            RuleOutcome(ruleID: rule.id, code: .breakpointLengthCorrected, actionIndex: 1),
        ])
    }

    @Test func directoryFallbackKeepsTheComposedMapRemote() throws {
        let remote = MapRemoteAction(targetScheme: "http", targetHost: "mapped.test", targetPort: 81, path: .preserve,
                                     preserveCredentials: true)
        let directory = MapLocalDirectoryAction(bookmark: Data([1]), displayName: "www", missing: .network)
        let map = ruleWith([RuleAction(.mapRemote(remote))])
        let local = Rule(name: "dir", conditions: ConditionGroup(rows: [ConditionRow(field: .host, op: .hostPattern, value: "mapped.test")]),
                             actions: [RuleAction(.returnDirectory(directory, pathPrefix: "/"))])
        let mapped = session([map, local])
        let decision = try mapped.prepareRequest()
        guard case .localDirectory = try mapped.continuation(for: decision) else {
            Issue.record("expected the directory route"); return
        }
        #expect(mapped.directoryRuleID == local.id)
        guard case .network(.request(let target, _), _) = try mapped.networkFallback() else {
            Issue.record("expected a network fallback"); return
        }
        #expect(target == HTTPMessageTarget(scheme: "http", host: "mapped.test", port: 81, method: "GET", pathAndQuery: "/"))

        // Without a Map Remote the fallback is the original target.
        let alone = session([local], target: HTTPMessageTarget(scheme: "http", host: "mapped.test", port: 80, method: "GET", pathAndQuery: "/x"))
        _ = try alone.prepareRequest()
        guard case .network(.request(let original, _), _) = try alone.networkFallback() else {
            Issue.record("expected a network fallback"); return
        }
        #expect(original == HTTPMessageTarget(scheme: "http", host: "mapped.test", port: 80, method: "GET", pathAndQuery: "/x"))
    }

    // MARK: R3 facts (T9)

    private func regexRule(_ row: ConditionRow) -> Rule {
        Rule(name: "regex", conditions: ConditionGroup(rows: [row]),
             actions: [RuleAction(.mark(MarkAction(background: "#FF0000")))])
    }

    /// A clock that advances 1 ms per reading, so every regular-expression row costs the allowance 1 ms.
    private static func steppingAllowance() -> RegexAllowance {
        let ticks = OSAllocatedUnfairLock(initialState: 0)
        return RegexAllowance(total: .milliseconds(8), clock: { .milliseconds(ticks.withLock { $0 += 1; return $0 }) })
    }

    @Test func sessionPassesTheSameAllowanceToBothPoints() throws {
        let allowance = Self.steppingAllowance()
        let rules = [
            regexRule(ConditionRow(field: .requestHeader, name: "Content-Type", op: .regex, value: "^text/.*$")),
            regexRule(ConditionRow(field: .responseHeader, name: "Content-Type", op: .regex, value: "^text/.*$")),
        ]
        let session = ExchangeRuleSession(
            snapshot: RuleSnapshot(revision: 3, rules: rules), hits: nil,
            originalRequest: .request(Self.target, headers: [HeaderField(name: "Content-Type", value: "text/plain")]),
            provenance: .init(), factsSource: .init(), allowance: allowance)
        #expect(session.allowance === allowance)
        let full = allowance.remaining
        _ = try session.prepareRequest()
        let afterRequest = allowance.remaining
        #expect(afterRequest < full)
        _ = try session.prepareResponse(response())
        #expect(allowance.remaining < afterRequest)
    }

    @Test func eachSessionHasItsOwnAllowance() {
        let first = session([]), second = session([])
        #expect(first.allowance !== second.allowance)
    }

    @Test func factsComeFromTheSourceAndTheProvenanceAtCallTime() throws {
        let app = ClientApp(pid: 9, name: "Fixture", executablePath: "/x/Fixture")
        let started = Date(timeIntervalSince1970: 1_000)
        let source = ExchangeRuleSession.FactsSource(
            clientIP: { "10.0.0.1" }, remoteIP: { "10.0.0.2" }, clientHTTPVersion: { .http2 }, upstreamHTTPVersion: { .http1_1 },
            clientTLSVersion: { "TLS 1.3" }, upstreamTLSVersion: { "TLS 1.2" }, certificate: { nil },
            app: { .known(app) }, comment: { "user" }, requestStartedAt: started)
        let edit = Rule(name: "edit", conditions: ConditionGroup(),
                        actions: [RuleAction(.editHeaders(direction: .request, operations: [.set(name: "X-A", value: "1")]))])
        // The comment and the app are only read when a row needs them.
        let reader = Rule(name: "reader", conditions: ConditionGroup(rows: [
            ConditionRow(field: .comment, op: .contains, value: "x"),
            ConditionRow(field: .clientApp, name: "name", op: .equals, value: "Fixture")]),
            actions: [RuleAction(.mark(MarkAction(background: "#00FF00")))])
        let session = ExchangeRuleSession(
            snapshot: RuleSnapshot(revision: 3, rules: [edit, reader]), hits: nil,
            originalRequest: .request(Self.target, headers: []), provenance: .init(), factsSource: source)
        let before = session.facts()
        #expect(before.clientIP == "10.0.0.1" && before.remoteIP == "10.0.0.2")
        #expect(before.clientHTTPVersion == .http2 && before.upstreamHTTPVersion == .http1_1)
        #expect(before.clientTLSVersion == "TLS 1.3" && before.upstreamTLSVersion == "TLS 1.2")
        #expect(before.app == .known(app))
        #expect(before.requestStartedAt == started)
        #expect(before.comment == "user")
        #expect(!before.rulesModified)
        _ = try session.prepareRequest()
        #expect(session.facts().rulesModified)
    }

    @Test func responsePointFactsCarryTheRequestPointCommentActions() throws {
        let comment = Rule(name: "comment", conditions: ConditionGroup(),
                           actions: [RuleAction(.comment(CommentAction(mode: .append, text: "from-p1")))])
        let reader = Rule(
            name: "reader",
            conditions: ConditionGroup(rows: [
                ConditionRow(field: .statusCode, op: .equals, value: "200"),
                ConditionRow(field: .comment, op: .equals, value: "user from-p1"),
            ]),
            actions: [RuleAction(.mark(MarkAction(background: "#00FF00")))])
        let source = ExchangeRuleSession.FactsSource(comment: { "user" })
        let session = ExchangeRuleSession(
            snapshot: RuleSnapshot(revision: 3, rules: [comment, reader]), hits: nil,
            originalRequest: .request(Self.target, headers: []), provenance: .init(), factsSource: source)
        _ = try session.prepareRequest()
        #expect(session.facts().comment == "user from-p1")
        let decision = try session.prepareResponse(response())
        #expect(decision.matches.ruleIDs.contains(reader.id))
    }
}
