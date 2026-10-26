import Foundation
import Localization
import RulesEngine
import Testing

@testable import AppCore

private struct Fixture {
    var tree = RuleTree(groups: [], rules: [])
    @discardableResult
    mutating func rule(
        _ name: String, in parent: UUID? = nil, order: Int, enabled: Bool = true, breakpoint: Bool = false
    ) -> UUID {
        let action = breakpoint ? RuleAction(.breakpoint(direction: .request, mode: .headers)) : RuleAction(.hide)
        let rule = Rule(name: name, enabled: enabled, groupID: parent, order: order, actions: [action])
        tree.rules.append(rule)
        return rule.id
    }
    @discardableResult
    mutating func group(_ name: String, in parent: UUID? = nil, order: Int, enabled: Bool = true) -> UUID {
        let group = RuleGroup(name: name, enabled: enabled, parentID: parent, order: order)
        tree.groups.append(group)
        return group.id
    }
}

private func availability(
    _ selection: [UUID], _ tree: RuleTree, canMutate: Bool = true, live: Bool = true
) -> (canDuplicate: Bool, canDelete: Bool, canToggle: Bool, canOpen: Bool, canMoveUp: Bool, canMoveDown: Bool) {
    RuleOutlineCommands.availability(selection: selection, tree: tree, canMutate: canMutate, liveBreakpoints: live)
}

@Suite(.productionChinese) struct RuleOutlineCommandsTests {
    @Test func noSelectionOffersNothing() {
        var f = Fixture()
        f.rule("a", order: 0)
        let a = availability([], f.tree)
        #expect(!a.canDuplicate && !a.canDelete && !a.canToggle && !a.canOpen && !a.canMoveUp && !a.canMoveDown)
        let unknown = availability([UUID()], f.tree)
        #expect(!unknown.canDelete && !unknown.canOpen)
    }

    @Test func singleRuleOffersAll() {
        var f = Fixture()
        f.rule("a", order: 0)
        let b = f.rule("b", order: 1)
        f.rule("c", order: 2)
        let a = availability([b], f.tree)
        #expect(a.canDuplicate && a.canDelete && a.canToggle && a.canOpen && a.canMoveUp && a.canMoveDown)
    }

    @Test func multiSelectionCannotOpenButCanDeleteAndToggle() {
        var f = Fixture()
        let a = f.rule("a", order: 0)
        let b = f.rule("b", order: 1)
        let result = availability([a, b], f.tree)
        #expect(!result.canOpen && !result.canDuplicate && !result.canMoveUp && !result.canMoveDown)
        #expect(result.canDelete && result.canToggle)
    }

    @Test func breakpointRuleCannotBeEnabledWithoutLiveBreakpoints() {
        var f = Fixture()
        let off = f.rule("off", order: 0, enabled: false, breakpoint: true)
        let on = f.rule("on", order: 1, enabled: true, breakpoint: true)
        #expect(!availability([off], f.tree, live: false).canToggle)
        #expect(availability([off], f.tree, live: true).canToggle)
        // Switching an enabled one off is always possible.
        #expect(availability([on], f.tree, live: false).canToggle)
        // A mixed selection would enable the disabled one.
        #expect(!availability([off, on], f.tree, live: false).canToggle)
        #expect(RuleOutlineCommands.toggleTarget(selection: [off, on], tree: f.tree) == true)
        #expect(RuleOutlineCommands.toggleTarget(selection: [on], tree: f.tree) == false)
    }

    @Test func groupSelectionCanToggleAndDelete() {
        var f = Fixture()
        let g = f.group("g", order: 0, enabled: false)
        f.rule("inside", in: g, order: 0, breakpoint: true)
        let a = availability([g], f.tree, live: false)
        #expect(a.canToggle && a.canDelete && a.canDuplicate)
        #expect(!a.canOpen)
        #expect(RuleOutlineCommands.toggleTarget(selection: [g], tree: f.tree) == true)
    }

    @Test func busyModelOffersNothing() {
        var f = Fixture()
        let a = f.rule("a", order: 0)
        f.rule("b", order: 1)
        let result = availability([a], f.tree, canMutate: false)
        #expect(!result.canDuplicate && !result.canDelete && !result.canToggle && !result.canOpen)
        #expect(!result.canMoveUp && !result.canMoveDown)
    }

    @Test func moveUpDisabledAtTheTopOfItsParent() {
        var f = Fixture()
        let g = f.group("g", order: 0)
        let first = f.rule("first", in: g, order: 0)
        let last = f.rule("last", in: g, order: 1)
        f.rule("root", order: 1)
        let top = availability([first], f.tree)
        #expect(!top.canMoveUp && top.canMoveDown)
        let bottom = availability([last], f.tree)
        #expect(bottom.canMoveUp && !bottom.canMoveDown)
    }

    @Test func newIsOfferedWheneverTheModelCanMutateAndNeedsNoSelection() {
        #expect(RuleOutlineCommands.canCreate(canMutate: true))
        #expect(!RuleOutlineCommands.canCreate(canMutate: false))
    }

    @Test func knownSelectionDropsIdsThatAreNotInTheTree() {
        var f = Fixture()
        let a = f.rule("a", order: 0)
        let g = f.group("g", order: 1)
        let draft = UUID()
        #expect(RuleOutlineCommands.knownSelection([draft, a, g, a], tree: f.tree) == [a, g])
    }

    @Test func aNewItemGoesInTheSelectedGroupOrBesideTheSelectedRule() {
        var f = Fixture()
        let g = f.group("g", order: 0)
        let inside = f.rule("inside", in: g, order: 0)
        let root = f.rule("root", order: 1)
        #expect(RuleOutlineCommands.newItemParent(selection: [g], tree: f.tree) == g)
        #expect(RuleOutlineCommands.newItemParent(selection: [inside], tree: f.tree) == g)
        #expect(RuleOutlineCommands.newItemParent(selection: [root], tree: f.tree) == nil)
        #expect(RuleOutlineCommands.newItemParent(selection: [], tree: f.tree) == nil)
        #expect(RuleOutlineCommands.newItemParent(selection: [g, root], tree: f.tree) == nil)
    }
}

@Suite(.productionChinese) struct RuleOutlinePresentationTests {
    private let zh = Localizer(bundle: L10n.bundle, preferredLanguages: ["zh-Hans"])

    @Test func aSingleActionShowsItsOwnSummary() {
        let rule = Rule(name: "r", order: 0, actions: [RuleAction(.hide)])
        #expect(
            RuleOutlinePresentation.actionText(of: rule, assetName: { _ in nil }, localizer: zh)
                == RulePresentation.actionSummary(of: rule, assetName: { _ in nil }, localizer: zh))
    }

    @Test func severalActionsShowTheFirstAndTheCount() {
        let rule = Rule(name: "r", order: 0, actions: [RuleAction(.hide), RuleAction(.hide), RuleAction(.hide)])
        var first = rule
        first.actions = [rule.actions[0]]
        let head = RulePresentation.actionSummary(of: first, assetName: { _ in nil }, localizer: zh)
        #expect(
            RuleOutlinePresentation.actionText(of: rule, assetName: { _ in nil }, localizer: zh)
                == zh.format("rules.outline.moreActions", arguments: [head, 3]))
    }

    @Test func groupCountReadsEnabledOverTotal() {
        #expect(RuleOutlinePresentation.groupCountText((enabled: 2, total: 5), localizer: zh) == "已启用 2 / 5")
    }

    @Test func everyRefusedVerdictHasAnExplanationExceptAllowedAndUnknown() {
        #expect(RuleOutlinePresentation.dropMessage(.allowed, localizer: zh) == nil)
        #expect(RuleOutlinePresentation.dropMessage(.unknownTarget, localizer: zh) == nil)
        #expect(RuleOutlinePresentation.dropMessage(.intoSelf, localizer: zh) == zh.string("rules.outline.drop.intoSelf"))
        #expect(RuleOutlinePresentation.dropMessage(.tooDeep, localizer: zh) == zh.string("rules.outline.drop.tooDeep"))
        #expect(RuleOutlinePresentation.dropMessage(.tooManyRules, localizer: zh) == zh.string("rules.outline.drop.limit"))
    }

    @Test func deleteQuestionNamesWhatGoes() {
        var f = Fixture()
        let g = f.group("G", order: 0)
        f.rule("in1", in: g, order: 0)
        f.rule("in2", in: g, order: 1)
        let r = f.rule("Solo", order: 1)
        let other = f.rule("Other", order: 2)
        #expect(RuleOutlinePresentation.deleteQuestion(for: [r], tree: f.tree, localizer: zh) == "删除规则「Solo」？")
        #expect(RuleOutlinePresentation.deleteQuestion(for: [g], tree: f.tree, localizer: zh) == "删除分组「G」及其中的 2 条规则？")
        #expect(
            RuleOutlinePresentation.deleteQuestion(for: [g, r, other], tree: f.tree, localizer: zh)
                == "删除所选的 3 项（含其中的 4 条规则）？")
        #expect(RuleOutlinePresentation.deleteQuestion(for: [UUID()], tree: f.tree, localizer: zh) == nil)
    }

    @Test func anUnnamedRuleIsAskedAboutByItsPlaceholder() {
        var f = Fixture()
        let r = f.rule("", order: 0)
        #expect(
            RuleOutlinePresentation.deleteQuestion(for: [r], tree: f.tree, localizer: zh)
                == zh.format("rules.outline.delete.rule", arguments: [zh.string("rules.list.unnamed")]))
    }
}

@Suite(.productionChinese) struct RuleOutlineDropTests {
    private let limits = RulesLimits()

    @Test func droppingBetweenRowsKeepsTheSlotAndSkipsTheMovedRowsAbove() {
        var f = Fixture()
        let a = f.rule("a", order: 0)
        f.rule("b", order: 1)
        f.rule("c", order: 2)
        // Dropping a after c: the table says slot 3; with a removed first, the insertion index is 2.
        let target = RuleOutlineDrop.target(proposedItem: nil, childIndex: 3, moving: [a], tree: f.tree)
        #expect(target == RuleOutlineDrop.Target(parent: nil, tableIndex: 3, insertionIndex: 2))
    }

    @Test func droppingOnAGroupAppendsInsideIt() {
        var f = Fixture()
        let g = f.group("g", order: 0)
        f.rule("x", in: g, order: 0)
        let r = f.rule("r", order: 1)
        let target = RuleOutlineDrop.target(proposedItem: g, childIndex: -1, moving: [r], tree: f.tree)
        #expect(target == RuleOutlineDrop.Target(parent: g, tableIndex: 1, insertionIndex: 1))
    }

    @Test func droppingOnARuleLandsRightAfterIt() {
        var f = Fixture()
        let a = f.rule("a", order: 0)
        let b = f.rule("b", order: 1)
        let c = f.rule("c", order: 2)
        let target = RuleOutlineDrop.target(proposedItem: b, childIndex: -1, moving: [c], tree: f.tree)
        #expect(target == RuleOutlineDrop.Target(parent: nil, tableIndex: 2, insertionIndex: 2))
        _ = a
    }

    @Test func droppingInsideARuleOfAGroupUsesTheGroupAsParent() {
        var f = Fixture()
        let g = f.group("g", order: 0)
        let inside = f.rule("inside", in: g, order: 0)
        let r = f.rule("r", order: 1)
        let target = RuleOutlineDrop.target(proposedItem: inside, childIndex: -1, moving: [r], tree: f.tree)
        #expect(target == RuleOutlineDrop.Target(parent: g, tableIndex: 1, insertionIndex: 1))
    }

    @Test func anUnknownProposalIsNil() {
        var f = Fixture()
        let a = f.rule("a", order: 0)
        #expect(RuleOutlineDrop.target(proposedItem: UUID(), childIndex: 0, moving: [a], tree: f.tree) == nil)
        #expect(RuleOutlineDrop.target(proposedItem: nil, childIndex: 0, moving: [], tree: f.tree) == nil)
    }

    @Test func theVerdictComesFromTheTree() {
        var f = Fixture()
        let g = f.group("g", order: 0)
        let inner = f.group("inner", in: g, order: 0)
        #expect(RuleOutlineDrop.verdict(proposedItem: inner, childIndex: -1, moving: [g], tree: f.tree, limits: limits) == .intoSelf)
        #expect(RuleOutlineDrop.verdict(proposedItem: nil, childIndex: 0, moving: [inner], tree: f.tree, limits: limits) == .allowed)
    }

    @Test func pasteboardIDsRoundTrip() {
        let ids = [UUID(), UUID()]
        let strings = ids.map(RuleOutlineDrop.pasteboardString)
        #expect(RuleOutlineDrop.ids(fromPasteboardStrings: strings + ["junk"]) == ids)
        #expect(RuleOutlineDrop.pasteboardType == "com.proxywoman.rules.items")
    }
}
