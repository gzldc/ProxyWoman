import Foundation
import FlowStore
import NIOCore
import NIOEmbedded
import NIOHTTP1
import Testing
@testable import ProxyCore

@Suite(.productionChinese) struct HTTPExchangeTests {
    @Test(arguments: [false, true])
    func actualNonTLSConnectRetainsPendingAndLiveRelayThroughDrain(late: Bool) async throws {
        try await withConnectionFixture { fixture in
            let run = ProxyRunConnections(loop: fixture.loop, deadline: ProxyDrainDeadline { loop, expire in
                let timer = loop.scheduleTask(in: .milliseconds(100), expire)
                return { timer.cancel() }
            })
            let context = fixture.context(run: run)
            let connecting = fixture.loop.makePromise(of: Channel.self)
            var calls = 0
            let handler = ProxyHandler(mode: .forwardProxy, environment: context.environment,
                connectionFactory: { host, port, _ in
                    #expect(host == "example.test" && port == 443)
                    calls += 1
                    return connecting.futureResult
                }, inheritedConnection: context)
            try fixture.client.pipeline.syncOperations.addHandlers([
                HTTPMessageTranslation.responseEncoder(), HTTP1TransferCodingFramer<HTTPResponseHead>(),
                ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes)), handler])
            try fixture.client.writeInbound(ByteBuffer(string: "CONNECT example.test:443 HTTP/1.1\r\nHost: example.test:443\r\n\r\n"))
            fixture.loop.run()
            _ = try fixture.client.pipeline.syncOperations.handler(type: ClientHelloSniffer.self)
            while let _ = try fixture.client.readOutbound(as: IOData.self) {}
            try fixture.client.writeInbound(ByteBuffer(string: "plain synthetic relay"))
            #expect(calls == 1)
            let close = ExchangeCloseBarrier()
            let raw = EmbeddedChannel(handler: close, loop: fixture.loop)
            try raw.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 12346)).wait()
            fixture.channels.append(raw)
            if !late { connecting.succeed(raw); fixture.loop.run() }
            var joined = false
            run.drain().assumeIsolated().whenSuccess { joined = true }
            fixture.loop.run()
            #expect(fixture.client.isActive)
            #expect(!joined)
            fixture.loop.advanceTime(by: .milliseconds(100))
            #expect(!fixture.client.isActive)
            #expect(!joined)
            if late { connecting.succeed(raw); fixture.loop.run() }
            #expect(raw.isActive && !joined)
            close.release(); fixture.loop.run()
            #expect(!raw.isActive && joined)
        }
    }

    @Test func runJoinsLateRawTransportAfterOriginalSocketCloses() async throws {
        try await withConnectionFixture { fixture in
            let run = ProxyRunConnections(loop: fixture.loop, deadline: ProxyDrainDeadline { loop, expire in
                let timer = loop.scheduleTask(in: .milliseconds(100), expire)
                return { timer.cancel() }
            })
            let context = fixture.context(run: run)
            let connecting = fixture.loop.makePromise(of: Channel.self)
            _ = context.retainTransportWork(connecting.futureResult)
            var joined = false
            run.drain().assumeIsolated().whenSuccess { joined = true }
            fixture.loop.run()
            #expect(fixture.client.isActive)
            fixture.loop.advanceTime(by: .milliseconds(100))
            #expect(!fixture.client.isActive && !joined)
            let close = ExchangeCloseBarrier()
            let raw = EmbeddedChannel(handler: close, loop: fixture.loop)
            try raw.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 12346)).wait()
            fixture.channels.append(raw)
            connecting.succeed(raw); fixture.loop.run()
            #expect(raw.isActive && !joined)
            close.release(); fixture.loop.run()
            #expect(!raw.isActive && joined)
        }
    }

    @Test func runDrainRetainsPendingDeliveryAndRejectsNewExchange() async throws {
        try await withConnectionFixture { fixture in
            let run = ProxyRunConnections(loop: fixture.loop)
            let context = fixture.context(run: run)
            let delivery = fixture.loop.makePromise(of: Void.self)
            let writer = ExchangeWriter(channel: fixture.client)
            writer.bodyCompletion = delivery.futureResult
            let exchange = makeExchange("/admitted", writer: writer, context: context)
            exchange.receiveRequest(.end(nil))
            let upstream = try fixture.connect(0)
            try upstream.writeInbound(ByteBuffer(string: "HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\none"))
            run.stopAdmission()
            let drained = run.drain()
            var joined = false
            drained.assumeIsolated().whenSuccess { joined = true }
            fixture.loop.run()
            #expect(!joined)
            #expect(fixture.client.isActive)
            let rejected = ExchangeWriter(channel: fixture.client)
            let newExchange = makeExchange("/rejected", writer: rejected, context: context)
            newExchange.receiveRequest(.end(nil))
            #expect(rejected.aborts == 1)
            #expect(fixture.connections.count == 1)
            #expect(fixture.store.allFlows().map(\.path) == ["/admitted"])
            delivery.succeed(())
            fixture.loop.run()
            #expect(joined)
            #expect(!fixture.client.isActive && !upstream.isActive)
            #expect(fixture.store.allFlows().first?.state == .completed)
        }
    }

    @Test func runExpiryJoinsLateConnectAndActualTransportClose() async throws {
        try await withConnectionFixture { fixture in
            let deadline = ProxyDrainDeadline { loop, expire in
                let timer = loop.scheduleTask(in: .milliseconds(100), expire)
                return { timer.cancel() }
            }
            let run = ProxyRunConnections(loop: fixture.loop, deadline: deadline)
            let context = fixture.context(run: run)
            let writer = ExchangeWriter(channel: fixture.client)
            let exchange = makeExchange("/late", writer: writer, context: context)
            exchange.receiveRequest(.end(nil))
            run.stopAdmission()
            var firstJoined = false, secondJoined = false
            run.drain().assumeIsolated().whenSuccess { firstJoined = true }
            run.drain().assumeIsolated().whenSuccess { secondJoined = true }
            fixture.loop.run()
            #expect(fixture.client.isActive && !firstJoined && !secondJoined)
            fixture.loop.advanceTime(by: .milliseconds(100))
            #expect(!fixture.client.isActive)
            #expect(writer.aborts == 1)
            #expect(!firstJoined && !secondJoined)
            let close = ExchangeCloseBarrier()
            let late = EmbeddedChannel(handler: close, loop: fixture.loop)
            try late.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 12346)).wait()
            fixture.channels.append(late)
            fixture.connections[0].succeed(late)
            fixture.loop.run()
            #expect(late.isActive)
            #expect(!firstJoined && !secondJoined)
            close.release()
            fixture.loop.run()
            #expect(!late.isActive)
            #expect(firstJoined && secondJoined)
            #expect(fixture.store.allFlows().first?.completedAt != nil)
            #expect(fixture.store.allFlows().first?.state != .completed)
        }
    }

    @Test(arguments: [false, true], [false, true])
    func normalResponseOwnsPendingWritesUntilOutcome(succeeds: Bool, delayEnd: Bool) async throws {
        try await withConnectionFixture { fixture in
            let context = fixture.context()
            let pending = fixture.loop.makePromise(of: Void.self)
            var resolved = false
            defer { if !resolved { pending.succeed(()) } }
            let writer = ExchangeWriter(channel: fixture.client, version: .http2)
            if delayEnd { writer.endCompletion = pending.futureResult }
            else { writer.bodyCompletion = pending.futureResult }
            let first = makeExchange("/pending-write", writer: writer, context: context)
            first.receiveRequest(.end(nil))
            let upstream = try fixture.connect(0)
            try upstream.writeInbound(ByteBuffer(string: "HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\none"))
            #expect(writer.finishes == 0)
            #expect(writer.aborts == 0)
            #expect(fixture.store.allFlows().first?.state != .completed)
            #expect(fixture.store.allFlows().first?.completedAt == nil)
            #expect(context.snapshot.exchanges.count == 1)
            // A real pool must retain the first lease until delivery outcome, so this
            // sibling needs a separate connection instead of taking that lease early.
            let healthy = ExchangeWriter(channel: fixture.client)
            let sibling = makeExchange("/sibling", writer: healthy, context: context)
            sibling.receiveRequest(.end(nil))
            try #require(fixture.connections.count == 2)
            let siblingChannel = try fixture.connect(1)
            try siblingChannel.writeInbound(ByteBuffer(string: "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"))
            #expect(healthy.finishes == 1)
            if succeeds { pending.succeed(()) } else { pending.fail(ChannelError.ioOnClosedChannel) }
            resolved = true
            #expect(writer.finishes == (succeeds ? 1 : 0))
            #expect(writer.aborts == (succeeds ? 0 : 1))
            #expect(upstream.isActive == succeeds)
            let flow = try #require(fixture.store.allFlows().first { $0.path == "/pending-write" })
            #expect((flow.state == .completed) == succeeds)
            if !succeeds, case .failed = flow.state {} else if !succeeds { Issue.record("Failed write did not fail its flow") }
            #expect(flow.completedAt != nil)
            #expect(context.snapshot.exchanges.isEmpty)
            let next = ExchangeWriter(channel: fixture.client)
            let subsequent = makeExchange("/subsequent", writer: next, context: context)
            subsequent.receiveRequest(.end(nil))
            // Late callbacks belong to the old exchange, never to the new lease owner.
            first.cancel(reason: "late duplicate")
            first.receiveResponse(.end(nil), attempt: 0)
            first.upstreamClosed(error: ChannelError.eof, attempt: 0)
            #expect(next.aborts == 0)
            // Identify the actual reused socket by its freshly written request bytes.
            for channel in [upstream, siblingChannel] {
                var bytes = ""
                while let part = try channel.readOutbound(as: ByteBuffer.self) { bytes += String(buffer: part) }
                if bytes.contains("/subsequent") {
                    try channel.writeInbound(ByteBuffer(string: "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"))
                }
            }
            #expect(next.finishes == 1)
            #expect(next.aborts == 0)
            #expect(writer.finishes == (succeeds ? 1 : 0))
            #expect(writer.aborts == (succeeds ? 0 : 1))
            #expect(fixture.connections.count == 2)
        }
    }

    @Test func earlyResponseDisposalTimerIsOneShotEvenWithLateFailedWrites() async throws {
        try await withConnectionFixture { fixture in
            var limits = HTTPTransportLimits(); limits.drainTimeout = .seconds(1)
            let context = fixture.context(limits: limits)
            let delayedWrite = fixture.loop.makePromise(of: Void.self)
            let writer = ExchangeWriter(channel: fixture.client, version: .http2)
            writer.writeCompletion = delayedWrite.futureResult
            let exchange = makeExchange("/early", writer: writer, context: context)
            let upstream = try fixture.connect(0)
            try upstream.writeInbound(ByteBuffer(string: "HTTP/1.1 413 Content Too Large\r\nContent-Length: 0\r\n\r\n"))
            #expect(exchange.snapshot.uploadDisposalTimers == 1)
            #expect(context.snapshot.exchanges.count == 1)
            fixture.loop.advanceTime(by: .milliseconds(500))
            exchange.receiveResponse(.end(nil), attempt: 0)
            #expect(exchange.snapshot.uploadDisposalTimers == 1)
            fixture.loop.advanceTime(by: .milliseconds(500))
            #expect(exchange.snapshot.uploadDisposalTimers == 0)
            #expect(context.snapshot.exchanges.isEmpty)
            #expect(writer.aborts == 1)
            delayedWrite.fail(ChannelError.ioOnClosedChannel)
            exchange.receiveRequest(.end(nil))
            #expect(writer.aborts == 1)
            #expect(fixture.store.allFlows().first?.state == .completed)
        }
    }

    @Test func failedDownstreamWriteCancelsOnlyItsLeaseAndCannotCompleteFlow() async throws {
        try await withConnectionFixture { fixture in
            let context = fixture.context()
            let broken = ExchangeWriter(channel: fixture.client)
            broken.writeFailure = ChannelError.ioOnClosedChannel
            let first = makeExchange("/broken", writer: broken, context: context)
            first.receiveRequest(.end(nil))
            let upstream = try fixture.connect(0)
            try upstream.writeInbound(ByteBuffer(string: "HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\nbad"))
            #expect(broken.aborts == 1)
            #expect(broken.finishes == 0)
            #expect(!upstream.isActive)
            #expect(fixture.store.allFlows().first?.state != .completed)
            #expect(context.snapshot.exchanges.isEmpty)
            let healthy = ExchangeWriter(channel: fixture.client)
            let second = makeExchange("/healthy", writer: healthy, context: context)
            second.receiveRequest(.end(nil))
            try #require(fixture.connections.count == 2)
            let next = try fixture.connect(1)
            try next.writeInbound(ByteBuffer(string: "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"))
            #expect(healthy.finishes == 1)
            #expect(healthy.aborts == 0)
        }
    }

    @Test func pendingSnapshotCountsSynthesizedHostAndOwnsOnlySliceBytes() async throws {
        try await withConnectionFixture { fixture in
            let context = fixture.context()
            let writer = ExchangeWriter(channel: fixture.client)
            let exchange = makeExchange("/owned", writer: writer, context: context)
            // /owned (6) + GET (3) + Host (4) + example.test (12) + field overhead (32).
            #expect(exchange.snapshot.pendingBytes == 57)
            #expect(context.snapshot.pendingBytes == 57)
            let backing = ByteBuffer(repeating: 120, count: 1_048_576)
            let slice = try #require(backing.getSlice(at: 10, length: 10))
            exchange.receiveRequest(.body(slice))
            #expect(exchange.snapshot.pendingBytes == 67)
            #expect(exchange.snapshot.pendingBodyCapacity <= 16)
            #expect(context.snapshot.pendingBytes == 67)
            print("HTTP2 pending ownership snapshot: \(context.snapshot)")
            exchange.cancel(reason: "fixture cancellation")
            #expect(context.snapshot.pendingBytes == 0)
            #expect(context.snapshot.exchanges.isEmpty)
            #expect(context.upstreamPool.snapshot.pending == 0)
            #expect(context.upstreamPool.snapshot.acquisitionTimers == 0)
            _ = try fixture.connect(0)
        }
    }

    @Test func independentExchangesShareContextButNeverCaptureOrTerminateEachOther() async throws {
        try await withConnectionFixture { fixture in
            let context = fixture.context()
            let writer1 = ExchangeWriter(channel: fixture.client)
            let writer2 = ExchangeWriter(channel: fixture.client)
            let first = makeExchange("/first", writer: writer1, context: context)
            let second = makeExchange("/second", writer: writer2, context: context)
            first.receiveRequest(.end(nil))
            second.receiveRequest(.end(nil))
            let channel1 = try fixture.connect(0)
            let channel2 = try fixture.connect(1)
            try channel2.writeInbound(ByteBuffer(string: "HTTP/1.1 201 Created\r\nContent-Length: 3\r\n\r\ntwo"))
            first.cancel(reason: "cancel first only")
            first.cancel(reason: "duplicate")
            first.upstreamClosed(error: ChannelError.eof, attempt: 0)
            #expect(!channel1.isActive)
            #expect(channel2.isActive)
            #expect(writer1.finishes == 0)
            #expect(writer1.aborts == 1)
            #expect(writer2.finishes == 1)
            #expect(writer2.aborts == 0)
            let flows = fixture.store.allFlows()
            #expect(flows.count == 2)
            let complete = try #require(flows.first { $0.path == "/second" })
            #expect(complete.state == .completed)
            #expect(complete.statusCode == 201)
            #expect(try complete.responseBody?.load() == Data("two".utf8))
            #expect(flows.first { $0.path == "/first" }?.completedAt != nil)
        }
    }

    @Test(arguments: [false, true])
    func lateClientLookupUpdatesAlreadyCompletedExchange(closeSocket: Bool) async throws {
        try await withConnectionFixture { fixture in
            let lookup = fixture.loop.makePromise(of: ClientApp?.self)
            let context = fixture.context(lookup: lookup.futureResult)
            let writer = ExchangeWriter(channel: fixture.client)
            var exchange: HTTPExchange? = makeExchange("/late-client", writer: writer, context: context)
            exchange?.receiveRequest(.end(nil))
            let upstream = try fixture.connect(0)
            fixture.loop.advanceTime(by: .milliseconds(50))
            try upstream.writeInbound(ByteBuffer(string: "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"))
            exchange = nil
            #expect(writer.finishes == 1)
            if closeSocket { try fixture.client.close().wait() }
            lookup.succeed(ClientApp(pid: 7, name: "late app"))
            #expect(fixture.store.allFlows().first?.client?.name == "late app")
        }
    }

    @Test func replacementAdapterKeepsContextUntilOriginalSocketCloses() async throws {
        try await withConnectionFixture { fixture in
            let context = fixture.context()
            let original = ProxyHandler(mode: .forwardProxy, environment: fixture.environment, inheritedConnection: context)
            try fixture.client.pipeline.syncOperations.addHandler(original)
            try fixture.client.writeInbound(HTTPServerRequestPart.head(.init(version: .http1_1, method: .GET, uri: "http://example.test/first")))
            try fixture.client.writeInbound(HTTPServerRequestPart.end(nil))
            let upstream = try fixture.connect(0)
            try upstream.writeInbound(ByteBuffer(string: "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"))
            fixture.client.pipeline.syncOperations.removeHandler(original, promise: nil)
            fixture.loop.run()
            let replacement = ProxyHandler(mode: .forwardProxy, environment: fixture.environment, inheritedConnection: context)
            try fixture.client.pipeline.syncOperations.addHandler(replacement)
            try fixture.client.writeInbound(HTTPServerRequestPart.head(.init(version: .http1_1, method: .GET, uri: "http://example.test/second")))
            try fixture.client.writeInbound(HTTPServerRequestPart.end(nil))
            #expect(fixture.connections.count == 1)
            #expect(upstream.isActive)
            try upstream.writeInbound(ByteBuffer(string: "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"))
            #expect(fixture.store.allFlows().count == 2)
            #expect(fixture.store.allFlows().allSatisfy { $0.state == .completed })
            fixture.client.pipeline.syncOperations.removeHandler(replacement, promise: nil)
            fixture.loop.run()
            try fixture.client.close().wait()
            fixture.loop.run()
            #expect(!upstream.isActive)
        }
    }

    @Test func responseFailureAbortsOnlyTheAffectedWriterAndNeverReportsNormalFinish() async throws {
        try await withConnectionFixture { fixture in
            let context = fixture.context()
            let writer = ExchangeWriter(channel: fixture.client)
            let exchange = makeExchange("/interim-eof", writer: writer, context: context)
            exchange.receiveRequest(.end(nil))
            let upstream = try fixture.connect(0)
            try upstream.writeInbound(ByteBuffer(string: "HTTP/1.1 103 Early Hints\r\n\r\n"))
            try upstream.close().wait()
            exchange.upstreamClosed(error: ChannelError.eof, attempt: 0)
            #expect(writer.statuses == [103])
            #expect(writer.finishes == 0)
            #expect(writer.aborts == 1)
            #expect(fixture.connections.count == 1)
            #expect(fixture.store.allFlows().first?.completedAt != nil)
        }
    }

    @Test(arguments: [false, true])
    func pendingBudgetFailureReleasesBytesAndOnlyFailsItsExchange(contextBudget: Bool) async throws {
        try await withConnectionFixture { fixture in
            var limits = HTTPTransportLimits()
            limits.pendingBytesPerExchange = contextBudget ? 256 : 128
            limits.pendingBytesPerContext = contextBudget ? 128 : 1024
            let context = fixture.context(limits: limits)
            let writer1 = ExchangeWriter(channel: fixture.client)
            let writer2 = ExchangeWriter(channel: fixture.client)
            let first = makeExchange("/first", writer: writer1, context: context)
            let second = makeExchange("/second", writer: writer2, context: context)
            first.receiveRequest(.body(ByteBuffer(repeating: 120, count: contextBudget ? 20 : 80)))
            first.receiveRequest(.end(nil))
            second.receiveRequest(.body(ByteBuffer(repeating: 121, count: 60)))
            second.receiveRequest(.end(nil))
            let late = try fixture.connect(0)
            #expect(!late.isActive)
            try #require(fixture.connections.count == 2)
            let upstream = try fixture.connect(1)
            var forwarded = ""
            while let bytes = try upstream.readOutbound(as: ByteBuffer.self) {
                forwarded += String(decoding: bytes.readableBytesView, as: UTF8.self)
            }
            #expect(forwarded.contains(String(repeating: "y", count: 60)))
            try upstream.writeInbound(ByteBuffer(string: "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"))
            #expect(writer1.statuses == [502])
            #expect(writer1.finishes == 1)
            #expect(writer2.statuses == [200])
            #expect(writer2.finishes == 1)
            #expect(fixture.store.allFlows().count == 2)
            #expect(fixture.store.allFlows().first { $0.path == "/second" }?.state == .completed)
        }
    }

    @Test func oversizedPendingHeadDoesNotStartAnUpstreamAfterLocalFailure() async throws {
        try await withConnectionFixture { fixture in
            var limits = HTTPTransportLimits()
            limits.pendingBytesPerExchange = 1
            let context = fixture.context(limits: limits)
            let writer = ExchangeWriter(channel: fixture.client)
            let exchange = makeExchange("/oversize-head", writer: writer, context: context)
            exchange.receiveRequest(.end(nil))
            #expect(fixture.connections.isEmpty)
            #expect(writer.statuses == [502])
            #expect(writer.finishes == 1)
            // Settle any erroneous connect so a failing implementation still cleans up deterministically.
            if !fixture.connections.isEmpty { _ = try fixture.connect(0) }
        }
    }

    @Test func recordingSwitchIsReadForEachExchangeOnExistingContext() async throws {
        try await withConnectionFixture { fixture in
            let context = fixture.context()
            let first = makeExchange("/recorded", writer: ExchangeWriter(channel: fixture.client), context: context)
            first.receiveRequest(.end(nil))
            let upstream = try fixture.connect(0)
            fixture.environment.recording.isEnabled.store(false, ordering: .relaxed)
            try upstream.writeInbound(ByteBuffer(string: "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"))
            let second = makeExchange("/paused", writer: ExchangeWriter(channel: fixture.client), context: context)
            second.receiveRequest(.end(nil))
            try upstream.writeInbound(ByteBuffer(string: "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"))
            fixture.environment.recording.isEnabled.store(true, ordering: .relaxed)
            let third = makeExchange("/resumed", writer: ExchangeWriter(channel: fixture.client), context: context)
            third.receiveRequest(.end(nil))
            try upstream.writeInbound(ByteBuffer(string: "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"))
            #expect(Set(fixture.store.allFlows().map(\.path)) == ["/recorded", "/resumed"])
            #expect(fixture.store.allFlows().allSatisfy { $0.state == .completed })
            #expect(fixture.connections.count == 1)
        }
    }

    @Test func oldAttemptCallbacksCannotTerminateSuccessfulFreshRetry() async throws {
        try await withConnectionFixture { fixture in
            let context = fixture.context()
            let primeWriter = ExchangeWriter(channel: fixture.client)
            let prime = makeExchange("/prime", writer: primeWriter, context: context)
            prime.receiveRequest(.end(nil))
            let old = try fixture.connect(0)
            try old.writeInbound(ByteBuffer(string: "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"))
            let writer = ExchangeWriter(channel: fixture.client)
            let exchange = makeExchange("/retry", writer: writer, context: context)
            exchange.receiveRequest(.end(nil))
            try old.close().wait()
            #expect(fixture.connections.count == 2)
            let fresh = try fixture.connect(1)
            exchange.upstreamClosed(error: ChannelError.eof, attempt: 0)
            exchange.receiveResponse(.head(HTTPResponseHead(version: .http1_1, status: .badGateway)), attempt: 0)
            exchange.upstreamWritabilityChanged(false, attempt: 0)
            try fresh.writeInbound(ByteBuffer(string: "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"))
            exchange.upstreamClosed(error: ChannelError.eof, attempt: 1)
            #expect(writer.finishes == 1)
            #expect(writer.aborts == 0)
            #expect(writer.statuses == [200])
            #expect(fixture.connections.count == 2)
            #expect(fixture.store.allFlows().filter { $0.path == "/retry" }.count == 1)
            #expect(fixture.store.allFlows().allSatisfy { $0.state == .completed })
        }
    }
}

private func makeExchange(_ path: String, writer: ExchangeWriter, context: ClientConnectionContext) -> HTTPExchange {
    let exchange = HTTPExchange(requestHead: HTTPRequestHead(version: .http1_1, method: .GET, uri: "http://example.test" + path),
        target: RequestTarget(host: "example.test", port: 80, originForm: path, defaultPort: 80),
        scheme: "http", downstream: writer, connection: context, transport: .init(downstreamRequest: .http1_1))
    exchange.execute()
    return exchange
}

private final class ExchangeWriter: DownstreamResponseWriter {
    let channel: Channel
    let version: HTTPWireVersion
    var eventLoop: EventLoop { channel.eventLoop }
    var isWritable: Bool { channel.isWritable }
    var isActive: Bool { channel.isActive }
    var finishes = 0
    var aborts = 0
    var statuses: [UInt] = []
    var writeFailure: Error?
    var writeCompletion: EventLoopFuture<Void>?
    var endCompletion: EventLoopFuture<Void>?
    var bodyCompletion: EventLoopFuture<Void>?
    init(channel: Channel, version: HTTPWireVersion = .http1_1) { self.channel = channel; self.version = version }
    func write(_ part: HTTPServerResponsePart) -> EventLoopFuture<Void> {
        if case .head(let head) = part { statuses.append(head.status.code) }
        if let writeFailure { return channel.eventLoop.makeFailedFuture(writeFailure) }
        if case .end = part, let endCompletion { return endCompletion }
        if case .body = part, let bodyCompletion { return bodyCompletion }
        if let writeCompletion { return writeCompletion }
        return channel.eventLoop.makeSucceededVoidFuture()
    }
    func flush() { channel.flush() }
    func setRequestReading(_ enabled: Bool) {}
    func responseFinished() { finishes += 1 }
    func abort(_ error: Error) { aborts += 1 }
}

private final class ExchangeCloseBarrier: ChannelOutboundHandler {
    typealias OutboundIn = ByteBuffer
    private var held: [(ChannelHandlerContext, NIOCore.CloseMode, EventLoopPromise<Void>?)] = []
    func close(context: ChannelHandlerContext, mode: NIOCore.CloseMode, promise: EventLoopPromise<Void>?) {
        held.append((context, mode, promise))
    }
    func release() {
        let pending = held; held.removeAll()
        for (context, mode, promise) in pending { context.close(mode: mode, promise: promise) }
    }
}
