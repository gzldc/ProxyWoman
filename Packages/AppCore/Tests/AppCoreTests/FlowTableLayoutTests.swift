import Testing

@testable import AppCore

@Suite(.productionChinese) struct FlowTableLayoutTests {
    @Test func urlUsesRemainingViewportWidth() {
        // 830 points after the sidebar; ten other columns total 600, with 33 spacing.
        #expect(FlowTableLayout.urlWidth(viewport: 830, fixedColumns: 600, spacing: 33) == 197)
        #expect(FlowTableLayout.urlWidth(viewport: 1030, fixedColumns: 600, spacing: 33) == 397)
    }

    @Test func resizedFixedColumnReducesOnlyURLWidth() {
        #expect(FlowTableLayout.urlWidth(viewport: 830, fixedColumns: 650, spacing: 33) == 147)
    }

    @Test func narrowViewportKeepsURLReadableAndAllowsScrolling() {
        #expect(FlowTableLayout.urlWidth(viewport: 400, fixedColumns: 600, spacing: 33) == 120)
    }
}
