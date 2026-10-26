import Atomics
import CertKit
import FlowStore
import Foundation
import NIOCore
import NIOPosix
import NIOSSL
import RulesEngine
import Testing
@testable import ProxyCore

/// ComposePolicy: rules on/off, the total timeout (and how a breakpoint pauses it) and the HTTP
/// version preference, through a real `ProxyServer` and loopback origins only.
@Suite(.serialized, .timeLimit(.minutes(3)), .productionChinese) struct ComposePolicyTests {
    @Test func policyDefaultsAndTimeoutRange() async throws {
        let policy = ComposePolicy()
        #expect(policy.applyRules == false)
        #expect(policy.timeout == .seconds(60))
        #expect(policy.httpVersion == .automatic)
        #expect(ComposePolicy.timeoutRange == Duration.seconds(1)...Duration.seconds(600))
        try await ComposeFixture.run { fx in
            for timeout in [Duration.zero, .milliseconds(999), .seconds(601), .seconds(-1)] {
                let result = await fx.compose.send(ComposeRequest(method: "GET", url: fx.url("/hello"), policy: ComposePolicy(timeout: timeout)))
                #expect(result.failure?.code == ComposeFailureCode.invalidRequest.rawValue, "\(timeout)")
                #expect(result.failure?.detail == "timeoutOutOfRange", "\(timeout)")
                #expect(result.flowID == nil)
                #expect(result.delivery == .notSent)
            }
            #expect(fx.origin.state.withLock { $0.connections } == 0)
            for timeout in [Duration.seconds(1), .seconds(600)] {
                let result = await fx.compose.send(ComposeRequest(method: "GET", url: fx.url("/hello"), policy: ComposePolicy(timeout: timeout)))
                #expect(result.response?.status == 200, "\(timeout)")
            }
            fx.expectIdle()
        }
    }

    // Rules off (the default) must bypass every rule kind: header edits, Map Remote, Map Local and
    // both breakpoint directions, and the flow says rules were disabled for this send.
    @Test func applyRulesFalseBypassesAllRuleKinds() async throws {
        let other = try await ComposeOrigin.start(tls: nil)
        do {
            let rules = [
                TestRules.headers(.request, [.set(name: "X-Rule", value: "request")]),
                TestRules.headers(.response, [.set(name: "X-Rule", value: "response")]),
                TestRules.mapRemote(host: "127.0.0.1", port: other.port),
                TestRules.mapLocal(),
                TestRules.breakpoint(.request),
                TestRules.breakpoint(.response),
            ]
            let coordinator = BreakpointCoordinator()
            try await ComposeFixture.run(rules: TestRules.provider(rules, revision: 3), breakpoints: coordinator) { fx in
                let request = ComposeRequest(method: "GET", url: fx.url("/hello"))
                let result = await fx.compose.send(request)
                #expect(result.response?.status == 200)
                #expect(result.response?.body == Data("hello".utf8))
                #expect(result.response?.headers.contains { $0.name == "X-Rule" } == false)
                let seen = try #require(fx.origin.state.withLock { $0.heads.last })
                #expect(seen.headers["X-Rule"] == [])
                #expect(other.state.withLock { $0.requests.isEmpty })
                #expect(coordinator.snapshot().isEmpty)
                let flowID = try #require(result.flowID)
                let flow = try await waitForFlow(fx.store) { $0.id == flowID && $0.state == .completed }
                #expect(flow.provenance.isCompose)
                #expect(flow.provenance.rulesDisabled)
                #expect(flow.provenance.ruleMatches == nil)
                #expect(flow.provenance.generatedResponse == nil)
                try await fx.expectReleased(request.id)
            }
            try await other.stop()
        } catch { try? await other.stop(); throw error }
    }

    @Test func applyRulesTrueHitsBreakpointThenContinue() async throws {
        let rule = TestRules.breakpoint(.request)
        let coordinator = BreakpointCoordinator()
        try await ComposeFixture.run(rules: TestRules.provider([rule], revision: 5), breakpoints: coordinator) { fx in
            let request = ComposeRequest(method: "GET", url: fx.url("/hello"), policy: ComposePolicy(applyRules: true))
            let send = Task { await fx.compose.send(request) }
            try await waitUntil("the send paused at its request breakpoint") { coordinator.snapshot().count == 1 }
            let ticket = try #require(coordinator.snapshot().first)
            #expect(ticket.contextID == request.id)
            #expect(ticket.direction == .request)
            guard case .compose(let sendID, _, _) = ticket.source else { Issue.record("not a Compose ticket"); return }
            #expect(sendID == request.id)
            #expect(fx.origin.state.withLock { $0.requests["/hello"] } == nil)
            #expect(await coordinator.perform(.continue(token: ticket.token, edit: .init(head: ticket.effectiveHead))) == .accepted)
            let result = await send.value
            #expect(result.response?.status == 200)
            #expect(result.delivery == .answered)
            let flowID = try #require(result.flowID)
            let flow = try await waitForFlow(fx.store) { $0.id == flowID && $0.state == .completed }
            #expect(!flow.provenance.rulesDisabled)
            #expect(flow.provenance.ruleMatches?.ruleIDs == [rule.id])
            try await fx.expectReleased(request.id)
        }
    }

    // Ruling: a paused breakpoint has its own absolute deadline and the Compose timeout does not
    // run meanwhile. With a 1 s Compose timeout and a 2 s ticket, an untouched ticket ends by the
    // breakpoint's own expiry, never by the Compose timeout; once continued, the rest of the
    // Compose budget runs again.
    @Test func composeTimeoutPausedDuringBreakpoint() async throws {
        let rule = TestRules.breakpoint(.request)
        let coordinator = BreakpointCoordinator(limits: RulesLimits(ticketSeconds: 2))
        try await ComposeFixture.run(rules: TestRules.provider([rule]), breakpoints: coordinator) { fx in
            let policy = ComposePolicy(applyRules: true, timeout: .seconds(1))
            let expiring = ComposeRequest(method: "GET", url: fx.url("/hello"), policy: policy)
            let expired = await fx.compose.send(expiring)
            #expect(expired.failure?.code == HTTPLocalFailureCode.breakpointTimeout.rawValue)
            #expect(expired.delivery == .notSent)
            #expect(fx.origin.state.withLock { $0.requests["/hello"] } == nil)
            try await fx.expectReleased(expiring.id)

            let resumed = ComposeRequest(method: "GET", url: fx.url("/hold"), policy: policy)
            let send = Task { await fx.compose.send(resumed) }
            try await waitUntil("the second send paused") { coordinator.snapshot().count == 1 }
            let ticket = try #require(coordinator.snapshot().first)
            #expect(await coordinator.perform(.continue(token: ticket.token, edit: .init(head: ticket.effectiveHead))) == .accepted)
            let result = await send.value
            #expect(result.failure?.code == ComposeFailureCode.timeout.rawValue)
            #expect(result.delivery == .unknown)
            #expect(fx.origin.state.withLock { $0.requests["/hold"] } == 1)
            try await fx.expectReleased(resumed.id)
        }
    }

    @Test func timeoutFiresAndCleansUp() async throws {
        try await ComposeFixture.run { fx in
            let request = ComposeRequest(method: "GET", url: fx.url("/hold"), policy: ComposePolicy(timeout: .seconds(1)))
            let result = await fx.compose.send(request)
            #expect(result.response == nil)
            #expect(result.partialResponse == nil)
            #expect(result.failure?.code == ComposeFailureCode.timeout.rawValue)
            #expect(result.failure?.message.contains("1") == true)
            #expect(result.delivery == .unknown)
            let flowID = try #require(result.flowID)
            let flow = try await waitForFlow(fx.store) { $0.id == flowID }
            if case .failed = flow.state {} else { Issue.record("flow not failed: \(flow.state)") }
            // The h1 upstream connection is closed, never kept for reuse.
            try await waitUntil("the origin saw its connection close") { fx.origin.state.withLock { $0.closed } == 1 }
            try await fx.expectReleased(request.id)
        }
    }

    @Test func timeoutWhileStreamingKeepsTheReceivedHead() async throws {
        try await ComposeFixture.run { fx in
            let request = ComposeRequest(method: "GET", url: fx.url("/stream"), policy: ComposePolicy(timeout: .seconds(1)))
            let result = await fx.compose.send(request)
            #expect(result.response == nil)
            #expect(result.failure?.code == ComposeFailureCode.timeout.rawValue)
            #expect(result.delivery == .answered)
            let partial = try #require(result.partialResponse)
            #expect(partial.status == 200)
            #expect(partial.body == Data("hello".utf8))
            #expect(partial.bodyBytes == 5)
            try await fx.expectReleased(request.id)
        }
    }

    // Ruling: the timeout counts from the moment a send gets its slot, never from queue entry.
    @Test func timeoutCountsFromSendStartNotQueueEntry() async throws {
        try await ComposeFixture.run(limits: .init(concurrentSends: 1, queuedSends: 1)) { fx in
            let first = ComposeRequest(method: "GET", url: fx.url("/hold"), policy: ComposePolicy(timeout: .seconds(2)))
            let held = Task { await fx.compose.send(first) }
            try await waitUntil("first held") { fx.origin.state.withLock { $0.concurrent } == 1 }
            let second = ComposeRequest(method: "GET", url: fx.url("/hello"), policy: ComposePolicy(timeout: .seconds(1)))
            let queued = Task { await fx.compose.send(second) }
            try await waitUntil("second queued") { fx.compose.resources.queued == 1 }
            #expect(await held.value.failure?.code == ComposeFailureCode.timeout.rawValue)
            // It waited about 2 s in the queue, longer than its own 1 s budget.
            #expect(await queued.value.response?.status == 200)
            try await fx.expectReleased(second.id)
        }
    }

    @Test func http1OnlyUsesSeparateConnectionWithHTTP1ALPN() async throws {
        let origin = try await ComposeTLSOrigin.start(protocols: ["h2", "http/1.1"])
        do {
            let roots = try origin.trustRoots
            try await ComposeFixture.run(configure: { $0.upstreamTrustRoots = roots }) { fx in
                let url = try #require(URL(string: "https://localhost:\(origin.port)/ok"))
                let automatic = await fx.compose.send(ComposeRequest(method: "GET", url: url))
                #expect(automatic.response?.status == 200)
                let http1 = ComposeRequest(method: "GET", url: url, policy: ComposePolicy(httpVersion: .http1Only))
                let pinned = await fx.compose.send(http1)
                #expect(pinned.response?.status == 200)
                #expect(origin.state.withLock { $0.negotiated } == [.http2, .http1])
                #expect(origin.state.withLock { $0.connections } == 2)
                let flowID = try #require(pinned.flowID)
                let flow = try await waitForFlow(fx.store) { $0.id == flowID && $0.state == .completed }
                #expect(flow.transport.upstreamRequest == .http1_1)
                let first = try #require(automatic.flowID)
                #expect(try await waitForFlow(fx.store) { $0.id == first && $0.state == .completed }.transport.upstreamRequest == .http2)
                try await fx.expectReleased(http1.id)
            }
            try await origin.stop()
        } catch { try? await origin.stop(); throw error }
    }

    // The pool key carries the protocol preference: one shared pool never hands an h2 session to
    // an http/1.1-only route, and still reuses its h2 session for an automatic one.
    @Test func http1OnlyRouteIsASeparatePoolKey() async throws {
        let origin = try await ComposeTLSOrigin.start(protocols: ["h2", "http/1.1"])
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let threads = NIOThreadPool(numberOfThreads: 1)
        threads.start()
        do {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("compose-pool-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: directory) }
            var configuration = ProxyConfiguration()
            configuration.upstreamTrustRoots = try origin.trustRoots
            let store = FlowStore(bodyDirectory: directory)
            let environment = ProxyEnvironment(
                configuration: configuration, recording: FlowRecording(store: store, isEnabled: ManagedAtomic(true)),
                tls: TLSInterception(certificateAuthority: try CertificateAuthority.generate()), passthrough: PassthroughRegistry(),
                clientLookup: ClientLookupBatcher(processLookup: ProcessLookup(lookup: { _, _ in nil }), threadPool: threads))
            let loop = group.next()
            let pool = try await loop.submit { NIOLoopBound(UpstreamSessionPool(eventLoop: loop, environment: environment, limits: .init()), eventLoop: loop) }.get()
            func lease(_ policy: UpstreamProtocolPolicy) async throws -> (HTTPWireVersion, Bool) {
                let acquired = try await loop.flatSubmit {
                    pool.value.acquire(route: UpstreamRoute(scheme: "https", host: "localhost", port: origin.port, policy: policy),
                                       forceFresh: false, responseSink: PoolSink()).futureResult.map { NIOLoopBound($0, eventLoop: loop) }
                }.get()
                return try await loop.submit {
                    let result = (acquired.value.version, acquired.value.wasReused)
                    acquired.value.release(reusable: true)
                    return result
                }.get()
            }
            let first = try await lease(.automatic)
            #expect(first.0 == .http2)
            let pinned = try await lease(.http1Only)
            #expect(pinned.0 == .http1_1)
            let again = try await lease(.automatic)
            #expect(again.0 == .http2)
            #expect(again.1)
            #expect(origin.state.withLock { $0.negotiated } == [.http2, .http1])
            #expect(origin.state.withLock { $0.connections } == 2)
            try await loop.flatSubmit { pool.value.shutdown(error: nil) }.get()
        } catch {
            try? await threads.shutdownGracefully(); try? await group.shutdownGracefully(); try? await origin.stop()
            throw error
        }
        try await threads.shutdownGracefully()
        try await group.shutdownGracefully()
        try await origin.stop()
    }

    // M9: the delivered body is de-chunked, so the delivered head must not claim chunked framing.
    @Test func deliveredHeadersDoNotClaimChunkedFraming() async throws {
        let origin = try await HTTP2TestOrigin.start(protocols: [], plaintext: true)
        do {
            try await ComposeFixture.run { fx in
                let request = ComposeRequest(method: "GET", url: try #require(URL(string: "http://127.0.0.1:\(origin.port)/chunked")))
                let result = await fx.compose.send(request)
                let response = try #require(result.response)
                #expect(response.body == Data("fixture-body".utf8))
                #expect(!response.headers.contains { $0.name.lowercased() == "transfer-encoding" })
                let flowID = try #require(result.flowID)
                let flow = try await waitForFlow(fx.store) { $0.id == flowID && $0.state == .completed }
                // The origin's exact head stays in the flow.
                #expect(flow.messages[.upstreamResponse]?.head.headers.contains { $0.name.lowercased() == "transfer-encoding" } == true)
                try await fx.expectReleased(request.id)
            }
            try await origin.stop()
        } catch { try? await origin.stop(); throw error }
    }
}
