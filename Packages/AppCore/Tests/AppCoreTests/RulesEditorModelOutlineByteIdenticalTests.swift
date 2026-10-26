import Foundation
import RulesEngine
import Testing

@testable import AppCore

/// Saving the tree the window already shows changes nothing in `rules.json` but the revision (R5 review focus 1):
/// the outline's `apply(tree)` round trip neither reorders, renumbers nor drops anything.
@MainActor @Suite(.timeLimit(.minutes(1)), .productionChinese) struct RulesEditorModelOutlineByteIdenticalTests {
    private static func withoutRevision(_ data: Data) -> String {
        let text = String(decoding: data, as: UTF8.self)
        return text.replacingOccurrences(of: #""revision":\d+"#, with: #""revision":0"#, options: .regularExpression)
    }

    @Test func applyingTheUnchangedTreeKeepsTheFileByteIdenticalExceptTheRevision() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let outer = RuleGroup(name: "Outer", order: 0)
        let inner = RuleGroup(name: "Inner", parentID: outer.id, order: 0)
        let rules = [
            Rule(name: "deep", groupID: inner.id, order: 0, actions: [RuleAction(.hide), RuleAction(.delay(milliseconds: 50))]),
            Rule(name: "mid", groupID: outer.id, order: 1, actions: [RuleAction(.hide)], note: "n"),
            Rule(name: "off", enabled: false, order: 1, actions: [RuleAction(.noDecrypt)]),
        ]
        _ = try await fixture.repository.load()
        _ = try await fixture.repository.save(groups: [outer, inner], rules: rules, expectedRevision: 0)
        let before = try Data(contentsOf: fixture.configFile)

        let model = RulesEditorModel(client: fixture.client(), limits: RulesLimits())
        await model.load()
        #expect(await model.apply(model.tree))
        let after = try Data(contentsOf: fixture.configFile)

        #expect(after != before, "the save bumps the revision")
        #expect(Self.withoutRevision(after) == Self.withoutRevision(before))
        #expect(model.groups == [outer, inner] && model.rules == rules)
    }
}
