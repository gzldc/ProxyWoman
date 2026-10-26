import FlowStore
import Foundation
import Testing
import os

@testable import RulesEngine

private let requestHead = HTTPMessageHead.request(
    HTTPMessageTarget(scheme: "https", host: "a.test", port: 443, method: "GET", pathAndQuery: "/x"), headers: [])

private func responseHead(status: Int = 200, headers: [HeaderField] = []) -> HTTPMessageHead {
    .response(status: status, reason: "OK", headers: headers)
}

private func row(_ field: ConditionField, _ op: ConditionOperator, _ value: String = "", name: String? = nil) -> ConditionRow {
    ConditionRow(field: field, name: name, op: op, value: value)
}
private let body = row(.responseBody, .contains, "vip")
private let mark = RuleAction(.mark(MarkAction(background: "#FF3B30")))

private func rule(_ rows: [ConditionRow], mode: ConditionGroup.Mode = .all, enabled: Bool = true,
                  actions: [RuleAction] = [mark]) -> Rule {
    Rule(name: "r", enabled: enabled, conditions: ConditionGroup(mode: mode, rows: rows), actions: actions)
}

private func needs(_ rules: Rule..., response: HTTPMessageHead = responseHead(), cache: PatternCache = .shared) throws -> Bool {
    let ordered = rules.enumerated().map { index, rule in
        var rule = rule
        rule.order = index
        return rule
    }
    let snapshot = RuleSnapshot(revision: 1, rules: ordered)
    let decision = try RuleEvaluator.request(requestHead, snapshot: snapshot)
    return RuleEvaluator.responseMayNeedBody(response, after: decision, snapshot: snapshot, facts: ExchangeFacts(), cache: cache)
}

/// The head-only pre-pass that decides whether a response body is held for a peek (T12).
@Suite struct ResponseBodyNeedTests {
    @Test func noBodyRulesNeverNeedTheBody() throws {
        #expect(try !needs(rule([row(.statusCode, .equals, "200")])))
        #expect(try !needs())
        #expect(try !needs(rule([body], enabled: false)))
    }

    @Test func aDecidableResponseRowRulesTheBodyRuleOut() throws {
        #expect(try !needs(rule([row(.statusCode, .equals, "404"), body])))
        #expect(try needs(rule([row(.statusCode, .equals, "200"), body])))
        let json = [HeaderField(name: "Content-Type", value: "application/json")]
        #expect(try !needs(rule([row(.responseHeader, .contains, "xml", name: "Content-Type"), body]), response: responseHead(headers: json)))
        #expect(try needs(rule([row(.responseHeader, .contains, "json", name: "Content-Type"), body]), response: responseHead(headers: json)))
    }

    @Test func requestRowsRuleItOutToo() throws {
        #expect(try !needs(rule([row(.host, .equals, "other.test"), body])))
        #expect(try needs(rule([row(.host, .equals, "a.test"), body])))
    }

    @Test func anyAndNoneModes() throws {
        #expect(try needs(rule([row(.statusCode, .equals, "404"), body], mode: .any)))
        #expect(try !needs(rule([row(.statusCode, .equals, "200"), body], mode: .none)))
        #expect(try needs(rule([row(.statusCode, .equals, "404"), body], mode: .none)))
    }

    @Test func rowsOfALaterPointAndRegexRowsCountAsPossibleAndNeverRun() throws {
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let cache = PatternCache(budget: RegexBudget(clock: { calls.withLock { $0 += 1 }; return .zero }))
        #expect(try needs(rule([row(.durationMs, .greaterThan, "100"), body]), cache: cache))
        #expect(try needs(rule([row(.responseHeader, .regex, "zzz", name: "X"), body]), cache: cache))
        #expect(calls.withLock { $0 } == 0)
    }

    @Test func anEarlierResponseEditKeepsLaterBodyRulesPossible() throws {
        let gated = rule([row(.responseHeader, .equals, "yes", name: "X-Flag"), body])
        #expect(try !needs(gated))
        let edit = rule([], actions: [RuleAction(.editHeaders(direction: .response, operations: [.set(name: "X-Flag", value: "yes")]))])
        #expect(try needs(edit, gated))
        let unreachable = rule([row(.host, .equals, "other.test")], actions: edit.actions)
        #expect(try !needs(unreachable, gated))
        #expect(try !needs(rule([]), gated))
    }

    @Test func aRequestPointRuleWithResponseSideActionsKeepsLaterBodyRulesPossible() throws {
        // Matched at the request point, its response header edit runs before the later rule's rows are read.
        let early = rule([row(.host, .equals, "a.test")],
                         actions: [RuleAction(.editHeaders(direction: .response, operations: [.set(name: "X-Flag", value: "yes")]))])
        let gated = rule([row(.responseHeader, .equals, "yes", name: "X-Flag"), body])
        #expect(try needs(early, gated))
    }

    @Test func anEarlierRuleThatModifiesKeepsRulesModifiedBodyRulesPossible() throws {
        let modifiedBody = rule([row(.rulesModified, .equals, "true"), body])
        #expect(try !needs(modifiedBody))
        let actions: [[RuleAction]] = [
            [RuleAction(.editHeaders(direction: .request, operations: [.set(name: "X", value: "1")]))],
            [RuleAction(.rewriteStatus(RewriteStatusAction(status: 500)))],
        ]
        for edit in actions { #expect(try needs(rule([], actions: edit), modifiedBody)) }
        #expect(try !needs(rule([row(.host, .equals, "other.test")], actions: actions[0]), modifiedBody))
    }

    @Test func aModificationAtTheRequestPointCountsAtTheResponse() throws {
        // The request point already modified the message, before the response pre-pass looks.
        let early = rule([row(.host, .equals, "a.test")],
                         actions: [RuleAction(.editHeaders(direction: .request, operations: [.set(name: "X", value: "1")]))])
        let modifiedBody = rule([row(.rulesModified, .equals, "true"), body])
        #expect(try needs(early, modifiedBody))
    }

    @Test func aCommentWrittenAtCompletionKeepsCommentBodyRulesPossible() throws {
        let gated = rule([row(.comment, .contains, "vip"), body])
        #expect(try !needs(gated))
        let comment = RuleAction(.comment(CommentAction(mode: .set, text: "vip")))
        #expect(try needs(rule([row(.durationMs, .greaterOrEqual, "0")], actions: [comment]), gated))
        #expect(try !needs(rule([row(.host, .equals, "other.test"), row(.durationMs, .greaterOrEqual, "0")], actions: [comment]), gated))
    }

    @Test func aNonMatchingResponseEditAboveDoesNotForceAPeek() throws {
        let gated = rule([row(.responseHeader, .equals, "yes", name: "X-Flag"), body])
        let edit = RuleAction(.editHeaders(direction: .response, operations: [.set(name: "X-Flag", value: "yes")]))
        // Judged at the response point (a status row) and not matching this 200.
        #expect(try !needs(rule([row(.statusCode, .equals, "404")], actions: [edit]), gated))
        let status = RuleAction(.rewriteStatus(RewriteStatusAction(status: 500)))
        #expect(try !needs(rule([row(.statusCode, .equals, "404")], actions: [status]), gated))
        // The same rule matching does keep the body rule possible.
        #expect(try needs(rule([row(.statusCode, .equals, "200")], actions: [edit]), gated))
    }
}
