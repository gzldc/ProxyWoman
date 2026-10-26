import Foundation
import NIOCore
import NIOPosix
import NIOSSL
import NIOTLS
import os

/// A raw TCP client for speaking hand-written bytes to the proxy.
final class RawClient: Sendable {
    private let group: MultiThreadedEventLoopGroup
    private let channel: Channel
    private let received: OSAllocatedUnfairLock<[UInt8]>
    private let errors: OSAllocatedUnfairLock<[String]>

    private init(group: MultiThreadedEventLoopGroup, channel: Channel, received: OSAllocatedUnfairLock<[UInt8]>,
                 errors: OSAllocatedUnfairLock<[String]>) {
        self.group = group
        self.channel = channel
        self.received = received
        self.errors = errors
    }

    /// `receiveBufferSize` fixes the kernel receive buffer (disabling autotuning) so a paused
    /// reader exerts backpressure after a small, bounded amount of data.
    static func connect(port: Int, receiveBufferSize: Int? = nil) async throws -> RawClient {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let received = OSAllocatedUnfairLock<[UInt8]>(initialState: [])
        let errors = OSAllocatedUnfairLock<[String]>(initialState: [])
        do {
            var bootstrap = ClientBootstrap(group: group)
            if let receiveBufferSize {
                bootstrap = bootstrap.channelOption(ChannelOptions.socketOption(.so_rcvbuf), value: SocketOptionValue(receiveBufferSize))
            }
            let channel = try await bootstrap
                .channelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.addHandler(Collector(received: received, errors: errors))
                    }
                }
                .connect(host: "127.0.0.1", port: port).get()
            return RawClient(group: group, channel: channel, received: received, errors: errors)
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
    }

    func send(_ string: String) async throws {
        try await channel.writeAndFlush(ByteBuffer(string: string)).get()
    }

    /// Sends arbitrary bytes, including invalid UTF-8, in one write.
    func send(bytes: [UInt8]) async throws {
        try await channel.writeAndFlush(ByteBuffer(bytes: bytes)).get()
    }

    /// Waits for and consumes exactly `count` received bytes.
    func receive(count: Int, timeout: Duration = .seconds(5)) async throws -> [UInt8] {
        try await waitUntil(timeout: timeout, "\(count) bytes from the proxy") { received.withLock { $0.count >= count } }
        return received.withLock { bytes in defer { bytes.removeFirst(count) }; return Array(bytes.prefix(count)) }
    }

    /// Bytes received but not yet consumed.
    func remainingBytes() -> [UInt8] { received.withLock { $0 } }

    /// The errors the connection reported (TLS included), described, in order.
    var observedErrors: [String] { errors.withLock { $0 } }

    /// Stops or resumes reading from the socket (a stalled receiver).
    func setReading(_ enabled: Bool) async throws {
        try await channel.setOption(ChannelOptions.autoRead, value: enabled).get()
    }

    var isActive: Bool { channel.isActive }

    /// Starts TLS on the connection (e.g. after a CONNECT was answered) and waits for the
    /// handshake. Bytes received afterwards are the decrypted stream.
    func startTLS(trustRoots: NIOSSLTrustRoots, serverName: String) async throws {
        var configuration = TLSConfiguration.makeClientConfiguration()
        configuration.trustRoots = trustRoots
        configuration.applicationProtocols = ["http/1.1"]
        let context = try NIOSSLContext(configuration: configuration)
        let handshake = channel.eventLoop.makePromise(of: Void.self)
        let channel = self.channel
        channel.eventLoop.execute {
            do {
                let pipeline = channel.pipeline.syncOperations
                let tls = try NIOSSLClientHandler(context: context, serverHostname: serverName)
                try pipeline.addHandler(tls, position: .first)
                try pipeline.addHandler(HandshakeWaiter(promise: handshake), position: .after(tls))
            } catch {
                handshake.fail(error)
            }
        }
        try await handshake.futureResult.get()
    }

    /// Waits until the bytes received so far contain `marker`, then returns (and consumes)
    /// everything up to and including it.
    func receive(until marker: String, timeout: Duration = .seconds(5)) async throws -> String {
        let needle = Array(marker.utf8)
        var result: [UInt8]?
        try await waitUntil(timeout: timeout, "\(marker.debugDescription) from the proxy") {
            result = received.withLock { bytes in
                guard let end = Self.endOfFirstMatch(of: needle, in: bytes) else { return nil }
                defer { bytes.removeFirst(end) }
                return Array(bytes[..<end])
            }
            return result != nil
        }
        return String(decoding: result!, as: UTF8.self)
    }

    /// Waits until the peer closed the connection.
    func waitUntilClosed(timeout: Duration = .seconds(5)) async throws {
        try await waitUntil(timeout: timeout, "the proxy to close the connection") { !channel.isActive }
    }

    func close() async throws {
        try? await channel.close().get()
        try await group.shutdownGracefully()
    }

    private static func endOfFirstMatch(of needle: [UInt8], in haystack: [UInt8]) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        for start in 0...(haystack.count - needle.count)
        where haystack[start..<(start + needle.count)].elementsEqual(needle) {
            return start + needle.count
        }
        return nil
    }
}

private final class Collector: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    private let received: OSAllocatedUnfairLock<[UInt8]>
    private let errors: OSAllocatedUnfairLock<[String]>

    init(received: OSAllocatedUnfairLock<[UInt8]>, errors: OSAllocatedUnfairLock<[String]>) {
        self.received = received
        self.errors = errors
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        received.withLock { $0.append(contentsOf: buffer.readableBytesView) }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        errors.withLock { $0.append(String(describing: error)) }
        context.fireErrorCaught(error)
    }
}

/// Completes `promise` when the TLS handshake finishes, or fails it if the connection breaks first.
private final class HandshakeWaiter: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    private let promise: EventLoopPromise<Void>

    init(promise: EventLoopPromise<Void>) {
        self.promise = promise
    }

    func handlerAdded(context: ChannelHandlerContext) {
        if !context.channel.isActive { promise.fail(ChannelError.eof) }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if case TLSUserEvent.handshakeCompleted = event { promise.succeed() }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        promise.fail(error)
        context.fireErrorCaught(error)
    }

    func channelInactive(context: ChannelHandlerContext) {
        promise.fail(ChannelError.eof)
        context.fireChannelInactive()
    }
}
