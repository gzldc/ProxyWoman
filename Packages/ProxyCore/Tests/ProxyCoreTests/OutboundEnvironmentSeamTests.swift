import FlowStore
import Foundation
import NIOCore
import NIOEmbedded
import NIOHTTP1
import Testing
@testable import ProxyCore

/// An exchange driven entirely without a client socket: the response goes to a virtual writer
/// and the outbound environment owns its own loop-bound pool.
@Suite(.productionChinese) struct OutboundEnvironmentSeamTests {
    @Test func exchangeRunsAgainstVirtualWriterAndChannelFreeEnvironment() async throws {
        try await withConnectionFixture { fixture in
            let outbound = VirtualOutbound(loop: fixture.loop, environment: fixture.environment)
            defer { outbound.shutdown() }
            let writer = VirtualWriter(loop: fixture.loop)
            let exchange = HTTPExchange(
                requestHead: HTTPRequestHead(version: .http1_1, method: .GET, uri: "http://example.test/virtual"),
                target: RequestTarget(host: "example.test", port: 80, originForm: "/virtual", defaultPort: 80),
                scheme: "http", downstream: writer, connection: outbound, transport: .init(downstreamRequest: .http1_1))
            exchange.execute()
            exchange.receiveRequest(.end(nil))
            #expect(outbound.registered == 1)
            #expect(outbound.connects == 1)

            let upstream = try outbound.connect()
            var request = ""
            while let bytes = try upstream.readOutbound(as: IOData.self) {
                if case .byteBuffer(let buffer) = bytes { request += String(buffer: buffer) }
            }
            #expect(request.hasPrefix("GET /virtual HTTP/1.1\r\n"))
            try upstream.writeInbound(ByteBuffer(string: "HTTP/1.1 200 OK\r\nContent-Length: 7\r\n\r\nvirtual"))
            fixture.loop.run()

            #expect(writer.statuses == [200])
            #expect(writer.body == "virtual")
            #expect(writer.ends == 1)
            #expect(writer.finishes == 1)
            #expect(writer.aborts == 0)
            #expect(outbound.registered == 0)
            #expect(outbound.pendingBytes == 0)
            let flow = try #require(fixture.store.allFlows().first { $0.path == "/virtual" })
            #expect(flow.state == .completed)
            #expect(try flow.responseBody?.load() == Data("virtual".utf8))
        }
    }
}

/// No Channel: writes complete on the loop and are recorded for inspection.
private final class VirtualWriter: DownstreamResponseWriter {
    let eventLoop: EventLoop
    let version: HTTPWireVersion = .http1_1
    let isWritable = true
    let isActive = true
    var statuses: [UInt] = []
    var body = ""
    var ends = 0
    var finishes = 0
    var aborts = 0
    init(loop: EventLoop) { eventLoop = loop }
    func write(_ part: HTTPServerResponsePart) -> EventLoopFuture<Void> {
        switch part {
        case .head(let head): statuses.append(head.status.code)
        case .body(.byteBuffer(let bytes)): body += String(buffer: bytes)
        case .body(.fileRegion): break
        case .end: ends += 1
        }
        return eventLoop.makeSucceededVoidFuture()
    }
    func flush() {}
    func setRequestReading(_ enabled: Bool) {}
    func responseFinished() { finishes += 1 }
    func abort(_ error: Error) { aborts += 1 }
}

/// A channel-free owner: forwarding is allowed immediately and there is no client identity.
private final class VirtualOutbound: HTTPOutboundEnvironment {
    let contextID = UUID()
    let environment: ProxyEnvironment
    let limits = HTTPTransportLimits()
    private(set) lazy var upstreamPool = UpstreamSessionPool(eventLoop: loop, environment: environment, limits: limits,
        connectionFactory: { [unowned self] _, _, loop in
            connects += 1
            let promise = loop.makePromise(of: Channel.self)
            connections.append(promise)
            return promise.futureResult
        })
    let knownClient: ClientApp? = nil
    let forwardingAllowed = true
    private(set) var registered = 0
    private(set) var pendingBytes = 0
    private(set) var connects = 0
    private let loop: EmbeddedEventLoop
    private var connections: [EventLoopPromise<Channel>] = []
    private var channels: [EmbeddedChannel] = []

    init(loop: EmbeddedEventLoop, environment: ProxyEnvironment) {
        self.loop = loop
        self.environment = environment
    }
    func connect() throws -> EmbeddedChannel {
        let channel = EmbeddedChannel(loop: loop)
        try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 12347)).wait()
        channels.append(channel)
        connections[channels.count - 1].succeed(channel)
        loop.run()
        return channel
    }
    func shutdown() {
        upstreamPool.shutdown(error: nil)
        channels.forEach { _ = try? $0.finish() }
        loop.run()
    }
    func onClient(_ callback: @escaping (ClientApp) -> Void) {}
    func whenForwardingAllowed(_ callback: @escaping () -> Void) { callback() }
    func register(_ exchange: HTTPExchange, streamID: Int?) -> Bool { registered += 1; return true }
    func unregister(_ exchange: HTTPExchange) { registered -= 1 }
    func reservePendingBytes(_ count: Int) -> Bool { pendingBytes += count; return true }
    func releasePendingBytes(_ count: Int) { pendingBytes -= count }
}
