import FlowStore
import Testing

@testable import AppCore

@Suite(.productionChinese) struct QuickFilterTests {
    @Test func thirteenChipsInOrderWithTitles() {
        #expect(
            QuickFilterChip.allCases.map(\.title)
                == ["全部", "HTTP", "HTTPS", "WebSocket", "JSON", "表单", "XML", "JS", "CSS", "GraphQL", "文档", "媒体", "其他"])
        #expect(QuickFilterChip.allCases.count == 13)
    }

    @Test func mapping() {
        func applied(_ chip: QuickFilterChip) -> FlowFilter {
            var filter = FlowFilter()
            QuickFilter.apply([chip], to: &filter)
            return filter
        }
        #expect(applied(.http).protocols == [.http])
        #expect(applied(.https).protocols == [.https])
        #expect(applied(.websocket).protocols == [.websocket])
        #expect(applied(.json).contentKinds == [.json])
        #expect(applied(.form).contentKinds == [.form])
        #expect(applied(.xml).contentKinds == [.xml])
        #expect(applied(.javascript).contentKinds == [.javascript])
        #expect(applied(.css).contentKinds == [.css])
        #expect(applied(.graphql).contentKinds == [.graphql])
        #expect(applied(.document).contentKinds == [.html])
        #expect(applied(.media).contentKinds == [.image, .font, .media])
        #expect(applied(.other).contentKinds == [.text, .other])
        #expect(applied(.all) == FlowFilter())
        for chip in QuickFilterChip.allCases where chip != .all {
            let filter = applied(chip)
            #expect(filter.protocols.isEmpty != filter.contentKinds.isEmpty, "\(chip) sets exactly one group")
        }
    }

    @Test func allClearsProtocolsAndKinds() {
        var filter = FlowFilter()
        filter.protocols = [.https]
        filter.contentKinds = [.json]
        QuickFilter.apply([.all], to: &filter)
        #expect(filter.protocols.isEmpty)
        #expect(filter.contentKinds.isEmpty)
    }

    @Test func allWinsOverOtherChips() {
        var filter = FlowFilter()
        QuickFilter.apply([.all, .json, .https], to: &filter)
        #expect(filter.protocols.isEmpty)
        #expect(filter.contentKinds.isEmpty)
    }

    @Test func emptySelectionClearsToo() {
        var filter = FlowFilter()
        filter.protocols = [.http]
        filter.contentKinds = [.css]
        QuickFilter.apply([], to: &filter)
        #expect(filter == FlowFilter())
    }

    @Test func sameGroupUnionsAcrossGroupsIntersect() {
        var filter = FlowFilter()
        QuickFilter.apply([.http, .https, .json, .document, .media], to: &filter)
        #expect(filter.protocols == [.http, .https])
        #expect(filter.contentKinds == [.json, .html, .image, .font, .media])
    }

    @Test func intersectionAcrossGroupsOnRealFlows() {
        var filter = FlowFilter()
        QuickFilter.apply([.https, .json], to: &filter)
        func flow(scheme: String, type: String) -> Flow {
            var f = Flow(id: 1, scheme: scheme, method: "GET", host: "x.com", port: 443, path: "/")
            f.responseHeaders = [HeaderField(name: "Content-Type", value: type)]
            return f
        }
        #expect(filter.matches(flow(scheme: "https", type: "application/json")))
        #expect(!filter.matches(flow(scheme: "http", type: "application/json")))
        #expect(!filter.matches(flow(scheme: "https", type: "text/html")))
    }

    @Test func doesNotTouchOtherDimensions() {
        var filter = FlowFilter()
        filter.text = "abc"
        filter.methods = ["POST"]
        filter.statusClasses = [.clientError]
        filter.scope = .host("x.com")
        let before = filter
        QuickFilter.apply([.https, .json], to: &filter)
        #expect(filter.text == before.text)
        #expect(filter.methods == before.methods)
        #expect(filter.statusClasses == before.statusClasses)
        #expect(filter.scope == before.scope)
        QuickFilter.apply([.all], to: &filter)
        #expect(filter.text == before.text)
        #expect(filter.methods == before.methods)
        #expect(filter.statusClasses == before.statusClasses)
        #expect(filter.scope == before.scope)
    }

    @Test func selectionOfEmptyFilterIsAll() {
        #expect(QuickFilter.selection(from: FlowFilter()) == [.all])
    }

    @Test func selectionOfFilterWithOnlyOtherDimensionsIsAll() {
        var filter = FlowFilter()
        filter.text = "abc"
        filter.methods = ["GET"]
        #expect(QuickFilter.selection(from: filter) == [.all])
    }

    @Test func selectionRoundTripsEveryNonAllCombination() {
        let chips = QuickFilterChip.allCases.filter { $0 != .all }
        for mask in 1..<(1 << chips.count) where mask % 7 == 0 || mask.nonzeroBitCount <= 2 {
            let selected = Set(chips.enumerated().filter { mask & (1 << $0.offset) != 0 }.map(\.element))
            var filter = FlowFilter()
            QuickFilter.apply(selected, to: &filter)
            #expect(QuickFilter.selection(from: filter) == selected, "\(selected)")
        }
    }

    @Test func selectionIgnoresPartialMultiKindChips() {
        var filter = FlowFilter()
        filter.contentKinds = [.image, .json]
        #expect(QuickFilter.selection(from: filter) == [.json])
        filter.contentKinds = [.image, .font, .media, .text]
        #expect(QuickFilter.selection(from: filter) == [.media])
    }

    @Test func togglingAllSelectsOnlyAll() {
        #expect(QuickFilter.toggling(.all, in: [.json, .https]) == [.all])
        #expect(QuickFilter.toggling(.all, in: [.all]) == [.all])
    }

    @Test func togglingAChipReplacesAllAndAddsWithinItsGroup() {
        #expect(QuickFilter.toggling(.json, in: [.all]) == [.json])
        #expect(QuickFilter.toggling(.xml, in: [.json]) == [.json, .xml])
        #expect(QuickFilter.toggling(.https, in: [.json]) == [.json, .https])
    }

    @Test func togglingTheLastChipOffFallsBackToAll() {
        #expect(QuickFilter.toggling(.json, in: [.json, .xml]) == [.xml])
        #expect(QuickFilter.toggling(.json, in: [.json]) == [.all])
    }
}

@Suite(.productionChinese) struct QuickFilterAnnotationTests {
    @Test func moreFilterCountCountsEveryExtraFilter() {
        var filter = FlowFilter()
        #expect(QuickFilter.moreFilterCount(filter) == 0)
        filter.methods = ["GET", "POST"]
        filter.statusClasses = [.success]
        #expect(QuickFilter.moreFilterCount(filter) == 3)
        filter.hasMark = true
        filter.rulesModified = true
        #expect(QuickFilter.moreFilterCount(filter) == 5)
        filter.commentContains = "x"
        #expect(QuickFilter.moreFilterCount(filter) == 6)
    }

    @Test func clearAnnotationFiltersLeavesMethodsAndStatuses() {
        var filter = FlowFilter()
        filter.methods = ["GET"]
        filter.statusClasses = [.failed]
        filter.text = "abc"
        filter.hasMark = true
        filter.rulesModified = true
        filter.commentContains = "x"
        QuickFilter.clearAnnotationFilters(&filter)
        #expect(!filter.hasMark && !filter.rulesModified && filter.commentContains.isEmpty)
        #expect(filter.methods == ["GET"] && filter.statusClasses == [.failed] && filter.text == "abc")
    }

    @Test func moreFilterCountIgnoresIds() {
        var filter = FlowFilter()
        QuickFilter.showRuleMatches(ids: [1, 2, 3], in: &filter)
        #expect(QuickFilter.moreFilterCount(filter) == 0)
        filter.methods = ["GET"]
        #expect(QuickFilter.moreFilterCount(filter) == 1)
    }

    @Test func ruleMatchChipLabel() {
        var filter = FlowFilter()
        #expect(QuickFilter.ruleMatchesTitle(filter) == nil)
        QuickFilter.showRuleMatches(ids: [4, 5, 5, 6], in: &filter)
        #expect(filter.ids == [4, 5, 6])
        #expect(QuickFilter.ruleMatchesTitle(filter) == "规则命中 3 条")
        QuickFilter.clearRuleMatches(&filter)
        #expect(filter.ids == nil && QuickFilter.ruleMatchesTitle(filter) == nil)
    }

    @Test func emptyMatchSetStillShowsTheChip() {
        var filter = FlowFilter()
        QuickFilter.showRuleMatches(ids: [], in: &filter)
        #expect(filter.ids == [] && QuickFilter.ruleMatchesTitle(filter) == "规则命中 0 条")
    }
}
