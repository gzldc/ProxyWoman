import AppCore
import FlowStore
import Foundation
import Testing

@testable import ProxyWoman

@MainActor @Suite(.productionChinese) struct FlowListModelHiddenTests {
    private func makeModel() -> FlowListModel {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return FlowListModel(store: FlowStore(bodyDirectory: directory))
    }

    private func flow(_ id: Int, hidden: Bool = false) -> Flow {
        var flow = Flow(id: id, scheme: "https", method: "GET", host: "example.com", port: 443, path: "/\(id)")
        flow.isHidden = hidden
        return flow
    }

    private func upsert(_ flows: Flow...) -> FlowChange {
        FlowChange(cleared: false, upserted: flows)
    }

    @Test func hiddenFlowsLeaveTheVisibleList() {
        let model = makeModel()
        model.apply(upsert(flow(1), flow(2, hidden: true), flow(3)))
        #expect(model.visible.map(\.id) == [1, 3])
    }

    @Test func selectedFlowThatBecomesHiddenIsDeselected() {
        let model = makeModel()
        model.apply(upsert(flow(1), flow(2)))
        model.selectedID = 2
        model.apply(upsert(flow(2, hidden: true)))
        #expect(model.selectedID == nil)
        #expect(model.selectedFlow == nil)
    }

    @Test func selectionInTheHiddenViewSurvivesBatches() {
        let model = makeModel()
        model.apply(upsert(flow(1), flow(2, hidden: true)))
        model.filter.source = .hidden
        model.selectedID = 2
        model.apply(upsert(flow(3)))
        #expect(model.selectedID == 2)
        #expect(model.selectedFlow?.id == 2)
        // Leaving the hidden view makes the hidden flow invisible again.
        model.filter.source = .any
        model.apply(upsert(flow(4)))
        #expect(model.selectedID == nil)
    }

    @Test func shownFlowIsNilForAHiddenFlowAndForAnUnknownId() {
        let model = makeModel()
        model.apply(upsert(flow(1), flow(2, hidden: true)))
        #expect(model.shownFlow(id: 1)?.id == 1)
        #expect(model.shownFlow(id: 2) == nil)
        #expect(model.shownFlow(id: 99) == nil)
    }

    @Test func hiddenCountFollowsTheState() {
        let model = makeModel()
        #expect(model.hiddenCount == 0)
        model.apply(upsert(flow(1), flow(2, hidden: true), flow(3, hidden: true)))
        #expect(model.hiddenCount == 2)
        model.apply(upsert(flow(2)))
        #expect(model.hiddenCount == 1)
    }

    @Test func autoSelectLatestSkipsHiddenFlows() {
        let model = makeModel()
        model.autoSelectsLatest = true
        model.apply(upsert(flow(1), flow(2), flow(3, hidden: true)))
        #expect(model.selectedID == 2)
    }

    @Test func selectedFlowStaysWhenAnotherFlowIsHidden() {
        let model = makeModel()
        model.apply(upsert(flow(1), flow(2)))
        model.selectedID = 1
        model.apply(upsert(flow(2, hidden: true)))
        #expect(model.selectedID == 1)
        #expect(model.selectedFlow?.id == 1)
    }

    @Test func commentColumnPreferenceChangesTheStyle() {
        var preferences = Preferences()
        let hidden = FlowTableStyle(preferences)
        preferences.showCommentColumn = true
        let shown = FlowTableStyle(preferences)
        #expect(hidden != shown)
        #expect(shown.showsCommentColumn)
    }
}
