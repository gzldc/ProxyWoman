import Foundation
import Testing

@testable import AppCore

@MainActor @Suite(.productionChinese) struct MainShellModelTests {
    private final class Saved { var values: [InspectorLayout] = [] }

    private func make(_ layout: InspectorLayout = InspectorLayout()) -> (MainShellModel, Saved) {
        let saved = Saved()
        return (MainShellModel(inspector: layout) { saved.values.append($0) }, saved)
    }

    @Test func defaultsAreRequestDetailsExpanded430() {
        let (model, saved) = make()
        #expect(model.page == .traffic)
        #expect(model.inspector.tab == .requestDetails)
        #expect(!model.inspector.isCollapsed)
        #expect(model.inspector.width == 430)
        #expect(model.inspector.sourceBarVisible)
        #expect(saved.values.isEmpty)
    }

    @Test func selectingATabExpandsAndPersists() {
        let (model, saved) = make()
        model.setCollapsed(true)
        model.selectTab(.rules)
        #expect(!model.inspector.isCollapsed)
        #expect(model.inspector.tab == .rules)
        #expect(saved.values.last == model.inspector)
    }

    @Test func focusRequestDetailsSwitchesPageAndTab() {
        var layout = InspectorLayout()
        layout.isCollapsed = true
        layout.tab = .rules
        let (model, saved) = make(layout)
        model.page = .compose
        model.focusRequestDetails()
        #expect(model.page == .traffic)
        #expect(!model.inspector.isCollapsed)
        #expect(model.inspector.tab == .requestDetails)
        #expect(saved.values.last == model.inspector)
    }

    @Test func showRulesSwitchesToTraffic() {
        let (model, saved) = make()
        model.page = .compose
        model.setCollapsed(true)
        model.showRules()
        #expect(model.page == .traffic)
        #expect(!model.inspector.isCollapsed)
        #expect(model.inspector.tab == .rules)
        #expect(saved.values.last == model.inspector)
    }

    @Test func widthIsClampedAndPersisted() {
        let (model, saved) = make()
        model.setWidth(100)
        #expect(model.inspector.width == 320)
        model.setWidth(9999)
        #expect(model.inspector.width == 760)
        #expect(saved.values.last?.width == 760)
    }

    @Test func subPointWidthChangeIsNotPersisted() {
        let (model, saved) = make()
        model.setWidth(430.4)
        #expect(saved.values.isEmpty)
        #expect(model.inspector.width == 430)
    }

    @Test func toggleCollapsedKeepsTab() {
        let (model, saved) = make()
        model.selectTab(.overview)
        model.toggleCollapsed()
        #expect(model.inspector.isCollapsed)
        #expect(model.inspector.tab == .overview)
        model.toggleCollapsed()
        #expect(!model.inspector.isCollapsed)
        #expect(saved.values.last == model.inspector)
    }

    @Test func sourceBarVisibilityPersists() {
        let (model, saved) = make()
        model.setSourceBarVisible(false)
        #expect(!model.inspector.sourceBarVisible)
        #expect(saved.values.last?.sourceBarVisible == false)
    }

    @Test func tabAndPageMetadata() {
        #expect(InspectorTab.allCases == [.overview, .requestDetails, .rules])
        #expect(InspectorTab.rules.titleKey == "inspector.tab.rules")
        #expect(InspectorTab.overview.icon == "chart.bar.doc.horizontal")
        #expect(ShellPage.compose.titleKey == "shell.page.compose")
        #expect(ShellPage.traffic.icon == "eye")
    }
}
