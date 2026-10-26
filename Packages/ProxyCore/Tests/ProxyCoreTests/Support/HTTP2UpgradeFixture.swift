import NIOCore
import NIOPosix
import NIOSSL
import os
@testable import ProxyCore

/// RFC 6455 example key/accept pair and literal valid frames, never message inspection code.
enum HTTP2UpgradeWire {
    static let key = "dGhlIHNhbXBsZSBub25jZQ=="
    static let accept = "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
    static let response = Array("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n".utf8)
    static let greeting: [UInt8] = [0x81, 0x02, 0x48, 0x69]
    // Masked binary payload 00 ff 80 01, mask 12 34 56 78.
    static let clientFrame: [UInt8] = [0x82, 0x84, 0x12, 0x34, 0x56, 0x78, 0x12, 0xcb, 0xd6, 0x79]
    static let serverFrame: [UInt8] = [0x82, 0x04, 0x00, 0xff, 0x80, 0x01]
    static func request(target: String, port: Int) -> [UInt8] {
        Array("GET \(target) HTTP/1.1\r\nHost: localhost:\(port)\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\n\r\n".utf8)
    }

    final class Receiver: ChannelInboundHandler {
        typealias InboundIn = ByteBuffer
        let observe: ([UInt8]) -> Void
        var bytes: [UInt8] = []
        init(observe: @escaping ([UInt8]) -> Void) { self.observe = observe }
        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            let received = Array(unwrapInboundIn(data).readableBytesView)
            observe(received); bytes += received
            if bytes.count >= HTTP2UpgradeWire.clientFrame.count {
                guard bytes == HTTP2UpgradeWire.clientFrame else { context.close(promise: nil); return }
                context.channel.writeAndFlush(ByteBuffer(bytes: HTTP2UpgradeWire.serverFrame), promise: nil)
                bytes.removeAll()
            }
        }
    }
}

/// Keeps every byte (including invalid UTF-8) and uses explicit synthetic trust only.
final class HTTP2UpgradeClient: Sendable {
    let channel: Channel
    private let group: MultiThreadedEventLoopGroup
    private let received: OSAllocatedUnfairLock<[UInt8]>
    private init(channel: Channel, group: MultiThreadedEventLoopGroup, received: OSAllocatedUnfairLock<[UInt8]>) {
        self.channel = channel; self.group = group; self.received = received
    }
    static func connect(fixture: HTTP2ProxyFixture, origin: HTTP2TestOrigin, tls: Bool) async throws -> HTTP2UpgradeClient {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let loop = group.next()
        let received = OSAllocatedUnfairLock(initialState: [UInt8]())
        var opened: Channel?
        do {
            let connected = loop.makePromise(of: Void.self)
            let channel = try await ClientBootstrap(group: loop).channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    if tls { try channel.pipeline.syncOperations.addHandler(HTTP2ProxyConnectResponse(promise: connected)) }
                    else { connected.succeed(()) }
                }
            }.connect(host: "127.0.0.1", port: fixture.channel.localAddress!.port!).get()
            opened = channel
            if tls {
                try await channel.writeAndFlush(ByteBuffer(string: "CONNECT localhost:\(origin.port) HTTP/1.1\r\nHost: localhost:\(origin.port)\r\n\r\n")).get()
                try await connected.futureResult.boundedGet()
                let interception = TLSInterception(certificateAuthority: fixture.ca, applicationProtocols: ["http/1.1"])
                let roots = NIOSSLTrustRoots.certificates([try NIOSSLCertificate(bytes: fixture.ca.rootCertificateDER, format: .der)])
                let negotiation = try await loop.flatSubmit {
                    do {
                        try channel.pipeline.syncOperations.addHandler(interception.upstreamHandler(host: "localhost", trustRoots: roots, tunneled: false))
                        return HTTP2Pipeline.installNegotiation(on: channel) { _, channel in
                            channel.eventLoop.makeCompletedFuture {
                                try channel.pipeline.syncOperations.addHandler(Collector(received: received))
                            }
                        }
                    } catch { return loop.makeFailedFuture(error) }
                }.get()
                _ = try await loop.flatSubmit { negotiation.readyProtocol }.boundedGet()
            } else {
                try await connected.futureResult.get()
                try await loop.submit { try channel.pipeline.syncOperations.addHandler(Collector(received: received)) }.get()
            }
            return .init(channel: channel, group: group, received: received)
        } catch {
            if let opened { try? await opened.close().get() }
            try? await group.shutdownGracefully(); throw error
        }
    }
    func send(_ bytes: [UInt8]) async throws { try await channel.writeAndFlush(ByteBuffer(bytes: bytes)).get() }
    func receive(count: Int) async throws -> [UInt8] {
        try await waitUntil("literal upgraded bytes") { received.withLock { $0.count >= count } }
        return received.withLock { bytes in defer { bytes.removeFirst(count) }; return Array(bytes.prefix(count)) }
    }
    func receive(until marker: String) async throws -> String {
        let needle = Array(marker.utf8)
        var end: Int?
        try await waitUntil("HTTP response delimiter") {
            end = received.withLock { bytes in
                guard bytes.count >= needle.count else { return nil }
                return (0...(bytes.count - needle.count)).first { bytes[$0..<($0 + needle.count)].elementsEqual(needle) }.map { $0 + needle.count }
            }
            return end != nil
        }
        return String(decoding: try await receive(count: end!), as: UTF8.self)
    }
    func remainingBytes() -> [UInt8] { received.withLock { $0 } }
    func stop() async throws {
        try? await channel.close().get(); try await group.shutdownGracefully()
    }
    private final class Collector: ChannelInboundHandler {
        typealias InboundIn = ByteBuffer
        let received: OSAllocatedUnfairLock<[UInt8]>
        init(received: OSAllocatedUnfairLock<[UInt8]>) { self.received = received }
        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            let bytes = Array(unwrapInboundIn(data).readableBytesView)
            received.withLock { $0.append(contentsOf: bytes) }
        }
    }
}
