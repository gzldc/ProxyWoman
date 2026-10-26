import Foundation
import RulesEngine
import Testing

@testable import AppCore

private func item(_ name: String, group: UUID? = nil, order: Int = 0, enabled: Bool = true) -> Rule {
    Rule(name: name, enabled: enabled, groupID: group, order: order, actions: [RuleAction(.hide)])
}

@MainActor
private func loaded(
    _ fixture: RulesFixture, groups: [RuleGroup] = [], rules: [Rule], saves: CallCounter? = nil,
    limits: RulesLimits = RulesLimits()
) async throws -> RulesEditorModel {
    _ = try await fixture.repository.load()
    _ = try await fixture.repository.save(groups: groups, rules: rules, expectedRevision: 0)
    let model = RulesEditorModel(client: fixture.client(saves: saves), limits: limits)
    await model.load()
    return model
}

@MainActor @Suite(.timeLimit(.minutes(1)), .productionChinese) struct RulesEditorModelOutlineTests {
    @Test func moveItemsSavesGroupsAndRulesTogether() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let g1 = RuleGroup(name: "A", order: 0), g2 = RuleGroup(name: "B", order: 1)
        let r = item("r", order: 2)
        let model = try await loaded(fixture, groups: [g1, g2], rules: [r])
        let seen = fixture.repository.provider
        #expect(await model.moveItems([g1.id, r.id], toParent: g2.id, at: 0))
        let saved = seen.current()
        #expect(saved.groups.first { $0.id == g1.id }?.parentID == g2.id)
        #expect(saved.groups.first { $0.id == g1.id }?.order == 0)
        #expect(saved.rules.first { $0.id == r.id }?.groupID == g2.id)
        #expect(saved.rules.first { $0.id == r.id }?.order == 1)
        #expect(model.groups == saved.groups && model.rules == saved.rules)
    }

    @Test func addGroupGoesToTheTopOfItsParent() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let first = item("first", order: 0)
        let model = try await loaded(fixture, rules: [first])
        let id = try #require(await model.addGroup(name: "G", inParent: nil))
        #expect(model.groups.first { $0.id == id }?.order == 0)
        #expect(model.rules.first { $0.id == first.id }?.order == 1)
        #expect(await model.addGroup(name: "x", inParent: UUID()) == nil)
        #expect(model.error != nil)
    }

    @Test func deleteGroupRemovesItsRulesInOneSave() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let g = RuleGroup(name: "G", order: 0)
        let sub = RuleGroup(name: "S", parentID: g.id, order: 0)
        let model = try await loaded(
            fixture, groups: [g, sub], rules: [item("a", group: g.id, order: 1), item("b", group: sub.id), item("keep", order: 1)],
            saves: nil)
        let saves = CallCounter()
        let counted = RulesEditorModel(client: fixture.client(saves: saves), limits: RulesLimits())
        await counted.load()
        #expect(await counted.deleteItems([g.id]))
        #expect(saves.value == 1)
        #expect(counted.groups.isEmpty && counted.rules.map(\.name) == ["keep"])
        #expect(model.rules.count == 3)
    }

    @Test func duplicateMultiActionRuleKeepsAllActions() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let multi = Rule(name: "multi", order: 0, actions: [RuleAction(.hide), RuleAction(.hide)])
        let model = try await loaded(fixture, rules: [multi, item("after", order: 1)])
        #expect(await model.duplicateItem(multi.id))
        #expect(model.rules.count == 3)
        let copy = try #require(model.rules.first { $0.id != multi.id && $0.name == "multi" })
        #expect(copy.actions.count == 2 && copy.order == 1)
        #expect(model.rules.first { $0.name == "after" }?.order == 2)
    }

    @Test func commitNewRuleGoesToTheTopOfTheGroupAndIsEnabled() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let g = RuleGroup(name: "G", order: 0)
        let old = item("old", group: g.id, order: 0)
        let model = try await loaded(fixture, groups: [g], rules: [old])
        let new = item("new")
        #expect(await model.commitNewRule(new, inParent: g.id))
        let saved = try #require(model.rules.first { $0.id == new.id })
        #expect(saved.order == 0 && saved.enabled && saved.groupID == g.id)
        #expect(model.rules.first { $0.id == old.id }?.order == 1)
        #expect(await model.commitNewRule(new, inParent: g.id) == false)
        #expect(await model.commitNewRule(item("x"), inParent: UUID()) == false)
    }

    @Test func commitEditedRuleKeepsPlaceUnlessGroupChanged() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let g = RuleGroup(name: "G", order: 0)
        let a = item("a", order: 1), b = item("b", order: 2), inside = item("in", group: g.id, order: 0)
        let model = try await loaded(fixture, groups: [g], rules: [a, b, inside])
        var edited = b
        edited.name = "b2"
        #expect(await model.commitEditedRule(edited))
        #expect(model.rules.first { $0.id == b.id }?.order == 2 && model.rules.first { $0.id == b.id }?.name == "b2")
        edited.groupID = g.id
        #expect(await model.commitEditedRule(edited))
        #expect(model.rules.first { $0.id == b.id }?.order == 0)
        #expect(model.rules.first { $0.id == inside.id }?.order == 1)
        #expect(model.rules.first { $0.id == a.id }?.order == 1)
    }

    @Test func conflictLeavesLocalTreeUntouched() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let r = item("r")
        let model = try await loaded(fixture, rules: [r])
        _ = try await fixture.repository.save(groups: [], rules: [r, item("other", order: 1)], expectedRevision: 1)
        let before = (model.rules, model.groups)
        #expect(await model.addGroup(name: "G", inParent: nil) == nil)
        #expect(model.conflict != nil && model.error == .conflict)
        #expect(model.rules == before.0 && model.groups == before.1)
    }

    @Test func tooManyRulesIsReportedNotSaved() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let saves = CallCounter()
        let model = try await loaded(
            fixture, rules: [item("a"), item("b", order: 1)], saves: saves, limits: RulesLimits(ruleCount: 2))
        let before = saves.value
        #expect(await model.commitNewRule(item("c"), inParent: nil) == false)
        #expect(model.error == .configurationTooLarge)
        #expect(saves.value == before && model.rules.count == 2)
    }

    @Test func oldSaveStillAppendsAtTheEnd() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let model = try await loaded(fixture, rules: [item("a", order: 0)])
        model.beginDraft(kind: .editHeaders)
        var draft = try #require(model.draft)
        draft.name = "tail"
        draft.match.host = "t.test"
        draft.headerOperations = [HeaderOperationRow(kind: .append, name: "X", value: "1")]
        model.setDraft(draft)
        #expect(await model.save())
        #expect(model.rules.map(\.name) == ["a", "tail"] && model.rules.last?.order == 1)
    }

    @Test func importManagedFileDoesNotTouchTheOldDraft() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let model = try await loaded(fixture, rules: [])
        model.beginDraft(kind: .mapLocal)
        let draft = model.draft
        let asset = try await model.importManagedFile(from: fixture.sourceFile("a.txt"))
        #expect(model.draft == draft && model.importState == .idle)
        #expect(fixture.assetFiles().count == 1)
        await model.discardManagedAssets([asset.id])
        #expect(fixture.assetFiles().isEmpty)
    }
}
