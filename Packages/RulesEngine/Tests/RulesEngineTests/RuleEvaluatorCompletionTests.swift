import FlowStore
import Foundation
import Testing

@testable import RulesEngine

private func target(host: String = "a.test", path: String = "/v1/items") -> HTTPMessageTarget {
    HTTPMessageTarget(scheme: "https", host: host, port: 443, method: "GET", pathAndQuery: path)
}

private func request(_ target: HTTPMessageTarget = target(), headers: [HeaderField] = []) -> HTTPMessageHead {
    .request(target, headers: headers)
}

private func response(_ status: Int = 200, headers: [HeaderField] = []) -> HTTPMessageHead {
    .response(status: status, reason: "OK", headers: headers)
}

/// A regular-expression clock that returns the given readings in order, then a long time.
private final class ScriptedClock: @unchecked Sendable {  // guarded by `lock`
    private let lock = NSLock()
    private var values: [Duration]
    init(_ millis: [Int]) { values = millis.map { .milliseconds($0) } }
    func read() -> Duration { lock.withLock { values.isEmpty ? .seconds(1000) : values.removeFirst() } }
}

// MARK: conditions

private func duration(_ op: ConditionOperator, _ value: String) -> ConditionRow {
    ConditionRow(field: .durationMs, op: op, value: value)
}
private func sessionState(_ value: String) -> ConditionRow {
    ConditionRow(field: .sessionState, op: .equals, value: value)
}
private func responseSize(_ op: ConditionOperator, _ value: String) -> ConditionRow {
    ConditionRow(field: .responseBodySize, op: op, value: value)
}
/// The new-path status comparison (the old `inRange` row judges at the response).
private func statusEquals(_ code: Int) -> ConditionRow {
    ConditionRow(field: .statusCode, op: .equals, value: "\(code)")
}
private func requestHeader(_ name: String, equals value: String) -> ConditionRow {
    ConditionRow(field: .requestHeader, name: name, op: .equals, value: value)
}
private func urlRegex(_ pattern: String) -> ConditionRow { ConditionRow(field: .url, op: .regex, value: pattern) }
/// Always true once the exchange finished; makes a rule judge at the completion point.
private let finished = duration(.greaterOrEqual, "0")

// MARK: actions

private let red = "#FF3B30"

private func mark(_ background: String = red) -> RuleAction { RuleAction(.mark(MarkAction(background: background))) }
private func comment(_ text: String = "note") -> RuleAction {
    RuleAction(.comment(CommentAction(mode: .append, text: text)))
}
private let hide = RuleAction(.hide)

private func setHeader(
    _ name: String, _ value: String, on direction: HTTPMessageDirection = .request, final: Bool = false
) -> RuleAction {
    RuleAction(.editHeaders(direction: direction, operations: [.set(name: name, value: value)]), isFinal: final)
}

private func rewriteStatus(_ status: Int) -> RuleAction {
    RuleAction(.rewriteStatus(RewriteStatusAction(status: status)))
}

private func rule(
    id: UUID = UUID(), name: String = "r", when rows: [ConditionRow] = [], occurrence: Occurrence = .any,
    _ actions: RuleAction...
) -> Rule {
    Rule(
        id: id, name: name, enabled: true, groupID: nil, order: 0,
        conditions: ConditionGroup(mode: .all, occurrence: occurrence, rows: rows), actions: actions)
}

/// Rules are evaluated in the order given (they all have order 0).
private func snapshot(_ rules: Rule...) -> RuleSnapshot { RuleSnapshot(revision: 7, rules: rules) }

private func calmCache() -> PatternCache { PatternCache(budget: RegexBudget(clock: { .zero })) }

private func completed(_ milliseconds: Int = 20, bytes: Int? = 10) -> CompletionFacts {
    CompletionFacts(state: .completed, durationMilliseconds: milliseconds, responseWireBytes: bytes)
}

private struct Exchange {
    var request: RequestRuleDecision
    var response: ResponseRuleDecision?
    var completion: CompletionRuleDecision
}

/// One exchange through all three points. `responseHead == nil` is an exchange that never got a
/// response (failed, cancelled, closed): the response point does not run.
private func evaluate(
    _ requestHead: HTTPMessageHead = request(), _ responseHead: HTTPMessageHead? = response(),
    _ snapshot: RuleSnapshot, completion: CompletionFacts = completed(), facts: ExchangeFacts = ExchangeFacts(),
    hits: RuleHitCounter? = nil, allowance: RegexAllowance = RegexAllowance(), cache: PatternCache = calmCache()
) throws -> Exchange {
    let p1 = try RuleEvaluator.request(
        requestHead, snapshot: snapshot, hits: hits, facts: facts, allowance: allowance, cache: cache)
    let p2 = try responseHead.map {
        try RuleEvaluator.response(
            $0, after: p1, snapshot: snapshot, hits: hits, facts: facts, allowance: allowance, cache: cache)
    }
    let p3 = RuleEvaluator.completion(
        after: p1, response: p2, snapshot: snapshot, facts: facts, completion: completion, hits: hits,
        allowance: allowance, cache: cache)
    return Exchange(request: p1, response: p2, completion: p3)
}

/// The same with the default request and a `200` response.
private func evaluate(
    _ snapshot: RuleSnapshot, completion: CompletionFacts = completed(), facts: ExchangeFacts = ExchangeFacts(),
    hits: RuleHitCounter? = nil, allowance: RegexAllowance = RegexAllowance()
) throws -> Exchange {
    try evaluate(
        request(), response(), snapshot, completion: completion, facts: facts, hits: hits, allowance: allowance)
}

private func outcome(_ id: UUID, _ code: RuleOutcomeCode, _ index: Int? = nil) -> RuleOutcome {
    RuleOutcome(ruleID: id, code: code, actionIndex: index)
}

private func flowMark(_ background: String = red, rule: Rule) -> FlowAnnotation {
    .mark(FlowMark(background: background, text: nil, source: .rule(id: rule.id, name: rule.name))!)
}

@Suite("RuleEvaluatorCompletion")
struct RuleEvaluatorCompletionTests {
    // MARK: the completion facts

    @Test func durationRuleMarksSlowRequests() throws {
        let slow = rule(when: [duration(.greaterThan, "1000")], mark())
        let late = try evaluate(snapshot(slow), completion: completed(1500))
        #expect(late.completion.annotations == [flowMark(rule: slow)])
        #expect(late.completion.matches.ruleIDs == [slow.id])
        #expect(late.completion.matches.outcomes == [outcome(slow.id, .applied)])
        // The rule waits for the completion point: the earlier points never see it.
        #expect(late.request.matches.ruleIDs.isEmpty && late.request.annotations.isEmpty)
        #expect(late.response?.matches.ruleIDs.isEmpty == true && late.response?.annotations.isEmpty == true)

        let quick = try evaluate(snapshot(slow), completion: completed(500))
        #expect(quick.completion.annotations.isEmpty)
        #expect(quick.completion.matches.ruleIDs.isEmpty && quick.completion.matches.outcomes.isEmpty)
    }

    @Test func failedSessionRuleMarks() throws {
        let failing = rule(when: [sessionState("failed")], mark())
        let failed = CompletionFacts(state: .failed, durationMilliseconds: 3, responseWireBytes: nil)
        #expect(try evaluate(snapshot(failing), completion: failed).completion.annotations == [flowMark(rule: failing)])
        #expect(try evaluate(snapshot(failing), completion: completed()).completion.annotations.isEmpty)
        // The value is one of the fixed choices, compared without regard to case.
        let shouting = rule(when: [sessionState("FAILED")], mark())
        #expect(try evaluate(snapshot(shouting), completion: failed).completion.annotations == [flowMark(rule: shouting)])
    }

    @Test func responseSizeUsesWireBytes() throws {
        let big = rule(when: [responseSize(.greaterThan, "100")], mark())
        // The declared length says small; what came over the wire decides.
        let declaredSmall = response(headers: [HeaderField(name: "Content-Length", value: "10")])
        let wireBig = try evaluate(request(), declaredSmall, snapshot(big), completion: completed(bytes: 500))
        #expect(wireBig.completion.annotations == [flowMark(rule: big)])
        let declaredBig = response(headers: [HeaderField(name: "Content-Length", value: "1000")])
        let wireSmall = try evaluate(request(), declaredBig, snapshot(big), completion: completed(bytes: 50))
        #expect(wireSmall.completion.annotations.isEmpty)
        #expect(wireSmall.completion.matches.outcomes.isEmpty)
    }

    @Test func responseSizeUnknownWithoutAResponse() throws {
        let big = rule(when: [responseSize(.greaterThan, "100")], mark())
        let small = rule(when: [responseSize(.lessThan, "100")], mark())
        let failed = CompletionFacts(state: .failed, durationMilliseconds: 3, responseWireBytes: nil)
        let result = try evaluate(request(), nil, snapshot(big, small), completion: failed)
        // Neither "greater" nor "less" can be said: both say why they stayed silent, once each.
        #expect(result.completion.annotations.isEmpty)
        #expect(result.completion.matches.ruleIDs.isEmpty)
        #expect(result.completion.matches.outcomes == [outcome(big.id, .unknownSize), outcome(small.id, .unknownSize)])
    }

    @Test func completionRunsWithoutAResponse() throws {
        let failing = rule(when: [sessionState("failed")], mark())
        let statusRead = rule(when: [statusEquals(200), sessionState("failed")], comment("x"))
        let failed = CompletionFacts(state: .failed, durationMilliseconds: 3, responseWireBytes: nil)
        let result = try evaluate(request(), nil, snapshot(failing, statusRead), completion: failed)
        #expect(result.response == nil)
        #expect(result.completion.annotations == [flowMark(rule: failing)])
        // The response side is unknown: the status row does not match, and it is not a noted outcome.
        #expect(result.completion.matches.outcomes == [outcome(failing.id, .applied)])
    }

    // MARK: the final messages

    @Test func completionReadsFinalResponse() throws {
        let rewrite = rule(when: [statusEquals(200)], rewriteStatus(500))
        let sees500 = rule(when: [statusEquals(500), finished], mark())
        let sees200 = rule(when: [statusEquals(200), finished], comment())
        let result = try evaluate(request(), response(200), snapshot(rewrite, sees500, sees200))
        #expect(result.response?.statusRewrite == 500)
        #expect(result.completion.annotations == [flowMark(rule: sees500)])
        #expect(result.completion.matches.ruleIDs == [sees500.id])
    }

    @Test func completionReadsFinalRequestHeaders() throws {
        let edit = rule(setHeader("X-A", "1"))
        let reader = rule(when: [requestHeader("X-A", equals: "1"), finished], mark())
        let original = rule(when: [requestHeader("X-A", equals: "0"), finished], comment())
        let result = try evaluate(
            request(headers: [HeaderField(name: "X-A", value: "0")]), response(), snapshot(edit, reader, original))
        #expect(result.completion.annotations == [flowMark(rule: reader)])
    }

    @Test func completionReadsTheResponseHeadersAsP2LeftThem() throws {
        let edit = rule(when: [statusEquals(200)], setHeader("X-B", "2", on: .response))
        let reader = rule(
            when: [ConditionRow(field: .responseHeader, name: "X-B", op: .equals, value: "2"), finished], mark())
        let result = try evaluate(snapshot(edit, reader))
        #expect(result.completion.annotations == [flowMark(rule: reader)])
    }

    @Test func rulesModifiedAndCommentReadWhatTheEarlierPointsLeft() throws {
        let edit = rule(setHeader("X-A", "1"))
        let modified = rule(
            when: [ConditionRow(field: .rulesModified, op: .equals, value: "true"), finished], mark())
        // The comment is the flow's, as the caller hands it in, with this point's earlier comments applied.
        let note = rule(when: [finished], comment("slow"))
        let reader = rule(when: [ConditionRow(field: .comment, op: .equals, value: "user slow"), finished], hide)
        let result = try evaluate(
            snapshot(edit, modified, note, reader), facts: ExchangeFacts(comment: "user"))
        #expect(
            result.completion.annotations == [
                flowMark(rule: modified), .comment(CommentAction(mode: .append, text: "slow")), .hide,
            ])
        let unmodified = try evaluate(snapshot(modified))
        #expect(unmodified.completion.annotations.isEmpty)
    }

    // MARK: what the point evaluates

    @Test func p1AndP2JudgedRulesAreNotReEvaluated() throws {
        let early = rule(mark())
        let middle = rule(when: [statusEquals(200)], mark())
        let late = rule(when: [finished], mark())
        let hits = RuleHitCounter()
        let result = try evaluate(snapshot(early, middle, late), hits: hits)
        #expect(hits.count(early.id) == 1)
        #expect(hits.count(middle.id) == 1)
        #expect(hits.count(late.id) == 1)
        #expect(result.completion.matches.ruleIDs == [late.id])
        #expect(result.completion.annotations == [flowMark(rule: late)])
        // Calling the completion point again re-evaluates only its own rule.
        _ = RuleEvaluator.completion(
            after: result.request, response: result.response, snapshot: snapshot(early, middle, late),
            facts: ExchangeFacts(), completion: completed(), hits: hits, cache: calmCache())
        #expect(hits.count(early.id) == 1 && hits.count(middle.id) == 1 && hits.count(late.id) == 2)
    }

    @Test func hitsAndOccurrenceApplyAtCompletion() throws {
        let second = rule(when: [finished], occurrence: .times(2...2), mark())
        let rules = snapshot(second)
        let hits = RuleHitCounter()
        let first = try evaluate(rules, hits: hits)
        #expect(first.completion.annotations.isEmpty)
        #expect(first.completion.matches.outcomes == [outcome(second.id, .occurrenceSkipped)])
        let next = try evaluate(rules, hits: hits)
        #expect(next.completion.annotations == [flowMark(rule: second)])
        let third = try evaluate(rules, hits: hits)
        #expect(third.completion.annotations.isEmpty)
        #expect(hits.count(second.id) == 3)
        // Without a counter the occurrence range is ignored, as at the other points.
        #expect(try evaluate(rules).completion.annotations == [flowMark(rule: second)])
    }

    // MARK: final actions

    @Test func finalStopAtP1CutsLowerCompletionRules() throws {
        let above = rule(when: [finished], mark())
        let stopper = rule(setHeader("X-A", "1", final: true))
        let below = rule(when: [finished], comment())
        let result = try evaluate(snapshot(above, stopper, below))
        #expect(result.request.carry?.finalStop == RuleCarry.FinalStop(position: 1, actionIndex: 0))
        #expect(result.completion.annotations == [flowMark(rule: above)])
        #expect(result.completion.matches.ruleIDs == [above.id])
    }

    @Test func finalStopAtP2CutsLowerCompletionRules() throws {
        let above = rule(when: [finished], mark())
        let stopper = rule(when: [statusEquals(200)], setHeader("X-B", "1", on: .response, final: true))
        let below = rule(when: [finished], comment())
        let result = try evaluate(snapshot(above, stopper, below))
        #expect(result.request.carry?.finalStop == nil)
        #expect(result.response?.carry.finalStop == RuleCarry.FinalStop(position: 1, actionIndex: 0))
        #expect(result.completion.annotations == [flowMark(rule: above)])
        #expect(result.completion.matches.ruleIDs == [above.id])
    }

    @Test func higherPriorityCompletionRulesStillRunAfterACloseOrFinal() throws {
        let other = rule(when: [requestHeader("X-Never", equals: "1")], mark())
        let above = rule(when: [sessionState("failed")], mark())
        let filler = rule(when: [requestHeader("X-Never", equals: "1")], comment())
        let stopper = rule(setHeader("X-A", "1", final: true))
        let below = rule(when: [sessionState("failed")], comment())
        let failed = CompletionFacts(state: .failed, durationMilliseconds: 3, responseWireBytes: nil)
        let result = try evaluate(request(), nil, snapshot(other, above, filler, stopper, below), completion: failed)
        #expect(result.request.carry?.finalStop?.position == 3)
        #expect(result.completion.annotations == [flowMark(rule: above)])
        #expect(result.completion.matches.ruleIDs == [above.id])
    }

    @Test func hideAtCompletionIsFinalAndCutsLowerCompletionRules() throws {
        let hiding = rule(when: [finished], hide, mark())
        let below = rule(when: [finished], comment())
        let result = try evaluate(snapshot(hiding, below))
        #expect(result.completion.annotations == [.hide])
        #expect(result.completion.matches.ruleIDs == [hiding.id])
        #expect(
            result.completion.matches.outcomes == [
                outcome(hiding.id, .applied, 0), outcome(hiding.id, .finalStop, 0),
                outcome(hiding.id, .skippedAfterFinal, 1),
            ])
        // The lowest rule's hide cuts nothing, so it records no final stop.
        let lowest = rule(when: [finished], hide)
        let alone = try evaluate(snapshot(lowest))
        #expect(alone.completion.annotations == [.hide])
        #expect(alone.completion.matches.outcomes == [outcome(lowest.id, .applied)])
    }

    @Test func hideAtCompletionLeavesHigherRulesAlone() throws {
        let above = rule(when: [finished], mark())
        let hiding = rule(when: [finished], hide)
        let result = try evaluate(snapshot(above, hiding))
        #expect(result.completion.annotations == [flowMark(rule: above), .hide])
    }

    @Test func markThenCommentKeepOrder() throws {
        let both = rule(when: [finished], mark(), comment("slow"))
        let then = rule(when: [finished], comment("again"))
        let result = try evaluate(snapshot(both, then))
        #expect(
            result.completion.annotations == [
                flowMark(rule: both), .comment(CommentAction(mode: .append, text: "slow")),
                .comment(CommentAction(mode: .append, text: "again")),
            ])
        #expect(
            result.completion.matches.outcomes == [
                outcome(both.id, .applied, 0), outcome(both.id, .applied, 1), outcome(then.id, .applied),
            ])
    }

    @Test func completionNeverTouchesTransportOutcomes() throws {
        // Validation refuses these; a snapshot that skipped it still runs only the annotations here.
        let mixed = Rule(
            name: "r", conditions: ConditionGroup(rows: [finished]),
            actions: [
                setHeader("X-A", "1", on: .response), RuleAction(.breakpoint(direction: .response, mode: .headers)),
                rewriteStatus(500), mark(),
            ])
        let result = try evaluate(snapshot(mixed))
        #expect(result.completion.annotations == [flowMark(rule: mixed)])
        #expect(result.completion.matches.outcomes == [outcome(mixed.id, .applied, 3)])
        #expect(result.response?.statusRewrite == nil)
        #expect(result.response?.breakpoint == nil)
    }

    @Test func completionDecisionCarriesOnlyItsOwnOutcomes() throws {
        let early = rule(mark())
        let middle = rule(when: [statusEquals(200)], comment())
        let late = rule(when: [finished], mark("#007AFF"))
        let result = try evaluate(snapshot(early, middle, late))
        #expect(result.completion.matches.revision == 7)
        #expect(result.completion.matches.ruleIDs == [late.id])
        #expect(result.completion.matches.total == 1)
        #expect(result.completion.matches.outcomes == [outcome(late.id, .applied)])
        #expect(result.completion.annotations == [flowMark("#007AFF", rule: late)])
    }

    @Test func regexAllowanceIsSharedWithEarlierPoints() throws {
        let early = rule(when: [urlRegex("items")], mark())
        let late = rule(when: [urlRegex("items"), finished], comment())
        // The request point's match takes 5 ms of a 4 ms allowance; nothing is left for the completion point.
        let clock = ScriptedClock([0, 5])
        let allowance = RegexAllowance(total: .milliseconds(4), clock: { clock.read() })
        let starved = try evaluate(snapshot(early, late), allowance: allowance)
        #expect(starved.request.annotations == [flowMark(rule: early)])
        #expect(starved.completion.annotations.isEmpty)
        #expect(starved.completion.matches.outcomes == [outcome(late.id, .patternTimedOut)])
        // Control: an allowance of its own lets the completion rule match.
        let fresh = try evaluate(snapshot(early, late))
        #expect(fresh.completion.annotations == [.comment(CommentAction(mode: .append, text: "note"))])
    }

    @Test func requestDecisionOfAnotherSnapshotRunsNothing() throws {
        let late = rule(when: [finished], mark())
        let p1 = try RuleEvaluator.request(request(), snapshot: snapshot(late), cache: calmCache())
        let other = RuleSnapshot(revision: 8, rules: [late])
        let hits = RuleHitCounter()
        var reported: [String] = []
        let decision = RuleEvaluator.completion(
            after: p1, response: nil, snapshot: other, facts: ExchangeFacts(), completion: completed(), hits: hits,
            cache: calmCache()
        ) { reported.append($0) }
        #expect(reported.count == 1)
        #expect(decision == CompletionRuleDecision(matches: RuleMatchSummary(revision: 8, ruleIDs: [], total: 0)))
        #expect(hits.snapshot().isEmpty)
    }

    // MARK: what the response point leaves

    @Test func responseDecisionCarryHoldsFinalHeadersAndStatus() throws {
        let edit = rule(when: [statusEquals(200)], rewriteStatus(503), setHeader("X-B", "2", on: .response))
        let server = HeaderField(name: "Server", value: "s")
        let result = try evaluate(request(), response(200, headers: [server]), snapshot(edit))
        #expect(
            result.response?.carry
                == ResponseCarry(finalStop: nil, status: 503, headers: [server, HeaderField(name: "X-B", value: "2")]))
        // Untouched, the carry is the response as it arrived.
        let plain = try evaluate(request(), response(404, headers: [server]), snapshot())
        #expect(plain.response?.carry == ResponseCarry(finalStop: nil, status: 404, headers: [server]))
    }

    @Test func responseDecisionCarryRecordsP2FinalStop() throws {
        let first = rule(when: [statusEquals(200)], setHeader("X-A", "1", on: .response))
        let stopper = rule(when: [statusEquals(200)], setHeader("X-B", "1", on: .response, final: true))
        let result = try evaluate(snapshot(first, stopper, rule(when: [statusEquals(200)], mark())))
        #expect(result.response?.carry.finalStop == RuleCarry.FinalStop(position: 1, actionIndex: 0))
        // A final action of the request point is the response point's too.
        let early = rule(setHeader("X-A", "1", final: true))
        let fromP1 = try evaluate(snapshot(early, rule(when: [statusEquals(200)], mark())))
        #expect(fromP1.response?.carry.finalStop == RuleCarry.FinalStop(position: 0, actionIndex: 0))
    }

    // MARK: building the condition input

    @Test func conditionInputIsBuiltOnlyForRulesWithRows() {
        var built = 0
        let input = {
            built += 1
            return ConditionInput(target: target())
        }
        let empty = rule(mark())
        #expect(RuleEvaluator.judge(empty, allowance: RegexAllowance(), cache: calmCache(), input: input).matched)
        #expect(built == 0)
        let one = rule(when: [requestHeader("X-A", equals: "")], mark())
        #expect(RuleEvaluator.judge(one, allowance: RegexAllowance(), cache: calmCache(), input: input).matched)
        #expect(built == 1)
    }
}

@Suite struct RuleEvaluatorRejectedRequestCompletionTests {
    @Test func rejectedRequestStillGetsRequestSideAndStateRows() {
        let hit = rule(name: "hit", when: [sessionState("failed"), requestHeader("X-A", equals: "1")], mark())
        let wrongState = rule(name: "completed", when: [sessionState("completed")], mark("#00FF00"))
        let response = rule(name: "response", when: [statusEquals(200), finished], mark("#0000FF"))
        let head = request(headers: [HeaderField(name: "X-A", value: "1")])
        let decision = RuleEvaluator.completion(
            afterRejectedRequest: head, snapshot: snapshot(hit, wrongState, response), facts: ExchangeFacts(),
            completion: CompletionFacts(state: .failed, durationMilliseconds: 3, responseWireBytes: nil),
            cache: calmCache())
        #expect(decision.matches.ruleIDs == [hit.id])
        #expect(decision.annotations.count == 1)
    }
}
