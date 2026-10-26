import NIOCore

/// Cancellation and completion are serialized on the context event loop.
final class UpstreamAcquisition {
    let futureResult: EventLoopFuture<UpstreamLease>
    fileprivate let promise: EventLoopPromise<UpstreamLease>
    fileprivate let route: UpstreamRoute
    fileprivate let forceFresh: Bool
    fileprivate let sink: UpstreamResponseSink
    fileprivate var deadline: Scheduled<Void>?
    fileprivate var settled = false
    private weak var pool: UpstreamSessionPool?

    fileprivate init(pool: UpstreamSessionPool, route: UpstreamRoute, forceFresh: Bool,
                     sink: UpstreamResponseSink, loop: EventLoop) {
        self.pool = pool
        self.route = route
        self.forceFresh = forceFresh
        self.sink = sink
        promise = loop.makePromise(of: UpstreamLease.self)
        futureResult = promise.futureResult
    }
    func cancel() { pool?.cancel(self, error: HTTPTransportError.cancelled) }
    fileprivate func fail(_ error: Error) {
        guard !settled else { return }
        settled = true
        deadline?.cancel()
        deadline = nil
        promise.fail(error)
    }
    fileprivate func succeed(_ lease: UpstreamLease) {
        guard !settled else { lease.release(reusable: false); return }
        settled = true
        deadline?.cancel()
        deadline = nil
        promise.assumeIsolated().succeed(lease)
    }
}

/// Per-client route pool; socket reservations survive negotiation and draining until closeFuture.
final class UpstreamSessionPool {
    private let eventLoop: EventLoop
    private let environment: ProxyEnvironment
    private let limits: HTTPTransportLimits
    private let connector: UpstreamConnector
    private let connectionFactory: UpstreamConnectionFactory?
    private let streamCreationGate: ((Channel) -> EventLoopFuture<Void>)?
    private var waiting: [UpstreamAcquisition] = []
    private var connecting: [ObjectIdentifier: UpstreamAcquisition] = [:]
    private enum ConfiguredSession {
        case http1(HTTP1UpstreamSession), http2(HTTP2Session)
    }
    private var configured: [ObjectIdentifier: ConfiguredSession] = [:]
    private var sessions: [ObjectIdentifier: HTTP1UpstreamSession] = [:]
    private var http2: [ObjectIdentifier: HTTP2Session] = [:]
    private var connectingChannels: [ObjectIdentifier: Channel] = [:]
    private var opening: [ObjectIdentifier: UpstreamAcquisition] = [:]
    /// Connects still in flight (before `connected`), so a cancelled acquisition closes its socket.
    private var attempts: [ObjectIdentifier: UpstreamConnectAttempt] = [:]
    private var knownHTTP1: Set<UpstreamRoute> = []
    private var closed = false
    private var pumping = false
    private var connectionSetups: Set<ObjectIdentifier> = []
    private let cleanup: EventLoopPromise<Void>
    private var cleanupCompleted = false

    init(eventLoop: EventLoop, environment: ProxyEnvironment, limits: HTTPTransportLimits,
         connectionFactory: UpstreamConnectionFactory? = nil,
         streamCreationGate: ((Channel) -> EventLoopFuture<Void>)? = nil) {
        self.cleanup = eventLoop.makePromise()
        self.eventLoop = eventLoop
        self.environment = environment
        self.limits = limits
        self.connector = UpstreamConnector(configuration: environment.configuration, traffic: environment.traffic)
        self.connectionFactory = connectionFactory
        self.streamCreationGate = streamCreationGate
    }

    var snapshot: UpstreamPoolSnapshot {
        eventLoop.preconditionInEventLoop()
        let acquisitions = waiting + Array(connecting.values) + Array(opening.values)
        return .init(waiting: waiting.count, connecting: connecting.count, opening: opening.count,
            pending: acquisitions.filter { !$0.settled }.count,
            acquisitionTimers: acquisitions.filter { $0.deadline != nil }.count,
            socketReservations: sessions.count + http2.count + connecting.count,
            physicalSockets: sessions.count + http2.count + connectingChannels.count,
            sessions: http2.values.map(\.snapshot))
    }

    func acquire(route: UpstreamRoute, forceFresh: Bool, responseSink: UpstreamResponseSink) -> UpstreamAcquisition {
        let result = UpstreamAcquisition(pool: self, route: route, forceFresh: forceFresh,
                                         sink: responseSink, loop: eventLoop)
        guard !closed else { result.fail(HTTPTransportError.closed); return result }
        guard waiting.count + opening.values.filter({ !$0.settled }).count + connecting.values.filter({ !$0.settled }).count < limits.pendingAcquisitions else {
            result.fail(HTTPTransportError.capacityExceeded)
            return result
        }
        result.deadline = eventLoop.assumeIsolated().scheduleTask(in: environment.configuration.connectTimeout) {
            [weak self, weak result] in
            if let self, let result {
                let negotiatingTLS = result.route.scheme == "https" && self.connectingChannels[ObjectIdentifier(result)] != nil
                self.cancel(result, error: negotiatingTLS ? TLSHandshakeTimeout() : HTTPTransportError.acquisitionTimedOut)
            }
        }
        waiting.append(result)
        pump()
        return result
    }

    fileprivate func cancel(_ acquisition: UpstreamAcquisition, error: Error) {
        guard !acquisition.settled else { return }
        waiting.removeAll { $0 === acquisition }
        acquisition.fail(error)
        attempts.removeValue(forKey: ObjectIdentifier(acquisition))?.cancel()
        connectingChannels[ObjectIdentifier(acquisition)]?.close(promise: nil)
        // A connecting transport still owns its reservation until the actual socket closes.
        pump()
    }

    private func pump() {
        checkCleanup()
        guard !closed, !pumping else { return }
        pumping = true
        defer { pumping = false }
        var index = 0
        while index < waiting.count {
            let acquisition = waiting[index]
            // Offline fails locally even when an idle or shared session to the route exists: a request
            // must never reach a host the conditions cut off (the same error a new connect gets).
            if connector.isOffline(host: acquisition.route.host, port: acquisition.route.port) {
                waiting.remove(at: index)
                acquisition.fail(NetworkConditionError.offline)
                continue
            }
            if !acquisition.forceFresh,
               let shared = http2.values.first(where: { $0.route == acquisition.route && $0.availableStreams > 0 }) {
                waiting.remove(at: index)
                open(acquisition, on: shared)
                continue
            }
            if !acquisition.forceFresh,
               let idle = sessions.values.first(where: { $0.route == acquisition.route && $0.available }) {
                waiting.remove(at: index)
                acquisition.succeed(idle.lease(sink: acquisition.sink))
                continue
            }
            let routeCount = sessions.values.filter { $0.route == acquisition.route }.count
                + connecting.values.filter { $0.route == acquisition.route }.count
                + http2.values.filter { $0.route == acquisition.route && !$0.isDraining }.count
            let routeLimit = knownHTTP1.contains(acquisition.route) ? limits.http1SocketsPerRoute : 1
            if routeCount >= routeLimit {
                // Force-fresh must also replace a same-route idle socket when only the route
                // limit is full. Its reservation stays owned until closeFuture completes.
                if let idle = sessions.values.first(where: { $0.route == acquisition.route && $0.available }) {
                    idle.close(error: nil)
                }
            } else if sessions.count + http2.count + connecting.count >= limits.totalUpstreamSockets {
                if let idle = sessions.values.first(where: { $0.available }) { idle.close(error: nil) }
            }
            guard routeCount < routeLimit, sessions.count + http2.count + connecting.count < limits.totalUpstreamSockets else {
                index += 1
                continue
            }
            waiting.remove(at: index)
            connecting[ObjectIdentifier(acquisition)] = acquisition // reserve BEFORE asynchronous connect
            connectionSetups.insert(ObjectIdentifier(acquisition))
            let future: EventLoopFuture<Channel>
            if let connectionFactory {
                future = connectionFactory(acquisition.route.host, acquisition.route.port, eventLoop)
            } else {
                let attempt = UpstreamConnectAttempt()
                attempts[ObjectIdentifier(acquisition)] = attempt
                future = connector.connect(host: acquisition.route.host, port: acquisition.route.port, on: eventLoop, attempt: attempt)
            }
            future.assumeIsolated().whenComplete { [self] result in connected(result, acquisition: acquisition) }
        }
    }

    private func open(_ acquisition: UpstreamAcquisition, on session: HTTP2Session) {
        opening[ObjectIdentifier(acquisition)] = acquisition
        session.openStream(responseSink: acquisition.sink).assumeIsolated().whenComplete { [self] result in
            opening.removeValue(forKey: ObjectIdentifier(acquisition))
            switch result {
            case .success(let lease): acquisition.succeed(lease)
            case .failure(let error): acquisition.fail(error)
            }
            pump()
        }
    }

    private func connected(_ result: Result<Channel, Error>, acquisition: UpstreamAcquisition) {
        let key = ObjectIdentifier(acquisition)
        attempts.removeValue(forKey: key)
        switch result {
        case .failure(let error):
            connectionSetups.remove(ObjectIdentifier(acquisition))
            connecting.removeValue(forKey: key)
            acquisition.fail(error)
            pump()
        case .success(let upstream):
            connectingChannels[key] = upstream
            upstream.closeFuture.assumeIsolated().whenComplete { [self] _ in
                connectingChannels.removeValue(forKey: key)
                configured.removeValue(forKey: key)
                if connecting.removeValue(forKey: key) != nil { acquisition.fail(HTTPTransportError.closed) }
                pump()
            }
            guard !closed, !acquisition.settled else {
                connectionSetups.remove(ObjectIdentifier(acquisition))
                upstream.close(promise: nil)
                checkCleanup()
                return
            }
            // Whatever address the resolver chose: never TLS or request bytes to our own listener.
            // Through an upstream proxy only the literal check before acquisition applies.
            if acquisition.route.rejectsListener, !connector.isTunneled(acquisition.route.host),
               environment.listeners?.isListener(remote: upstream.remoteAddress, local: upstream.localAddress) == true {
                connectionSetups.remove(ObjectIdentifier(acquisition))
                acquisition.fail(ProxySelfTargetError(
                    authority: UpstreamConnector.authority(host: acquisition.route.host, port: acquisition.route.port)))
                upstream.close(promise: nil)
                checkCleanup()
                return
            }
            if acquisition.route.scheme != "https" {
                configure(.http1, channel: upstream, acquisition: acquisition)
                    .assumeIsolated().whenComplete { [self] result in ready(result, acquisition: acquisition, channel: upstream) }
                return
            }
            let owner = NIOLoopBound(self, eventLoop: upstream.eventLoop)
            let pending = NIOLoopBound(acquisition, eventLoop: upstream.eventLoop)
            // Install negotiation before TLS can produce a synchronous handshake event. The
            // bootstrap already connected this raw socket; readiness includes selected setup.
            HTTP2Pipeline.installNegotiation(on: upstream) { selected, channel in
                owner.value.configure(selected, channel: channel, acquisition: pending.value)
            }.assumeIsolated().whenComplete { [self] installed in
                switch installed {
                case .failure(let error): ready(.failure(error), acquisition: acquisition, channel: upstream)
                case .success(let negotiation):
                    negotiation.readyProtocol.assumeIsolated().whenComplete { [self] result in
                        ready(result.map { _ in () }, acquisition: acquisition, channel: upstream)
                    }
                    do {
                        let tls = try environment.tls.upstreamHandler(host: acquisition.route.host,
                            trustRoots: environment.configuration.upstreamTrustRoots,
                            tunneled: connector.isTunneled(acquisition.route.host), policy: acquisition.route.policy)
                        try upstream.pipeline.syncOperations.addHandler(tls, position: .first)
                        // A download gate that ends a ragged TLS close closes the socket past the TLS layer.
                        if (try? upstream.pipeline.syncOperations.handler(type: ConnectionPacer.self)) != nil {
                            try upstream.pipeline.syncOperations.addHandler(UpstreamSocketCloser(), position: .first)
                        }
                    } catch { ready(.failure(error), acquisition: acquisition, channel: upstream) }
                }
            }
        }
    }

    private func configure(_ selected: NegotiatedHTTPProtocol, channel: Channel,
                           acquisition: UpstreamAcquisition) -> EventLoopFuture<Void> {
        guard !closed, !acquisition.settled else { return channel.eventLoop.makeFailedFuture(HTTPTransportError.cancelled) }
        if selected == .http2 {
            return HTTP2Pipeline.installClient(on: channel, route: acquisition.route, limits: limits, streamCreationGate: streamCreationGate)
                .assumeIsolated().map { [self] session in
                    guard !closed, channel.isActive else { session.close(error: HTTPTransportError.closed); return }
                    configured[ObjectIdentifier(acquisition)] = .http2(session)
                }.nonisolated()
        }
        return channel.eventLoop.makeCompletedFuture {
            let session = try HTTP1UpstreamSession(channel: channel, route: acquisition.route,
                idleTimeout: self.limits.idleTimeout, pool: self)
            self.configured[ObjectIdentifier(acquisition)] = .http1(session)
        }
    }

    private func ready(_ result: Result<Void, Error>, acquisition: UpstreamAcquisition, channel: Channel) {
        connectionSetups.remove(ObjectIdentifier(acquisition))
        defer { checkCleanup() }
        switch result {
        case .failure(let error):
            acquisition.fail(error)
            channel.close(promise: nil)
        case .success:
            guard !closed, !acquisition.settled else { channel.close(promise: nil); return }
            connecting.removeValue(forKey: ObjectIdentifier(acquisition))
            connectingChannels.removeValue(forKey: ObjectIdentifier(acquisition))
            switch configured.removeValue(forKey: ObjectIdentifier(acquisition)) {
            case .http2(let session):
                http2[ObjectIdentifier(channel)] = session
                session.stateChanged = { [weak self] in self?.pump() }
                channel.closeFuture.assumeIsolated().whenComplete { [self] _ in
                    http2.removeValue(forKey: ObjectIdentifier(channel))
                    pump()
                }
                open(acquisition, on: session)
            case .http1(let session):
                sessions[ObjectIdentifier(session)] = session
                knownHTTP1.insert(acquisition.route)
                acquisition.succeed(session.lease(sink: acquisition.sink))
            case .none: acquisition.fail(HTTPTransportError.closed)
            }
        }
        pump()
    }

    func sessionAvailable(_ session: HTTP1UpstreamSession) { pump() }
    func sessionClosed(_ session: HTTP1UpstreamSession) {
        sessions.removeValue(forKey: ObjectIdentifier(session))
        pump()
    }
    func detach(_ session: HTTP1UpstreamSession) { sessionClosed(session) }
    @discardableResult func shutdown(error: Error?) -> EventLoopFuture<Void> {
        guard !closed else { return cleanup.futureResult }
        closed = true
        let pending = waiting + Array(connecting.values) + Array(opening.values)
        waiting.removeAll()
        pending.forEach { $0.fail(error ?? HTTPTransportError.closed) }
        Array(sessions.values).forEach { $0.close(error: error) }
        Array(http2.values).forEach { $0.close(error: error) }
        Array(connectingChannels.values).forEach { $0.close(promise: nil) }
        let inFlight = Array(attempts.values)
        attempts.removeAll()
        inFlight.forEach { $0.cancel() }
        checkCleanup()
        return cleanup.futureResult
    }
    private func checkCleanup() {
        guard closed, !cleanupCompleted, connectionSetups.isEmpty, connecting.isEmpty,
              connectingChannels.isEmpty, opening.isEmpty, sessions.isEmpty, http2.isEmpty else { return }
        cleanupCompleted = true
        cleanup.succeed(())
    }
}
