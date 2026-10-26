import CertKit
import FlowStore
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import os
import ProxyCore
import RulesEngine
@testable import AppCore

struct FixtureTimeout: Error, CustomStringConvertible {
    let what: String
    var description: String { "timed out waiting for \(what)" }
}

/// A one-shot latch; later resumes are ignored.
final class Latch: Sendable {
    private let state = OSAllocatedUnfairLock<(Bool?, CheckedContinuation<Bool, Never>?)>(initialState: (nil, nil))

    func resume(_ value: Bool) {
        let continuation = state.withLock { state -> CheckedContinuation<Bool, Never>? in
            guard state.0 == nil else { return nil }
            state.0 = value
            defer { state.1 = nil }
            return state.1
        }
        continuation?.resume(returning: value)
    }

    func value() async -> Bool {
        await withCheckedContinuation { continuation in
            let ready = state.withLock { state -> Bool? in
                if let value = state.0 { return value }
                state.1 = continuation
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }
}

/// Waits (refresh by refresh, never by sleeping) until `condition` holds, failing after `timeout`.
@MainActor
func waitUntil(_ model: BreakpointQueueModel, _ what: String, timeout: Duration = .seconds(10),
               _ condition: @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    defer { model.refreshObserver = nil }
    while !condition() {
        guard ContinuousClock.now < deadline else { throw FixtureTimeout(what: what) }
        let latch = Latch()
        model.refreshObserver = { latch.resume(true) }
        if condition() { return }
        let timer = Task { try? await Task.sleep(until: deadline); latch.resume(false) }
        let refreshed = await latch.value()
        timer.cancel()
        guard refreshed || condition() else { throw FixtureTimeout(what: what) }
    }
}

struct OriginRequest: Sendable {
    var method: String
    var uri: String
    var headers: [HeaderField]
}

/// A loopback HTTP/1.1 origin that records each request head and answers `200 origin-ok`.
final class LoopbackOrigin: Sendable {
    let port: Int
    private let group: MultiThreadedEventLoopGroup
    private let channel: Channel
    private let received: OSAllocatedUnfairLock<[OriginRequest]>
    private let receivedBodies: OSAllocatedUnfairLock<[[UInt8]]>
    private let stream: AsyncStream<OriginRequest>
    private let accepted: OSAllocatedUnfairLock<Int>

    private init(port: Int, group: MultiThreadedEventLoopGroup, channel: Channel,
                 received: OSAllocatedUnfairLock<[OriginRequest]>, bodies: OSAllocatedUnfairLock<[[UInt8]]>,
                 stream: AsyncStream<OriginRequest>, accepted: OSAllocatedUnfairLock<Int>) {
        self.port = port; self.group = group; self.channel = channel; self.received = received
        self.receivedBodies = bodies; self.stream = stream; self.accepted = accepted
    }

    /// Connections the origin has accepted so far.
    var connections: Int { accepted.withLock { $0 } }

    var requests: [OriginRequest] { received.withLock { $0 } }
    /// The complete body of each request, appended when its end arrived.
    var bodies: [[UInt8]] { receivedBodies.withLock { $0 } }

    static func start() async throws -> LoopbackOrigin {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let received = OSAllocatedUnfairLock<[OriginRequest]>(initialState: [])
        let bodies = OSAllocatedUnfairLock<[[UInt8]]>(initialState: [])
        let (stream, continuation) = AsyncStream.makeStream(of: OriginRequest.self)
        let accepted = OSAllocatedUnfairLock(initialState: 0)
        do {
            let channel = try await ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { channel in
                    accepted.withLock { $0 += 1 }
                    return channel.pipeline.configureHTTPServerPipeline().flatMap {
                        channel.pipeline.addHandler(OriginHandler(received: received, bodies: bodies, continuation: continuation))
                    }
                }
                .bind(host: "127.0.0.1", port: 0).get()
            let port = try require(channel.localAddress?.port)
            return LoopbackOrigin(port: port, group: group, channel: channel, received: received, bodies: bodies,
                                  stream: stream, accepted: accepted)
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
    }

    func awaitRequest(timeout: Duration = .seconds(10)) async throws -> OriginRequest {
        let stream = self.stream
        return try await withThrowingTaskGroup(of: OriginRequest?.self) { group in
            group.addTask { for await request in stream { return request }; return nil }
            group.addTask { try await Task.sleep(for: timeout); return nil }
            defer { group.cancelAll() }
            guard let first = try await group.next(), let request = first else { throw FixtureTimeout(what: "an origin request") }
            return request
        }
    }

    func stop() async {
        try? await channel.close().get()
        try? await group.shutdownGracefully()
    }

    private final class OriginHandler: ChannelInboundHandler, Sendable {
        typealias InboundIn = HTTPServerRequestPart
        typealias OutboundOut = HTTPServerResponsePart
        let received: OSAllocatedUnfairLock<[OriginRequest]>
        let bodies: OSAllocatedUnfairLock<[[UInt8]]>
        let body = OSAllocatedUnfairLock<[UInt8]>(initialState: [])
        let continuation: AsyncStream<OriginRequest>.Continuation

        init(received: OSAllocatedUnfairLock<[OriginRequest]>, bodies: OSAllocatedUnfairLock<[[UInt8]]>,
             continuation: AsyncStream<OriginRequest>.Continuation) {
            self.received = received; self.bodies = bodies; self.continuation = continuation
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            switch unwrapInboundIn(data) {
            case .head(let head):
                let request = OriginRequest(method: head.method.rawValue, uri: head.uri,
                                            headers: head.headers.map { HeaderField(name: $0.name, value: $0.value) })
                received.withLock { $0.append(request) }
                continuation.yield(request)
            case .body(let buffer): body.withLock { $0 += Array(buffer.readableBytesView) }
            case .end:
                let complete = body.withLock { body in defer { body = [] }; return body }
                bodies.withLock { $0.append(complete) }
                var headers = HTTPHeaders()
                headers.add(name: "Content-Length", value: "9")
                headers.add(name: "Connection", value: "close")
                context.write(wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: .ok, headers: headers))), promise: nil)
                context.write(wrapOutboundOut(.body(.byteBuffer(ByteBuffer(string: "origin-ok")))), promise: nil)
                let bound = NIOLoopBound(context, eventLoop: context.eventLoop)
                context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in bound.value.close(promise: nil) }
            }
        }
    }
}

/// Raw bytes to and from the proxy.
final class LoopbackClient: Sendable {
    private let group: MultiThreadedEventLoopGroup
    private let channel: Channel
    private let received: OSAllocatedUnfairLock<[UInt8]>
    private let closed: Latch

    private init(group: MultiThreadedEventLoopGroup, channel: Channel, received: OSAllocatedUnfairLock<[UInt8]>, closed: Latch) {
        self.group = group; self.channel = channel; self.received = received; self.closed = closed
    }

    static func connect(port: Int) async throws -> LoopbackClient {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let received = OSAllocatedUnfairLock<[UInt8]>(initialState: [])
        let closed = Latch()
        do {
            let channel = try await ClientBootstrap(group: group)
                .channelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.addHandler(Collector(received: received, closed: closed))
                    }
                }
                .connect(host: "127.0.0.1", port: port).get()
            return LoopbackClient(group: group, channel: channel, received: received, closed: closed)
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
    }

    func send(_ text: String) async throws {
        try await channel.writeAndFlush(ByteBuffer(string: text)).get()
    }

    /// Everything the proxy sent until it closed the connection.
    func responseUntilClose(timeout: Duration = .seconds(10)) async throws -> String {
        let closed = self.closed
        let timer = Task { try? await Task.sleep(for: timeout); closed.resume(false) }
        let didClose = await closed.value()
        timer.cancel()
        guard didClose else { throw FixtureTimeout(what: "the proxy to close the client connection") }
        return String(decoding: received.withLock { $0 }, as: UTF8.self)
    }

    /// The raw bytes the proxy sent until it closed the connection (binary bodies stay intact).
    func bytesUntilClose(timeout: Duration = .seconds(20)) async throws -> [UInt8] {
        let closed = self.closed
        let timer = Task { try? await Task.sleep(for: timeout); closed.resume(false) }
        let didClose = await closed.value()
        timer.cancel()
        guard didClose else { throw FixtureTimeout(what: "the proxy to close the client connection") }
        return received.withLock { $0 }
    }

    func close() async {
        try? await channel.close().get()
        try? await group.shutdownGracefully()
    }

    private final class Collector: ChannelInboundHandler, Sendable {
        typealias InboundIn = ByteBuffer
        let received: OSAllocatedUnfairLock<[UInt8]>
        let closed: Latch

        init(received: OSAllocatedUnfairLock<[UInt8]>, closed: Latch) { self.received = received; self.closed = closed }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            let bytes = Array(buffer: unwrapInboundIn(data))
            received.withLock { $0.append(contentsOf: bytes) }
        }

        func channelInactive(context: ChannelHandlerContext) {
            closed.resume(true)
            context.fireChannelInactive()
        }
    }
}

/// A real ProxyServer with one breakpoint rule and the single coordinator the bridge wraps.
struct BridgeHarness {
    let root: URL
    let store: FlowStore
    let coordinator: BreakpointCoordinator
    let server: ProxyServer
    let proxyPort: Int

    static func start(rules: [Rule]) async throws -> BridgeHarness {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pw-bridge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = FlowStore(bodyDirectory: root.appendingPathComponent("Bodies"))
        let limits = RulesLimits()
        let coordinator = BreakpointCoordinator(limits: limits)
        var configuration = ProxyConfiguration()
        configuration.port = 0
        configuration.portFallbackCount = 0
        let provider = RuleSnapshotProvider(RuleSnapshot(revision: 1, rules: rules))
        let server = ProxyServer(
            configuration: configuration, certificateAuthority: try CertificateAuthority.generate(), store: store,
            passthrough: PassthroughRegistry(), processLookup: .none, rules: provider, breakpoints: coordinator,
            breakpointSpoolDirectory: root.appendingPathComponent("Spool"))
        do {
            try await server.start()
            let port = try require(server.boundPort)
            return BridgeHarness(root: root, store: store, coordinator: coordinator, server: server, proxyPort: port)
        } catch {
            try? await server.stop()
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    func stop() async {
        try? await server.stop()
        try? FileManager.default.removeItem(at: root)
    }
}

private func require<T>(_ value: T?) throws -> T {
    guard let value else { throw FixtureTimeout(what: "a required value") }
    return value
}
