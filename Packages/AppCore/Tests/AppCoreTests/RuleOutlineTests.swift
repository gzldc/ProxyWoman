import Foundation
import RulesEngine
import Testing

@testable import AppCore

@Suite(.productionChinese) struct RuleOutlineTests {
    private struct Tree {
        var tree = RuleTree(groups: [], rules: [])
        @discardableResult
        mutating func rule(_ name: String, in parent: UUID? = nil, order: Int, enabled: Bool = true) -> UUID {
            let rule = Rule(name: name, enabled: enabled, groupID: parent, order: order, actions: [RuleAction(.hide)])
            tree.rules.append(rule)
            return rule.id
        }
        @discardableResult
        mutating func group(_ name: String, in parent: UUID? = nil, order: Int) -> UUID {
            let group = RuleGroup(name: name, parentID: parent, order: order)
            tree.groups.append(group)
            return group.id
        }
    }

    private func outline(_ tree: RuleTree, expanded: Set<UUID> = [], onlyEnabled: Bool = false, query: String = "") -> RuleOutline {
        RuleOutline(tree: tree, expanded: expanded, onlyEnabled: onlyEnabled, query: query) { [$0.name, $0.note ?? ""] }
    }

    private func label(_ row: RuleOutlineRow) -> String {
        switch row.item {
        case .group(let group): "G:" + group.name
        case .rule(let rule): "R:" + rule.name
        }
    }

    @Test func rowsFollowStoredOrderWithRootItemsAtDepthZero() {
        var t = Tree()
        let g = t.group("g", order: 1)
        t.rule("first", order: 0)
        t.rule("inside", in: g, order: 0)
        t.rule("last", order: 2)
        let rows = outline(t.tree, expanded: [g]).rows
        #expect(rows.map(label) == ["R:first", "G:g", "R:inside", "R:last"])
        #expect(rows.map(\.depth) == [0, 0, 1, 0])
        #expect(rows[2].parentID == g && rows[0].parentID == nil)
        #expect(rows.map(\.isExpandable) == [false, true, false, false])
        #expect(rows.allSatisfy { row in if case .group(let g) = row.item { g.name != "未分组" } else { true } })
    }

    @Test func collapsedGroupHidesItsChildren() {
        var t = Tree()
        let g = t.group("g", order: 0)
        let inner = t.group("inner", in: g, order: 0)
        t.rule("deep", in: inner, order: 0)
        #expect(outline(t.tree).rows.map(label) == ["G:g"])
        #expect(outline(t.tree, expanded: [g]).rows.map(label) == ["G:g", "G:inner"])
        #expect(outline(t.tree, expanded: [g, inner]).rows.map(label) == ["G:g", "G:inner", "R:deep"])
        #expect(outline(t.tree, expanded: [g, inner]).rows.map(\.depth) == [0, 1, 2])
    }

    @Test func onlyEnabledHidesDisabledRules() {
        var t = Tree()
        let g = t.group("g", order: 0)
        let empty = t.group("emptyAfterFilter", order: 1)
        t.rule("on", in: g, order: 0)
        t.rule("off", in: g, order: 1, enabled: false)
        t.rule("hidden", in: empty, order: 0, enabled: false)
        t.rule("rootOff", order: 2, enabled: false)
        let result = outline(t.tree, expanded: [g], onlyEnabled: true)
        #expect(result.rows.map(label) == ["G:g", "R:on"])
        #expect(result.isFiltered)
    }

    @Test func queryFiltersByRuleFields() {
        var t = Tree()
        let g = t.group("g", order: 0)
        t.rule("alpha", in: g, order: 0)
        let tagged = Rule(name: "beta", groupID: nil, order: 1, actions: [RuleAction(.hide)], note: "ALPHA note")
        t.tree.rules.append(tagged)
        t.rule("gamma", order: 2)
        let result = outline(t.tree, query: "alpha")
        // Matches are shown with their groups opened, even though nothing is expanded.
        #expect(result.rows.map(label) == ["G:g", "R:alpha", "R:beta"])
        #expect(outline(t.tree, query: "   ").isFiltered == false)
        #expect(outline(t.tree, query: "nothing").rows.isEmpty)
        #expect(outline(t.tree, query: "G").rows.contains { label($0) == "G:g" })
    }

    @Test func filteredOutlineDisablesDragging() {
        var t = Tree()
        t.rule("a", order: 0)
        #expect(!outline(t.tree).isFiltered)
        #expect(outline(t.tree, onlyEnabled: true).isFiltered)
        #expect(outline(t.tree, query: "a").isFiltered)
    }

    @Test func groupRowCarriesEnabledOverTotal() throws {
        var t = Tree()
        let g = t.group("g", order: 0)
        let inner = t.group("inner", in: g, order: 0)
        t.rule("on", in: g, order: 1)
        t.rule("off", in: inner, order: 0, enabled: false)
        t.rule("plain", order: 1)
        let rows = outline(t.tree).rows
        let counts = try #require(rows[0].counts)
        #expect(counts.enabled == 1 && counts.total == 2)
        #expect(rows[1].counts == nil && rows[1].isExpandable == false)
    }
}
