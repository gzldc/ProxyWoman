import NIOCore

/// Relays raw bytes between two channels that share one event loop (after an HTTP upgrade, or
/// for a CONNECT tunnel). Each side stops reading while its partner's channel is not writable.
final class GlueHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private var partner: GlueHandler?
    private var context: ChannelHandlerContext?
    /// Called with the size of every buffer read on this side, before it is relayed.
    var onRead: ((Int) -> Void)?
    /// Optional passive observation; forwarding always uses the original buffer.
    var onObservedRead: ((ByteBuffer) -> Void)?
    /// Called when this side's channel goes inactive.
    var onClose: (() -> Void)?

    private init() {}

    static func makePair() -> (GlueHandler, GlueHandler) {
        let first = GlueHandler()
        let second = GlueHandler()
        first.partner = second
        second.partner = first
        return (first, second)
    }

    /// Relays `client` ⇄ `upstream` (both on one event loop) as a CONNECT tunnel whose bytes and
    /// end are recorded by `recorder`, if any. `installClientGlue` puts the client side's handler
    /// in place.
    static func joinTunnel(
        client: Channel, upstream: Channel, recorder: TunnelRecorder?,
        installClientGlue: (GlueHandler) throws -> Void
    ) throws {
        let (clientGlue, upstreamGlue) = makePair()
        clientGlue.onRead = recorder?.addSent
        upstreamGlue.onRead = recorder?.addReceived
        clientGlue.onClose = recorder?.close
        upstreamGlue.onClose = recorder?.close
        try upstream.pipeline.syncOperations.addHandler(upstreamGlue)
        try installClientGlue(clientGlue)
        client.setAutoRead(upstream.isWritable)
        upstream.setAutoRead(client.isWritable)
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
        partner = nil
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        // Flushed per read: bytes a decoder hands over when it is removed come without a
        // channelReadComplete.
        let buffer = unwrapInboundIn(data)
        onRead?(buffer.readableBytes)
        onObservedRead?(buffer)
        partner?.context?.writeAndFlush(wrapOutboundOut(buffer), promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        onClose?()
        partner?.context?.close(promise: nil)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        partner?.context?.channel.setAutoRead(context.channel.isWritable)
        context.fireChannelWritabilityChanged()
    }
}

/// Removes an HTTP decoder during an upgrade or CONNECT handoff without losing the leftover
/// bytes behind the head when an EOF arrives in the same read batch.
///
/// Depends on this swift-nio ordering (re-check on every swift-nio bump):
/// - `NIOCore/Codec.swift` `ByteToMessageHandler.removeHandler(context:removalToken:)` runs
///   `processLeftovers` in ONE `eventLoop.execute` task queued at removal time, then completes
///   the removal promise;
/// - `NIOHTTP1/HTTPDecoder.swift` `decodeLast` forwards leftover bytes (`.forwardBytes`) only
///   when `seenEOF` is false, so an earlier `channelInactive` would drop them;
/// - `NIOPosix/BaseSocketChannel.swift` `close0` fires `channelInactive` synchronously and only
///   then queues `removeHandlers` with `eventLoop.execute`.
/// While the removal is pending, the guard re-fires inactivity from a task queued during
/// `close0`: FIFO after the decoder's removal task and before pipeline teardown. Once the
/// removal completed it is disarmed and passes inactivity through immediately, so guards from
/// successive handoffs on one channel (CONNECT then Upgrade) never chain past teardown.
final class DeferredInactiveHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    private var armed = true
    func channelInactive(context: ChannelHandlerContext) {
        guard armed else { context.fireChannelInactive(); return }
        context.eventLoop.assumeIsolated().execute { context.fireChannelInactive() }
    }
    /// Inserts a guard before `decoder` and requests the decoder's removal.
    static func removeDecoder(_ decoder: RemovableChannelHandler, from pipeline: ChannelPipeline.SynchronousOperations,
                              on eventLoop: EventLoop) throws {
        let guardHandler = DeferredInactiveHandler()
        try pipeline.addHandler(guardHandler, position: .before(decoder))
        let removed = eventLoop.makePromise(of: Void.self)
        removed.futureResult.assumeIsolated().whenComplete { _ in guardHandler.armed = false }
        pipeline.removeHandler(decoder, promise: removed)
    }
}

extension Channel {
    /// Toggles reading for backpressure. Must be called on the channel's event loop.
    /// On a paced connection whose queue is at its cap, a re-enable is handed to the
    /// `ConnectionPacer` (NIO would otherwise start a socket read the gate cannot withhold).
    func setAutoRead(_ enabled: Bool) {
        if let options = syncOptions {
            if let pacer = try? pipeline.syncOperations.handler(type: ConnectionPacer.self),
               pacer.holdsAutoRead(enabled) { return }
            try? options.setOption(ChannelOptions.autoRead, value: enabled)
        } else {
            setOption(ChannelOptions.autoRead, value: enabled).whenFailure { _ in }
        }
    }
}
