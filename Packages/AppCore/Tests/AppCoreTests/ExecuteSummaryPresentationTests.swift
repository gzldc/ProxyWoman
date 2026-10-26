import FlowStore
import Foundation
import Localization
import RulesEngine
import Testing

@testable import AppCore

private let r1 = UUID(), gone = UUID()
private func names(_ id: UUID) -> String? { id == r1 ? "Slow" : nil }

@Suite(.productionChinese) struct ExecuteSummaryPresentationTests {
    @Test func summaryLinesCoverEveryCount() {
        let summary = ExecuteSummary(
            runID: UUID(), rules: [.init(ruleID: r1, flows: 3)], considered: 9, matchedFlows: 3, modifiedFlows: 2,
            hiddenFlows: 1, annotatedFlows: 4, skippedInProgress: 5, notApplicableActions: 6, vanished: 7)
        #expect(ExecuteSummaryPresentation.lines(summary, ruleName: names) == [
            "Slow：命中 3 条会话", "修改了 2 条会话", "隐藏了 1 条", "标记或注释了 4 条", "跳过 5 条进行中的会话",
            "6 个动作不适用于已抓会话（断点、延迟、关闭连接等）", "7 条会话在执行期间被清除",
        ])
    }

    @Test func zeroCountsProduceNoLine() {
        let summary = ExecuteSummary(runID: UUID(), considered: 2)
        #expect(ExecuteSummaryPresentation.lines(summary, ruleName: names).isEmpty)
    }

    @Test func summaryRuleLineUsesUnknownRuleNameForDeletedRules() {
        let summary = ExecuteSummary(runID: UUID(), rules: [.init(ruleID: gone, flows: 1)])
        #expect(ExecuteSummaryPresentation.lines(summary, ruleName: names) == ["已删除的规则：命中 1 条会话"])
    }

    @Test func cancelledSummaryAddsTheCancelledLine() {
        let summary = ExecuteSummary(runID: UUID(), modifiedFlows: 1, wasCancelled: true)
        #expect(ExecuteSummaryPresentation.lines(summary, ruleName: names) == ["已取消（已写入的改动可以撤销）", "修改了 1 条会话"])
    }

    @Test func resultLinesReadTheFlowsExecuteRecord() {
        var flow = Flow(id: 1, scheme: "https", method: "GET", host: "a.test", port: 443, path: "/")
        #expect(ExecuteSummaryPresentation.resultLines(of: flow, ruleName: names).isEmpty)
        flow.execute = ExecuteRecord(
            runID: UUID(), executedAt: Date(timeIntervalSince1970: 1),
            matches: RuleMatchSummary(
                revision: 1, ruleIDs: [r1], total: 1, outcomes: [RuleOutcome(ruleID: r1, code: .notApplicableOffline)]),
            baseline: ExecuteFieldValues(), written: ExecuteFieldValues())
        let lines = ExecuteSummaryPresentation.resultLines(of: flow, ruleName: names)
        #expect(lines.map(\.text) == ["「Slow」的动作不适用于已抓到的会话，已跳过"])
        #expect(lines.map(\.tone) == [.attention])
    }
}
