import FlowStore
import Foundation
import Testing

@testable import RulesEngine

/// `docs/fixtures/rules2/R4-actions.rules.json`: a schema 4 file with one rule per R4 action, every condition
/// limited to the host `r4.test`. The native acceptance copies it into an isolated configuration directory;
/// this test keeps it loadable and keeps it meaning what its rules say.
@Suite struct R4FixtureTests {
    static let fixtureURL: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("docs/fixtures/rules2/R4-actions.rules.json")

    private static func id(_ index: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-0000000004%02d", index))!
    }

    private static let host = ConditionRow(field: .host, op: .equals, value: "r4.test")

    private static func rule(_ index: Int, _ name: String, path: String? = nil, port: Int? = nil, _ kind: ActionKind) -> Rule {
        var rows = [host]
        if let path { rows.append(ConditionRow(field: .path, op: .startsWith, value: path)) }
        if let port { rows.append(ConditionRow(field: .port, op: .equals, value: String(port))) }
        return Rule(
            id: id(index), name: name, enabled: true, order: index - 1, conditions: ConditionGroup(rows: rows),
            actions: [RuleAction(kind)])
    }

    /// One rule per R4 action kind (both cookie directions, both close modes, a redirect and a refusal preset).
    static let expected: [Rule] = [
        rule(1, "R4 modify URL (set)", path: "/set-url",
             .modifyURL(URLEditAction(mode: .set, replacement: "http://r4-target.test:8080/landing?from=rule"))),
        rule(2, "R4 modify URL (find and replace)", path: "/find-url",
             .modifyURL(URLEditAction(mode: .findReplace, find: "/find-url", replacement: "/found-url"))),
        rule(3, "R4 modify URL (regex)", path: "/regex-url",
             .modifyURL(URLEditAction(mode: .regex, find: "^(.*)/regex-url(.*)$", replacement: "$1/regexed-url$2"))),
        rule(4, "R4 modify query", path: "/query",
             .modifyQuery(QueryEditAction(operations: [
                 .set(name: "token", value: "r4"), .add(name: "added", value: "1"), .remove(name: "debug"),
             ]))),
        rule(5, "R4 edit request cookies", path: "/cookie-in",
             .editCookies(direction: .request, operations: [.set(name: "session", value: "r4"), .remove(name: "tracking")])),
        rule(6, "R4 edit response cookies", path: "/cookie-out",
             .editCookies(direction: .response, operations: [.set(name: "served", value: "by-rule")])),
        rule(7, "R4 delay", path: "/slow", .delay(milliseconds: 1500)),
        rule(8, "R4 handwritten response", path: "/handwritten",
             .returnHandwritten(HandwrittenResponse(
                 text: "HTTP/1.1 403 Forbidden\r\nContent-Type: text/html; charset=utf-8\r\n\r\n<h1>Blocked by a rule</h1>"))),
        rule(9, "R4 preset redirect", path: "/preset-redirect",
             .returnPreset(PresetResponse(preset: .movedPermanently301, location: "https://example.com/"))),
        rule(10, "R4 preset refusal", path: "/preset-forbidden",
             .returnPreset(PresetResponse(preset: .forbidden403, body: "Forbidden by a rule"))),
        rule(11, "R4 close connection (graceful)", path: "/close", .closeConnection(.graceful)),
        rule(12, "R4 close connection (reset)", path: "/reset", .closeConnection(.reset)),
        rule(13, "R4 return CONNECT tunnel", port: 443, .returnConnectTunnel),
        rule(14, "R4 do not decrypt", port: 8443, .noDecrypt),
    ]

    @Test func r4FixtureLoadsAndValidates() async throws {
        let data = try Data(contentsOf: Self.fixtureURL)
        // Hand-written fixtures supply every key the synthesized Codable payloads need.
        let text = String(decoding: data, as: UTF8.self)
        for key in ["caseSensitive", "preserveCredentials", "schemaVersion"] { #expect(text.contains("\"\(key)\""), "\(key)") }

        let root = makeTempDirectory(); defer { removeTree(root) }
        let directory = root.appendingPathComponent("config")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        writeFile(directory.appendingPathComponent("rules.json"), data)
        let limits = RulesLimits()
        let assets = ManagedAssetStore(
            directory: root.appendingPathComponent("assets"), limits: limits,
            budgets: OwnedFileBudgets(limits: limits, freeDiskBytes: ample))
        let repository = RuleRepository(directory: directory, assets: assets, limits: limits)
        let snapshot = try await repository.load()

        #expect(snapshot.schemaVersion == 4)
        #expect(snapshot.migrationNotice == nil)
        #expect(snapshot.rules == Self.expected)
        for rule in snapshot.rules {
            try rule.validate(limits: limits)
            #expect(rule.conditions.rows.first == Self.host, "\(rule.name)")
        }
        #expect(snapshot.requirements.connect)
        // Nothing was rewritten: a file that loads as it is stays as it is.
        #expect(try Data(contentsOf: directory.appendingPathComponent("rules.json")) == data)
    }

    @Test func everyR4ActionKindAppears() {
        let kinds = Set(Self.expected.flatMap(\.actions).map { String(describing: $0.kind).prefix { $0 != "(" } })
        #expect(kinds == [
            "modifyURL", "modifyQuery", "editCookies", "delay", "returnHandwritten", "returnPreset", "closeConnection",
            "returnConnectTunnel", "noDecrypt",
        ])
    }
}
