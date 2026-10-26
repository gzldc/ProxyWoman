import FlowStore
import Foundation
import Localization
import RulesEngine
import Testing
import os

@testable import AppCore

private func summary(_ outcomes: [RuleOutcome], ids: [UUID] = []) -> RuleMatchSummary {
    RuleMatchSummary(revision: 1, ruleIDs: ids, total: ids.count, outcomes: outcomes)
}

@Suite(.productionChinese) struct PatternHealthPresentationTests {
    private let named = UUID(), unnamed = UUID(), gone = UUID()

    private func name(_ id: UUID) -> String? {
        if id == named { return "Block ads" }
        if id == unnamed { return "  " }
        return nil
    }

    @Test func eachProblemRuleGetsOneLineWithItsName() {
        let lines = RulePresentation.patternProblemLines(
            summary([
                RuleOutcome(ruleID: named, code: .patternTimedOut),
                RuleOutcome(ruleID: named, code: .patternTimedOut),  // request and response phase: one line
                RuleOutcome(ruleID: unnamed, code: .patternDisabled),
                RuleOutcome(ruleID: gone, code: .patternDisabled),
                RuleOutcome(ruleID: named, code: .applied),
            ]),
            ruleName: name)
        #expect(lines == [
            L10n.format("ruleOutcome.patternTimedOut", "Block ads"),
            L10n.format("ruleOutcome.patternDisabled", L10n.string("rules.list.unnamed")),
            L10n.format("ruleOutcome.patternDisabled", L10n.string("ruleOutcome.unknownRule")),
        ])
        #expect(lines[0].contains("Block ads"))
    }

    @Test func noProvenanceAndOrdinaryOutcomesGiveNoLines() {
        #expect(RulePresentation.patternProblemLines(nil, ruleName: name).isEmpty)
        #expect(RulePresentation.patternProblemLines(
            summary([RuleOutcome(ruleID: named, code: .applied), RuleOutcome(ruleID: named, code: .shadowed)], ids: [named]),
            ruleName: name).isEmpty)
    }

    @Test func englishAndFrenchTextsTakeTheRuleNameAsTheOnlyArgument() throws {
        for key in ["ruleOutcome.patternTimedOut", "ruleOutcome.patternDisabled"] {
            let text = L10n.string(key)
            #expect(text.contains("%1$@") && !text.contains("%2$@"), "\(key)")
        }
    }
}

@MainActor @Suite(.productionChinese) struct PatternHealthMonitorTests {
    private let slow = "/" + String(repeating: "a", count: 60) + "b"
    private var matcher: RuleMatcher { RuleMatcher(path: .regex("/(a|aa)+c")) }

    private func trip(_ cache: PatternCache) {
        let target = HTTPMessageTarget(scheme: "https", host: "a.test", port: 443, method: "GET", pathAndQuery: slow)
        for _ in 0..<3 { _ = matcher.evaluate(target, status: nil, cache: cache) }
    }

    private func slowCache() -> PatternCache {
        // Every clock read is 1 ms later: a 2 ms budget runs out after a few progress callbacks.
        let ticks = TickCounter()
        return PatternCache(budget: RegexBudget(maxDuration: .milliseconds(2), maxStrikes: 3, clock: { ticks.next() }))
    }

    @Test func aTripBumpsTheRevisionAndTheMatcherReportsDisabled() async {
        let cache = slowCache()
        let monitor = PatternHealthMonitor(cache: cache)
        #expect(monitor.revision == 0)
        #expect(!monitor.isDisabled(matcher))
        trip(cache)
        // The observer hops to the main actor; this task queues behind that hop.
        await Task { @MainActor in }.value
        #expect(monitor.revision == 1)
        #expect(monitor.isDisabled(matcher))
        #expect(!monitor.isDisabled(RuleMatcher(path: .regex("/other"))))
        #expect(!monitor.isDisabled(RuleMatcher(hostPattern: "a.test")))
    }

    @Test func aRuleIsDisabledWhenAnyOfItsRowsIs() async {
        let cache = slowCache()
        let monitor = PatternHealthMonitor(cache: cache)
        // Rows of any shape count, in any combination mode, and the rule's other actions do not matter.
        var rule = Rule(
            id: UUID(), name: "r", enabled: true, order: 0, matcher: matcher, action: .rewriteStatus(RewriteStatusAction(status: 404)))
        rule.conditions.mode = .none
        rule.actions.append(RuleAction(.breakpoint(direction: .response, mode: .headers)))
        let other = Rule(
            id: UUID(), name: "o", enabled: true, order: 1, matcher: RuleMatcher(path: .regex("/other")),
            action: .rewriteStatus(RewriteStatusAction(status: 404)))
        #expect(!monitor.isDisabled(rule))
        trip(cache)
        await Task { @MainActor in }.value
        #expect(monitor.isDisabled(rule) && !monitor.isDisabled(other))
        #expect(monitor.isDisabled(rule) == monitor.isDisabled(matcher))
    }

    @Test func monitorsOfDifferentCachesDoNotSeeEachOther() async {
        let first = slowCache(), second = slowCache()
        let one = PatternHealthMonitor(cache: first), two = PatternHealthMonitor(cache: second)
        trip(first)
        await Task { @MainActor in }.value
        #expect(one.revision == 1 && two.revision == 0)
        #expect(one.isDisabled(matcher) && !two.isDisabled(matcher))
    }
}

private final class TickCounter: Sendable {
    private let value = OSAllocatedUnfairLock(initialState: Duration.zero)
    func next() -> Duration { value.withLock { $0 += .milliseconds(1); return $0 } }
}
