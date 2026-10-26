import AppKit
import AppCore
import FlowStore
import Testing
@testable import ProxyWoman

/// The row view carries the mark fill and the annotation tooltip (a view-based table never asks a cell delegate).
@MainActor @Suite(.productionChinese) struct MarkedRowViewTests {
    private func flow() -> Flow {
        Flow(id: 1, scheme: "https", method: "GET", host: "example.com", port: 443, path: "/")
    }

    @Test func plainFlowHasNoFillAndNoTooltip() {
        let row = MarkedRowView()
        row.toolTip = "stale"
        row.markFill = .red
        row.apply(flow())
        #expect(row.markFill == nil)
        #expect(row.toolTip == nil)
    }

    @Test func commentedAndMarkedFlowGetsFillAndTooltip() throws {
        var marked = flow()
        marked.comment = "look here"
        marked.manualMark = FlowMark(background: "#FF3B30", source: .manual)
        let row = MarkedRowView()
        row.apply(marked)
        #expect(row.markFill != nil)
        let tip = try #require(row.toolTip)
        #expect(tip.contains("look here"))
        #expect(tip == FlowAnnotationPresentation.tooltip(for: marked))
    }

    @Test func noFlowClearsBoth() {
        let row = MarkedRowView()
        row.toolTip = "x"
        row.markFill = .red
        row.apply(nil)
        #expect(row.markFill == nil && row.toolTip == nil)
    }
}
