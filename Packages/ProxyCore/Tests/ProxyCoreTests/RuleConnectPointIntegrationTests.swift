import Atomics
import CertKit
import FlowStore
import Foundation
import NIOCore
import NIOEmbedded
import NIOHTTP1
import NIOPosix
import Testing
@testable import ProxyCore
@testable import RulesEngine

private let red = MarkAction(background: "#FF0000")
private let markRed = RuleAction(.mark(red))
private let noDecrypt = RuleAction(.noDecrypt)
private let returnTunnel = RuleAction(.returnConnectTunnel)
private let hide = RuleAction(.hide)
private func note(_ text: String) -> RuleAction { RuleAction(.comment(CommentAction(mode: .set, text: text))) }
private func close(_ mode: RulesEngine.CloseMode) -> RuleAction { RuleAction(.closeConnection(mode)) }

private func rule(_ name: String = "p0", when rows: [ConditionRow] = [], _ actions: RuleAction...) -> Rule {
    Rule(name: name, conditions: ConditionGroup(rows: rows), actions: actions)
}
private func hostIs(_ host: String) -> ConditionRow { ConditionRow(field: .host, op: .equals, value: host) }
private func portIs(_ port: Int) -> ConditionRow { ConditionRow(field: .port, op: .equals, value: String(port)) }
private func urlContains(_ text: String) -> ConditionRow { ConditionRow(field: .url, op: .contains, value: text) }
private func pathStarts(_ text: String) -> ConditionRow {
    ConditionRow(field: .pathAndQuery, op: .startsWith, value: text, caseSensitive: true)
}

private func connectLine(_ authority: String) -> String { "CONNECT \(authority) HTTP/1.1\r\nHost: \(authority)\r\n\r\n" }

/// The CONNECT point (P0, R4 T11, D11–D14): rules judged at the CONNECT can close it before the 200, keep a
/// decrypted host out of decryption, or let decryption go on while cutting the rules below; their marks,
/// comments and hide land on the CONNECT's own row when it keeps one (tunnel, closed), and are dropped for a
/// decrypted CONNECT, which has none. The tools decide first; without a P0 rule nothing here changes.
@Suite(.productionChinese, .serialized, .timeLimit(.minutes(4))) struct RuleConnectPointIntegrationTests {
    // MARK: untouched without P0 rules, and behind the tools

    @Test func connectPathUntouchedWithoutP0Rules() async throws {
        // Twenty rules that never run at the CONNECT (none has a CONNECT-capable action), plus a request-point mark.
        let (rules, groups) = RulesUnusedByteIdenticalTests.unmatchedRules(host: "127.0.0.1", port: 9)
        let provider = TestRules.provider(rules + [rule("request mark", when: [pathStarts("/never")], markRed)], groups: groups)
        try await ProxyFixture.run(configure: { $0.decryption.enabled = false }, rules: provider) { fx in
            let client = try await RawClient.connect(port: fx.proxyPort)
            do {
                try await client.send(connectLine("127.0.0.1:\(fx.origin.port)"))
                #expect(try await client.receive(until: "\r\n\r\n") == ProxyHandler.connectEstablished)
                try await client.send("GET /hello HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
                _ = try await client.receive(until: "hello")
                try await client.close()
            } catch { try? await client.close(); throw error }
            let flow = try await waitForFlow(fx.store) { $0.method == "CONNECT" && $0.completedAt != nil }
            #expect(flow.state == .tunnel)
            #expect(flow.provenance.ruleMatches == nil)
            #expect(flow.ruleMark == nil && flow.comment == nil && !flow.isHidden)
            #expect(provider.readCounts.active == 0, "the CONNECT never takes the request-point snapshot")
            #expect(rules.allSatisfy { provider.hits.connectCount($0.id) == 0 })
        }
    }

    @Test func blockedConnectNeverReachesRules() async throws {
        let provider = TestRules.provider([rule(when: [], close(.reset)), rule(when: [], noDecrypt)])
        var policy = TrafficPolicy()
        policy.blockEnabled = true
        policy.blockEntries = [TrafficFilterEntry(matcher: RuleMatcher(hostPattern: "127.0.0.1"))]
        try await RulesComposeServer.run(rules: provider, traffic: TrafficPolicyProvider(policy)) { fx in
            let reply = try await wireExchange(port: try fx.port, connectLine("127.0.0.1:9"))
            #expect(String(decoding: reply.bytes, as: UTF8.self).hasPrefix("HTTP/1.1 403"))
            _ = try await waitForFlow(fx.store) { $0.method == "CONNECT" && $0.completedAt != nil }
            #expect(provider.readCounts == .init(active: 0, connect: 0))
            #expect(provider.current().rules.allSatisfy { provider.hits.connectCount($0.id) == 0 })
        }
    }

    @Test func allowMissNeverReachesRules() async throws {
        let provider = TestRules.provider([rule(when: [], close(.reset))])
        var policy = TrafficPolicy()
        policy.allowEnabled = true
        policy.allowEntries = [TrafficFilterEntry(matcher: RuleMatcher(hostPattern: "elsewhere.test"))]
        let origin = try await TestOriginServer.start()
        do {
            try await RulesComposeServer.run(rules: provider, traffic: TrafficPolicyProvider(policy)) { fx in
                let client = try await RawClient.connect(port: try fx.port)
                do {
                    try await client.send(connectLine("127.0.0.1:\(origin.port)"))
                    #expect(try await client.receive(until: "\r\n\r\n") == ProxyHandler.connectEstablished)
                    try await client.close()
                } catch { try? await client.close(); throw error }
                #expect(provider.readCounts == .init(active: 0, connect: 0))
                #expect(fx.store.allFlows().isEmpty)
            }
        } catch { try? await origin.stop(); throw error }
        try await origin.stop()
    }

    // MARK: not decrypting, returning the tunnel

    @Test func noDecryptTunnelsADecryptedHost() async throws {
        let setup = try HTTPSSetup()
        let tunnel = rule("plain", when: [hostIs("localhost")], noDecrypt)
        try await setup.run(rules: TestRules.provider([tunnel])) { fx in
            // Only the origin's own certificate (CA B) is trusted: the handshake succeeds only end to end.
            let r = try curl(["-x", fx.proxyURL, "--cacert", setup.originCAFile, "https://localhost:\(fx.origin.port)/hello"])
            #expect(r.exitCode == 0, "\(r.stderr)")
            #expect(r.text == "hello")
            let flow = try await waitForFlow(fx.store) { $0.method == "CONNECT" && $0.completedAt != nil }
            #expect(flow.state == .tunnel)
            #expect(flow.bytesSent > 0 && flow.bytesReceived > 0)
            #expect(flow.provenance.ruleMatches?.outcomes == [RuleOutcome(ruleID: tunnel.id, code: .applied)])
            #expect(fx.store.allFlows().count == 1)
        }
    }

    @Test func noDecryptMatchesByHostAndPortOnly() async throws {
        for samePort in [false, true] {
            let setup = try HTTPSSetup()
            let provider = TestRules.provider([])
            try await setup.run(rules: provider) { fx in
                let p = fx.origin.port
                TestRules.publish([rule("plain", when: [hostIs("localhost"), portIs(samePort ? p : p + 1)], noDecrypt)],
                                  revision: 2, to: provider)
                let trusted = samePort ? setup.originCAFile : setup.proxyCAFile
                // Any path: the CONNECT has none, and the rule reads only the host and the port.
                let r = try curl(["-x", fx.proxyURL, "--cacert", trusted, "https://localhost:\(p)/hello?x=1"])
                #expect(r.exitCode == 0, "samePort \(samePort): \(r.stderr)")
                if samePort {
                    _ = try await waitForFlow(fx.store) { $0.method == "CONNECT" && $0.state == .tunnel }
                } else {
                    _ = try await waitForFlow(fx.store) { $0.path == "/hello?x=1" && $0.state == .completed }
                    #expect(!fx.store.allFlows().contains { $0.method == "CONNECT" })
                }
            }
        }
    }

    @Test func returnConnectTunnelStillIntercepts() async throws {
        let setup = try HTTPSSetup()
        try await setup.run(rules: TestRules.provider([rule("intercept", when: [hostIs("localhost")], returnTunnel)])) { fx in
            let r = try curl(["-x", fx.proxyURL, "--cacert", setup.proxyCAFile, "https://localhost:\(fx.origin.port)/hello"])
            #expect(r.exitCode == 0, "\(r.stderr)")
            let flow = try await waitForFlow(fx.store) { $0.path == "/hello" && $0.state == .completed }
            #expect(flow.scheme == "https")
            #expect(fx.store.allFlows().count == 1)
        }
    }

    @Test func returnConnectTunnelCutsLowerNoDecrypt() async throws {
        let setup = try HTTPSSetup()
        let rules = [rule("keep decrypting", when: [hostIs("localhost")], returnTunnel), rule("plain", when: [], noDecrypt)]
        try await setup.run(rules: TestRules.provider(rules)) { fx in
            let r = try curl(["-x", fx.proxyURL, "--cacert", setup.proxyCAFile, "https://localhost:\(fx.origin.port)/hello"])
            #expect(r.exitCode == 0, "\(r.stderr)")
            _ = try await waitForFlow(fx.store) { $0.path == "/hello" && $0.state == .completed }
            #expect(!fx.store.allFlows().contains { $0.method == "CONNECT" })
        }
    }

    @Test func toolDecidedTunnelRecordsSkippedByTool() async throws {
        let setup = try HTTPSSetup()
        let plain = rule("plain", when: [hostIs("localhost")], noDecrypt)
        try await setup.run(configure: { $0.decryption.excludedHosts = ["localhost"] }, rules: TestRules.provider([plain])) { fx in
            let r = try curl(["-x", fx.proxyURL, "--cacert", setup.originCAFile, "https://localhost:\(fx.origin.port)/hello"])
            #expect(r.exitCode == 0, "\(r.stderr)")
            let flow = try await waitForFlow(fx.store) { $0.method == "CONNECT" && $0.completedAt != nil }
            #expect(flow.state == .tunnel)
            #expect(flow.provenance.ruleMatches?.outcomes == [RuleOutcome(ruleID: plain.id, code: .skippedByTool)])
        }
    }

    @Test func pinningPassthroughHostsUnaffected() async throws {
        let setup = try HTTPSSetup()
        let decrypt = rule("keep decrypting", when: [hostIs("localhost")], returnTunnel)
        try await setup.run(rules: TestRules.provider([decrypt])) { fx in
            #expect(fx.passthrough.insert("localhost"))
            // The rule cannot bring a passthrough host back into decryption: the origin's certificate arrives.
            let r = try curl(["-x", fx.proxyURL, "--cacert", setup.originCAFile, "https://localhost:\(fx.origin.port)/hello"])
            #expect(r.exitCode == 0, "\(r.stderr)")
            let flow = try await waitForFlow(fx.store) { $0.method == "CONNECT" && $0.completedAt != nil }
            #expect(flow.state == .tunnel)
            #expect(flow.provenance.ruleMatches?.outcomes == [RuleOutcome(ruleID: decrypt.id, code: .skippedByTool)])
            #expect(fx.passthrough.hosts == ["localhost"])
        }
    }

    @Test func connectToUnreachableHostStillReportsUnreachable() async throws {
        let setup = try HTTPSSetup()
        let plain = rule("plain", when: [hostIs("localhost")], markRed, noDecrypt)
        try await setup.run(rules: TestRules.provider([plain])) { fx in
            let r = try curl(["-x", fx.proxyURL, "--cacert", setup.originCAFile, "-w", "%{http_connect}", "https://localhost:1/hello"])
            #expect(r.exitCode != 0)
            #expect(r.text.hasSuffix("502"), "\(r.text) \(r.stderr)")
            let flow = try await waitForFlow(fx.store) { $0.method == "CONNECT" && $0.completedAt != nil }
            #expect(flow.state == .failed("连接被拒绝"))
            #expect(flow.ruleMark?.source == .rule(id: plain.id, name: "plain"))
            #expect(flow.provenance.ruleMatches?.outcomes.contains(RuleOutcome(ruleID: plain.id, code: .applied, actionIndex: 1)) == true)
        }
    }

    // MARK: closing before the 200

    @Test func closeBeforeTheOKLine() async throws {
        try await ProxyFixture.run(rules: TestRules.provider([rule(when: [], close(.graceful))])) { fx in
            let reply = try await wireExchange(port: fx.proxyPort, connectLine("127.0.0.1:\(fx.origin.port)"))
            #expect(reply.bytes.isEmpty, "\(String(decoding: reply.bytes, as: UTF8.self))")
            #expect(reply.ending == .fin)
            #expect(fx.origin.acceptedConnections == 0)
        }
    }

    @Test func closeResetIsRST() async throws {
        try await ProxyFixture.run(rules: TestRules.provider([rule(when: [], close(.reset))])) { fx in
            let reply = try await wireExchange(port: fx.proxyPort, connectLine("127.0.0.1:\(fx.origin.port)"))
            #expect(reply.bytes.isEmpty)
            #expect(reply.ending == .reset)
            #expect(fx.origin.acceptedConnections == 0)
        }
    }

    @Test func closeRecordsAFailedConnectRow() async throws {
        let shut = rule("Shut it", when: [portIs(443)], close(.reset))
        try await ProxyFixture.run(rules: TestRules.provider([shut])) { fx in
            _ = try await wireExchange(port: fx.proxyPort, connectLine("127.0.0.1:443"))
            let flow = try await waitForFlow(fx.store) { $0.method == "CONNECT" && $0.completedAt != nil }
            let reason = HTTPLocalFailureText.ruleClosed(ruleName: "Shut it")
            #expect(reason.contains("Shut it"))
            #expect(flow.state == .failed(reason))
            #expect(flow.host == "127.0.0.1" && flow.port == 443)
            #expect(flow.provenance.ruleMatches?.outcomes == [RuleOutcome(ruleID: shut.id, code: .applied)])
            #expect(fx.store.allFlows().count == 1)
        }
    }

    @Test func closeCarriesAnnotationsToTheFailedRow() async throws {
        let annotate = rule("annotate", when: [], markRed, note("closed by P0"))
        let shut = rule("shut", when: [], close(.graceful))
        try await ProxyFixture.run(rules: TestRules.provider([annotate, shut])) { fx in
            _ = try await wireExchange(port: fx.proxyPort, connectLine("127.0.0.1:\(fx.origin.port)"))
            let flow = try await waitForFlow(fx.store) { $0.method == "CONNECT" && $0.completedAt != nil }
            if case .failed = flow.state {} else { Issue.record("expected a failed row, got \(flow.state)") }
            #expect(flow.ruleMark?.source == .rule(id: annotate.id, name: "annotate"))
            #expect(flow.comment == "closed by P0")
        }
    }

    // MARK: annotations

    @Test func annotationsLandOnTheTunnelRow() async throws {
        let setup = try HTTPSSetup()
        let plain = rule("plain", when: [hostIs("localhost")], markRed, note("tunnelled"), noDecrypt)
        try await setup.run(rules: TestRules.provider([plain])) { fx in
            let r = try curl(["-x", fx.proxyURL, "--cacert", setup.originCAFile, "https://localhost:\(fx.origin.port)/hello"])
            #expect(r.exitCode == 0, "\(r.stderr)")
            let flow = try await waitForFlow(fx.store) { $0.method == "CONNECT" && $0.completedAt != nil }
            #expect(flow.state == .tunnel)
            #expect(flow.ruleMark?.source == .rule(id: plain.id, name: "plain"))
            #expect(flow.comment == "tunnelled")
            #expect(!flow.isHidden)
        }
        // A hide on a CONNECT the tools tunnel: the row is hidden.
        let hiding = try HTTPSSetup()
        try await hiding.run(configure: { $0.decryption.excludedHosts = ["localhost"] },
                             rules: TestRules.provider([rule("hide", when: [hostIs("localhost")], hide)])) { fx in
            let r = try curl(["-x", fx.proxyURL, "--cacert", hiding.originCAFile, "https://localhost:\(fx.origin.port)/hello"])
            #expect(r.exitCode == 0, "\(r.stderr)")
            let flow = try await waitForFlow(fx.store) { $0.method == "CONNECT" && $0.completedAt != nil }
            #expect(flow.isHidden)
            #expect(flow.state == .tunnel)
        }
    }

    @Test func annotationsOnADecryptedConnectLeaveNoRow() async throws {
        let setup = try HTTPSSetup()
        let marking = rule("mark host", when: [hostIs("localhost")], markRed)
        let provider = TestRules.provider([marking])
        try await setup.run(rules: provider) { fx in
            let r = try curl(["-x", fx.proxyURL, "--cacert", setup.proxyCAFile, "https://localhost:\(fx.origin.port)/hello"])
            #expect(r.exitCode == 0, "\(r.stderr)")
            let flow = try await waitForFlow(fx.store) { $0.path == "/hello" && $0.state == .completed }
            // The request inside is judged on its own and marked by its own evaluation.
            #expect(flow.ruleMark?.source == .rule(id: marking.id, name: "mark host"))
            #expect(fx.store.allFlows().count == 1)
            #expect(provider.hits.connectCount(marking.id) == 1)
            #expect(provider.hits.count(marking.id) == 1)
        }
    }

    @Test func p0RuleDoesNotChangeRequestsInsideATunnelItDecrypts() async throws {
        let setup = try HTTPSSetup()
        // The URL of the CONNECT has no path, so this rule does not match there; it does match the request inside,
        // where a CONNECT-only action neither runs nor stops the rules below it.
        let plain = rule("plain", when: [urlContains("/hello")], noDecrypt)
        let below = rule("below", when: [pathStarts("/hello")], markRed)
        try await setup.run(rules: TestRules.provider([plain, below])) { fx in
            let r = try curl(["-x", fx.proxyURL, "--cacert", setup.proxyCAFile, "https://localhost:\(fx.origin.port)/hello"])
            #expect(r.exitCode == 0, "\(r.stderr)")
            let flow = try await waitForFlow(fx.store) { $0.path == "/hello" && $0.state == .completed }
            #expect(flow.ruleMark?.source == .rule(id: below.id, name: "below"))
            #expect(flow.provenance.ruleMatches?.outcomes.contains { $0.ruleID == plain.id } == false)
            #expect(!fx.store.allFlows().contains { $0.method == "CONNECT" })
        }
    }

    @Test func firstRequestAfterReturnTunnelEvaluatesFromScratch() async throws {
        let setup = try HTTPSSetup()
        // At the CONNECT the tunnel rule is final and cuts the mark below it; the request inside starts over.
        let decrypt = rule("keep decrypting", when: [hostIs("localhost")], returnTunnel)
        let marking = rule("mark", when: [], markRed)
        let provider = TestRules.provider([decrypt, marking])
        try await setup.run(rules: provider) { fx in
            let r = try curl(["-x", fx.proxyURL, "--cacert", setup.proxyCAFile, "https://localhost:\(fx.origin.port)/hello"])
            #expect(r.exitCode == 0, "\(r.stderr)")
            let flow = try await waitForFlow(fx.store) { $0.path == "/hello" && $0.state == .completed }
            #expect(flow.ruleMark?.source == .rule(id: marking.id, name: "mark"))
            #expect(flow.provenance.ruleMatches?.outcomes == [RuleOutcome(ruleID: marking.id, code: .applied)])
            #expect(provider.hits.connectCount(decrypt.id) == 1)
            #expect(provider.hits.connectCount(marking.id) == 0, "cut at the CONNECT")
            #expect(provider.hits.count(marking.id) == 1)
        }
    }

    @Test func hitCountsShareOneCounter() async throws {
        let shut = rule("shut", when: [], close(.graceful))
        let provider = TestRules.provider([shut])
        try await ProxyFixture.run(rules: provider) { fx in
            _ = try await wireExchange(port: fx.proxyPort, connectLine("127.0.0.1:\(fx.origin.port)"))
            _ = try await wireExchange(port: fx.proxyPort, connectLine("127.0.0.1:\(fx.origin.port)"))
            try await waitUntil("two CONNECT hits on the provider's counter") { provider.hits.connectCount(shut.id) == 2 }
            #expect(provider.hits.count(shut.id) == 0, "CONNECT hits are counted apart from the requests'")
        }
    }

    // MARK: waiting for the client app (D13)

    @Test func clientAppConditionWaitsForLookup() async throws {
        let fixture = rule("fixture app", when: [ConditionRow(field: .clientApp, name: "name", op: .equals, value: "Fixture")],
                           close(.reset))
        // The lookup answers: the rule sees the app and closes before any 200.
        try await withConnectPipeline(rules: TestRules.provider([fixture])) { pipe in
            try pipe.client.writeInbound(ByteBuffer(string: connectLine("127.0.0.1:443")))
            pipe.loop.run()
            #expect(try pipe.output().isEmpty, "nothing is answered before the lookup")
            #expect(pipe.client.isActive)
            pipe.lookup.succeed(ClientApp(pid: 42, name: "Fixture", executablePath: "/Applications/Fixture.app"))
            pipe.loop.run()
            #expect(!pipe.client.isActive)
            #expect(try pipe.output().isEmpty)
            let flow = try #require(pipe.store.allFlows().first)
            #expect(flow.provenance.ruleMatches?.outcomes == [RuleOutcome(ruleID: fixture.id, code: .applied)])
            #expect(flow.client?.name == "Fixture")
        }
        // The lookup does not answer within the grace: the app is unknown and the CONNECT goes on.
        try await withConnectPipeline(rules: TestRules.provider([fixture])) { pipe in
            try pipe.client.writeInbound(ByteBuffer(string: connectLine("127.0.0.1:443")))
            pipe.loop.run()
            #expect(try pipe.output().isEmpty)
            pipe.loop.advanceTime(by: ProxyHandler.clientLookupGrace)
            pipe.loop.run()
            #expect(try pipe.output() == ProxyHandler.connectEstablished)
            #expect(pipe.client.isActive)
            let flow = try #require(pipe.store.allFlows().first { $0.method == "CONNECT" })
            #expect(flow.provenance.ruleMatches?.outcomes.contains(RuleOutcome(ruleID: fixture.id, code: .appUnknown)) == true)
            pipe.lookup.succeed(nil)
            pipe.loop.run()
        }
    }
}

/// An embedded HTTP/1 client pipeline with a `ProxyHandler` whose client lookup is a promise the test answers,
/// and whose tunnels connect to an embedded upstream. Decryption is off, so a CONNECT that goes on is tunnelled.
@Suite(.productionChinese) struct ConnectPipeline {
    let loop: EmbeddedEventLoop
    let client: EmbeddedChannel
    let upstream: EmbeddedChannel
    let store: FlowStore
    let lookup: EventLoopPromise<ClientApp?>

    func output() throws -> String {
        var result = ""
        while let data = try client.readOutbound(as: IOData.self) {
            if case .byteBuffer(var buffer) = data { result += buffer.readString(length: buffer.readableBytes) ?? "" }
        }
        return result
    }
}

func withConnectPipeline(rules: RuleSnapshotProvider, _ body: (ConnectPipeline) throws -> Void) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let pool = NIOThreadPool(numberOfThreads: 1)
    pool.start()
    let result = Result {
        let store = FlowStore(bodyDirectory: directory)
        let loop = EmbeddedEventLoop()
        let upstream = EmbeddedChannel(loop: loop)
        try upstream.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 12346)).wait()
        defer { _ = try? upstream.finish() }
        var configuration = ProxyConfiguration()
        configuration.decryption.enabled = false
        var environment = ProxyEnvironment(
            configuration: configuration,
            recording: FlowRecording(store: store, isEnabled: ManagedAtomic(true)),
            tls: TLSInterception(certificateAuthority: try CertificateAuthority.generate()),
            passthrough: PassthroughRegistry(),
            clientLookup: ClientLookupBatcher(processLookup: .none, threadPool: pool))
        environment.rules = rules
        let lookup = loop.makePromise(of: ClientApp?.self)
        let owner = ProxyHandler(mode: .forwardProxy, environment: environment, inheritedClientLookup: lookup.futureResult,
                                 connectionFactory: { _, _, eventLoop in eventLoop.makeSucceededFuture(upstream) })
        let client = EmbeddedChannel(handlers: [HTTPMessageTranslation.responseEncoder(), HTTP1TransferCodingFramer<HTTPResponseHead>(),
                                                ByteToMessageHandler(HTTPRequestDecoder()), owner], loop: loop)
        defer { _ = try? client.finish() }
        try client.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 12345)).wait()
        try body(ConnectPipeline(loop: loop, client: client, upstream: upstream, store: store, lookup: lookup))
    }
    try await pool.shutdownGracefully()
    try result.get()
}
