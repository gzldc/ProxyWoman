import FlowStore
import Foundation
import Testing
@testable import ProxyCore
import RulesEngine

/// Rules whose conditions do not hold change nothing on either wire (R2 baseline), whether they use
/// only the old fields or the connection, header, cookie and query fields of R3.
@Suite(.serialized, .timeLimit(.minutes(3)), .productionChinese) struct RuleConditionByteIdenticalTests {
    private func neverMatchingNewFieldRules() -> [Rule] {
        let edits: [RuleAction] = [
            RuleAction(.editHeaders(direction: .request, operations: [.set(name: "X-Probe", value: "1")])),
            RuleAction(.editHeaders(direction: .response, operations: [.set(name: "X-Probe", value: "1")])),
            RuleAction(.rewriteStatus(RewriteStatusAction(status: 418))),
        ]
        let rows: [[ConditionRow]] = [
            [ConditionRow(field: .requestHeader, name: "X-Never", op: .equals, value: "1")],
            [ConditionRow(field: .requestCookie, name: "never", op: .equals, value: "1")],
            [ConditionRow(field: .queryParam, name: "never", op: .equals, value: "1")],
            [ConditionRow(field: .responseHeader, name: "X-Never", op: .equals, value: "1")],
            [ConditionRow(field: .clientIP, op: .equals, value: "203.0.113.9")],
            [ConditionRow(field: .remoteIP, op: .equals, value: "203.0.113.9")],
            [ConditionRow(field: .clientTLSVersion, op: .equals, value: "TLS 1.3")],
            [ConditionRow(field: .clientHTTPVersion, op: .equals, value: "HTTP/2")],
        ]
        return rows.map { Rule(name: "never", conditions: ConditionGroup(rows: $0), actions: edits) }
    }

    @Test func oldFieldRulesLeaveBothWiresAndTheRecordAsWithoutRules() async throws {
        let origin = try await TestOriginServer.start()
        do {
            let requests = RulesUnusedByteIdenticalTests.requests(port: origin.port)
            let baseline = try await RulesUnusedByteIdenticalTests.capture(nil, requests, origin: { origin.receivedBytes })
            let unmatched = RulesUnusedByteIdenticalTests.unmatchedProvider(host: "127.0.0.1", port: origin.port)
            let observed = try await RulesUnusedByteIdenticalTests.capture(unmatched, requests, origin: { origin.receivedBytes })
            #expect(!baseline.origin.isEmpty)
            #expect(observed.client == baseline.client)
            #expect(observed.origin == baseline.origin)
            #expect(observed.flows == baseline.flows)
            #expect(observed.flows.allSatisfy { $0.provenance == .passive })
            try await origin.stop()
        } catch { try? await origin.stop(); throw error }
    }

    @Test func newFieldRulesThatDoNotHoldLeaveBothWiresAndTheRecordAsWithoutRules() async throws {
        let origin = try await TestOriginServer.start()
        do {
            let requests = RulesUnusedByteIdenticalTests.requests(port: origin.port)
            let baseline = try await RulesUnusedByteIdenticalTests.capture(nil, requests, origin: { origin.receivedBytes })
            let provider = TestRules.provider(neverMatchingNewFieldRules())
            let observed = try await RulesUnusedByteIdenticalTests.capture(provider, requests, origin: { origin.receivedBytes })
            #expect(observed.client == baseline.client)
            #expect(observed.origin == baseline.origin)
            #expect(observed.flows == baseline.flows)
            #expect(observed.flows.allSatisfy { $0.provenance == .passive })
            try await origin.stop()
        } catch { try? await origin.stop(); throw error }
    }
}
