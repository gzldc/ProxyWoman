import FlowStore
import Foundation
import NIOCore
import NIOEmbedded
import NIOHTTP1
import Testing
@testable import ProxyCore
@testable import RulesEngine

/// The Allow list and Block list in the HTTP exchange: a block answers a local 403 before any
/// upstream is chosen, an Allow miss forwards without recording or rules, and an empty or absent
/// policy leaves every byte as before.
@Suite(.serialized, .timeLimit(.minutes(2)), .productionChinese) struct HTTPTrafficPolicyTests {
    private static func provider(
        allow: [String]? = nil, block: [String]? = nil, mode: BlockDisplayMode = .show
    ) -> (provider: TrafficPolicyProvider, blockID: UUID?) {
        var policy = TrafficPolicy()
        if let allow {
            policy.allowEnabled = true
            policy.allowEntries = allow.map { TrafficFilterEntry(matcher: RuleMatcher(hostPattern: $0)) }
        }
        var blockID: UUID?
        if let block {
            policy.blockEnabled = true
            policy.blockMode = mode
            policy.blockEntries = block.map { TrafficFilterEntry(matcher: RuleMatcher(hostPattern: $0)) }
            blockID = policy.blockEntries.first?.id
        }
        return (TrafficPolicyProvider(policy), blockID)
    }

    private static let headerRule = TestRules.headers(.request, [.set(name: "X-Rule", value: "1")])

    @Test func blockedRequestGets403AndNeverConnectsUpstream() async throws {
        try await withConnectionFixture { fixture in
            let (traffic, blockID) = Self.provider(block: ["example.test"])
            let writer = RecordingResponseWriter(channel: fixture.client)
            let exchange = fixture.admit("/blocked", writer: writer, context: fixture.context(traffic: traffic))
            exchange.receiveRequest(.end(nil))
            exchange.execute()
            #expect(writer.heads.map(\.status.code) == [403])
            #expect(writer.ends == 1)
            #expect(writer.body.contains("example.test"))
            #expect(fixture.connections.isEmpty)
            #expect(exchange.localFailure == .blockedByList)
            let flow = try fixture.flow("/blocked")
            if case .failed = flow.state {} else { Issue.record("expected a failed flow, got \(flow.state)") }
            #expect(flow.provenance.tools.blockedByEntry == blockID)
            #expect(flow.messages[.generatedResponse] != nil)
        }
    }

    @Test func blockHideModeRecordsNoFlowButStillBlocks() async throws {
        try await withConnectionFixture { fixture in
            let (traffic, _) = Self.provider(block: ["example.test"], mode: .hide)
            let writer = RecordingResponseWriter(channel: fixture.client)
            let exchange = fixture.admit("/hidden", writer: writer, context: fixture.context(traffic: traffic))
            exchange.receiveRequest(.end(nil))
            exchange.execute()
            #expect(writer.heads.map(\.status.code) == [403])
            #expect(writer.ends == 1)
            #expect(fixture.connections.isEmpty)
            #expect(exchange.flowID == nil)
            #expect(fixture.store.allFlows().isEmpty)
        }
    }

    @Test func allowMissForwardsWithoutRecordingOrRules() async throws {
        try await withConnectionFixture { fixture in
            let (traffic, _) = Self.provider(allow: ["only.test"])
            let writer = RecordingResponseWriter(channel: fixture.client)
            let exchange = fixture.admit("/passes", writer: writer,
                context: fixture.context(rules: TestRules.provider([Self.headerRule]), traffic: traffic))
            exchange.receiveRequest(.end(nil))
            exchange.execute()
            guard !fixture.connections.isEmpty else { Issue.record("an Allow miss must still be forwarded"); return }
            let upstream = try fixture.connect(0)
            let sent = try fixture.written(upstream)
            #expect(sent.hasPrefix("GET /passes HTTP/1.1\r\n"))
            #expect(!sent.contains("X-Rule"))
            try upstream.writeInbound(ByteBuffer(string: "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nX-Origin: yes\r\n\r\n"))
            fixture.loop.run()
            #expect(writer.heads.map(\.status.code) == [200])
            #expect(writer.heads.first?.headers["x-origin"] == ["yes"])
            #expect(exchange.flowID == nil)
            #expect(fixture.store.allFlows().isEmpty)
        }
    }

    @Test func allowHitRecordsAndAppliesRules() async throws {
        try await withConnectionFixture { fixture in
            let (traffic, _) = Self.provider(allow: ["example.test"])
            let writer = RecordingResponseWriter(channel: fixture.client)
            let exchange = fixture.admit("/hit", writer: writer,
                context: fixture.context(rules: TestRules.provider([Self.headerRule]), traffic: traffic))
            exchange.receiveRequest(.end(nil))
            exchange.execute()
            guard !fixture.connections.isEmpty else { Issue.record("an Allow hit must be forwarded"); return }
            let upstream = try fixture.connect(0)
            let sent = try fixture.written(upstream)
            #expect(sent.contains("X-Rule: 1\r\n"))
            try upstream.writeInbound(ByteBuffer(string: "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"))
            fixture.loop.run()
            #expect(writer.heads.map(\.status.code) == [200])
            let flow = try fixture.flow("/hit")
            #expect(flow.state == .completed)
            #expect(flow.provenance.ruleMatches?.total == 1)
            #expect(flow.provenance.tools.isEmpty)
        }
    }

    @Test func blockedHostOnRealServerReturns403AndOriginSeesNothing() async throws {
        let origin = try await ComposeOrigin.start(tls: nil)
        do {
            let (traffic, blockID) = Self.provider(block: ["127.0.0.1"])
            try await RulesComposeServer.run(traffic: traffic) { fx in
                let raw = try await RawClient.connect(port: try fx.port)
                do {
                    try await raw.send("GET http://127.0.0.1:\(origin.port)/x HTTP/1.1\r\nHost: 127.0.0.1:\(origin.port)\r\nConnection: close\r\n\r\n")
                    try await raw.waitUntilClosed()
                    let text = String(decoding: raw.remainingBytes(), as: UTF8.self)
                    try await raw.close()
                    #expect(text.hasPrefix("HTTP/1.1 403"), "\(text)")
                    #expect(text.contains("127.0.0.1"))
                } catch { try? await raw.close(); throw error }
                #expect(origin.state.withLock { $0.connections } == 0)
                let flow = try await waitForFlow(fx.store) { $0.path == "/x" && $0.state != .inProgress }
                #expect(flow.provenance.tools.blockedByEntry == blockID)
            }
            try await origin.stop()
        } catch { try? await origin.stop(); throw error }
    }

    @Test func composeSendIgnoresAllowListAndHideButNotBlock() async throws {
        let (traffic, _) = Self.provider(allow: ["elsewhere.test"])
        try await ComposeFixture.run(traffic: traffic) { fx in
            // An Allow miss does not stop an explicit send, and the send is recorded.
            let sent = await fx.compose.send(ComposeRequest(method: "GET", url: fx.url("/hello")))
            #expect(sent.failure == nil)
            #expect(sent.response?.body == Data("hello".utf8))
            let sentFlowID = try #require(sent.flowID)
            _ = try await waitForFlow(fx.store) { $0.id == sentFlowID && $0.state == .completed }

            // Block beats everything; hide mode does not hide an explicit send.
            var policy = traffic.current()
            policy.blockEnabled = true
            policy.blockMode = .hide
            let entry = TrafficFilterEntry(matcher: RuleMatcher(hostPattern: "127.0.0.1"))
            policy.blockEntries = [entry]
            traffic.publish(policy)
            let before = fx.origin.state.withLock { $0.requests["/hello"] }
            let blocked = await fx.compose.send(ComposeRequest(method: "GET", url: fx.url("/hello")))
            #expect(blocked.response == nil)
            #expect(blocked.failure?.code == "traffic.blocked")
            #expect(fx.origin.state.withLock { $0.requests["/hello"] } == before)
            let blockedFlowID = try #require(blocked.flowID)
            let flow = try await waitForFlow(fx.store) { $0.id == blockedFlowID && $0.state != .inProgress }
            #expect(flow.provenance.tools.blockedByEntry == entry.id)
            #expect(flow.provenance.isCompose)
            fx.expectIdle()
        }
    }

    @Test func emptyAndNilPolicyAreByteIdentical() async throws {
        let origin = try await ComposeOrigin.start(tls: nil)
        var responses: [[UInt8]] = []
        do {
            for traffic in [nil, TrafficPolicyProvider()] as [TrafficPolicyProvider?] {
                try await RulesComposeServer.run(traffic: traffic) { fx in
                    let raw = try await RawClient.connect(port: try fx.port)
                    do {
                        try await raw.send("GET http://127.0.0.1:\(origin.port)/hello?a=1 HTTP/1.1\r\nHost: 127.0.0.1:\(origin.port)\r\n"
                            + "X-Dup: 1\r\nAccept: */*\r\nX-Dup: 2\r\nConnection: close\r\n\r\n")
                        try await raw.waitUntilClosed()
                        responses.append(raw.remainingBytes())
                        try await raw.close()
                    } catch { try? await raw.close(); throw error }
                    _ = try await waitForFlow(fx.store) { $0.path == "/hello?a=1" && $0.state == .completed }
                }
            }
            let seen = origin.state.withLock { $0.heads }
            try await origin.stop()
            #expect(seen.count == 2)
            #expect(seen.first?.headers.map { "\($0.name): \($0.value)" } == seen.last?.headers.map { "\($0.name): \($0.value)" })
            #expect(seen.first?.uri == seen.last?.uri)
            #expect(seen.first?.method == seen.last?.method)
            func stripped(_ bytes: [UInt8]) -> String {
                String(decoding: bytes, as: UTF8.self).components(separatedBy: "\r\n")
                    .filter { !$0.lowercased().hasPrefix("date:") }.joined(separator: "\r\n")
            }
            #expect(responses.count == 2)
            #expect(stripped(responses[0]) == stripped(responses[1]))
            #expect(stripped(responses[0]).hasPrefix("HTTP/1.1 200"))
        } catch { try? await origin.stop(); throw error }
    }

    @Test func mergeToolsSurvivesRuleProvenanceUpdates() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("recorder-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FlowStore(bodyDirectory: directory)
        let loop = EmbeddedEventLoop()
        let recorder = FlowRecorder(
            store: store, scheme: "http", method: "GET", host: "example.test", port: 80, path: "/",
            requestHeaders: HTTPHeaders(), client: nil, eventLoop: loop)
        let entry = UUID()
        recorder.mergeTools { $0.blockedByEntry = entry }
        recorder.mergeTools { $0.networkCondition = "preset.threeG" }
        #expect(store.flow(recorder.id)?.provenance.tools
            == TrafficToolsProvenance(blockedByEntry: entry, networkCondition: "preset.threeG"))

        // What a rule session reports knows nothing of traffic tools; it must not erase them.
        let ruleID = UUID()
        var ruleProvenance = FlowProvenance.passive
        ruleProvenance.ruleMatches = RuleMatchSummary(revision: 1, ruleIDs: [ruleID], total: 1)
        recorder.setProvenance(ruleProvenance)
        let merged = try #require(store.flow(recorder.id)?.provenance)
        #expect(merged.ruleMatches?.ruleIDs == [ruleID])
        #expect(merged.tools.blockedByEntry == entry)
        #expect(merged.tools.networkCondition == "preset.threeG")

        // A newer set field replaces ours; unset ones keep ours.
        var newer = FlowProvenance.passive
        newer.tools = TrafficToolsProvenance(networkCondition: "custom")
        recorder.setProvenance(newer)
        let after = try #require(store.flow(recorder.id)?.provenance.tools)
        #expect(after.blockedByEntry == entry)
        #expect(after.networkCondition == "custom")
    }
}
