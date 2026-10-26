import FlowStore
import Foundation
import Localization
import RulesEngine
import Testing

@testable import AppCore

/// R8F2 F3: every surface that names an action of a rule numbers it by the editor's card, and a stop outcome by the card
/// that carries the stop tick (the last card of a split action).
@MainActor @Suite(.productionChinese) struct RuleCardNumberingTests {
    private let id = UUID()

    /// Stored: 0 mark, 1 header edit with three operations (three cards), 2 hide.
    private func splitRule() -> Rule {
        Rule(
            id: id, name: "Fix price", conditions: ConditionGroup(mode: .all, rows: []),
            actions: [
                RuleAction(.mark(MarkAction(background: "#FF3B30"))),
                RuleAction(.editHeaders(direction: .request, operations: [.set(name: "A", value: "1"), .set(name: "B", value: "2"), .remove(name: "C")])),
                RuleAction(.hide),
            ])
    }

    private func matches(_ outcomes: [RuleOutcome]) -> RuleMatchSummary {
        RuleMatchSummary(revision: 1, ruleIDs: [id], total: 1, outcomes: outcomes)
    }

    @Test func aNewRevisionForgetsTheDocumentsOfRulesThatAreGone() {
        let numbering = RuleCardNumbering()
        let gone = splitRule()
        _ = numbering.index(rule: gone, revision: 1, stored: 0, code: .applied)
        #expect(numbering.cachedRuleCount == 1)
        let other = Rule(id: UUID(), name: "Other", conditions: ConditionGroup(mode: .all, rows: []), actions: [RuleAction(.hide)])
        _ = numbering.index(rule: other, revision: 2, stored: 0, code: .applied)
        #expect(numbering.cachedRuleCount == 1)
        // An outcome of the older revision does not bring back what the newer one dropped.
        #expect(numbering.index(rule: other, revision: 2, stored: 0, code: .applied) == 0)
        #expect(numbering.cachedRuleCount == 1)
    }

    @Test func stopOutcomesUseTheLastCardOfASplitActionAndOthersTheFirst() {
        let numbering = RuleCardNumbering()
        let rule = splitRule()
        #expect(numbering.index(rule: rule, revision: 1, stored: 1, code: .applied) == 1)
        #expect(numbering.index(rule: rule, revision: 1, stored: 1, code: .finalStop) == 3)
        #expect(numbering.index(rule: rule, revision: 1, stored: 1, code: .skippedAfterFinal) == 3)
        #expect(numbering.index(rule: rule, revision: 1, stored: 1, code: .requestActionVisibleOnly) == 1)
        #expect(numbering.index(rule: rule, revision: 1, stored: 2, code: .applied) == 4)
        #expect(numbering.index(rule: rule, revision: 1, stored: 5, code: .applied) == nil)
        #expect(numbering.index(rule: nil, revision: 1, stored: 0, code: .applied) == nil)
    }

    @Test func theDocumentIsBuiltOncePerRuleAndRevision() {
        let numbering = RuleCardNumbering()
        let rule = splitRule()
        for stored in 0..<3 { _ = numbering.index(rule: rule, revision: 1, stored: stored, code: .applied) }
        _ = numbering.index(rule: rule, revision: 1, stored: 1, code: .finalStop)
        #expect(numbering.builds == 1)
        _ = numbering.index(rule: rule, revision: 2, stored: 0, code: .applied)
        #expect(numbering.builds == 2)
    }

    @Test func overviewRulesSectionNumbersByCard() {
        let numbering = RuleCardNumbering()
        let rule = splitRule()
        var flow = Flow(id: 1, scheme: "https", method: "GET", host: "a.test", port: 443, path: "/")
        flow.provenance.ruleMatches = matches([RuleOutcome(ruleID: id, code: .applied, actionIndex: 2), RuleOutcome(ruleID: id, code: .finalStop, actionIndex: 1)])
        let sections = FlowOverviewPresentation.sections(
            for: flow, ruleName: { _ in rule.name },
            cardIndex: { numbering.index(rule: rule, revision: 1, stored: $1, code: $2) })
        let values = sections.first { $0.kind == .rules }?.rows.map(\.value)
        #expect(values == [L10n.format("ruleOutcome.appliedAction", "Fix price", 5), L10n.format("ruleOutcome.finalStop", "Fix price", 4)])
    }

    @Test func executeResultLinesNumberByCard() {
        let numbering = RuleCardNumbering()
        let rule = splitRule()
        var flow = Flow(id: 1, scheme: "https", method: "GET", host: "a.test", port: 443, path: "/")
        flow.execute = ExecuteRecord(
            runID: UUID(), executedAt: Date(timeIntervalSince1970: 1),
            matches: matches([RuleOutcome(ruleID: id, code: .finalStop, actionIndex: 1)]),
            baseline: ExecuteFieldValues(), written: ExecuteFieldValues())
        let lines = ExecuteSummaryPresentation.resultLines(
            of: flow, ruleName: { _ in rule.name },
            cardIndex: { numbering.index(rule: rule, revision: 1, stored: $1, code: $2) })
        #expect(lines.map(\.text) == [L10n.format("ruleOutcome.finalStop", "Fix price", 4)])
    }
}
