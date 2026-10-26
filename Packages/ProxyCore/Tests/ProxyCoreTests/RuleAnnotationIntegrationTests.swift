import FlowStore
import Foundation
import Testing
import os
@testable import ProxyCore
@testable import RulesEngine

/// Mark, comment and hide rules in real exchanges (Rules 2.0 R2): they write the flow's record and
/// never touch the traffic; a rule that may hide a flow at the request point holds its announcement
/// back until the request rules have run.
@Suite(.serialized, .timeLimit(.minutes(3)), .productionChinese) struct RuleAnnotationIntegrationTests {
    @Test func markRuleColoursTheFlowAndLeavesTheWireAlone() async throws {
        let marker = rule("red", [mark(red)])
        try await ProxyFixture.run(rules: TestRules.provider([marker])) { fx in
            let reply = try curl(["-x", fx.proxyURL, "-w", "\n%{http_code}", "http://localhost:\(fx.origin.port)/hello"])
            #expect(reply.text == "hello\n200")
            let flow = try await waitForFlow(fx.store) { $0.state == .completed }
            #expect(flow.ruleMark?.background == red)
            #expect(flow.ruleMark?.source == .rule(id: marker.id, name: "red"))
            #expect(flow.provenance.ruleMatches?.outcomes == [RuleOutcome(ruleID: marker.id, code: .applied)])
            #expect(flow.provenance.rulesModified == false)
            #expect(!flow.isHidden)
        }
    }

    @Test func commentRulesAppendInRuleOrder() async throws {
        let rules = TestRules.provider([rule("a", [comment("first")]), rule("b", [comment("second")])])
        try await ProxyFixture.run(rules: rules) { fx in
            _ = try curl(["-x", fx.proxyURL, "http://localhost:\(fx.origin.port)/hello"])
            let flow = try await waitForFlow(fx.store) { $0.state == .completed }
            #expect(flow.comment == "first second")
        }
    }

    @Test func statusJudgedMarkMarksOnlyMatchingResponses() async throws {
        let rules = TestRules.provider([rule("404", [mark(red)], rows: [status404])])
        try await ProxyFixture.run(rules: rules) { fx in
            for code in [404, 200] {
                _ = try curl(["-x", fx.proxyURL, "http://localhost:\(fx.origin.port)/status?code=\(code)"])
            }
            try await waitForCompletedFlows(fx.store, atLeast: 2)
            let flows = fx.store.allFlows()
            #expect(flows.first { $0.path.hasSuffix("404") }?.ruleMark?.background == red)
            #expect(flows.first { $0.path.hasSuffix("200") }?.ruleMark == nil)
        }
    }

    @Test func markOnAFailedRequestIsKept() async throws {
        let rules = TestRules.provider([rule("red", [mark(red)])])
        try await ProxyFixture.run(rules: rules) { fx in
            let reply = try curl(["-x", fx.proxyURL, "-w", "\n%{http_code}", "http://localhost:1/"])
            #expect(reply.text.hasSuffix("\n502"))
            let flow = try await waitForFlow(fx.store) { if case .failed = $0.state { true } else { false } }
            #expect(flow.ruleMark?.background == red)
        }
    }

    @Test func responseJudgedMarkIsNotAppliedWithoutAResponse() async throws {
        let rules = TestRules.provider([rule("404", [mark(red)], rows: [status404])])
        try await ProxyFixture.run(rules: rules) { fx in
            _ = try curl(["-x", fx.proxyURL, "http://localhost:1/"])
            let flow = try await waitForFlow(fx.store) { if case .failed = $0.state { true } else { false } }
            #expect(flow.ruleMark == nil)
        }
    }

    @Test func hideRuleHidesTheFlowButKeepsItInTheStore() async throws {
        let rules = TestRules.provider([rule("hide", [RuleAction(.hide)])])
        try await ProxyFixture.run(rules: rules) { fx in
            let reply = try curl(["-x", fx.proxyURL, "http://localhost:\(fx.origin.port)/hello"])
            #expect(reply.text == "hello")
            let flow = try await waitForFlow(fx.store) { $0.state == .completed }
            #expect(flow.isHidden)
            #expect(fx.store.allFlows().map(\.id) == [flow.id])
            #expect(fx.store.visibleFlows().isEmpty)
            #expect(fx.store.flowCount == 1)
        }
    }

    @Test func rejectedRuleStillAppliesEarlierMarks() async throws {
        let rejected = rule("reject", [RuleAction(.editHeaders(
            direction: .request, operations: [.set(name: "Content-Length", value: "1")]))])
        let rules = TestRules.provider([rule("red", [mark(red)]), rejected])
        try await ProxyFixture.run(rules: rules) { fx in
            let reply = try curl(["-x", fx.proxyURL, "-w", "\n%{http_code}", "http://localhost:\(fx.origin.port)/hello"])
            #expect(reply.text.hasSuffix("\n502"))
            let flow = try await waitForFlow(fx.store) { if case .failed = $0.state { true } else { false } }
            #expect(flow.ruleMark?.background == red)
            #expect(fx.origin.receivedRequestCount == 0)
        }
    }

    @Test func hiddenAtRequestPointNeverReachesASubscriberVisible() async throws {
        let rules = TestRules.provider([rule("hide", [RuleAction(.hide)], rows: [
            ConditionRow(field: .pathAndQuery, op: .startsWith, value: "/hide", caseSensitive: true)])])
        try await ProxyFixture.run(rules: rules) { fx in
            let announced = OSAllocatedUnfairLock(initialState: [Flow]())
            let stream = fx.store.changes()
            let task = Task { for await change in stream { announced.withLock { $0 += change.upserted } } }
            defer { task.cancel() }
            for index in 0..<15 {
                for kind in ["hide", "show"] {
                    _ = try curl(["-x", fx.proxyURL, "http://localhost:\(fx.origin.port)/\(kind)-\(index)"])
                }
            }
            try await waitUntil("every flow is announced") {
                Set(announced.withLock { $0 }.map(\.path)).count == 30
            }
            let seen = announced.withLock { $0 }
            for flow in seen where flow.path.hasPrefix("/hide") {
                #expect(flow.isHidden, "\(flow.path) was announced visible")
            }
            for flow in seen where flow.path.hasPrefix("/show") {
                #expect(!flow.isHidden, "\(flow.path) was announced hidden")
            }
        }
    }

    @Test func hideAtTheResponsePointHidesWhenTheResponseArrives() async throws {
        let rules = TestRules.provider([rule("hide 404", [RuleAction(.hide)], rows: [status404])])
        try await ProxyFixture.run(rules: rules) { fx in
            _ = try curl(["-x", fx.proxyURL, "http://localhost:\(fx.origin.port)/status?code=404"])
            let flow = try await waitForFlow(fx.store) { $0.state == .completed }
            #expect(flow.isHidden)
            #expect(fx.store.visibleFlows().isEmpty)
        }
    }

    @Test func snapshotWithoutAHideRuleNeverHoldsAFlow() async throws {
        let rules = TestRules.provider([rule("red", [mark(red)])])
        try await ProxyFixture.run(rules: rules) { fx in
            let stream = fx.store.changes()
            var iterator = stream.makeAsyncIterator()
            _ = try curl(["-x", fx.proxyURL, "http://localhost:\(fx.origin.port)/hello"])
            let first = await iterator.next()
            #expect(first?.upserted.map(\.path) == ["/hello"])
        }
    }

    @Test func annotationsApplyOnAnUpgradeHandshake() async throws {
        var heads: [String] = []
        for rules in [nil, TestRules.provider([rule("red", [mark(red)])])] as [RuleSnapshotProvider?] {
            try await ProxyFixture.run(rules: rules) { fx in
                let client = try await RawClient.connect(port: fx.proxyPort)
                let port = fx.origin.port
                try await client.send(
                    "GET http://localhost:\(port)/ws HTTP/1.1\r\nHost: localhost:\(port)\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n")
                heads.append(try await client.receive(until: "\r\n\r\n"))
                _ = try await client.receive(until: TestOriginServer.wsGreeting)
                try await client.close()
                let flow = try await waitForFlow(fx.store) { $0.path == "/ws" && $0.state == .completed }
                #expect(flow.statusCode == 101)
                #expect((flow.ruleMark?.background == red) == (rules != nil))
            }
        }
        #expect(heads.count == 2 && heads[0] == heads[1])
    }
}

private let red = "#FF3B30"
private let status404 = ConditionRow(field: .statusCode, op: .inRange, value: "404-404")

private func rule(_ name: String, _ actions: [RuleAction], rows: [ConditionRow] = []) -> Rule {
    Rule(name: name, conditions: ConditionGroup(rows: rows), actions: actions)
}

private func mark(_ background: String) -> RuleAction {
    RuleAction(.mark(MarkAction(background: background)))
}

private func comment(_ text: String) -> RuleAction {
    RuleAction(.comment(CommentAction(mode: .append, text: text)))
}
