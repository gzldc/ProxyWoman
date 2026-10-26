import AppCore
import FlowStore
import Foundation
import Testing

@testable import ProxyWoman

@MainActor @Suite(.productionChinese) struct FlowListModelRuleMatchesTests {
    private func makeModel() -> FlowListModel {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return FlowListModel(store: FlowStore(bodyDirectory: directory))
    }

    private func flow(_ id: Int) -> Flow {
        Flow(id: id, scheme: "https", method: "GET", host: "example.com", port: 443, path: "/\(id)")
    }

    private func upsert(_ flows: Flow...) -> FlowChange {
        FlowChange(cleared: false, upserted: flows)
    }

    @Test func showRuleMatchesSetsTheIdFilter() {
        let model = makeModel()
        model.showRuleMatches(ids: [2, 3, 3])
        #expect(model.filter.ids == [2, 3])
    }

    @Test func clearingRestoresTheList() {
        let model = makeModel()
        model.apply(upsert(flow(1), flow(2), flow(3)))
        model.showRuleMatches(ids: [2])
        #expect(model.visible.map(\.id) == [2])
        model.clearRuleMatches()
        #expect(model.filter.ids == nil)
        #expect(model.visible.map(\.id) == [1, 2, 3])
    }

    @Test func idFilterShowsOnlyListedRows() {
        let model = makeModel()
        model.apply(upsert(flow(1), flow(2), flow(3), flow(4)))
        model.showRuleMatches(ids: [1, 4, 99])
        #expect(model.visible.map(\.id) == [1, 4])
        model.showRuleMatches(ids: [])
        #expect(model.visible.isEmpty)
    }

    @Test func newMatchingFlowDoesNotAppearInAStaticSnapshot() {
        let model = makeModel()
        model.apply(upsert(flow(1), flow(2)))
        model.showRuleMatches(ids: [1])
        model.apply(upsert(flow(3)))
        #expect(model.visible.map(\.id) == [1])
    }
}
