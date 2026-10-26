import FlowStore
import Foundation
import Testing

@testable import RulesEngine

/// Rules 2.0 phase R6 adds no stored shape (Execute never touches the rules file, spec 8, review focus 1): the
/// R5 editor fixture loads and saves with the same bytes, and the Execute acceptance fixture is valid.
@Suite struct RulesFileByteIdenticalR6Tests {
    private static let docs = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("docs/fixtures/rules2")
    static let r5FixtureURL = docs.appendingPathComponent("R5-editor.rules.json")
    static let executeFixtureURL = docs.appendingPathComponent("R6-execute.rules.json")

    private static func id(_ index: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-0000000006%02d", index))!
    }

    private static func conditions(path: String? = nil, _ extra: ConditionRow...) -> ConditionGroup {
        var rows = [ConditionRow(field: .host, op: .equals, value: "r6.test")]
        if let path { rows.append(ConditionRow(field: .path, op: .startsWith, value: path)) }
        return ConditionGroup(rows: rows + extra)
    }

    static let enabledGroup = RuleGroup(id: id(90), name: "R6 enabled group", order: 0)
    static let disabledGroup = RuleGroup(id: id(91), name: "R6 disabled group", enabled: false, order: 1)

    static let executeRules: [Rule] = [
        Rule(
            id: id(1), name: "R6 request header edit", groupID: id(90), order: 0, conditions: conditions(path: "/api"),
            actions: [RuleAction(.editHeaders(direction: .request, operations: [.set(name: "X-R6-Request", value: "1")]))]),
        Rule(
            id: id(2), name: "R6 response edit", groupID: id(90), order: 1, conditions: conditions(path: "/api"),
            actions: [
                RuleAction(.editHeaders(direction: .response, operations: [.set(name: "X-R6-Response", value: "1")])),
                RuleAction(.rewriteStatus(RewriteStatusAction(status: 203))),
                RuleAction(.rewriteBody(direction: .response, BodyRewriteAction(find: "original", replacement: "rewritten"))),
            ]),
        Rule(
            id: id(3), name: "R6 mark", groupID: id(90), order: 2, conditions: conditions(path: "/mark"),
            actions: [RuleAction(.mark(MarkAction(background: "#FFD54F", foreground: "#000000", text: "r6")))]),
        Rule(
            id: id(4), name: "R6 comment append", groupID: id(90), order: 3, conditions: conditions(path: "/mark"),
            actions: [RuleAction(.comment(CommentAction(mode: .append, text: "executed")))]),
        Rule(
            id: id(5), name: "R6 disabled group member", groupID: id(91), order: 0, conditions: conditions(path: "/grouped"),
            actions: [RuleAction(.mark(MarkAction(background: "#90CAF9", text: "grouped")))]),
        Rule(
            id: id(6), name: "R6 breakpoint", order: 2, conditions: conditions(path: "/pause"),
            actions: [RuleAction(.breakpoint(direction: .request, mode: .headers))]),
        Rule(
            id: id(7), name: "R6 delay", order: 3, conditions: conditions(path: "/slow"),
            actions: [RuleAction(.delay(milliseconds: 500))]),
        Rule(
            id: id(8), name: "R6 close connection", order: 4,
            conditions: ConditionGroup(rows: [ConditionRow(field: .host, op: .equals, value: "closed.r6.test")]),
            actions: [RuleAction(.closeConnection(.graceful))]),
        Rule(
            id: id(9), name: "R6 failed session mark", order: 5,
            conditions: conditions(ConditionRow(field: .sessionState, op: .equals, value: "failed")),
            actions: [RuleAction(.mark(MarkAction(background: "#EF9A9A", foreground: "#000000", text: "failed")))]),
        Rule(
            id: id(10), name: "R6 preset 404", order: 6, conditions: conditions(path: "/blocked/"),
            actions: [RuleAction(.returnPreset(PresetResponse(preset: .notFound404)), isFinal: true)]),
        Rule(
            id: id(11), name: "R6 hide", order: 7, conditions: conditions(path: "/hidden"),
            actions: [RuleAction(.hide)]),
    ]

    static let executeSnapshot = RuleSnapshot(revision: 1, groups: [enabledGroup, disabledGroup], rules: executeRules)

    private static func current(_ data: Data) throws -> RuleStorage.Configuration {
        guard case .current(let configuration) = try RuleStorage.read(data, limits: RulesLimits()) else {
            Issue.record("expected a schema 4 file")
            throw RuleConfigurationProblem.corrupt
        }
        return configuration
    }

    /// The same JSON value with sorted keys and no insignificant white space.
    private static func canonical(_ data: Data) throws -> Data {
        let object = try JSONSerialization.jsonObject(with: data)
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    @Test func rulesFileRoundTripsByteForByte() throws {
        let r5 = try Data(contentsOf: Self.r5FixtureURL)
        let reencoded = try RuleStorage.encode(Self.current(r5))
        #expect(try Self.canonical(reencoded) == Self.canonical(r5))
        #expect(try RuleStorage.encode(Self.current(reencoded)) == reencoded)

        let execute = try Data(contentsOf: Self.executeFixtureURL)
        let executeEncoded = try RuleStorage.encode(Self.current(execute))
        #expect(try Self.canonical(executeEncoded) == Self.canonical(execute))
        #expect(try RuleStorage.encode(Self.current(executeEncoded)) == executeEncoded)
    }

    @Test func executeFixtureIsValid() throws {
        let configuration = try Self.current(Data(contentsOf: Self.executeFixtureURL))
        let limits = RulesLimits()
        let snapshot = configuration.snapshot
        try snapshot.validateStructure(limits: limits)
        for rule in snapshot.rules { try rule.validate(limits: limits) }
        #expect(snapshot.rules == Self.executeRules)
        #expect(snapshot.groups == [Self.enabledGroup, Self.disabledGroup])
        #expect(snapshot.migrationNotice == nil)
    }

    @Test func executeFixtureCoversWhatTheAcceptanceNeeds() throws {
        let snapshot = try Self.current(Data(contentsOf: Self.executeFixtureURL)).snapshot
        let rules = snapshot.rules
        // A disabled group holding an enabled rule.
        let member = try #require(rules.first { $0.groupID == Self.disabledGroup.id })
        #expect(member.enabled && !Self.disabledGroup.enabled)
        // Hide is the last rule in order.
        let last = try #require(rules.max { $0.order < $1.order })
        #expect(last.actions.contains { $0.kind == .hide })
        // A final preset 404 limited to /blocked/.
        let preset = try #require(rules.first { rule in
            rule.actions.contains { if case .returnPreset(let p) = $0.kind { p.preset == .notFound404 } else { false } }
        })
        let allFinal = preset.actions.allSatisfy { $0.isFinal }
        #expect(allFinal)
        #expect(preset.conditions.rows.contains { $0.field == .path && $0.value == "/blocked/" })
        // Every other kind the acceptance runs.
        func has(_ test: (ActionKind) -> Bool) -> Bool { rules.contains { $0.actions.contains { test($0.kind) } } }
        #expect(has { if case .breakpoint = $0 { true } else { false } })
        #expect(has { if case .delay = $0 { true } else { false } })
        #expect(has { if case .closeConnection = $0 { true } else { false } })
        #expect(has { if case .rewriteStatus = $0 { true } else { false } })
        #expect(has { if case .rewriteBody(.response, _) = $0 { true } else { false } })
        #expect(has { if case .editHeaders(.request, _) = $0 { true } else { false } })
        #expect(has { if case .editHeaders(.response, _) = $0 { true } else { false } })
        #expect(has { if case .comment(let c) = $0 { c.mode == .append } else { false } })
        #expect(rules.contains { rule in
            rule.conditions.rows.contains { $0.field == .sessionState && $0.value == "failed" }
                && rule.actions.contains { if case .mark = $0.kind { true } else { false } }
        })
    }
}
