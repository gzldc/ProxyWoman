import Foundation
import RulesEngine
import Testing

@testable import AppCore

// Rules 2.0 R1, Task 10: a schema 1…3 file that could not be migrated leaves the rules paused. The window
// offers "retry migration" there and never "reset" (a reset would clear rules whose file is fine).

private func legacyHeaderRule() -> LegacyRule {
    LegacyRule(
        id: UUID(), name: "legacy", enabled: true, order: 0, matcher: RuleMatcher(hostPattern: "a.test"),
        action: .editHeaders(direction: .request, operations: [.set(name: "X-Legacy", value: "1")]))
}

private func writeLegacyFile(_ fixture: RulesFixture, rules: [LegacyRule]) throws -> Data {
    struct LegacyFile: Encodable {
        var schemaVersion = 3
        var revision: UInt64 = 4
        var rules: [LegacyRule]
        var assets: [ManagedAsset] = []
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(LegacyFile(rules: rules))
    try FileManager.default.createDirectory(at: fixture.configDir, withIntermediateDirectories: true)
    try data.write(to: fixture.configFile)
    return data
}

@MainActor @Suite(.timeLimit(.minutes(1)), .productionChinese) struct RulesEditorModelMigrationTests {
    @Test func retryMigrationReloadsAfterAFailure() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let rule = legacyHeaderRule()
        let original = try writeLegacyFile(fixture, rules: [rule])
        let loads = CallCounter()
        let model = RulesEditorModel(client: fixture.client(loads: loads), limits: RulesLimits())

        fixture.fault.arm(.backup)
        await model.load()
        #expect(model.loadState == .unavailable(.migrationFailed))
        #expect(model.rules.isEmpty && !model.canMutate)
        #expect(model.offersMigrationRetry && !model.offersReset)
        #expect(try Data(contentsOf: fixture.configFile) == original)
        // Asking again without a retry reads nothing: the first failure is the answer until the user asks.
        await model.load()
        #expect(loads.value == 1)

        fixture.fault.arm(nil)
        await model.retryMigration()
        #expect(loads.value == 2)
        #expect(model.loadState == .loaded && model.canMutate && model.error == nil)
        #expect(model.rules.map(\.id) == [rule.id] && model.revision == 5)
        #expect(!model.offersMigrationRetry && !model.offersReset)
        #expect(fixture.repository.provider.current().rules.map(\.id) == [rule.id])
    }

    @Test func retryMigrationThatFailsAgainKeepsTheRulesPaused() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let original = try writeLegacyFile(fixture, rules: [legacyHeaderRule()])
        let loads = CallCounter()
        let model = RulesEditorModel(client: fixture.client(loads: loads), limits: RulesLimits())

        fixture.fault.arm(.backup)
        await model.load()
        await model.retryMigration()
        #expect(loads.value == 2)
        #expect(model.loadState == .unavailable(.migrationFailed) && model.offersMigrationRetry)
        #expect(model.rules.isEmpty && !model.canMutate)
        #expect(try Data(contentsOf: fixture.configFile) == original)
    }

    @Test func retryMigrationOnlyActsOnAFailedMigration() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let loads = CallCounter()
        let model = RulesEditorModel(client: fixture.client(loads: loads), limits: RulesLimits())
        await model.retryMigration()
        #expect(loads.value == 0 && model.loadState == .notLoaded, "nothing was loaded yet")
        await model.load()
        await model.retryMigration()
        #expect(loads.value == 1 && model.loadState == .loaded)

        // Another problem is the reset's business, not the retry's.
        let corrupt = RulesFixture(); defer { corrupt.remove() }
        try FileManager.default.createDirectory(at: corrupt.configDir, withIntermediateDirectories: true)
        try Data("{\"schemaVersion\":1,\"rules\":[}".utf8).write(to: corrupt.configFile)
        let corruptLoads = CallCounter()
        let other = RulesEditorModel(client: corrupt.client(loads: corruptLoads), limits: RulesLimits())
        await other.load()
        await other.retryMigration()
        #expect(corruptLoads.value == 1 && other.loadState == .unavailable(.corrupt))
        #expect(other.offersReset && !other.offersMigrationRetry)
    }

    @Test func migrationFailedOffersNoReset() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let original = try writeLegacyFile(fixture, rules: [legacyHeaderRule()])
        let resets = CallCounter()
        var client = fixture.client()
        let reset = client.reset
        client.reset = {
            resets.increment()
            return try await reset()
        }
        let model = RulesEditorModel(client: client, limits: RulesLimits())

        fixture.fault.arm(.backup)
        await model.load()
        #expect(model.loadState == .unavailable(.migrationFailed))
        #expect(!model.offersReset)
        #expect(await model.resetUnavailableConfiguration() == false)
        #expect(resets.value == 0)
        #expect(model.loadState == .unavailable(.migrationFailed) && !model.didReset)
        #expect(try Data(contentsOf: fixture.configFile) == original)

        // The sentence the banner shows names the retry, not a reset.
        #expect(RulesEditorError.unavailable(.migrationFailed).localizationKey == "rules.error.unavailable.migrationFailed")
    }

    /// Ruling (phase review I2): a file made by another version (a later schema, or a schema 4 file this
    /// version cannot decode) is left alone: no reset, which would clear rules that version still reads.
    @Test func unsupportedSchemaOffersNoReset() async throws {
        for text in [
            #"{"assets":[],"groups":[],"revision":9,"rules":[],"schemaVersion":5,"templatesInstalled":false}"#,
            #"{"schemaVersion":4,"revision":9,"rules":[],"assets":[]}"#,
        ] {
            let fixture = RulesFixture(); defer { fixture.remove() }
            try FileManager.default.createDirectory(at: fixture.configDir, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: fixture.configFile)
            let resets = CallCounter()
            var client = fixture.client()
            let reset = client.reset
            client.reset = {
                resets.increment()
                return try await reset()
            }
            let model = RulesEditorModel(client: client, limits: RulesLimits())
            await model.load()
            #expect(model.loadState == .unavailable(.unsupportedSchema))
            #expect(!model.offersReset && !model.offersMigrationRetry)
            #expect(await model.resetUnavailableConfiguration() == false)
            #expect(resets.value == 0 && !model.didReset)
            #expect(try String(contentsOf: fixture.configFile, encoding: .utf8) == text)
            #expect(RulesEditorError.unavailable(.unsupportedSchema).localizationKey == "rules.error.unavailable.unsupportedSchema")
        }
    }

    @Test func otherProblemsKeepOfferingReset() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.configDir, withIntermediateDirectories: true)
        try Data("{\"schemaVersion\":1,\"rules\":[}".utf8).write(to: fixture.configFile)
        let model = RulesEditorModel(client: fixture.client(), limits: RulesLimits())
        await model.load()
        #expect(model.offersReset && !model.offersMigrationRetry)
        #expect(await model.resetUnavailableConfiguration())
        #expect(model.loadState == .loaded && !model.offersReset)
    }
}
