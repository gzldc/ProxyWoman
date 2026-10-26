import FlowStore
import Foundation
import Testing

@testable import RulesEngine

/// Rules 2.0 phase R5 only appends stored shapes (spec 8, review focus 1): a schema 4 file that uses none of
/// the new Header methods or body operations loads and saves with the same bytes, and the R5 editor fixture
/// loads and is valid.
@Suite struct RulesFileByteIdenticalR5Tests {
    private static let docs = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("docs/fixtures/rules2")
    static let r4FixtureURL = docs.appendingPathComponent("R4-actions.rules.json")
    static let editorFixtureURL = docs.appendingPathComponent("R5-editor.rules.json")

    private static func id(_ index: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-0000000005%02d", index))!
    }

    private static let host = ConditionRow(field: .host, op: .equals, value: "r5.test")

    private static func conditions(path: String? = nil, _ extra: ConditionRow...) -> ConditionGroup {
        var rows = [host]
        if let path { rows.append(ConditionRow(field: .path, op: .startsWith, value: path)) }
        return ConditionGroup(rows: rows + extra)
    }

    static let outer = RuleGroup(id: id(90), name: "R5 outer group", order: 0)
    static let inner = RuleGroup(id: id(91), name: "R5 inner group", parentID: id(90), order: 0)

    /// Two nested groups, a multi-action rule, the four new Header methods, body set-value and clear, a
    /// completion point (P3) rule with a mark and a connect-only rule.
    static let editorRules: [Rule] = [
        Rule(
            id: id(1), name: "R5 multi-action", groupID: id(91), order: 0, conditions: conditions(path: "/multi"),
            actions: [
                RuleAction(.editHeaders(direction: .request, operations: [.set(name: "X-R5", value: "1")])),
                RuleAction(.delay(milliseconds: 200)),
                RuleAction(.comment(CommentAction(mode: .append, text: "multi"))),
            ], note: "Three actions in one rule."),
        Rule(
            id: id(2), name: "R5 body set-value and clear", groupID: id(91), order: 1, conditions: conditions(path: "/body"),
            actions: [
                RuleAction(.rewriteBody(direction: .request, BodyRewriteAction(find: "", replacement: "{\"r5\":true}", operation: .setValue))),
                RuleAction(.rewriteBody(direction: .response, BodyRewriteAction(find: "", replacement: "", operation: .clear))),
            ]),
        Rule(
            id: id(3), name: "R5 header methods", groupID: id(90), order: 1, conditions: conditions(path: "/headers"),
            actions: [
                RuleAction(.editHeaders(direction: .request, operations: [
                    .addIfMissing(name: "X-R5-Missing", value: "added"),
                    .appendToValue(name: "Accept", text: ", text/r5"),
                    .findReplace(name: "User-Agent", find: "Mozilla", replacement: "R5", caseSensitive: false),
                    .regex(name: "Accept-Language", pattern: "en-(\\w+)", replacement: "r5-$1", caseSensitive: false),
                ]))
            ]),
        Rule(
            id: id(4), name: "R5 completion mark", order: 1, conditions: conditions(ConditionRow(field: .durationMs, op: .greaterThan, value: "1000")),
            actions: [RuleAction(.mark(MarkAction(background: "#FFD54F", foreground: "#000000", text: "slow")))]),
        Rule(
            id: id(5), name: "R5 connect only", order: 2,
            conditions: ConditionGroup(rows: [host, ConditionRow(field: .port, op: .equals, value: "8443")]),
            actions: [RuleAction(.noDecrypt)]),
    ]

    static let editorSnapshot = RuleSnapshot(revision: 1, groups: [outer, inner], rules: editorRules)

    /// Only the old Header methods and the plain find-and-replace body forms.
    static let legacyOnly: [Rule] = [
        Rule(
            id: id(11), name: "old header methods", order: 0, conditions: conditions(path: "/old"),
            actions: [
                RuleAction(.editHeaders(direction: .request, operations: [
                    .set(name: "X-A", value: "1"), .append(name: "X-B", value: "2"), .remove(name: "X-C"),
                ])),
                RuleAction(.editHeaders(direction: .response, operations: [.set(name: "X-D", value: "4")])),
            ]),
        Rule(
            id: id(12), name: "old body forms", order: 1, conditions: conditions(path: "/old-body"),
            actions: [
                RuleAction(.rewriteBody(direction: .request, BodyRewriteAction(find: "foo", replacement: "bar"))),
                RuleAction(.rewriteBody(direction: .response, BodyRewriteAction(find: "a+", replacement: "b", syntax: .regex, caseSensitive: false))),
            ]),
    ]

    private static func configuration(_ snapshot: RuleSnapshot) -> RuleStorage.Configuration {
        RuleStorage.Configuration(snapshot: snapshot, assets: [])
    }

    private static func current(_ data: Data) throws -> RuleStorage.Configuration {
        guard case .current(let configuration) = try RuleStorage.read(data, limits: RulesLimits()) else {
            Issue.record("expected a schema 4 file")
            throw RuleConfigurationProblem.corrupt
        }
        return configuration
    }

    @Test func rulesFileRoundTripsByteForByte() throws {
        let legacyFile = try RuleStorage.encode(Self.configuration(RuleSnapshot(revision: 7, rules: Self.legacyOnly)))
        let text = String(decoding: legacyFile, as: UTF8.self)
        #expect(!text.contains("\"operation\""))
        for method in ["addIfMissing", "appendToValue"] { #expect(!text.contains(method), "\(method)") }
        #expect(text.contains("\"set\"") && text.contains("\"append\"") && text.contains("\"remove\""))
        #expect(try RuleStorage.encode(Self.current(legacyFile)) == legacyFile)

        // The pretty-printed R4 fixture re-encodes to its own content, key for key.
        let r4 = try Data(contentsOf: Self.r4FixtureURL)
        let reencoded = try RuleStorage.encode(Self.current(r4))
        #expect(try Self.canonical(reencoded) == Self.canonical(r4))
        #expect(try RuleStorage.encode(Self.current(reencoded)) == reencoded)
    }

    @Test func newShapesAlsoRoundTripByteForByte() throws {
        let editor = try RuleStorage.encode(Self.configuration(Self.editorSnapshot))
        #expect(try RuleStorage.encode(Self.current(editor)) == editor)
        let fixture = try Data(contentsOf: Self.editorFixtureURL)
        #expect(try Self.canonical(RuleStorage.encode(Self.current(fixture))) == Self.canonical(fixture))
    }

    /// The same JSON value with sorted keys and no insignificant white space.
    private static func canonical(_ data: Data) throws -> Data {
        let object = try JSONSerialization.jsonObject(with: data)
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    @Test func editorFixtureIsValid() throws {
        let data = try Data(contentsOf: Self.editorFixtureURL)
        let configuration = try Self.current(data)
        let limits = RulesLimits()
        let snapshot = configuration.snapshot
        try snapshot.validateStructure(limits: limits)
        for rule in snapshot.rules { try rule.validate(limits: limits) }
        #expect(snapshot.rules == Self.editorRules)
        #expect(snapshot.groups == [Self.outer, Self.inner])
        #expect(snapshot.migrationNotice == nil)
    }

    @Test func editorFixtureCoversWhatTheAcceptanceNeeds() throws {
        let snapshot = try Self.current(Data(contentsOf: Self.editorFixtureURL)).snapshot
        #expect(Self.depth(of: Self.inner, in: snapshot.groups) == 2)
        #expect(snapshot.rules.contains { $0.actions.count > 1 })

        var headerMethods: Set<String> = []
        var bodyOperations: Set<BodyRewriteOperation> = []
        for action in snapshot.rules.flatMap(\.actions) {
            switch action.kind {
            case .editHeaders(_, let operations):
                for operation in operations {
                    switch operation {
                    case .addIfMissing: headerMethods.insert("addIfMissing")
                    case .appendToValue: headerMethods.insert("appendToValue")
                    case .findReplace: headerMethods.insert("findReplace")
                    case .regex: headerMethods.insert("regex")
                    case .set, .append, .remove: break
                    }
                }
            case .rewriteBody(_, let body): bodyOperations.insert(body.operation)
            default: break
            }
        }
        #expect(headerMethods == ["addIfMissing", "appendToValue", "findReplace", "regex"])
        #expect(bodyOperations == [.setValue, .clear])

        let completionMark = snapshot.rules.filter { rule in
            rule.conditions.judgmentPoint == .completion && rule.actions.contains { if case .mark = $0.kind { true } else { false } }
        }
        #expect(completionMark.count == 1)
        #expect(snapshot.rules.contains { $0.conditions.judgmentPoint == .connect && $0.actions.contains { $0.kind == .noDecrypt } })
        #expect(snapshot.requirements.connect)
    }

    private static func depth(of group: RuleGroup, in groups: [RuleGroup]) -> Int {
        var depth = 1, current = group
        while let parent = groups.first(where: { $0.id == current.parentID }) { depth += 1; current = parent }
        return depth
    }
}
