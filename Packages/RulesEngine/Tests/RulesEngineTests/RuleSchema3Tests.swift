import FlowStore
import Foundation
import Testing

@testable import RulesEngine

private struct Stack {
    var root: URL
    var configDir: URL { root.appendingPathComponent("config") }
    var configFile: URL { configDir.appendingPathComponent("rules.json") }
    var repository: RuleRepository

    init(root: URL) {
        self.root = root
        let limits = RulesLimits()
        let budgets = OwnedFileBudgets(limits: limits, freeDiskBytes: ample)
        let assets = ManagedAssetStore(
            directory: root.appendingPathComponent("assets"), limits: limits, budgets: budgets)
        repository = RuleRepository(directory: root.appendingPathComponent("config"), assets: assets, limits: limits)
    }

    func writeConfiguration(_ text: String) throws {
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        writeFile(configFile, Data(text.utf8))
    }

    func storedText() throws -> String { try String(contentsOf: configFile, encoding: .utf8) }
}

private let bodyRewriteRule = LegacyRule(
    id: UUID(uuidString: "00000000-0000-0000-0000-0000000000D1")!, name: "body", enabled: true, order: 1,
    matcher: RuleMatcher(hostPattern: "example.com"),
    action: .rewriteBody(direction: .response, BodyRewriteAction(find: "foo", replacement: "bar")))

private let statusRewriteRule = LegacyRule(
    id: UUID(uuidString: "00000000-0000-0000-0000-0000000000D2")!, name: "status", enabled: false, order: 2,
    matcher: RuleMatcher(hostPattern: "example.com"),
    action: .rewriteStatus(RewriteStatusAction(status: 404)))

private let schema2Rule = LegacyRule(
    id: UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!, name: "advanced", enabled: true, order: 0,
    matcher: RuleMatcher(hostPattern: #"(a|b)\.example\.com"#, path: .wildcard("/api/*"), hostSyntax: .regex),
    action: .breakpoint(direction: .request, mode: .headers))

/// Pinned once when schema 3 was introduced; do not regenerate. `_1` is the compiler-synthesized key of
/// the second (unlabeled) associated value of `rewriteBody`.
private let bodyRewriteRuleJSON = #"{"action":{"rewriteBody":{"_1":{"caseSensitive":true,"find":"foo","replacement":"bar","scope":"all","syntax":"text"},"direction":"response"}},"enabled":true,"id":"00000000-0000-0000-0000-0000000000D1","matcher":{"hostPattern":"example.com","path":{"any":{}}},"name":"body","order":1}"#
private let statusRewriteRuleJSON = #"{"action":{"rewriteStatus":{"_0":{"includeLocalResponses":false,"status":404}}},"enabled":false,"id":"00000000-0000-0000-0000-0000000000D2","matcher":{"hostPattern":"example.com","path":{"any":{}}},"name":"status","order":2}"#
private let schema3GoldenFile =
    #"{"assets":[],"revision":1,"rules":["# + bodyRewriteRuleJSON + "," + statusRewriteRuleJSON + #"],"schemaVersion":3}"#

private let schema4Suffix = #""schemaVersion":4,"templatesInstalled":false}"#

@Suite("RuleSchema3") struct RuleSchema3Tests {
    /// Rules 2.0 (spec 5.1): saves write schema 4 whatever the rules contain.
    @Test func rulesWithoutNewActionsWriteSchema4() async throws {
        let root = makeTempDirectory(); defer { removeTree(root) }
        let stack = Stack(root: root)
        _ = try await stack.repository.load()
        let saved = try await stack.repository.save(
            groups: [], rules: [Rule(migrating: goldenLiteralRule)], expectedRevision: 0)
        #expect(saved.schemaVersion == 4)
        #expect(try stack.storedText().hasSuffix(schema4Suffix))
    }

    @Test func schema2RulesWriteSchema4() async throws {
        let root = makeTempDirectory(); defer { removeTree(root) }
        let stack = Stack(root: root)
        _ = try await stack.repository.load()
        let saved = try await stack.repository.save(groups: [], rules: [Rule(migrating: schema2Rule)], expectedRevision: 0)
        #expect(saved.schemaVersion == 4)
        #expect(try stack.storedText().hasSuffix(schema4Suffix))
        #expect(try await Stack(root: root).repository.load().rules == [Rule(migrating: schema2Rule)])
    }

    @Test func rewriteRulesWriteSchema4() async throws {
        let root = makeTempDirectory(); defer { removeTree(root) }
        let stack = Stack(root: root)
        _ = try await stack.repository.load()
        for rule in [bodyRewriteRule, statusRewriteRule] {
            let saved = try await stack.repository.save(
                groups: [], rules: [Rule(migrating: rule)], expectedRevision: stack.repository.provider.current().revision)
            #expect(saved.schemaVersion == 4)
            #expect(try stack.storedText().hasSuffix(schema4Suffix))
        }
    }

    /// The pinned schema 3 bytes still decode, now through the migration: the same rules (renumbered to
    /// their positions) at the next revision, and a byte-exact backup of the old file.
    @Test func schema3GoldenSampleStillMigrates() async throws {
        let other = makeTempDirectory(); defer { removeTree(other) }
        let reader = Stack(root: other)
        try reader.writeConfiguration(schema3GoldenFile)
        let loaded = try await reader.repository.load()
        var body = bodyRewriteRule, status = statusRewriteRule
        body.order = 0
        status.order = 1
        #expect(loaded.rules == [Rule(migrating: body), Rule(migrating: status)])
        #expect(loaded.schemaVersion == 4 && loaded.revision == 2)
        let backups = names(in: reader.configDir).filter { $0.hasPrefix("rules.v3-backup-") }
        #expect(backups.count == 1)
        if let backup = backups.first {
            #expect(try String(contentsOf: reader.configDir.appendingPathComponent(backup), encoding: .utf8) == schema3GoldenFile)
        }
    }

    @Test func schema3RoundTripsThroughRepository() async throws {
        let root = makeTempDirectory(); defer { removeTree(root) }
        let stack = Stack(root: root)
        _ = try await stack.repository.load()
        let rewrites = [Rule(migrating: bodyRewriteRule), Rule(migrating: statusRewriteRule)]
        let saved = try await stack.repository.save(groups: [], rules: rewrites, expectedRevision: 0)
        let reloaded = try await Stack(root: root).repository.load()
        #expect(reloaded == saved)
        #expect(reloaded.rules == rewrites)

        // Dropping the rewrite rules: the file stays schema 4.
        _ = try await stack.repository.save(
            groups: [], rules: [Rule(migrating: goldenLiteralRule)], expectedRevision: saved.revision)
        #expect(try stack.storedText().hasSuffix(schema4Suffix))
    }

    @Test func schema3IsAcceptedAndMigrated() async throws {
        let root = makeTempDirectory(); defer { removeTree(root) }
        let stack = Stack(root: root)
        try stack.writeConfiguration(#"{"assets":[],"revision":9,"rules":[],"schemaVersion":3}"#)
        let snapshot = try await stack.repository.load()
        #expect(snapshot.revision == 10 && snapshot.rules.isEmpty)
    }

    @Test func schema5IsUnsupportedAndFileUntouched() async throws {
        let root = makeTempDirectory(); defer { removeTree(root) }
        let stack = Stack(root: root)
        let text = #"{"assets":[],"revision":9,"rules":[],"schemaVersion":5}"#
        try stack.writeConfiguration(text)
        await #expect(throws: RuleRepositoryError.unavailable(.unsupportedSchema)) {
            _ = try await stack.repository.load()
        }
        #expect(try stack.storedText() == text)
    }

    @Test func mixedMigratedRulesRoundTrip() async throws {
        let root = makeTempDirectory(); defer { removeTree(root) }
        let stack = Stack(root: root)
        _ = try await stack.repository.load()
        let mixed = [goldenLiteralRule, schema2Rule, bodyRewriteRule].map { Rule(migrating: $0) }
        let saved = try await stack.repository.save(groups: [], rules: mixed, expectedRevision: 0)
        #expect(saved.schemaVersion == 4)
        let reloaded = try await Stack(root: root).repository.load()
        #expect(reloaded.rules == mixed)
    }

    @Test func invalidRewriteRuleIsRejectedOnSaveAndCorruptOnLoad() async throws {
        let root = makeTempDirectory(); defer { removeTree(root) }
        let stack = Stack(root: root)
        _ = try await stack.repository.load()
        var bad = bodyRewriteRule
        bad.action = .rewriteBody(direction: .response, BodyRewriteAction(find: "", replacement: "x"))
        await #expect(throws: RuleRepositoryError.invalidRule(
            index: 0, RuleValidationError(code: .emptyFind, field: .bodyFind))) {
            _ = try await stack.repository.save(groups: [], rules: [Rule(migrating: bad)], expectedRevision: 0)
        }
        let file = schema3GoldenFile.replacingOccurrences(of: #""find":"foo""#, with: #""find":"""#)
        let reader = Stack(root: makeTempDirectory())
        defer { removeTree(reader.root) }
        try reader.writeConfiguration(file)
        await #expect(throws: RuleRepositoryError.unavailable(.corrupt)) { _ = try await reader.repository.load() }
    }

    @Test func editingABodySearchPreparesItAgainAndResetsStrikes() throws {
        let clock = BodyTestClock()
        let cache = PatternCache(bodyBudget: clock.budget(maxDuration: .milliseconds(5)))
        let action = BodyRewriteAction(find: catastrophicFind, replacement: "x", syntax: .regex)
        let rule = LegacyRule(
            id: UUID(), name: "slow", enabled: true, order: 0, matcher: RuleMatcher(),
            action: .rewriteBody(direction: .response, action))
        let provider = RuleSnapshotProvider(patternCache: cache)
        provider.publish(RuleSnapshot(revision: 1, rules: [Rule(migrating: rule)]))
        let compiled = try cache.bodyPattern(action)
        for _ in 0..<3 {
            #expect(compiled.replace(in: catastrophicInput, with: "x", scope: .all) == .timedOut)
        }
        #expect(cache.isBodyPatternDisabled(action))

        // Saving the same rule again leaves the pattern as it is (phase review I1); editing the rule's body
        // search publishes it again and switches it back on.
        provider.publish(RuleSnapshot(revision: 2, rules: [Rule(migrating: rule)]))
        #expect(cache.isBodyPatternDisabled(action))
        var edited = rule
        edited.action = .rewriteBody(
            direction: .response, BodyRewriteAction(find: catastrophicFind, replacement: "y", syntax: .regex))
        provider.publish(RuleSnapshot(revision: 3, rules: [Rule(migrating: edited)]))
        #expect(!cache.isBodyPatternDisabled(action))
    }
}
