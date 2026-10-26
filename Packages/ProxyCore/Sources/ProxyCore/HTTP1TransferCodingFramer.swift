import NIOCore
import NIOHTTP1

protocol HTTP1FramingHead: Equatable {
    var version: HTTPVersion { get }
    var headers: HTTPHeaders { get }
    var isInterim: Bool { get }
}
extension HTTPRequestHead: HTTP1FramingHead {
    var isInterim: Bool { false }
}
extension HTTPResponseHead: HTTP1FramingHead {
    var isInterim: Bool { (100..<200).contains(status.code) && status != .switchingProtocols }
}

/// NIO's identity encoder preserves compound Transfer-Encoding text but only chunks the
/// literal value "chunked". Reapply that final coding here, leaving opaque earlier codings
/// untouched. Heads still use NIO serialization; buffers/file regions are forwarded intact.
final class HTTP1TransferCodingFramer<Head: HTTP1FramingHead>: ChannelOutboundHandler, RemovableChannelHandler {
    typealias OutboundIn = HTTPPart<Head, IOData>
    typealias OutboundOut = OutboundIn
    private enum State { case idle, ordinary, compound, failed }
    private var state = State.idle

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let part = unwrapOutboundIn(data)
        do {
            switch part {
            case .head(let head):
                guard state == .idle, head.version.major == 1 else { throw HTTPTranslationError.invalidFraming }
                try HTTPMessageTranslation.validate(head.headers)
                let codings = try HTTPMessageTranslation.transferCodings(head.headers)
                state = head.isInterim ? .idle : (codings.count > 1 && codings.last == "chunked" ? .compound : .ordinary)
                context.write(data, promise: promise)
            case .body(let body):
                guard state == .ordinary || state == .compound else { throw HTTPTranslationError.invalidFraming }
                if state == .compound, body.readableBytes > 0 {
                    let prefix = ByteBuffer(string: String(body.readableBytes, radix: 16) + "\r\n")
                    write([.body(.byteBuffer(prefix)), .body(body), .body(.byteBuffer(ByteBuffer(string: "\r\n")))], context: context, promise: promise)
                } else { context.write(data, promise: promise) }
            case .end(let fields):
                guard state == .ordinary || state == .compound else { throw HTTPTranslationError.invalidFraming }
                let trailers = try fields.flatMap { try HTTPMessageTranslation.trailers($0, destination: .http1_1, bodyAllowed: true) }
                let compound = state == .compound
                state = .idle
                if compound {
                    var buffer = ByteBuffer(string: "0\r\n")
                    if let trailers {
                        for (name, value) in trailers { buffer.writeString(name + ": " + value + "\r\n") }
                    }
                    buffer.writeString("\r\n")
                    write([.body(.byteBuffer(buffer)), .end(nil)], context: context, promise: promise)
                } else { context.write(wrapOutboundOut(.end(trailers)), promise: promise) }
            }
        } catch {
            state = .failed
            if let promise { promise.fail(error) }
            else { context.fireErrorCaught(error) }
        }
    }

    private func write(_ parts: [OutboundOut], context: ChannelHandlerContext, promise: EventLoopPromise<Void>?) {
        var result = context.eventLoop.makeSucceededVoidFuture()
        for part in parts {
            if promise != nil {
                let subwrite = context.eventLoop.makePromise(of: Void.self)
                context.write(wrapOutboundOut(part), promise: subwrite)
                result = result.and(subwrite.futureResult).map { _ in () }
            } else { context.write(wrapOutboundOut(part), promise: nil) }
        }
        if let promise { result.cascade(to: promise) }
    }
}
