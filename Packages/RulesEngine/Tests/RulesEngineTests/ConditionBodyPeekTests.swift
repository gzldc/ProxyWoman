import FlowStore
import Foundation
import Testing

@testable import RulesEngine

private func header(_ name: String, _ value: String) -> HeaderField { HeaderField(name: name, value: value) }

private let textHeaders = [header("Content-Type", "text/plain")]

private func target() -> HTTPMessageTarget {
    HTTPMessageTarget(scheme: "https", host: "a.test", port: 443, method: "POST", pathAndQuery: "/v1")
}

private func calmCache() -> PatternCache { PatternCache(budget: RegexBudget(clock: { .zero })) }

private func bodyRow(
    _ op: ConditionOperator, _ value: String = "", response: Bool = false, caseSensitive: Bool = true
) -> ConditionRow {
    ConditionRow(field: response ? .responseBody : .requestBody, op: op, value: value, caseSensitive: caseSensitive)
}

private func requestInput(_ body: BodyPeek) -> ConditionInput {
    ConditionInput(target: target(), requestHeaders: textHeaders, requestBody: body)
}

private func responseInput(_ body: BodyPeek) -> ConditionInput {
    ConditionInput(
        target: target(), requestHeaders: textHeaders, response: (200, textHeaders), responseBody: body)
}

private func verdict(
    _ rows: [ConditionRow], mode: ConditionGroup.Mode = .all, _ input: ConditionInput,
    allowance: RegexAllowance = RegexAllowance(total: .seconds(100)), cache: PatternCache = calmCache(),
    limits: RulesLimits = RulesLimits()
) -> ConditionVerdict {
    ConditionGroup(mode: mode, rows: rows).evaluate(input, allowance: allowance, cache: cache, limits: limits)
}

private final class CountingClock: @unchecked Sendable {  // guarded by `lock`
    private let lock = NSLock()
    private var count = 0
    var reads: Int { lock.withLock { count } }
    func read() -> Duration {
        lock.withLock {
            count += 1
            return .zero
        }
    }
}

private let slowRegex = "(a|aa)+c"
private let slowText = String(repeating: "a", count: 60) + "b"

private func rule(
    id: UUID = UUID(), when rows: [ConditionRow] = [], _ actions: RuleAction...
) -> Rule {
    Rule(
        id: id, name: "r", enabled: true, groupID: nil, order: 0,
        conditions: ConditionGroup(mode: .all, rows: rows), actions: actions)
}

private func rewrite(_ direction: HTTPMessageDirection, find: String, to replacement: String, regex: Bool = false)
    -> RuleAction
{
    RuleAction(
        .rewriteBody(
            direction: direction,
            BodyRewriteAction(find: find, replacement: replacement, syntax: regex ? .regex : .text)))
}

private let mark = RuleAction(.mark(MarkAction(background: "#FF3B30")))

private func request(_ snapshot: RuleSnapshot, body: BodyPeek) throws -> RequestRuleDecision {
    try RuleEvaluator.request(
        .request(target(), headers: textHeaders), snapshot: snapshot, cache: calmCache(), requestBody: body)
}

@Suite("ConditionBodyPeek")
struct ConditionBodyPeekTests {
    // MARK: classify

    private func plan(
        _ headers: [HeaderField], length: Int? = nil, noBody: Bool = false, limits: RulesLimits = RulesLimits()
    ) -> BodyPeekPlan {
        BodyPeekRules.classify(headers: headers, knownLength: length, isHeadOrNoBody: noBody, limits: limits)
    }

    @Test func classifyTable() {
        let json = [header("Content-Type", "application/json")]
        let cap = RulesLimits().conditionBodyBytes
        #expect(plan(json, length: 10, noBody: true) == .empty)  // HEAD, 204, 304, 1xx
        #expect(plan(json, length: 0) == .empty)
        #expect(plan([header("Content-Type", "text/event-stream"), header("Content-Length", "5")], length: 5) == .skip(.bodySkippedStreaming))
        #expect(plan(json + [header("Transfer-Encoding", "chunked")], length: 5) == .skip(.bodySkippedStreaming))
        #expect(plan(json, length: nil) == .skip(.bodySkippedStreaming))
        #expect(plan(json, length: cap) == .collect)
        #expect(plan(json, length: cap + 1) == .skip(.bodyTooLarge))
        #expect(plan([header("Content-Type", "image/png")], length: 10) == .skip(.bodySkippedNotText))
        #expect(plan(json, length: 10) == .collect)
        #expect(plan([header("Content-Type", "text/html; charset=gbk")], length: 10) == .collect)
    }

    @Test func classifyUsesContentLengthHeaderWhenNoLengthIsGiven() {
        #expect(plan([header("Content-Type", "text/plain"), header("Content-Length", "12")]) == .collect)
        #expect(plan([header("Content-Type", "text/plain"), header("Content-Length", "0")]) == .empty)
    }

    // MARK: text

    @Test func textBodyContainsAndRegex() {
        let input = requestInput(.text("hello {\"vip\":true} world"))
        #expect(verdict([bodyRow(.contains, "\"vip\":true")], input).result == .matched)
        #expect(verdict([bodyRow(.contains, "VIP")], input).result == .noMatch)
        #expect(verdict([bodyRow(.contains, "VIP", caseSensitive: false)], input).result == .matched)
        #expect(verdict([bodyRow(.regex, "vip\"\\s*:\\s*true")], input).result == .matched)
        #expect(verdict([bodyRow(.regex, "vip\"\\s*:\\s*false")], input).result == .noMatch)
        #expect(verdict([bodyRow(.contains, "world", response: true)], responseInput(.text("big world"))).result == .matched)
    }

    @Test func regexBodyUsesFindAndNotTheEightMsAllowance() {
        let spent = RegexAllowance(total: .zero)
        let input = requestInput(.text(String(repeating: "x", count: 20_000) + "needle"))
        // Longer than the 8192-byte cap of header regexes, and the allowance is gone.
        let result = verdict([bodyRow(.regex, "needle$")], input, allowance: spent)
        #expect(result.result == .matched)
        #expect(spent.remaining == .zero)
    }

    @Test func bodyRegexOverTheBodyCapIsAMissNotATimeout() {
        let limits = RulesLimits(conditionBodyBytes: 16)
        let input = requestInput(.text(String(repeating: "x", count: 17) + "needle"))
        #expect(verdict([bodyRow(.regex, "needle")], input, limits: limits).result == .noMatch)
    }

    @Test func bodyRegexUsesBodyBudgetAndBreaker() {
        let clock = StepClock()
        let cache = PatternCache(budget: RegexBudget(clock: { .zero }), bodyBudget: clock.budget)
        let input = requestInput(.text(slowText))
        let row = bodyRow(.regex, slowRegex)
        for _ in 0..<3 { #expect(verdict([row], input, cache: cache).result == .patternTimedOut) }
        #expect(verdict([row], input, cache: cache).result == .patternDisabled)
    }

    @Test func skippedBodyNeverMatchesNotContains() {
        let input = requestInput(.skipped(.bodyTooLarge))
        #expect(verdict([bodyRow(.notContains, "x")], input).result == .noMatch)
        #expect(verdict([bodyRow(.notContains, "x")], mode: .none, input).result == .noMatch)
        #expect(verdict([bodyRow(.isEmpty)], input).result == .noMatch)
    }

    @Test func skippedBodyNotesItsCodeOnce() {
        let input = requestInput(.skipped(.bodySkippedStreaming))
        let both = verdict([bodyRow(.contains, "a"), bodyRow(.contains, "b")], mode: .any, input)
        #expect(both.result == .noMatch)
        #expect(both.notes == [.bodySkippedStreaming])
        let response = verdict([bodyRow(.contains, "a", response: true)], responseInput(.skipped(.bodySkippedOnDisk)))
        #expect(response.notes == [.bodySkippedOnDisk])
    }

    @Test func emptyBodyComparesAsEmptyString() {
        let input = requestInput(.empty)
        #expect(verdict([bodyRow(.isEmpty)], input).result == .matched)
        #expect(verdict([bodyRow(.notContains, "x")], input).result == .matched)
        #expect(verdict([bodyRow(.contains, "x")], input).result == .noMatch)
        #expect(verdict([bodyRow(.equals, "")], input).notes.isEmpty)
    }

    @Test func notCollectedIsUnknownWithoutNote() {
        let input = requestInput(.notCollected)
        let result = verdict([bodyRow(.notContains, "x")], input)
        #expect(result.result == .noMatch)
        #expect(result.notes.isEmpty)
    }

    @Test func bodyRowsAreEvaluatedAfterCheapRows() {
        let counter = CountingClock()
        let cache = PatternCache(budget: RegexBudget(clock: { .zero }), bodyBudget: RegexBudget(clock: { counter.read() }))
        let cheap = ConditionRow(field: .method, op: .equals, value: "DELETE", caseSensitive: true)
        let input = requestInput(.text("abc"))
        // The cheap row fails first, so the body regex never reads the clock.
        #expect(verdict([bodyRow(.regex, "abc"), cheap], input, cache: cache).result == .noMatch)
        #expect(counter.reads == 0)
        #expect(verdict([bodyRow(.regex, "abc")], input, cache: cache).result == .matched)
        #expect(counter.reads > 0)
    }

    // MARK: decoding

    @Test func gzipBodyIsDecodedBeforeComparison() {
        let headers = [header("Content-Type", "text/plain"), header("Content-Encoding", "gzip")]
        let peek = BodyPeek.decode(TestCompression.gzip(Data("compressed vip".utf8)), headers: headers)
        #expect(peek == .text("compressed vip"))
    }

    @Test func undecodableBodyIsSkippedNotText() {
        let gz = [header("Content-Type", "text/plain"), header("Content-Encoding", "gzip")]
        #expect(BodyPeek.decode(Data([1, 2, 3, 4]), headers: gz) == .skipped(.bodySkippedNotText))
        #expect(BodyPeek.decode(Data([0xff, 0xfe, 0xfd]), headers: textHeaders) == .skipped(.bodySkippedNotText))
        let br = [header("Content-Type", "text/plain"), header("Content-Encoding", "zstd")]
        #expect(BodyPeek.decode(Data("x".utf8), headers: br) == .skipped(.bodySkippedNotText))
    }

    @Test func emptyDataDecodesToEmpty() {
        #expect(BodyPeek.decode(Data(), headers: textHeaders) == .empty)
    }

    @Test func decodedTextOverTheCapIsTooLarge() {
        let limits = RulesLimits(conditionBodyBytes: 8)
        #expect(BodyPeek.decode(Data(repeating: 0x61, count: 9), headers: textHeaders, limits: limits) == .skipped(.bodyTooLarge))
    }

    @Test func charsetIsHonoured() throws {
        let gbk = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        let data = try #require("你好，世界".data(using: gbk))
        let peek = BodyPeek.decode(data, headers: [header("Content-Type", "text/html; charset=gbk")])
        #expect(peek == .readOnlyText("你好，世界"))
        #expect(verdict([bodyRow(.contains, "世界")], requestInput(peek)).result == .matched)
    }

    // MARK: applying rewrites to a peek

    private func step(_ find: String, to replacement: String = "b", regex: Bool = false) -> BodyRewriteStep {
        BodyRewriteStep(
            ruleID: UUID(),
            action: BodyRewriteAction(find: find, replacement: replacement, syntax: regex ? .regex : .text))
    }

    @Test func applyingRewritesText() {
        let result = BodyPeek.text("aXa").applying([step("a"), step("X", to: "-")], limits: RulesLimits(), cache: calmCache())
        #expect(result == .text("b-b"))
    }

    @Test func applyingTimeoutMakesTheBodyUnknown() {
        let cache = PatternCache(budget: RegexBudget(clock: { .zero }), bodyBudget: StepClock().budget)
        let result = BodyPeek.text(slowText).applying([step(slowRegex, regex: true)], limits: RulesLimits(), cache: cache)
        #expect(result == .skipped(.bodySkippedNotText))
    }

    @Test func applyingADisabledPatternMakesTheBodyUnknown() throws {
        let cache = PatternCache(budget: RegexBudget(clock: { .zero }), bodyBudget: StepClock().budget)
        let slow = step(slowRegex, regex: true)
        let pattern = try cache.bodyPattern(slow.action)
        for _ in 0..<3 { #expect(pattern.replace(in: slowText, with: "b", scope: .all) == .timedOut) }
        let result = BodyPeek.text(slowText).applying([slow], limits: RulesLimits(), cache: cache)
        #expect(result == .skipped(.bodySkippedNotText))
    }

    @Test func applyingAResultOverTheCapIsTooLarge() {
        let limits = RulesLimits(conditionBodyBytes: 10)
        let result = BodyPeek.text("aaaa").applying([step("a", to: "bbbbbbbb")], limits: limits, cache: calmCache())
        #expect(result == .skipped(.bodyTooLarge))
    }

    @Test func applyingLeavesReadOnlyCharsetTextAlone() {
        let text = BodyPeek.readOnlyText("a")
        #expect(text.applying([step("a")], limits: RulesLimits(), cache: calmCache()) == text)
    }

    @Test func readOnlyCharsetBodyKeepsItsOriginalTextForLaterRules() throws {
        let marked = UUID()
        let snapshot = RuleSnapshot(
            revision: 1,
            rules: [rule(rewrite(.request, find: "a", to: "b")), rule(id: marked, when: [bodyRow(.contains, "a")], mark)])
        let decision = try request(snapshot, body: .readOnlyText("a"))
        #expect(decision.matches.ruleIDs.contains(marked))
        #expect(decision.carry?.requestBody == .readOnlyText("a"))
    }

    @Test func peekNeverStrikesTheRealPatternsBreaker() throws {
        let cache = PatternCache(budget: RegexBudget(clock: { .zero }), bodyBudget: StepClock().budget)
        let slow = rewrite(.request, find: slowRegex, to: "b", regex: true)
        let snapshot = RuleSnapshot(revision: 1, rules: [rule(slow), rule(when: [bodyRow(.contains, "a")], mark)])
        let action = BodyRewriteAction(find: slowRegex, replacement: "b", syntax: .regex)
        for _ in 0..<5 {
            _ = try RuleEvaluator.request(
                .request(target(), headers: textHeaders), snapshot: snapshot, cache: cache,
                requestBody: .text(slowText))
        }
        #expect(!cache.isBodyPatternDisabled(action))
        // The real rewrite still gets all of its own strikes.
        let pattern = try cache.bodyPattern(action)
        #expect(pattern.replace(in: slowText, with: "b", scope: .all) == .timedOut)
        #expect(!cache.isBodyPatternDisabled(action))
    }

    // MARK: through the evaluator

    @Test func laterRuleSeesEarlierBodyRewrite() throws {
        let marked = UUID()
        let snapshot = RuleSnapshot(
            revision: 1,
            rules: [
                rule(rewrite(.request, find: "a", to: "b")),
                rule(id: marked, when: [bodyRow(.contains, "b")], mark),
            ])
        let decision = try request(snapshot, body: .text("a"))
        #expect(decision.matches.ruleIDs.contains(marked))
        #expect(decision.annotations.count == 1)
        #expect(decision.carry?.requestBody == .text("b"))
    }

    @Test func earlierRuleDoesNotSeeALaterRewrite() throws {
        let marked = UUID()
        let snapshot = RuleSnapshot(
            revision: 1,
            rules: [
                rule(id: marked, when: [bodyRow(.contains, "b")], mark),
                rule(rewrite(.request, find: "a", to: "b")),
            ])
        let decision = try request(snapshot, body: .text("a"))
        #expect(!decision.matches.ruleIDs.contains(marked))
    }

    @Test func failedRewriteMakesLaterBodyRowsUnknown() throws {
        let later = UUID()
        let snapshot = RuleSnapshot(
            revision: 1,
            rules: [
                rule(rewrite(.request, find: "(", to: "b", regex: true)),
                rule(id: later, when: [bodyRow(.contains, "a")], mark),
            ])
        let decision = try request(snapshot, body: .text("a"))
        #expect(decision.annotations.isEmpty)
        #expect(decision.matches.outcomes.contains(RuleOutcome(ruleID: later, code: .bodySkippedNotText)))
        #expect(decision.carry?.requestBody == .skipped(.bodySkippedNotText))
    }

    @Test func peekFlowsFromP1ToP2ThroughTheCarry() throws {
        let judgedAtResponse = UUID()
        let snapshot = RuleSnapshot(
            revision: 1,
            rules: [
                rewrite(.request, find: "hello", to: "bye"),
            ].map { rule($0) } + [
                rule(
                    id: judgedAtResponse,
                    when: [
                        bodyRow(.contains, "bye"),
                        ConditionRow(field: .statusCode, op: .equals, value: "200"),
                    ], mark)
            ])
        let first = try request(snapshot, body: .text("hello"))
        #expect(first.carry?.requestBody == .text("bye"))
        #expect(first.annotations.isEmpty)  // Judged at the response.
        let second = try RuleEvaluator.response(
            .response(status: 200, reason: "OK", headers: textHeaders), after: first, snapshot: snapshot,
            cache: calmCache(), responseBody: .text("ok"))
        #expect(second.matches.ruleIDs == [judgedAtResponse])
        #expect(second.carry.body == .text("ok"))
    }

    @Test func responseBodyRowsReadThePeekAndRewritesAccumulate() throws {
        let marked = UUID()
        let snapshot = RuleSnapshot(
            revision: 1,
            rules: [
                rule(rewrite(.response, find: "a", to: "b")),
                rule(id: marked, when: [bodyRow(.contains, "b", response: true)], mark),
            ])
        let first = try request(snapshot, body: .notCollected)
        let second = try RuleEvaluator.response(
            .response(status: 200, reason: "OK", headers: textHeaders), after: first, snapshot: snapshot,
            cache: calmCache(), responseBody: .text("a"))
        #expect(second.matches.ruleIDs.contains(marked))
        #expect(second.carry.body == .text("b"))
    }

    @Test func completionReadsTheCarriedBodies() throws {
        let marked = UUID()
        let snapshot = RuleSnapshot(
            revision: 1,
            rules: [
                rule(
                    id: marked,
                    when: [
                        bodyRow(.contains, "req"), bodyRow(.contains, "resp", response: true),
                        ConditionRow(field: .durationMs, op: .greaterOrEqual, value: "0"),
                    ], mark)
            ])
        let first = try request(snapshot, body: .text("req"))
        let second = try RuleEvaluator.response(
            .response(status: 200, reason: "OK", headers: textHeaders), after: first, snapshot: snapshot,
            cache: calmCache(), responseBody: .text("resp"))
        let done = RuleEvaluator.completion(
            after: first, response: second, snapshot: snapshot, facts: ExchangeFacts(),
            completion: CompletionFacts(state: .completed, durationMilliseconds: 5, responseWireBytes: 4),
            cache: calmCache())
        #expect(done.matches.ruleIDs == [marked])
    }

    @Test func unusedBodyPeekChangesNothing() throws {
        let snapshot = RuleSnapshot(revision: 1, rules: [rule(when: [bodyRow(.contains, "x")], mark)])
        let decision = try request(snapshot, body: .notCollected)
        #expect(decision.matches.ruleIDs.isEmpty)
        #expect(decision.carry?.requestBody == .notCollected)
    }
}
