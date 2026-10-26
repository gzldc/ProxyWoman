import FlowStore
import NIOCore
import NIOHTTP1

/// One exclusively leased HTTP/1 socket; all state is on the client event loop.
final class HTTP1UpstreamSession: UpstreamResponseSink {
    let channel: Channel
    let route: UpstreamRoute
    private let handler: UpstreamResponseHandler
    private weak var pool: UpstreamSessionPool?
    private let idleTimeout: TimeAmount
    private var idleTimer: Scheduled<Void>?
    private var activeLease: Lease?
    private var used = false
    private var closed = false
    private var detached = false
    var available: Bool { !closed && !detached && activeLease == nil && channel.isActive }

    init(channel: Channel, route: UpstreamRoute,
         idleTimeout: TimeAmount, pool: UpstreamSessionPool) throws {
        self.channel = channel
        self.route = route
        self.pool = pool
        self.idleTimeout = idleTimeout
        self.handler = UpstreamResponseHandler()
        handler.sink = self
        let pipeline = channel.pipeline.syncOperations
        try pipeline.addHandlers([
            HTTPMessageTranslation.requestEncoder(), HTTP1TransferCodingFramer<HTTPRequestHead>(),
            ByteToMessageHandler(HTTPResponseDecoder(leftOverBytesStrategy: .forwardBytes,
                                                      informationalResponseStrategy: .forward)), handler,
        ])
        channel.closeFuture.assumeIsolated().whenComplete { [weak self] _ in
            guard let self, !self.detached else { return }
            self.upstreamClosed(error: nil)
            self.pool?.sessionClosed(self)
        }
    }

    func lease(sink: UpstreamResponseSink) -> UpstreamLease {
        precondition(available)
        idleTimer?.cancel()
        idleTimer = nil
        let lease = Lease(session: self, sink: sink, wasReused: used)
        used = true
        activeLease = lease
        return lease
    }
    func receiveResponse(_ part: HTTPClientResponsePart) {
        guard !closed, !detached else { return }
        guard let activeLease else { close(error: nil); return }
        activeLease.sink?.receiveResponse(part)
    }
    func responseReadStarted() { activeLease?.sink?.responseReadStarted() }
    func responseReadComplete() { activeLease?.sink?.responseReadComplete() }
    func upstreamWritabilityChanged(_ writable: Bool) {
        guard !closed, !detached else { return }
        activeLease?.sink?.upstreamWritabilityChanged(writable)
    }
    func upstreamClosed(error: Error?) {
        guard !closed, !detached else { return }
        closed = true
        idleTimer?.cancel()
        let lease = activeLease
        activeLease = nil
        let sink = lease?.sink
        lease?.invalidate()
        sink?.upstreamClosed(error: error)
    }
    func close(error: Error?) {
        guard !detached else { return }
        if let error {
            // A TLS/protocol error may already be retained by the response handler when
            // failing buffered writes reenter this path with a generic closed-channel error.
            handler.close(error: error)
        } else { upstreamClosed(error: nil) }
        channel.close(promise: nil)
    }
    private func release(_ lease: Lease, reusable: Bool) {
        guard activeLease === lease else { return }
        activeLease = nil
        lease.invalidate()
        if reusable, !closed, channel.isActive {
            handler.setReading(true)
            idleTimer = channel.eventLoop.assumeIsolated().scheduleTask(in: idleTimeout) { [weak self] in
                self?.close(error: nil)
            }
            pool?.sessionAvailable(self)
        } else { close(error: nil) }
    }
    private func detach(_ lease: Lease) -> Channel? {
        guard activeLease === lease, !closed, !detached else { return nil }
        detached = true
        activeLease = nil
        lease.invalidate()
        idleTimer?.cancel()
        handler.sink = nil
        pool?.detach(self)
        return channel
    }

    private final class Lease: HTTP1UpstreamLease {
        let channel: Channel
        let version: HTTPWireVersion = .http1_1
        let wasReused: Bool
        fileprivate var sink: UpstreamResponseSink?
        private weak var session: HTTP1UpstreamSession?
        init(session: HTTP1UpstreamSession, sink: UpstreamResponseSink, wasReused: Bool) {
            self.session = session
            self.channel = session.channel
            self.sink = sink
            self.wasReused = wasReused
        }
        var isWritable: Bool { session?.channel.isWritable == true }
        func write(_ part: HTTPClientRequestPart) -> EventLoopFuture<Void> {
            guard let session else { return channel.eventLoop.makeFailedFuture(ChannelError.ioOnClosedChannel) }
            return session.handler.write(part) ?? channel.eventLoop.makeFailedFuture(ChannelError.ioOnClosedChannel)
        }
        func flush() { session?.handler.flush() }
        func setResponseReading(_ enabled: Bool) { session?.handler.setReading(enabled) }
        func release(reusable: Bool) { session?.release(self, reusable: reusable) }
        func cancel(error: Error?) { session?.close(error: error) }
        func detachForUpgrade() -> Channel? { session?.detach(self) }
        fileprivate func invalidate() { session = nil; sink = nil }
    }
}
