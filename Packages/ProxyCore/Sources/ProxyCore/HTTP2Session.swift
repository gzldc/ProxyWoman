import FlowStore
import NIOCore
import NIOHTTP1
import NIOHTTP2

/// Read on the owning event loop. Stream IDs remain nil until NIO assigns them on first flush.
protocol HTTP2UpstreamLease: UpstreamLease {
    var responseHeaders: HTTP2StreamHeaders? { get }
    var streamID: HTTP2StreamID? { get }
    var queuedBodyBytes: Int { get }
    var reading: Bool { get }
}

/// One route on one accepted client's event loop. Stream reservations are charged before child
/// creation, released once, and never imply a replay/retry. The pool owns route selection.
final class HTTP2Session {
    let channel: Channel
    let route: UpstreamRoute
    private let limits: HTTPTransportLimits
    private let multiplexer: HTTP2StreamMultiplexer
    private let streamCreationGate: ((Channel) -> EventLoopFuture<Void>)?
    private var creatingStreams = 0
    var stateChanged: (() -> Void)?
    private var peerMaximum = Int.max
    private var reservations = 0
    private var streamCreations = 0
    private var leases: [ObjectIdentifier: Lease] = [:]
    private var used = false
    private var closed = false
    private(set) var isDraining = false
    private(set) var goAwayLastStreamID: HTTP2StreamID?
    private var idleTimer: Scheduled<Void>?
    private var drainTimer: Scheduled<Void>?
    var availableStreams: Int {
        channel.eventLoop.preconditionInEventLoop()
        return closed || isDraining ? 0 : max(0, min(limits.upstreamStreams, peerMaximum) - reservations)
    }

    var snapshot: HTTP2SessionSnapshot {
        channel.eventLoop.preconditionInEventLoop()
        return .init(reservedStreams: reservations, creatingStreams: creatingStreams,
            activeStreams: leases.values.filter { !$0.reservation.creating }.count, streamCreations: streamCreations,
            idleTimers: idleTimer == nil ? 0 : 1, drainTimers: drainTimer == nil ? 0 : 1)
    }

    init(channel: Channel, route: UpstreamRoute, limits: HTTPTransportLimits, multiplexer: HTTP2StreamMultiplexer,
         streamCreationGate: ((Channel) -> EventLoopFuture<Void>)? = nil) {
        self.channel = channel; self.route = route; self.limits = limits; self.multiplexer = multiplexer
        self.streamCreationGate = streamCreationGate
    }

    func openStream(responseSink: UpstreamResponseSink) -> EventLoopFuture<UpstreamLease> {
        channel.eventLoop.preconditionInEventLoop()
        guard !closed, channel.isActive else { return channel.eventLoop.makeFailedFuture(HTTPTransportError.closed) }
        guard !isDraining else { return channel.eventLoop.makeFailedFuture(HTTP2TransportError.draining) }
        guard availableStreams > 0 else { return channel.eventLoop.makeFailedFuture(HTTPTransportError.capacityExceeded) }
        reservations += 1
        creatingStreams += 1
        streamCreations += 1
        if streamCreations == limits.upstreamStreamCreationsPerSession { beginDraining() }
        idleTimer?.cancel(); idleTimer = nil
        let reservation = Reservation()
        let held = NIOLoopBound(reservation, eventLoop: channel.eventLoop)
        let promise = channel.eventLoop.makePromise(of: UpstreamLease.self)
        let owner = NIOLoopBound(self, eventLoop: channel.eventLoop)
        let sink = NIOLoopBound(responseSink, eventLoop: channel.eventLoop)
        let reused = used
        used = true
        multiplexer.createStreamChannel { child in
            child.eventLoop.makeCompletedFuture {
                let session = owner.value
                guard !session.closed else { throw HTTPTransportError.closed }
                let metadata = HTTP2StreamMetadataHandler(role: .response, limits: session.limits)
                let lease = Lease(session: session, channel: child, sink: sink.value, wasReused: reused, metadata: metadata, reservation: held.value)
                try child.pipeline.syncOperations.addHandlers([
                    metadata,
                    HTTP2FramePayloadToHTTP1ClientCodec(httpProtocol: session.route.scheme == "https" ? .https : .http),
                    lease,
                ])
                held.value.lease = lease
                session.leases[ObjectIdentifier(child)] = lease
            }.assumeIsolated().flatMap {
                owner.value.streamCreationGate?(child) ?? child.eventLoop.makeSucceededVoidFuture()
            }.nonisolated()
        }.assumeIsolated().whenComplete { [self] result in
            creatingStreams -= 1
            reservation.creating = false
            switch result {
            case .failure(let error):
                if let lease = reservation.lease { release(lease, error: error) }
                releaseReservation(reservation)
                promise.fail(error)
            case .success(let child):
                guard let lease = leases[ObjectIdentifier(child)], !closed, goAwayLastStreamID == nil else {
                    if let lease = leases[ObjectIdentifier(child)] { release(lease, error: HTTP2TransportError.draining) }
                    releaseReservation(reservation)
                    child.close(promise: nil)
                    promise.fail(closed ? HTTPTransportError.closed : HTTP2TransportError.draining)
                    return
                }
                promise.assumeIsolated().succeed(lease)
            }
        }
        return promise.futureResult
    }

    func receivedPeerSettings(_ settings: HTTP2Settings) {
        channel.eventLoop.preconditionInEventLoop()
        for setting in settings where setting.parameter == .maxConcurrentStreams { peerMaximum = setting.value }
        stateChanged?()
    }

    func receivedGoAway(lastStreamID: HTTP2StreamID, errorCode: HTTP2ErrorCode) {
        channel.eventLoop.preconditionInEventLoop()
        guard !closed else { return }
        let last = min(goAwayLastStreamID ?? lastStreamID, lastStreamID)
        goAwayLastStreamID = last
        beginDraining()
        for lease in Array(leases.values) {
            let streamID = try? lease.channel.syncOptions?.getOption(HTTP2StreamChannelOptions.streamID)
            if let streamID {
                if streamID > last {
                    release(lease, error: NIOHTTP2Errors.streamClosed(streamID: streamID, errorCode: errorCode))
                }
            } else {
                release(lease, error: HTTP2TransportError.draining)
            }
        }
        // Releasing the last rejected stream may have synchronously closed this session.
        guard !closed else { return }
        afterRelease()
    }

    private func beginDraining() {
        guard !isDraining else { return }
        isDraining = true
        idleTimer?.cancel(); idleTimer = nil
        drainTimer = channel.eventLoop.assumeIsolated().scheduleTask(in: limits.drainTimeout) { [weak self] in
            self?.close(error: HTTP2TransportError.draining)
        }
        stateChanged?()
    }

    func close(error: Error?) {
        channel.eventLoop.preconditionInEventLoop()
        guard !closed else { return }
        closed = true
        idleTimer?.cancel(); idleTimer = nil
        drainTimer?.cancel(); drainTimer = nil
        for lease in Array(leases.values) { release(lease, error: error ?? HTTPTransportError.closed) }
        channel.close(promise: nil)
        stateChanged?()
    }

    private func release(_ lease: Lease, error: Error?) {
        guard leases.removeValue(forKey: ObjectIdentifier(lease.channel)) != nil else { return }
        lease.finish(error: error)
        lease.channel.close(promise: nil)
        releaseReservation(lease.reservation)
    }
    // A child close can precede completion of its asynchronous initializer. Keep that
    // reservation until NIO settles, then release once even when both paths report failure.
    private final class Reservation {
        var creating = true
        var released = false
        weak var lease: Lease?
    }
    private func releaseReservation(_ reservation: Reservation) {
        guard !reservation.creating, !reservation.released else { return }
        reservation.released = true
        reservations -= 1
        afterRelease()
    }
    private func afterRelease() {
        stateChanged?()
        guard !closed, reservations == 0 else { return }
        if isDraining { close(error: nil) }
        else {
            idleTimer?.cancel()
            idleTimer = channel.eventLoop.assumeIsolated().scheduleTask(in: limits.idleTimeout) { [weak self] in
                self?.close(error: nil)
            }
        }
    }

    private final class Lease: ChannelInboundHandler, HTTP2UpstreamLease {
        typealias InboundIn = HTTPClientResponsePart
        let channel: Channel
        let version: HTTPWireVersion = .http2
        let wasReused: Bool
        let metadata: HTTP2StreamMetadataHandler
        let reservation: Reservation
        private weak var session: HTTP2Session?
        private var sink: UpstreamResponseSink?
        private var responseEnded = false
        private var ended = false
        private(set) var reading = true
        private(set) var queuedBodyBytes = 0
        init(session: HTTP2Session, channel: Channel, sink: UpstreamResponseSink, wasReused: Bool,
             metadata: HTTP2StreamMetadataHandler, reservation: Reservation) {
            self.session = session; self.channel = channel; self.sink = sink
            self.wasReused = wasReused; self.metadata = metadata; self.reservation = reservation
        }
        var responseHeaders: HTTP2StreamHeaders? { metadata.currentHeaders }
        var streamID: HTTP2StreamID? { try? channel.syncOptions?.getOption(HTTP2StreamChannelOptions.streamID) }
        var isWritable: Bool { !ended && channel.isWritable }
        func write(_ part: HTTPClientRequestPart) -> EventLoopFuture<Void> {
            guard !ended else { return channel.eventLoop.makeFailedFuture(HTTPTransportError.closed) }
            let count: Int
            if case .body(.byteBuffer(let bytes)) = part { count = bytes.readableBytes } else { count = 0 }
            queuedBodyBytes += count
            let result = channel.write(part)
            result.assumeIsolated().whenComplete { [self] _ in queuedBodyBytes -= count }
            return result
        }
        func flush() { if !ended { channel.flush() } }
        func setResponseReading(_ enabled: Bool) {
            guard !ended, reading != enabled else { return }
            reading = enabled
            channel.setAutoRead(enabled)
            if enabled { channel.read() }
        }
        func release(reusable: Bool) { session?.release(self, error: nil) }
        func cancel(error: Error?) { session?.release(self, error: error ?? HTTPTransportError.cancelled) }
        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            guard !ended else { return }
            var part = unwrapInboundIn(data)
            if case .head(var head) = part {
                // Restore original fields before capture/translation. NIO validates original
                // Content-Length against DATA upstream; the codec may synthesize h1 framing.
                head.version = .http2
                if let original = metadata.currentHeaders { head.headers = original.regularHeaders }
                part = .head(head)
            }
            if case .end = part { responseEnded = true }
            sink?.responseReadStarted()
            sink?.receiveResponse(part)
        }
        func channelReadComplete(context: ChannelHandlerContext) {
            sink?.responseReadComplete()
            context.fireChannelReadComplete()
        }
        func channelWritabilityChanged(context: ChannelHandlerContext) {
            sink?.upstreamWritabilityChanged(isWritable)
            context.fireChannelWritabilityChanged()
        }
        func errorCaught(context: ChannelHandlerContext, error: Error) { session?.release(self, error: error) }
        func channelInactive(context: ChannelHandlerContext) {
            session?.release(self, error: responseEnded ? nil : HTTPTransportError.closed)
            context.fireChannelInactive()
        }
        fileprivate func finish(error: Error?) {
            guard !ended else { return }; ended = true
            let sink = sink
            self.sink = nil; session = nil
            if let error, !responseEnded { sink?.upstreamClosed(error: error) }
        }
    }
}
