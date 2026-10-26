import Localization
import NIOCore
import NIOHTTP1
import NIOHTTP2
import NIOTLS

enum NegotiatedHTTPProtocol: Sendable { case http1, http2 }

/// Installation and handshake readiness are deliberately different futures. Bootstraps await
/// installation; acquisitions await this result, after the selected pipeline has been configured.
struct HTTPProtocolNegotiation: Sendable {
    let readyProtocol: EventLoopFuture<NegotiatedHTTPProtocol>
}

enum HTTP2TransportError: Error {
    case unsupportedALPN(String), invalidAuthority, headerLimitExceeded, draining

    func description(localizer: Localizer = L10n.localizer) -> String {
        switch self {
        case .unsupportedALPN(let token): return localizer.format("proxyHTTP2.unsupportedALPN", arguments: [token])
        case .invalidAuthority: return localizer.format("proxyHTTP2.invalidAuthority", arguments: [])
        case .headerLimitExceeded: return localizer.format("proxyHTTP2.headerLimitExceeded", arguments: [])
        case .draining: return localizer.format("proxyHTTP2.draining", arguments: [])
        }
    }
}

enum HTTP2Pipeline {
    static func installNegotiation(
        on channel: Channel,
        configure: @escaping @Sendable (NegotiatedHTTPProtocol, Channel) -> EventLoopFuture<Void>
    ) -> EventLoopFuture<HTTPProtocolNegotiation> {
        channel.eventLoop.makeCompletedFuture {
            let completion = NegotiationCompletion(loop: channel.eventLoop)
            let handler = ApplicationProtocolNegotiationHandler { result, channel in
                let selected: NegotiatedHTTPProtocol
                switch result {
                case .negotiated("h2"): selected = .http2
                case .negotiated("http/1.1"), .fallback: selected = .http1
                case .negotiated(let token):
                    let error = HTTP2TransportError.unsupportedALPN(token)
                    completion.fail(error, channel: channel)
                    return channel.eventLoop.makeFailedFuture(error)
                }
                let configured = configure(selected, channel).hop(to: channel.eventLoop)
                configured.assumeIsolated().whenComplete { result in
                    switch result {
                    case .success:
                        completion.succeed(selected, channel: channel)
                    case .failure(let error): completion.fail(error, channel: channel)
                    }
                }
                return configured
            }
            do {
                try channel.pipeline.syncOperations.addHandlers([completion, handler])
            } catch {
                completion.fail(error, channel: channel)
                throw error
            }
            return HTTPProtocolNegotiation(readyProtocol: completion.promise.futureResult)
        }
    }

    static func installServer(on channel: Channel, connection: ClientConnectionContext,
                              authority: RequestTarget) -> EventLoopFuture<Void> {
        let owner = NIOLoopBound(connection, eventLoop: channel.eventLoop)
        return installServer(on: channel, limits: connection.limits) { child in
            child.eventLoop.makeCompletedFuture {
                let metadata = HTTP2StreamMetadataHandler(role: .request, limits: owner.value.limits)
                try child.pipeline.syncOperations.addHandlers([
                    metadata, HTTP2FramePayloadToHTTP1ServerCodec(),
                    HTTP2DownstreamHandler(channel: child, connection: owner.value, authority: authority, metadata: metadata),
                ])
            }
        }
    }

    static func installServer(
        on channel: Channel, limits: HTTPTransportLimits,
        streamInitializer: @escaping @Sendable (Channel) -> EventLoopFuture<Void>
    ) -> EventLoopFuture<Void> {
        channel.eventLoop.makeCompletedFuture {
            let mux = HTTP2StreamMultiplexer(mode: .server, channel: channel,
                targetWindowSize: limits.receiveWindow, outboundBufferSizeHighWatermark: limits.highWatermark,
                outboundBufferSizeLowWatermark: limits.lowWatermark, inboundStreamInitializer: streamInitializer)
            try channel.pipeline.syncOperations.addHandlers([
                NIOHTTP2Handler(mode: .server, initialSettings: settings(limits: limits, server: true)),
                HTTP2ConnectionObserver(session: nil), mux,
            ])
        }
    }

    /// Called only in the selected h2 configurator, never for h1/no-ALPN fallback.
    /// Like leases, the returned session is confined to channel.eventLoop.
    static func installClient(on channel: Channel, route: UpstreamRoute,
                              limits: HTTPTransportLimits,
                              streamCreationGate: ((Channel) -> EventLoopFuture<Void>)? = nil) -> EventLoopFuture<HTTP2Session> {
        channel.eventLoop.preconditionInEventLoop()
        let promise = channel.eventLoop.makePromise(of: HTTP2Session.self)
        do {
            let mux = HTTP2StreamMultiplexer(mode: .client, channel: channel,
                targetWindowSize: limits.receiveWindow, outboundBufferSizeHighWatermark: limits.highWatermark,
                outboundBufferSizeLowWatermark: limits.lowWatermark,
                inboundStreamInitializer: { child in child.close() })
            let session = HTTP2Session(channel: channel, route: route, limits: limits, multiplexer: mux, streamCreationGate: streamCreationGate)
            try channel.pipeline.syncOperations.addHandlers([
                NIOHTTP2Handler(mode: .client, initialSettings: settings(limits: limits, server: false)),
                HTTP2ConnectionObserver(session: session), mux,
            ])
            promise.assumeIsolated().succeed(session)
        } catch { promise.fail(error) }
        return promise.futureResult
    }

    private static func settings(limits: HTTPTransportLimits, server: Bool) -> HTTP2Settings {
        var settings: HTTP2Settings = [
            .init(parameter: .maxConcurrentStreams, value: server ? limits.downstreamStreams : 0),
            .init(parameter: .initialWindowSize, value: limits.receiveWindow),
            .init(parameter: .maxHeaderListSize, value: limits.headerBytes),
        ]
        if !server { settings.append(.init(parameter: .enablePush, value: 0)) }
        return settings
    }
}

/// Before ALPN buffering, independently of the pinning/handshake monitor. Preserve the first
/// underlying TLS error; a subsequent channelInactive must not replace it with a generic close.
private final class NegotiationCompletion: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    let promise: EventLoopPromise<NegotiatedHTTPProtocol>
    private var settled = false
    init(loop: EventLoop) { promise = loop.makePromise() }
    func succeed(_ selected: NegotiatedHTTPProtocol, channel: Channel) {
        guard !settled else { return }
        settled = true
        promise.succeed(selected)
        channel.pipeline.syncOperations.removeHandler(self, promise: nil)
    }
    func fail(_ error: Error, channel: Channel) {
        guard !settled else { return }
        settled = true
        promise.fail(error)
        channel.close(promise: nil)
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        fail(error, channel: context.channel)
        context.fireErrorCaught(error)
    }
    func channelInactive(context: ChannelHandlerContext) {
        fail(HTTPTransportError.closed, channel: context.channel)
        context.fireChannelInactive()
    }
}
