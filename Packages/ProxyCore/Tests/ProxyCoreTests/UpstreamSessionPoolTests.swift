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
import RulesEngine

@Suite(.productionChinese) struct UpstreamSessionPoolTests {
    @Test func capacityIsReservedBeforeConnectAndHTTP1LeasesAreExclusive() async throws {
        try await withConnectionFixture { fixture in
            var limits = HTTPTransportLimits()
            limits.http1SocketsPerRoute = 2
            limits.totalUpstreamSockets = 2
            let context = fixture.context(limits: limits)
            let first = context.upstreamPool.acquire(route: fixture.route, forceFresh: false, responseSink: PoolSink())
            let second = context.upstreamPool.acquire(route: fixture.route, forceFresh: false, responseSink: PoolSink())
            #expect(fixture.connections.count == 1) // initially unknown protocol: only one connect
            let channel1 = try fixture.connect(0)
            let lease1 = try resolvedLease(first)
            #expect(fixture.connections.count == 2)
            let channel2 = try fixture.connect(1)
            let lease2 = try resolvedLease(second)
            #expect(lease1.channel !== lease2.channel)
            let third = context.upstreamPool.acquire(route: fixture.route, forceFresh: false, responseSink: PoolSink())
            var thirdDone = false
            third.futureResult.assumeIsolated().whenComplete { _ in thirdDone = true }
            #expect(!thirdDone)
            #expect(fixture.connections.count == 2)
            lease1.release(reusable: true)
            let lease3 = try resolvedLease(third)
            #expect(lease3.channel === channel1)
            #expect(lease3.wasReused)
            lease1.cancel(error: ChannelError.eof) // released lease cannot close its new owner
            #expect(channel1.isActive)
            #expect(channel2.isActive)
            lease2.release(reusable: false)
            lease3.release(reusable: false)
        }
    }

    @Test func cancelledWaitingAcquisitionNeverConsumesReleasedSocket() async throws {
        try await withConnectionFixture { fixture in
            var limits = HTTPTransportLimits()
            limits.totalUpstreamSockets = 1
            let context = fixture.context(limits: limits)
            let first = context.upstreamPool.acquire(route: fixture.route, forceFresh: false, responseSink: PoolSink())
            _ = try fixture.connect(0)
            let lease = try resolvedLease(first)
            let cancelled = context.upstreamPool.acquire(route: fixture.route, forceFresh: false, responseSink: PoolSink())
            var settlements = 0
            cancelled.futureResult.assumeIsolated().whenFailure { _ in settlements += 1 }
            cancelled.cancel()
            cancelled.cancel()
            let next = context.upstreamPool.acquire(route: fixture.route, forceFresh: false, responseSink: PoolSink())
            lease.release(reusable: true)
            let nextLease = try resolvedLease(next)
            #expect(settlements == 1)
            #expect(nextLease.wasReused)
            #expect(fixture.connections.count == 1)
            nextLease.release(reusable: false)
        }
    }

    @Test(arguments: [false, true])
    func cancelledOrExpiredConnectKeepsReservationUntilLateChannelIsClosed(expires: Bool) async throws {
        try await withConnectionFixture { fixture in
            var limits = HTTPTransportLimits()
            limits.totalUpstreamSockets = 1
            let context = fixture.context(limits: limits)
            let cancelled = context.upstreamPool.acquire(route: fixture.route, forceFresh: false, responseSink: PoolSink())
            var settlements = 0
            cancelled.futureResult.assumeIsolated().whenFailure { _ in settlements += 1 }
            if expires { fixture.loop.advanceTime(by: .seconds(1)) }
            else { cancelled.cancel() }
            let next = context.upstreamPool.acquire(route: fixture.route, forceFresh: false, responseSink: PoolSink())
            #expect(fixture.connections.count == 1)
            let late = try fixture.connect(0)
            fixture.loop.run()
            #expect(!late.isActive)
            #expect(fixture.connections.count == 2)
            #expect(settlements == 1)
            _ = try fixture.connect(1)
            try resolvedLease(next).release(reusable: false)
        }
    }

    @Test func deadlineIncludesTimeWaitingForCapacity() async throws {
        try await withConnectionFixture { fixture in
            var limits = HTTPTransportLimits()
            limits.totalUpstreamSockets = 1
            let context = fixture.context(limits: limits)
            let first = context.upstreamPool.acquire(route: fixture.route, forceFresh: false, responseSink: PoolSink())
            _ = try fixture.connect(0)
            let lease = try resolvedLease(first)
            let waiting = context.upstreamPool.acquire(route: fixture.route, forceFresh: false, responseSink: PoolSink())
            var failed = false
            waiting.futureResult.assumeIsolated().whenFailure { _ in failed = true }
            fixture.loop.advanceTime(by: .seconds(1))
            #expect(failed)
            lease.release(reusable: true)
            #expect(fixture.connections.count == 1)
        }
    }

    @Test func shutdownSettlesActiveAndWaitingOwnersExactlyOnce() async throws {
        try await withConnectionFixture { fixture in
            var limits = HTTPTransportLimits()
            limits.totalUpstreamSockets = 1
            let context = fixture.context(limits: limits)
            let sink = PoolSink()
            let first = context.upstreamPool.acquire(route: fixture.route, forceFresh: false, responseSink: sink)
            let channel = try fixture.connect(0)
            let lease = try resolvedLease(first)
            let waiting = context.upstreamPool.acquire(route: fixture.route, forceFresh: false, responseSink: PoolSink())
            var failed = 0
            waiting.futureResult.assumeIsolated().whenFailure { _ in failed += 1 }
            context.close(error: ChannelError.eof)
            context.close(error: ChannelError.eof)
            waiting.cancel()
            lease.cancel(error: ChannelError.eof)
            lease.release(reusable: true)
            fixture.loop.run()
            #expect(!channel.isActive)
            #expect(sink.closes == 1)
            #expect(failed == 1)
            #expect(fixture.connections.count == 1)
        }
    }

    @Test func pendingLimitRejectsOverflowAndCancellationRestoresAdmission() async throws {
        try await withConnectionFixture { fixture in
            var limits = HTTPTransportLimits()
            limits.pendingAcquisitions = 1
            limits.totalUpstreamSockets = 1
            let context = fixture.context(limits: limits)
            let first = context.upstreamPool.acquire(route: fixture.route, forceFresh: false, responseSink: PoolSink())
            let overflow = context.upstreamPool.acquire(route: fixture.route, forceFresh: false, responseSink: PoolSink())
            var overflowFailed = false
            overflow.futureResult.assumeIsolated().whenFailure { _ in overflowFailed = true }
            #expect(overflowFailed)
            first.cancel()
            let next = context.upstreamPool.acquire(route: fixture.route, forceFresh: false, responseSink: PoolSink())
            var nextFailed = false
            next.futureResult.assumeIsolated().whenFailure { _ in nextFailed = true }
            #expect(!nextFailed)
            #expect(fixture.connections.count == 1)
            _ = try fixture.connect(0)
            try #require(fixture.connections.count == 2)
            _ = try fixture.connect(1)
            try resolvedLease(next).release(reusable: false)
        }
    }

    @Test func idleTimeoutClosesSocketAndAllowsNewAdmission() async throws {
        try await withConnectionFixture { fixture in
            var limits = HTTPTransportLimits()
            limits.idleTimeout = .seconds(1)
            limits.totalUpstreamSockets = 1
            let context = fixture.context(limits: limits)
            let first = context.upstreamPool.acquire(route: fixture.route, forceFresh: false, responseSink: PoolSink())
            let old = try fixture.connect(0)
            try resolvedLease(first).release(reusable: true)
            fixture.loop.advanceTime(by: .seconds(1))
            #expect(!old.isActive)
            let next = context.upstreamPool.acquire(route: fixture.route, forceFresh: false, responseSink: PoolSink())
            #expect(fixture.connections.count == 2)
            _ = try fixture.connect(1)
            #expect(try !resolvedLease(next).wasReused)
            try resolvedLease(next).release(reusable: false)
        }
    }

    @Test(arguments: [1, 2])
    func forcedFreshEvictsIdleSocketWithoutLosingCapacityWakeup(totalSockets: Int) async throws {
        try await withConnectionFixture { fixture in
            var limits = HTTPTransportLimits()
            limits.http1SocketsPerRoute = 1
            limits.totalUpstreamSockets = totalSockets
            let context = fixture.context(limits: limits)
            let first = context.upstreamPool.acquire(route: fixture.route, forceFresh: false, responseSink: PoolSink())
            let old = try fixture.connect(0)
            try resolvedLease(first).release(reusable: true)
            let fresh = context.upstreamPool.acquire(route: fixture.route, forceFresh: true, responseSink: PoolSink())
            fixture.loop.run()
            #expect(!old.isActive)
            try #require(fixture.connections.count == 2)
            _ = try fixture.connect(1)
            let lease = try resolvedLease(fresh)
            #expect(!lease.wasReused)
            lease.release(reusable: false)
        }
    }

    @Test func upgradeDetachTransfersExactlyOnceAndIgnoresOldSink() async throws {
        try await withConnectionFixture { fixture in
            var limits = HTTPTransportLimits()
            limits.totalUpstreamSockets = 1
            let context = fixture.context(limits: limits)
            let sink = PoolSink()
            let request = context.upstreamPool.acquire(
                route: .init(scheme: "http", host: "example.test", port: 80, policy: .http1OnlyUpgrade),
                forceFresh: false, responseSink: sink)
            let channel = try fixture.connect(0)
            let oldSink = try #require(channel.pipeline.syncOperations.handler(type: UpstreamResponseHandler.self).sink)
            let lease = try #require(try resolvedLease(request) as? HTTP1UpstreamLease)
            #expect(lease.detachForUpgrade() === channel)
            #expect(lease.detachForUpgrade() == nil)
            lease.cancel(error: ChannelError.eof)
            oldSink.receiveResponse(.head(HTTPResponseHead(version: .http1_1, status: .ok)))
            oldSink.upstreamClosed(error: ChannelError.eof)
            oldSink.upstreamWritabilityChanged(false)
            #expect(channel.isActive)
            let next = context.upstreamPool.acquire(route: fixture.route, forceFresh: false, responseSink: PoolSink())
            #expect(fixture.connections.count == 2)
            context.close(error: nil)
            #expect(channel.isActive)
            _ = try fixture.connect(1)
            #expect(sink.closes == 0)
            #expect(sink.reads == 0)
            #expect(sink.writabilityChanges == 0)
            next.cancel()
        }
    }
}

final class PoolSink: UpstreamResponseSink {
    var closes = 0
    var reads = 0
    var writabilityChanges = 0
    func receiveResponse(_ part: HTTPClientResponsePart) { reads += 1 }
    func upstreamWritabilityChanged(_ writable: Bool) { writabilityChanges += 1 }
    func upstreamClosed(error: Error?) { closes += 1 }
}

final class ConnectionFixture {
    let loop = EmbeddedEventLoop()
    let client: EmbeddedChannel
    var environment: ProxyEnvironment
    let store: FlowStore
    var connections: [EventLoopPromise<Channel>] = []
    var channels: [EmbeddedChannel] = []
    var contexts: [ClientConnectionContext] = []
    let route = UpstreamRoute(scheme: "http", host: "example.test", port: 80, policy: .automatic)
    /// Where every upstream connection of this fixture must go, and where they actually went.
    var expectedEndpoint = (host: "example.test", port: 80)
    var connectedEndpoints: [String] = []
    init(directory: URL, threadPool: NIOThreadPool) throws {
        client = EmbeddedChannel(loop: loop)
        try client.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 12345)).wait()
        store = FlowStore(bodyDirectory: directory)
        var configuration = ProxyConfiguration()
        configuration.connectTimeout = .seconds(1)
        environment = ProxyEnvironment(
            configuration: configuration, recording: FlowRecording(store: store, isEnabled: ManagedAtomic(true)),
            tls: TLSInterception(certificateAuthority: try CertificateAuthority.generate()),
            passthrough: PassthroughRegistry(),
            clientLookup: ClientLookupBatcher(processLookup: ProcessLookup(lookup: { _, _ in nil }), threadPool: threadPool), fileIOPool: threadPool)
    }
    func context(limits: HTTPTransportLimits = .init(), lookup: EventLoopFuture<ClientApp?>? = nil,
                 run: ProxyRunConnections? = nil, rules: RuleSnapshotProvider? = nil, breakpoints: BreakpointCoordinator? = nil,
                 traffic: TrafficPolicyProvider? = nil) -> ClientConnectionContext {
        var environment = self.environment
        environment.runConnections = run
        environment.rules = rules
        environment.traffic = traffic
        environment.breakpoints = breakpoints
        if let run { #expect(run.accept(client)) }
        let result = ClientConnectionContext(channel: client, environment: environment,
            clientLookup: lookup ?? loop.makeSucceededFuture(nil), limits: limits, connectionFactory: { [self] host, port, loop in
                #expect(host == expectedEndpoint.host)
                #expect(port == expectedEndpoint.port)
                connectedEndpoints.append("\(host):\(port)")
                let promise = loop.makePromise(of: Channel.self)
                connections.append(promise)
                return promise.futureResult
            })
        contexts.append(result)
        return result
    }
    func connect(_ index: Int) throws -> EmbeddedChannel {
        let channel = EmbeddedChannel(loop: loop)
        try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 12346)).wait()
        channels.append(channel)
        connections[index].succeed(channel)
        loop.run()
        return channel
    }
    func cleanup() {
        contexts.forEach { $0.close(error: nil) }
        _ = try? client.finish()
        channels.forEach { _ = try? $0.finish() }
        loop.run()
    }
}

func withConnectionFixture(_ body: (ConnectionFixture) throws -> Void) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let pool = NIOThreadPool(numberOfThreads: 1)
    pool.start()
    do {
        let fixture = try ConnectionFixture(directory: directory, threadPool: pool)
        defer { fixture.cleanup() }
        try body(fixture)
    } catch {
        try await pool.shutdownGracefully()
        throw error
    }
    try await pool.shutdownGracefully()
}

/// Never blocks an EmbeddedEventLoop: an unmet ordering assertion fails instead of hanging.
func resolvedLease(_ acquisition: UpstreamAcquisition) throws -> UpstreamLease {
    var result: Result<UpstreamLease, Error>?
    acquisition.futureResult.assumeIsolated().whenComplete { result = $0 }
    return try #require(result).get()
}
