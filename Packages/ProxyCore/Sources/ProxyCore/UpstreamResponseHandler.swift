import NIOCore
import NIOHTTP1

/// Last handler of an upstream channel: feeds response parts to the session response sink and
/// writes request parts it is handed.
final class UpstreamResponseHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPClientResponsePart
    typealias OutboundOut = HTTPClientRequestPart

    weak var sink: UpstreamResponseSink?
    private var context: ChannelHandlerContext?
    private var closeError: Error?
    private var reportedClose = false

    var isWritable: Bool { context?.channel.isWritable ?? false }

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        sink?.responseReadStarted()
        sink?.receiveResponse(unwrapInboundIn(data))
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        sink?.responseReadComplete()
        context.fireChannelReadComplete()
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        sink?.upstreamWritabilityChanged(context.channel.isWritable)
        context.fireChannelWritabilityChanged()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        if closeError == nil { closeError = error }
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        reportClose()
        context.fireChannelInactive()
    }

    func write(_ part: HTTPClientRequestPart) -> EventLoopFuture<Void>? {
        context?.write(wrapOutboundOut(part))
    }

    func flush() {
        context?.flush()
    }

    func writeAndFlush(_ part: HTTPClientRequestPart) -> EventLoopFuture<Void>? {
        context?.writeAndFlush(wrapOutboundOut(part))
    }

    func setReading(_ enabled: Bool) {
        context?.channel.setAutoRead(enabled)
    }

    func close() {
        context?.close(promise: nil)
    }

    /// Closes the connection, reporting `error` as the reason to the owner.
    func close(error: Error) {
        if closeError == nil { closeError = error }
        reportClose()
        context?.close(promise: nil)
    }

    private func reportClose() {
        guard !reportedClose else { return }
        reportedClose = true
        sink?.upstreamClosed(error: closeError)
    }
}
