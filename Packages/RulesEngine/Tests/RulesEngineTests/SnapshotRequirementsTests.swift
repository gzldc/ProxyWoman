import Foundation
import Testing

@testable import RulesEngine

/// Rules 2.0 R3 Task 7: which asynchronous facts an enabled rule set needs, worked out once per snapshot.
struct SnapshotRequirementsTests {
    private static func rule(
        _ rows: [ConditionRow], enabled: Bool = true, groupID: UUID? = nil, order: Int = 0
    ) -> Rule {
        Rule(
            id: UUID(), name: "r", enabled: enabled, groupID: groupID, order: order,
            conditions: ConditionGroup(mode: .all, occurrence: .any, rows: rows),
            actions: [RuleAction(.editHeaders(direction: .request, operations: [.set(name: "X", value: "1")]))])
    }

    private static func snapshot(_ rules: [Rule], groups: [RuleGroup] = []) -> RuleSnapshot {
        RuleSnapshot(revision: 1, groups: groups, rules: rules)
    }

    private static let requestBodyRow = ConditionRow(field: .requestBody, op: .contains, value: "a")
    private static let responseBodyRow = ConditionRow(field: .responseBody, op: .contains, value: "a")
    private static let clientAppRow = ConditionRow(field: .clientApp, name: "name", op: .equals, value: "Safari")
    private static let durationRow = ConditionRow(field: .durationMs, op: .greaterThan, value: "100")

    @Test func emptySnapshotNeedsNothing() {
        #expect(Self.snapshot([]).requirements == SnapshotRequirements())
        #expect(Self.snapshot([]).requirements.isEmpty)
    }

    @Test func migratedRulesNeedNothing() {
        let legacyRules: [Rule] = [
            Rule(
                id: UUID(), name: "host", enabled: true, order: 0,
                matcher: RuleMatcher(hostPattern: "*.example.com", hostSyntax: .wildcard),
                action: .editHeaders(direction: .request, operations: [.set(name: "X", value: "1")])),
            Rule(
                id: UUID(), name: "status", enabled: true, order: 1,
                matcher: RuleMatcher(method: "GET", path: .prefix("/api/"), statusRange: 500...599, hostSyntax: .regex),
                action: .editHeaders(direction: .response, operations: [.set(name: "X", value: "2")])),
            Rule(
                id: UUID(), name: "port", enabled: true, order: 2,
                matcher: RuleMatcher(scheme: "https", port: 8443),
                action: .editHeaders(direction: .request, operations: [.set(name: "X", value: "3")])),
        ]
        #expect(Self.snapshot(legacyRules).requirements.isEmpty)
    }

    @Test func requestBodyRowSetsRequestBody() {
        let requirements = Self.snapshot([Self.rule([Self.requestBodyRow])]).requirements
        #expect(requirements.requestBody)
        #expect(!requirements.responseBody && !requirements.clientApp && !requirements.completion)
    }

    @Test func responseBodyRowSetsResponseBody() {
        let requirements = Self.snapshot([Self.rule([Self.responseBodyRow])]).requirements
        #expect(requirements.responseBody)
        #expect(!requirements.requestBody && !requirements.clientApp && !requirements.completion)
    }

    @Test func clientAppRowSetsClientApp() {
        let requirements = Self.snapshot([Self.rule([Self.clientAppRow])]).requirements
        #expect(requirements.clientApp)
        #expect(!requirements.requestBody && !requirements.responseBody && !requirements.completion)
    }

    @Test func durationRowSetsCompletion() {
        let requirements = Self.snapshot([Self.rule([Self.durationRow])]).requirements
        #expect(requirements.completion)
        #expect(!requirements.requestBody && !requirements.responseBody && !requirements.clientApp)
    }

    @Test func disabledRuleIsIgnored() {
        let requirements = Self.snapshot([Self.rule([Self.requestBodyRow], enabled: false)]).requirements
        #expect(requirements.isEmpty)
    }

    @Test func disabledGroupIsIgnored() {
        let group = RuleGroup(name: "off", enabled: false)
        let requirements = Self.snapshot(
            [Self.rule([Self.clientAppRow], groupID: group.id)], groups: [group]
        ).requirements
        #expect(requirements.isEmpty)
    }

    @Test func requirementsAreComputedOncePerSnapshotValue() {
        let original = Self.snapshot([Self.rule([Self.requestBodyRow])])
        #expect(original.requirements.requestBody)
        // A copy shares the cached value until its rules change; then it is worked out again.
        var edited = original
        #expect(edited.requirements.requestBody)
        edited.rules = [Self.rule([Self.durationRow])]
        #expect(edited.requirements == SnapshotRequirements(completion: true))
        #expect(original.requirements.requestBody && !original.requirements.completion)
    }

    @Test func responseBodyRuleAlsoNeedsNoRequestBody() {
        let requirements = Self.snapshot([Self.rule([Self.responseBodyRow])]).requirements
        #expect(requirements.responseBody)
        #expect(requirements.requestBody == false)
    }

    @Test func requestBodyRowInAResponseJudgedRuleStillSetsRequestBody() {
        // A rule judged at the response can still read the request body (D14).
        let rule = Self.rule([Self.requestBodyRow, Self.responseBodyRow])
        #expect(rule.conditions.judgmentPoint == .response)
        let requirements = Self.snapshot([rule]).requirements
        #expect(requirements.requestBody)
        #expect(requirements.responseBody)
    }
}
