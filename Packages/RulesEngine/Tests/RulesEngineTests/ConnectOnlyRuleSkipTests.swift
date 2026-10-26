import FlowStore
import Foundation
import Testing

@testable import RulesEngine

/// Rules 2.0 R4 fix wave I1: a rule whose actions are all connect-only is invisible to P1, P2 and P3.
struct ConnectOnlyRuleSkipTests {
    private static let head = HTTPMessageHead.request(
        HTTPMessageTarget(scheme: "https", host: "a.test", port: 443, method: "GET", pathAndQuery: "/"), headers: [])
    private static let ok = HTTPMessageHead.response(status: 200, reason: "OK", headers: [])
    private static let mark = RuleAction(.mark(MarkAction(background: "#FF3B30")))
    private static let clientAppRow = ConditionRow(field: .clientApp, name: "name", op: .equals, value: "Safari")
    private static let hostRow = ConditionRow(field: .host, op: .hostPattern, value: "a.test")

    private static func rule(
        _ rows: [ConditionRow] = [], occurrence: Occurrence = .any, _ actions: RuleAction...
    ) -> Rule {
        Rule(
            id: UUID(), name: "r", enabled: true, groupID: nil, order: 0,
            conditions: ConditionGroup(mode: .all, occurrence: occurrence, rows: rows), actions: actions)
    }

    private static func cache() -> PatternCache { PatternCache(budget: RegexBudget(clock: { .zero })) }

    @Test func connectOnlyRuleLeavesNoTraceAtP1() throws {
        let only = Self.rule([Self.hostRow], occurrence: .times(1...1), RuleAction(.noDecrypt))
        let tunnel = Self.rule([Self.hostRow], RuleAction(.returnConnectTunnel), RuleAction(.noDecrypt))
        let snapshot = RuleSnapshot(revision: 1, rules: [only, tunnel])
        let hits = RuleHitCounter()
        for _ in 0..<3 {
            let decision = try RuleEvaluator.request(Self.head, snapshot: snapshot, hits: hits, cache: Self.cache())
            #expect(decision.matches.total == 0 && decision.matches.ruleIDs.isEmpty)
            #expect(decision.carry?.pending.isEmpty == true)
        }
        #expect(hits.count(only.id) == 0 && hits.count(tunnel.id) == 0 && hits.snapshot().isEmpty)
        let response = try RuleEvaluator.response(
            Self.ok, after: RuleEvaluator.request(Self.head, snapshot: snapshot, cache: Self.cache()),
            snapshot: snapshot, hits: hits, cache: Self.cache())
        #expect(response.matches.total == 0 && hits.snapshot().isEmpty)
    }

    @Test func mixedRuleStillJudgedAtP1() throws {
        let mixed = Self.rule([Self.hostRow], RuleAction(.noDecrypt), Self.mark)
        let snapshot = RuleSnapshot(revision: 1, rules: [mixed])
        let hits = RuleHitCounter()
        let decision = try RuleEvaluator.request(Self.head, snapshot: snapshot, hits: hits, cache: Self.cache())
        #expect(hits.count(mixed.id) == 1)
        #expect(decision.matches.ruleIDs == [mixed.id])
    }

    @Test func requirementsIgnoreConnectOnlyRulesAtP1() {
        let p0Only = Self.rule([Self.clientAppRow], RuleAction(.noDecrypt))
        let requirements = RuleSnapshot(revision: 1, rules: [p0Only]).requirements
        #expect(requirements.connect && requirements.connectClientApp)
        #expect(!requirements.clientApp && !requirements.requestBody && !requirements.responseBody)
        // Mixed with an annotation, the P1 judgment still reads the app.
        let mixed = Self.rule([Self.clientAppRow], RuleAction(.noDecrypt), Self.mark)
        #expect(RuleSnapshot(revision: 1, rules: [mixed]).requirements.clientApp)
        // Beside a normal rule that reads it, the flag is on.
        let both = RuleSnapshot(revision: 1, rules: [p0Only, Self.rule([Self.clientAppRow], Self.mark)]).requirements
        #expect(both.clientApp && both.connectClientApp)
    }
}
