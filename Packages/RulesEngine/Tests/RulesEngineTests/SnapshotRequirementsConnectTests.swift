import Foundation
import Testing

@testable import RulesEngine

/// Rules 2.0 R4 Task 7: whether a snapshot has rules for the CONNECT point (D11, D13).
struct SnapshotRequirementsConnectTests {
    private static func rule(
        _ rows: [ConditionRow] = [], enabled: Bool = true, groupID: UUID? = nil, _ actions: RuleAction...
    ) -> Rule {
        Rule(
            id: UUID(), name: "r", enabled: enabled, groupID: groupID, order: 0,
            conditions: ConditionGroup(mode: .all, occurrence: .any, rows: rows), actions: actions)
    }

    private static func snapshot(_ rules: [Rule], groups: [RuleGroup] = []) -> RuleSnapshot {
        RuleSnapshot(revision: 1, groups: groups, rules: rules)
    }

    private static let hostRow = ConditionRow(field: .host, op: .hostPattern, value: "x.com")
    private static let pathRow = ConditionRow(field: .path, op: .equals, value: "/")
    private static let clientAppRow = ConditionRow(field: .clientApp, name: "name", op: .equals, value: "Safari")
    private static let setHeader = RuleAction(.editHeaders(direction: .request, operations: [.set(name: "X", value: "1")]))
    private static let mark = RuleAction(.mark(MarkAction(background: "#FF3B30")))

    @Test func connectFlagOnlyForP0RulesWithConnectCapableActions() {
        for action in [
            RuleAction(.noDecrypt), RuleAction(.returnConnectTunnel), RuleAction(.closeConnection(.reset)), Self.mark,
            RuleAction(.comment(CommentAction())), RuleAction(.hide),
        ] {
            let requirements = Self.snapshot([Self.rule([Self.hostRow], action)]).requirements
            #expect(requirements.connect, "\(action.kind)")
            #expect(!requirements.connectClientApp)
            #expect(!requirements.isEmpty)
        }
        // A connect-judged rule with no action that can run there.
        #expect(!Self.snapshot([Self.rule([Self.hostRow], Self.setHeader)]).requirements.connect)
        #expect(Self.snapshot([Self.rule([Self.hostRow], Self.setHeader)]).requirements.isEmpty)
        // A rule judged at the request, whatever it does.
        #expect(!Self.snapshot([Self.rule([Self.pathRow], Self.mark)]).requirements.connect)
        // Mixed with a request-side action, the connect-capable one still counts.
        #expect(Self.snapshot([Self.rule([], Self.setHeader, Self.mark)]).requirements.connect)
    }

    @Test func connectClientAppOnlyWhenAP0RuleReadsClientApp() {
        let p0 = Self.snapshot([Self.rule([Self.clientAppRow], RuleAction(.closeConnection(.graceful)))]).requirements
        #expect(p0.connect && p0.connectClientApp && p0.clientApp)
        // A request-point rule reading the app needs it at the request only.
        let p1 = Self.snapshot([Self.rule([Self.clientAppRow], Self.setHeader)]).requirements
        #expect(p1.clientApp && !p1.connect && !p1.connectClientApp)
        // A P0 rule that does not read the app, beside a P1 rule that does.
        let split = Self.snapshot([
            Self.rule([Self.hostRow], Self.mark), Self.rule([Self.clientAppRow, Self.pathRow], Self.mark),
        ]).requirements
        #expect(split.connect && split.clientApp && !split.connectClientApp)
    }

    @Test func disabledRulesDoNotCount() {
        let group = RuleGroup(name: "off", enabled: false)
        let requirements = Self.snapshot(
            [
                Self.rule([Self.clientAppRow], enabled: false, RuleAction(.noDecrypt)),
                Self.rule([Self.clientAppRow], groupID: group.id, RuleAction(.noDecrypt)),
            ], groups: [group]
        ).requirements
        #expect(!requirements.connect && !requirements.connectClientApp)
        #expect(requirements.isEmpty)
    }

    @Test func existingFlagsUnchanged() {
        let requirements = Self.snapshot([Self.rule([Self.hostRow], RuleAction(.noDecrypt))]).requirements
        #expect(requirements == SnapshotRequirements(connect: true))
        #expect(!requirements.requestBody && !requirements.responseBody && !requirements.clientApp)
        #expect(!requirements.completion)
        #expect(Self.snapshot([]).requirements == SnapshotRequirements())
    }

    @Test func valueIsComputedOncePerSnapshot() {
        let original = Self.snapshot([Self.rule([Self.hostRow], RuleAction(.noDecrypt))])
        #expect(original.requirements.connect)
        // A copy shares the cached value until its rules change; then it is worked out again.
        var edited = original
        #expect(edited.requirements.connect)
        edited.rules = [Self.rule([Self.pathRow], Self.mark)]
        #expect(!edited.requirements.connect)
        #expect(original.requirements.connect)
    }
}
