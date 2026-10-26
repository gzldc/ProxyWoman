import FlowStore
import Foundation
import Testing
import os

@testable import RulesEngine

/// A fake clock: every read advances one millisecond, so a 2 ms budget runs out after a few reads.
private final class TickClock: Sendable {
    private let now = OSAllocatedState()
    var budget: RegexBudget {
        RegexBudget(maxDuration: .milliseconds(2), maxStrikes: 3, clock: { [now] in now.tick() })
    }
}

private final class OSAllocatedState: Sendable {
    private let value = OSAllocatedUnfairLock(initialState: Duration.zero)
    func tick() -> Duration { value.withLock { $0 += .milliseconds(1); return $0 } }
}

private let slowPath = "/" + String(repeating: "a", count: 60) + "b"

private func slowTarget() -> HTTPMessageTarget {
    HTTPMessageTarget(scheme: "https", host: "a.test", port: 443, method: "GET", pathAndQuery: slowPath)
}

private func regexRule(
    _ id: UUID = UUID(), order: Int = 0, direction: HTTPMessageDirection = .request, path: String = "/(a|aa)+c"
) -> LegacyRule {
    LegacyRule(id: id, name: "r", enabled: true, order: order, matcher: RuleMatcher(path: .regex(path)),
         action: .breakpoint(direction: direction, mode: .headers))
}

/// The evaluator tests here run against the frozen pre-2.0 evaluator (`Oracle/LegacyRuleEvaluatorOracle.swift`);
/// `RuleEvaluatorP1Tests`, `RuleEvaluatorP2Tests` and `EvaluatorOracleTests` hold the same promises for the new one.
@Suite("PatternHealth")
struct PatternHealthTests {
    @Test func aTimedOutPatternLeavesAnOutcomeButIsNotCountedAsAMatch() throws {
        let cache = PatternCache(budget: TickClock().budget)
        let id = UUID()
        let decision = try LegacyRuleEvaluator.request(
            .request(slowTarget(), headers: []), snapshot: LegacyRuleSnapshot(revision: 3, rules: [regexRule(id)]), cache: cache)
        #expect(decision.matches.total == 0)
        #expect(decision.matches.ruleIDs.isEmpty)
        #expect(decision.matches.outcomes == [RuleOutcome(ruleID: id, code: .patternTimedOut)])
        #expect(decision.breakpoint == nil)
    }

    @Test func aDisabledPatternIsReportedAsDisabledOnEveryLaterRequest() throws {
        let cache = PatternCache(budget: TickClock().budget)
        let id = UUID()
        let snapshot = LegacyRuleSnapshot(revision: 1, rules: [regexRule(id)])
        let head = HTTPMessageHead.request(slowTarget(), headers: [])
        for _ in 0..<3 { _ = try LegacyRuleEvaluator.request(head, snapshot: snapshot, cache: cache) }
        for _ in 0..<2 {
            let decision = try LegacyRuleEvaluator.request(head, snapshot: snapshot, cache: cache)
            #expect(decision.matches.outcomes == [RuleOutcome(ruleID: id, code: .patternDisabled)])
            #expect(decision.matches.total == 0)
        }
    }

    @Test func aMatchingRuleAndAProblemRuleAreBothReportedInOrder() throws {
        let cache = PatternCache(budget: TickClock().budget)
        let ok = UUID(), bad = UUID()
        let rules = [
            LegacyRule(id: ok, name: "ok", enabled: true, order: 0, matcher: RuleMatcher(),
                 action: .breakpoint(direction: .request, mode: .headers)),
            regexRule(bad, order: 1),
        ]
        let decision = try LegacyRuleEvaluator.request(
            .request(slowTarget(), headers: []), snapshot: LegacyRuleSnapshot(revision: 1, rules: rules), cache: cache)
        #expect(decision.matches.ruleIDs == [ok])
        #expect(decision.matches.outcomes == [
            RuleOutcome(ruleID: ok, code: .applied), RuleOutcome(ruleID: bad, code: .patternTimedOut),
        ])
    }

    @Test func responseRulesReportTheSameWay() throws {
        let cache = PatternCache(budget: TickClock().budget)
        let id = UUID()
        let decision = try LegacyRuleEvaluator.response(
            .response(status: 200, reason: nil, headers: []), request: slowTarget(),
            snapshot: LegacyRuleSnapshot(revision: 1, rules: [regexRule(id, direction: .response)]), cache: cache)
        #expect(decision.matches.outcomes == [RuleOutcome(ruleID: id, code: .patternTimedOut)])
    }

    @Test func aFailingEditStillReportsPatternProblems() {
        let cache = PatternCache(budget: TickClock().budget)
        let bad = UUID(), editor = UUID()
        let rules = [
            regexRule(bad, order: 0),
            LegacyRule(id: editor, name: "e", enabled: true, order: 1, matcher: RuleMatcher(),
                 action: .editHeaders(direction: .request, operations: [.set(name: "Host", value: "x")])),
        ]
        do {
            _ = try LegacyRuleEvaluator.request(
                .request(slowTarget(), headers: []), snapshot: LegacyRuleSnapshot(revision: 1, rules: rules), cache: cache)
            Issue.record("expected the protected-header edit to fail")
        } catch let error as RuleEvaluationError {
            #expect(error.matches.outcomes.contains(RuleOutcome(ruleID: bad, code: .patternTimedOut)))
            #expect(error.matches.outcomes.contains(RuleOutcome(ruleID: editor, code: .rejected)))
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func outcomeCodesAreValidMachineCodes() {
        #expect(RuleOutcomeCode(rawValue: "patternTimedOut") == .patternTimedOut)
        #expect(RuleOutcomeCode(rawValue: "patternDisabled") == .patternDisabled)
    }

    @Test func publishingARulePreparesChangedPatternsOnly() async throws {
        let cache = PatternCache(budget: TickClock().budget)
        let provider = RuleSnapshotProvider(patternCache: cache)
        let changed = UUID(), untouched = UUID()
        let first = [Rule(migrating: regexRule(changed, order: 0)), Rule(migrating: other(untouched, order: 1))]
        provider.publish(RuleSnapshot(revision: 1, rules: first))
        #expect(cache.count == 2, "both regexes were compiled when first published")
        for _ in 0..<3 {
            _ = RuleMatcher(path: .regex("/(a|aa)+c")).evaluate(slowTarget(), status: nil, cache: cache)
            _ = RuleMatcher(path: .regex("/(b|bb)+c")).evaluate(
                HTTPMessageTarget(scheme: "https", host: "a.test", port: 443, method: "GET", pathAndQuery: "/" + String(repeating: "b", count: 60) + "x"),
                status: nil, cache: cache)
        }
        #expect(cache.isRegexDisabled("/(a|aa)+c", caseInsensitive: false))
        #expect(cache.isRegexDisabled("/(b|bb)+c", caseInsensitive: false))
        // Saving changes the first rule's pattern text only: the untouched rule keeps its breaker open.
        let edited = [Rule(migrating: regexRule(changed, order: 0, path: "/(a|aa)+d")), first[1]]
        provider.publish(RuleSnapshot(revision: 2, rules: edited))
        #expect(cache.isRegexDisabled("/(b|bb)+c", caseInsensitive: false))
        // Saving the first rule again with the same matcher re-enables nothing it did not own.
        // A new rule that reuses the disabled text is treated as changed and re-enabled.
        var reused = edited
        reused.append(Rule(migrating: regexRule(UUID(), order: 2)))
        provider.publish(RuleSnapshot(revision: 3, rules: reused))
        #expect(!cache.isRegexDisabled("/(a|aa)+c", caseInsensitive: false))
        #expect(cache.isRegexDisabled("/(b|bb)+c", caseInsensitive: false))
    }

    @Test func publishingATrafficPolicyPreparesNewEntriesOnly() {
        let cache = PatternCache(budget: TickClock().budget)
        let provider = TrafficPolicyProvider(patternCache: cache)
        var policy = TrafficPolicy()
        policy.blockEnabled = true
        policy.blockEntries = [TrafficFilterEntry(matcher: RuleMatcher(path: .regex("/(a|aa)+c")))]
        provider.publish(policy)
        #expect(cache.count == 1)
        for _ in 0..<3 { _ = policy.blockEntries[0].matcher.evaluate(slowTarget(), status: nil, cache: cache) }
        #expect(cache.isRegexDisabled("/(a|aa)+c", caseInsensitive: false))
        policy.noCaching = true  // an unrelated change keeps the breaker open
        provider.publish(policy)
        #expect(cache.isRegexDisabled("/(a|aa)+c", caseInsensitive: false))
        policy.blockEntries = [TrafficFilterEntry(matcher: RuleMatcher(path: .regex("/(a|aa)+c")))]  // a new entry
        provider.publish(policy)
        #expect(!cache.isRegexDisabled("/(a|aa)+c", caseInsensitive: false))
    }

    private func other(_ id: UUID, order: Int) -> LegacyRule {
        LegacyRule(id: id, name: "o", enabled: true, order: order, matcher: RuleMatcher(path: .regex("/(b|bb)+c")),
             action: .breakpoint(direction: .request, mode: .headers))
    }
}
