import FlowStore
import Foundation
import Localization
import NIOCore
import NIOHTTP2

/// Original-socket ownership, independent of HTTP codec/CONNECT handler replacement.
/// Every operation and isolated future callback executes on `channel.eventLoop`.
final class ClientConnectionContext: HTTPOutboundEnvironment {
    let contextID = UUID()
    let channel: Channel
    let environment: ProxyEnvironment
    let clientLookup: EventLoopFuture<ClientApp?>
    let limits: HTTPTransportLimits
    let upstreamPool: UpstreamSessionPool
    private(set) var knownClient: ClientApp?
    private(set) var lookupDone = false
    /// Set once by the TLS handshake monitor when this socket is intercepted.
    private(set) var downstreamTLSVersion: String?
    private(set) var forwardingAllowed = false
    private var lookupWaiters: [(ClientApp) -> Void] = []
    private var forwardingWaiters: [() -> Void] = []
    private var grace: Scheduled<Void>?
    private var exchanges: [ObjectIdentifier: HTTPExchange] = [:]
    private var closed = false
    private var pendingBytes = 0
    private var draining = false
    private var localOperations = 0
    private var lastDownstreamStreamID = 0
    private var detachedTransports: [ObjectIdentifier: Channel] = [:]
    private var transportWork = 0
    private var socketClosed = false
    private var poolClosed = false
    private var cleanupCompleted = false
    private let cleanup: EventLoopPromise<Void>
    /// The socket's upload gate, found once (it stays in the pipeline for the socket's lifetime).
    private lazy var pacer: ConnectionPacer? = environment.traffic == nil ? nil
        : try? channel.pipeline.syncOperations.handler(type: ConnectionPacer.self)
    var clientIP: String? { ConnectionInfoReader.peerIP(of: channel) }
    func setDownstreamTLSVersion(_ version: String?) { downstreamTLSVersion = version }
    var cleanupFuture: EventLoopFuture<Void> { cleanup.futureResult }
    var permitsExchange: Bool { !closed && !draining && environment.runConnections?.permitsExchange != false }

    var snapshot: ClientConnectionSnapshot {
        channel.eventLoop.preconditionInEventLoop()
        return .init(pendingBytes: pendingBytes, lookupTimers: grace == nil ? 0 : 1,
            exchanges: exchanges.values.map(\.snapshot))
    }

    init(channel: Channel, environment: ProxyEnvironment, clientLookup: EventLoopFuture<ClientApp?>,
         limits: HTTPTransportLimits = .init(), connectionFactory: UpstreamConnectionFactory? = nil,
         streamCreationGate: ((Channel) -> EventLoopFuture<Void>)? = nil) {
        self.cleanup = channel.eventLoop.makePromise()
        self.channel = channel
        self.environment = environment
        self.clientLookup = clientLookup
        self.limits = limits
        self.upstreamPool = UpstreamSessionPool(eventLoop: channel.eventLoop, environment: environment, limits: limits,
                                                connectionFactory: connectionFactory, streamCreationGate: streamCreationGate)
        grace = channel.eventLoop.assumeIsolated().scheduleTask(in: ProxyHandler.clientLookupGrace) { [weak self] in
            self?.allowForwarding()
        }
        // Lookup may finish after capture or the socket. Preserve that final identity update,
        // while allowForwarding independently refuses to revive a closed connection.
        clientLookup.assumeIsolated().whenComplete { [self] result in
            self.lookupDone = true
            if case .success(let app) = result { self.knownClient = app }
            if let app = self.knownClient { self.lookupWaiters.forEach { $0(app) } }
            self.lookupWaiters.removeAll()
            self.allowForwarding()
        }
        // Retain context through the actual socket lifetime, including CONNECT handoff gaps.
        channel.closeFuture.assumeIsolated().whenComplete { [self] _ in
            close(error: nil)
            socketClosed = true
            upstreamPool.shutdown(error: nil).assumeIsolated().whenComplete { [self] _ in
                poolClosed = true
                finishCleanup()
            }
            finishCleanup()
        }
        environment.runConnections?.attach(self)
    }

    func onClient(_ callback: @escaping (ClientApp) -> Void) {
        if let knownClient { callback(knownClient) }
        else if !lookupDone, !closed { lookupWaiters.append(callback) }
    }
    func whenForwardingAllowed(_ callback: @escaping () -> Void) {
        if forwardingAllowed { callback() }
        else if !closed { forwardingWaiters.append(callback) }
    }
    private func allowForwarding() {
        guard !closed, !forwardingAllowed else { return }
        forwardingAllowed = true
        grace?.cancel()
        grace = nil
        let waiters = forwardingWaiters
        forwardingWaiters.removeAll()
        waiters.forEach { $0() }
    }
    func register(_ exchange: HTTPExchange, streamID: Int? = nil) -> Bool {
        guard permitsExchange else { return false }
        if let streamID { lastDownstreamStreamID = max(lastDownstreamStreamID, streamID) }
        exchanges[ObjectIdentifier(exchange)] = exchange
        return true
    }
    func unregister(_ exchange: HTTPExchange) {
        exchanges.removeValue(forKey: ObjectIdentifier(exchange))
        closeIfDrained()
    }
    func admitLocalOperation() -> Bool {
        guard permitsExchange else { return false }
        localOperations += 1
        return true
    }
    func finishLocalOperation() {
        localOperations -= 1
        closeIfDrained()
    }
    func beginDrain() {
        guard !draining, !closed else { return }
        draining = true
        if (try? channel.pipeline.syncOperations.handler(type: HTTP2StreamMultiplexer.self)) != nil {
            channel.writeAndFlush(HTTP2Frame(streamID: .rootStream, payload: .goAway(
                lastStreamID: HTTP2StreamID(lastDownstreamStreamID), errorCode: .noError, opaqueData: nil)), promise: nil)
        }
        closeIfDrained()
    }
    private func closeIfDrained() {
        guard draining, exchanges.isEmpty, localOperations == 0, detachedTransports.isEmpty, transportWork == 0 else { return }
        // Defer past the exchange's final write/finish stack (including H1 Upgrade handoff).
        let owner = NIOLoopBound(self, eventLoop: channel.eventLoop)
        channel.eventLoop.execute {
            let context = owner.value
            guard context.exchanges.isEmpty, context.localOperations == 0,
                  context.detachedTransports.isEmpty, context.transportWork == 0 else { return }
            context.channel.close(promise: nil)
        }
    }
    /// Raw CONNECT/Upgrade transports use this same original-socket owner, outside its pool.
    func retainTransport(_ transport: Channel) {
        let key = ObjectIdentifier(transport)
        guard detachedTransports[key] == nil else { return }
        detachedTransports[key] = transport
        transport.closeFuture.assumeIsolated().whenComplete { [self] _ in
            detachedTransports.removeValue(forKey: key)
            closeIfDrained()
            finishCleanup()
        }
        if closed { transport.close(promise: nil) }
    }
    func retainTransportWork(_ future: EventLoopFuture<Channel>) -> EventLoopFuture<Channel> {
        transportWork += 1
        future.assumeIsolated().whenComplete { [self] result in
            if case .success(let transport) = result { retainTransport(transport) }
            transportWork -= 1
            closeIfDrained()
            finishCleanup()
        }
        return future
    }
    private func finishCleanup() {
        guard socketClosed, poolClosed, transportWork == 0, detachedTransports.isEmpty, !cleanupCompleted else { return }
        cleanupCompleted = true
        cleanup.succeed(())
    }
    func forceClose() {
        close(error: HTTPTransportError.cancelled)
        channel.close(promise: nil)
    }
    func bindShaping(host: String, port: Int) {
        channel.eventLoop.preconditionInEventLoop()
        pacer?.bind(host: host, port: port)
    }
    func reservePendingBytes(_ count: Int) -> Bool {
        guard count <= limits.pendingBytesPerContext - pendingBytes else { return false }
        pendingBytes += count
        return true
    }
    func releasePendingBytes(_ count: Int) { pendingBytes -= count; assert(pendingBytes >= 0) }
    func close(error: Error?) {
        guard !closed else { return }
        closed = true
        grace?.cancel()
        grace = nil
        forwardingWaiters.removeAll()
        let active = Array(exchanges.values)
        active.forEach { $0.cancel(reason: L10n.string("proxyFailure.clientDisconnected")) }
        upstreamPool.shutdown(error: error)
        Array(detachedTransports.values).forEach { $0.close(promise: nil) }
    }
}
