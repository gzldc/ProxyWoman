import FlowStore
import Testing

@testable import AppCore

@Suite(.productionChinese) struct SourceBarItemTests {
    @Test func markedItemSetsSourceAndAllScope() {
        var filter = FlowFilter()
        filter.scope = .host("a.com")
        SourceBarItem.marked.apply(to: &filter)
        #expect(filter.source == .marked)
        #expect(filter.scope == .all)
    }

    @Test func undecryptedHostSetsHostScope() {
        var filter = FlowFilter()
        SourceBarItem.undecryptedHost("a.com").apply(to: &filter)
        #expect(filter.source == .undecrypted)
        #expect(filter.scope == .host("a.com"))
    }

    @Test func applyKeepsOtherFilterDimensions() {
        var filter = FlowFilter()
        filter.text = "abc"
        filter.methods = ["GET"]
        filter.hasMark = true
        SourceBarItem.app("Safari").apply(to: &filter)
        #expect(filter.text == "abc")
        #expect(filter.methods == ["GET"])
        #expect(filter.hasMark)
        #expect(filter.scope == .app("Safari"))
    }

    @Test func itemForFilterRoundTrips() {
        let items: [SourceBarItem] = [
            .all, .app("Safari"), .host("a.com"), .appHost(app: "Safari", host: "a.com"),
            .marked, .hidden, .undecrypted, .undecryptedHost("a.com"),
        ]
        for item in items {
            var filter = FlowFilter()
            item.apply(to: &filter)
            #expect(SourceBarItem.item(for: filter) == item)
        }
    }
}
