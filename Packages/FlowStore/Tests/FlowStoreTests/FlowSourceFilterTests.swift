import Foundation
import Testing

@testable import FlowStore

private func mark(_ source: FlowMark.Source) -> FlowMark {
    FlowMark(background: "#FF0000", source: source)!
}

/// 12 samples: 1 plain http, 2 https, 3 manual mark, 4 rule mark, 5 hidden, 6 hidden+marked,
/// 7 CONNECT tunnel a.com, 8 CONNECT failed b.com, 9 hidden CONNECT, 10 failed GET, 11 https a.com, 12 CONNECT tunnel b.com.
private func samples() -> [Flow] {
    func flow(_ id: Int, scheme: String = "http", method: String = "GET", host: String = "x.com") -> Flow {
        Flow(id: id, scheme: scheme, method: method, host: host, port: scheme == "http" ? 80 : 443, path: "/\(id)")
    }
    var all: [Flow] = []
    all.append(flow(1))
    all.append(flow(2, scheme: "https"))
    var f3 = flow(3); f3.manualMark = mark(.manual); all.append(f3)
    var f4 = flow(4); f4.ruleMark = mark(.rule(id: UUID(), name: "r")); all.append(f4)
    var f5 = flow(5); f5.isHidden = true; all.append(f5)
    var f6 = flow(6); f6.isHidden = true; f6.manualMark = mark(.manual); all.append(f6)
    var f7 = flow(7, scheme: "https", method: "CONNECT", host: "a.com"); f7.state = .tunnel; all.append(f7)
    var f8 = flow(8, scheme: "https", method: "CONNECT", host: "b.com"); f8.state = .failed("x"); all.append(f8)
    var f9 = flow(9, scheme: "https", method: "CONNECT", host: "a.com"); f9.state = .tunnel; f9.isHidden = true; all.append(f9)
    var f10 = flow(10); f10.state = .failed("x"); all.append(f10)
    all.append(flow(11, scheme: "https", host: "a.com"))
    var f12 = flow(12, scheme: "https", method: "CONNECT", host: "b.com"); f12.state = .tunnel; all.append(f12)
    return all
}

private func ids(_ filter: FlowFilter) -> [Int] { samples().filter(filter.matches).map(\.id) }

@Suite struct FlowSourceFilterTests {
    @Test func defaultFilterBehavesExactlyAsBefore() {
        #expect(FlowFilter().source == .any)
        #expect(ids(FlowFilter()) == [1, 2, 3, 4, 7, 8, 10, 11, 12])
    }

    @Test func markedMatchesManualOrRuleMark() {
        var filter = FlowFilter()
        filter.source = .marked
        #expect(ids(filter) == [3, 4])
    }

    @Test func hiddenSourceShowsOnlyHiddenEvenWithoutIncludeHidden() {
        var filter = FlowFilter()
        filter.source = .hidden
        #expect(!filter.includeHidden)
        #expect(ids(filter) == [5, 6, 9])
    }

    @Test func undecryptedMatchesConnectRowsOnly() {
        var filter = FlowFilter()
        filter.source = .undecrypted
        #expect(ids(filter) == [7, 8, 12])
    }

    @Test func undecryptedWithHostScope() {
        var filter = FlowFilter()
        filter.source = .undecrypted
        filter.scope = .host("a.com")
        #expect(ids(filter) == [7])
    }

    @Test func listStateRefiltersOnSourceChange() {
        var state = FlowListState()
        state.apply(FlowChange(cleared: false, upserted: samples()))
        let initial = state.visible.map(\.id)
        let hiddenCount = state.hiddenCount
        var filter = FlowFilter()
        filter.source = .hidden
        state.setFilter(filter)
        #expect(state.visible.map(\.id) == [5, 6, 9])
        #expect(state.hiddenCount == hiddenCount)
        state.setFilter(FlowFilter())
        #expect(state.visible.map(\.id) == initial)
    }
}
