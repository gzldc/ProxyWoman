import FlowStore
import Foundation
import Localization
import Testing

@testable import AppCore

private let zh = Localizer(bundle: L10n.bundle, preferredLanguages: ["zh-Hans"])

private func mark(_ hex: String = "#FF3B30", text: String? = nil, source: FlowMark.Source = .manual) -> FlowMark {
    FlowMark(background: hex, text: text, source: source)!
}

private func flow() -> Flow { Flow(id: 1, scheme: "https", method: "GET", host: "h", port: 443, path: "/") }

@Suite(.productionChinese) struct FlowAnnotationPresentationTests {
    @Test func markLinePrefersTheTextOverTheColourName() {
        #expect(FlowAnnotationPresentation.markLine(mark(text: "慢"), localizer: zh) == "标记：慢")
        #expect(FlowAnnotationPresentation.markLine(mark(), localizer: zh) == "标记：红色")
        #expect(FlowAnnotationPresentation.colourName(forHex: "#0A84FF", localizer: zh) == "蓝色")
    }

    @Test func customColourIsNamedCustom() {
        #expect(FlowAnnotationPresentation.colourName(forHex: "#123456", localizer: zh) == "自定义颜色")
        #expect(FlowAnnotationPresentation.markLine(mark("#123456"), localizer: zh) == "标记：自定义颜色")
    }

    @Test func markSourceLineNamesTheRule() {
        let executed = mark(source: .execute(runID: UUID(), ruleID: UUID(), ruleName: "R"))
        #expect(FlowAnnotationPresentation.markSourceLine(executed, localizer: zh) == "Execute · R")
    }

    @Test func sourceLines() {
        let rule = mark(source: .rule(id: UUID(), name: "R"))
        #expect(FlowAnnotationPresentation.markSourceLine(rule, localizer: zh) == "来源：规则「R」")
        #expect(FlowAnnotationPresentation.markSourceLine(mark(), localizer: zh) == "来源：手动标记")
        #expect(FlowAnnotationPresentation.commentLine("好", localizer: zh) == "注释：好")
    }

    @Test func tooltipJoinsMarkSourceAndComment() {
        var f = flow()
        f.manualMark = mark(text: "慢")
        f.comment = "待查"
        #expect(FlowAnnotationPresentation.tooltip(for: f, localizer: zh) == "标记：慢\n来源：手动标记\n注释：待查")
        f.manualMark = nil
        #expect(FlowAnnotationPresentation.tooltip(for: f, localizer: zh) == "注释：待查")
        f.ruleMark = mark(source: .rule(id: UUID(), name: "R"))
        f.comment = nil
        #expect(FlowAnnotationPresentation.tooltip(for: f, localizer: zh) == "标记：红色\n来源：规则「R」")
    }

    @Test func tooltipIsNilWithoutAnnotations() {
        #expect(FlowAnnotationPresentation.tooltip(for: flow(), localizer: zh) == nil)
    }
}
