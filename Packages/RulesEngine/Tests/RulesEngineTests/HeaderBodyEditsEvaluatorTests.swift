import FlowStore
import Foundation
import Testing

@testable import RulesEngine

private func target() -> HTTPMessageTarget {
    HTTPMessageTarget(scheme: "https", host: "a.test", port: 443, method: "GET", pathAndQuery: "/v1")
}

private func request(headers: [HeaderField] = []) -> HTTPMessageHead { .request(target(), headers: headers) }

private func response(headers: [HeaderField] = []) -> HTTPMessageHead {
    .response(status: 200, reason: "OK", headers: headers)
}

private func edit(_ direction: HTTPMessageDirection, _ operations: HeaderEdit...) -> RuleAction {
    RuleAction(.editHeaders(direction: direction, operations: operations))
}

private func rule(id: UUID = UUID(), _ actions: RuleAction...) -> Rule {
    Rule(
        id: id, name: "r", enabled: true, groupID: nil, order: 0,
        conditions: ConditionGroup(mode: .all, occurrence: .any, rows: []), actions: actions)
}

private func snapshot(_ rules: Rule...) -> RuleSnapshot { RuleSnapshot(revision: 7, groups: [], rules: rules) }

private func calmCache() -> PatternCache { PatternCache(budget: RegexBudget(clock: { .zero })) }

private func exchange(
    _ requestHead: HTTPMessageHead, _ responseHead: HTTPMessageHead, _ snapshot: RuleSnapshot
) throws -> (request: RequestRuleDecision, response: ResponseRuleDecision) {
    let cache = calmCache()
    let p1 = try RuleEvaluator.request(requestHead, snapshot: snapshot, cache: cache)
    let p2 = try RuleEvaluator.response(
        responseHead, after: p1, snapshot: snapshot,
        requestWasUpgradeCandidate: HTTPMutationValidator.isUpgradeCandidate(requestHead.headers),
        isLocalResponse: false, cache: cache)
    return (p1, p2)
}

private func outcome(_ id: UUID, _ code: RuleOutcomeCode, _ index: Int? = nil) -> RuleOutcome {
    RuleOutcome(ruleID: id, code: code, actionIndex: index)
}

@Suite("HeaderBodyEditsEvaluator")
struct HeaderBodyEditsEvaluatorTests {
    @Test func newHeaderMethodsRunAtRequestAndResponsePoint() throws {
        let req = rule(
            edit(.request, .addIfMissing(name: "X-New", value: "1"), .appendToValue(name: "Accept", text: ",c")))
        let res = rule(
            edit(
                .response, .findReplace(name: "X-R", find: "foo", replacement: "bar", caseSensitive: true),
                .regex(name: "X-R", pattern: "(b)ar", replacement: "$1az", caseSensitive: true)))
        let result = try exchange(
            request(headers: [HeaderField(name: "Accept", value: "a")]),
            response(headers: [HeaderField(name: "X-R", value: "foo")]), snapshot(req, res))
        #expect(
            result.request.effectiveHead.headers == [
                HeaderField(name: "Accept", value: "a,c"), HeaderField(name: "X-New", value: "1"),
            ])
        #expect(result.response.effectiveHead.headers == [HeaderField(name: "X-R", value: "baz")])
        #expect(result.request.matches.outcomes == [outcome(req.id, .applied)])
        #expect(result.response.matches.outcomes == [outcome(res.id, .applied)])
        #expect(result.request.rulesModified && result.response.rulesModified)
    }

    @Test func noMatchRecordsEditNoMatchNotApplied() throws {
        let r = rule(edit(.request, .appendToValue(name: "Accept", text: ",c")))
        let decision = try RuleEvaluator.request(
            request(headers: [HeaderField(name: "Other", value: "x")]), snapshot: snapshot(r), cache: calmCache())
        #expect(decision.matches.outcomes == [outcome(r.id, .editNoMatch)])
        #expect(decision.effectiveHead.headers == [HeaderField(name: "Other", value: "x")])
        #expect(!decision.rulesModified)
    }

    @Test func oldMethodThatChangedSomethingCountsAsAMatchNextToAMissedLookup() throws {
        let r = rule(
            edit(.request, .set(name: "X-New", value: "1"), .appendToValue(name: "Accept", text: ",c")))
        let decision = try RuleEvaluator.request(
            request(headers: [HeaderField(name: "Other", value: "x")]), snapshot: snapshot(r), cache: calmCache())
        #expect(decision.matches.outcomes == [outcome(r.id, .applied)])
        #expect(decision.rulesModified)
    }

    @Test func changedHeaderSetsModified() throws {
        let r = rule(edit(.request, .findReplace(name: "X", find: "a", replacement: "b", caseSensitive: true)))
        let decision = try RuleEvaluator.request(
            request(headers: [HeaderField(name: "X", value: "a")]), snapshot: snapshot(r), cache: calmCache())
        #expect(decision.rulesModified)
        #expect(decision.matches.outcomes == [outcome(r.id, .applied)])
    }

    @Test func addIfMissingThatFindsTheFieldIsAppliedButNotModified() throws {
        let r = rule(edit(.request, .addIfMissing(name: "X", value: "2")))
        let decision = try RuleEvaluator.request(
            request(headers: [HeaderField(name: "X", value: "1")]), snapshot: snapshot(r), cache: calmCache())
        #expect(decision.matches.outcomes == [outcome(r.id, .applied)])
        #expect(!decision.rulesModified)
    }

    @Test func patternTimeoutIsListedAndNothingChanges() throws {
        let hostile = String(repeating: "a", count: 60) + "b"
        let r = rule(edit(.request, .regex(name: "X", pattern: "(a|aa)+c", replacement: "z", caseSensitive: true)))
        let decision = try RuleEvaluator.request(
            request(headers: [HeaderField(name: "X", value: hostile)]), snapshot: snapshot(r),
            cache: PatternCache(budget: StepClock().budget))
        #expect(decision.matches.outcomes.contains(outcome(r.id, .patternTimedOut)))
        #expect(decision.effectiveHead.headers == [HeaderField(name: "X", value: hostile)])
        #expect(!decision.rulesModified)
    }

    @Test func legacyHeaderEditsKeepTheirBytesAndOutcomes() throws {
        let r = rule(edit(.request, .set(name: "X", value: "1"), .append(name: "Y", value: "2"), .remove(name: "Z")))
        // Nothing to change at all still counts as applied and modified, as before R5.
        let untouched = try RuleEvaluator.request(
            request(headers: [HeaderField(name: "X", value: "1"), HeaderField(name: "Y", value: "2")]),
            snapshot: snapshot(rule(edit(.request, .set(name: "X", value: "1"), .remove(name: "Z")))), cache: calmCache())
        #expect(untouched.rulesModified)
        #expect(untouched.matches.outcomes.map(\.code) == [.applied])
        let decision = try RuleEvaluator.request(
            request(headers: [HeaderField(name: "Z", value: "q"), HeaderField(name: "x", value: "0")]),
            snapshot: snapshot(r), cache: calmCache())
        #expect(decision.effectiveHead.headers == [HeaderField(name: "X", value: "1"), HeaderField(name: "Y", value: "2")])
        #expect(decision.matches.outcomes == [outcome(r.id, .applied)])
        #expect(decision.rulesModified)
    }

    @Test func protectedNamesStillRejectAtEvaluation() {
        let r = rule(edit(.request, .appendToValue(name: "Host", text: "x")))
        #expect(throws: RuleEvaluationError.self) {
            _ = try RuleEvaluator.request(request(headers: [HeaderField(name: "Host", value: "a")]), snapshot: snapshot(r), cache: calmCache())
        }
    }

    @Test func oldEditorFormIsNilForNewMethods() {
        let old = rule(edit(.request, .set(name: "X", value: "1")))
        #expect(old.oldEditorForm != nil)
        let operations: [HeaderEdit] = [
            .addIfMissing(name: "X", value: "1"), .appendToValue(name: "X", text: "1"),
            .findReplace(name: "X", find: "a", replacement: "b", caseSensitive: true),
            .regex(name: "X", pattern: "a", replacement: "b", caseSensitive: true),
        ]
        for operation in operations {
            #expect(rule(edit(.request, .set(name: "Y", value: "1"), operation)).oldEditorForm == nil, "\(operation)")
        }
    }
}

@Suite("BodyEditsEvaluator")
struct BodyEditsEvaluatorTests {
    @Test func peekSeesSetValueForLaterBodyConditions() throws {
        let setter = rule(
            RuleAction(
                .rewriteBody(
                    direction: .request, BodyRewriteAction(find: "", replacement: "hello", operation: .setValue))))
        let later = UUID()
        let reader = rule(
            id: later, RuleAction(.mark(MarkAction(background: "#FF3B30"))))
        var conditional = reader
        conditional.conditions = ConditionGroup(
            mode: .all, occurrence: .any, rows: [ConditionRow(field: .requestBody, op: .contains, value: "hello")])
        let decision = try RuleEvaluator.request(
            .request(target(), headers: [HeaderField(name: "Content-Type", value: "text/plain")]),
            snapshot: snapshot(setter, conditional), cache: calmCache(), requestBody: .text("old"))
        #expect(decision.matches.ruleIDs.contains(later))
        #expect(decision.carry?.requestBody == .text("hello"))
    }

    @Test func peekSeesClearAsEmptyText() throws {
        let clearing = rule(
            RuleAction(.rewriteBody(direction: .request, BodyRewriteAction(find: "", replacement: "", operation: .clear))))
        let later = UUID()
        var reader = rule(id: later, RuleAction(.mark(MarkAction(background: "#FF3B30"))))
        reader.conditions = ConditionGroup(
            mode: .all, occurrence: .any, rows: [ConditionRow(field: .requestBody, op: .notContains, value: "old")])
        let decision = try RuleEvaluator.request(
            .request(target(), headers: [HeaderField(name: "Content-Type", value: "text/plain")]),
            snapshot: snapshot(clearing, reader), cache: calmCache(), requestBody: .text("old"))
        #expect(decision.matches.ruleIDs.contains(later))
        #expect(decision.carry?.requestBody == .text(""))
    }

    private func reader(_ id: UUID, _ op: ConditionOperator, _ value: String) -> Rule {
        var r = rule(id: id, RuleAction(.mark(MarkAction(background: "#FF3B30"))))
        r.conditions = ConditionGroup(
            mode: .all, occurrence: .any, rows: [ConditionRow(field: .requestBody, op: op, value: value)])
        return r
    }

    private func body(_ action: BodyRewriteAction) -> Rule { rule(RuleAction(.rewriteBody(direction: .request, action))) }

    private func run(_ rules: [Rule], body: String) throws -> RequestRuleDecision {
        try RuleEvaluator.request(
            .request(target(), headers: [HeaderField(name: "Content-Type", value: "text/plain")]),
            snapshot: RuleSnapshot(revision: 7, groups: [], rules: rules), cache: calmCache(), requestBody: .text(body))
    }

    @Test func setValueAfterClearIsStillSeenByLaterRows() throws {
        let (second, fourth) = (UUID(), UUID())
        let decision = try run(
            [
                body(BodyRewriteAction(find: "", replacement: "", operation: .clear)),
                reader(second, .notContains, "old"),
                body(BodyRewriteAction(find: "", replacement: "hello", operation: .setValue)),
                reader(fourth, .contains, "hello"),
            ], body: "old")
        #expect(decision.matches.ruleIDs.contains(second))
        #expect(decision.matches.ruleIDs.contains(fourth))
    }

    @Test func ordinaryEmptyMatchRegexStillRunsAfterEmptying() throws {
        let (second, fourth) = (UUID(), UUID())
        let decision = try run(
            [
                body(BodyRewriteAction(find: "abc", replacement: "")),
                reader(second, .notContains, "abc"),
                body(BodyRewriteAction(find: "^$", replacement: "Z", syntax: .regex)),
                reader(fourth, .contains, "Z"),
            ], body: "abc")
        #expect(decision.matches.ruleIDs.contains(second))
        #expect(decision.matches.ruleIDs.contains(fourth))
    }
}
