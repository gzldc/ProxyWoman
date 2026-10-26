import Atomics
import CertKit
import FlowStore
import Foundation
import NIOCore
import NIOHTTP1
import NIOHTTP2
import NIOPosix
import NIOSSL
import os
@testable import ProxyCore
import RulesEngine

/// Independent proxy and origin roots; the system keychain is never consulted or mutated.
final class HTTP2ProxyFixture: Sendable {
    let channel: Channel
    let store: FlowStore
    let ca: CertificateAuthority
    let directory: URL
    let recording: FlowRecording
    let upstreams: OSAllocatedUnfairLock<[Channel]>
    let lookups: OSAllocatedUnfairLock<Int>
    let connections: OSAllocatedUnfairLock<[NIOLoopBound<ClientConnectionContext>]>
    private let group: MultiThreadedEventLoopGroup
    private let workers: NIOThreadPool
    let bodyRuntime: BreakpointBodyRuntime

    private init(channel: Channel, store: FlowStore, ca: CertificateAuthority, directory: URL,
                 recording: FlowRecording, upstreams: OSAllocatedUnfairLock<[Channel]>,
                 lookups: OSAllocatedUnfairLock<Int>, connections: OSAllocatedUnfairLock<[NIOLoopBound<ClientConnectionContext>]>, group: MultiThreadedEventLoopGroup, workers: NIOThreadPool, bodyRuntime: BreakpointBodyRuntime) {
        self.channel = channel; self.store = store; self.ca = ca; self.directory = directory
        self.recording = recording; self.upstreams = upstreams; self.lookups = lookups
        self.connections = connections
        self.group = group; self.workers = workers; self.bodyRuntime = bodyRuntime
    }
    static func start(origin: HTTP2TestOrigin, limits: HTTPTransportLimits = .init(), maxFlows: Int = 1000,
                      streamCreationGate: (@Sendable (Channel) -> EventLoopFuture<Void>)? = nil,
                      connectTimeout: TimeAmount = .seconds(3), runConnections: ProxyRunConnections? = nil,
                      rules: RuleSnapshotProvider? = nil, assets: ManagedAssetStore? = nil, breakpoints: BreakpointCoordinator? = nil,
                      localResponseHooks: LocalResponseSource.Hooks? = nil, bodyHooks: BodyFileIOHooks = .init(), trustedOrigins: [CertificateAuthority]? = nil,
                      traffic: TrafficPolicyProvider? = nil, ruleDelayHook: RuleDelayHook? = nil) async throws -> HTTP2ProxyFixture {
        let ca = try CertificateAuthority.generate(commonName: "Proxy fixture CA")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = FlowStore(bodyDirectory: directory, maxFlows: maxFlows)
        var config = ProxyConfiguration()
        config.port = 0
        config.connectTimeout = connectTimeout
        config.upstreamTrustRoots = .certificates(try (trustedOrigins ?? [origin.ca]).map {
            try NIOSSLCertificate(bytes: $0.rootCertificateDER, format: .der)
        })
        let lookups = OSAllocatedUnfairLock(initialState: 0)
        let upstreams = OSAllocatedUnfairLock(initialState: [Channel]())
        let connections = OSAllocatedUnfairLock(initialState: [NIOLoopBound<ClientConnectionContext>]())
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let workers = NIOThreadPool(numberOfThreads: 1)
        workers.start()
        let bodyLimits = breakpoints?.limits ?? RulesLimits()
        let bodyRuntime = BreakpointBodyRuntime(budgets: assets?.bodyBudgets ?? OwnedFileBudgets(limits: bodyLimits), limits: bodyLimits, hooks: bodyHooks)
        let recording = FlowRecording(store: store, isEnabled: ManagedAtomic(true))
        let environment = ProxyEnvironment(configuration: config, recording: recording,
            tls: TLSInterception(certificateAuthority: ca), passthrough: PassthroughRegistry(),
            clientLookup: ClientLookupBatcher(processLookup: ProcessLookup(lookup: { _, _ in
                lookups.withLock { $0 += 1 }
                return ClientApp(pid: 42, name: "fixture")
            }), threadPool: workers), runConnections: runConnections, rules: rules, assets: assets, directories: assets?.directoryResolver(), breakpoints: breakpoints, localResponseHooks: localResponseHooks, ruleDelayHook: ruleDelayHook, fileIOPool: workers, bodyRuntime: bodyRuntime, traffic: traffic)
        do {
            let channel = try await ServerBootstrap(group: group).childChannelInitializer { child in
                if let runConnections, !runConnections.accept(child) { return child.close() }
                return child.eventLoop.makeCompletedFuture {
                    let lookup = environment.clientLookup.lookup(clientPort: child.remoteAddress!.port!, proxyPort: child.localAddress!.port!, on: child.eventLoop)
                    let connection = ClientConnectionContext(channel: child, environment: environment, clientLookup: lookup,
                        limits: limits, connectionFactory: { host, port, loop in
                            ClientBootstrap(group: loop).connect(host: host, port: port).map { upstream in
                                upstreams.withLock { $0.append(upstream) }
                                return upstream
                            }
                        }, streamCreationGate: streamCreationGate)
                    let owner = NIOLoopBound(connection, eventLoop: child.eventLoop)
                    connections.withLock { $0.append(owner) }
                    try child.pipeline.syncOperations.addHandlers([
                        TrafficCountingHandler(meter: TrafficMeter()),
                        HTTPMessageTranslation.responseEncoder(), HTTP1TransferCodingFramer<HTTPResponseHead>(),
                        ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes)),
                        ProxyHandler(mode: .forwardProxy, environment: environment, inheritedConnection: connection),
                    ])
                }
            }.bind(host: "127.0.0.1", port: 0).get()
            return .init(channel: channel, store: store, ca: ca, directory: directory, recording: recording,
                         upstreams: upstreams, lookups: lookups, connections: connections, group: group, workers: workers, bodyRuntime: bodyRuntime)
        } catch {
            try? await workers.shutdownGracefully(); try? await group.shutdownGracefully()
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
    func stop() async throws {
        try? await channel.close().get()
        for owner in connections.withLock({ $0 }) { try await owner.eventLoop.submit { owner.value.close(error: nil) }.get() }
        await bodyRuntime.drain()
        try await workers.shutdownGracefully()
        try await group.shutdownGracefully()
        try? FileManager.default.removeItem(at: directory)
    }
    static func withProxy(origin: HTTP2TestOrigin, downstreamH2: Bool, limits: HTTPTransportLimits = .init(),
                          maxFlows: Int = 1000, streamCreationGate: (@Sendable (Channel) -> EventLoopFuture<Void>)? = nil,
                          connectTimeout: TimeAmount = .seconds(3), clientLimits: HTTPTransportLimits = .init(),
                          rules: RuleSnapshotProvider? = nil, assets: ManagedAssetStore? = nil, breakpoints: BreakpointCoordinator? = nil,
                      localResponseHooks: LocalResponseSource.Hooks? = nil, bodyHooks: BodyFileIOHooks = .init(), trustedOrigins: [CertificateAuthority]? = nil,
                          traffic: TrafficPolicyProvider? = nil, ruleDelayHook: RuleDelayHook? = nil,
                          _ body: (HTTP2ProxyFixture, HTTP2TestClient) async throws -> Void) async throws {
        let fixture = try await start(origin: origin, limits: limits, maxFlows: maxFlows, streamCreationGate: streamCreationGate,
                                      connectTimeout: connectTimeout, rules: rules, assets: assets, breakpoints: breakpoints, localResponseHooks: localResponseHooks, bodyHooks: bodyHooks, trustedOrigins: trustedOrigins, traffic: traffic, ruleDelayHook: ruleDelayHook)
        var client: HTTP2TestClient?
        do {
            let connected = try await HTTP2TestClient.connect(origin: origin,
                tls: TLSInterception(certificateAuthority: fixture.ca, applicationProtocols: downstreamH2 ? ["h2", "http/1.1"] : ["http/1.1"]),
                roots: .certificates([try NIOSSLCertificate(bytes: fixture.ca.rootCertificateDER, format: .der)]),
                limits: clientLimits, proxyPort: fixture.channel.localAddress!.port!)
            client = connected
            try await body(fixture, connected)
            try await connected.stop()
            try await fixture.stop()
        } catch {
            if let client { try? await client.stop() }
            try? await fixture.stop()
            throw error
        }
    }
}

final class HTTP2ProxyConnectResponse: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    let promise: EventLoopPromise<Void>
    private var bytes = ""
    private var done = false
    init(promise: EventLoopPromise<Void>) { self.promise = promise }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        bytes += String(buffer: unwrapInboundIn(data))
        guard bytes.contains("\r\n\r\n"), !done else { return }
        done = true
        guard bytes.hasPrefix("HTTP/1.1 200 ") else { promise.fail(HTTPTransportError.closed); return }
        context.pipeline.syncOperations.removeHandler(self, promise: promise)
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        if !done { done = true; promise.fail(error) }
        context.close(promise: nil)
    }
    func channelInactive(context: ChannelHandlerContext) {
        if !done { done = true; promise.fail(HTTPTransportError.closed) }
        context.fireChannelInactive()
    }
}

/// Observes real peer control frames after the production observer has applied their state.
final class HTTP2FixtureControlBarrier: ChannelInboundHandler {
    typealias InboundIn = HTTP2Frame
    let promise: EventLoopPromise<Void>
    let maximum: Int?
    private var done = false
    init(promise: EventLoopPromise<Void>, maximum: Int?) { self.promise = promise; self.maximum = maximum }
    static func install(on channel: Channel, maximum: Int? = nil) async throws -> EventLoopFuture<Void> {
        try await channel.eventLoop.submit {
            let promise = channel.eventLoop.makePromise(of: Void.self)
            let observer = try channel.pipeline.syncOperations.handler(type: HTTP2ConnectionObserver.self)
            try channel.pipeline.syncOperations.addHandler(HTTP2FixtureControlBarrier(promise: promise, maximum: maximum), position: .before(observer))
            return promise.futureResult
        }.get()
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        var matched = false
        switch frame.payload {
        case .goAway: matched = maximum == nil
        case .settings(.settings(let settings)):
            matched = settings.contains { $0.parameter == .maxConcurrentStreams && $0.value == maximum }
        default: break
        }
        context.fireChannelRead(data)
        if matched, !done { done = true; promise.succeed(()) }
    }
    func channelInactive(context: ChannelHandlerContext) {
        if !done { done = true; promise.fail(HTTPTransportError.closed) }
        context.fireChannelInactive()
    }
}
