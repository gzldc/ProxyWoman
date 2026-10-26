import FlowStore
import Foundation
import NIOCore
import NIOEmbedded
import NIOHTTP1
import NIOPosix
import Testing
import os
@testable import ProxyCore
@testable import RulesEngine

/// Rules 2.0 changes nothing for traffic that does not use it (spec 8, 5.6.3): with no rule provider,
/// an empty snapshot, twenty rules of every action kind that match nothing, the global switch off, or a
/// Compose send that did not switch rules on, the origin receives the same bytes and the client the same
/// bytes, and every flow records the same boundaries. Where a rule does change something, the traffic is
/// the traffic a client or an origin that did the same thing by hand would have produced.
@Suite(.serialized, .timeLimit(.minutes(5)), .productionChinese) struct RulesUnusedByteIdenticalTests {
    // MARK: byte identity over real sockets

    @Test func noProviderAndEmptySnapshotProduceIdenticalWireBytes() async throws {
        let origin = try await TestOriginServer.start()
        do {
            let requests = Self.requests(port: origin.port)
            let (rules, _) = Self.unmatchedRules(host: "127.0.0.1", port: origin.port)
            #expect(rules.count == 20)
            #expect(Set(rules.flatMap(\.actions).map { String(describing: $0.kind).prefix { $0 != "(" } })
                == ["returnFile", "returnDirectory", "mapRemote", "editHeaders", "breakpoint", "rewriteBody", "rewriteStatus"])
            let baseline = try await Self.capture(nil, requests, origin: { origin.receivedBytes })
            Self.expectServed(baseline, requests)
            let empty = try await Self.capture(TestRules.provider([]), requests, origin: { origin.receivedBytes })
            let unmatched = try await Self.capture(
                Self.unmatchedProvider(host: "127.0.0.1", port: origin.port), requests, origin: { origin.receivedBytes })
            Self.expectIdentical(empty, baseline, "empty snapshot")
            Self.expectIdentical(unmatched, baseline, "twenty rules that match nothing")
            try await origin.stop()
        } catch { try? await origin.stop(); throw error }
    }

    @Test func globalSwitchOffAndNonMatchingRulesAreIdentical() async throws {
        let origin = try await TestOriginServer.start()
        do {
            let requests = Array(Self.requests(port: origin.port).prefix(3))
            let baseline = try await Self.capture(nil, requests, origin: { origin.receivedBytes })
            Self.expectServed(baseline, requests)

            // Rules that would change every exchange, switched off as a whole.
            let switchedOff = TestRules.provider(Self.matchingRules())
            switchedOff.setEnabled(false)
            let off = try await Self.capture(switchedOff, requests, origin: { origin.receivedBytes })
            Self.expectIdentical(off, baseline, "global switch off")

            // The same rules, each switched off on its own.
            let individually = TestRules.provider(Self.matchingRules().map { rule in
                var rule = rule
                rule.enabled = false
                return rule
            })
            let disabled = try await Self.capture(individually, requests, origin: { origin.receivedBytes })
            Self.expectIdentical(disabled, baseline, "every rule disabled")

            let unmatched = try await Self.capture(
                Self.unmatchedProvider(host: "127.0.0.1", port: origin.port), requests, origin: { origin.receivedBytes })
            Self.expectIdentical(unmatched, baseline, "twenty rules that match nothing")

            // Control: the same rules switched on do change the traffic, so the three comparisons above
            // had something to catch.
            let on = try await Self.capture(
                TestRules.provider(Self.matchingRules()), requests, origin: { origin.receivedBytes })
            #expect(on.client != baseline.client)
            #expect(on.origin != baseline.origin)
            #expect(String(decoding: on.origin, as: UTF8.self).contains("X-Probe: 1\r\n"))
            #expect(String(decoding: on.client[0], as: UTF8.self).contains("HTTP/1.1 418 "))
            try await origin.stop()
        } catch { try? await origin.stop(); throw error }
    }

    /// R4 T8: handwritten / preset / close-connection rules that match nothing leave the traffic and every
    /// flow (`FlowDigest`) as they are without rules.
    @Test func unmatchedGeneratedResponseRulesAreIdentical() async throws {
        let origin = try await TestOriginServer.start()
        do {
            let requests = Self.requests(port: origin.port)
            let baseline = try await Self.capture(nil, requests, origin: { origin.receivedBytes })
            Self.expectServed(baseline, requests)
            let never = ConditionGroup(rows: [ConditionRow(field: .host, op: .hostPattern, value: "never.example")])
            let rules = [
                Rule(name: "preset", conditions: never, actions: [RuleAction(.returnPreset(PresetResponse(preset: .forbidden403)))]),
                Rule(name: "handwritten", conditions: never,
                     actions: [RuleAction(.returnHandwritten(HandwrittenResponse(text: "HTTP/1.1 200 OK\r\n\r\nx")))]),
                Rule(name: "close", conditions: never, actions: [RuleAction(.closeConnection(.reset))]),
            ]
            let unmatched = try await Self.capture(TestRules.provider(rules), requests, origin: { origin.receivedBytes })
            Self.expectIdentical(unmatched, baseline, "generated-response rules that match nothing")
            try await origin.stop()
        } catch { try? await origin.stop(); throw error }
    }

    /// R4 T11: a CONNECT under no provider, an empty snapshot, twenty rules that never run at the CONNECT, or a
    /// CONNECT-point rule that does not match answers the same `200 Connection Established`, relays the same bytes
    /// and records the same tunnel row.
    @Test func connectUnderRulesThatDoNotRunThereIsIdentical() async throws {
        struct Capture: Equatable {
            var established: String
            var relayed: String
            var row: String
        }
        func capture(_ rules: ((Int) -> (rules: [Rule], groups: [RuleGroup]))?) async throws -> Capture {
            var result = Capture(established: "", relayed: "", row: "")
            let provider = rules.map { _ in TestRules.provider([]) }
            try await ProxyFixture.run(configure: { $0.decryption.enabled = false }, rules: provider) { fx in
                if let rules, let provider {
                    let (published, groups) = rules(fx.origin.port)
                    TestRules.publish(published, groups: groups, revision: 2, to: provider)
                }
                let client = try await RawClient.connect(port: fx.proxyPort)
                do {
                    try await client.send("CONNECT 127.0.0.1:\(fx.origin.port) HTTP/1.1\r\nHost: 127.0.0.1:\(fx.origin.port)\r\n\r\n")
                    result.established = try await client.receive(until: "\r\n\r\n")
                    try await client.send("GET /hello HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
                    result.relayed = try await client.receive(until: "hello")
                    try await client.close()
                } catch { try? await client.close(); throw error }
                let flow = try await waitForFlow(fx.store) { $0.method == "CONNECT" && $0.completedAt != nil }
                result.row = "\(flow.state) \(flow.host) \(flow.path) \(flow.provenance) \(String(describing: flow.ruleMark)) "
                    + "\(String(describing: flow.comment)) \(flow.isHidden) \(fx.store.allFlows().count)"
                result.relayed = result.relayed.split(separator: "\r\n").filter { !$0.lowercased().hasPrefix("date:") }
                    .joined(separator: "\r\n")
            }
            return result
        }
        let baseline = try await capture(nil)
        #expect(baseline.established == ProxyHandler.connectEstablished)
        let empty = try await capture { _ in ([], []) }
        let unmatched = try await capture { Self.unmatchedRules(host: "127.0.0.1", port: $0) }
        let p0Miss = try await capture { _ in
            ([Rule(name: "elsewhere", conditions: ConditionGroup(rows: [ConditionRow(field: .host, op: .equals, value: "never.example")]),
                   actions: [RuleAction(.closeConnection(.reset))])], [])
        }
        #expect(empty == baseline)
        #expect(unmatched == baseline)
        #expect(p0Miss == baseline)
    }

    /// Close rules that match nothing never reach the writer's close seam: the exchange goes upstream and
    /// answers exactly as without rules.
    @Test func unusedRulesLeaveWriterUntouched() async throws {
        try await withConnectionFixture { fixture in
            let never = ConditionGroup(rows: [ConditionRow(field: .host, op: .hostPattern, value: "never.example")])
            let unmatched = TestRules.provider(RulesEngine.CloseMode.allCases.map { mode in
                Rule(name: "close \(mode)", conditions: never, actions: [RuleAction(.closeConnection(mode))])
            })
            var observed: [(upstream: String, writer: RecordingResponseWriter)] = []
            for (index, rules) in [nil, unmatched].enumerated() {
                let writer = RecordingResponseWriter(channel: fixture.client)
                let exchange = fixture.admit("/same", writer: writer, context: fixture.context(rules: rules))
                exchange.receiveRequest(.end(nil))
                exchange.execute()
                let upstream = try fixture.connect(index)
                let sent = try fixture.written(upstream)
                try upstream.writeInbound(ByteBuffer(string: "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"))
                fixture.loop.run()
                observed.append((sent, writer))
            }
            let (plain, ruled) = (observed[0], observed[1])
            #expect(ruled.upstream == plain.upstream)
            #expect(ruled.writer.closes.isEmpty && plain.writer.closes.isEmpty)
            #expect(ruled.writer.aborts == 0 && plain.writer.aborts == 0)
            #expect(ruled.writer.heads == plain.writer.heads)
            #expect(ruled.writer.body == "ok" && plain.writer.body == "ok")
        }
    }

    @Test func ruleEditedTrafficEqualsHandEditedTraffic() async throws {
        // A request Header edit: the origin receives what a client that sent the header itself would send.
        do {
            let origin = try await LiteralAnswerOrigin.start(response: Self.plain)
            do {
                let target = "127.0.0.1:\(origin.port)"
                func request(_ extra: String) -> String {
                    "GET http://\(target)/hello?a=1 HTTP/1.1\r\nHost: \(target)\r\nAccept: */*\r\n\(extra)\r\n"
                }
                let probe = TestRules.headers(.request, [.set(name: "X-Probe", value: "1")])
                let plain = try await Self.exchange(request(""), rules: nil, origin: origin)
                let ruled = try await Self.exchange(request(""), rules: TestRules.provider([probe]), origin: origin)
                let byHand = try await Self.exchange(request("X-Probe: 1\r\n"), rules: nil, origin: origin)
                #expect(ruled.origin == byHand.origin, "request Header edit:\n\(Self.text(ruled.origin))\n---\n\(Self.text(byHand.origin))")
                #expect(ruled.client == byHand.client)
                #expect(ruled.origin != plain.origin)
                #expect(Self.text(ruled.origin).contains("X-Probe: 1\r\n"))
                try await origin.stop()
            } catch { try? await origin.stop(); throw error }
        }

        // A response Header edit: the client receives what an origin that sent the header itself would send.
        do {
            let editedByRule = try await LiteralAnswerOrigin.start(response: Self.plain)
            let editedByHand = try await LiteralAnswerOrigin.start(response: Self.plain(extraHeader: "X-Probe: 1"))
            do {
                let probe = TestRules.headers(.response, [.set(name: "X-Probe", value: "1")])
                let ruled = try await Self.exchange(Self.get(editedByRule), rules: TestRules.provider([probe]), origin: editedByRule)
                let byHand = try await Self.exchange(Self.get(editedByHand), rules: nil, origin: editedByHand)
                #expect(ruled.client == byHand.client, "response Header edit:\n\(Self.text(ruled.client))\n---\n\(Self.text(byHand.client))")
                #expect(Self.text(ruled.client).contains("X-Probe: 1\r\n"))
                // The rule did not touch the request.
                #expect(Self.text(ruled.origin, hiding: editedByRule.port) == Self.text(byHand.origin, hiding: editedByHand.port))
                try await editedByRule.stop()
                try await editedByHand.stop()
            } catch {
                try? await editedByRule.stop()
                try? await editedByHand.stop()
                throw error
            }
        }

        // A Map Remote: the target receives what a client that asked it directly would send, and the
        // original host receives nothing.
        do {
            let original = try await LiteralAnswerOrigin.start(response: Self.plain)
            let mapped = try await LiteralAnswerOrigin.start(response: Self.plain)
            do {
                let map = TestRules.mapRemote(host: "127.0.0.1", port: mapped.port, matcher: RuleMatcher(port: original.port))
                let ruled = try await Self.exchange(Self.get(original), rules: TestRules.provider([map]), origin: mapped)
                #expect(original.receivedBytes.isEmpty)
                // Map Remote drops the client's Host and the writer generates the target's after the other
                // fields (unchanged by Rules 2.0), so the client that asks the target directly lists Host last.
                let direct = try await Self.exchange(
                    Self.get(mapped, hostLast: true), rules: nil, origin: mapped)
                #expect(ruled.origin == direct.origin, "Map Remote:\n\(Self.text(ruled.origin))\n---\n\(Self.text(direct.origin))")
                #expect(ruled.client == direct.client)
                #expect(!ruled.origin.isEmpty)
                try await original.stop()
                try await mapped.stop()
            } catch {
                try? await original.stop()
                try? await mapped.stop()
                throw error
            }
        }

        // A status rewrite: the client receives what an origin that answered with that status itself would
        // send, status line reason phrase included.
        do {
            let rewritten = try await LiteralAnswerOrigin.start(response: Self.plain)
            let direct = try await LiteralAnswerOrigin.start(response: Self.plain(status: "404 Not Found"))
            do {
                let ruled = try await Self.exchange(Self.get(rewritten), rules: TestRules.provider([TestRules.rewriteStatus(404)]), origin: rewritten)
                let byHand = try await Self.exchange(Self.get(direct), rules: nil, origin: direct)
                #expect(ruled.client == byHand.client, "status rewrite:\n\(Self.text(ruled.client))\n---\n\(Self.text(byHand.client))")
                #expect(Self.text(ruled.client).hasPrefix("HTTP/1.1 404 Not Found\r\n"))
                try await rewritten.stop()
                try await direct.stop()
            } catch {
                try? await rewritten.stop()
                try? await direct.stop()
                throw error
            }
        }
    }

    @Test func nonMatchingRulesLeaveFlowProvenancePassive() async throws {
        let origin = try await TestOriginServer.start()
        do {
            let requests = Array(Self.requests(port: origin.port).prefix(4))
            let provider = Self.unmatchedProvider(host: "127.0.0.1", port: origin.port)
            #expect(provider.active()?.evaluationOrder.count == 20)
            let capture = try await Self.capture(provider, requests, origin: { origin.receivedBytes })
            Self.expectServed(capture, requests)
            // No rule matched, so no rule was counted either.
            #expect(provider.hits.snapshot().isEmpty)
            #expect(capture.flows.count == requests.count)
            for flow in capture.flows {
                #expect(flow.provenance == .passive, "\(flow.path)")
                #expect(!flow.provenance.rulesModified, "\(flow.path)")
                #expect(flow.provenance.ruleMatches == nil, "\(flow.path)")
                #expect(flow.provenance.generatedResponse == nil, "\(flow.path)")
                #expect(!flow.provenance.rulesDisabled, "\(flow.path)")
            }
        } catch { try? await origin.stop(); throw error }
        try await origin.stop()
    }

    @Test func migratedRulesNeverWriteActionIndexIntoProvenanceOrHAR() async throws {
        let origin = try await TestOriginServer.start()
        do {
            let request = "GET http://127.0.0.1:\(origin.port)/hello?a=1 HTTP/1.1\r\nHost: 127.0.0.1:\(origin.port)\r\nConnection: close\r\n\r\n"
            // Rules as an upgrading user has them: one action each, migrated by the repository seam.
            let old = [
                TestRules.headers(.request, [.set(name: "X-Probe", value: "1")]),
                TestRules.headers(.response, [.set(name: "X-Probe", value: "1")]),
                TestRules.rewriteBody(.response, find: "hello", replacement: "HELLO"),
                TestRules.rewriteStatus(418),
            ]
            let migrated = try await Self.capture(TestRules.provider(old), [request], origin: { origin.receivedBytes })
            let flow = try #require(migrated.flows.first)
            #expect(migrated.flows.count == 1)
            #expect(flow.provenance.rulesModified)
            let matches = try #require(flow.provenance.ruleMatches)
            #expect(matches.ruleIDs == old.map(\.id))
            #expect(matches.outcomes.count == old.count)
            #expect(matches.outcomes.allSatisfy { $0.code == .applied }, "\(matches.outcomes)")
            #expect(matches.outcomes.allSatisfy { $0.actionIndex == nil }, "\(matches.outcomes)")
            try Self.expectHARHasNoActionIndex(for: migrated.recorded)

            // Control: a rule written for 2.0 with two actions does carry the index in provenance, and the
            // HAR still does not export it, so the assertions above can tell the two apart.
            let two = Rule(name: "two actions", actions: [
                RuleAction(.editHeaders(direction: .request, operations: [.set(name: "X-Probe", value: "1")])),
                RuleAction(.editHeaders(direction: .response, operations: [.set(name: "X-Probe", value: "1")])),
            ])
            let native = try await Self.capture(TestRules.provider([two]), [request], origin: { origin.receivedBytes })
            let nativeOutcomes = try #require(native.flows.first?.provenance.ruleMatches?.outcomes)
            #expect(nativeOutcomes.map(\.actionIndex) == [0, 1], "\(nativeOutcomes)")
            try Self.expectHARHasNoActionIndex(for: native.recorded)
            try await origin.stop()
        } catch { try? await origin.stop(); throw error }
    }

    // MARK: HTTP/2 and Upgrade

    @Test(arguments: LegPair.all)
    func http2ExchangeWithNonMatchingRulesIsIdentical(pair: LegPair) async throws {
        try await HTTP2TestOrigin.withOrigin(protocols: pair.origin) { origin in
            var observations: [Variant: H2Observation] = [:]
            for variant in Variant.allCases {
                let before = origin.counts
                let rules = variant.provider(host: "localhost", port: origin.port)
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
                    observations[variant] = H2Observation(
                        replies: [H2Reply(first), H2Reply(second)], origin: OriginView(origin.counts, since: before), flows: flows)
                }
            }
            let baseline = try #require(observations[.noProvider])
            #expect(baseline.replies.map(\.status) == [200, 200])
            #expect(baseline.replies.map(\.body) == ["fixture-body", "fixture-body"])
            #expect(baseline.origin.headers.count == 2)
            #expect(baseline.flows.count == 2)
            #expect(baseline.flows.allSatisfy { $0.provenance == .passive })
            for variant in Variant.allCases where variant != .noProvider {
                let observed = try #require(observations[variant])
                if variant.changesTraffic {
                    #expect(observed.replies != baseline.replies, "\(variant): what the client received")
                    #expect(observed.origin != baseline.origin, "\(variant): what the origin received")
                } else {
                    #expect(observed.replies == baseline.replies, "\(variant): what the client received")
                    #expect(observed.origin == baseline.origin, "\(variant): what the origin received")
                    #expect(observed.flows == baseline.flows, "\(variant): what the flows recorded")
                }
            }
        }
    }

    @Test func upgradeHandshakeWithNonMatchingRulesIsIdentical() async throws {
        var observations: [Variant: UpgradeObservation] = [:]
        for variant in Variant.allCases {
            let serverFrame = WSWire.frame(1, Array("welcome".utf8))
            let clientFrame = WSWire.client(1, Array("ping".utf8))
            let directory = WebSocketIntegrationTests.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let origin = try await WebSocketOrigin.start(
                tls: false, script: [.send(bytes: Data(serverFrame)), .expect(bytes: Data(clientFrame)), .closeTransport],
                directory: directory)
            do {
                let rules = variant.provider(host: "localhost", port: origin.port)
                try await RulesComposeServer.run(rules: rules) { fx in
                    let client = try await WSProxyPeer.connect(proxyPort: try fx.port, originPort: origin.port, tls: nil)
                    do {
                        let key = "dGhlIHNhbXBsZSBub25jZQ=="
                        try await client.send(bytes: WSWire.upgradeRequest(
                            target: "http://localhost:\(origin.port)/chat", port: origin.port, key: key))
                        let head = try await client.receive(until: "\r\n\r\n")
                        let greeting = try await client.receive(count: serverFrame.count)
                        try await client.send(bytes: clientFrame)
                        try await client.waitUntilClosed()
                        try await origin.waitUntilFinished()
                        let (flow, token) = try await WebSocketIntegrationTests.session(fx.store)
                        // The origin ends the transport without a closing handshake.
                        try await waitUntil("ended WebSocket lifecycle") {
                            fx.store.webSocketSummary(token: token)?.lifecycle == .transportEndedWithoutClose
                        }
                        let rows = WebSocketIntegrationTests.rows(fx.store, token).map { row in
                            let payload = WebSocketIntegrationTests.payload(fx.store, token, row).map { String(decoding: $0, as: UTF8.self) }
                            return "\(row.direction) \(row.kind) \(payload ?? "-") \(row.integrity)"
                        }
                        let port = origin.port
                        func headers(_ boundary: HTTPMessageBoundary) -> [String]? {
                            fx.store.flow(flow.id)?.messages[boundary]?.headers.map { Self.hiding(port, in: "\($0.name): \($0.value)") }
                        }
                        observations[variant] = UpgradeObservation(
                            clientHead: Self.hiding(port, in: head), clientBytes: greeting + client.remainingBytes(),
                            originHead: Self.hiding(port, in: origin.transcript.requestHead), originReceived: origin.received,
                            originSent: origin.sent, failures: origin.transcript.failures,
                            boundaries: [
                                HTTPMessageBoundary.downstreamRequest, .upstreamRequest, .upstreamResponse, .downstreamResponse,
                            ].map { headers($0) ?? [] },
                            events: rows, statusCode: fx.store.flow(flow.id)?.statusCode, provenance: fx.store.flow(flow.id)?.provenance)
                        try await client.close()
                    } catch { try? await client.close(); throw error }
                }
                try await origin.stop()
            } catch { try? await origin.stop(); throw error }
        }
        let baseline = try #require(observations[.noProvider])
        #expect(baseline.clientHead.hasPrefix("HTTP/1.1 101 "))
        #expect(baseline.originHead.contains("Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"))
        #expect(baseline.statusCode == 101)
        #expect(baseline.events.count == 2, "\(baseline.events)")
        #expect(baseline.provenance == .passive)
        #expect(baseline.failures.isEmpty)
        for variant in Variant.allCases where variant != .noProvider {
            if variant.changesTraffic {
                #expect(observations[variant]?.originHead != baseline.originHead, "\(variant)")
                #expect(observations[variant]?.clientHead != baseline.clientHead, "\(variant)")
            } else {
                #expect(observations[variant] == baseline, "\(variant)")
            }
        }
    }

    @Test func composeSendWithRulesDisabledIsIdentical() async throws {
        let origin = try await TestOriginServer.start()
        do {
            let sendID = try #require(UUID(uuidString: "00000000-0000-0000-0000-0000000C0DE5"))
            func send(rules: RuleSnapshotProvider?, applyRules: Bool) async throws -> ComposeObservation {
                let before = origin.receivedBytes.count
                var observed: ComposeObservation?
                try await RulesComposeServer.run(rules: rules) { fx in
                    let url = try #require(URL(string: "http://127.0.0.1:\(origin.port)/echo?a=1"))
                    let result = await fx.compose.send(ComposeRequest(
                        id: sendID, method: "POST", url: url,
                        headers: [
                            HeaderField(name: "X-Dup", value: "1"), HeaderField(name: "Content-Type", value: "text/plain"),
                            HeaderField(name: "X-Dup", value: "2"),
                        ],
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
            // Compose sends the rules were not switched on for, whatever the server publishes.
            let baseline = try await send(rules: nil, applyRules: false)
            #expect(baseline.response?.status == 200)
            #expect(baseline.response?.body == Data("payload".utf8))
            #expect(baseline.flow.provenance.rulesDisabled)
            #expect(baseline.flow.provenance.ruleMatches == nil)
            #expect(Self.text(baseline.origin).contains("POST /echo?a=1 HTTP/1.1\r\n"))
            let published = try await send(rules: TestRules.provider(Self.matchingRules()), applyRules: false)
            #expect(published == baseline)
            let unmatched = try await send(
                rules: Self.unmatchedProvider(host: "127.0.0.1", port: origin.port), applyRules: false)
            #expect(unmatched == baseline)
            // Control: switched on, the same rules do change the send.
            let applied = try await send(rules: TestRules.provider(Self.matchingRules()), applyRules: true)
            #expect(applied != baseline)
            #expect(Self.text(applied.origin).contains("X-Probe: 1\r\n"))
            try await origin.stop()
        } catch { try? await origin.stop(); throw error }

        // What Compose sets, `HTTPExecutionPolicy.rulesEnabled == false`, on the exchange itself: the
        // upstream gets the request as it arrived and the client the response as it came.
        func run(rules: RuleSnapshotProvider?, policy: HTTPExecutionPolicy) async throws
            -> (sent: String, heads: [Int], probe: [String], provenance: FlowProvenance)
        {
            var outcome: (sent: String, heads: [Int], probe: [String], provenance: FlowProvenance)?
            try await withConnectionFixture { fixture in
                let writer = RecordingResponseWriter(channel: fixture.client)
                let exchange = fixture.admit(
                    "/policy?a=1", headers: HTTPHeaders([("X-Dup", "1"), ("Accept", "*/*"), ("X-Dup", "2")]), writer: writer,
                    context: fixture.context(rules: rules), policy: policy)
                exchange.receiveRequest(.end(nil))
                exchange.execute()
                let upstream = try fixture.connect(0)
                let sent = try fixture.written(upstream)
                try upstream.writeInbound(ByteBuffer(string: "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nX-Origin: yes\r\n\r\n"))
                fixture.loop.run()
                #expect(writer.heads.first?.headers["x-origin"] == ["yes"])
                outcome = (sent, writer.heads.map { Int($0.status.code) }, writer.heads.first?.headers["x-probe"] ?? [],
                           try fixture.flow("/policy?a=1").provenance)
            }
            return try #require(outcome)
        }
        let plain = try await run(rules: nil, policy: HTTPExecutionPolicy())
        let off = try await run(rules: TestRules.provider(Self.matchingRules()), policy: HTTPExecutionPolicy(rulesEnabled: false))
        #expect(off.sent == plain.sent)
        #expect(off.heads == plain.heads)
        #expect(off.probe == plain.probe)
        #expect(off.provenance == plain.provenance)
        #expect(!off.sent.contains("X-Probe") && off.probe.isEmpty)
        let on = try await run(rules: TestRules.provider(Self.matchingRules()), policy: HTTPExecutionPolicy())
        #expect(on.sent != plain.sent)
        #expect(on.sent.contains("X-Probe: 1\r\n"))
        #expect(on.probe == ["1"])
    }
}

// MARK: - Rules and requests

extension RulesUnusedByteIdenticalTests {
    /// How the server is given rules.
    enum Variant: CaseIterable, Hashable, CustomStringConvertible {
        /// No `RuleSnapshotProvider` at all.
        case noProvider
        /// A provider whose snapshot has no rule.
        case emptySnapshot
        /// Twenty rules of every action kind that match nothing the test sends.
        case nonMatching
        /// The control: rules that do change every exchange, so a comparison has something to catch.
        case matching

        var description: String {
            switch self {
            case .noProvider: "no provider"
            case .emptySnapshot: "empty snapshot"
            case .nonMatching: "twenty rules that match nothing"
            case .matching: "rules that match"
            }
        }

        /// Whether the traffic is expected to differ from the one without rules.
        var changesTraffic: Bool { self == .matching }

        func provider(host: String, port: Int) -> RuleSnapshotProvider? {
            switch self {
            case .noProvider: nil
            case .emptySnapshot: TestRules.provider([])
            case .nonMatching: RulesUnusedByteIdenticalTests.unmatchedProvider(host: host, port: port)
            case .matching: TestRules.provider(RulesUnusedByteIdenticalTests.matchingRules())
            }
        }
    }

    /// Rules that would change every exchange of these tests; used switched off, and switched on as a control.
    static func matchingRules() -> [Rule] {
        [
            Rule(name: "request edit", actions: [
                RuleAction(.editHeaders(direction: .request, operations: [.set(name: "X-Probe", value: "1")])),
            ]),
            Rule(name: "response edit", actions: [
                RuleAction(.editHeaders(direction: .response, operations: [.set(name: "X-Probe", value: "1")])),
            ]),
            Rule(name: "status", actions: [RuleAction(.rewriteStatus(RewriteStatusAction(status: 418)))]),
            Rule(name: "body", actions: [
                RuleAction(.rewriteBody(direction: .response, BodyRewriteAction(find: "hello", replacement: "HELLO"))),
            ]),
        ]
    }

    static func unmatchedProvider(host: String, port: Int) -> RuleSnapshotProvider {
        let (rules, groups) = unmatchedRules(host: host, port: port)
        return TestRules.provider(rules, groups: groups)
    }

    /// Twenty enabled rules, at least one of each of the seven action kinds in both directions where the
    /// kind has them, each with a condition group that cannot match a request to `host:port` that is
    /// answered with a status other than 599: one row off, an `any` group with every row off, a `none`
    /// group with a row that matches, a status range the response is not in, and a partial match (host
    /// and port right, path wrong). Four of them sit in a group; two have several actions.
    static func unmatchedRules(host: String, port: Int) -> (rules: [Rule], groups: [RuleGroup]) {
        let hostIs = ConditionRow(field: .host, op: .hostPattern, value: host)
        let portIs = ConditionRow(field: .port, op: .equals, value: String(port))
        let otherHost = ConditionRow(field: .host, op: .hostPattern, value: "never.example")
        let otherPort = ConditionRow(field: .port, op: .equals, value: String(port == 9 ? 10 : 9))
        let otherPath = ConditionRow(field: .pathAndQuery, op: .startsWith, value: "/never", caseSensitive: true)
        let otherMethod = ConditionRow(field: .method, op: .equals, value: "DELETE", caseSensitive: true)
        let otherScheme = ConditionRow(field: .scheme, op: .equals, value: "gopher")
        let otherStatus = ConditionRow(field: .statusCode, op: .inRange, value: "599-599")

        let off = ConditionGroup(rows: [otherHost])  // one row, off
        let wrongPath = ConditionGroup(rows: [otherPath])
        let wrongMethod = ConditionGroup(rows: [otherMethod])
        let wrongPort = ConditionGroup(rows: [otherPort])
        let wrongScheme = ConditionGroup(rows: [otherScheme])
        let noneButOneMatches = ConditionGroup(mode: .none, rows: [otherHost, hostIs])
        let anyAllOff = ConditionGroup(mode: .any, rows: [otherHost, otherPath, otherMethod])
        let partial = ConditionGroup(rows: [hostIs, portIs, otherPath])
        let wrongStatus = ConditionGroup(rows: [hostIs, otherStatus])
        let noneAllMatch = ConditionGroup(mode: .none, rows: [hostIs, portIs])

        func file() -> RuleAction { RuleAction(.returnFile(MapLocalAction(assetID: UUID(), headers: []))) }
        func directory() -> RuleAction {
            RuleAction(.returnDirectory(MapLocalDirectoryAction(bookmark: Data([1, 2, 3]), displayName: "site"), pathPrefix: "/never/"))
        }
        func remote() -> RuleAction {
            RuleAction(.mapRemote(MapRemoteAction(targetScheme: "http", targetHost: "never.example", targetPort: 81, path: .preserve)))
        }
        func edit(_ direction: HTTPMessageDirection) -> RuleAction {
            RuleAction(.editHeaders(direction: direction, operations: [.set(name: "X-Never", value: "1"), .remove(name: "Accept")]))
        }
        func breakpoint(_ direction: HTTPMessageDirection) -> RuleAction {
            RuleAction(.breakpoint(direction: direction, mode: .fullBody))
        }
        func body(_ direction: HTTPMessageDirection) -> RuleAction {
            RuleAction(.rewriteBody(direction: direction, BodyRewriteAction(find: "hello", replacement: "HELLO")))
        }
        func status(_ code: Int) -> RuleAction { RuleAction(.rewriteStatus(RewriteStatusAction(status: code))) }

        let group = RuleGroup(name: "never", order: 0)
        func rule(_ name: String, _ conditions: ConditionGroup, _ actions: [RuleAction], inGroup: Bool = false) -> Rule {
            Rule(name: name, groupID: inGroup ? group.id : nil, conditions: conditions, actions: actions)
        }
        let rules = [
            rule("1 file", off, [file()]),
            rule("2 directory", wrongPath, [directory()]),
            rule("3 remote", wrongMethod, [remote()]),
            rule("4 request edit and remote", wrongPort, [edit(.request), remote()]),
            rule("5 request breakpoint", wrongScheme, [breakpoint(.request)], inGroup: true),
            rule("6 request body", noneButOneMatches, [body(.request)], inGroup: true),
            rule("7 response edit", anyAllOff, [edit(.response)], inGroup: true),
            rule("8 response breakpoint", partial, [breakpoint(.response)], inGroup: true),
            rule("9 status", wrongStatus, [status(500)]),
            rule("10 file", noneAllMatch, [file()]),
            rule("11 response body", off, [body(.response)]),
            rule("12 remote", wrongPath, [remote()]),
            rule("13 response edit and status", wrongMethod, [edit(.response), status(404)]),
            rule("14 status", wrongPort, [status(204)]),
            rule("15 directory", wrongScheme, [directory()]),
            rule("16 response breakpoint", noneButOneMatches, [breakpoint(.response)]),
            rule("17 status", anyAllOff, [status(503)]),
            rule("18 request edit", partial, [edit(.request)]),
            rule("19 response edit", wrongStatus, [edit(.response)]),
            rule("20 response body", noneAllMatch, [body(.response)]),
        ]
        return (rules, [group])
    }

    /// Five requests of different shapes, each on its own connection that the client asks to close:
    /// duplicate and reordered headers, a fixed-length body, a chunked body, an error status, a JSON answer.
    static func requests(port: Int) -> [String] {
        let host = "127.0.0.1:\(port)"
        return [
            "GET http://\(host)/hello?a=1 HTTP/1.1\r\nHost: \(host)\r\nX-Dup: 1\r\nAccept: */*\r\nX-Dup: 2\r\nConnection: close\r\n\r\n",
            "POST http://\(host)/echo HTTP/1.1\r\nHost: \(host)\r\nContent-Type: application/json\r\nContent-Length: 13\r\n"
                + "Connection: close\r\n\r\n{\"b\":1,\"a\":2}",
            "POST http://\(host)/echo HTTP/1.1\r\nHost: \(host)\r\nContent-Type: text/plain\r\nTransfer-Encoding: chunked\r\n"
                + "Connection: close\r\n\r\n5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n",
            "GET http://\(host)/status?code=404 HTTP/1.1\r\nHost: \(host)\r\nConnection: close\r\n\r\n",
            "GET http://\(host)/json HTTP/1.1\r\nHost: \(host)\r\nAccept: application/json\r\nConnection: close\r\n\r\n",
        ]
    }

    /// The answer of a `LiteralAnswerOrigin`: a short text body with a fixed length.
    static var plain: String { plain() }

    static func plain(status: String = "200 OK", extraHeader: String? = nil) -> String {
        "HTTP/1.1 \(status)\r\nContent-Type: text/plain\r\nContent-Length: 5\r\n" + (extraHeader.map { "\($0)\r\n" } ?? "") + "\r\nhello"
    }

    /// A GET for `/hello?a=1` of the origin, in absolute form, with the connection left open.
    static func get(_ origin: LiteralAnswerOrigin, hostLast: Bool = false) -> String {
        let target = "127.0.0.1:\(origin.port)"
        let fields = ["Host: \(target)\r\n", "Accept: */*\r\n"]
        return "GET http://\(target)/hello?a=1 HTTP/1.1\r\n" + (hostLast ? fields.reversed() : fields).joined() + "\r\n"
    }
}

// MARK: - Running an exchange and comparing what was seen

extension RulesUnusedByteIdenticalTests {
    struct Capture {
        /// Every byte the client received, one entry per request.
        var client: [[UInt8]] = []
        /// Every byte the origin received while the requests ran.
        var origin: [UInt8] = []
        var flows: [FlowDigest] = []
        var recorded: [Flow] = []
    }

    /// Sends each request on a connection of its own to a real `ProxyServer` that has `rules`, and waits for the
    /// flows. `origin` reads the bytes the origin has received so far.
    static func capture(_ rules: RuleSnapshotProvider?, _ requests: [String], origin: () -> [UInt8]) async throws -> Capture {
        let before = origin().count
        var capture = Capture()
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
        }
        capture.origin = Array(origin().dropFirst(before))
        return capture
    }

    /// One request on a keep-alive connection, read up to the end of the answer's body ("hello").
    static func exchange(_ request: String, rules: RuleSnapshotProvider?, origin: LiteralAnswerOrigin) async throws -> (client: [UInt8], origin: [UInt8]) {
        let before = origin.receivedBytes.count
        var client: [UInt8] = []
        try await RulesComposeServer.run(rules: rules) { fx in
            let raw = try await RawClient.connect(port: try fx.port)
            do {
                try await raw.send(request)
                client = Array(try await raw.receive(until: "\r\n\r\nhello").utf8)
                try await raw.close()
            } catch { try? await raw.close(); throw error }
            try await waitForCompletedFlows(fx.store, atLeast: 1)
        }
        return (client, Array(origin.receivedBytes.dropFirst(before)))
    }

    static func text(_ bytes: [UInt8]) -> String { String(decoding: bytes, as: UTF8.self) }

    static func text(_ bytes: [UInt8], hiding port: Int) -> String { hiding(port, in: text(bytes)) }

    /// The port of the origin is the one thing that differs between two origins that are otherwise alike.
    static func hiding(_ port: Int, in text: String) -> String { text.replacingOccurrences(of: ":\(port)", with: ":PORT") }

    /// The requests got an answer, were not empty on the origin side and the flows are the ones expected.
    static func expectServed(_ capture: Capture, _ requests: [String], sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(capture.client.count == requests.count, sourceLocation: sourceLocation)
        for (index, bytes) in capture.client.enumerated() {
            #expect(text(bytes).hasPrefix("HTTP/1.1 "), "request \(index): \(text(bytes))", sourceLocation: sourceLocation)
        }
        let origin = text(capture.origin)
        for request in requests {
            let line = request.components(separatedBy: "\r\n")[0].split(separator: " ")
            // "GET http://127.0.0.1:1234/hello HTTP/1.1": the origin sees the origin form, `/hello`.
            let originForm = line[1].dropFirst("http://".count).drop { $0 != "/" }
            #expect(origin.contains("\(line[0]) \(originForm) HTTP/1.1\r\n"), "the origin never saw \(line[0]) \(originForm)",
                    sourceLocation: sourceLocation)
        }
        #expect(capture.flows.count == requests.count, sourceLocation: sourceLocation)
        #expect(capture.flows.allSatisfy { $0.state == .completed }, sourceLocation: sourceLocation)
    }

    static func expectIdentical(
        _ actual: Capture, _ baseline: Capture, _ name: String, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(actual.client.count == baseline.client.count, "\(name)", sourceLocation: sourceLocation)
        for (index, pair) in zip(actual.client, baseline.client).enumerated() {
            #expect(pair.0 == pair.1, "\(name): what the client received for request \(index)\n\(text(pair.0))\n---\n\(text(pair.1))",
                    sourceLocation: sourceLocation)
        }
        #expect(actual.origin == baseline.origin, "\(name): what the origin received\n\(text(actual.origin))\n---\n\(text(baseline.origin))",
                sourceLocation: sourceLocation)
        #expect(actual.flows.count == baseline.flows.count, "\(name)", sourceLocation: sourceLocation)
        for (index, pair) in zip(actual.flows, baseline.flows).enumerated() {
            #expect(pair.0 == pair.1, "\(name): flow \(index)\n\(pair.0)\n---\n\(pair.1)", sourceLocation: sourceLocation)
        }
    }

    /// The HAR entry of each flow lists rule outcomes by rule and code only, never by action.
    static func expectHARHasNoActionIndex(for flows: [Flow], sourceLocation: SourceLocation = #_sourceLocation) throws {
        for flow in flows {
            let data = try HARExporter.export([flow], creatorName: "Test", creatorVersion: "1")
            #expect(!String(decoding: data, as: UTF8.self).contains("actionIndex"), sourceLocation: sourceLocation)
            let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any], sourceLocation: sourceLocation)
            let entry = try #require(((root["log"] as? [String: Any])?["entries"] as? [[String: Any]])?.first, sourceLocation: sourceLocation)
            let provenance = try #require((entry["_proxywoman"] as? [String: Any])?["provenance"] as? [String: Any], sourceLocation: sourceLocation)
            let outcomes = try #require(provenance["ruleOutcomes"] as? [[String: Any]], sourceLocation: sourceLocation)
            #expect(!outcomes.isEmpty, sourceLocation: sourceLocation)
            #expect(outcomes.allSatisfy { Set($0.keys) == ["ruleID", "code"] }, "\(outcomes)", sourceLocation: sourceLocation)
        }
    }
}

// MARK: - What is compared

/// What a flow recorded about an exchange, without what differs from one run to the next (its number,
/// its times, where a body file lives): both ends' messages at every boundary, the bodies, the
/// transport, the byte counts and the provenance.
struct FlowDigest: Equatable, CustomStringConvertible {
    struct Boundary: Equatable {
        var message: HTTPMessageSnapshot
        var body: Data?
    }

    var scheme: String
    var method: String
    var host: String
    var port: Int
    var path: String
    var statusCode: Int?
    var statusReason: String?
    var state: FlowState
    var transport: HTTPTransportMetadata
    var requestHeaders: [HeaderField]
    var requestTrailers: [HeaderField]
    var responseHeaders: [HeaderField]
    var responseTrailers: [HeaderField]
    var requestBody: Data?
    var responseBody: Data?
    var requestBodyTruncated: Bool
    var responseBodyTruncated: Bool
    var bytesSent: Int
    var bytesReceived: Int
    var boundaries: [HTTPMessageBoundary: Boundary]
    var provenance: FlowProvenance
    /// What a user or a rule wrote on the record (never on the wire): the mark a rule left, the mark the
    /// user set, the comment, and whether the flow is hidden. Described as text so a difference reads.
    var ruleMark: String?
    var manualMark: String?
    var comment: String?
    var hidden: Bool

    init(_ flow: Flow) throws {
        scheme = flow.scheme
        method = flow.method
        host = flow.host
        port = flow.port
        path = flow.path
        statusCode = flow.statusCode
        statusReason = flow.statusReason
        state = flow.state
        // Connection info (client/remote IP, certificate, TLS versions) is recorded whether or not rules
        // exist; it is not traffic (D20), so the digest leaves it out.
        transport = flow.transport
        transport.downstreamTLSVersion = nil
        transport.upstreamTLSVersion = nil
        requestHeaders = flow.requestHeaders
        requestTrailers = flow.requestTrailers
        responseHeaders = flow.responseHeaders
        responseTrailers = flow.responseTrailers
        requestBody = try flow.requestBody?.load()
        responseBody = try flow.responseBody?.load()
        requestBodyTruncated = flow.requestBodyTruncated
        responseBodyTruncated = flow.responseBodyTruncated
        bytesSent = flow.bytesSent
        bytesReceived = flow.bytesReceived
        boundaries = try flow.messages.mapValues { message in
            var bare = message
            bare.body = nil
            return Boundary(message: bare, body: try message.body.map { try $0.load(maxBytes: 1 << 20).data })
        }
        provenance = flow.provenance
        ruleMark = flow.ruleMark.map { String(describing: $0) }
        manualMark = flow.manualMark.map { String(describing: $0) }
        comment = flow.comment
        hidden = flow.isHidden
    }

    /// The same flow as far as the transport is concerned: the four user fields cleared, and the rule
    /// outcomes with them (an annotation rule that applied is an outcome, not a change to the exchange).
    var withoutUserFields: FlowDigest {
        var copy = self
        copy.ruleMark = nil
        copy.manualMark = nil
        copy.comment = nil
        copy.hidden = false
        copy.provenance.ruleMatches = nil
        return copy
    }

    var description: String { "\(method) \(scheme)://\(host):\(port)\(path) \(String(describing: statusCode)) \(state) \(provenance)" }
}

struct H2Reply: Equatable {
    var status: Int
    var headers: [String]
    var body: String
    var trailers: [String]?

    init(_ response: HTTP2TestClient.Response) {
        status = response.status
        headers = response.headers.map { "\($0.name): \($0.value)" }
        body = response.body
        trailers = response.trailers?.map { "\($0.name): \($0.value)" }
    }
}

/// What the HTTP/2 test origin saw during one run: per request, the headers as the fixture parsed them, the
/// original HTTP/2 header block, the trailers, the authority and the stream.
struct OriginView: Equatable {
    var headers: [[String]]
    var originalHeaders: [[String]]
    var originalTrailers: [[String]]
    var authorities: [String]
    var streamIDs: [Int]
    var paths: [String]

    init(_ counts: HTTP2TestOrigin.Counts, since before: HTTP2TestOrigin.Counts) {
        func lines(_ headers: [HTTPHeaders]) -> [[String]] { headers.map { $0.map { "\($0.name): \($0.value)" } } }
        headers = lines(Array(counts.requestHeaders.dropFirst(before.requestHeaders.count)))
        originalHeaders = lines(Array(counts.originalHeaders.dropFirst(before.originalHeaders.count)))
        originalTrailers = lines(Array(counts.originalTrailers.dropFirst(before.originalTrailers.count)))
        authorities = Array(counts.authorities.dropFirst(before.authorities.count))
        streamIDs = Array(counts.streamIDs.dropFirst(before.streamIDs.count))
        paths = Array(counts.paths.dropFirst(before.paths.count))
    }
}

struct H2Observation: Equatable {
    var replies: [H2Reply]
    var origin: OriginView
    var flows: [FlowDigest]
}

struct UpgradeObservation: Equatable {
    var clientHead: String
    var clientBytes: [UInt8]
    var originHead: String
    var originReceived: [UInt8]
    var originSent: [UInt8]
    var failures: [String]
    /// The header lines of the downstream request, upstream request, upstream response and downstream response.
    var boundaries: [[String]]
    /// The WebSocket events the store recorded, as direction, kind, payload and integrity.
    var events: [String]
    var statusCode: Int?
    var provenance: FlowProvenance?
}

struct ComposeObservation: Equatable {
    var response: ComposeResponse?
    var failure: String?
    var delivery: ComposeDelivery
    var flow: FlowDigest
    var origin: [UInt8]
}

// MARK: - A scripted origin

/// A loopback origin that answers every complete request with the same literal bytes and keeps every byte it
/// received, so two runs can be compared down to the last byte of what each sent. Requests with a body must
/// declare a `Content-Length`.
final class LiteralAnswerOrigin: Sendable {
    let port: Int
    private let log: OSAllocatedUnfairLock<[UInt8]>
    private let group: MultiThreadedEventLoopGroup
    private let channel: Channel

    var receivedBytes: [UInt8] { log.withLock { $0 } }

    private init(port: Int, log: OSAllocatedUnfairLock<[UInt8]>, group: MultiThreadedEventLoopGroup, channel: Channel) {
        self.port = port
        self.log = log
        self.group = group
        self.channel = channel
    }

    static func start(response: String) async throws -> LiteralAnswerOrigin {
        let log = OSAllocatedUnfairLock<[UInt8]>(initialState: [])
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let answer = Array(response.utf8)
        do {
            let channel = try await ServerBootstrap(group: group).childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(LiteralAnswerHandler(response: answer, log: log))
                }
            }.bind(host: "127.0.0.1", port: 0).get()
            guard let port = channel.localAddress?.port else { throw ChannelError.unknownLocalAddress }
            return LiteralAnswerOrigin(port: port, log: log, group: group, channel: channel)
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
    }

    func stop() async throws {
        try? await channel.close().get()
        try await group.shutdownGracefully()
    }
}

private final class LiteralAnswerHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let response: [UInt8]
    private let log: OSAllocatedUnfairLock<[UInt8]>
    private var pending: [UInt8] = []

    init(response: [UInt8], log: OSAllocatedUnfairLock<[UInt8]>) {
        self.response = response
        self.log = log
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let bytes = Array(unwrapInboundIn(data).readableBytesView)
        log.withLock { $0.append(contentsOf: bytes) }
        pending.append(contentsOf: bytes)
        while let length = Self.completeRequestLength(pending) {
            pending.removeFirst(length)
            context.writeAndFlush(wrapOutboundOut(ByteBuffer(bytes: response)), promise: nil)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }

    /// The length of the first complete request in `bytes` (head and `Content-Length` body), or nil.
    private static func completeRequestLength(_ bytes: [UInt8]) -> Int? {
        let marker = Array("\r\n\r\n".utf8)
        guard bytes.count >= marker.count,
              let start = (0...(bytes.count - marker.count)).first(where: { bytes[$0..<($0 + marker.count)].elementsEqual(marker) })
        else { return nil }
        let headEnd = start + marker.count
        let head = String(decoding: bytes[..<headEnd], as: UTF8.self).lowercased()
        let length = head.components(separatedBy: "\r\n")
            .compactMap { $0.hasPrefix("content-length:") ? Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) : nil }
            .first ?? 0
        return bytes.count >= headEnd + length ? headEnd + length : nil
    }
}
