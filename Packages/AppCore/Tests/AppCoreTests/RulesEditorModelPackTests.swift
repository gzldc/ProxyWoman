import Foundation
import os
import RulesEngine
import Testing

@testable import AppCore

private final class SelectionLog: Sendable {
    private let state = OSAllocatedUnfairLock<[Set<UUID>?]>(initialState: [])
    var seen: [Set<UUID>?] { state.withLock { $0 } }
    func add(_ selection: Set<UUID>?) { state.withLock { $0.append(selection) } }
}

@MainActor @Suite(.timeLimit(.minutes(1)), .productionChinese) struct RulesEditorModelPackTests {
    // MARK: export

    @Test func exportSelectedAndAllPassTheRightSelection() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let g = RuleGroup(name: "G", order: 0)
        let model = try await loadedModel(fixture, groups: [g], rules: [plainRule("in", group: g.id), plainRule("out", order: 1)])
        let log = SelectionLog()
        let live = RulePackClient.live(assets: fixture.assets, limits: RulesLimits(), appVersion: "1")
        let client = RulePackClient(
            read: live.read,
            export: { selection, groups, rules in
                log.add(selection)
                return try await live.export(selection, groups, rules)
            },
            write: live.write)
        _ = try await model.exportPack(ids: [g.id], client: client)
        let all = try await model.exportPack(ids: nil, client: client)
        #expect(log.seen == [[g.id], nil])
        #expect(all.ruleCount == 2 && all.groupCount == 1)  // nil selection exports everything
    }

    @Test func exportOfAGroupIncludesItsDescendantsThroughTheLiveClient() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let g = RuleGroup(name: "G", order: 0), sub = RuleGroup(name: "S", parentID: g.id, order: 0)
        let model = try await loadedModel(
            fixture, groups: [g, sub],
            rules: [plainRule("a", group: g.id, order: 1), plainRule("b", group: sub.id), plainRule("out", order: 1)])
        let client = RulePackClient.live(assets: fixture.assets, limits: RulesLimits(), appVersion: "1")
        let export = try await model.exportPack(ids: [g.id], client: client)
        #expect(export.ruleCount == 2 && export.groupCount == 2)
        let preview = try RulePackReader.inspect(export.data, limits: RulesLimits())
        #expect(Set(preview.rules.map(\.name)) == ["a", "b"])
    }

    @Test func exportRefusesAnUnloadedModel() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let model = RulesEditorModel(client: fixture.client(), limits: RulesLimits())
        let client = RulePackClient.live(assets: fixture.assets, limits: RulesLimits(), appVersion: "1")
        await #expect(throws: RulePackError.nothingToExport) { try await model.exportPack(ids: nil, client: client) }
    }

    @Test func exportWritesAtomicallyThroughTheClient() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let client = RulePackClient.live(assets: fixture.assets, limits: RulesLimits(), appVersion: "1")
        let target = fixture.root.appendingPathComponent("out.pwrules")
        try await client.write(Data("old".utf8), target)
        let payload = Data(repeating: 7, count: 100_000)
        try await client.write(payload, target)
        #expect(try Data(contentsOf: target) == payload)
        // Only the target remains: the temporary file of an atomic write is gone.
        let names = try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).filter { $0.contains("out") }
        #expect(names == ["out.pwrules"])
    }

    @Test func liveReadReportsTypedErrors() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let client = RulePackClient.live(assets: fixture.assets, limits: RulesLimits(), appVersion: "1")
        let missing = fixture.root.appendingPathComponent("missing.pwrules")
        await #expect(throws: RulePackError.readFailed) { try await client.read(missing) }
        let text = fixture.sourceFile("text.pwrules", "not a zip")
        await #expect(throws: RulePackError.notAPack) { try await client.read(text) }
    }

    // MARK: installed template data

    @Test func alreadyInstalledTemplateDataStaysUntouched() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let g = RuleGroup(name: "Templates", enabled: false, order: 0)
        let keep = plainRule("kept", group: g.id)
        let gone = plainRule("gone", group: g.id, order: 1)
        let model = try await loadedModel(fixture, groups: [g], rules: [keep, gone])
        #expect(model.groups.map(\.name) == ["Templates"])
        #expect(Set(model.rules.map(\.name)) == ["kept", "gone"])
        // The user can still delete a rule inside the installed group, and the group stays.
        #expect(await model.delete(id: gone.id))
        #expect(model.rules.map(\.name) == ["kept"])
        #expect(model.groups.map(\.name) == ["Templates"])
    }
}
