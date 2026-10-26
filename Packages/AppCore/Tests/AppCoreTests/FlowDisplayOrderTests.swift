import FlowStore
import Foundation
import Testing
@testable import AppCore

@Suite(.productionChinese) struct FlowDisplayOrderTests {
    private func flows(_ ids: [Int]) -> [Flow] {
        ids.map { Flow(id: $0, scheme: "https", method: "GET", host: "a.test", port: 443, path: "/\($0)") }
    }

    @Test func pausedMoveToTopInTicketOrder() {
        let result = FlowDisplayOrder.pausedFirst(flows([1, 2, 3, 4, 5]), paused: [4, 2])
        #expect(result.map(\.id) == [4, 2, 1, 3, 5])
    }

    @Test func pausedNotVisibleIgnored() {
        let result = FlowDisplayOrder.pausedFirst(flows([1, 2, 3]), paused: [9, 3, 7])
        #expect(result.map(\.id) == [3, 1, 2])
    }

    @Test func noPausedIsIdentity() {
        let visible = flows([5, 3, 9, 1])
        let result = FlowDisplayOrder.pausedFirst(visible, paused: [])
        #expect(result.map(\.id) == [5, 3, 9, 1])
        #expect(result == visible)
    }

    @Test func duplicatePausedIDsAppearOnce() {
        let result = FlowDisplayOrder.pausedFirst(flows([1, 2, 3]), paused: [2, 2, 3])
        #expect(result.map(\.id) == [2, 3, 1])
    }
}
