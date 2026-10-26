import NIOCore
import NIOHTTP2

/// Must sit after NIO's validation/state machine and BEFORE the multiplexer: state updates
/// precede any child callbacks/reentrant acquisitions triggered by forwarding the same frame.
final class HTTP2ConnectionObserver: ChannelInboundHandler {
    typealias InboundIn = HTTP2Frame
    typealias InboundOut = HTTP2Frame
    private let session: HTTP2Session?
    init(session: HTTP2Session?) { self.session = session }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data).payload {
        case .settings(.settings(let settings)): session?.receivedPeerSettings(settings)
        case .goAway(let lastStreamID, let errorCode, _): session?.receivedGoAway(lastStreamID: lastStreamID, errorCode: errorCode)
        default: break
        }
        context.fireChannelRead(data)
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        // NIO uses this typed wrapper for errors owned by one stream. The mux delivers the
        // original base error to that child; closing the parent here would cancel its siblings.
        if error is NIOHTTP2Errors.StreamError {
            context.fireErrorCaught(error)
            return
        }
        session?.close(error: error)
        context.fireErrorCaught(error)
        context.close(promise: nil)
    }
    func channelInactive(context: ChannelHandlerContext) {
        session?.close(error: nil)
        context.fireChannelInactive()
    }
}
