import FlowStore
import Foundation
import NIOCore
import NIOPosix
import Testing
@testable import ProxyCore
@testable import RulesEngine

private let red = MarkAction(background: "#FF0000")

private func rule(_ name: String, _ rows: [ConditionRow], _ actions: [RuleAction] = [RuleAction(.mark(red))]) -> Rule {
    Rule(name: name, conditions: ConditionGroup(rows: rows), actions: actions)
}

private func state(_ value: String) -> ConditionRow { ConditionRow(field: .sessionState, op: .equals, value: value) }

private let gzip4000: [UInt8] = [
    0x1f, 0x8b, 0x8, 0x0, 0x0, 0x0, 0x0, 0x0, 0x2, 0xff, 0xed, 0xc1, 0x31, 0x1, 0x0, 0x0, 0x0, 0xc2, 0xa0, 0xac, 0xeb, 0x5f,
    0xc2, 0x18, 0x3e, 0x40, 0x1, 0x0, 0x0, 0x0, 0x6f, 0x3, 0xeb, 0xbe, 0x85, 0x78, 0xa0, 0xf, 0x0, 0x0,
]

/// Rules judged when the flow finished (Rules 2.0 R3, P3): duration, response size and session state.
@Suite(.serialized, .timeLimit(.minutes(3)), .productionChinese) struct RuleCompletionIntegrationTests {
    private func get(_ fx: ProxyFixture, _ path: String, host: String? = nil) async throws -> DirectoryReply {
        try await directoryRaw(fx, host: host ?? "127.0.0.1:\(fx.origin.port)", path: path)
    }

    private func finished(_ fx: ProxyFixture, _ path: String) async throws -> Flow {
        try await waitForFlow(fx.store) { $0.path == path && $0.state != .inProgress }
    }

    @Test func durationRuleMarksEveryFinishedFlow() async throws {
        let marker = rule("any", [ConditionRow(field: .durationMs, op: .greaterOrEqual, value: "0")])
        try await ProxyFixture.run(rules: TestRules.provider([marker])) { fx in
            for path in ["/hello", "/json", "/status?code=404"] { _ = try await get(fx, path) }
            for path in ["/hello", "/json", "/status?code=404"] {
                #expect(try await finished(fx, path).ruleMark?.source == .rule(id: marker.id, name: "any"), "\(path)")
            }
        }
    }

    @Test func failedUpstreamIsMarkedByAStateRule() async throws {
        let failed = rule("failed", [state("failed")])
        let completed = rule("completed", [state("completed")])
        let origin = try await ScriptedOrigin.start(reply: [])
        do {
            try await ProxyFixture.run(rules: TestRules.provider([completed, failed])) { fx in
                _ = try await get(fx, "/reset", host: "127.0.0.1:\(origin.port)")
                let flow = try await finished(fx, "/reset")
                if case .failed = flow.state {} else { Issue.record("expected a failed flow") }
                #expect(flow.ruleMark?.source == .rule(id: failed.id, name: "failed"))
            }
            try await origin.stop()
        } catch { try? await origin.stop(); throw error }
    }

    @Test func clientCancelIsMarkedByAStateRule() async throws {
        let failed = rule("failed", [state("failed")])
        try await ProxyFixture.run(rules: TestRules.provider([failed])) { fx in
            let client = try await RawClient.connect(port: fx.proxyPort)
            try await client.send("GET http://127.0.0.1:\(fx.origin.port)/slow HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
            _ = try await waitForFlow(fx.store) { $0.path == "/slow" && $0.state == .inProgress && $0.bytesReceived == 5 }
            try await client.close()
            let flow = try await finished(fx, "/slow")
            if case .failed = flow.state {} else { Issue.record("expected a failed flow, got \(flow.state)") }
            #expect(flow.ruleMark?.source == .rule(id: failed.id, name: "failed"))
        }
    }

    @Test func ruleClosedExchangeStillReachesCompletion() async throws {
        // A response header edit the executor refuses ends the exchange with a local failure.
        let reject = rule("reject", [], [RuleAction(.editHeaders(
            direction: .response, operations: [.set(name: "Content-Length", value: "1")]))])
        let failed = rule("failed", [state("failed")])
        try await ProxyFixture.run(rules: TestRules.provider([reject, failed])) { fx in
            _ = try await get(fx, "/hello")
            let flow = try await finished(fx, "/hello")
            if case .failed = flow.state {} else { Issue.record("expected a failed flow, got \(flow.state)") }
            #expect(flow.ruleMark?.source == .rule(id: failed.id, name: "failed"))
        }
    }

    @Test func requestRejectionStillReachesCompletion() async throws {
        let reject = rule("reject", [], [RuleAction(.editHeaders(
            direction: .request, operations: [.set(name: "Content-Length", value: "1")]))])
        let failed = rule("failed", [state("failed")])
        try await ProxyFixture.run(rules: TestRules.provider([reject, failed])) { fx in
            _ = try await get(fx, "/hello")
            let flow = try await finished(fx, "/hello")
            if case .failed = flow.state {} else { Issue.record("expected a failed flow, got \(flow.state)") }
            #expect(fx.origin.receivedRequestCount == 0)
            #expect(flow.ruleMark?.source == .rule(id: failed.id, name: "failed"))
            #expect(flow.provenance.ruleMatches?.ruleIDs == [reject.id, failed.id])
        }
    }

    @Test func completionRunsForEveryTerminalPath() async throws {
        enum Path: String, CaseIterable { case success, upgrade, localFailure, cancelled }
        for path in Path.allCases {
            let marker = rule("any", [ConditionRow(field: .durationMs, op: .greaterOrEqual, value: "0")])
            try await ProxyFixture.run(rules: TestRules.provider([marker])) { fx in
                switch path {
                case .success: _ = try await get(fx, "/hello")
                case .upgrade:
                    let client = try await RawClient.connect(port: fx.proxyPort)
                    let port = fx.origin.port
                    try await client.send("GET http://127.0.0.1:\(port)/ws HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n")
                    let head = try await client.receive(until: "\r\n\r\n")
                    #expect(head.hasPrefix("HTTP/1.1 101 "))
                    try await client.close()
                case .localFailure: _ = try await get(fx, "/unreachable", host: "127.0.0.1:1")
                case .cancelled:
                    let client = try await RawClient.connect(port: fx.proxyPort)
                    try await client.send("GET http://127.0.0.1:\(fx.origin.port)/slow HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
                    _ = try await waitForFlow(fx.store) { $0.path == "/slow" && $0.bytesReceived == 5 }
                    try await client.close()
                }
                let flow = try await waitForFlow(fx.store) { $0.state != .inProgress }
                #expect(flow.ruleMark?.source == .rule(id: marker.id, name: "any"), "\(path)")
            }
        }
    }

    @Test func responseSizeRuleSeesWireBytes() async throws {
        let head = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Encoding: gzip\r\nContent-Length: \(gzip4000.count)\r\nConnection: close\r\n\r\n"
        let origin = try await ScriptedOrigin.start(reply: Array(head.utf8) + gzip4000)
        let wire = rule("wire", [ConditionRow(field: .responseBodySize, op: .lessThan, value: "100")])
        let decoded = rule("decoded", [ConditionRow(field: .responseBodySize, op: .greaterOrEqual, value: "4000")])
        do {
            try await ProxyFixture.run(rules: TestRules.provider([wire, decoded])) { fx in
                _ = try await get(fx, "/gz", host: "127.0.0.1:\(origin.port)")
                let flow = try await finished(fx, "/gz")
                #expect(flow.ruleMark?.source == .rule(id: wire.id, name: "wire"))
                #expect(flow.provenance.ruleMatches?.ruleIDs == [wire.id])
            }
            try await origin.stop()
        } catch { try? await origin.stop(); throw error }
    }

    @Test func hideAtCompletionHidesTheFlowAfterItFinished() async throws {
        let hide = rule("hide", [state("completed")], [RuleAction(.hide)])
        try await ProxyFixture.run(rules: TestRules.provider([hide])) { fx in
            _ = try await get(fx, "/hello")
            let flow = try await finished(fx, "/hello")
            #expect(flow.isHidden)
            #expect(fx.store.visibleFlows().isEmpty)
            #expect(fx.store.flowCount == 1)
        }
    }

    @Test func completionRuleCannotAddEditsToTrafficBytes() async throws {
        let paths = ["/hello", "/json", "/status?code=404"]
        func capture(_ provider: RuleSnapshotProvider?) async throws -> [String] {
            var replies: [String] = []
            try await ProxyFixture.run(rules: provider) { fx in
                for path in paths { replies.append(try await get(fx, path).raw) }
                try await waitForCompletedFlows(fx.store, atLeast: paths.count)
            }
            return replies
        }
        let withRule = rule("p3", [ConditionRow(field: .durationMs, op: .greaterOrEqual, value: "0")],
                            [RuleAction(.mark(red)), RuleAction(.comment(CommentAction(mode: .set, text: "x")))])
        let baseline = try await capture(nil)
        let marked = try await capture(TestRules.provider([withRule]))
        #expect(marked == baseline)
    }

    @Test func p3OutcomesAppearInProvenance() async throws {
        let request = rule("p1", [ConditionRow(field: .pathAndQuery, op: .startsWith, value: "/hello")])
        let response = rule("p2", [ConditionRow(field: .statusCode, op: .equals, value: "200")])
        let completion = rule("p3", [state("completed")])
        try await ProxyFixture.run(rules: TestRules.provider([request, response, completion])) { fx in
            _ = try await get(fx, "/hello")
            let flow = try await finished(fx, "/hello")
            let matches = try #require(flow.provenance.ruleMatches)
            #expect(matches.ruleIDs == [request.id, response.id, completion.id])
            #expect(matches.total == 3)
            #expect(matches.outcomes.map(\.ruleID) == [request.id, response.id, completion.id])
        }
    }

    @Test func p3CommentSeesAnnotationsOfEarlierPoints() async throws {
        let p1 = rule("p1", [], [RuleAction(.comment(CommentAction(mode: .set, text: "first")))])
        let p2 = rule("p2", [ConditionRow(field: .statusCode, op: .equals, value: "200")],
                      [RuleAction(.comment(CommentAction(mode: .append, text: "second")))])
        let p3 = rule("p3", [ConditionRow(field: .comment, op: .equals, value: "first second"), state("completed")],
                      [RuleAction(.comment(CommentAction(mode: .append, text: "third")))])
        try await ProxyFixture.run(rules: TestRules.provider([p1, p2, p3])) { fx in
            _ = try await get(fx, "/hello")
            #expect(try await finished(fx, "/hello").comment == "first second third")
        }
    }

    @Test func completionHookNotSetWithoutCompletionRules() async throws {
        try await withConnectionFixture { fixture in
            let plain = rule("p1", [ConditionRow(field: .pathAndQuery, op: .startsWith, value: "/")])
            let withP3 = rule("p3", [state("completed")])
            for (path, rules, expected) in [("/none", [plain], false), ("/some", [plain, withP3], true)] {
                let writer = RecordingResponseWriter(channel: fixture.client)
                let exchange = fixture.admit(path, writer: writer, context: fixture.context(rules: TestRules.provider(rules)))
                exchange.receiveRequest(.end(nil))
                exchange.execute()
                #expect((exchange.recorder?.completionHook != nil) == expected, "\(path)")
            }
        }
    }

    @Test func tunnelRowsAreNotEvaluated() async throws {
        let marker = rule("any", [ConditionRow(field: .durationMs, op: .greaterOrEqual, value: "0")])
        let provider = TestRules.provider([marker])
        try await ProxyFixture.run(rules: provider) { fx in
            let reply = try curl(["-p", "-x", fx.proxyURL, "http://localhost:\(fx.origin.port)/hello"])
            #expect(reply.text == "hello")
            let tunnel = try await waitForFlow(fx.store) { $0.method == "CONNECT" && $0.state != .inProgress }
            #expect(tunnel.ruleMark == nil)
            #expect(tunnel.provenance.ruleMatches == nil)
            #expect(provider.hits.snapshot().isEmpty)
        }
    }

    @Test func hitCountersCountCompletionMatches() async throws {
        let marker = rule("any", [state("completed")])
        let provider = TestRules.provider([marker])
        try await ProxyFixture.run(rules: provider) { fx in
            _ = try await get(fx, "/hello")
            _ = try await get(fx, "/json")
            _ = try await finished(fx, "/hello")
            _ = try await finished(fx, "/json")
            #expect(provider.hits.count(marker.id) == 2)
        }
    }
}
