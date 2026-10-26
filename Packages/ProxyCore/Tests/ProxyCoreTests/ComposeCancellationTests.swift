import FlowStore
import Foundation
import NIOCore
import NIOEmbedded
import NIOHTTP1
import NIOPosix
import RulesEngine
import Testing
import os
@testable import ProxyCore

/// Staged cancellation of a Compose send: queued, connecting (upstream proxy CONNECT or TLS),
/// awaiting the head (h1 and h2), streaming the body, paused at a breakpoint and after it
/// completed. Every stage ends in exactly one result, returns every resource and releases the
/// send's virtual client and exchange. Origins are loopback only; no sleeps.
@Suite(.serialized, .timeLimit(.minutes(3)), .productionChinese) struct ComposeCancellationTests {
    @Test func cancelWhileQueued() async throws {
        try await ComposeFixture.run(limits: .init(concurrentSends: 1, queuedSends: 1)) { fx in
            let first = ComposeRequest(method: "GET", url: fx.url("/hold"))
            let held = Task { await fx.compose.send(first) }
            try await waitUntil("first held") { fx.origin.state.withLock { $0.concurrent } == 1 }
            let second = ComposeRequest(method: "GET", url: fx.url("/hello"))
            let queued = Task { await fx.compose.send(second) }
            try await waitUntil("second queued") { fx.compose.resources.queued == 1 }
            #expect(fx.compose.cancel(second.id))
            let result = await queued.value
            #expect(result.failure?.code == ComposeFailureCode.cancelled.rawValue)
            #expect(result.flowID == nil)
            #expect(result.delivery == .notSent)
            #expect(fx.compose.resources.queued == 0)
            fx.origin.releaseHeld()
            #expect(await held.value.response?.status == 200)
            #expect(fx.origin.state.withLock { $0.requests["/hello"] } == nil)
            #expect(fx.origin.state.withLock { $0.connections } == 1)
            fx.expectNeverStarted(second.id)
            try await fx.expectReleased(first.id)
        }
    }

    // The upstream proxy accepted the TCP connection but never answers the CONNECT. Cancelling
    // closes that connection at once instead of waiting out the 20 s connect timeout.
    @Test func cancelWhileConnectingThroughUpstreamProxy() async throws {
        let proxy = try await ComposeSilentServer.start()
        do {
            try await ComposeFixture.run(configure: { configuration in
                var upstream = UpstreamProxy(host: "127.0.0.1", port: proxy.port, bypass: [])
                upstream.alwaysBypassLoopback = false
                configuration.upstreamProxy = upstream
                configuration.connectTimeout = .seconds(20)
            }) { fx in
                let request = ComposeRequest(method: "GET", url: fx.url("/hello"))
                let send = Task { await fx.compose.send(request) }
                try await waitUntil("the CONNECT reached the silent proxy") { proxy.state.withLock { $0.receivedBytes } > 0 }
                #expect(fx.compose.cancel(request.id))
                let result = try await awaitPromptly(send, "the cancelled send ended before the connect timeout")
                #expect(result.failure?.code == ComposeFailureCode.cancelled.rawValue)
                #expect(result.delivery == .notSent)
                #expect(result.partialResponse == nil)
                try await waitUntil("the proxy saw its connection close") { proxy.state.withLock { $0.closed } == 1 }
                #expect(proxy.state.withLock { $0.connections } == 1)
                #expect(fx.origin.state.withLock { $0.connections } == 0)
                try await fx.expectReleased(request.id)
            }
            try await proxy.stop()
        } catch { try? await proxy.stop(); throw error }
    }

    // The origin accepted TCP but never answers the TLS ClientHello.
    @Test func cancelWhileTLSHandshaking() async throws {
        let origin = try await ComposeSilentServer.start()
        do {
            try await ComposeFixture.run(configure: { $0.connectTimeout = .seconds(20) }) { fx in
                let request = ComposeRequest(method: "GET", url: try #require(URL(string: "https://127.0.0.1:\(origin.port)/hello")))
                let send = Task { await fx.compose.send(request) }
                try await waitUntil("the ClientHello reached the silent origin") { origin.state.withLock { $0.receivedBytes } > 0 }
                #expect(fx.compose.cancel(request.id))
                let result = try await awaitPromptly(send, "the cancelled send ended before the handshake timeout")
                #expect(result.failure?.code == ComposeFailureCode.cancelled.rawValue)
                #expect(result.delivery == .notSent)
                try await waitUntil("the origin saw its connection close") { origin.state.withLock { $0.closed } == 1 }
                #expect(origin.state.withLock { $0.connections } == 1)
                try await fx.expectReleased(request.id)
            }
            try await origin.stop()
        } catch { try? await origin.stop(); throw error }
    }

    @Test func cancelWhileAwaitingHead() async throws {
        try await ComposeFixture.run { fx in
            let request = ComposeRequest(method: "GET", url: fx.url("/hold"))
            let send = Task { await fx.compose.send(request) }
            try await waitUntil("held") { fx.origin.state.withLock { $0.concurrent } == 1 }
            #expect(fx.compose.cancel(request.id))
            let result = await send.value
            #expect(result.failure?.code == ComposeFailureCode.cancelled.rawValue)
            #expect(result.response == nil)
            #expect(result.partialResponse == nil)
            #expect(result.delivery == .unknown)
            let flowID = try #require(result.flowID)
            let flow = try await waitForFlow(fx.store) { $0.id == flowID }
            if case .failed = flow.state {} else { Issue.record("flow not failed: \(flow.state)") }
            try await waitUntil("the origin saw its connection close") { fx.origin.state.withLock { $0.closed } == 1 }
            try await fx.expectReleased(request.id)
        }
    }

    @Test func cancelWhileAwaitingHeadOnH2ResetsTheStream() async throws {
        let origin = try await ComposeTLSOrigin.start(protocols: ["h2"])
        do {
            let roots = try origin.trustRoots
            try await ComposeFixture.run(configure: { $0.upstreamTrustRoots = roots }) { fx in
                let request = ComposeRequest(method: "GET", url: try #require(URL(string: "https://localhost:\(origin.port)/hold")))
                let send = Task { await fx.compose.send(request) }
                try await waitUntil("the h2 request reached the origin") { origin.state.withLock { $0.paths } == ["/hold"] }
                #expect(fx.compose.cancel(request.id))
                let result = await send.value
                #expect(result.failure?.code == ComposeFailureCode.cancelled.rawValue)
                #expect(result.delivery == .unknown)
                try await waitUntil("the origin received RST_STREAM(CANCEL)") { origin.state.withLock { $0.resets } == [.cancel] }
                #expect(origin.state.withLock { $0.negotiated } == [.http2])
                try await fx.expectReleased(request.id)
            }
            try await origin.stop()
        } catch { try? await origin.stop(); throw error }
    }

    @Test func cancelWhileStreamingBody() async throws {
        try await ComposeFixture.run { fx in
            let request = ComposeRequest(method: "GET", url: fx.url("/stream"))
            let send = Task { await fx.compose.send(request) }
            _ = try await waitForFlow(fx.store) { $0.path == "/stream" && $0.messages[.upstreamResponse]?.observedBytes == 5 }
            #expect(fx.compose.cancel(request.id))
            let result = await send.value
            #expect(result.response == nil)
            #expect(result.failure?.code == ComposeFailureCode.cancelled.rawValue)
            #expect(result.delivery == .answered)
            let partial = try #require(result.partialResponse)
            #expect(partial.status == 200)
            #expect(partial.body == Data("hello".utf8))
            #expect(partial.bodyBytes == 5)
            #expect(partial.headers.contains(HeaderField(name: "X-Origin", value: "compose-fixture")))
            try await waitUntil("the origin saw its connection close") { fx.origin.state.withLock { $0.closed } == 1 }
            try await fx.expectReleased(request.id)
        }
    }

    @Test func cancelWhilePausedAtBreakpoint() async throws {
        let coordinator = BreakpointCoordinator()
        try await ComposeFixture.run(rules: TestRules.provider([TestRules.breakpoint(.request)]), breakpoints: coordinator) { fx in
            let request = ComposeRequest(method: "GET", url: fx.url("/hello"), policy: ComposePolicy(applyRules: true))
            let send = Task { await fx.compose.send(request) }
            try await waitUntil("paused at the request breakpoint") { coordinator.snapshot().count == 1 }
            #expect(coordinator.snapshot().first?.contextID == request.id)
            #expect(fx.compose.cancel(request.id))
            let result = await send.value
            #expect(result.failure?.code == ComposeFailureCode.cancelled.rawValue)
            #expect(result.delivery == .notSent)
            #expect(coordinator.snapshot().isEmpty)
            #expect(fx.origin.state.withLock { $0.connections } == 0)
            try await fx.expectReleased(request.id)
        }
    }

    @Test func cancelWhilePausedAtResponseBreakpoint() async throws {
        let coordinator = BreakpointCoordinator()
        try await ComposeFixture.run(rules: TestRules.provider([TestRules.breakpoint(.response)]), breakpoints: coordinator) { fx in
            let request = ComposeRequest(method: "GET", url: fx.url("/hello"), policy: ComposePolicy(applyRules: true))
            let send = Task { await fx.compose.send(request) }
            try await waitUntil("paused at the response breakpoint") { coordinator.snapshot().count == 1 }
            #expect(coordinator.snapshot().first?.direction == .response)
            #expect(fx.compose.cancel(request.id))
            let result = await send.value
            #expect(result.failure?.code == ComposeFailureCode.cancelled.rawValue)
            // The origin answered, but nothing was delivered to the send.
            #expect(result.delivery == .answered)
            #expect(result.partialResponse == nil)
            #expect(coordinator.snapshot().isEmpty)
            try await waitUntil("the origin saw its connection close") { fx.origin.state.withLock { $0.closed } == 1 }
            try await fx.expectReleased(request.id)
        }
    }

    @Test func cancelAfterCompleteIsNoop() async throws {
        try await ComposeFixture.run { fx in
            let request = ComposeRequest(method: "GET", url: fx.url("/hello"))
            let result = await fx.compose.send(request)
            #expect(result.response?.status == 200)
            #expect(!fx.compose.cancel(request.id))
            #expect(!fx.compose.cancel(request.id))
            let flowID = try #require(result.flowID)
            let flow = try await waitForFlow(fx.store) { $0.id == flowID && $0.state == .completed }
            #expect(flow.statusCode == 200)
            #expect(fx.store.allFlows().count == 1)
            try await fx.expectReleased(request.id)
        }
    }

    // A cancelled exchange on a shared client pool closes its HTTP/1 upstream; the next request
    // to the same route opens a new connection.
    @Test func cancelledH1UpstreamNotReturnedToPool() async throws {
        try await withConnectionFixture { f in
            let context = f.context()
            let first = f.admit("/a", writer: RecordingResponseWriter(channel: f.client), context: context)
            first.execute()
            first.receiveRequest(.end(nil))
            let upstream = try f.connect(0)
            #expect(try f.written(upstream).hasPrefix("GET /a HTTP/1.1"))
            first.cancel(reason: "synthetic cancellation")
            f.loop.run()
            #expect(!upstream.isActive)
            #expect(context.upstreamPool.snapshot.physicalSockets == 0)
            let second = f.admit("/b", writer: RecordingResponseWriter(channel: f.client), context: context)
            second.execute()
            second.receiveRequest(.end(nil))
            #expect(f.connections.count == 2)
            let next = try f.connect(1)
            #expect(try f.written(next).hasPrefix("GET /b HTTP/1.1"))
            second.cancel(reason: "cleanup")
            f.loop.run()
        }
        // The same through Compose: the next send uses a new connection.
        try await ComposeFixture.run { fx in
            let request = ComposeRequest(method: "GET", url: fx.url("/hold"))
            let send = Task { await fx.compose.send(request) }
            try await waitUntil("held") { fx.origin.state.withLock { $0.concurrent } == 1 }
            fx.compose.cancel(request.id)
            #expect(await send.value.failure?.code == ComposeFailureCode.cancelled.rawValue)
            try await waitUntil("the origin saw its connection close") { fx.origin.state.withLock { $0.closed } == 1 }
            #expect(await fx.compose.send(ComposeRequest(method: "GET", url: fx.url("/hello"))).response?.status == 200)
            #expect(fx.origin.state.withLock { $0.connections } == 2)
            try await fx.expectReleased(request.id)
        }
    }

    // M8: a final response that ended the exchange stops the asset body from being read further.
    @Test func earlyLocalFailureStopsReadingTheAssetBody() async throws {
        let bytes = Data(repeating: 0x61, count: 1_048_576)
        try await ComposeFixture.run(withAssets: true) { fx in
            let port = try #require(fx.server.boundPort)
            let asset = try await fx.importAsset(bytes)
            let request = ComposeRequest(method: "PUT", url: try #require(URL(string: "http://127.0.0.1:\(port)/loop")), body: .asset(asset.id))
            let result = await fx.compose.send(request)
            #expect(result.failure?.code == "rule.selfTarget")
            #expect(result.delivery == .notSent)
            let flowID = try #require(result.flowID)
            let flow = try await waitForFlow(fx.store) { $0.id == flowID && $0.state != .inProgress }
            let submitted = try #require(flow.messages[.composeSubmitted])
            #expect(submitted.transferState != .finished)
            #expect(submitted.observedBytes < UInt64(bytes.count))
            // The exchange ended inside its own start: not one chunk of the asset was read.
            #expect(fx.lifetimes.bodyBytesRead(request.id) == 0)
            try await fx.expectReleased(request.id)
        }
    }

    // m3: an upstream connect failure also releases the virtual client and exchange.
    @Test func connectFailureReleasesContextAndExchange() async throws {
        let closed = try await ComposeSilentServer.start()
        let port = closed.port
        try await closed.stop()
        try await ComposeFixture.run { fx in
            let request = ComposeRequest(method: "GET", url: try #require(URL(string: "http://127.0.0.1:\(port)/x")))
            let result = await fx.compose.send(request)
            #expect(result.failure?.code == "upstream.unreachable")
            #expect(result.delivery == .notSent)
            try await fx.expectReleased(request.id)
        }
    }
}

/// Waits for `task` within the default polling deadline; a send stuck behind a long timeout fails
/// the test instead of silently passing late.
private func awaitPromptly(_ task: Task<ComposeResult, Never>, _ what: String) async throws -> ComposeResult {
    let box = OSAllocatedUnfairLock<ComposeResult?>(initialState: nil)
    let waiter = Task { let result = await task.value; box.withLock { $0 = result } }
    defer { waiter.cancel() }
    try await waitUntil(what) { box.withLock { $0 != nil } }
    return try #require(box.withLock { $0 })
}
