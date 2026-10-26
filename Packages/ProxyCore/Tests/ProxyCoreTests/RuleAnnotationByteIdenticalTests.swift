import FlowStore
import Foundation
import NIOHTTP1
import Testing
@testable import ProxyCore
@testable import RulesEngine

/// Mark, comment and hide rules write the flow's record and never touch the traffic (Rules 2.0 R2): with
/// them applied to every exchange the origin receives the same bytes and the client the same bytes as with
/// no rules, and the only difference in the record is the four user fields. Where "hide" ends rule
/// evaluation, the rules below it do not run, which is the one intended effect on traffic.
@Suite(.serialized, .timeLimit(.minutes(5)), .productionChinese) struct RuleAnnotationByteIdenticalTests {
    typealias Base = RulesUnusedByteIdenticalTests

    // MARK: byte identity over real sockets

    @Test func annotationRulesLeaveWireBytesIdentical() async throws {
        let origin = try await TestOriginServer.start()
        do {
            let requests = Base.requests(port: origin.port)
            let baseline = try await Base.capture(nil, requests, origin: { origin.receivedBytes })
            Base.expectServed(baseline, requests)
            let annotated = try await Base.capture(Self.provider(Self.markAndComment), requests, origin: { origin.receivedBytes })
            Base.expectServed(annotated, requests)
            Self.expectSameTransport(annotated, baseline, "mark and comment")
            #expect(annotated.recorded.count == requests.count)
            for flow in annotated.recorded {
                #expect(flow.ruleMark != nil, "\(flow.path)")
                #expect(flow.ruleMark?.background == Self.red, "\(flow.path)")
                #expect(flow.comment == "audited", "\(flow.path)")
                #expect(!flow.isHidden, "\(flow.path)")
                #expect(flow.provenance.rulesModified == false, "\(flow.path)")
            }
            try await origin.stop()
        } catch { try? await origin.stop(); throw error }
    }

    @Test func hideRuleLeavesWireBytesIdenticalAndOnlyHidesTheFlow() async throws {
        let origin = try await TestOriginServer.start()
        do {
            let requests = Base.requests(port: origin.port)
            let baseline = try await Base.capture(nil, requests, origin: { origin.receivedBytes })
            let hidden = try await Self.observe(Self.provider([Self.rule("hide", RuleAction(.hide))]), requests) { origin.receivedBytes }
            Base.expectServed(hidden.capture, requests)
            Self.expectSameTransport(hidden.capture, baseline, "hide")
            #expect(hidden.capture.recorded.allSatisfy { $0.isHidden })
            #expect(hidden.flowCount == requests.count)
            #expect(hidden.visibleFlowCount == 0)
            try await origin.stop()
        } catch { try? await origin.stop(); throw error }
    }

    @Test func unmatchedAnnotationRulesLeaveFlowsPassive() async throws {
        let origin = try await TestOriginServer.start()
        do {
            let requests = Array(Base.requests(port: origin.port).prefix(4))
            let never = ConditionGroup(rows: [ConditionRow(field: .host, op: .hostPattern, value: "never.example")])
            let rules = [
                Rule(name: "mark", conditions: never, actions: [Self.mark]),
                Rule(name: "comment", conditions: never, actions: [Self.comment]),
                Rule(name: "hide", conditions: never, actions: [RuleAction(.hide)]),
                // Judged on the response, which is never a 599.
                Rule(name: "late", conditions: ConditionGroup(rows: [ConditionRow(field: .statusCode, op: .inRange, value: "599-599")]),
                     actions: [Self.mark, Self.comment, RuleAction(.hide)]),
            ]
            let provider = Self.provider(rules)
            let baseline = try await Base.capture(nil, requests, origin: { origin.receivedBytes })
            let capture = try await Base.capture(provider, requests, origin: { origin.receivedBytes })
            Base.expectServed(capture, requests)
            Base.expectIdentical(capture, baseline, "annotation rules that match nothing")
            #expect(provider.hits.snapshot().isEmpty)
            for flow in capture.recorded {
                #expect(flow.provenance == .passive, "\(flow.path)")
                #expect(flow.ruleMark == nil && flow.manualMark == nil && flow.comment == nil && !flow.isHidden, "\(flow.path)")
            }
            try await origin.stop()
        } catch { try? await origin.stop(); throw error }
    }

    @Test func perRuleControl() async throws {
        let origin = try await TestOriginServer.start()
        do {
            let requests = Array(Base.requests(port: origin.port).prefix(2))
            let baseline = try await Base.capture(nil, requests, origin: { origin.receivedBytes })
            for (name, action) in [("mark", Self.mark), ("comment", Self.comment), ("hide", RuleAction(.hide))] {
                let used = try await Base.capture(Self.provider([Self.rule(name, action)]), requests, origin: { origin.receivedBytes })
                #expect(used.flows.count == baseline.flows.count, "\(name)")
                #expect(used.flows != baseline.flows, "\(name): the record must show that the rule ran")
                #expect(used.flows.map(\.withoutUserFields) == baseline.flows.map(\.withoutUserFields), "\(name): only the record changes")
                #expect(used.client == baseline.client, "\(name)")
                #expect(used.origin == baseline.origin, "\(name)")
            }
            try await origin.stop()
        } catch { try? await origin.stop(); throw error }
    }

    @Test func hideCutsLowerHeaderRule() async throws {
        let origin = try await TestOriginServer.start()
        do {
            let requests = Array(Base.requests(port: origin.port).prefix(1))
            let header = Self.rule("probe", RuleAction(.editHeaders(direction: .request, operations: [.set(name: "X-Probe", value: "1")])))
            let hide = Self.rule("hide", RuleAction(.hide))
            let headerOnly = try await Base.capture(Self.provider([header]), requests, origin: { origin.receivedBytes })
            let hideFirst = try await Base.capture(Self.provider([hide, header]), requests, origin: { origin.receivedBytes })
            let hideLast = try await Base.capture(Self.provider([header, hide]), requests, origin: { origin.receivedBytes })
            #expect(Base.text(headerOnly.origin).contains("X-Probe: 1\r\n"))
            // "Hide" is a final action: the header rule below it does not run, and the exchange is the plain one.
            #expect(!Base.text(hideFirst.origin).contains("X-Probe"))
            #expect(hideFirst.recorded.allSatisfy { $0.isHidden })
            // Above it the header rule still runs.
            #expect(Base.text(hideLast.origin).contains("X-Probe: 1\r\n"))
            #expect(hideLast.recorded.allSatisfy { $0.isHidden })
            try await origin.stop()
        } catch { try? await origin.stop(); throw error }
    }

    // MARK: HTTP/2 and Upgrade

    @Test(arguments: LegPair.all)
    func http2AnnotationRulesAreIdentical(pair: LegPair) async throws {
        try await HTTP2TestOrigin.withOrigin(protocols: pair.origin) { origin in
            var observations: [Bool: H2Observation] = [:]
            for annotated in [false, true] {
                let before = origin.counts
                let rules = annotated ? Self.provider(Self.markAndComment) : nil
                try await HTTP2ProxyFixture.withProxy(origin: origin, downstreamH2: pair.downstreamH2, rules: rules) { fixture, client in
                    var upload = HTTPHeaders([
                        ("host", "localhost:\(origin.port)"), ("x-order", "a"), ("x-order", "b"), ("transfer-encoding", "chunked"),
                    ])
                    if pair.downstreamH2 { upload.remove(name: "transfer-encoding") }
                    let first = try await client.request(
                        headers: upload, path: "/one?x=%2f", method: .POST, body: "request-\u{0}payload",
                        trailers: HTTPHeaders([("x-trailer", "a"), ("x-trailer", "b")]))
                    let second = try await client.request(
                        headers: HTTPHeaders([("host", "localhost:\(origin.port)"), ("accept", "*/*"), ("x-dup", "1"), ("x-dup", "2")]),
                        path: "/two")
                    try await waitForCompletedFlows(fixture.store, atLeast: 2)
                    let flows = try fixture.store.allFlows().sorted { $0.id < $1.id }.map(FlowDigest.init)
                    observations[annotated] = H2Observation(
                        replies: [H2Reply(first), H2Reply(second)], origin: OriginView(origin.counts, since: before), flows: flows)
                }
            }
            let baseline = try #require(observations[false])
            let observed = try #require(observations[true])
            #expect(baseline.replies.map(\.status) == [200, 200])
            #expect(baseline.flows.count == 2)
            #expect(observed.replies == baseline.replies, "what the client received")
            #expect(observed.origin == baseline.origin, "what the origin received")
            #expect(observed.flows.map(\.withoutUserFields) == baseline.flows.map(\.withoutUserFields), "what the flows recorded")
            #expect(observed.flows.allSatisfy { $0.ruleMark != nil && $0.comment == "audited" && !$0.hidden })
            #expect(baseline.flows.allSatisfy { $0.ruleMark == nil && $0.comment == nil && !$0.hidden })
        }
    }

    @Test func upgradeHandshakeKeepsAnnotationsAndBytes() async throws {
        var observations: [Bool: UpgradeObservation] = [:]
        var marks: [Bool: (mark: String?, comment: String?)] = [:]
        for annotated in [false, true] {
            let serverFrame = WSWire.frame(1, Array("welcome".utf8))
            let clientFrame = WSWire.client(1, Array("ping".utf8))
            let directory = WebSocketIntegrationTests.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let origin = try await WebSocketOrigin.start(
                tls: false, script: [.send(bytes: Data(serverFrame)), .expect(bytes: Data(clientFrame)), .closeTransport],
                directory: directory)
            do {
                let rules = annotated ? Self.provider(Self.markAndComment) : nil
                try await RulesComposeServer.run(rules: rules) { fx in
                    let client = try await WSProxyPeer.connect(proxyPort: try fx.port, originPort: origin.port, tls: nil)
                    do {
                        try await client.send(bytes: WSWire.upgradeRequest(
                            target: "http://localhost:\(origin.port)/chat", port: origin.port, key: "dGhlIHNhbXBsZSBub25jZQ=="))
                        let head = try await client.receive(until: "\r\n\r\n")
                        let greeting = try await client.receive(count: serverFrame.count)
                        try await client.send(bytes: clientFrame)
                        try await client.waitUntilClosed()
                        try await origin.waitUntilFinished()
                        let (flow, token) = try await WebSocketIntegrationTests.session(fx.store)
                        try await waitUntil("ended WebSocket lifecycle") {
                            fx.store.webSocketSummary(token: token)?.lifecycle == .transportEndedWithoutClose
                        }
                        let rows = WebSocketIntegrationTests.rows(fx.store, token).map { row in
                            let payload = WebSocketIntegrationTests.payload(fx.store, token, row).map { String(decoding: $0, as: UTF8.self) }
                            return "\(row.direction) \(row.kind) \(payload ?? "-") \(row.integrity)"
                        }
                        let port = origin.port
                        func headers(_ boundary: HTTPMessageBoundary) -> [String]? {
                            fx.store.flow(flow.id)?.messages[boundary]?.headers.map { Base.hiding(port, in: "\($0.name): \($0.value)") }
                        }
                        let stored = fx.store.flow(flow.id)
                        marks[annotated] = (stored?.ruleMark?.background, stored?.comment)
                        var provenance = stored?.provenance
                        provenance?.ruleMatches = nil
                        observations[annotated] = UpgradeObservation(
                            clientHead: Base.hiding(port, in: head), clientBytes: greeting + client.remainingBytes(),
                            originHead: Base.hiding(port, in: origin.transcript.requestHead), originReceived: origin.received,
                            originSent: origin.sent, failures: origin.transcript.failures,
                            boundaries: [
                                HTTPMessageBoundary.downstreamRequest, .upstreamRequest, .upstreamResponse, .downstreamResponse,
                            ].map { headers($0) ?? [] },
                            events: rows, statusCode: stored?.statusCode, provenance: provenance)
                        try await client.close()
                    } catch { try? await client.close(); throw error }
                }
                try await origin.stop()
            } catch { try? await origin.stop(); throw error }
        }
        let baseline = try #require(observations[false])
        #expect(baseline.clientHead.hasPrefix("HTTP/1.1 101 "))
        #expect(baseline.statusCode == 101)
        #expect(baseline.events.count == 2, "\(baseline.events)")
        #expect(observations[true] == baseline)
        #expect(marks[false]?.mark == nil && marks[false]?.comment == nil)
        #expect(marks[true]?.mark == Self.red && marks[true]?.comment == "audited")
    }

    // MARK: Compose

    @Test func composeSendWithRulesOffIgnoresAnnotationRules() async throws {
        let origin = try await TestOriginServer.start()
        do {
            let sendID = try #require(UUID(uuidString: "00000000-0000-0000-0000-0000000C0DE8"))
            func send(rules: RuleSnapshotProvider?, applyRules: Bool) async throws -> ComposeObservation {
                let before = origin.receivedBytes.count
                var observed: ComposeObservation?
                try await RulesComposeServer.run(rules: rules) { fx in
                    let url = try #require(URL(string: "http://127.0.0.1:\(origin.port)/echo?a=1"))
                    let result = await fx.compose.send(ComposeRequest(
                        id: sendID, method: "POST", url: url,
                        headers: [HeaderField(name: "Content-Type", value: "text/plain")],
                        body: .bytes(Data("payload".utf8)), policy: ComposePolicy(applyRules: applyRules)))
                    let flowID = try #require(result.flowID)
                    let flow = try await waitForFlow(fx.store) { $0.id == flowID && $0.state == .completed }
                    observed = ComposeObservation(
                        response: result.response, failure: result.failure?.code, delivery: result.delivery,
                        flow: try FlowDigest(flow), origin: [])
                }
                var result = try #require(observed)
                result.origin = Array(origin.receivedBytes.dropFirst(before))
                return result
            }
            let baseline = try await send(rules: nil, applyRules: false)
            #expect(baseline.response?.status == 200)
            let off = try await send(rules: Self.provider(Self.markAndComment + [Self.rule("hide", RuleAction(.hide))]), applyRules: false)
            #expect(off == baseline)
            #expect(off.flow.ruleMark == nil && off.flow.comment == nil && !off.flow.hidden)
            // Control: switched on, the rules do write the record, and still not the traffic.
            let on = try await send(rules: Self.provider(Self.markAndComment), applyRules: true)
            #expect(on != baseline)
            #expect(on.flow.ruleMark != nil && on.flow.comment == "audited")
            #expect(on.origin == baseline.origin)
            #expect(on.response == baseline.response)
            try await origin.stop()
        } catch { try? await origin.stop(); throw error }
    }
}

// MARK: - Support

extension RuleAnnotationByteIdenticalTests {
    static let red = "#FF3B30"
    static let mark = RuleAction(.mark(MarkAction(background: red)))
    static let comment = RuleAction(.comment(CommentAction(mode: .append, text: "audited")))
    /// Match-all rules, one action each.
    static var markAndComment: [Rule] { [rule("mark", mark), rule("comment", comment)] }

    static func rule(_ name: String, _ action: RuleAction) -> Rule { Rule(name: name, actions: [action]) }
    static func provider(_ rules: [Rule]) -> RuleSnapshotProvider { TestRules.provider(rules) }

    /// Identical to the baseline in everything the exchange put on a wire or recorded of it, leaving aside
    /// the user fields (and the outcomes of the rules that wrote them).
    static func expectSameTransport(
        _ actual: Base.Capture, _ baseline: Base.Capture, _ name: String, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(actual.client == baseline.client, "\(name): what the client received", sourceLocation: sourceLocation)
        #expect(actual.origin == baseline.origin, "\(name): what the origin received", sourceLocation: sourceLocation)
        #expect(actual.flows.map(\.withoutUserFields) == baseline.flows.map(\.withoutUserFields), "\(name): what the flows recorded",
                sourceLocation: sourceLocation)
    }

    struct Observed {
        var capture: Base.Capture
        var flowCount: Int
        var visibleFlowCount: Int
    }

    /// `Base.capture`, with the store's counts read before the server goes away.
    static func observe(_ rules: RuleSnapshotProvider?, _ requests: [String], origin: () -> [UInt8]) async throws -> Observed {
        let before = origin().count
        var capture = Base.Capture()
        var counts = (0, 0)
        try await RulesComposeServer.run(rules: rules) { fx in
            for text in requests {
                let raw = try await RawClient.connect(port: try fx.port)
                do {
                    try await raw.send(text)
                    try await raw.waitUntilClosed()
                    capture.client.append(raw.remainingBytes())
                    try await raw.close()
                } catch { try? await raw.close(); throw error }
            }
            try await waitForCompletedFlows(fx.store, atLeast: requests.count)
            capture.recorded = fx.store.allFlows().sorted { $0.id < $1.id }
            capture.flows = try capture.recorded.map(FlowDigest.init)
            counts = (fx.store.flowCount, fx.store.visibleFlowCount)
        }
        capture.origin = Array(origin().dropFirst(before))
        return Observed(capture: capture, flowCount: counts.0, visibleFlowCount: counts.1)
    }
}
