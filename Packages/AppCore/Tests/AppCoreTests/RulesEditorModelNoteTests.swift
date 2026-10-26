import Foundation
import RulesEngine
import Testing

@testable import AppCore

@MainActor @Suite(.timeLimit(.minutes(1)), .productionChinese) struct RulesEditorModelNoteTests {
    private func loaded(_ fixture: RulesFixture, rules: [Rule]) async throws -> RulesEditorModel {
        _ = try await fixture.repository.load()
        _ = try await fixture.repository.save(groups: [], rules: rules, expectedRevision: 0)
        let model = RulesEditorModel(client: fixture.client(), limits: RulesLimits())
        await model.load()
        return model
    }

    private func rule(_ name: String, order: Int, note: String? = nil) -> Rule {
        Rule(name: name, order: order, actions: [RuleAction(.hide)], note: note)
    }

    @Test func setNoteTrimsAndSaves() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let a = rule("a", order: 0)
        let model = try await loaded(fixture, rules: [a])
        #expect(await model.setNote(ruleID: a.id, note: "  hello \n"))
        #expect(model.rules.first?.note == "hello")
        #expect(fixture.repository.provider.current().rules.first?.note == "hello")
    }

    @Test func emptyNoteClearsToNil() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let a = rule("a", order: 0, note: "old")
        let model = try await loaded(fixture, rules: [a])
        #expect(await model.setNote(ruleID: a.id, note: " \n "))
        #expect(model.rules.first?.note == nil)
    }

    @Test func setNoteOnUnknownRuleFails() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let model = try await loaded(fixture, rules: [rule("a", order: 0)])
        #expect(await model.setNote(ruleID: UUID(), note: "x") == false)
    }

    @Test func noteChangeKeepsEverythingElse() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let a = rule("a", order: 0), b = rule("b", order: 1)
        let model = try await loaded(fixture, rules: [a, b])
        let before = model.rules
        #expect(await model.setNote(ruleID: a.id, note: "n"))
        #expect(model.rules.map(\.id) == before.map(\.id))
        var expected = before[0]; expected.note = "n"
        #expect(model.rules[0] == expected && model.rules[1] == before[1])
    }

    @Test func setNoteOnReadOnlyRuleFails() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let multi = Rule(name: "m", order: 0, actions: [RuleAction(.hide), RuleAction(.hide)])
        let model = try await loaded(fixture, rules: [multi])
        #expect(model.isReadOnly(multi.id))
        #expect(await model.setNote(ruleID: multi.id, note: "x") == false)
        #expect(model.rules.first?.note == nil)
    }
}
