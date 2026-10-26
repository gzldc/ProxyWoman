import Atomics
import NIOHTTP1
import NIOPosix
import CertKit
import FlowStore
import NIOSSL
import os
import Foundation
import NIOCore
import NIOEmbedded
import Testing
@testable import ProxyCore

@Suite(.productionChinese) struct WebSocketRelayTests {
    @Test func optionalCallbackObservesBeforeUnchangedForwarding() throws {
        let (a, b) = GlueHandler.makePair()
        let client = EmbeddedChannel(handler: a), origin = EmbeddedChannel(handler: b)
        var observed: [UInt8] = []
        a.onObservedRead = { observed += $0.readableBytesView }
        let bytes = ByteBuffer(bytes: [0x89, 0x00])
        try client.writeInbound(bytes)
        #expect(observed == [0x89, 0x00])
        #expect(try origin.readOutbound(as: ByteBuffer.self) == bytes)
        #expect(try client.readOutbound(as: ByteBuffer.self) == nil)
        _ = try client.finish(); _ = try? origin.finish()
    }
}

extension WebSocketRelayTests {
    @Test func assessmentPreservesOriginalAbsoluteURI() throws {
        let heads = observationHeads()
        let handshake = WebSocketHandshakeAssessment.evaluate(request: heads.0, response: heads.1).handshake
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(handshake)) as? [String: Any]
        #expect(encoded?["requestURI"] as? String == "http://synthetic.test/ws")
    }
}

extension WebSocketRelayTests {
    @Test(arguments: [false, true])
    func realServerSamePacketGreetingAndStopJoinsWorker(tls: Bool) async throws {
        var response = HTTP2TestOrigin.Response(); response.supportsUpgrade = true; response.trailers = nil
        let origin = try await HTTP2TestOrigin.start(protocols: ["http/1.1"], response: response, plaintext: !tls)
        let ca = try CertificateAuthority.generate(commonName: "WS synthetic proxy CA")
        let store = observationStore(), progress = WSProgress(), cleanup = WSBarrier()
        var configuration = ProxyConfiguration(); configuration.port = 0
        configuration.upstreamTrustRoots = .certificates([try NIOSSLCertificate(bytes: origin.ca.rootCertificateDER, format: .der)])
        let server = ProxyServer(configuration: configuration, certificateAuthority: ca, store: store,
            passthrough: PassthroughRegistry(), processLookup: .none, drainDeadline: .init { loop, action in loop.execute(action); return {} },
            webSocketHooks: .init(afterChunk: { await progress.advance() }, beforeCleanup: { await cleanup.enter() }))
        var client: RawClient?
        do {
            try await server.start()
            let connected = try await RawClient.connect(port: try #require(server.boundPort)); client = connected
            if tls {
                try await connected.send("CONNECT localhost:\(origin.port) HTTP/1.1\r\nHost: localhost:\(origin.port)\r\n\r\n")
                _ = try await connected.receive(until: "\r\n\r\n")
                try await connected.startTLS(trustRoots: .certificates([try NIOSSLCertificate(bytes: ca.rootCertificateDER, format: .der)]), serverName: "localhost")
            }
            let target = tls ? "/ws" : "http://localhost:\(origin.port)/ws"
            try await connected.send(String(decoding: HTTP2UpgradeWire.request(target: target, port: origin.port), as: UTF8.self))
            let head = try await connected.receive(until: "\r\n\r\n")
            #expect(head.hasPrefix("HTTP/1.1 101"))
            #expect(try await connected.receive(until: "Hi").hasSuffix("Hi"))
            await progress.wait(1)
            let flow = try #require(store.allFlows().first { $0.path == "/ws" })
            #expect(flow.state == .completed && flow.statusCode == 101)
            let token = try #require(store.webSocketToken(flowID: flow.id))
            let rows = try #require(store.webSocketPage(token: token, after: nil, limit: 10)?.rows)
            #expect(rows.count == 1)
            #expect(store.webSocketSummary(token: token)?.handshake.requestURI == target)
            #expect(store.webSocketPayload(token: token, eventID: rows[0].id, kind: .application, maxBytes: 10)?.bytes == Data("Hi".utf8))
            let stopped = OSAllocatedUnfairLock(initialState: false)
            let stopping = Task { try await server.stop(); stopped.withLock { $0 = true } }
            await cleanup.wait()
            #expect(!stopped.withLock { $0 })
            #expect(store.webSocketBudget.usedBytes(category: .working) == 32_768)
            let secondStop = Task { try await server.stop() }
            let restarted = OSAllocatedUnfairLock(initialState: false)
            let restarting = Task { try await server.start(); restarted.withLock { $0 = true } }
            stopping.cancel()
            #expect(!restarted.withLock { $0 })
            await cleanup.release()
            try await stopping.value; try await secondStop.value; try await restarting.value
            #expect(store.webSocketBudget.usedBytes(category: .working) == 0)
            #expect(store.webSocketBudget.usedBytes(category: .native) == 0)
            #expect(store.webSocketBudget.usedBytes(category: .mailbox) == 0)
            #expect(store.webSocketSummary(token: token)?.lifecycle == .transportEndedWithoutClose)
            try await connected.close(); client = nil
            #expect(restarted.withLock { $0 })
            let fresh = try await RawClient.connect(port: try #require(server.boundPort)); client = fresh
            if tls {
                try await fresh.send("CONNECT localhost:\(origin.port) HTTP/1.1\r\nHost: localhost:\(origin.port)\r\n\r\n")
                _ = try await fresh.receive(until: "\r\n\r\n")
                try await fresh.startTLS(trustRoots: .certificates([try NIOSSLCertificate(bytes: ca.rootCertificateDER, format: .der)]), serverName: "localhost")
            }
            try await fresh.send(String(decoding: HTTP2UpgradeWire.request(target: target, port: origin.port), as: UTF8.self))
            #expect(try await fresh.receive(until: "\r\n\r\n").hasPrefix("HTTP/1.1 101"))
            #expect(try await fresh.receive(until: "Hi").hasSuffix("Hi"))
            await progress.wait(2)
            let newFlow = try #require(store.allFlows().last { $0.id != flow.id && $0.statusCode == 101 })
            #expect(store.webSocketToken(flowID: newFlow.id)?.sessionID != token.sessionID)
            try await fresh.close(); client = nil
            try await server.stop()
            try await origin.stop()
        } catch {
            await cleanup.release()
            if let client { try? await client.close() }
            try? await server.stop(); try? await origin.stop(); throw error
        }
    }
}

extension WebSocketRelayTests {
    @Test(arguments: [false, true])
    func requestAdmissionBeforePauseControlsLaterSamePacketAttachment(admitted: Bool) async throws {
        let seen = MultiThreadedEventLoopGroup.singleton.next().makePromise(of: Void.self)
        var response = HTTP2TestOrigin.Response(); response.supportsUpgrade = true; response.requestsObserved = seen
        let origin = try await HTTP2TestOrigin.start(protocols: ["http/1.1"], response: response, plaintext: true)
        let ca = try CertificateAuthority.generate(commonName: "WS paused admission CA")
        let store = observationStore(), progress = WSProgress()
        var config = ProxyConfiguration(); config.port = 0; config.recordingEnabled = admitted
        let server = ProxyServer(configuration: config, certificateAuthority: ca, store: store, passthrough: PassthroughRegistry(), processLookup: .none,
            drainDeadline: .init { loop, action in loop.execute(action); return {} }, webSocketHooks: .init(afterChunk: { await progress.advance() }))
        var client: RawClient?
        do {
            try await server.start()
            let connected = try await RawClient.connect(port: try #require(server.boundPort)); client = connected
            let request = String(decoding: HTTP2UpgradeWire.request(target: "http://localhost:\(origin.port)/ws", port: origin.port), as: UTF8.self)
                .replacingOccurrences(of: "\r\n\r\n", with: "\r\nContent-Length: 1\r\n\r\n")
            try await connected.send(request)
            try await seen.futureResult.get()
            server.updateConfiguration { $0.recordingEnabled = !admitted }
            try await connected.send("x")
            #expect(try await connected.receive(until: "\r\n\r\n").contains("101"))
            #expect(try await connected.receive(until: "Hi").hasSuffix("Hi"))
            if admitted {
                await progress.wait(1)
                let flow = try #require(store.allFlows().first)
                let token = try #require(store.webSocketToken(flowID: flow.id))
                #expect(store.webSocketPage(token: token, after: nil, limit: 10)?.rows.isEmpty == true)
                #expect(store.webSocketSummary(token: token)?.serverToClient.applicationBytes == 2)
                #expect(store.webSocketBudget.usedBytes(category: .retained) == 0)
                #expect(store.webSocketBudget.usedBytes(category: .working) == 32_768)
            } else { #expect(store.allFlows().isEmpty && store.webSocketBudget.usedBytes(category: .working) == 0) }
            try await connected.close(); client = nil
            try await server.stop(); try await origin.stop()
        } catch {
            if let client { try? await client.close() }; try? await server.stop(); try? await origin.stop(); throw error
        }
    }

    @Test func productionHandoffNoReadCompletePreservesTraceAndOriginalHeads() async throws {
        struct Trace: Equatable { let bytes: [UInt8]; let flushes: Int; let closes: Int; let autoRead: Bool }
        let store = observationStore(), cleanup = WSBarrier()
        let coordinator = WebSocketCaptureCoordinator(store: store, hooks: .init(beforeCleanup: { await cleanup.enter() }))
        let workers = NIOThreadPool(numberOfThreads: 1); workers.start()
        func run(observe: Bool) throws -> Trace {
            let loop = EmbeddedEventLoop()
            // Both production channels share the same loop.
            let origin = EmbeddedChannel(loop: loop), trace = WSWireTrace()
            try origin.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 12346)).wait()
            let recording = FlowRecording(store: observe ? store : observationStore(), isEnabled: ManagedAtomic(true))
            let environment = ProxyEnvironment(configuration: .init(), recording: recording,
                tls: TLSInterception(certificateAuthority: try CertificateAuthority.generate()), passthrough: .init(),
                clientLookup: ClientLookupBatcher(processLookup: .none, threadPool: workers), webSockets: observe ? coordinator : nil)
            let handler = ProxyHandler(mode: .forwardProxy, environment: environment, connectionFactory: { _, _, loop in loop.makeSucceededFuture(origin) })
            let client = EmbeddedChannel(handlers: [trace, HTTPMessageTranslation.responseEncoder(), HTTP1TransferCodingFramer<HTTPResponseHead>(),
                ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes)), handler], loop: loop)
            try client.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 12345)).wait()
            var request = String(decoding: HTTP2UpgradeWire.request(target: "http://localhost:12346/ws", port: 12346), as: UTF8.self)
            request = request.replacingOccurrences(of: "\r\n\r\n", with: "\r\nX-Repeat: first\r\nX-Repeat: second\r\nProxy-Connection: keep-alive\r\n\r\n")
            try client.writeInbound(ByteBuffer(string: request))
            var forwarded = ""
            while let output = try origin.readOutbound(as: IOData.self) { if case .byteBuffer(let bytes) = output { forwarded += String(buffer: bytes) } }
            #expect(forwarded.hasPrefix("GET /ws HTTP/1.1"))
            #expect(!forwarded.lowercased().contains("proxy-connection:"))
            origin.pipeline.fireChannelRead(ByteBuffer(bytes: HTTP2UpgradeWire.response + HTTP2UpgradeWire.greeting))
            // Advance scheduled handler removal, deliberately without a readComplete event.
            loop.run()
            #expect(trace.bytes.suffix(4) == [0x81, 2, 72, 105])
            let automatic = try client.getOption(ChannelOptions.autoRead).wait()
            _ = try? origin.finish(); _ = try? client.finish()
            return Trace(bytes: trace.bytes, flushes: trace.flushes, closes: trace.closes, autoRead: automatic)
        }
        let baseline = try run(observe: false), observed = try run(observe: true)
        #expect(observed == baseline)
        await cleanup.wait(); await cleanup.release(); await coordinator.shutdown()
        let flow = try #require(store.allFlows().first)
        #expect(flow.bytesSent == 0 && flow.bytesReceived == 0)
        let token = try #require(store.webSocketToken(flowID: flow.id))
        let summary = try #require(store.webSocketSummary(token: token))
        #expect(summary.handshake.requestURI == "http://localhost:12346/ws")
        #expect(summary.handshake.requestHeaders.filter { $0.name.lowercased() == "x-repeat" }.map(\.value) == ["first", "second"])
        #expect(summary.handshake.requestHeaders.contains { $0.name.lowercased() == "proxy-connection" })
        #expect(store.webSocketPage(token: token, after: nil, limit: 10)?.rows.count == 1)
        print("WS_RELAY_TRACE bytes=\(observed.bytes.count) flushes=\(observed.flushes) closes=\(observed.closes) autoRead=\(observed.autoRead) equal=true observerGeneratedWrites=0")
        try await workers.shutdownGracefully()
    }
}

extension WebSocketRelayTests {
    @Test(arguments: ["healthy", "invalid", "opaque", "exhausted", "cancelled", "cleared"])
    func actualGlueTraceIsIndependentOfCaptureFailure(mode: String) async throws {
        struct Trace: Equatable { let a: [UInt8]; let b: [UInt8]; let flushA: Int; let flushB: Int; let closeA: Int; let closeB: Int; let autoA: [Bool]; let autoB: [Bool] }
        let store = observationStore()
        let owner = WebSocketCaptureCoordinator(store: store)
        var heads = observationHeads()
        if mode == "opaque" { heads.0.headers.add(name: "Sec-WebSocket-Extensions", value: "x-synthetic"); heads.1.headers.add(name: "Sec-WebSocket-Extensions", value: "x-synthetic") }
        let id = observationFlow(store)
        let handle = try #require(owner.begin(flowID: id, request: heads.0, response: heads.1, eventLoop: MultiThreadedEventLoopGroup.singleton.next()))
        if mode == "cancelled" { handle.cancel() }
        if mode == "cleared" { store.clear() }
        var blocker: WebSocketReservation?
        if mode == "exhausted" { blocker = store.webSocketBudget.reserve(category: .mailbox, bytes: store.webSocketLimits.mailboxBytes) }
        func trace(_ handle: ObservationHandle?) throws -> Trace {
            let loop = EmbeddedEventLoop(), left = WSWireTrace(), right = WSWireTrace()
            let (a, b) = GlueHandler.makePair()
            a.onObservedRead = { handle?.offer($0, direction: .clientToServer) }
            b.onObservedRead = { handle?.offer($0, direction: .serverToClient) }
            a.onClose = { handle?.transportEnded(direction: .clientToServer) }
            b.onClose = { handle?.transportEnded(direction: .serverToClient) }
            let client = EmbeddedChannel(handlers: [left, a], loop: loop), origin = EmbeddedChannel(handlers: [right, b], loop: loop)
            try client.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 12345)).wait()
            try origin.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 12346)).wait()
            try client.writeInbound(wsFrame([65], opcode: mode == "invalid" ? 3 : 9, masked: true))
            try origin.writeInbound(wsFrame([66], opcode: 10))
            var automaticA: [Bool] = [], automaticB: [Bool] = []
            for writable in [false, true] {
                client.isWritable = writable; origin.isWritable = writable
                client.pipeline.fireChannelWritabilityChanged(); origin.pipeline.fireChannelWritabilityChanged()
                // Embedded getOption(autoRead) hardcodes true; its public options retain actual setOption writes.
                automaticA.append(try #require(client.options.first { $0.option is ChannelOptions.Types.AutoReadOption }?.value as? Bool))
                automaticB.append(try #require(origin.options.first { $0.option is ChannelOptions.Types.AutoReadOption }?.value as? Bool))
            }
            #expect(automaticA == [false, true] && automaticB == [false, true])
            _ = try? client.finish(); _ = try? origin.finish(); loop.run()
            return Trace(a: left.bytes, b: right.bytes, flushA: left.flushes, flushB: right.flushes, closeA: left.closes, closeB: right.closes, autoA: automaticA, autoB: automaticB)
        }
        let baseline = try trace(nil), observed = try trace(handle)
        #expect(observed == baseline)
        #expect(observed.a == [0x8a, 1, 66])
        #expect(observed.b.count == 7 && observed.flushA == 1 && observed.flushB == 1)
        print("WS_GLUE_TRACE mode=\(mode) bytesA=\(observed.a) bytesB=\(observed.b) flushA=\(observed.flushA) flushB=\(observed.flushB) closeA=\(observed.closeA) closeB=\(observed.closeB) autoA=\(observed.autoA) autoB=\(observed.autoB) equal=true")
        await owner.shutdown(); blocker = nil; _ = consume blocker
        #expect(store.webSocketBudget.usedBytes(category: .mailbox) == 0)
    }
    @Test func failedPartialProductionHandoffJoinsObserverAndBothEndpoints() async throws {
        let store = observationStore()
        let owner = WebSocketCaptureCoordinator(store: store)
        let workers = NIOThreadPool(numberOfThreads: 1); workers.start()
        func exercise() throws {
            let loop = EmbeddedEventLoop(), origin = EmbeddedChannel(loop: loop)
            try origin.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 12346)).wait()
            let environment = ProxyEnvironment(configuration: .init(), recording: FlowRecording(store: store, isEnabled: ManagedAtomic(true)),
                tls: TLSInterception(certificateAuthority: try CertificateAuthority.generate()), passthrough: .init(),
                clientLookup: ClientLookupBatcher(processLookup: .none, threadPool: workers), webSockets: owner)
            let handler = ProxyHandler(mode: .forwardProxy, environment: environment, connectionFactory: { _, _, loop in loop.makeSucceededFuture(origin) })
            let decoder = ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes))
            let client = EmbeddedChannel(handlers: [HTTPMessageTranslation.responseEncoder(), HTTP1TransferCodingFramer<HTTPResponseHead>(), decoder, handler], loop: loop)
            try client.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 12345)).wait()
            try client.writeInbound(ByteBuffer(bytes: HTTP2UpgradeWire.request(target: "http://localhost:12346/ws", port: 12346)))
            client.pipeline.syncOperations.removeHandler(decoder, promise: nil)
            loop.run()
            origin.pipeline.fireChannelRead(ByteBuffer(bytes: HTTP2UpgradeWire.response + HTTP2UpgradeWire.greeting)); loop.run()
            #expect(!client.isActive && !origin.isActive)
            try client.closeFuture.wait(); try origin.closeFuture.wait()
            _ = try? client.finish(); _ = try? origin.finish()
        }
        try exercise(); await owner.shutdown(); try await workers.shutdownGracefully()
        #expect(owner.activeWorkerCount == 0)
        // Phase fix 4: the partially attached (one-sided) relay still ends both directions.
        let flowID = try #require(store.allFlows().first?.id)
        #expect(store.webSocketToken(flowID: flowID).flatMap { store.webSocketSummary(token: $0) }?.lifecycle == .transportEndedWithoutClose)
        for category in [WebSocketMemoryCategory.working, .native, .mailbox] { #expect(store.webSocketBudget.usedBytes(category: category) == 0) }
        #expect(store.allFlows().first?.statusCode == 101)
    }
    @Test func pendingOriginalHeadsRejectInterimAndReleaseOnEveryConsumingPath() async throws {
        let store = observationStore(), owner = WebSocketCaptureCoordinator(store: store)
        let heads = observationHeads()
        guard var pending = WebSocketPendingHandshake(request: heads.0, budget: store.webSocketBudget) else { Issue.record("pending admission refused"); await owner.shutdown(); return }
        let requestCost = store.webSocketBudget.usedBytes(category: .metadata)
        #expect(requestCost > heads.0.uri.utf8.count)
        pending.captureResponse(.init(version: .http1_1, status: .continue, headers: ["X-Interim": "excluded"]))
        #expect(store.webSocketBudget.usedBytes(category: .metadata) == requestCost)
        pending.captureResponse(heads.1)
        let bothCost = store.webSocketBudget.usedBytes(category: .metadata)
        #expect(bothCost > requestCost)
        // Force destination staging rejection while the original parsed heads remain owned.
        var blocker = store.webSocketBudget.reserve(category: .metadata, bytes: store.webSocketLimits.metadataBytes - bothCost)
        let handle = pending.begin(flowID: observationFlow(store), coordinator: owner, eventLoop: MultiThreadedEventLoopGroup.singleton.next())
        #expect(handle == nil)
        blocker = nil
        #expect(store.webSocketBudget.usedBytes(category: .metadata) == 0)
        if let another = WebSocketPendingHandshake(request: heads.0, budget: store.webSocketBudget) { another.discard() }
        #expect(store.webSocketBudget.usedBytes(category: .metadata) == 0)
        await owner.shutdown(); _ = consume blocker
    }
}

extension WebSocketRelayTests {
    @Test(arguments: [false, true])
    func actualWriterNilOwnerAndRejectedDetachReleaseObservation(nilOwner: Bool) async throws {
        let store = observationStore()
        let owner = WebSocketCaptureCoordinator(store: store)
        let heads = observationHeads(), id = observationFlow(store)
        let token = OSAllocatedUnfairLock<WebSocketSessionToken?>(initialState: nil)
        try await withConnectionFixture { fixture in
            let context = fixture.context()
            let acquisition = context.upstreamPool.acquire(route: fixture.route, forceFresh: false, responseSink: PoolSink())
            let upstream = try fixture.connect(0)
            let lease = try #require(try resolvedLease(acquisition) as? HTTP1UpstreamLease)
            let handle = try #require(owner.begin(flowID: id, request: heads.0, response: heads.1, eventLoop: fixture.loop))
            token.withLock { $0 = handle.token }
            var adapter: ProxyHandler? = ProxyHandler(mode: .forwardProxy, environment: fixture.environment)
            if !nilOwner { try fixture.client.pipeline.syncOperations.addHandler(adapter!) }
            let writer = ProxyHandler.Writer(owner: adapter!, channel: fixture.client)
            if nilOwner { adapter = nil }
            else { lease.cancel(error: ChannelError.eof); fixture.loop.run() }
            writer.upgrade(lease: lease, observation: handle)
            fixture.loop.run()
            #expect(!upstream.isActive)
            if !nilOwner { #expect(!fixture.client.isActive) }
        }
        await owner.shutdown()
        // Phase fix 4: a relay that never attached ends the Store session with a bounded diagnostic.
        let ended = try #require(token.withLock { $0 })
        let summary = try #require(store.webSocketSummary(token: ended))
        #expect(summary.lifecycle == .transportEndedWithoutClose && summary.closedAt != nil)
        #expect(summary.clientToServer.diagnostic?.code == "relayNotAttached" && summary.serverToClient.capture == .contentStoppedUntilReconnect)
        #expect(owner.activeWorkerCount == 0)
        #expect(store.webSocketBudget.usedBytes(category: .working) == 0)
        #expect(store.webSocketBudget.usedBytes(category: .mailbox) == 0)
        #expect(store.webSocketBudget.usedBytes(category: .native) == 0)
    }
}

extension WebSocketRelayTests {
    struct CleanupFault: Error, Equatable { let stage: ProxyCleanupStage }

    @Test(arguments: [ProxyCleanupStage.listenerClosed, .transportsDrained, .lookupsStopped, .eventLoopsStopped])
    func realCleanupContinuesAfterBoundaryErrors(first: ProxyCleanupStage) async throws {
        var response = HTTP2TestOrigin.Response(); response.supportsUpgrade = true
        let origin = try await HTTP2TestOrigin.start(protocols: ["http/1.1"], response: response, plaintext: true)
        let store = observationStore(), progress = WSProgress()
        let stages = OSAllocatedUnfairLock(initialState: [ProxyCleanupStage]())
        let lookupGate = WSSynchronousGate()
        let lookupFacts = OSAllocatedUnfairLock(initialState: (started: false, completed: false))
        let lookup = ProcessLookup(lookup: { _, _ in
            lookupFacts.withLock { $0.started = true }
            lookupGate.enter()
            lookupFacts.withLock { $0.completed = true }
            return ClientApp(pid: 42, name: "WS cleanup fixture")
        })
        var config = ProxyConfiguration(); config.port = 0
        let server = ProxyServer(configuration: config, certificateAuthority: try CertificateAuthority.generate(),
            store: store, passthrough: .init(), processLookup: lookup,
            drainDeadline: .init { loop, action in loop.execute(action); return {} },
            webSocketHooks: .init(afterChunk: { await progress.advance() }), cleanupProbe: { stage, loop in
                stages.withLock { $0.append(stage) }
                if stage == .transportsDrained {
                    #expect(lookupFacts.withLock { $0.started && !$0.completed })
                    lookupGate.release()
                }
                if stage == .lookupsStopped {
                    #expect(lookupFacts.withLock { $0.completed })
                    #expect(try await loop.submit { true }.get())
                    #expect(store.webSocketBudget.usedBytes(category: .working) == 0)
                    #expect(store.webSocketBudget.usedBytes(category: .native) == 0)
                    #expect(store.webSocketBudget.usedBytes(category: .mailbox) == 0)
                }
                // Throw at the selected boundary AND every later boundary: the first must win.
                if stage.rawValue >= first.rawValue { throw CleanupFault(stage: stage) }
            })
        var client: RawClient?
        do {
            try await server.start()
            let connected = try await RawClient.connect(port: try #require(server.boundPort)); client = connected
            try await connected.send(String(decoding: HTTP2UpgradeWire.request(target: "http://localhost:\(origin.port)/ws", port: origin.port), as: UTF8.self))
            _ = try await connected.receive(until: "\r\n\r\n")
            _ = try await connected.receive(until: "Hi")
            await progress.wait(1)
            let flow = try #require(store.allFlows().first)
            let token = try #require(store.webSocketToken(flowID: flow.id))
            do { try await server.stop(); Issue.record("Expected cleanup boundary error") }
            catch { #expect(error as? CleanupFault == CleanupFault(stage: first)) }
            #expect(stages.withLock { $0 } == [.listenerClosed, .transportsDrained, .lookupsStopped, .eventLoopsStopped])
            #expect(server.boundPort == nil)
            #expect(store.webSocketSummary(token: token)?.lifecycle == .transportEndedWithoutClose)
            try await server.stop() // The shared cleanup has settled despite its reported error.
            try await connected.close(); client = nil
            try await origin.stop()
        } catch {
            lookupGate.release()
            if let client { try? await client.close() }; try? await server.stop(); try? await origin.stop(); throw error
        }
    }

    @Test func failedStartKeepsBindErrorAfterActualCleanupBoundaryErrors() async throws {
        let origin = try await HTTP2TestOrigin.start(protocols: ["http/1.1"], plaintext: true)
        let stages = OSAllocatedUnfairLock(initialState: [ProxyCleanupStage]())
        let store = observationStore()
        var config = ProxyConfiguration(); config.port = origin.port; config.portFallbackCount = 0
        let server = ProxyServer(configuration: config, certificateAuthority: try CertificateAuthority.generate(), store: store,
            passthrough: .init(), processLookup: .none, drainDeadline: .standard, cleanupProbe: { stage, loop in
                stages.withLock { $0.append(stage) }
                if stage == .lookupsStopped { #expect(try await loop.submit { true }.get()) }
                throw CleanupFault(stage: stage)
            })
        do {
            do { try await server.start(); Issue.record("Expected occupied-port bind failure") }
            catch { #expect(error as? ProxyServerError == .portUnavailable) }
            #expect(stages.withLock { $0 } == [.transportsDrained, .lookupsStopped, .eventLoopsStopped])
            #expect(server.boundPort == nil)
            #expect(store.webSocketBudget.usedBytes(category: .working) == 0)
            #expect(store.webSocketBudget.usedBytes(category: .native) == 0)
            #expect(store.webSocketBudget.usedBytes(category: .mailbox) == 0)
            try await server.stop(); try await origin.stop()
        } catch { try? await server.stop(); try? await origin.stop(); throw error }
    }
}

extension WebSocketRelayTests {
    @Test func actualTLSHandlerIdentitiesSurviveObservedUpgrade() async throws {
        let seen = MultiThreadedEventLoopGroup.singleton.next().makePromise(of: Void.self)
        var response = HTTP2TestOrigin.Response(); response.supportsUpgrade = true; response.requestsObserved = seen
        let origin = try await HTTP2TestOrigin.start(protocols: ["http/1.1"], response: response)
        let progress = WSProgress()
        let fixture = try await WSTLSIdentityFixture.start(origin: origin, progress: progress)
        var client: RawClient?
        do {
            let connected = try await RawClient.connect(port: try #require(fixture.listener.localAddress?.port)); client = connected
            try await connected.send("CONNECT localhost:\(origin.port) HTTP/1.1\r\nHost: localhost:\(origin.port)\r\n\r\n")
            _ = try await connected.receive(until: "\r\n\r\n")
            try await connected.startTLS(trustRoots: .certificates([try NIOSSLCertificate(bytes: fixture.ca.rootCertificateDER, format: .der)]), serverName: "localhost")
            let request = String(decoding: HTTP2UpgradeWire.request(target: "/ws", port: origin.port), as: UTF8.self)
                .replacingOccurrences(of: "\r\n\r\n", with: "\r\nContent-Length: 1\r\n\r\n")
            try await connected.send(request)
            try await seen.futureResult.get() // Both TLS pipelines exist; 101 waits for the real request end.
            let downstream = try #require(fixture.downstreams.withLock { $0.first })
            let upstream = try #require(fixture.upstreams.withLock { $0.first })
            let beforeDown = try await downstream.eventLoop.submit {
                ObjectIdentifier(try downstream.pipeline.syncOperations.handler(type: NIOSSLServerHandler.self))
            }.get()
            let beforeUp = try await upstream.eventLoop.submit {
                ObjectIdentifier(try upstream.pipeline.syncOperations.handler(type: NIOSSLClientHandler.self))
            }.get()
            try await connected.send("x")
            #expect(try await connected.receive(until: "\r\n\r\n").hasPrefix("HTTP/1.1 101"))
            #expect(try await connected.receive(until: "Hi").hasSuffix("Hi"))
            await progress.wait(1)
            let afterDown = try await downstream.eventLoop.submit {
                ObjectIdentifier(try downstream.pipeline.syncOperations.handler(type: NIOSSLServerHandler.self))
            }.get()
            let afterUp = try await upstream.eventLoop.submit {
                ObjectIdentifier(try upstream.pipeline.syncOperations.handler(type: NIOSSLClientHandler.self))
            }.get()
            #expect(beforeDown == afterDown && beforeUp == afterUp)
            let flow = try #require(fixture.store.allFlows().first { $0.path == "/ws" })
            let token = try #require(fixture.store.webSocketToken(flowID: flow.id))
            #expect(fixture.store.webSocketPage(token: token, after: nil, limit: 10)?.rows.count == 1)
            print("WS_TLS_IDENTITY downstreamSame=true upstreamSame=true recordedGreeting=true")
            try await connected.close(); client = nil
            try await fixture.stop(); try await origin.stop()
        } catch {
            if let client { try? await client.close() }; try? await fixture.stop(); try? await origin.stop(); throw error
        }
    }
}
