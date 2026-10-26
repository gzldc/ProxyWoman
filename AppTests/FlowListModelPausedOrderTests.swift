import AppCore
import FlowStore
import Foundation
import Testing

@testable import ProxyWoman

@MainActor @Suite(.productionChinese) struct FlowListModelPausedOrderTests {
    private func makeModel(ids: [Int]) -> FlowListModel {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = FlowListModel(store: FlowStore(bodyDirectory: directory))
        let flows = ids.map { Flow(id: $0, scheme: "https", method: "GET", host: "example.com", port: 443, path: "/\($0)") }
        model.apply(FlowChange(cleared: false, upserted: flows))
        return model
    }

    @Test func displayedPutsPausedFirst() {
        let model = makeModel(ids: [1, 2, 3, 4, 5])
        model.pausedFlowIDs = [4, 2]
        #expect(model.displayed.map(\.id) == [4, 2, 1, 3, 5])
        #expect(model.displayedRow(ofID: 4) == 0)
        #expect(model.displayedRow(ofID: 2) == 1)
        #expect(model.displayedRow(ofID: 1) == 2)
        #expect(model.displayedRow(ofID: 3) == 3)
        #expect(model.displayedRow(ofID: 5) == 4)
        #expect(model.displayedRow(ofID: 9) == nil)
    }

    @Test func displayedRowMatchesDisplayedIndexOverManyPausedSets() {
        let ids = Array(1...24)
        let model = makeModel(ids: ids)
        var seed: UInt64 = 0x2545F4914F6CDD1D
        func next() -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int(seed >> 33)
        }
        for _ in 0..<40 {
            // 0...8 paused ids, some of which are not in the list.
            model.pausedFlowIDs = (0..<(next() % 9)).map { _ in 1 + next() % 30 }
            let rows = model.displayed.map(\.id)
            for id in 0...31 {
                #expect(model.displayedRow(ofID: id) == rows.firstIndex(of: id), "id \(id) paused \(model.pausedFlowIDs)")
            }
        }
    }

    @Test func displayedEqualsVisibleWithoutPaused() {
        let model = makeModel(ids: [1, 2, 3])
        #expect(model.displayed.map(\.id) == model.visible.map(\.id))
        model.pausedFlowIDs = [9]
        #expect(model.displayed.map(\.id) == [1, 2, 3])
        #expect(model.displayedRow(ofID: 2) == 1)
    }

    @Test func selectionSurvivesReorder() {
        let model = makeModel(ids: [1, 5, 9])
        model.selectedID = 5
        model.pausedFlowIDs = [9]
        #expect(model.selectedID == 5)
        #expect(model.displayed.first?.id == 9)
        #expect(model.selectedFlow?.id == 5)
        model.pausedFlowIDs = []
        #expect(model.selectedID == 5)
        #expect(model.displayed.map(\.id) == [1, 5, 9])
    }

    @Test func changingPausedIDsBumpsRevisionOnlyWhenDifferent() {
        let model = makeModel(ids: [1, 2])
        let before = model.revision
        model.pausedFlowIDs = [2]
        #expect(model.revision == before + 1)
        model.pausedFlowIDs = [2]
        #expect(model.revision == before + 1)
    }
}

@MainActor @Suite(.productionChinese) struct FlowListModelSelectEarliestPausedTests {
    private func makeModel() -> FlowListModel {
        FlowListModel(store: FlowStore(bodyDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
    }

    @Test func selectsTheOldestPausedWithoutAnyWindow() {
        let model = makeModel()
        model.selectEarliestPaused(of: [7, 9])
        #expect(model.selectedID == 7)
    }

    @Test func noPauseKeepsTheSelection() {
        let model = makeModel()
        model.selectedID = 3
        model.selectEarliestPaused(of: [])
        #expect(model.selectedID == 3)
    }
}
