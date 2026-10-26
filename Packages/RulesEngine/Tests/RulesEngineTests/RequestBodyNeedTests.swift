import FlowStore
import Foundation
import Testing
import os

@testable import RulesEngine

private let head = HTTPMessageHead.request(
    HTTPMessageTarget(scheme: "https", host: "a.test", port: 443, method: "POST", pathAndQuery: "/api?x=1"),
    headers: [HeaderField(name: "Content-Type", value: "application/json")])

private func row(_ field: ConditionField, _ op: ConditionOperator, _ value: String = "", name: String? = nil) -> ConditionRow {
    ConditionRow(field: field, name: name, op: op, value: value)
}
private let body = row(.requestBody, .contains, "vip")
private let mark = RuleAction(.mark(MarkAction(background: "#FF3B30")))

private func rule(_ rows: [ConditionRow], mode: ConditionGroup.Mode = .all, enabled: Bool = true,
                  actions: [RuleAction] = [mark]) -> Rule {
    Rule(name: "r", enabled: enabled, conditions: ConditionGroup(mode: mode, rows: rows), actions: actions)
}

private func needs(_ rules: Rule..., facts: ExchangeFacts = ExchangeFacts(), cache: PatternCache = .shared) -> Bool {
    let ordered = rules.enumerated().map { index, rule in
        var rule = rule
        rule.order = index
        return rule
    }
    return RuleEvaluator.requestMayNeedBody(head, snapshot: RuleSnapshot(revision: 1, rules: ordered), facts: facts, cache: cache)
}

/// The head-only pre-pass that decides whether a request body is held for a peek (T11 review I1).
@Suite struct RequestBodyNeedTests {
    @Test func noBodyRulesNeverNeedTheBody() {
        #expect(!needs(rule([row(.host, .equals, "a.test")])))
        #expect(!needs())
    }

    @Test func disabledBodyRulesAreIgnored() {
        #expect(!needs(rule([body], enabled: false)))
    }

    @Test func aDecidableRowRulesTheBodyRuleOut() {
        #expect(!needs(rule([row(.host, .equals, "other.test"), body])))
        #expect(needs(rule([row(.host, .equals, "a.test"), body])))
        #expect(needs(rule([body])))
        // The legacy path decides too (a host pattern).
        #expect(!needs(rule([row(.host, .hostPattern, "other.test"), body])))
        #expect(!needs(rule([row(.queryParam, .equals, "2", name: "x"), body])))
    }

    @Test func anyModeStaysOpenThroughTheBodyRow() {
        #expect(needs(rule([row(.host, .equals, "other.test"), body], mode: .any)))
        #expect(needs(rule([row(.host, .equals, "a.test"), body], mode: .any)))
    }

    @Test func noneModeIsRuledOutByAMatchingRow() {
        #expect(!needs(rule([row(.host, .equals, "a.test"), body], mode: .none)))
        #expect(needs(rule([row(.host, .equals, "other.test"), body], mode: .none)))
    }

    @Test func unknownFactsCountAsPossible() {
        var facts = ExchangeFacts()
        facts.app = .unknown
        #expect(needs(rule([row(.clientApp, .equals, "Fixture", name: "name"), body]), facts: facts))
        // No client address known: the row cannot rule the body rule out.
        #expect(needs(rule([row(.clientIP, .equals, "10.0.0.9"), body])))
        facts.clientIP = "127.0.0.1"
        #expect(!needs(rule([row(.clientIP, .equals, "10.0.0.9"), body]), facts: facts))
    }

    @Test func regexRowsDoNotRunAndCountAsPossible() {
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let cache = PatternCache(budget: RegexBudget(clock: { calls.withLock { $0 += 1 }; return .zero }))
        #expect(needs(rule([row(.url, .regex, "zzz"), body]), cache: cache))
        #expect(needs(rule([row(.host, .regexWhole, "zzz"), body]), cache: cache))
        #expect(calls.withLock { $0 } == 0)
    }

    @Test func laterPointRowsCountAsPossible() {
        // Judged at the response, yet it reads the body the request point peeked.
        #expect(needs(rule([row(.statusCode, .equals, "500"), body])))
        #expect(needs(rule([row(.durationMs, .greaterThan, "100"), body])))
    }

    @Test func anEarlierRuleThatChangesTheRequestKeepsLaterBodyRulesPossible() {
        let gated = rule([row(.requestHeader, .equals, "prod", name: "X-Env"), body])
        #expect(!needs(gated))
        let edit = rule([], actions: [RuleAction(.editHeaders(direction: .request, operations: [.set(name: "X-Env", value: "prod")]))])
        #expect(needs(edit, gated))
        // An earlier edit that cannot match changes nothing.
        let unreachable = rule([row(.host, .equals, "other.test")], actions: edit.actions)
        #expect(!needs(unreachable, gated))
        // An earlier mark does not change what rows read.
        #expect(!needs(rule([]), gated))
    }

    @Test func anEarlierRuleThatModifiesKeepsRulesModifiedBodyRulesPossible() {
        let modifiedBody = rule([row(.rulesModified, .equals, "true"), body])
        #expect(!needs(modifiedBody))
        let actions: [[RuleAction]] = [
            [RuleAction(.editHeaders(direction: .response, operations: [.set(name: "X", value: "1")]))],
            [RuleAction(.rewriteStatus(RewriteStatusAction(status: 500)))],
            [RuleAction(.editHeaders(direction: .request, operations: [.set(name: "X", value: "1")]))],
        ]
        for edit in actions { #expect(needs(rule([], actions: edit), modifiedBody)) }
        // A modification that cannot match changes nothing.
        #expect(!needs(rule([row(.host, .equals, "other.test")], actions: actions[0]), modifiedBody))
    }

    @Test func aCommentWrittenAtALaterPointKeepsCommentBodyRulesPossible() {
        let gated = rule([row(.comment, .contains, "vip"), body])
        #expect(!needs(gated))
        let comment = RuleAction(.comment(CommentAction(mode: .set, text: "vip")))
        // A comment written at the response point and one at completion both change what a later row reads.
        #expect(needs(rule([row(.statusCode, .equals, "200")], actions: [comment]), gated))
        #expect(needs(rule([row(.durationMs, .greaterOrEqual, "0")], actions: [comment]), gated))
        #expect(!needs(rule([row(.host, .equals, "other.test"), row(.statusCode, .equals, "200")], actions: [comment]), gated))
    }

    /// Ruling M2: the completion point runs on the event loop, so a body regular expression there gets at
    /// most 2 ms per match, and a timeout under that cap is not a strike against the pattern.
    @Test func completionPointBodyRegexIsCappedOnTheLoop() throws {
        let clock = OSAllocatedUnfairLock(initialState: Duration.zero)
        let step: @Sendable () -> Duration = { clock.withLock { $0 += .milliseconds(1); return $0 } }
        let cache = PatternCache(budget: RegexBudget(clock: { .zero }), bodyBudget: RegexBudget(maxDuration: .seconds(5), clock: step))
        let slow = Rule(name: "slow", conditions: ConditionGroup(rows: [
            row(.durationMs, .greaterOrEqual, "0"), row(.requestBody, .regex, "(a|aa)+c"),
        ]), actions: [mark])
        let snapshot = RuleSnapshot(revision: 1, rules: [slow])
        let p1 = try RuleEvaluator.request(head, snapshot: snapshot, cache: cache,
                                           requestBody: .text(String(repeating: "a", count: 60) + "b"))
        let p3 = RuleEvaluator.completion(
            after: p1, response: nil, snapshot: snapshot, facts: ExchangeFacts(),
            completion: CompletionFacts(state: .completed, durationMilliseconds: 5, responseWireBytes: nil), cache: cache)
        #expect(p3.matches.outcomes == [RuleOutcome(ruleID: slow.id, code: .patternTimedOut)])
        #expect(p3.annotations.isEmpty)
        // Only a few milliseconds of the clock went by, far below the 5 s body budget.
        #expect(clock.withLock { $0 } < .milliseconds(20))
        #expect(try cache.bodyRegex("(a|aa)+c", caseInsensitive: true).timeoutCount == 0)
    }
}
