import Foundation
import RulesEngine
import Testing

@testable import AppCore

/// A save that goes through the old, array-position numbering never changes the priority a tree operation set:
/// the model keeps its `rules` in sibling order, so numbering by position renumbers nothing.
@MainActor @Suite(.timeLimit(.minutes(1)), .productionChinese) struct RulesEditorModelPriorityInvariantTests {
    private static func rule(_ name: String, order: Int, group: UUID? = nil) -> Rule {
        Rule(name: name, groupID: group, order: order, actions: [RuleAction(.hide)])
    }

    private func loaded(_ fixture: RulesFixture, groups: [RuleGroup] = [], rules: [Rule]) async throws -> RulesEditorModel {
        _ = try await fixture.repository.load()
        _ = try await fixture.repository.save(groups: groups, rules: rules, expectedRevision: 0)
        let model = RulesEditorModel(client: fixture.client(), limits: RulesLimits())
        await model.load()
        return model
    }

    private func names(_ model: RulesEditorModel, parent: UUID? = nil) -> [String] {
        model.rules.filter { $0.groupID == parent }.sorted { $0.order < $1.order }.map(\.name)
    }

    @Test func newRuleAtTheTopStaysFirstWhenAnotherRuleIsSwitched() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let a = Self.rule("A", order: 0), b = Self.rule("B", order: 1)
        let model = try await loaded(fixture, rules: [a, b])
        let c = Self.rule("C", order: 0)
        #expect(await model.commitNewRule(c, inParent: nil))
        #expect(await model.setEnabled(id: a.id, enabled: false))
        #expect(names(model) == ["C", "A", "B"])
        #expect(fixture.repository.provider.current().rules.sorted { $0.order < $1.order }.map(\.name) == ["C", "A", "B"])
    }

    @Test func movedItemsKeepTheirPlaceWhenARuleIsSwitched() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let a = Self.rule("A", order: 0), b = Self.rule("B", order: 1), c = Self.rule("C", order: 2)
        let model = try await loaded(fixture, rules: [a, b, c])
        #expect(await model.moveItems([c.id], toParent: nil, at: 0))
        #expect(await model.setEnabled(id: b.id, enabled: false))
        #expect(names(model) == ["C", "A", "B"])
    }

    @Test func duplicateThenExternalCommitKeepsTheCopyRightAfterTheOriginal() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let a = Self.rule("A", order: 0), b = Self.rule("B", order: 1)
        let model = try await loaded(fixture, rules: [a, b])
        #expect(await model.duplicateItem(a.id))
        let fresh = Self.rule("N", order: 0)
        let outcome = await model.commitExternal(rule: fresh, isNew: true, allowEnabledRule: true)
        guard case .saved = outcome else { Issue.record("not saved: \(outcome)"); return }
        #expect(names(model) == ["A", "A", "B", "N"])
        let copy = try #require(model.rules.first { $0.name == "A" && $0.id != a.id })
        #expect(model.rules.first { $0.id == a.id }?.order == 0 && copy.order == 1)
    }

    @Test func loadedRulesAreKeptInSiblingOrderEvenWhenTheFileWasWrittenOutOfOrder() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let model = try await loaded(fixture, rules: [Self.rule("A", order: 1), Self.rule("B", order: 0)])
        #expect(model.rules.map(\.name) == ["B", "A"])
    }
}
