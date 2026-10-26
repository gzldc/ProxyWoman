import Testing
@testable import AppCore

@Suite(.productionChinese) struct InspectorTabStripPolicyTests {
    @Test func onlySelectedTabShowsTitle() {
        #expect(InspectorTabStripPolicy.showsTitle(selected: true))
        #expect(!InspectorTabStripPolicy.showsTitle(selected: false))
    }

    @Test func toggleLabelFollowsState() {
        #expect(InspectorTabStripPolicy.toggleLabelKey(isCollapsed: true) == "inspector.toggle.show")
        #expect(InspectorTabStripPolicy.toggleLabelKey(isCollapsed: false) == "inspector.toggle.hide")
    }

    @Test func iconTabWidthIsPositive() {
        #expect(InspectorTabStripPolicy.iconTabWidth > 0)
    }
}
