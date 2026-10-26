import FlowStore
import Foundation
import NIOCore
import NIOEmbedded
import NIOHPACK
import NIOHTTP1
import Testing

@testable import FlowStore
@testable import ProxyCore

// MARK: - Fixtures

/// Sits at the head of an upstream test channel and decides, per outbound write, whether the
/// write future succeeds, fails, or stays pending until released.
private final class BoundaryWriteGate: ChannelOutboundHandler {
    typealias OutboundIn = IOData
    typealias OutboundOut = IOData
    enum Action { case accept, hold, fail }
    struct Refused: Error {}
    private let decide: (_ index: Int, _ size: Int) -> Action
    private var index = 0
    private var held: [(IOData, EventLoopPromise<Void>?)] = []
    private var context: ChannelHandlerContext?
    init(_ decide: @escaping (Int, Int) -> Action) { self.decide = decide }
    func handlerAdded(context: ChannelHandlerContext) { self.context = context }
    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let io = unwrapOutboundIn(data)
        let size: Int
        switch io {
        case .byteBuffer(let bytes): size = bytes.readableBytes
        case .fileRegion(let region): size = region.readableBytes
        }
        let action = decide(index, size)
        index += 1
        switch action {
        case .accept: accept(io, promise, context)
        case .hold: held.append((io, promise))
        case .fail: promise?.fail(Refused())
        }
    }
    /// The writer accepting a write: the bytes go on and the future succeeds right away.
    private func accept(_ io: IOData, _ promise: EventLoopPromise<Void>?, _ context: ChannelHandlerContext) {
        context.write(NIOAny(io), promise: nil)
        context.flush()
        promise?.succeed(())
    }
    func releaseHeld(accept: Bool) {
        guard let context else { return }
        let writes = held
        held = []
        for (io, promise) in writes {
            if accept { self.accept(io, promise, context) } else { promise?.fail(Refused()) }
        }
    }
}

private final class BoundaryWriter: DownstreamResponseWriter {
    let channel: Channel
    let version: HTTPWireVersion
    var eventLoop: EventLoop { channel.eventLoop }
    var isWritable: Bool { channel.isWritable }
    var isActive: Bool { channel.isActive }
    var statuses: [UInt] = []
    var finishes = 0
    var completion: EventLoopFuture<Void>?
    init(channel: Channel, version: HTTPWireVersion = .http1_1) { self.channel = channel; self.version = version }
    func write(_ part: HTTPServerResponsePart) -> EventLoopFuture<Void> {
        if case .head(let head) = part { statuses.append(head.status.code) }
        return completion ?? channel.eventLoop.makeSucceededVoidFuture()
    }
    func flush() { channel.flush() }
    func setRequestReading(_ enabled: Bool) {}
    func responseFinished() { finishes += 1 }
    func abort(_ error: Error) {}
}

private func makeExchange(
    _ path: String, method: HTTPMethod = .POST, version: HTTPVersion = .http1_1, headers: HTTPHeaders = HTTPHeaders(),
    writer: BoundaryWriter, context: ClientConnectionContext
) -> HTTPExchange {
    let exchange = HTTPExchange(
        requestHead: HTTPRequestHead(version: version, method: method, uri: "http://example.test" + path, headers: headers),
        target: RequestTarget(host: "example.test", port: 80, originForm: path, defaultPort: 80),
        scheme: "http", downstream: writer, connection: context,
        transport: .init(downstreamRequest: HTTPWireVersion(version)))
    exchange.execute()
    return exchange
}

private func connectGated(_ fixture: ConnectionFixture, _ gate: BoundaryWriteGate, index: Int = 0) throws -> EmbeddedChannel {
    let channel = EmbeddedChannel(handler: gate, loop: fixture.loop)
    try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 12346)).wait()
    fixture.channels.append(channel)
    fixture.connections[index].succeed(channel)
    fixture.loop.run()
    return channel
}

private func contentLength(_ count: Int) -> HTTPHeaders { HTTPHeaders([("Content-Length", String(count))]) }

private func theFlow(_ fixture: ConnectionFixture, _ path: String) throws -> Flow {
    try #require(fixture.store.allFlows().first { $0.path == path })
}

private let ok = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"

// MARK: - Real exchange boundaries

@Suite(.productionChinese) struct BoundaryCaptureTests {
    @Test(arguments: [false, true])
    func upstreamBoundaryAppearsOnlyAfterTheWriterAcceptsTheHead(failTheWrite: Bool) async throws {
        try await withConnectionFixture { fixture in
            let gate = BoundaryWriteGate { _, _ in .hold }
            let writer = BoundaryWriter(channel: fixture.client)
            let exchange = makeExchange("/gate", headers: contentLength(5), writer: writer, context: fixture.context())
            exchange.receiveRequest(.body(ByteBuffer(string: "hello")))
            exchange.receiveRequest(.end(nil))
            _ = try connectGated(fixture, gate)

            // The head is prepared and submitted, but no writer has accepted anything yet.
            var flow = try theFlow(fixture, "/gate")
            #expect(flow.messages[.upstreamRequest] == nil)
            #expect(flow.transport.upstreamRequest == nil)
            let original = try #require(flow.messages[.downstreamRequest])
            #expect(original.bodyState == .complete)
            #expect(try original.body?.load() == Data("hello".utf8))

            gate.releaseHeld(accept: !failTheWrite)
            fixture.loop.run()
            flow = try theFlow(fixture, "/gate")
            let upstream = try #require(flow.messages[.upstreamRequest])
            if failTheWrite {
                #expect(upstream.transferState == .partiallySent)
                // A failed write is not proof anything reached the origin.
                #expect(flow.transport.upstreamRequest == nil)
                #expect(upstream.body == nil)
                #expect(upstream.bodyState == .incomplete)
            } else {
                #expect(upstream.transferState == .finished)
                #expect(flow.transport.upstreamRequest == .http1_1)
                #expect(upstream.wireVersion == .http1_1)
                #expect(try upstream.body?.load() == Data("hello".utf8))
                #expect(upstream.bodyState == .complete)
                #expect(upstream.target?.pathAndQuery == "/gate")
            }
        }
    }

    @Test func upstreamAcceptingOnlyPartOfTheBodyKeepsTheSourceWholeAndAccountsItOnce() async throws {
        try await withConnectionFixture { fixture in
            var accepted = 0
            let gate = BoundaryWriteGate { index, size in
                if index == 0 { return .accept }  // head
                guard accepted + size <= 40 else { return .fail }
                accepted += size
                return .accept
            }
            let writer = BoundaryWriter(channel: fixture.client)
            let exchange = makeExchange("/partial", headers: contentLength(100), writer: writer, context: fixture.context())
            exchange.receiveRequest(.body(ByteBuffer(repeating: 0x61, count: 40)))
            exchange.receiveRequest(.body(ByteBuffer(repeating: 0x62, count: 60)))
            exchange.receiveRequest(.end(nil))
            _ = try connectGated(fixture, gate)
            fixture.loop.run()

            let flow = try theFlow(fixture, "/partial")
            let source = try #require(flow.messages[.downstreamRequest])
            let upstream = try #require(flow.messages[.upstreamRequest])
            #expect(source.body?.count == 100)
            #expect(source.bodyState == .complete)
            #expect(upstream.body?.count == 40)
            #expect(upstream.bodyState != .complete)
            #expect(upstream.transferState == .partiallySent)
            #expect(upstream.observedBytes == 40)
            #expect(try upstream.body?.load() == Data(repeating: 0x61, count: 40))
            #expect(flow.requestBody?.size == 100)

            // One capture of the 100 request bytes (shared by the legacy field and both slices),
            // plus the generated failure page, which is also captured once.
            let generated = try #require(flow.messages[.generatedResponse])
            let ownership = fixture.store.bodyOwnershipSnapshot()
            #expect(ownership.retainedBodies == 2)
            #expect(ownership.retainedMemoryBytes == 100 + (generated.body?.count ?? -1))
            #expect(writer.statuses == [502])
        }
    }

    @Test(arguments: [false, true])
    func downstreamResponseBoundaryAppearsOnlyAfterTheClientWriterAcceptsTheHead(failTheWrite: Bool) async throws {
        try await withConnectionFixture { fixture in
            let held = fixture.loop.makePromise(of: Void.self)
            let writer = BoundaryWriter(channel: fixture.client)
            writer.completion = held.futureResult
            let exchange = makeExchange("/reply", method: .GET, writer: writer, context: fixture.context())
            exchange.receiveRequest(.end(nil))
            let upstream = try fixture.connect(0)
            try upstream.writeInbound(ByteBuffer(string: "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello"))

            var flow = try theFlow(fixture, "/reply")
            let received = try #require(flow.messages[.upstreamResponse])
            #expect(received.status == 200)
            #expect(flow.messages[.downstreamResponse] == nil)
            #expect(flow.transport.downstreamResponse == nil)
            #expect(flow.state == .inProgress)

            if failTheWrite { held.fail(BoundaryWriteGate.Refused()) } else { held.succeed(()) }
            fixture.loop.run()
            flow = try theFlow(fixture, "/reply")
            let delivered = try #require(flow.messages[.downstreamResponse])
            if failTheWrite {
                #expect(delivered.transferState == .partiallySent)
                #expect(flow.transport.downstreamResponse == nil)
                #expect(delivered.bodyState == .incomplete)
            } else {
                #expect(delivered.transferState == .finished)
                #expect(delivered.bodyState == .complete)
                #expect(flow.transport.downstreamResponse == .http1_1)
                #expect(try delivered.body?.load() == Data("hello".utf8))
                #expect(flow.state == .completed)
                // The same 5 response bytes back the legacy field and both boundaries.
                #expect(fixture.store.bodyOwnershipSnapshot().retainedBodies == 1)
            }
        }
    }

    @Test func eachBoundaryKeepsItsOwnVersionHeadersAndStatus() async throws {
        try await withConnectionFixture { fixture in
            let writer = BoundaryWriter(channel: fixture.client)
            let exchange = makeExchange(
                "/pair?x=1", method: .GET, version: .http1_0, headers: HTTPHeaders([("X-Dup", "a"), ("X-Dup", "b")]),
                writer: writer, context: fixture.context())
            exchange.receiveRequest(.end(nil))
            let upstream = try fixture.connect(0)
            try upstream.writeInbound(ByteBuffer(string: "HTTP/1.1 200 OK\r\nX-Origin: 1\r\nContent-Length: 4\r\n\r\nbody"))
            fixture.loop.run()

            let flow = try theFlow(fixture, "/pair?x=1")
            let client = try #require(flow.messages[.downstreamRequest])
            let effective = try #require(flow.messages[.upstreamRequest])
            let origin = try #require(flow.messages[.upstreamResponse])
            let delivered = try #require(flow.messages[.downstreamResponse])
            #expect(client.wireVersion == .http1_0)
            #expect(effective.wireVersion == .http1_0)
            #expect(origin.wireVersion == .http1_1)
            #expect(delivered.wireVersion == .http1_0)
            // The original client head, in order, duplicates kept; and the legacy projection agrees.
            #expect(client.headers.filter { $0.name == "X-Dup" }.map(\.value) == ["a", "b"])
            #expect(client.headers == flow.requestHeaders)
            #expect(origin.headers == flow.responseHeaders)
            #expect(origin.headers.value(for: "X-Origin") == "1")
            #expect(client.target?.pathAndQuery == "/pair?x=1")
            #expect(delivered.status == 200)
            #expect(try origin.body?.load() == Data("body".utf8))
            #expect(try delivered.body?.load() == Data("body".utf8))
        }
    }

    @Test func interimInformationalHeadsAreNotABoundary() async throws {
        try await withConnectionFixture { fixture in
            let writer = BoundaryWriter(channel: fixture.client)
            let exchange = makeExchange("/continue", method: .GET, writer: writer, context: fixture.context())
            exchange.receiveRequest(.end(nil))
            let upstream = try fixture.connect(0)
            try upstream.writeInbound(ByteBuffer(string: "HTTP/1.1 100 Continue\r\n\r\n"))
            var flow = try theFlow(fixture, "/continue")
            #expect(writer.statuses == [100])
            #expect(flow.messages[.upstreamResponse] == nil)
            #expect(flow.messages[.downstreamResponse] == nil)
            try upstream.writeInbound(ByteBuffer(string: "HTTP/1.1 204 No Content\r\n\r\n"))
            fixture.loop.run()
            flow = try theFlow(fixture, "/continue")
            #expect(writer.statuses == [100, 204])
            #expect(flow.messages[.upstreamResponse]?.status == 204)
            #expect(flow.messages[.downstreamResponse]?.status == 204)
            #expect(flow.messages.values.allSatisfy { $0.status != 100 })
            // No body at all is a complete empty body, not an unavailable one.
            #expect(flow.messages[.downstreamResponse]?.body == nil)
            #expect(flow.messages[.downstreamResponse]?.bodyState == .complete)
            #expect(flow.messages[.upstreamRequest]?.bodyState == .complete)
        }
    }

    @Test func earlyResponseLeavesAnHonestPartialUpstreamRequestAndALateWholeClientRequest() async throws {
        try await withConnectionFixture { fixture in
            let writer = BoundaryWriter(channel: fixture.client)
            let exchange = makeExchange("/early", headers: contentLength(100), writer: writer, context: fixture.context())
            exchange.receiveRequest(.body(ByteBuffer(repeating: 0x71, count: 10)))
            let upstream = try fixture.connect(0)
            try upstream.writeInbound(ByteBuffer(string: "HTTP/1.1 413 Payload Too Large\r\nContent-Length: 0\r\n\r\n"))
            fixture.loop.run()
            var flow = try theFlow(fixture, "/early")
            #expect(flow.state == .completed)
            #expect(flow.messages[.downstreamResponse]?.status == 413)
            #expect(flow.messages[.downstreamResponse]?.transferState == .finished)
            #expect(flow.messages[.downstreamRequest]?.bodyState == .pending)

            // The client keeps uploading after the response completed; the proxy no longer forwards it.
            exchange.receiveRequest(.body(ByteBuffer(repeating: 0x72, count: 90)))
            exchange.receiveRequest(.end(nil))
            fixture.loop.run()
            flow = try theFlow(fixture, "/early")
            let client = try #require(flow.messages[.downstreamRequest])
            let forwarded = try #require(flow.messages[.upstreamRequest])
            #expect(client.body?.count == 100)
            #expect(client.bodyState == .complete)
            #expect(forwarded.body?.count == 10)
            #expect(forwarded.bodyState == .incomplete)
            #expect(forwarded.transferState == .partiallySent)
            #expect(try forwarded.body?.load() == Data(repeating: 0x71, count: 10))
        }
    }

    @Test(arguments: [false, true], [false, true])
    func downstreamBoundaryBegunAfterAFailureStillEndsOnceTheLastWriteSettles(h2: Bool, writeSucceeds: Bool) async throws {
        try await withConnectionFixture { fixture in
            let held = fixture.loop.makePromise(of: Void.self)
            let writer = BoundaryWriter(channel: fixture.client, version: h2 ? .http2 : .http1_1)
            writer.completion = held.futureResult
            let exchange = makeExchange("/cut", method: .GET, writer: writer, context: fixture.context())
            exchange.receiveRequest(.end(nil))
            let upstream = try fixture.connect(0)
            // The head is out; the client write for it is still pending when the origin dies.
            try upstream.writeInbound(ByteBuffer(string: "HTTP/1.1 200 OK\r\nContent-Length: 50\r\n\r\npart"))
            try upstream.close().wait()
            fixture.loop.run()
            var flow = try theFlow(fixture, "/cut")
            guard case .failed = flow.state else { Issue.record("expected a failed flow"); return }
            #expect(flow.messages[.downstreamResponse] == nil)

            if writeSucceeds { held.succeed(()) } else { held.fail(BoundaryWriteGate.Refused()) }
            fixture.loop.run()
            flow = try theFlow(fixture, "/cut")
            let delivered = try #require(flow.messages[.downstreamResponse])
            #expect(delivered.transferState == .partiallySent)
            #expect(delivered.bodyState == .incomplete)
            #expect(delivered.bodyState != .pending)
        }
    }

    @Test(arguments: [HTTPMethod.GET, .HEAD])
    func connectionFailureHasAGeneratedResponseAndNoFabricatedUpstream(method: HTTPMethod) async throws {
        try await withConnectionFixture { fixture in
            let writer = BoundaryWriter(channel: fixture.client)
            let exchange = makeExchange("/down", method: method, writer: writer, context: fixture.context())
            exchange.receiveRequest(.end(nil))
            fixture.connections[0].fail(ChannelError.ioOnClosedChannel)
            fixture.loop.run()

            let flow = try theFlow(fixture, "/down")
            #expect(writer.statuses == [502])
            #expect(flow.messages[.upstreamRequest] == nil)
            #expect(flow.messages[.upstreamResponse] == nil)
            #expect(flow.transport.upstreamRequest == nil)
            #expect(flow.transport.upstreamResponse == nil)
            let generated = try #require(flow.messages[.generatedResponse])
            let delivered = try #require(flow.messages[.downstreamResponse])
            #expect(generated.status == 502)
            #expect(generated.wireVersion == nil)
            #expect(generated.bodyState == .complete)
            #expect((generated.body?.count ?? 0) > 0)
            #expect(flow.provenance.generatedResponse?.size == UInt64(generated.body?.count ?? -1))
            #expect(delivered.status == 502)
            #expect(delivered.wireVersion == .http1_1)
            #expect(flow.transport.downstreamResponse == .http1_1)
            if method == .HEAD {
                #expect(delivered.body == nil)
                #expect(delivered.observedBytes == 0)
            } else {
                #expect(try delivered.body?.load() == generated.body?.load())
                #expect(delivered.bodyState == .complete)
            }
            guard case .failed = flow.state else { Issue.record("expected a failed flow"); return }
        }
    }
}

// MARK: - Recorder primitives

@Suite(.productionChinese) struct RecorderBoundaryTests {
    private func withRecorder(
        maxCapturedBodyBytes: Int = BodyCapture.defaultMaxCapturedBytes,
        _ body: (FlowRecorder, FlowStore, EmbeddedEventLoop) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("boundary-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FlowStore(bodyDirectory: directory, maxCapturedBodyBytes: maxCapturedBodyBytes)
        let loop = EmbeddedEventLoop()
        let recorder = FlowRecorder(
            store: store, scheme: "https", method: "POST", host: "Example.com", port: 443, path: "/p?q=1",
            requestHeaders: HTTPHeaders([("A", "1"), ("A", "2")]), client: nil, eventLoop: loop,
            transport: .init(downstreamRequest: .http2, downstreamStreamID: 5))
        try body(recorder, store, loop)
    }

    private let head = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/p?q=1")

    @Test func theClientRequestIsTheOriginalBoundaryFromTheStart() throws {
        try withRecorder { recorder, store, _ in
            let flow = try #require(store.flow(recorder.id))
            let original = try #require(flow.messages[.downstreamRequest])
            #expect(original.target == HTTPMessageTarget(scheme: "https", host: "example.com", port: 443, method: "POST", pathAndQuery: "/p?q=1"))
            #expect(original.headers.map(\.value) == ["1", "2"])
            #expect(original.wireVersion == .http2)
            #expect(original.streamID == 5)
            #expect(original.transferState == .observed)
            #expect(original.bodyState == .pending)
            #expect(flow.provenance == .passive)
        }
    }

    @Test func unchangedForwardingMirrorsCountedOffsetsOfOneCapture() throws {
        try withRecorder { recorder, store, _ in
            recorder.recordRequestBody(ByteBuffer(repeating: 1, count: 60))
            recorder.recordRequestBody(ByteBuffer(repeating: 2, count: 40))
            recorder.recordUpstreamWrite(.head(head), version: .http1_1, streamID: nil, succeeded: true)
            recorder.recordUpstreamWrite(.body(.byteBuffer(ByteBuffer(repeating: 1, count: 60))), version: nil, streamID: nil, succeeded: true)
            recorder.finishRequest()
            var flow = try #require(store.flow(recorder.id))
            // Source finished, the upstream boundary has seen 60 of the 100 bytes and is still going.
            #expect(flow.messages[.downstreamRequest]?.body?.count == 100)
            #expect(flow.messages[.downstreamRequest]?.bodyState == .complete)
            #expect(flow.messages[.upstreamRequest]?.body?.count == 60)
            #expect(flow.messages[.upstreamRequest]?.bodyState == .pending)

            // A write that settles after the source capture closed still lands on the same capture.
            recorder.recordUpstreamWrite(.body(.byteBuffer(ByteBuffer(repeating: 2, count: 40))), version: nil, streamID: nil, succeeded: true)
            recorder.recordUpstreamWrite(.end(nil), version: nil, streamID: nil, succeeded: true)
            flow = try #require(store.flow(recorder.id))
            #expect(flow.messages[.upstreamRequest]?.body?.count == 100)
            #expect(flow.messages[.upstreamRequest]?.bodyState == .complete)
            #expect(try flow.messages[.upstreamRequest]?.body?.load() == flow.messages[.downstreamRequest]?.body?.load())
            #expect(store.bodyOwnershipSnapshot().retainedBodies == 1)
            #expect(store.bodyOwnershipSnapshot().retainedMemoryBytes == 100)
        }
    }

    @Test func aChangedEntityUsesItsOwnStreamAndIsChargedSeparately() throws {
        try withRecorder { recorder, store, _ in
            recorder.recordRequestBody(ByteBuffer(string: "original-bytes"))
            recorder.finishRequest()
            let stream = recorder.makeBodyStream()
            recorder.captureBody(stream: stream, bytes: ByteBuffer(string: "edited"))
            recorder.beginMessage(.request(HTTPMessageTarget(scheme: "https", host: "example.com", port: 443, method: "PUT", pathAndQuery: "/x"), headers: []),
                boundary: .upstreamRequest, version: .http1_1, streamID: nil)
            recorder.observeBody(boundary: .upstreamRequest, stream: stream, byteCount: 6)
            recorder.finishMessage(boundary: .upstreamRequest, trailers: [], complete: true)
            // The edited stream has no producer ending of its own here: it is closed with the flow.
            recorder.fail("end of test")
            let flow = try #require(store.flow(recorder.id))
            #expect(try flow.messages[.downstreamRequest]?.body?.load() == Data("original-bytes".utf8))
            #expect(try flow.messages[.upstreamRequest]?.body?.load() == Data("edited".utf8))
            #expect(store.bodyOwnershipSnapshot().retainedBodies == 2)
            #expect(store.bodyOwnershipSnapshot().retainedMemoryBytes == 14 + 6)
        }
    }

    @Test func aBoundarySliceClampsToWhatWasAcceptedEvenWhenTheSourceIsAbandoned() throws {
        try withRecorder { recorder, store, _ in
            recorder.recordRequestBody(ByteBuffer(repeating: 9, count: 50))
            recorder.recordUpstreamWrite(.head(head), version: .http1_1, streamID: nil, succeeded: true)
            recorder.recordUpstreamWrite(.body(.byteBuffer(ByteBuffer(repeating: 9, count: 30))), version: nil, streamID: nil, succeeded: true)
            recorder.finishRequest(complete: false)  // the client went away
            let flow = try #require(store.flow(recorder.id))
            #expect(flow.messages[.downstreamRequest]?.bodyState == .incomplete)
            #expect(flow.messages[.downstreamRequest]?.body?.count == 50)
            #expect(flow.messages[.upstreamRequest]?.body?.count == 30)
            #expect(flow.messages[.upstreamRequest]?.observedBytes == 30)
        }
    }

    @Test func captureTruncationIsDistinctFromEmptyAndFromIncomplete() throws {
        try withRecorder(maxCapturedBodyBytes: 10) { recorder, store, _ in
            recorder.recordRequestBody(ByteBuffer(repeating: 3, count: 25))
            recorder.finishRequest()
            let flow = try #require(store.flow(recorder.id))
            let original = try #require(flow.messages[.downstreamRequest])
            #expect(original.observedBytes == 25)
            #expect(original.body?.count == 10)
            #expect(original.bodyState == .truncated)
            #expect(flow.requestBodyTruncated)
        }
    }

    @Test func aWrittenBoundaryWithoutABodyIsCompleteAndEmpty() throws {
        try withRecorder { recorder, store, _ in
            recorder.recordUpstreamWrite(.head(head), version: .http1_1, streamID: nil, succeeded: true)
            #expect(store.flow(recorder.id)?.messages[.upstreamRequest]?.bodyState == .pending)
            recorder.recordUpstreamWrite(.end(HTTPHeaders([("T", "1"), ("T", "2")])), version: nil, streamID: nil, succeeded: true)
            let upstream = try #require(store.flow(recorder.id)?.messages[.upstreamRequest])
            #expect(upstream.body == nil)
            #expect(upstream.bodyState == .complete)
            #expect(upstream.transferState == .finished)
            #expect(upstream.trailers.map(\.value) == ["1", "2"])
        }
    }

    @Test func generatedResponsePlaceholdersCarryNoOriginAndMirrorOneBody() throws {
        try withRecorder { recorder, store, _ in
            let assetID = UUID()
            let stream = recorder.recordGeneratedResponse(
                status: .ok, headers: HTTPHeaders([("Content-Length", "6")]), body: ByteBuffer(string: "mapped"), assetID: assetID)
            recorder.recordDownstreamWrite(
                .head(HTTPResponseHead(version: .http1_1, status: .ok, headers: HTTPHeaders([("Content-Length", "6")]))),
                bodyStream: stream, succeeded: true)
            recorder.recordDownstreamWrite(.body(.byteBuffer(ByteBuffer(string: "mapped"))), bodyStream: stream, succeeded: true)
            recorder.recordDownstreamWrite(.end(nil), bodyStream: stream, succeeded: true)
            recorder.complete()
            let flow = try #require(store.flow(recorder.id))
            #expect(flow.messages[.upstreamRequest] == nil)
            #expect(flow.messages[.upstreamResponse] == nil)
            #expect(flow.provenance.generatedResponse == GeneratedResponseSource(assetID: assetID, size: 6))
            #expect(try flow.messages[.generatedResponse]?.body?.load() == Data("mapped".utf8))
            #expect(try flow.messages[.downstreamResponse]?.body?.load() == Data("mapped".utf8))
            #expect(flow.messages[.downstreamResponse]?.bodyState == .complete)
            #expect(store.bodyOwnershipSnapshot().retainedBodies == 1)
        }
    }

    @Test func clearedFlowsAreNotRevivedByLateBoundaryEvents() throws {
        try withRecorder { recorder, store, _ in
            recorder.recordRequestBody(ByteBuffer(repeating: 1, count: 10))
            store.clear()
            recorder.recordUpstreamWrite(.head(head), version: .http1_1, streamID: nil, succeeded: true)
            recorder.finishRequest()
            recorder.fail("late")
            #expect(store.flow(recorder.id) == nil)
            #expect(store.allFlows().isEmpty)
            #expect(store.bodyOwnershipSnapshot() == .init())
        }
    }

    @Test func publishingBodyProgressNeverTouchesTheWebSocketExportGate() throws {
        try withRecorder { recorder, store, loop in
            let before = store.state.withLock { $0.webSockets.generation }
            recorder.recordRequestBody(ByteBuffer(repeating: 1, count: 10))
            recorder.recordUpstreamWrite(.head(head), version: .http1_1, streamID: nil, succeeded: true)
            loop.advanceTime(by: .milliseconds(250))
            recorder.complete()
            #expect(store.state.withLock { $0.webSockets.generation } == before)
            #expect(store.flow(recorder.id)?.messages[.downstreamRequest]?.observedBytes == 10)
        }
    }
}

// MARK: - Real loopback (production h1/h2 writers)

@Suite(.timeLimit(.minutes(2)), .productionChinese) struct LoopbackBoundaryTests {
    @Test(arguments: [false, true], [false, true])
    func fourSnapshotsAppearAtTheirTrueBoundariesWithByteCorrectOriginals(downstreamH2: Bool, upstreamH2: Bool) async throws {
        try await HTTP2TestOrigin.withOrigin(protocols: upstreamH2 ? ["h2", "http/1.1"] : ["http/1.1"]) { origin in
            try await HTTP2ProxyFixture.withProxy(origin: origin, downstreamH2: downstreamH2) { fixture, client in
                var fields = HTTPHeaders([("host", "localhost:\(origin.port)"), ("x-order", "a"), ("x-order", "b")])
                if !downstreamH2 { fields.add(name: "transfer-encoding", value: "chunked") }
                let result = try await client.request(
                    headers: fields, path: "/boundary?x=%2f", method: .POST, body: "request-\u{0}payload",
                    trailers: HTTPHeaders([("x-trailer", "a"), ("x-trailer", "b")]))
                #expect(result.status == 200)
                let flow = try await waitForFlow(fixture.store) {
                    $0.state == .completed && $0.messages[.downstreamResponse]?.transferState == .finished
                        && $0.messages[.upstreamRequest]?.transferState == .finished
                }
                let version: (Bool) -> HTTPWireVersion = { $0 ? .http2 : .http1_1 }
                #expect(Set(flow.messages.keys) == [.downstreamRequest, .upstreamRequest, .upstreamResponse, .downstreamResponse])
                #expect(flow.messages[.downstreamRequest]?.wireVersion == version(downstreamH2))
                #expect(flow.messages[.downstreamResponse]?.wireVersion == version(downstreamH2))
                #expect(flow.messages[.upstreamRequest]?.wireVersion == version(upstreamH2))
                #expect(flow.messages[.upstreamResponse]?.wireVersion == version(upstreamH2))
                #expect((flow.messages[.downstreamRequest]?.streamID != nil) == downstreamH2)
                #expect((flow.messages[.upstreamRequest]?.streamID != nil) == upstreamH2)
                // Legacy projection == downstream request / upstream response.
                #expect(flow.messages[.downstreamRequest]?.headers == flow.requestHeaders)
                #expect(flow.messages[.upstreamResponse]?.headers == flow.responseHeaders)
                #expect(flow.messages[.downstreamRequest]?.headers.filter { $0.name == "x-order" }.map(\.value) == ["a", "b"])
                #expect(flow.messages[.downstreamRequest]?.trailers.map(\.value) == ["a", "b"])
                for boundary in [HTTPMessageBoundary.downstreamRequest, .upstreamRequest] {
                    #expect(try flow.messages[boundary]?.body?.load() == Data("request-\u{0}payload".utf8))
                    #expect(flow.messages[boundary]?.bodyState == .complete)
                }
                for boundary in [HTTPMessageBoundary.upstreamResponse, .downstreamResponse] {
                    #expect(try flow.messages[boundary]?.body?.load() == Data("fixture-body".utf8))
                    #expect(flow.messages[boundary]?.bodyState == .complete)
                }
                // The origin and client views of one body share one capture each way.
                #expect(fixture.store.bodyOwnershipSnapshot().retainedBodies == 2)
            }
        }
    }

    @Test func rejectedHTTP2RequestIsAGeneratedResponseWithoutAnUpstream() async throws {
        try await HTTP2TestOrigin.withOrigin(protocols: ["h2"]) { origin in
            try await HTTP2ProxyFixture.withProxy(origin: origin, downstreamH2: true) { fixture, client in
                let rejected = try await client.rawRequest(headers: HPACKHeaders([
                    (":method", "GET"), (":scheme", "https"), (":authority", "other.test:443"), (":path", "/misdirected"),
                ]))
                #expect(rejected.status == 421)
                let flow = try await waitForFlow(fixture.store) {
                    $0.path == "/misdirected" && $0.messages[.downstreamResponse]?.transferState == .finished
                }
                #expect(flow.messages[.generatedResponse]?.status == 421)
                #expect(flow.messages[.downstreamResponse]?.status == 421)
                #expect(flow.messages[.downstreamResponse]?.wireVersion == .http2)
                #expect(flow.transport.downstreamResponse == .http2)
                #expect(flow.messages[.upstreamRequest] == nil)
                #expect(flow.messages[.upstreamResponse] == nil)
                #expect(flow.messages[.downstreamRequest]?.wireVersion == .http2)
                #expect(flow.messages[.downstreamResponse]?.bodyState == .complete)
                #expect(flow.provenance.generatedResponse?.size == 0)
                #expect(origin.counts.connections == 0)
            }
        }
    }
}
