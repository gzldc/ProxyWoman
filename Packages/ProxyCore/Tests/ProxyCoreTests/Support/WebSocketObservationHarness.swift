import Foundation
import FlowStore
import NIOCore
import NIOHTTP1
import NIOEmbedded
import Testing
@testable import ProxyCore

actor WSBarrier {
    private var reached = false
    private var open = false
    private var observers: [CheckedContinuation<Void, Never>] = []
    private var workers: [CheckedContinuation<Void, Never>] = []
    func enter() async {
        reached = true
        let notify = observers; observers.removeAll(); notify.forEach { $0.resume() }
        notifyTimed()
        if !open { await withCheckedContinuation { workers.append($0) } }
    }
    func wait() async { if !reached { await withCheckedContinuation { observers.append($0) } } }
    func release() {
        open = true; let pending = workers; workers.removeAll(); pending.forEach { $0.resume() }
    }
    private var timed: [UUID: CheckedContinuation<Void, Error>] = [:]
    /// Bounded form of `wait()`: throws `WaitTimeout` (and drops its continuation) if `enter()`
    /// is not reached in time. Cancellation of the timer never resumes the waiter twice.
    func wait(timeout: Duration, _ what: String = "barrier") async throws {
        guard !reached else { return }
        let id = UUID()
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            await self?.expire(id, "timed out after \(timeout) waiting for \(what)")
        }
        defer { timer.cancel() }
        try await withCheckedThrowingContinuation { timed[id] = $0; if reached { notifyTimed() } }
    }
    private func expire(_ id: UUID, _ description: String) {
        timed.removeValue(forKey: id)?.resume(throwing: WaitTimeout(description: description))
    }
    private func notifyTimed() { let ready = timed; timed.removeAll(); ready.values.forEach { $0.resume() } }
}
func observationStore(_ limits: WebSocketLimits = .init()) -> FlowStore {
    FlowStore(bodyDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), webSocketLimits: limits)
}
func observationFlow(_ store: FlowStore) -> Int {
    store.begin { Flow(id: $0, scheme: "http", method: "GET", host: "synthetic.test", port: 80, path: "/ws") }
}
func observationHeads() -> (HTTPRequestHead, HTTPResponseHead) {
    (.init(version: .http1_1, method: .GET, uri: "http://synthetic.test/ws", headers: [
        "Host": "synthetic.test", "Connection": "Upgrade", "Upgrade": "websocket",
        "Sec-WebSocket-Version": "13", "Sec-WebSocket-Key": "dGhlIHNhbXBsZSBub25jZQ=="]),
     .init(version: .http1_1, status: .switchingProtocols, headers: ["Connection": "Upgrade", "Upgrade": "websocket",
        "Sec-WebSocket-Accept": "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="]))
}

actor WSProgress {
    private var count = 0
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    func advance() {
        count += 1
        let ready = waiters.filter { $0.0 <= count }; waiters.removeAll { $0.0 <= count }
        for (_, waiter) in ready { waiter.resume() }
        resumeTimed()
    }
    func wait(_ value: Int) async { if count < value { await withCheckedContinuation { waiters.append((value, $0)) } } }
    private var timed: [UUID: (Int, CheckedContinuation<Void, Error>)] = [:]
    /// Bounded form of `wait(_:)`: throws `WaitTimeout` if `value` advances are not reached in time.
    func wait(_ value: Int, timeout: Duration) async throws {
        guard count < value else { return }
        let id = UUID()
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            await self?.expire(id, "timed out after \(timeout) waiting for \(value) progress steps")
        }
        defer { timer.cancel() }
        try await withCheckedThrowingContinuation { timed[id] = (value, $0); resumeTimed() }
    }
    private func expire(_ id: UUID, _ description: String) {
        timed.removeValue(forKey: id)?.1.resume(throwing: WaitTimeout(description: description))
    }
    private func resumeTimed() {
        for (id, entry) in timed where entry.0 <= count { timed.removeValue(forKey: id); entry.1.resume() }
    }
}
func wsFrame(_ payload: [UInt8], opcode: UInt8 = 1, fin: Bool = true, masked: Bool = false, compressed: Bool = false) -> ByteBuffer {
    var bytes: [UInt8] = [(fin ? 0x80 : 0) | (compressed ? 0x40 : 0) | opcode]
    let bit: UInt8 = masked ? 0x80 : 0
    if payload.count < 126 { bytes.append(bit | UInt8(payload.count)) }
    else { bytes += [bit | 126, UInt8((payload.count >> 8) & 255), UInt8(payload.count & 255)] }
    if masked { bytes += [1, 2, 3, 4]; bytes += payload.enumerated().map { $0.element ^ [1, 2, 3, 4][$0.offset % 4] } }
    else { bytes += payload }
    return ByteBuffer(bytes: bytes)
}

/// Only accessed on one EmbeddedEventLoop; returns copied value traces before crossing await.
final class WSWireTrace: ChannelOutboundHandler {
    typealias OutboundIn = IOData
    var bytes: [UInt8] = []
    var flushes = 0
    var closes = 0
    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        if case .byteBuffer(let buffer) = unwrapOutboundIn(data) { bytes += buffer.readableBytesView }
        context.write(data, promise: promise)
    }
    func flush(context: ChannelHandlerContext) { flushes += 1; context.flush() }
    func close(context: ChannelHandlerContext, mode: NIOCore.CloseMode, promise: EventLoopPromise<Void>?) {
        closes += 1; context.close(mode: mode, promise: promise)
    }
}
final class WSSynchronousGate: @unchecked Sendable {
    // The condition protects both flags. It is used solely as an explicit test scheduling barrier.
    private let condition = NSCondition()
    private var reached = false
    private var released = false
    func enter() { condition.lock(); reached = true; condition.broadcast(); while !released { condition.wait() }; condition.unlock() }
    func wait() { condition.lock(); while !reached { condition.wait() }; condition.unlock() }
    func wait(timeout: TimeInterval) -> Bool {
        condition.lock(); defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while !reached { if !condition.wait(until: deadline) { return reached } }
        return true
    }
    func release() { condition.lock(); released = true; condition.broadcast(); condition.unlock() }
}

import Atomics
import CertKit
import NIOPosix
import NIOSSL
import os

/// Real production CONNECT/TLS/HTTP1 handoff, with existing factory channels retained for identity reads.
final class WSTLSIdentityFixture: Sendable {
    let listener: Channel
    let store: FlowStore
    let ca: CertificateAuthority
    let downstreams: OSAllocatedUnfairLock<[Channel]>
    let upstreams: OSAllocatedUnfairLock<[Channel]>
    let coordinator: WebSocketCaptureCoordinator
    private let group: MultiThreadedEventLoopGroup
    private let workers: NIOThreadPool
    private init(listener: Channel, store: FlowStore, ca: CertificateAuthority,
                 downstreams: OSAllocatedUnfairLock<[Channel]>, upstreams: OSAllocatedUnfairLock<[Channel]>,
                 coordinator: WebSocketCaptureCoordinator, group: MultiThreadedEventLoopGroup, workers: NIOThreadPool) {
        self.listener = listener; self.store = store; self.ca = ca
        self.downstreams = downstreams; self.upstreams = upstreams; self.coordinator = coordinator
        self.group = group; self.workers = workers
    }
    static func start(origin: HTTP2TestOrigin, progress: WSProgress) async throws -> WSTLSIdentityFixture {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1), workers = NIOThreadPool(numberOfThreads: 1)
        workers.start()
        let store = observationStore(), ca = try CertificateAuthority.generate(commonName: "WS identity fixture CA")
        let downstreams = OSAllocatedUnfairLock(initialState: [Channel]()), upstreams = OSAllocatedUnfairLock(initialState: [Channel]())
        let recording = FlowRecording(store: store, isEnabled: ManagedAtomic(true))
        let coordinator = WebSocketCaptureCoordinator(store: store, hooks: .init(afterChunk: { await progress.advance() }), controller: recording.webSocketController)
        var config = ProxyConfiguration()
        config.upstreamTrustRoots = .certificates([try NIOSSLCertificate(bytes: origin.ca.rootCertificateDER, format: .der)])
        let environment = ProxyEnvironment(configuration: config, recording: recording,
            tls: TLSInterception(certificateAuthority: ca), passthrough: .init(),
            clientLookup: ClientLookupBatcher(processLookup: .none, threadPool: workers), webSockets: coordinator)
        do {
            let listener = try await ServerBootstrap(group: group).childChannelInitializer { child in
                downstreams.withLock { $0.append(child) }
                return child.eventLoop.makeCompletedFuture {
                    let connection = ClientConnectionContext(channel: child, environment: environment,
                        clientLookup: child.eventLoop.makeSucceededFuture(nil), connectionFactory: { host, port, loop in
                            ClientBootstrap(group: loop).connect(host: host, port: port).map { upstream in
                                upstreams.withLock { $0.append(upstream) }; return upstream
                            }
                        })
                    try child.pipeline.syncOperations.addHandlers([
                        HTTPMessageTranslation.responseEncoder(), HTTP1TransferCodingFramer<HTTPResponseHead>(),
                        ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes)),
                        ProxyHandler(mode: .forwardProxy, environment: environment, inheritedConnection: connection),
                    ])
                }
            }.bind(host: "127.0.0.1", port: 0).get()
            return .init(listener: listener, store: store, ca: ca, downstreams: downstreams, upstreams: upstreams,
                coordinator: coordinator, group: group, workers: workers)
        } catch {
            await coordinator.shutdown(); try? await workers.shutdownGracefully(); try? await group.shutdownGracefully(); throw error
        }
    }
    func stop() async throws {
        try? await listener.close().get()
        for channel in downstreams.withLock({ $0 }) + upstreams.withLock({ $0 }) { try? await channel.close().get() }
        await coordinator.shutdown()
        try await workers.shutdownGracefully(); try await group.shutdownGracefully()
    }
}
