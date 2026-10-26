import FlowStore
import Foundation
import Localization
import RulesEngine
import Testing

@testable import AppCore

private let r1 = UUID(), r2 = UUID(), r3 = UUID(), gone = UUID()

private func names(_ id: UUID) -> String? {
    switch id {
    case r1: "Slow"
    case r2: "T"
    case r3: "Multi"
    default: nil
    }
}

private func summary(_ outcomes: [RuleOutcome]) -> RuleMatchSummary {
    RuleMatchSummary(revision: 1, ruleIDs: [], total: outcomes.count, outcomes: outcomes)
}

@Suite(.productionChinese) struct RuleResultLinesTests {
    @Test func appliedLinesAndProblemLinesKeepTheirOrder() {
        let lines = RulePresentation.resultLines(
            summary([
                RuleOutcome(ruleID: r1, code: .applied),
                RuleOutcome(ruleID: r2, code: .patternTimedOut),
                RuleOutcome(ruleID: r3, code: .applied, actionIndex: 1),
                RuleOutcome(ruleID: r3, code: RuleOutcomeCode(rawValue: "finalStop")!, actionIndex: 1),
            ]),
            ruleName: names)
        #expect(lines.map(\.text) == [
            "规则「Slow」已应用。",
            L10n.format("ruleOutcome.patternTimedOut", "T"),
            "规则「Multi」的第 2 个动作已应用。",
            L10n.format("ruleOutcome.finalStop", "Multi", 2),
        ])
        #expect(lines.map(\.tone) == [.applied, .attention, .applied, .attention])
    }

    @Test func sameOutcomeIsListedOnce() {
        let lines = RulePresentation.resultLines(
            summary([RuleOutcome(ruleID: r1, code: .applied), RuleOutcome(ruleID: r1, code: .applied)]), ruleName: names)
        #expect(lines.map(\.text) == ["规则「Slow」已应用。"])
    }

    @Test func deletedRulesUsePlaceholderName() {
        let lines = RulePresentation.resultLines(summary([RuleOutcome(ruleID: gone, code: .applied)]), ruleName: names)
        #expect(lines.map(\.text) == ["规则「已删除的规则」已应用。"])
    }

    @Test func rejectedAndUnsupportedUpgradeHaveSentences() {
        let lines = RulePresentation.resultLines(
            summary([RuleOutcome(ruleID: r1, code: .rejected), RuleOutcome(ruleID: r2, code: .unsupportedUpgradeAction)]),
            ruleName: names)
        #expect(lines.map(\.text) == [
            "规则「Slow」的修改没有通过校验，这条流量已被本地拒绝。",
            "规则「T」的这个动作不适用于协议升级（Upgrade / WebSocket）握手，没有执行。",
        ])
        #expect(lines.map(\.tone) == [.attention, .attention])
    }

    @Test func codesWithoutASentenceAreLeftOut() {
        let lines = RulePresentation.resultLines(
            summary([RuleOutcome(ruleID: r1, code: .breakpointLengthCorrected), RuleOutcome(ruleID: r1, code: .breakpointBodyIgnored)]),
            ruleName: names)
        #expect(lines.isEmpty)
    }

    @Test func nilMatchesGiveNoLines() {
        #expect(RulePresentation.resultLines(nil, ruleName: names).isEmpty)
    }

    @Test func outcomeLinesIsUnchanged() {
        let matches = summary([
            RuleOutcome(ruleID: r1, code: .applied), RuleOutcome(ruleID: r2, code: .patternTimedOut),
            RuleOutcome(ruleID: r1, code: .rejected),
        ])
        #expect(RulePresentation.outcomeLines(matches, ruleName: names) == [L10n.format("ruleOutcome.patternTimedOut", "T")])
    }

    @Test func resultLinesIncludeNotApplicableOffline() {
        let lines = RulePresentation.resultLines(
            summary([RuleOutcome(ruleID: r1, code: .notApplicableOffline)]), ruleName: names)
        #expect(lines.map(\.text) == [L10n.format("ruleOutcome.notApplicableOffline", "Slow")])
        #expect(lines.map(\.tone) == [.attention])
    }

    @Test func requestActionsInAResponseJudgedRuleHaveTheirOwnLines() {
        let outcomes = [
            RuleOutcome(ruleID: r3, code: .requestActionVisibleOnly, actionIndex: 0),
            RuleOutcome(ruleID: r3, code: .requestActionSkippedAtResponse, actionIndex: 2),
        ]
        let lines = RulePresentation.resultLines(summary(outcomes), ruleName: names)
        #expect(lines.map(\.text) == [
            L10n.format("ruleOutcome.requestActionVisibleOnly", "Multi", 1),
            L10n.format("ruleOutcome.requestActionSkippedAtResponse", "Multi", 3),
        ])
        #expect(lines.map(\.tone) == [.attention, .attention])
        #expect(RulePresentation.outcomeLines(summary(outcomes), ruleName: names) == lines.map(\.text))
        #expect(lines[0].text.contains("没有发到服务器") && lines[1].text.contains("已跳过"))
        // A rule with one action has no index: it reads as the first.
        let single = RulePresentation.resultLines(summary([RuleOutcome(ruleID: r1, code: .requestActionVisibleOnly)]), ruleName: names)
        #expect(single.map(\.text) == [L10n.format("ruleOutcome.requestActionVisibleOnly", "Slow", 1)])
    }

    @Test func aReturnThatCouldNotReplaceTheProxysOwnResponseHasALine() {
        let outcomes = [RuleOutcome(ruleID: r3, code: .responseAlreadyLocal, actionIndex: 1)]
        let lines = RulePresentation.resultLines(summary(outcomes), ruleName: names)
        #expect(lines.map(\.text) == [L10n.format("ruleOutcome.responseAlreadyLocal", "Multi", 2)])
        #expect(lines.map(\.tone) == [.attention])
        #expect(RulePresentation.outcomeLines(summary(outcomes), ruleName: names) == lines.map(\.text))
    }
}
