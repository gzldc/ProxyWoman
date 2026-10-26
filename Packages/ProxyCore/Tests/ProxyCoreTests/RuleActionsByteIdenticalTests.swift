import FlowStore
import Foundation
import Testing
@testable import ProxyCore
import RulesEngine

/// Rules 2.0 phase R4 changes nothing for traffic whose conditions do not hold (spec 8): a snapshot that
/// carries every new action, on rules that match nothing, gives the same bytes on both wires and the same
/// flow records (`FlowDigest`) as a proxy without those rules.
@Suite(.serialized, .timeLimit(.minutes(3)), .productionChinese) struct RuleActionsByteIdenticalTests {
    /// One rule per new action kind (both cookie directions, both close modes, a redirect, a refusal), each
    /// with a condition that cannot hold for a request to `host:port`: another host, another port, a path that
    /// is not the one requested, a `none` group with a row that matches, an `any` group with every row off.
    static func neverMatchingActionRules(host: String, port: Int) -> [Rule] {
        let otherHost = ConditionRow(field: .host, op: .hostPattern, value: "never.example")
        let hostIs = ConditionRow(field: .host, op: .hostPattern, value: host)
        let portIs = ConditionRow(field: .port, op: .equals, value: String(port))
        let otherPath = ConditionRow(field: .pathAndQuery, op: .startsWith, value: "/never", caseSensitive: true)
        let otherMethod = ConditionRow(field: .method, op: .equals, value: "DELETE", caseSensitive: true)
        let hostOff = ConditionGroup(rows: [otherHost])
        let pathOff = ConditionGroup(rows: [hostIs, portIs, otherPath])
        let noneButOneMatches = ConditionGroup(mode: .none, rows: [otherHost, hostIs])
        let anyAllOff = ConditionGroup(mode: .any, rows: [otherHost, otherPath, otherMethod])
        let connectOff = ConditionGroup(rows: [otherHost])

        func rule(_ name: String, _ conditions: ConditionGroup, _ kind: ActionKind) -> Rule {
            Rule(name: name, conditions: conditions, actions: [RuleAction(kind)])
        }
        return [
            rule("1 url set", hostOff, .modifyURL(URLEditAction(mode: .set, replacement: "http://never.example:81/x?y=1"))),
            rule("2 url find", pathOff, .modifyURL(URLEditAction(mode: .findReplace, find: "/hello", replacement: "/bye"))),
            rule("3 url regex", noneButOneMatches, .modifyURL(URLEditAction(mode: .regex, find: "^(.*)$", replacement: "$1"))),
            rule("4 query", anyAllOff, .modifyQuery(QueryEditAction(operations: [.set(name: "a", value: "2"), .remove(name: "b")]))),
            rule("5 request cookies", pathOff, .editCookies(direction: .request, operations: [.set(name: "s", value: "1")])),
            rule("6 response cookies", hostOff, .editCookies(direction: .response, operations: [.remove(name: "s")])),
            rule("7 delay", pathOff, .delay(milliseconds: 60_000)),
            rule("8 handwritten", noneButOneMatches, .returnHandwritten(HandwrittenResponse(text: "HTTP/1.1 418 I'm a teapot\r\n\r\nno"))),
            rule("9 preset redirect", hostOff, .returnPreset(PresetResponse(preset: .found302, location: "https://never.example/"))),
            rule("10 preset refusal", anyAllOff, .returnPreset(PresetResponse(preset: .forbidden403, body: "no"))),
            rule("11 graceful close", pathOff, .closeConnection(.graceful)),
            rule("12 reset close", hostOff, .closeConnection(.reset)),
            rule("13 connect tunnel", connectOff, .returnConnectTunnel),
            rule("14 do not decrypt", connectOff, .noDecrypt),
        ]
    }

    @Test func theRuleSetCoversEveryNewActionKind() {
        let rules = Self.neverMatchingActionRules(host: "127.0.0.1", port: 1)
        let kinds = Set(rules.flatMap(\.actions).map { String(describing: $0.kind).prefix { $0 != "(" } })
        #expect(kinds == [
            "modifyURL", "modifyQuery", "editCookies", "delay", "returnHandwritten", "returnPreset", "closeConnection",
            "returnConnectTunnel", "noDecrypt",
        ])
        #expect(rules.compactMap { rule -> String? in
            if case .editCookies(let direction, _) = rule.actions[0].kind { direction.rawValue } else { nil }
        }.sorted() == ["request", "response"])
        #expect(rules.compactMap { rule -> CloseMode? in
            if case .closeConnection(let mode) = rule.actions[0].kind { mode } else { nil }
        } == [.graceful, .reset])
    }

    @Test func newActionRulesThatDoNotHoldLeaveBothWiresAndTheRecordAsWithoutRules() async throws {
        let origin = try await TestOriginServer.start()
        do {
            let requests = RulesUnusedByteIdenticalTests.requests(port: origin.port)
            let baseline = try await RulesUnusedByteIdenticalTests.capture(nil, requests, origin: { origin.receivedBytes })
            RulesUnusedByteIdenticalTests.expectServed(baseline, requests)
            let provider = TestRules.provider(Self.neverMatchingActionRules(host: "127.0.0.1", port: origin.port))
            let observed = try await RulesUnusedByteIdenticalTests.capture(provider, requests, origin: { origin.receivedBytes })
            RulesUnusedByteIdenticalTests.expectIdentical(observed, baseline, "fourteen new-action rules that match nothing")
            #expect(observed.flows.allSatisfy { $0.provenance == .passive })
            try await origin.stop()
        } catch { try? await origin.stop(); throw error }
    }

    @Test func conditionFreeNewActionRulesSwitchedOffLeaveTheTrafficAsWithoutRules() async throws {
        let origin = try await TestOriginServer.start()
        do {
            let requests = RulesUnusedByteIdenticalTests.requests(port: origin.port)
            let baseline = try await RulesUnusedByteIdenticalTests.capture(nil, requests, origin: { origin.receivedBytes })
            // The same rules, but matching: switched off globally they are as good as absent.
            let matching = Self.neverMatchingActionRules(host: "127.0.0.1", port: origin.port).map { rule -> Rule in
                var rule = rule
                rule.conditions = ConditionGroup()
                return rule
            }
            let off = TestRules.provider(matching)
            off.setEnabled(false)
            let observed = try await RulesUnusedByteIdenticalTests.capture(off, requests, origin: { origin.receivedBytes })
            RulesUnusedByteIdenticalTests.expectIdentical(observed, baseline, "condition-free new-action rules, rules switched off")
            #expect(observed.flows.allSatisfy { $0.provenance == .passive })
            try await origin.stop()
        } catch { try? await origin.stop(); throw error }
    }
}
