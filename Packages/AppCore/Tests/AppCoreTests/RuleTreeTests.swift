import Foundation
import RulesEngine
import Testing

@testable import AppCore

/// Builds trees from a compact description so each test reads as the tree it checks.
private final class Fixture {
    var tree = RuleTree(groups: [], rules: [])
    let limits = RulesLimits()

    @discardableResult
    func rule(_ name: String, in parent: UUID? = nil, order: Int, enabled: Bool = true) -> UUID {
        let rule = Rule(name: name, enabled: enabled, groupID: parent, order: order, actions: [RuleAction(.hide)])
        tree.rules.append(rule)
        return rule.id
    }

    @discardableResult
    func group(_ name: String, in parent: UUID? = nil, order: Int) -> UUID {
        let group = RuleGroup(name: name, parentID: parent, order: order)
        tree.groups.append(group)
        return group.id
    }

    @discardableResult
    func move(_ ids: [UUID], toParent parent: UUID?, at index: Int, limits: RulesLimits) -> RuleTree.MoveVerdict {
        tree.move(ids, toParent: parent, at: index, limits: limits)
    }

    @discardableResult
    func step(_ id: UUID, by delta: Int) -> Bool { tree.moveStep(id, by: delta) }

    func addGroup(name: String, inParent parent: UUID?, at index: Int, limits: RulesLimits) -> UUID? {
        tree.addGroup(name: name, inParent: parent, at: index, limits: limits)
    }

    func name(_ id: UUID) -> String {
        tree.rules.first { $0.id == id }?.name ?? tree.groups.first { $0.id == id }?.name ?? "?"
    }

    func names(_ parent: UUID?) -> [String] { tree.siblings(ofParent: parent).map(name) }
}

private func orders(_ tree: RuleTree, _ parent: UUID?) -> [Int] {
    (tree.rules.filter { $0.groupID == parent }.map(\.order) + tree.groups.filter { $0.parentID == parent }.map(\.order)).sorted()
}

private func allParents(_ tree: RuleTree) -> [UUID?] { [nil] + tree.groups.map { Optional($0.id) } }

private func expectContiguous(_ tree: RuleTree, sourceLocation: SourceLocation = #_sourceLocation) {
    for parent in allParents(tree) {
        let found = orders(tree, parent)
        #expect(found == Array(0..<found.count), "parent \(String(describing: parent)): \(found)", sourceLocation: sourceLocation)
    }
}

private func expectValid(_ tree: RuleTree, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(throws: Never.self, sourceLocation: sourceLocation) {
        try RuleSnapshot(revision: 1, groups: tree.groups, rules: tree.rules).validateStructure(limits: RulesLimits())
    }
}

@Suite(.productionChinese) struct RuleTreeTests {
    @Test func orderNumbersStayContiguous() {
        let f = Fixture()
        let a = f.rule("a", order: 0), b = f.rule("b", order: 1)
        let g = f.group("g", order: 2)
        let c = f.rule("c", in: g, order: 0), d = f.rule("d", in: g, order: 1)
        #expect(f.move([a, d], toParent: g, at: 1, limits: f.limits) == .allowed)
        expectContiguous(f.tree)
        #expect(f.move([c], toParent: nil, at: 0, limits: f.limits) == .allowed)
        expectContiguous(f.tree)
        #expect(f.move([b, g], toParent: nil, at: 99, limits: f.limits) == .allowed)
        expectContiguous(f.tree)
        expectValid(f.tree)
    }

    @Test func orderNumbersAreRepairedEvenWhenStoredOnesAreSparseOrDuplicate() {
        let f = Fixture()
        let a = f.rule("a", order: 5), b = f.rule("b", order: 5), c = f.rule("c", order: 9)
        #expect(f.move([c], toParent: nil, at: 0, limits: f.limits) == .allowed)
        expectContiguous(f.tree)
        #expect(f.names(nil) == ["c", "a", "b"])
        _ = (a, b)
    }

    @Test func moveWithinSameParentKeepsOthersRelativeOrder() {
        let f = Fixture()
        let a = f.rule("a", order: 0)
        f.rule("b", order: 1); f.rule("c", order: 2); f.rule("d", order: 3)
        // Index counts the siblings after the moved item is taken out: a goes between c and d.
        #expect(f.move([a], toParent: nil, at: 2, limits: f.limits) == .allowed)
        #expect(f.names(nil) == ["b", "c", "a", "d"])
    }

    @Test func groupCannotMoveIntoItsDescendant() {
        let f = Fixture()
        let g = f.group("g", order: 0)
        let child = f.group("child", in: g, order: 0)
        f.rule("r", in: child, order: 0)
        let before = f.tree
        #expect(f.tree.canMove([g], toParent: child, at: 0, limits: f.limits) == .intoSelf)
        #expect(f.tree.canMove([g], toParent: g, at: 0, limits: f.limits) == .intoSelf)
        #expect(f.move([g], toParent: child, at: 0, limits: f.limits) == .intoSelf)
        #expect(f.tree == before)
    }

    @Test func moveBeyondDepthLimitIsRefused() {
        let f = Fixture()
        let deep = f.group("deep", order: 0)
        let deeper = f.group("deeper", in: deep, order: 0)
        f.group("deepest", in: deeper, order: 0)           // `deep` is a 3-level subtree
        let shallow = f.group("shallow", order: 1)
        let inner = f.group("inner", in: shallow, order: 0)  // depth 2
        let before = f.tree
        #expect(f.move([deep], toParent: inner, at: 0, limits: f.limits) == .tooDeep)
        #expect(f.move([deep], toParent: shallow, at: 0, limits: f.limits) == .tooDeep)
        #expect(f.tree == before)
        // A rule has no depth of its own, so it fits under the deepest group.
        let r = f.rule("r", order: 2)
        #expect(f.move([r], toParent: inner, at: 0, limits: f.limits) == .allowed)
        // A one-level group fits at depth 3.
        let flat = f.group("flat", order: 2)
        #expect(f.move([flat], toParent: inner, at: 0, limits: f.limits) == .allowed)
        expectValid(f.tree)
    }

    @Test func unknownIDsAndTargetsAreRefused() {
        let f = Fixture()
        let a = f.rule("a", order: 0)
        let before = f.tree
        #expect(f.move([UUID()], toParent: nil, at: 0, limits: f.limits) == .unknownTarget)
        #expect(f.move([a], toParent: UUID(), at: 0, limits: f.limits) == .unknownTarget)
        #expect(f.move([], toParent: nil, at: 0, limits: f.limits) == .unknownTarget)
        #expect(f.tree == before)
    }

    @Test func selectionWithParentAndChildMovesOnce() {
        let f = Fixture()
        let g = f.group("g", order: 0)
        let inGroup = f.rule("inGroup", in: g, order: 0)
        let target = f.group("target", order: 1)
        #expect(f.move([inGroup, g], toParent: target, at: 0, limits: f.limits) == .allowed)
        #expect(f.names(target) == ["g"])
        #expect(f.names(g) == ["inGroup"])   // the rule stayed in its group
        #expect(f.tree.rules.count == 1 && f.tree.groups.count == 2)
        expectContiguous(f.tree)
    }

    @Test func movedItemsKeepTheirRelativeOrder() {
        let f = Fixture()
        let a = f.rule("a", order: 0), b = f.rule("b", order: 1), c = f.rule("c", order: 2)
        let g = f.group("g", order: 3)
        let x = f.rule("x", in: g, order: 0)
        // Selected in reverse; they land in tree order, with x (deeper in the tree) after the root rules.
        #expect(f.move([x, c, a], toParent: nil, at: 0, limits: f.limits) == .allowed)
        #expect(f.names(nil) == ["a", "c", "x", "b", "g"])
        _ = b
    }

    @Test func evaluationOrderFollowsTheMovedTree() {
        let f = Fixture()
        let a = f.rule("a", order: 0), b = f.rule("b", order: 1)
        let g = f.group("g", order: 2)
        let c = f.rule("c", in: g, order: 0)
        #expect(f.move([c, b], toParent: nil, at: 0, limits: f.limits) == .allowed)
        let snapshot = RuleSnapshot(revision: 1, groups: f.tree.groups, rules: f.tree.rules)
        #expect(snapshot.evaluationOrder.map(\.id) == [b, c, a])
    }

    @Test func moveStepSwapsWithTheNeighbourAcrossRulesAndGroups() {
        let f = Fixture()
        f.rule("a", order: 0)
        let g = f.group("g", order: 1)
        let c = f.rule("c", order: 2)
        #expect(f.step(g, by: 1))
        #expect(f.names(nil) == ["a", "c", "g"])
        #expect(f.step(c, by: -1))
        #expect(f.names(nil) == ["c", "a", "g"])
        expectContiguous(f.tree)
    }

    @Test func moveStepAtTheEndsReturnsFalse() {
        let f = Fixture()
        let a = f.rule("a", order: 0)
        let b = f.rule("b", order: 1)
        let before = f.tree
        #expect(!f.step(a, by: -1))
        #expect(!f.step(b, by: 1))
        #expect(!f.step(UUID(), by: 1))
        #expect(f.tree == before)
    }

    @Test func insertRuleAtTopRenumbers() {
        let f = Fixture()
        let g = f.group("g", order: 0)
        f.rule("a", in: g, order: 0); f.rule("b", in: g, order: 1)
        let new = Rule(name: "new", groupID: nil, order: 7, actions: [RuleAction(.hide)])
        f.tree.insertRule(new, inParent: g, at: 0)
        #expect(f.names(g) == ["new", "a", "b"])
        #expect(f.tree.rules.first { $0.id == new.id }?.groupID == g)
        expectContiguous(f.tree)
        expectValid(f.tree)
    }

    @Test func addGroupRespectsDepthAndRuleCapLimits() {
        let f = Fixture()
        let one = f.group("one", order: 0)
        let two = f.group("two", in: one, order: 0)
        let three = f.group("three", in: two, order: 0)
        #expect(f.addGroup(name: "x", inParent: three, at: 0, limits: f.limits) == nil)
        #expect(f.addGroup(name: "x", inParent: UUID(), at: 0, limits: f.limits) == nil)
        #expect(f.tree.groups.count == 3)
        let added = f.addGroup(name: "x", inParent: two, at: 0, limits: f.limits)
        #expect(added != nil && f.names(two) == ["x", "three"])
        // The rule cap constrains rules, not groups: a tree at the cap still takes a group.
        let tiny = RulesLimits(ruleCount: 1)
        f.rule("r", order: 5)
        #expect(f.addGroup(name: "y", inParent: nil, at: 0, limits: tiny) != nil)
        expectContiguous(f.tree)
        expectValid(f.tree)
    }

    @Test func duplicatingARuleKeepsEverythingButTheID() throws {
        let f = Fixture()
        let original = Rule(
            name: "multi", enabled: false, groupID: nil, order: 0,
            conditions: ConditionGroup(mode: .any, occurrence: .times(2...3), rows: [ConditionRow(field: .host, op: .equals, value: "a.test")]),
            actions: [RuleAction(.hide, isFinal: true), RuleAction(.delay(milliseconds: 5))], note: "keep me")
        f.tree.rules.append(original)
        f.rule("after", order: 1)
        let result = try #require(f.tree.duplicating(original.id, limits: f.limits))
        let copy = try #require(result.tree.rules.first { $0.id == result.newID })
        #expect(copy.id != original.id)
        var expected = original
        expected.id = copy.id
        expected.order = copy.order
        #expect(copy == expected)
        #expect(result.tree.siblings(ofParent: nil) == [original.id, copy.id, f.tree.rules[1].id])
        expectContiguous(result.tree)
        expectValid(result.tree)
    }

    @Test func duplicatingAGroupDeepCopiesWithFreshIDs() throws {
        let f = Fixture()
        let g = f.group("g", order: 0)
        let inner = f.group("inner", in: g, order: 0)
        let r1 = f.rule("r1", in: g, order: 1), r2 = f.rule("r2", in: inner, order: 0)
        f.rule("tail", order: 1)
        let result = try #require(f.tree.duplicating(g, limits: f.limits))
        let tree = result.tree
        #expect(tree.groups.count == 4 && tree.rules.count == 5)
        #expect(result.newID != g)
        #expect(tree.siblings(ofParent: nil).count == 3)
        #expect(tree.siblings(ofParent: nil)[1] == result.newID)
        let ids = Set(tree.groups.map(\.id) + tree.rules.map(\.id))
        #expect(ids.count == 9, "no id is used twice")
        let copyChildren = tree.siblings(ofParent: result.newID)
        #expect(copyChildren.count == 2 && !Set(copyChildren).isDisjoint(with: tree.rules.map(\.id)))
        for id in copyChildren { #expect(![r1, r2, inner].contains(id)) }
        // The originals are untouched.
        #expect(tree.siblings(ofParent: g) == f.tree.siblings(ofParent: g))
        let copiedInner = try #require(tree.groups.first { $0.parentID == result.newID })
        #expect(copiedInner.name == "inner" && copiedInner.id != inner)
        #expect(tree.rules.filter { $0.groupID == copiedInner.id }.map(\.name) == ["r2"])
        expectContiguous(tree)
        expectValid(tree)
    }

    @Test func duplicatingBeyondRuleCountIsRefused() {
        let f = Fixture()
        let a = f.rule("a", order: 0)
        let g = f.group("g", order: 1)
        f.rule("b", in: g, order: 0); f.rule("c", in: g, order: 1)
        let cap = RulesLimits(ruleCount: 3)
        #expect(f.tree.duplicating(a, limits: cap) == nil)       // 3 + 1 > 3
        #expect(f.tree.duplicating(g, limits: cap) == nil)       // 3 + 2 > 3
        #expect(f.tree.duplicating(UUID(), limits: f.limits) == nil)
        #expect(f.tree.duplicating(a, limits: RulesLimits(ruleCount: 4)) != nil)
    }

    @Test func removingAGroupCountsItsSubtree() {
        let f = Fixture()
        let g = f.group("g", order: 0)
        let inner = f.group("inner", in: g, order: 0)
        f.rule("r1", in: g, order: 1); f.rule("r2", in: inner, order: 0)
        f.rule("keep", order: 1)
        let result = f.tree.removing([g])
        #expect(result.removedRules == 2 && result.removedGroups == 2)
        #expect(result.tree.rules.map(\.name) == ["keep"] && result.tree.groups.isEmpty)
        expectContiguous(result.tree)
        expectValid(result.tree)
    }

    @Test func removingParentAndChildCountsOnce() {
        let f = Fixture()
        let g = f.group("g", order: 0)
        let child = f.rule("child", in: g, order: 0)
        let other = f.rule("other", order: 1)
        let result = f.tree.removing([child, g, other, UUID()])
        #expect(result.removedRules == 2 && result.removedGroups == 1)
        #expect(result.tree.rules.isEmpty && result.tree.groups.isEmpty)
    }

    @Test func removingARuleRenumbersItsSiblings() {
        let f = Fixture()
        f.rule("a", order: 0)
        let b = f.rule("b", order: 1)
        f.rule("c", order: 2)
        let result = f.tree.removing([b])
        #expect(result.removedRules == 1 && result.removedGroups == 0)
        #expect(orders(result.tree, nil) == [0, 1])
    }

    @Test func subtreeCountsIgnoreAncestorSwitches() {
        let f = Fixture()
        let outer = f.group("outer", order: 0)
        let inner = f.group("inner", in: outer, order: 0)
        f.tree.groups[0].enabled = false
        f.rule("on", in: inner, order: 0); f.rule("off", in: inner, order: 1, enabled: false)
        f.rule("direct", in: outer, order: 1)
        let counts = f.tree.subtreeCounts(of: outer)
        #expect(counts.enabled == 2 && counts.total == 3)
        let innerCounts = f.tree.subtreeCounts(of: inner)
        #expect(innerCounts.enabled == 1 && innerCounts.total == 2)
    }

    @Test func depthOfGroupCountsRootChildAsOne() {
        let f = Fixture()
        let one = f.group("one", order: 0)
        let two = f.group("two", in: one, order: 0)
        #expect(f.tree.depth(ofGroup: one) == 1 && f.tree.depth(ofGroup: two) == 2)
        #expect(f.tree.depth(ofGroup: UUID()) == 0)
    }

    @Test func structureStaysValid() throws {
        let f = Fixture()
        let a = f.rule("a", order: 0)
        let g = f.group("g", order: 1)
        let h = f.group("h", in: g, order: 0)
        let r = f.rule("r", in: h, order: 0)
        expectValid(f.tree)
        f.move([a], toParent: h, at: 0, limits: f.limits)
        expectValid(f.tree)
        f.step(r, by: -1)
        expectValid(f.tree)
        f.tree.insertRule(Rule(name: "n", actions: [RuleAction(.hide)]), inParent: g, at: 0)
        expectValid(f.tree)
        _ = f.addGroup(name: "z", inParent: nil, at: 0, limits: f.limits)
        expectValid(f.tree)
        f.tree = try #require(f.tree.duplicating(g, limits: f.limits)).tree
        expectValid(f.tree)
        f.tree = f.tree.removing([h]).tree
        expectValid(f.tree)
        expectContiguous(f.tree)
    }
}
