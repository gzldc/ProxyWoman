import CertKit
import NIOCore
import NIOHTTP1
import NIOHTTP2
import NIOPosix
import NIOSSL
import os
@testable import ProxyCore

/// Accepts TCP connections and never sends a byte: a stalled TLS handshake for an `https` URL, or
/// an upstream proxy that never answers its CONNECT. Counts accepted and closed connections and
/// the bytes it received.
final class ComposeSilentServer: Sendable {
    struct State {
        var connections = 0
        var closed = 0
        var receivedBytes = 0
    }

    let state: OSAllocatedUnfairLock<State>
    let port: Int
    private let group: MultiThreadedEventLoopGroup
    private let channel: Channel

    private init(group: MultiThreadedEventLoopGroup, channel: Channel, state: OSAllocatedUnfairLock<State>) {
        self.group = group
        self.channel = channel
        self.state = state
        self.port = channel.localAddress!.port!
    }

    static func start() async throws -> ComposeSilentServer {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let state = OSAllocatedUnfairLock(initialState: State())
        do {
            let channel = try await ServerBootstrap(group: group).childChannelInitializer { channel in
                state.withLock { $0.connections += 1 }
                return channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(SilentHandler(state: state))
                }
            }.bind(host: "127.0.0.1", port: 0).get()
            return ComposeSilentServer(group: group, channel: channel, state: state)
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
    }

    func stop() async throws {
        try? await channel.close().get()
        try await group.shutdownGracefully()
    }

    private final class SilentHandler: ChannelInboundHandler {
        typealias InboundIn = ByteBuffer
        let state: OSAllocatedUnfairLock<State>
        init(state: OSAllocatedUnfairLock<State>) { self.state = state }
        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            let count = unwrapInboundIn(data).readableBytes
            state.withLock { $0.receivedBytes += count }
        }
        func channelInactive(context: ChannelHandlerContext) {
            state.withLock { $0.closed += 1 }
            context.fireChannelInactive()
        }
        func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
    }
}

/// A TLS origin for `localhost` offering `protocols` by ALPN. It records each connection's
/// negotiated protocol, the paths it was asked for, every RST_STREAM a client sent and every
/// connection that ended. `/hold` is never answered; anything else gets 200 "ok".
final class ComposeTLSOrigin: Sendable {
    struct State {
        var connections = 0
        var closed = 0
        var negotiated: [NegotiatedHTTPProtocol] = []
        var paths: [String] = []
        var resets: [HTTP2ErrorCode] = []
    }

    let ca: CertificateAuthority
    let state: OSAllocatedUnfairLock<State>
    let port: Int
    private let group: MultiThreadedEventLoopGroup
    private let channel: Channel

    private init(ca: CertificateAuthority, group: MultiThreadedEventLoopGroup, channel: Channel, state: OSAllocatedUnfairLock<State>) {
        self.ca = ca
        self.group = group
        self.channel = channel
        self.state = state
        self.port = channel.localAddress!.port!
    }

    var trustRoots: NIOSSLTrustRoots {
        get throws { .certificates([try NIOSSLCertificate(bytes: ca.rootCertificateDER, format: .der)]) }
    }

    static func start(protocols: [String]) async throws -> ComposeTLSOrigin {
        let ca = try CertificateAuthority.generate(commonName: "Compose TLS origin CA")
        let leaf = try ca.leaf(for: "localhost")
        var configuration = TLSConfiguration.makeServerConfiguration(
            certificateChain: [.certificate(try NIOSSLCertificate(bytes: leaf.certificateDER, format: .der))],
            privateKey: .privateKey(try NIOSSLPrivateKey(bytes: leaf.privateKeyDER, format: .der)))
        configuration.applicationProtocols = protocols
        let tls = try NIOSSLContext(configuration: configuration)
        let state = OSAllocatedUnfairLock(initialState: State())
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        do {
            let channel = try await ServerBootstrap(group: group).childChannelInitializer { channel in
                state.withLock { $0.connections += 1 }
                return channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: tls))
                    try channel.pipeline.syncOperations.addHandler(ClosureObserver(state: state))
                }.flatMap {
                    HTTP2Pipeline.installNegotiation(on: channel) { selected, channel in
                        state.withLock { $0.negotiated.append(selected) }
                        guard selected == .http2 else {
                            return channel.eventLoop.makeCompletedFuture {
                                try channel.pipeline.syncOperations.addHandlers([
                                    HTTPResponseEncoder(), ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes)),
                                    OriginHandler(state: state, version: .http1_1),
                                ])
                            }
                        }
                        return HTTP2Pipeline.installServer(on: channel, limits: .init()) { child in
                            child.eventLoop.makeCompletedFuture {
                                try child.pipeline.syncOperations.addHandlers([
                                    HTTP2FramePayloadToHTTP1ServerCodec(), OriginHandler(state: state, version: .http2),
                                ])
                            }
                        }.flatMapThrowing {
                            // Frames reach the multiplexer here, RST_STREAM included.
                            let mux = try channel.pipeline.syncOperations.handler(type: HTTP2StreamMultiplexer.self)
                            try channel.pipeline.syncOperations.addHandler(ResetRecorder(state: state), position: .before(mux))
                        }
                    }.map { _ in () }
                }
            }.bind(host: "127.0.0.1", port: 0).get()
            return ComposeTLSOrigin(ca: ca, group: group, channel: channel, state: state)
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
    }

    func stop() async throws {
        try? await channel.close().get()
        try await group.shutdownGracefully()
    }

    private final class ClosureObserver: ChannelInboundHandler {
        typealias InboundIn = NIOAny
        let state: OSAllocatedUnfairLock<State>
        init(state: OSAllocatedUnfairLock<State>) { self.state = state }
        func channelInactive(context: ChannelHandlerContext) {
            state.withLock { $0.closed += 1 }
            context.fireChannelInactive()
        }
    }

    private final class ResetRecorder: ChannelInboundHandler {
        typealias InboundIn = HTTP2Frame
        typealias InboundOut = HTTP2Frame
        let state: OSAllocatedUnfairLock<State>
        init(state: OSAllocatedUnfairLock<State>) { self.state = state }
        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            if case .rstStream(let code) = unwrapInboundIn(data).payload { state.withLock { $0.resets.append(code) } }
            context.fireChannelRead(data)
        }
    }

    private final class OriginHandler: ChannelInboundHandler {
        typealias InboundIn = HTTPServerRequestPart
        typealias OutboundOut = HTTPServerResponsePart
        let state: OSAllocatedUnfairLock<State>
        let version: HTTPVersion
        private var path = ""
        init(state: OSAllocatedUnfairLock<State>, version: HTTPVersion) { self.state = state; self.version = version }
        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            switch unwrapInboundIn(data) {
            case .head(let head):
                path = head.uri
                state.withLock { [path] in $0.paths.append(path) }
            case .body: break
            case .end:
                guard path != "/hold" else { return }
                let body = ByteBuffer(string: "ok")
                let head = HTTPResponseHead(version: version, status: .ok, headers: HTTPHeaders([("Content-Length", "2")]))
                context.write(wrapOutboundOut(.head(head)), promise: nil)
                context.write(wrapOutboundOut(.body(.byteBuffer(body))), promise: nil)
                context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
            }
        }
        func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
    }
}
