import NIOCore
import NIOHTTP2
import Testing
@testable import ProxyCore

/// Payload/control operations only; production session and pool own every quota.
enum HTTP2FlowControlFixture {
    static func credit(_ request: HTTP2TestClient.PendingRequest, parent: Channel, bytes: Int) async throws {
        let id = try await request.channel.getOption(HTTP2StreamChannelOptions.streamID).boundedGet()
        try await parent.writeAndFlush(HTTP2Frame(streamID: id, payload: .windowUpdate(windowSizeIncrement: bytes))).boundedGet()
    }
    static func ping(_ parent: Channel) async throws {
        let result = try await parent.eventLoop.submit {
            let promise = parent.eventLoop.makePromise(of: Void.self)
            let observer = try parent.pipeline.syncOperations.handler(type: HTTP2ConnectionObserver.self)
            try parent.pipeline.syncOperations.addHandler(PingBarrier(promise: promise), position: .before(observer))
            parent.writeAndFlush(HTTP2Frame(streamID: .rootStream, payload: .ping(.init(withInteger: 42), ack: false)), promise: nil)
            return promise.futureResult
        }.boundedGet()
        try await result.boundedGet()
    }
    static func snapshot(_ fixture: HTTP2ProxyFixture) async throws -> ClientConnectionSnapshot {
        let owner = try #require(fixture.connections.withLock { $0.first })
        return try await fixture.channel.eventLoop.submit { owner.value.snapshot }.boundedGet()
    }
}

private final class PingBarrier: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTP2Frame
    let promise: EventLoopPromise<Void>
    var done = false
    init(promise: EventLoopPromise<Void>) { self.promise = promise }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        if case .ping(let bytes, ack: true) = unwrapInboundIn(data).payload, bytes == HTTP2PingData(withInteger: 42), !done {
            done = true
            promise.succeed(())
            context.pipeline.syncOperations.removeHandler(self, promise: nil)
        }
        context.fireChannelRead(data)
    }
    func channelInactive(context: ChannelHandlerContext) {
        if !done { done = true; promise.fail(HTTPTransportError.closed) }
        context.fireChannelInactive()
    }
}

enum HTTP2FixtureDeadlineExceeded: Error { case exceeded }

extension EventLoopFuture where Value: Sendable {
    /// Bounded failure deadline, never a sleep or a race-ordering mechanism.
    func boundedGet() async throws -> Value {
        let loop = eventLoop
        return try await loop.flatSubmit {
            let completion = FixtureDeadlineCompletion<Value>(loop: loop)
            let timer = loop.assumeIsolated().scheduleTask(in: .seconds(5)) {
                completion.finish(.failure(HTTP2FixtureDeadlineExceeded.exceeded))
            }
            self.assumeIsolated().whenComplete { result in
                timer.cancel()
                completion.finish(result)
            }
            return completion.promise.futureResult
        }.get()
    }
}

private final class FixtureDeadlineCompletion<Value: Sendable> {
    let promise: EventLoopPromise<Value>
    private var done = false
    init(loop: EventLoop) { promise = loop.makePromise() }
    func finish(_ result: Result<Value, Error>) {
        guard !done else { return }
        done = true
        promise.completeWith(result)
    }
}

/// Retains actual mux writes before the parent HTTP/2 encoder, so NIO's own child
/// write-promise accounting changes writability without consuming peer flow credit.
final class HTTP2FrameWriteGate: ChannelDuplexHandler {
    typealias InboundIn = HTTP2Frame
    typealias OutboundIn = HTTP2Frame
    typealias OutboundOut = HTTP2Frame
    private let path: String
    let held: EventLoopPromise<Void>
    private var signalled = false
    private var open = false
    private var target: HTTP2StreamID?
    private var context: ChannelHandlerContext?
    private var frames: [(HTTP2Frame, EventLoopPromise<Void>?)] = []
    private(set) var heldBytes = 0
    private(set) var otherDataBytes = 0
    init(path: String, loop: EventLoop) { self.path = path; held = loop.makePromise() }
    static func install(on parent: Channel, path: String) async throws -> NIOLoopBound<HTTP2FrameWriteGate> {
        try await parent.eventLoop.submit {
            let gate = HTTP2FrameWriteGate(path: path, loop: parent.eventLoop)
            let observer = try parent.pipeline.syncOperations.handler(type: HTTP2ConnectionObserver.self)
            try parent.pipeline.syncOperations.addHandler(gate, position: .before(observer))
            return NIOLoopBound(gate, eventLoop: parent.eventLoop)
        }.boundedGet()
    }
    func handlerAdded(context: ChannelHandlerContext) { self.context = context }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        if case .headers(let headers) = frame.payload, headers.headers.first(name: ":path") == path { target = frame.streamID }
        context.fireChannelRead(data)
    }
    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let frame = unwrapOutboundIn(data)
        let bytes: Int
        if case .data(let payload) = frame.payload { bytes = payload.data.readableBytes } else { bytes = 0 }
        if !open, frame.streamID == target, bytes > 0 || !frames.isEmpty {
            frames.append((frame, promise)); heldBytes += bytes
            if !signalled { signalled = true; held.succeed(()) }
        } else {
            if frame.streamID != target { otherDataBytes += bytes }
            context.write(data, promise: promise)
        }
    }
    func release() {
        guard !open, let context else { return }
        open = true
        let pending = frames; frames.removeAll(); heldBytes = 0
        for (frame, promise) in pending { context.write(wrapOutboundOut(frame), promise: promise) }
        context.flush()
    }
    func channelInactive(context: ChannelHandlerContext) {
        if !signalled { signalled = true; held.fail(HTTPTransportError.closed) }
        let pending = frames; frames.removeAll(); heldBytes = 0
        for (_, promise) in pending { promise?.fail(HTTPTransportError.closed) }
        context.fireChannelInactive()
    }
    func handlerRemoved(context: ChannelHandlerContext) { self.context = nil }
}

/// Observes a genuine source-child read after the production downstream handler
/// resumes it. Installed only after the test has observed that child paused.
final class HTTP2ResumeReadProbe: ChannelOutboundHandler, RemovableChannelHandler {
    typealias OutboundIn = HTTP2Frame.FramePayload
    let observed: EventLoopPromise<Bool>
    private var done = false
    init(loop: EventLoop) { observed = loop.makePromise() }
    static func install(on child: Channel) async throws -> EventLoopFuture<Bool> {
        try await child.eventLoop.submit {
            let probe = HTTP2ResumeReadProbe(loop: child.eventLoop)
            try child.pipeline.syncOperations.addHandler(probe, position: .first)
            return probe.observed.futureResult
        }.boundedGet()
    }
    func handlerRemoved(context: ChannelHandlerContext) {
        if !done { done = true; observed.fail(HTTPTransportError.closed) }
    }
    func read(context: ChannelHandlerContext) {
        let first = !done
        if first {
            done = true
            context.channel.getOption(ChannelOptions.autoRead).cascade(to: observed)
        }
        // Forward before removal: a removed context no longer has an outbound link.
        context.read()
        if first { context.pipeline.syncOperations.removeHandler(self, promise: nil) }
    }
}
