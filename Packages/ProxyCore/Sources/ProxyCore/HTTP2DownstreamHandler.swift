import FlowStore
import NIOCore
import NIOHTTP1
import NIOHTTP2
import RulesEngine

/// One handler and exchange per child. The original connection alone owns its pool/lookup.
final class HTTP2DownstreamHandler: ChannelInboundHandler, DownstreamResponseWriter {
    typealias InboundIn = HTTPServerRequestPart
    let channel: Channel
    let version: HTTPWireVersion = .http2
    var eventLoop: EventLoop { channel.eventLoop }
    var isWritable: Bool { channel.isWritable }
    var isActive: Bool { channel.isActive }
    private let connection: ClientConnectionContext
    private let authority: RequestTarget
    private let metadata: HTTP2StreamMetadataHandler
    private var exchange: HTTPExchange?
    private var finished = false
    private(set) var reading = true
    private(set) var queuedBodyBytes = 0
    private var lastWrite: EventLoopFuture<Void>?

    init(channel: Channel, connection: ClientConnectionContext, authority: RequestTarget,
         metadata: HTTP2StreamMetadataHandler) {
        self.channel = channel; self.connection = connection; self.authority = authority; self.metadata = metadata
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !finished else { return }
        let part = unwrapInboundIn(data)
        if case .head(var head) = part {
            guard connection.permitsExchange else { abort(HTTPTransportError.closed); return }
            guard exchange == nil, let initial = metadata.initialHeaders else { abort(HTTPTransportError.closed); return }
            guard initial.scheme == "https", initial.method != "CONNECT",
                  let path = initial.path, !path.contains("#"),
                  path.utf8.allSatisfy({ $0 > 32 && $0 != 127 }),
                  path.hasPrefix("/") || (path == "*" && initial.method == "OPTIONS") else {
                reject(.badRequest, head: head, initial: initial)
                return
            }
            guard let requested = initial.authority,
                  HTTP2StreamMetadataHandler.sameEndpoint(requested, authority.authority, defaultPort: 443) else {
                reject(.misdirectedRequest, head: head, initial: initial)
                return
            }
            head.version = .http2
            head.headers = initial.regularHeaders
            var target = authority
            target.originForm = head.uri
            exchange = HTTPExchange(requestHead: head, target: target, scheme: "https", downstream: self,
                connection: connection, transport: .init(downstreamRequest: .http2, downstreamStreamID: Int(initial.streamID)),
                requestInitialEndStream: initial.endStream, requestReadBatch: true)
            exchange?.execute()
        } else { exchange?.requestReadStarted(); exchange?.receiveRequest(part) }
    }
    func channelReadComplete(context: ChannelHandlerContext) {
        exchange?.requestReadComplete()
        context.fireChannelReadComplete()
    }
    /// A request the proxy refuses to forward: the 400/421 is a generated response with no
    /// upstream, and its downstream boundary is recorded only once the writer accepted each part.
    private func reject(_ status: HTTPResponseStatus, head: HTTPRequestHead, initial: HTTP2StreamHeaders) {
        let headers = HTTPHeaders([("content-length", "0")])
        let recorder = connection.environment.recording.activeStore.map { store in
            FlowRecorder(store: store, scheme: "https", method: head.method.rawValue,
                host: authority.host, port: authority.port, path: initial.path ?? head.uri,
                requestHeaders: initial.regularHeaders, client: connection.knownClient, eventLoop: channel.eventLoop,
                transport: .init(downstreamRequest: .http2, downstreamStreamID: Int(initial.streamID)))
        }
        if let recorder {
            connection.onClient(recorder.setClient)
            recorder.fail(HTTP2TransportError.invalidAuthority.description())
            recorder.recordGeneratedResponse(status: status, headers: headers, body: nil)
        }
        for part in [HTTPServerResponsePart.head(.init(version: .http2, status: status, headers: headers)), .end(nil)] {
            write(part).assumeIsolated().whenComplete { result in
                var failed = false
                if case .failure = result { failed = true }
                recorder?.recordDownstreamWrite(part, bodyStream: nil, succeeded: !failed)
            }
        }
        flush()
        responseFinished()
    }

    func write(_ part: HTTPServerResponsePart) -> EventLoopFuture<Void> {
        let count: Int
        if case .body(.byteBuffer(let bytes)) = part { count = bytes.readableBytes } else { count = 0 }
        queuedBodyBytes += count
        let result = channel.write(part)
        result.assumeIsolated().whenComplete { [self] _ in queuedBodyBytes -= count }
        lastWrite = result
        return result
    }
    func flush() { channel.flush() }
    func setRequestReading(_ enabled: Bool) {
        guard reading != enabled else { return }
        reading = enabled
        channel.setAutoRead(enabled)
        if enabled { channel.read() }
    }
    func responseFinished() {
        guard !finished else { return }
        finished = true
        exchange = nil
        if let lastWrite { lastWrite.whenComplete { [channel] _ in channel.close(promise: nil) } }
        else { channel.close(promise: nil) }
    }
    func abort(_ error: Error) {
        guard !finished else { return }
        finished = true
        let active = exchange; exchange = nil
        active?.cancel(reason: UpstreamConnector.describe(error))
        channel.close(promise: nil)
    }
    /// Resets only this stream (D15): RST_STREAM NO_ERROR (graceful) or INTERNAL_ERROR (reset), written
    /// below the HTTP/1 codec, then the child closes. The parent connection and its other streams stay.
    func closeConnection(_ mode: RulesEngine.CloseMode) {
        guard !finished else { return }
        finished = true
        exchange = nil
        guard let codec = try? channel.pipeline.syncOperations.context(handlerType: HTTP2FramePayloadToHTTP1ServerCodec.self) else {
            channel.close(promise: nil)
            return
        }
        let code: HTTP2ErrorCode = mode == .reset ? .internalError : .noError
        codec.writeAndFlush(NIOAny(HTTP2Frame.FramePayload.rstStream(code))).whenComplete { [channel] _ in channel.close(promise: nil) }
    }
    func channelWritabilityChanged(context: ChannelHandlerContext) {
        exchange?.downstreamWritabilityChanged(channel.isWritable)
        context.fireChannelWritabilityChanged()
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) { abort(error) }
    func channelInactive(context: ChannelHandlerContext) {
        // END_STREAM flush can synchronously close a fully ended child while the exchange
        // is still recording completion. Let that stack finish before cancellation.
        let owner = NIOLoopBound(self, eventLoop: context.eventLoop)
        context.eventLoop.execute { owner.value.abort(HTTPTransportError.closed) }
        context.fireChannelInactive()
    }
}
