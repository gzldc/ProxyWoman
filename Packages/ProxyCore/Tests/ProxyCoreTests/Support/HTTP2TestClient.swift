import CertKit
import NIOCore
import NIOHTTP1
import NIOHTTP2
import NIOHPACK
import NIOPosix
import NIOSSL
@testable import ProxyCore

final class HTTP2TestClient: Sendable {
    struct Response: Sendable {
        var status = 0
        var statuses: [Int] = []
        var headers = HTTPHeaders()
        var body = ""
        var bytes: [UInt8] = []
        var trailers: HTTPHeaders?
        var snapshots: [HTTP2StreamHeaders] = []
    }
    final class State {
        var session: HTTP2Session?
        var negotiation: HTTPProtocolNegotiation?
        var http1Handler: UpstreamResponseHandler?
        var retainedSinks: [Sink] = []
    }
    let channel: Channel
    let selected: NegotiatedHTTPProtocol
    let state: NIOLoopBound<State>
    private let group: MultiThreadedEventLoopGroup
    private init(channel: Channel, selected: NegotiatedHTTPProtocol, state: NIOLoopBound<State>, group: MultiThreadedEventLoopGroup) {
        self.channel = channel; self.selected = selected; self.state = state; self.group = group
    }

    static func connect(origin: HTTP2TestOrigin, tls: TLSInterception? = nil,
                        roots: NIOSSLTrustRoots? = nil, policy: UpstreamProtocolPolicy = .automatic,
                        limits: HTTPTransportLimits = .init(), barrier: EventLoopFuture<Void>? = nil,
                        configurationStarted: EventLoopPromise<Void>? = nil,
                        firstBytes: EventLoopPromise<Void>? = nil,
                        configurationFails: Bool = false,
                        verificationHost: String = "localhost", tunneled: Bool = false,
                        proxyPort: Int? = nil) async throws -> HTTP2TestClient {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let loop = group.next()
        let state = try await loop.submit { NIOLoopBound(State(), eventLoop: loop) }.get()
        let tls = tls ?? TLSInterception(certificateAuthority: origin.ca, applicationProtocols: ["h2", "http/1.1"])
        let trustRoots = try roots ?? .certificates([NIOSSLCertificate(bytes: origin.ca.rootCertificateDER, format: .der)])
        let route = UpstreamRoute(scheme: "https", host: "localhost", port: origin.port, policy: policy)
        var opened: Channel?
        do {
            let install: @Sendable (Channel) -> EventLoopFuture<Void> = { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(tls.upstreamHandler(host: verificationHost, trustRoots: trustRoots,
                                                                                       tunneled: tunneled, policy: policy))
                    if let firstBytes { try channel.pipeline.syncOperations.addHandler(FixtureFirstBytes(promise: firstBytes)) }
                }.flatMap {
                    HTTP2Pipeline.installNegotiation(on: channel) { selected, channel in
                        configurationStarted?.succeed(())
                        if configurationFails { return channel.eventLoop.makeFailedFuture(FixtureError.setup) }
                        let start = barrier?.hop(to: channel.eventLoop) ?? channel.eventLoop.makeSucceededVoidFuture()
                        return start.flatMap {
                            if selected == .http2 {
                                return HTTP2Pipeline.installClient(on: channel, route: route, limits: limits)
                                    .assumeIsolated().map { session in state.value.session = session }.nonisolated()
                            }
                            return channel.eventLoop.makeCompletedFuture {
                                let handler = UpstreamResponseHandler()
                                state.value.http1Handler = handler
                                try channel.pipeline.syncOperations.addHandlers([
                                    HTTPMessageTranslation.requestEncoder(), HTTP1TransferCodingFramer<HTTPRequestHead>(),
                                    ByteToMessageHandler(HTTPResponseDecoder()), handler,
                                ])
                            }
                        }
                    }.assumeIsolated().map { state.value.negotiation = $0 }.nonisolated()
                }
            }
            let channel: Channel
            if let proxyPort {
                let tunnel = loop.makePromise(of: Void.self)
                channel = try await ClientBootstrap(group: loop).channelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.addHandler(HTTP2ProxyConnectResponse(promise: tunnel))
                    }
                }.connect(host: "127.0.0.1", port: proxyPort).get()
                opened = channel
                try await channel.writeAndFlush(ByteBuffer(string: "CONNECT localhost:\(origin.port) HTTP/1.1\r\nHost: localhost:\(origin.port)\r\n\r\n")).get()
                try await tunnel.futureResult.get()
                try await loop.flatSubmit { install(channel) }.get()
            } else {
                channel = try await ClientBootstrap(group: loop).channelInitializer(install)
                    .connect(host: "127.0.0.1", port: origin.port).get()
            }
            opened = channel
            let selected = try await loop.flatSubmit { state.value.negotiation!.readyProtocol }.get()
            return .init(channel: channel, selected: selected, state: state, group: group)
        } catch {
            if let opened { try? await opened.close().get() }
            try? await group.shutdownGracefully()
            throw error
        }
    }

    func request(headers: HTTPHeaders = .init([("host", "localhost")]), path: String = "/",
                 method: HTTPMethod = .GET, body: String? = nil, trailers: HTTPHeaders? = nil, waitForContinue: Bool = false) async throws -> Response {
        try await channel.eventLoop.flatSubmit { [self] in
            let sink = Sink(loop: channel.eventLoop)
            state.value.retainedSinks.append(sink)
            let head = HTTPRequestHead(version: selected == .http2 ? .http2 : .http1_1, method: method, uri: path, headers: headers)
            if let session = state.value.session {
                session.openStream(responseSink: sink).assumeIsolated().whenComplete { result in
                    switch result {
                    case .success(let lease):
                        sink.lease = lease
                        lease.write(.head(head)).assumeIsolated().whenFailure { sink.upstreamClosed(error: $0) }
                        let upload = {
                            if let body { _ = lease.write(.body(.byteBuffer(ByteBuffer(string: body)))) }
                            lease.write(.end(trailers)).assumeIsolated().whenFailure { sink.upstreamClosed(error: $0) }
                            lease.flush()
                        }
                        if waitForContinue {
                            sink.onHead = { [weak sink] in
                                guard let sink, sink.response.status == 100 else { return }
                                sink.onHead = nil; upload()
                            }
                            lease.flush()
                        } else { upload() }
                    case .failure(let error): sink.promise.fail(error)
                    }
                }
            } else if let handler = state.value.http1Handler {
                handler.sink = sink
                handler.write(.head(head))?.assumeIsolated().whenFailure { sink.upstreamClosed(error: $0) }
                if let body { _ = handler.write(.body(.byteBuffer(ByteBuffer(string: body)))) }
                handler.writeAndFlush(.end(trailers))?.assumeIsolated().whenFailure { sink.upstreamClosed(error: $0) }
            }
            return sink.promise.futureResult
        }.boundedGet()
    }

    func stop() async throws {
        try? await channel.close().get()
        try await group.shutdownGracefully()
    }

    /// Sink state stays on the channel event loop; futures carry only the Sendable response.
    final class Sink: UpstreamResponseSink {
        let promise: EventLoopPromise<Response>
        var response = Response()
        var lease: UpstreamLease?
        var onHead: (() -> Void)?
        var done = false
        init(loop: EventLoop) { promise = loop.makePromise() }
        func receiveResponse(_ part: HTTPClientResponsePart) {
            guard !done else { return }
            switch part {
            case .head(let head):
                if let headers = (lease as? HTTP2UpstreamLease)?.responseHeaders { response.snapshots.append(headers) }
                response.status = Int(head.status.code); response.headers = head.headers
                response.statuses.append(Int(head.status.code))
                onHead?()
            case .body(let body): response.body += String(buffer: body); response.bytes.append(contentsOf: body.readableBytesView)
            case .end(let trailers):
                if let headers = (lease as? HTTP2UpstreamLease)?.responseHeaders, headers.kind == .trailers { response.snapshots.append(headers) }
                response.trailers = trailers; done = true
                lease?.release(reusable: true); lease = nil
                promise.succeed(response)
            }
        }
        func upstreamWritabilityChanged(_ writable: Bool) {}
        func upstreamClosed(error: Error?) {
            guard !done else { return }; done = true
            promise.fail(error ?? HTTPTransportError.closed); lease = nil
        }
    }
}

private final class FixtureFirstBytes: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    let promise: EventLoopPromise<Void>
    var observed = false
    init(promise: EventLoopPromise<Void>) { self.promise = promise }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        if !observed { observed = true; promise.succeed(()) }
        context.fireChannelRead(data)
    }
}

extension HTTP2TestClient {
    struct PendingRequest: Sendable {
        let channel: Channel
        let response: EventLoopFuture<Response>
        func body(_ value: String, endStream: Bool = false) async throws {
            try await channel.writeAndFlush(HTTP2Frame.FramePayload.data(.init(data: .byteBuffer(ByteBuffer(string: value)), endStream: endStream))).boundedGet()
        }
        func end(trailers: HPACKHeaders = .init()) async throws {
            if trailers.isEmpty {
                try await channel.writeAndFlush(HTTP2Frame.FramePayload.data(.init(data: .byteBuffer(ByteBuffer()), endStream: true))).boundedGet()
            } else {
                try await channel.writeAndFlush(HTTP2Frame.FramePayload.headers(.init(headers: trailers, endStream: true))).boundedGet()
            }
        }
    }
    func startRawRequest(headers: HPACKHeaders, headObserved: EventLoopPromise<Void>? = nil) async throws -> PendingRequest {
        try await channel.eventLoop.flatSubmit { [self] in
            let response = channel.eventLoop.makePromise(of: Response.self)
            do {
                let mux = try channel.pipeline.syncOperations.handler(type: HTTP2StreamMultiplexer.self)
                let stream = mux.createStreamChannel { child in
                    child.eventLoop.makeCompletedFuture {
                        try child.pipeline.syncOperations.addHandler(FixturePayloadResponse(promise: response, headObserved: headObserved))
                    }
                }
                stream.whenFailure { response.fail($0) }
                return stream.flatMap { child in
                    child.writeAndFlush(HTTP2Frame.FramePayload.headers(.init(headers: headers, endStream: false)))
                        .map { PendingRequest(channel: child, response: response.futureResult) }
                }
            } catch { response.fail(error); return channel.eventLoop.makeFailedFuture(error) }
        }.boundedGet()
    }

    /// Payload-level test client permits exact END_STREAM/trailers and intentionally invalid
    /// frames without HTTP/1 codec normalization. Still uses the real parent HTTP/2 validator.
    func rawRequest(headers: HPACKHeaders, body: String? = nil, trailers: HPACKHeaders? = nil,
                    failStreamSetup: Bool = false) async throws -> Response {
        try await channel.eventLoop.flatSubmit { [self] in
            let response = channel.eventLoop.makePromise(of: Response.self)
            do {
                let mux = try channel.pipeline.syncOperations.handler(type: HTTP2StreamMultiplexer.self)
                mux.createStreamChannel { child in
                    child.eventLoop.makeCompletedFuture {
                        if failStreamSetup { throw HTTPTransportError.cancelled }
                        try child.pipeline.syncOperations.addHandler(FixturePayloadResponse(promise: response))
                    }
                }.whenComplete { result in
                    guard case .success(let child) = result else {
                        if case .failure(let error) = result { response.fail(error) }
                        return
                    }
                    child.write(HTTP2Frame.FramePayload.headers(.init(headers: headers, endStream: body == nil && trailers == nil)), promise: nil)
                    if let body {
                        child.write(HTTP2Frame.FramePayload.data(.init(data: .byteBuffer(ByteBuffer(string: body)), endStream: trailers == nil)), promise: nil)
                    }
                    if let trailers { child.write(HTTP2Frame.FramePayload.headers(.init(headers: trailers, endStream: true)), promise: nil) }
                    child.flush()
                }
            } catch { response.fail(error) }
            return response.futureResult
        }.boundedGet()
    }
}

private final class FixturePayloadResponse: ChannelInboundHandler {
    typealias InboundIn = HTTP2Frame.FramePayload
    let promise: EventLoopPromise<HTTP2TestClient.Response>
    var result = HTTP2TestClient.Response()
    var done = false
    let headObserved: EventLoopPromise<Void>?
    var headSeen = false
    init(promise: EventLoopPromise<HTTP2TestClient.Response>, headObserved: EventLoopPromise<Void>? = nil) {
        self.promise = promise; self.headObserved = headObserved
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !done else { return }
        switch unwrapInboundIn(data) {
        case .headers(let block):
            var regular = HTTPHeaders()
            for field in block.headers {
                if field.name == ":status" { result.status = Int(field.value)! }
                else if !field.name.hasPrefix(":") { regular.add(name: field.name, value: field.value) }
            }
            if block.headers.contains(name: ":status") {
                result.headers = regular
                if !headSeen { headSeen = true; headObserved?.succeed(()) }
            }
            else { result.trailers = regular }
            if block.endStream { complete() }
        case .data(let data):
            if case .byteBuffer(let body) = data.data { result.body += String(buffer: body) }
            if data.endStream { complete() }
        default: break
        }
    }
    func complete() { done = true; promise.succeed(result) }
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        if !done { done = true; promise.fail(error) }
        if !headSeen { headSeen = true; headObserved?.fail(error) }
        context.close(promise: nil)
    }
    func channelInactive(context: ChannelHandlerContext) {
        if !done { done = true; promise.fail(HTTPTransportError.closed) }
        if !headSeen { headSeen = true; headObserved?.fail(HTTPTransportError.closed) }
        context.fireChannelInactive()
    }
}

/// A real single-thread loop for barriers shared by async tasks and network event loops.
func withHTTP2ControlLoop(_ body: (EventLoop) async throws -> Void) async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    do { try await body(group.next()); try await group.shutdownGracefully() }
    catch { try? await group.shutdownGracefully(); throw error }
}
