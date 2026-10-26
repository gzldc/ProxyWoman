import CertKit
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL
import os

/// A local origin server on 127.0.0.1 with fixed routes:
/// - `GET /hello` → text/plain "hello"
/// - `GET /json` → application/json `{"b":1,"a":[true,null]}`
/// - `POST /echo` → the request body and Content-Type
/// - `GET /status?code=N` → status N with the body "origin-body" (204 and 304 bodiless)
/// - `GET /big?mb=N` → N MiB of 0x61 with Content-Length
/// - `GET /slow` → chunked "first", then "second" 500 ms later
/// - `GET /close` → "bye" with `Connection: close`
/// - `GET /close-delimited-bytes?bytes=N` → an HTTP/1.0 response of N bytes of 0x62 without a length, then the origin closes at once
/// - `GET /ws` with `Upgrade: websocket` → 101 plus `wsGreeting` in one write, then echoes raw bytes
/// - `POST /early413` → 413 with `Connection: close` right after the head, without reading the body
final class TestOriginServer: Sendable {
    static let wsGreeting = "welcome"

    private let accepted: OSAllocatedUnfairLock<Int>
    var acceptedConnections: Int { accepted.withLock { $0 } }
    private let log: OSAllocatedUnfairLock<OriginLog>
    /// Every complete request head the origin parsed, in arrival order.
    var receivedRequests: [OriginRequest] { log.withLock { $0.requests } }
    var receivedRequestCount: Int { log.withLock { $0.requests.count } }
    /// The first `OriginLog.byteCap` bytes received on any connection (after TLS, if any), in arrival
    /// order, including raw bytes an upgraded (echo) connection receives.
    var receivedBytes: [UInt8] { log.withLock { $0.bytes } }
    let port: Int
    private let group: MultiThreadedEventLoopGroup
    private let channel: Channel

    private init(port: Int, group: MultiThreadedEventLoopGroup, channel: Channel, accepted: OSAllocatedUnfairLock<Int>,
                 log: OSAllocatedUnfairLock<OriginLog>) {
        self.accepted = accepted
        self.log = log
        self.port = port
        self.group = group
        self.channel = channel
    }

    static func start(tls: LeafIdentity? = nil, slowResponseBarrier: EventLoopFuture<Void>? = nil) async throws -> TestOriginServer {
        let accepted = OSAllocatedUnfairLock(initialState: 0)
        let log = OSAllocatedUnfairLock(initialState: OriginLog())
        let sslContext = try tls.map(makeSSLContext)
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        do {
            let channel = try await ServerBootstrap(group: group)
                .childChannelInitializer { channel in
                    accepted.withLock { $0 += 1 }
                    return channel.eventLoop.makeCompletedFuture {
                        let pipeline = channel.pipeline.syncOperations
                        if let sslContext {
                            try pipeline.addHandler(NIOSSLServerHandler(context: sslContext))
                        }
                        try pipeline.addHandlers([
                            OriginTap(log: log),
                            HTTPResponseEncoder(),
                            ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes)),
                            OriginHandler(slowResponseBarrier: slowResponseBarrier, log: log),
                        ])
                    }
                }
                .bind(host: "127.0.0.1", port: 0).get()
            guard let port = channel.localAddress?.port else {
                throw ChannelError.unknownLocalAddress
            }
            return TestOriginServer(port: port, group: group, channel: channel, accepted: accepted, log: log)
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
    }

    func stop() async throws {
        try? await channel.close().get()
        try await group.shutdownGracefully()
    }

    private static func makeSSLContext(_ identity: LeafIdentity) throws -> NIOSSLContext {
        var configuration = TLSConfiguration.makeServerConfiguration(
            certificateChain: [.certificate(try NIOSSLCertificate(bytes: identity.certificateDER, format: .der))],
            privateKey: .privateKey(try NIOSSLPrivateKey(bytes: identity.privateKeyDER, format: .der))
        )
        configuration.applicationProtocols = ["http/1.1"]
        return try NIOSSLContext(configuration: configuration)
    }
}

/// One request the origin parsed completely.
struct OriginRequest: Sendable {
    let head: HTTPRequestHead
    let body: [UInt8]
}

struct OriginLog: Sendable {
    /// Keeps large uploads in other tests from growing the log without bound.
    static let byteCap = 1 << 20
    var requests: [OriginRequest] = []
    var bytes: [UInt8] = []
}

/// Records the raw request bytes before any decoding; passes everything on unchanged.
private final class OriginTap: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer
    private let log: OSAllocatedUnfairLock<OriginLog>
    init(log: OSAllocatedUnfairLock<OriginLog>) { self.log = log }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let bytes = unwrapInboundIn(data)
        log.withLock { log in
            let room = OriginLog.byteCap - log.bytes.count
            if room > 0 { log.bytes.append(contentsOf: bytes.readableBytesView.prefix(room)) }
        }
        context.fireChannelRead(data)
    }
}

private final class OriginHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private static let mebibyte = ByteBuffer(repeating: 0x61, count: 1 << 20)

    private let slowResponseBarrier: EventLoopFuture<Void>?
    private let log: OSAllocatedUnfairLock<OriginLog>
    init(slowResponseBarrier: EventLoopFuture<Void>?, log: OSAllocatedUnfairLock<OriginLog>) {
        self.slowResponseBarrier = slowResponseBarrier
        self.log = log
    }

    private var head: HTTPRequestHead?
    private var body = ByteBuffer()
    /// Set after an early response: the rest of that request is ignored.
    private var ignoringRequest = false

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            if head.method == .POST, head.uri == "/early413" {
                ignoringRequest = true
                respondEarly413(context: context)
                return
            }
            self.head = head
            if head.uri.hasPrefix("/expect") {
                // Exercise actual interim encoding and client wait-before-upload behavior.
                if head.headers.contains(name: "expect") || head.uri == "/expect-duplicate" {
                    context.writeAndFlush(wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: .continue))), promise: nil)
                }
                if head.uri == "/expect-hints" {
                    for value in ["first", "second"] {
                        context.writeAndFlush(wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: .init(statusCode: 103),
                            headers: .init([("x-hint", value)])))), promise: nil)
                    }
                }
            }
            body.clear()
        case .body(var chunk):
            if !ignoringRequest { body.writeBuffer(&chunk) }
        case .end:
            if ignoringRequest {
                ignoringRequest = false
            } else if let head {
                let request = OriginRequest(head: head, body: Array(body.readableBytesView))
                log.withLock { $0.requests.append(request) }
                respond(to: head, context: context)
            }
            head = nil
        }
    }

    /// Malformed input (e.g. a TLS ClientHello sent to the plain-HTTP origin): hang up.
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }

    private func respondEarly413(context: ChannelHandlerContext) {
        var headers = HTTPHeaders([("Content-Type", "text/plain"), ("Content-Length", "9")])
        headers.add(name: "Connection", value: "close")
        context.write(wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: .payloadTooLarge, headers: headers))), promise: nil)
        context.write(wrapOutboundOut(.body(.byteBuffer(ByteBuffer(string: "too large")))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil))).assumeIsolated().whenComplete { _ in
            context.close(promise: nil)
        }
    }

    /// Writes the 101 and a greeting in one buffer, so whoever parses the 101 also receives bytes
    /// past it, then turns the connection into a raw echo.
    private func upgradeToEcho(context: ChannelHandlerContext) {
        let pipeline = context.pipeline.syncOperations
        do {
            let encoder = try pipeline.handler(type: HTTPResponseEncoder.self)
            let decoder = try pipeline.handler(type: ByteToMessageHandler<HTTPRequestDecoder>.self)
            try pipeline.addHandler(EchoHandler())
            pipeline.removeHandler(context: context, promise: nil)
            pipeline.removeHandler(encoder, promise: nil)
            pipeline.removeHandler(decoder, promise: nil)  // forwards any early bytes to the echo
            let response =
                "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n"
                + TestOriginServer.wsGreeting
            context.channel.writeAndFlush(ByteBuffer(string: response), promise: nil)
        } catch {
            context.close(promise: nil)
        }
    }

    private func respond(to head: HTTPRequestHead, context: ChannelHandlerContext) {
        let parts = head.uri.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let path = String(parts[0])
        let query = parts.count > 1 ? String(parts[1]) : ""

        switch (head.method, path) {
        case (.GET, "/ws") where head.headers.first(name: "upgrade")?.lowercased() == "websocket":
            upgradeToEcho(context: context)
        case (.GET, "/hello"):
            sendFull(ByteBuffer(string: "hello"), contentType: "text/plain", context: context)
        case (.GET, "/json"):
            sendFull(ByteBuffer(string: #"{"b":1,"a":[true,null]}"#), contentType: "application/json", context: context)
        case (.POST, "/echo"), (.POST, "/expect"), (.POST, "/expect-duplicate"), (.POST, "/expect-hints"):
            let type = head.headers.first(name: "content-type") ?? "application/octet-stream"
            sendFull(body, contentType: type, context: context)
        case (.GET, "/status"):
            // `?code=N`: that status with the body "origin-body"; 204 and 304 carry neither body nor length.
            let code = query.split(separator: "&")
                .compactMap { $0.hasPrefix("code=") ? Int($0.dropFirst(5)) : nil }.first ?? 200
            if code == 204 || code == 304 {
                context.write(wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: .init(statusCode: code)))), promise: nil)
                context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
            } else {
                sendFull(ByteBuffer(string: "origin-body"), contentType: "text/plain", status: .init(statusCode: code), context: context)
            }
        case (.GET, "/big"):
            let megabytes = query.split(separator: "&")
                .compactMap { $0.hasPrefix("mb=") ? Int($0.dropFirst(3)) : nil }.first ?? 1
            sendBig(megabytes: megabytes, context: context)
        case (.GET, "/slow"):
            sendSlow(context: context)
        case (.GET, "/opaque-full-body"), (.GET, "/opaque-compound-full-body"):
            // Literal bytes bypass the fixture encoder: no implicit chunking or transfer decoding.
            do {
                let encoder = try context.pipeline.syncOperations.context(handlerType: HTTPResponseEncoder.self)
                let compound = path == "/opaque-compound-full-body"
                let wire = compound ? "HTTP/1.1 200 OK\r\nTransfer-Encoding: gzip, chunked\r\n\r\n6\r\nopaque\r\n0\r\n\r\n"
                    : "HTTP/1.1 200 OK\r\nTransfer-Encoding: gzip\r\n\r\nopaque"
                encoder.writeAndFlush(NIOAny(ByteBuffer(string: wire))).assumeIsolated().whenComplete { _ in context.close(promise: nil) }
            } catch { context.close(promise: nil) }
        case (.GET, "/close-delimited-10"):
            context.write(wrapOutboundOut(.head(HTTPResponseHead(version: .http1_0, status: .ok, headers: HTTPHeaders()))), promise: nil)
            context.write(wrapOutboundOut(.body(.byteBuffer(ByteBuffer(string: "complete after EOF")))), promise: nil)
            context.writeAndFlush(wrapOutboundOut(.end(nil))).assumeIsolated().whenComplete { _ in context.close(promise: nil) }
        case (.GET, "/close-delimited-bytes"):
            let count = query.split(separator: "&")
                .compactMap { $0.hasPrefix("bytes=") ? Int($0.dropFirst(6)) : nil }.first ?? 1_000
            context.write(wrapOutboundOut(.head(HTTPResponseHead(version: .http1_0, status: .ok, headers: HTTPHeaders()))), promise: nil)
            context.write(wrapOutboundOut(.body(.byteBuffer(ByteBuffer(repeating: 0x62, count: count)))), promise: nil)
            context.writeAndFlush(wrapOutboundOut(.end(nil))).assumeIsolated().whenComplete { _ in context.close(promise: nil) }
        case (.GET, "/close"):
            var headers = HTTPHeaders([("Content-Type", "text/plain"), ("Content-Length", "3")])
            headers.add(name: "Connection", value: "close")
            context.write(wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: .ok, headers: headers))), promise: nil)
            context.write(wrapOutboundOut(.body(.byteBuffer(ByteBuffer(string: "bye")))), promise: nil)
            context.writeAndFlush(wrapOutboundOut(.end(nil))).assumeIsolated().whenComplete { _ in
                context.close(promise: nil)
            }
        default:
            sendFull(ByteBuffer(string: "not found"), contentType: "text/plain", status: .notFound, context: context)
        }
    }

    private func sendFull(
        _ body: ByteBuffer, contentType: String, status: HTTPResponseStatus = .ok, context: ChannelHandlerContext
    ) {
        let headers = HTTPHeaders([("Content-Type", contentType), ("Content-Length", String(body.readableBytes))])
        context.write(wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: status, headers: headers))), promise: nil)
        context.write(wrapOutboundOut(.body(.byteBuffer(body))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }

    private func sendBig(megabytes: Int, context: ChannelHandlerContext) {
        let headers = HTTPHeaders([
            ("Content-Type", "application/octet-stream"), ("Content-Length", String(megabytes << 20)),
        ])
        context.writeAndFlush(wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: .ok, headers: headers))), promise: nil)
        sendMebibytes(remaining: megabytes, context: context)
    }

    /// One MiB at a time, each after the previous one reached the socket, so memory stays bounded.
    private func sendMebibytes(remaining: Int, context: ChannelHandlerContext) {
        guard remaining > 0 else {
            context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
            return
        }
        context.writeAndFlush(wrapOutboundOut(.body(.byteBuffer(Self.mebibyte))))
            .assumeIsolated()
            .whenSuccess { self.sendMebibytes(remaining: remaining - 1, context: context) }
    }

    private func sendSlow(context: ChannelHandlerContext) {
        let headers = HTTPHeaders([("Content-Type", "text/plain")])  // no length: the encoder chunks it
        context.write(wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: .ok, headers: headers))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.body(.byteBuffer(ByteBuffer(string: "first")))), promise: nil)
        if let slowResponseBarrier {
            // Test-controlled completion must return to this origin connection's owner loop.
            slowResponseBarrier.hop(to: context.eventLoop).assumeIsolated().whenComplete { result in
                switch result {
                case .success: self.finishSlow(context: context)
                case .failure: context.close(promise: nil)
                }
            }
        } else {
            context.eventLoop.assumeIsolated().scheduleTask(in: .milliseconds(500)) {
                self.finishSlow(context: context)
            }
        }
    }

    private func finishSlow(context: ChannelHandlerContext) {
        guard context.channel.isActive else { return }
        context.write(wrapOutboundOut(.body(.byteBuffer(ByteBuffer(string: "second")))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }
}

private final class EchoHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        context.writeAndFlush(wrapOutboundOut(unwrapInboundIn(data)), promise: nil)
    }
}
