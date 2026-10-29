import CertKit
import NIOCore
import NIOHTTP1
import NIOHTTP2
import NIOHPACK
import NIOPosix
import NIOSSL
import os
@testable import ProxyCore

/// Complete loopback adapter, independent of the future production downstream adapter.
final class HTTP2TestOrigin: Sendable {
    struct Response: Sendable {
        var supportsUpgrade = false
        var headers = HTTPHeaders([("set-cookie", "a=1"), ("set-cookie", "b=2")])
        var body = "fixture-body"
        var rawBody: [UInt8]? = nil
        var bodiesByPath: [String: String] = [:]
        var status: HTTPResponseStatus = .ok
        var informational: HTTPHeaders?
        var informationalStatuses: [Int] = []
        var headersOnly = false
        var truncateAfterBody = false
        var h1TransferCoding: String?
        var earlyPaths: Set<String> = []
        /// Answer at the request head, then reset the stream with NO_ERROR without reading the upload
        /// (RFC 9113 8.1: a server may reject an upload this way, like an origin enforcing a size limit).
        var rejectPaths: Set<String> = []
        var requestsObserved: EventLoopPromise<Void>?
        var requestCountTarget = 1
        var trailers: HTTPHeaders? = HTTPHeaders([("x-finish", "done")])
        var barrier: EventLoopFuture<Void>?
        var bodyBarriersByPath: [String: EventLoopFuture<Void>] = [:]
        var barriersByPath: [String: EventLoopFuture<Void>] = [:]
        var endsObserved: EventLoopPromise<Void>?
        var endsTarget = 1
    }
    struct Counts: Sendable {
        var upgradeBytes: [UInt8] = []
        var negotiated: [NegotiatedHTTPProtocol] = []
        var connections = 0
        var parents: [Channel] = []
        var paths: [String] = []
        var bodies: [String: String] = [:]
        var endedPaths: [String] = []
        var responseOrder: [String] = []
        var requestHeaders: [HTTPHeaders] = []
        var requests = 0
        var streamIDs: [Int] = []
        var originalHeaders: [HTTPHeaders] = []
        var originalTrailers: [HTTPHeaders] = []
        var authorities: [String] = []
        var initialEndStreams: [Bool] = []
    }
    let ca: CertificateAuthority
    let channel: Channel
    var port: Int { channel.localAddress!.port! }
    private let group: MultiThreadedEventLoopGroup
    private let observations: OSAllocatedUnfairLock<Counts>
    var counts: Counts { observations.withLock { $0 } }

    private init(ca: CertificateAuthority, channel: Channel, group: MultiThreadedEventLoopGroup,
                 observations: OSAllocatedUnfairLock<Counts>) {
        self.ca = ca; self.channel = channel; self.group = group; self.observations = observations
    }

    static func withOrigin(protocols: [String], response: Response = .init(), limits: HTTPTransportLimits = .init(),
                           _ body: (HTTP2TestOrigin) async throws -> Void) async throws {
        let origin = try await start(protocols: protocols, response: response, limits: limits)
        do { try await body(origin); try await origin.stop() }
        catch { try? await origin.stop(); throw error }
    }

    static func start(protocols: [String], response: Response = .init(), certificateHost: String = "localhost", plaintext: Bool = false, limits: HTTPTransportLimits = .init()) async throws -> HTTP2TestOrigin {
        let ca = try CertificateAuthority.generate(commonName: "HTTP2 fixture CA")
        let leaf = try ca.leaf(for: certificateHost)
        var config = TLSConfiguration.makeServerConfiguration(
            certificateChain: [.certificate(try NIOSSLCertificate(bytes: leaf.certificateDER, format: .der))],
            privateKey: .privateKey(try NIOSSLPrivateKey(bytes: leaf.privateKeyDER, format: .der)))
        config.applicationProtocols = protocols
        let tls = try NIOSSLContext(configuration: config)
        let observations = OSAllocatedUnfairLock(initialState: Counts())
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        do {
            let channel = try await ServerBootstrap(group: group).childChannelInitializer { channel in
                observations.withLock { $0.connections += 1; $0.parents.append(channel) }
                if plaintext {
                    return channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.addHandlers([
                            HTTPMessageTranslation.responseEncoder(), HTTP1TransferCodingFramer<HTTPResponseHead>(),
                            ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes)),
                            FixtureOriginHandler(response: response, counts: observations, metadata: nil),
                        ])
                    }
                }
                return channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: tls))
                }.flatMap {
                    HTTP2Pipeline.installNegotiation(on: channel) { selected, channel in
                        observations.withLock { $0.negotiated.append(selected) }
                        if selected == .http2 {
                            return HTTP2Pipeline.installServer(on: channel, limits: limits) { child in
                                child.eventLoop.makeCompletedFuture {
                                    let metadata = HTTP2StreamMetadataHandler(role: .request, limits: .init())
                                    try child.pipeline.syncOperations.addHandlers([
                                        metadata, HTTP2FramePayloadToHTTP1ServerCodec(),
                                        FixtureOriginHandler(response: response, counts: observations, metadata: metadata),
                                    ])
                                }
                            }
                        }
                        return channel.eventLoop.makeCompletedFuture {
                            try channel.pipeline.syncOperations.addHandlers([
                                HTTPMessageTranslation.responseEncoder(), HTTP1TransferCodingFramer<HTTPResponseHead>(),
                                ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes)),
                                FixtureOriginHandler(response: response, counts: observations, metadata: nil),
                            ])
                        }
                    }.map { _ in () }
                }
            }.bind(host: "127.0.0.1", port: 0).get()
            return .init(ca: ca, channel: channel, group: group, observations: observations)
        } catch { try? await group.shutdownGracefully(); throw error }
    }

    func stop() async throws {
        try? await channel.close().get()
        try await group.shutdownGracefully()
    }
}

private final class FixtureOriginHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart
    let response: HTTP2TestOrigin.Response
    let counts: OSAllocatedUnfairLock<HTTP2TestOrigin.Counts>
    let metadata: HTTP2StreamMetadataHandler?
    var path = ""
    var requestHeaders = HTTPHeaders()
    var method: HTTPMethod = .GET
    var responded = false
    init(response: HTTP2TestOrigin.Response, counts: OSAllocatedUnfairLock<HTTP2TestOrigin.Counts>,
         metadata: HTTP2StreamMetadataHandler?) {
        self.response = response; self.counts = counts; self.metadata = metadata
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            path = head.uri; method = head.method; responded = false; requestHeaders = head.headers
            let initial = metadata?.initialHeaders
            let count = counts.withLock { [path] in
                $0.requests += 1
                $0.paths.append(path)
                $0.requestHeaders.append(head.headers)
                if let initial {
                    $0.streamIDs.append(Int(initial.streamID))
                    $0.originalHeaders.append(initial.regularHeaders)
                    if let authority = initial.authority { $0.authorities.append(authority) }
                    $0.initialEndStreams.append(initial.endStream)
                }
                return $0.requests
            }
            if count == response.requestCountTarget { response.requestsObserved?.succeed(()) }
            if response.earlyPaths.contains(path) { respond(context: context) }
            if response.rejectPaths.contains(path), metadata != nil {
                responded = true
                counts.withLock { [path] in $0.responseOrder.append(path) }
                context.write(wrapOutboundOut(.head(.init(version: .http2, status: response.status, headers: response.headers))), promise: nil)
                context.write(wrapOutboundOut(.body(.byteBuffer(ByteBuffer(string: response.body)))), promise: nil)
                // RST_STREAM skips queued DATA, so reset only once the whole response is on the wire.
                context.writeAndFlush(wrapOutboundOut(.end(nil))).assumeIsolated().whenComplete { _ in
                    if let codec = try? context.pipeline.syncOperations.context(handlerType: HTTP2FramePayloadToHTTP1ServerCodec.self) {
                        codec.writeAndFlush(NIOAny(HTTP2Frame.FramePayload.rstStream(.noError)), promise: nil)
                    }
                }
            }
        case .end(let trailers):
            if response.supportsUpgrade, metadata == nil, path.hasPrefix("/ws") {
                if path == "/ws-fail" { context.close(promise: nil) }
                else { upgrade(context: context) }
                return
            }
            let ends = counts.withLock { [path] in $0.endedPaths.append(path); return $0.endedPaths.count }
            if ends == response.endsTarget { response.endsObserved?.succeed(()) }
            if let original = metadata?.trailingHeaders { counts.withLock { $0.originalTrailers.append(original.regularHeaders) } }
            else if metadata == nil, let trailers { counts.withLock { $0.originalTrailers.append(trailers) } }
            if let barrier = response.barriersByPath[path] ?? response.barrier {
                barrier.hop(to: context.eventLoop).assumeIsolated().whenSuccess { self.respond(context: context) }
            } else { respond(context: context) }
        case .body(let body): counts.withLock { [path] in $0.bodies[path, default: ""] += String(buffer: body) }
        }
    }
    private func upgrade(context: ChannelHandlerContext) {
        guard requestHeaders.first(name: "sec-websocket-key") == HTTP2UpgradeWire.key,
              requestHeaders.first(name: "sec-websocket-version") == "13",
              requestHeaders.first(name: "upgrade")?.lowercased() == "websocket" else {
            context.close(promise: nil); return
        }
        let pipeline = context.pipeline.syncOperations
        do {
            let encoder = try pipeline.handler(type: HTTPResponseEncoder.self)
            let decoder = try pipeline.handler(type: ByteToMessageHandler<HTTPRequestDecoder>.self)
            let framer = try pipeline.handler(type: HTTP1TransferCodingFramer<HTTPResponseHead>.self)
            try pipeline.addHandler(HTTP2UpgradeWire.Receiver { [counts] bytes in
                counts.withLock { $0.upgradeBytes.append(contentsOf: bytes) }
            })
            pipeline.removeHandler(context: context, promise: nil)
            pipeline.removeHandler(encoder, promise: nil)
            pipeline.removeHandler(framer, promise: nil)
            pipeline.removeHandler(decoder, promise: nil)
            // One literal buffer and write: the first frame is already behind the 101 head.
            context.channel.writeAndFlush(ByteBuffer(bytes: HTTP2UpgradeWire.response + HTTP2UpgradeWire.greeting), promise: nil)
        } catch { context.close(promise: nil) }
    }

    private func respond(context: ChannelHandlerContext) {
        guard context.channel.isActive, !responded else { return }
        responded = true
        counts.withLock { [path] in $0.responseOrder.append(path) }
        for status in response.informationalStatuses {
            context.write(wrapOutboundOut(.head(.init(version: metadata == nil ? .http1_1 : .http2,
                status: .init(statusCode: status)))), promise: nil)
        }
        if let informational = response.informational {
            context.write(wrapOutboundOut(.head(.init(version: .http2, status: .init(statusCode: 103), headers: informational))), promise: nil)
        }
        if response.headersOnly, metadata != nil {
            do {
                var headers = HPACKHeaders([ (":status", "200") ])
                for field in response.headers { headers.add(name: field.name, value: field.value) }
                let codec = try context.pipeline.syncOperations.context(handlerType: HTTP2FramePayloadToHTTP1ServerCodec.self)
                codec.writeAndFlush(NIOAny(HTTP2Frame.FramePayload.headers(.init(headers: headers, endStream: true))), promise: nil)
            } catch { context.close(promise: nil) }
            return
        }
        var headers = response.headers
        if metadata == nil, method != .HEAD { headers.add(name: "transfer-encoding", value: response.h1TransferCoding ?? "chunked") }
        context.write(wrapOutboundOut(.head(.init(version: metadata == nil ? .http1_1 : .http2, status: response.status, headers: headers))), promise: nil)
        if let barrier = response.bodyBarriersByPath[path] {
            context.flush()
            barrier.hop(to: context.eventLoop).assumeIsolated().whenSuccess { self.finishBody(context: context) }
        } else { finishBody(context: context) }
    }
    private func finishBody(context: ChannelHandlerContext) {
        guard context.channel.isActive else { return }
        if method != .HEAD { context.write(wrapOutboundOut(.body(.byteBuffer(response.rawBody.map { ByteBuffer(bytes: $0) } ?? ByteBuffer(string: response.bodiesByPath[path] ?? response.body)))), promise: nil) }
        if response.truncateAfterBody { context.flush(); context.close(promise: nil); return }
        context.writeAndFlush(wrapOutboundOut(.end(method == .HEAD ? nil : response.trailers)), promise: nil)
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}
