import Foundation
import Testing
@testable import RulesEngine

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0
    func next() -> UUID {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return UUID(uuidString: String(format: "00000000-0000-4000-8000-%012llX", value + 0xF000_0000))!
    }
}

private func preview(
    groups: [RuleGroup] = [], rules: [Rule] = [], assets: [RulePackPreview.AssetEntry] = [], ignored: Int = 0
) -> RulePackPreview {
    RulePackPreview(
        manifest: RulePackManifest(appVersion: "1", exportedAt: "x", groupCount: groups.count, ruleCount: rules.count,
                                   assetCount: assets.count),
        groups: groups, rules: rules, assets: assets, ignoredAssetCount: ignored, archive: nil)
}

private func rule(_ name: String, group: UUID? = nil, order: Int = 0, enabled: Bool = true,
                  kinds: [ActionKind] = [.hide]) -> Rule {
    Rule(name: name, enabled: enabled, groupID: group, order: order, actions: kinds.map { RuleAction($0) })
}

private func plan(_ p: RulePackPreview, into existing: RuleSnapshot = RuleSnapshot(revision: 1, rules: []),
                  limits: RulesLimits = RulesLimits(), live: Bool = true) throws -> RulePackImportPlan {
    let counter = Counter()
    return try RulePackTransform.plan(p, into: existing, wrapperName: "W", limits: limits, breakpointsLive: live,
                                      idGenerator: counter.next)
}

@Suite struct RulePackTransformTests {
    @Test func everyIdIsRegenerated() throws {
        let asset = UUID()
        let g1 = RuleGroup(name: "g1"), g2 = RuleGroup(name: "g2", parentID: g1.id)
        let r1 = rule("a", group: g2.id)
        let r2 = rule("b", kinds: [.returnFile(MapLocalAction(assetID: asset, headers: []))])
        let entry = RulePackPreview.AssetEntry(id: asset, displayName: "f", size: 3, entryName: "assets/x")
        let existing = RuleSnapshot(revision: 1, groups: [RuleGroup(name: "e")], rules: [rule("e")])
        let result = try plan(preview(groups: [g1, g2], rules: [r1, r2], assets: [entry]), into: existing)
        let old = Set([g1.id, g2.id, r1.id, r2.id, asset])
        let imported = Array(result.groups.dropFirst(1)) // wrapper + 2 groups
        let importedRules = Array(result.rules.dropFirst(1))
        let newIDs = Set(imported.map(\.id)).union(importedRules.map(\.id)).union(result.assets.map(\.newID))
        #expect(newIDs.isDisjoint(with: old))
        #expect(newIDs.isDisjoint(with: Set(existing.groups.map(\.id)).union(existing.rules.map(\.id))))
        #expect(newIDs.count == 6)
        let newG2 = result.groups.first { $0.name == "g2" }!
        let newG1 = result.groups.first { $0.name == "g1" }!
        #expect(newG2.parentID == newG1.id)
        #expect(importedRules.first { $0.name == "a" }!.groupID == newG2.id)
        guard case .returnFile(let file) = importedRules.first(where: { $0.name == "b" })!.actions[0].kind else {
            Issue.record("not a file rule"); return
        }
        #expect(file.assetID == result.assets[0].newID)
        #expect(result.assets[0].oldID == asset)
    }

    @Test func wrapperIsDisabledAndAtTheTopOfTheRoot() throws {
        let g = RuleGroup(name: "e", order: 0), g2 = RuleGroup(name: "e2", parentID: g.id, order: 0)
        let existing = RuleSnapshot(revision: 1, groups: [g, g2], rules: [rule("r", order: 1), rule("in", group: g.id, order: 1)])
        let result = try plan(preview(rules: [rule("p")]), into: existing)
        #expect(result.wrapper.order == 0 && !result.wrapper.enabled && result.wrapper.parentID == nil)
        #expect(result.groups.first { $0.id == g.id }!.order == 1)
        #expect(result.groups.first { $0.id == g2.id }!.order == 0)
        #expect(result.rules.first { $0.name == "r" }!.order == 2)
        #expect(result.rules.first { $0.name == "in" }!.order == 1)
        #expect(result.groups.contains(result.wrapper))
    }

    @Test func existingRulesAreUntouched() throws {
        let g = RuleGroup(name: "e", order: 3)
        let r = rule("r", group: g.id, order: 5, kinds: [.breakpoint(direction: .request, mode: .headers)])
        let root = rule("root", order: 1)
        let existing = RuleSnapshot(revision: 7, groups: [g], rules: [r, root])
        let result = try plan(preview(rules: [rule("p")]), into: existing, live: false)
        #expect(Array(result.rules.prefix(2)).map(\.id) == [r.id, root.id])
        #expect(result.rules[0] == r)
        var shifted = root
        shifted.order = 2
        #expect(result.rules[1] == shifted)
        var shiftedGroup = g
        shiftedGroup.order = 4
        #expect(result.groups[0] == shiftedGroup)
    }

    @Test func packRootItemsBecomeChildrenOfTheWrapper() throws {
        let g = RuleGroup(name: "g")
        let result = try plan(preview(groups: [g], rules: [rule("r")]))
        let wrapperID = result.wrapper.id
        #expect(result.groups.first { $0.name == "g" }!.parentID == wrapperID)
        #expect(result.rules.first { $0.name == "r" }!.groupID == wrapperID)
        #expect(result.importedRuleCount == 1 && result.importedGroupCount == 1)
    }

    @Test func nestedStructureAndRelativeOrderSurvive() throws {
        let g = RuleGroup(name: "g", order: 5)
        let c = RuleGroup(name: "c", parentID: g.id, order: 9)
        let rules = [rule("late", group: g.id, order: 20), rule("early", group: g.id, order: 2), rule("top", order: 1)]
        let result = try plan(preview(groups: [g, c], rules: rules))
        func r(_ n: String) -> Rule { result.rules.first { $0.name == n }! }
        func gr(_ n: String) -> RuleGroup { result.groups.first { $0.name == n }! }
        #expect(r("top").order == 0 && gr("g").order == 1)
        #expect(r("early").order == 0 && gr("c").order == 1 && r("late").order == 2)
        #expect(gr("c").parentID == gr("g").id)
    }

    @Test func enabledStateOfImportedRulesIsKept() throws {
        let result = try plan(preview(rules: [rule("on"), rule("off", enabled: false)]))
        #expect(result.rules.first { $0.name == "on" }!.enabled)
        #expect(!result.rules.first { $0.name == "off" }!.enabled)
    }

    @Test func groupsDeeperThanAllowedAreLiftedAndCounted() throws {
        let a = RuleGroup(name: "a"), b = RuleGroup(name: "b", parentID: a.id), c = RuleGroup(name: "c", parentID: b.id)
        let d = RuleGroup(name: "d", parentID: c.id)
        let limits = RulesLimits(groupDepth: 3)
        let result = try plan(preview(groups: [a, b, c, d], rules: [rule("in-c", group: c.id)]), limits: limits)
        func gr(_ n: String) -> RuleGroup { result.groups.first { $0.name == n }! }
        #expect(gr("c").parentID == gr("a").id)
        #expect(gr("d").parentID == gr("a").id)
        #expect(result.liftedGroupCount == 2)
        #expect(result.rules[0].groupID == gr("c").id)
        let snapshot = RuleSnapshot(revision: 1, groups: result.groups, rules: result.rules)
        try snapshot.validateStructure(limits: limits)
    }

    @Test func breakpointRulesAreDisabledWhenBreakpointsAreNotLive() throws {
        let bp = rule("bp", kinds: [.hide, .breakpoint(direction: .response, mode: .fullBody)])
        let p = preview(rules: [bp, rule("plain")])
        let off = try plan(p, live: false)
        #expect(off.breakpointRuleCount == 1)
        #expect(!off.rules.first { $0.name == "bp" }!.enabled)
        #expect(off.rules.first { $0.name == "plain" }!.enabled)
        let live = try plan(p, live: true)
        #expect(live.breakpointRuleCount == 0)
        #expect(live.rules.first { $0.name == "bp" }!.enabled)
    }

    @Test func ruleCapRefusesWithCounts() {
        let limits = RulesLimits(ruleCount: 500)
        let existing = RuleSnapshot(revision: 1, rules: (0..<499).map { rule("e\($0)") })
        #expect(throws: RulePackError.tooManyRules(have: 501, limit: 500)) {
            try plan(preview(rules: [rule("a"), rule("b")]), into: existing, limits: limits)
        }
        #expect(throws: Never.self) { try plan(preview(rules: [rule("a")]), into: existing, limits: limits) }
        let over = RuleSnapshot(revision: 1, rules: (0..<600).map { rule("e\($0)") })
        #expect(throws: RulePackError.tooManyRules(have: 601, limit: 500)) {
            try plan(preview(rules: [rule("a")]), into: over, limits: limits)
        }
        #expect(throws: Never.self) { try plan(preview(), into: over, limits: limits) }
    }

    @Test func nameCollisionsAreFine() throws {
        let existing = RuleSnapshot(revision: 1, groups: [RuleGroup(name: "g")], rules: [rule("r")])
        let result = try plan(preview(groups: [RuleGroup(name: "g")], rules: [rule("r")]), into: existing)
        #expect(result.groups.filter { $0.name == "g" }.count == 2)
        #expect(result.rules.filter { $0.name == "r" }.count == 2)
    }

    @Test func resultPassesStructureValidation() throws {
        let g = RuleGroup(name: "g")
        let existing = RuleSnapshot(revision: 1, groups: [RuleGroup(name: "e")], rules: [rule("e")])
        let result = try plan(preview(groups: [g], rules: [rule("r", group: g.id)]), into: existing)
        try RuleSnapshot(revision: 1, groups: result.groups, rules: result.rules).validateStructure(limits: RulesLimits())
    }

    @Test func planIsDeterministicForEqualInput() throws {
        let g = RuleGroup(name: "g")
        let p = preview(groups: [g], rules: [rule("r", group: g.id)])
        #expect(try plan(p) == plan(p))
    }

    @Test func ignoredAssetsAreCarriedIntoThePlanCounts() throws {
        #expect(try plan(preview(ignored: 3)).ignoredAssetCount == 3)
    }
}
