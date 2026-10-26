import FlowStore
import Foundation
import Testing

@testable import RulesEngine

/// The fixed literal rule whose encoding must never change while no advanced syntax is used.
let goldenLiteralRule = LegacyRule(
    id: UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!, name: "golden", enabled: true, order: 3,
    matcher: RuleMatcher(
        scheme: "https", hostPattern: "*.example.com", port: 443, method: "GET", path: .prefix("/api/"),
        statusRange: nil),
    action: .editHeaders(direction: .request, operations: [.set(name: "X-Test", value: "1")]))

/// Captured from the code before schema 2 existed; do not regenerate.
let goldenLiteralRuleJSON = #"{"action":{"editHeaders":{"direction":"request","operations":[{"set":{"name":"X-Test","value":"1"}}]}},"enabled":true,"id":"00000000-0000-0000-0000-0000000000A1","matcher":{"hostPattern":"*.example.com","method":"GET","path":{"prefix":{"_0":"\/api\/"}},"port":443,"scheme":"https"},"name":"golden","order":3}"#

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

private let advancedRule = LegacyRule(
    id: UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!, name: "advanced", enabled: true, order: 0,
    matcher: RuleMatcher(hostPattern: #"(a|b)\.example\.com"#, path: .wildcard("/api/*"), hostSyntax: .regex),
    action: .breakpoint(direction: .request, mode: .headers))

@Suite("RuleSchemaCompatibility") struct RuleSchemaCompatibilityTests {
    @Test func goldenLiteralRuleJSONIsUnchanged() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(decoding: try encoder.encode(goldenLiteralRule), as: UTF8.self)
        #expect(json == goldenLiteralRuleJSON)
    }

    @Test func missingHostSyntaxDecodesLiteral() throws {
        let rule = try JSONDecoder().decode(LegacyRule.self, from: Data(goldenLiteralRuleJSON.utf8))
        #expect(rule == goldenLiteralRule)
        #expect(rule.matcher.hostSyntax == .literal)
        #expect(!rule.matcher.usesAdvancedSyntax)
    }

    /// The pre-schema-2 matcher shape with compiler-synthesized Codable.
    private struct LegacyMatcher: Codable {
        var scheme: String?
        var hostPattern: String?
        var port: Int?
        var method: String?
        var path: PathMatch
        var statusRange: ClosedRange<Int>?
    }

    @Test func literalMatchersEncodeLikeTheSynthesizedLegacyShape() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let matchers = [
            RuleMatcher(),
            RuleMatcher(path: .exact("/x?y=1")),
            RuleMatcher(scheme: "http", hostPattern: "a.test", port: 80, method: "POST", path: .prefix("/p"), statusRange: 400...499),
            RuleMatcher(statusRange: 200...200),
        ]
        for matcher in matchers {
            let legacy = LegacyMatcher(
                scheme: matcher.scheme, hostPattern: matcher.hostPattern, port: matcher.port, method: matcher.method,
                path: matcher.path, statusRange: matcher.statusRange)
            let expected = try encoder.encode(legacy)
            #expect(try encoder.encode(matcher) == expected)
            #expect(try JSONDecoder().decode(RuleMatcher.self, from: expected) == matcher)
        }
    }

    @Test func hostSyntaxIsOnlyEncodedWhenNotLiteral() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let literal = String(decoding: try encoder.encode(goldenLiteralRule.matcher), as: UTF8.self)
        #expect(!literal.contains("hostSyntax"))
        let advanced = String(decoding: try encoder.encode(advancedRule.matcher), as: UTF8.self)
        #expect(advanced.contains(#""hostSyntax":"regex""#))
        #expect(try JSONDecoder().decode(RuleMatcher.self, from: Data(advanced.utf8)) == advancedRule.matcher)
    }

    /// Rules 2.0 (spec 5.6.1): a schema 1 file is migrated to schema 4 on load. The rule comes back migrated,
    /// renumbered to its position, at the next revision.
    @Test func v1FileWithLiteralRulesMigratesToTheSameRule() async throws {
        let root = makeTempDirectory(); defer { removeTree(root) }
        let stack = Stack(root: root)
        try stack.writeConfiguration(
            #"{"assets":[],"revision":4,"rules":["# + goldenLiteralRuleJSON + #"],"schemaVersion":1}"#)
        let snapshot = try await stack.repository.load()
        var renumbered = goldenLiteralRule
        renumbered.order = 0
        #expect(snapshot.revision == 5)
        #expect(snapshot.rules == [Rule(migrating: renumbered)])
        #expect(snapshot.schemaVersion == 4)
        #expect(try stack.storedText().hasSuffix(#""schemaVersion":4,"templatesInstalled":false}"#))
    }

    /// Spec 5.1: saves always write schema 4 now (no smallest-schema-by-content any more).
    @Test func savingLiteralRulesWritesSchema4() async throws {
        let root = makeTempDirectory(); defer { removeTree(root) }
        let stack = Stack(root: root)
        _ = try await stack.repository.load()
        _ = try await stack.repository.save(groups: [], rules: [Rule(migrating: goldenLiteralRule)], expectedRevision: 0)
        #expect(try stack.storedText().hasPrefix(#"{"assets":[],"groups":[],"revision":1,"rules":[{"#))
        #expect(try stack.storedText().hasSuffix(#""schemaVersion":4,"templatesInstalled":false}"#))
    }

    @Test func savingAdvancedRuleWritesSchema4AndRoundTrips() async throws {
        let root = makeTempDirectory(); defer { removeTree(root) }
        let stack = Stack(root: root)
        _ = try await stack.repository.load()
        let saved = try await stack.repository.save(
            groups: [], rules: [Rule(migrating: goldenLiteralRule), Rule(migrating: advancedRule)], expectedRevision: 0)
        #expect(saved.schemaVersion == 4)
        #expect(try stack.storedText().hasSuffix(#""schemaVersion":4,"templatesInstalled":false}"#))
        let reloaded = try await Stack(root: root).repository.load()
        #expect(reloaded == saved)
        #expect(reloaded.rules == [Rule(migrating: goldenLiteralRule), Rule(migrating: advancedRule)])

        // Dropping the advanced rule: the file stays schema 4.
        _ = try await stack.repository.save(
            groups: [], rules: [Rule(migrating: goldenLiteralRule)], expectedRevision: saved.revision)
        #expect(try stack.storedText().hasSuffix(#""schemaVersion":4,"templatesInstalled":false}"#))
    }

    @Test func schema5IsUnsupportedNotCorrupt() async throws {
        let root = makeTempDirectory(); defer { removeTree(root) }
        let stack = Stack(root: root)
        let text = #"{"assets":[],"revision":9,"rules":[],"schemaVersion":5}"#
        try stack.writeConfiguration(text)
        await #expect(throws: RuleRepositoryError.unavailable(.unsupportedSchema)) {
            _ = try await stack.repository.load()
        }
        #expect(try stack.storedText() == text)
    }

    @Test func storedInvalidRegexIsCorrupt() async throws {
        let root = makeTempDirectory(); defer { removeTree(root) }
        let stack = Stack(root: root)
        let text = #"{"assets":[],"revision":2,"rules":[{"action":{"breakpoint":{"direction":"request","mode":"headers"}},"enabled":true,"id":"00000000-0000-0000-0000-0000000000C3","matcher":{"path":{"regex":{"_0":"("}}},"name":"bad","order":0}],"schemaVersion":2}"#
        try stack.writeConfiguration(text)
        await #expect(throws: RuleRepositoryError.unavailable(.corrupt)) {
            _ = try await stack.repository.load()
        }
        #expect(try stack.storedText() == text)
    }
}
