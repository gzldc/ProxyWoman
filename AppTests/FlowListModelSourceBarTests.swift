import AppCore
import FlowStore
import Foundation
import Testing

@testable import ProxyWoman

@MainActor @Suite(.productionChinese) struct FlowListModelSourceBarTests {
    @Test func tallyFollowsStoreChanges() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = FlowListModel(store: FlowStore(bodyDirectory: directory))
        var connect = Flow(id: 2, scheme: "https", method: "CONNECT", host: "b.com", port: 443, path: "")
        connect.isHidden = false
        var hidden = Flow(id: 3, scheme: "https", method: "GET", host: "c.com", port: 443, path: "/3")
        hidden.isHidden = true
        let plain = Flow(id: 1, scheme: "https", method: "GET", host: "a.com", port: 443, path: "/1")
        model.apply(FlowChange(cleared: false, upserted: [plain, connect, hidden]))
        #expect(model.sourceTally == SourceBarTally.recount([plain, connect, hidden]))
        #expect(model.sourceTally.undecryptedCount == 1)
        #expect(model.sourceTally.hiddenCount == 1)
        var unhidden = hidden
        unhidden.isHidden = false
        model.apply(FlowChange(cleared: false, upserted: [unhidden]))
        #expect(model.sourceTally == SourceBarTally.recount([plain, connect, unhidden]))
    }
}
