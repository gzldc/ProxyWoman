import FlowStore
import Foundation
import NIOCore
import NIOEmbedded
import NIOHTTP1
import Testing
@testable import ProxyCore

/// The seams later rule, MapLocal, breakpoint and Compose stages use: admission is separate from
/// execution, every final response head passes one synchronous stage, local failures carry a
/// status and stable code, and the replay copy is built from what is actually forwarded.
@Suite(.productionChinese) struct ExchangeAdmissionTests {
    @Test func admissionRegistersAndRecordsButAcquiresNothingUntilExecute() async throws {
        try await withConnectionFixture { fixture in
            let writer = StageWriter(channel: fixture.client)
            let exchange = admit("/admit", writer: writer, context: fixture.context())
            #expect(try theFlow(fixture, "/admit").state == .inProgress)
            exchange.receiveRequest(.end(nil))
            #expect(fixture.connections.isEmpty)
            #expect(writer.heads.isEmpty)

            exchange.execute()
            #expect(fixture.connections.count == 1)
            let upstream = try fixture.connect(0)
            #expect(try drain(upstream).hasPrefix("GET /admit HTTP/1.1\r\n"))
            try upstream.writeInbound(ByteBuffer(string: ok))
            fixture.loop.run()
            #expect(writer.heads.map(\.status.code) == [200])
            #expect(writer.finishes == 1)
            #expect(try theFlow(fixture, "/admit").state == .completed)
        }
    }

    @Test func bodyReceivedBeforeExecuteIsForwardedAfterTheHeadAndJoinsTheReplayCopy() async throws {
        try await withConnectionFixture { fixture in
            let context = fixture.context()
            try prime(fixture, context: context)
            let old = fixture.channels[0]
            let writer = StageWriter(channel: fixture.client)
            let exchange = admit("/early-body", method: .PUT, headers: HTTPHeaders([("Content-Length", "4")]),
                                 writer: writer, context: context)
            exchange.receiveRequest(.body(ByteBuffer(string: "data")))
            exchange.receiveRequest(.end(nil))
            exchange.execute()
            let first = try drain(old)
            #expect(first.hasPrefix("PUT /early-body HTTP/1.1\r\n"))
            #expect(first.hasSuffix("\r\n\r\ndata"))
            try old.close().wait()
            #expect(fixture.connections.count == 2)
            let fresh = try fixture.connect(1)
            #expect(try drain(fresh) == first)
            try fresh.writeInbound(ByteBuffer(string: ok))
            fixture.loop.run()
            #expect(writer.heads.map(\.status.code) == [200])
        }
    }

    @Test func executingTwiceIsAPreconditionFailure() async throws {
        let result = try await #require(processExitsWith: .failure, observing: [\.standardErrorContent]) {
            try await withConnectionFixture { fixture in
                let exchange = admit("/twice", writer: StageWriter(channel: fixture.client), context: fixture.context())
                exchange.execute()
                exchange.execute()
            }
        }
        #expect(String(decoding: result.standardErrorContent, as: UTF8.self).contains("an exchange executes exactly once"))
    }

    @Test func finalResponseStageRunsOncePerFinalHeadAndNeverForInterimHeads() async throws {
        try await withConnectionFixture { fixture in
            let writer = StageWriter(channel: fixture.client)
            let exchange = admit("/stage", writer: writer, context: fixture.context())
            var staged: [UInt] = []
            var decision = exchange.forwardUnchanged
            decision.finalResponseStage = { head, resume in
                staged.append(head.status.code)
                var result = head
                result.headers.add(name: "X-Staged", value: "1")
                resume(result)
            }
            exchange.receiveRequest(.end(nil))
            exchange.execute(decision)
            let upstream = try fixture.connect(0)
            try upstream.writeInbound(ByteBuffer(string:
                "HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 103 Early Hints\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"))
            fixture.loop.run()
            #expect(staged == [200])
            #expect(writer.heads.map(\.status.code) == [100, 103, 200])
            #expect(writer.heads.prefix(2).allSatisfy { !$0.headers.contains(name: "x-staged") })
            #expect(writer.heads.last?.headers["x-staged"] == ["1"])
            #expect(writer.body == "ok")
            let flow = try theFlow(fixture, "/stage")
            #expect(flow.state == .completed)
            // The upstream boundary keeps the original head; the downstream one shows what was written.
            #expect(!(flow.messages[.upstreamResponse]?.headers.contains { $0.name == "X-Staged" } ?? true))
            #expect(flow.messages[.downstreamResponse]?.headers.contains { $0.name == "X-Staged" } == true)
        }
    }

    @Test func aRejectingResponseStageProducesOneLocalFailureInsteadOfTheUpstreamHead() async throws {
        try await withConnectionFixture { fixture in
            let writer = StageWriter(channel: fixture.client)
            let exchange = admit("/rejected", writer: writer, context: fixture.context())
            var decision = exchange.forwardUnchanged
            decision.finalResponseStage = { _, _ in throw HTTPTranslationError.invalidHeader }
            exchange.receiveRequest(.end(nil))
            exchange.execute(decision)
            let upstream = try fixture.connect(0)
            try upstream.writeInbound(ByteBuffer(string: "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"))
            fixture.loop.run()
            #expect(writer.heads.map(\.status.code) == [502])
            #expect(writer.body == "ProxyWoman：HTTP 消息头字段无效")
            #expect(exchange.localFailure == .responseUntranslatable)
            #expect(writer.finishes == 1)
        }
    }

    @Test(arguments: [LocalFailureCase.http11, .http10KeepAlive, .http10Close, .head, .http2],
          [HTTPResponseStatus.serviceUnavailable, .gatewayTimeout])
    func localFailureUsesItsStatusCodeAndDownstreamFraming(variant: LocalFailureCase, status: HTTPResponseStatus) async throws {
        try await withConnectionFixture { fixture in
            let writer = StageWriter(channel: fixture.client, version: variant.writerVersion)
            let exchange = admit("/local", method: variant.method, version: variant.requestVersion,
                                 headers: variant.requestHeaders, writer: writer, context: fixture.context())
            exchange.receiveRequest(.end(nil))
            exchange.execute()
            #expect(fixture.connections.count == 1)
            let code: HTTPLocalFailureCode = status == .gatewayTimeout ? .gatewayTimeout : .serviceUnavailable
            let message = status == .gatewayTimeout
                ? HTTPLocalFailureText.gatewayTimeout(reason: "deadline") : HTTPLocalFailureText.serviceUnavailable(reason: "capacity")
            exchange.fail(status: status, code: code, message: message)
            fixture.loop.run()

            let body = "ProxyWoman：\(message)"
            let head = try #require(writer.heads.first)
            #expect(writer.heads.count == 1)
            #expect(head.status == status)
            #expect(head.version == variant.responseVersion)
            #expect(head.headers["Content-Type"] == ["text/plain; charset=utf-8"])
            #expect(head.headers["Content-Length"] == [String(body.utf8.count)])
            #expect(head.headers["Connection"] == variant.connection)
            #expect(writer.body == (variant.method == .HEAD ? "" : body))
            #expect(writer.bodyParts == (variant.method == .HEAD ? 0 : 1))
            #expect(writer.ends == 1)
            #expect(writer.finishes == 1)
            #expect(exchange.localFailure == code)

            let flow = try theFlow(fixture, "/local")
            #expect(flow.state == .failed(message))
            #expect(flow.messages[.generatedResponse]?.status == Int(status.code))
            #expect(flow.messages[.downstreamResponse]?.status == Int(status.code))
            // The acquisition was abandoned: a late upstream connection is closed unused.
            let late = try fixture.connect(0)
            #expect(!late.isActive)
        }
    }

    @Test func unreachableUpstreamKeepsTheLegacyBadGatewayPage() async throws {
        try await withConnectionFixture { fixture in
            var limits = HTTPTransportLimits()
            limits.pendingBytesPerExchange = 1
            let writer = StageWriter(channel: fixture.client)
            let exchange = admit("/oversize", writer: writer, context: fixture.context(limits: limits))
            exchange.receiveRequest(.end(nil))
            exchange.execute()
            #expect(fixture.connections.isEmpty)
            #expect(writer.heads.map(\.status.code) == [502])
            #expect(writer.body == "ProxyWoman：无法连接 example.test:80（待转发请求超过缓冲上限）")
            #expect(exchange.localFailure == .pendingBytesExceeded)
            let flow = try theFlow(fixture, "/oversize")
            #expect(flow.state == .failed("待转发请求超过缓冲上限"))
        }
    }

    @Test(arguments: [true, false])
    func replayIsBuiltFromTheForwardedHeadAndHonoursItsReplayability(allowsReplay: Bool) async throws {
        try await withConnectionFixture { fixture in
            let context = fixture.context()
            try prime(fixture, context: context)
            let old = fixture.channels[0]
            let writer = StageWriter(channel: fixture.client)
            let exchange = admit("/replay", writer: writer, context: context)
            var decision = exchange.forwardUnchanged
            decision.head.headers.add(name: "X-Effective", value: "1")
            decision.allowsReplay = allowsReplay
            exchange.receiveRequest(.end(nil))
            exchange.execute(decision)
            #expect(try drain(old).contains("\r\nX-Effective: 1\r\n"))
            #expect(!exchange.requestHead.headers.contains(name: "x-effective"))
            try old.close().wait()
            if allowsReplay {
                #expect(fixture.connections.count == 2)
                let fresh = try fixture.connect(1)
                let replayed = try drain(fresh)
                #expect(replayed.hasPrefix("GET /replay HTTP/1.1\r\n"))
                #expect(replayed.contains("\r\nX-Effective: 1\r\n"))
                try fresh.writeInbound(ByteBuffer(string: ok))
                fixture.loop.run()
                #expect(writer.heads.map(\.status.code) == [200])
            } else {
                #expect(fixture.connections.count == 1)
                #expect(writer.heads.map(\.status.code) == [502])
                #expect(exchange.localFailure == .upstreamUnreachable)
            }
        }
    }
}

@Suite(.productionChinese) struct LocalFailureCase: Sendable, CustomTestStringConvertible {
    let name: String
    let method: HTTPMethod
    let requestVersion: HTTPVersion
    let requestHeaders: HTTPHeaders
    let writerVersion: HTTPWireVersion
    let responseVersion: HTTPVersion
    let connection: [String]
    var testDescription: String { name }

    static let http11 = Self(name: "h1.1", method: .GET, requestVersion: .http1_1, requestHeaders: HTTPHeaders(),
                             writerVersion: .http1_1, responseVersion: .http1_1, connection: [])
    static let http10KeepAlive = Self(name: "h1.0 keep-alive", method: .GET, requestVersion: .http1_0,
                                      requestHeaders: HTTPHeaders([("Connection", "keep-alive")]), writerVersion: .http1_1,
                                      responseVersion: .http1_0, connection: ["keep-alive"])
    static let http10Close = Self(name: "h1.0 close", method: .GET, requestVersion: .http1_0, requestHeaders: HTTPHeaders(),
                                  writerVersion: .http1_1, responseVersion: .http1_0, connection: ["close"])
    static let head = Self(name: "HEAD", method: .HEAD, requestVersion: .http1_1, requestHeaders: HTTPHeaders(),
                           writerVersion: .http1_1, responseVersion: .http1_1, connection: [])
    static let http2 = Self(name: "h2", method: .GET, requestVersion: .http2, requestHeaders: HTTPHeaders(),
                            writerVersion: .http2, responseVersion: .http2, connection: [])
}

/// An admitted, not yet executed exchange.
private func admit(
    _ path: String, method: HTTPMethod = .GET, version: HTTPVersion = .http1_1, headers: HTTPHeaders = HTTPHeaders(),
    writer: StageWriter, context: ClientConnectionContext
) -> HTTPExchange {
    HTTPExchange(
        requestHead: HTTPRequestHead(version: version, method: method, uri: "http://example.test" + path, headers: headers),
        target: RequestTarget(host: "example.test", port: 80, originForm: path, defaultPort: 80),
        scheme: "http", downstream: writer, connection: context,
        transport: .init(downstreamRequest: HTTPWireVersion(version)))
}

/// Leaves connection 0 idle in the pool, so the next exchange reuses it and may replay.
private func prime(_ fixture: ConnectionFixture, context: ClientConnectionContext) throws {
    let exchange = admit("/prime", writer: StageWriter(channel: fixture.client), context: context)
    exchange.receiveRequest(.end(nil))
    exchange.execute()
    let upstream = try fixture.connect(0)
    try upstream.writeInbound(ByteBuffer(string: ok))
    fixture.loop.run()
    _ = try drain(upstream)
}

private func drain(_ channel: EmbeddedChannel) throws -> String {
    var bytes = ""
    while let part = try channel.readOutbound(as: IOData.self) {
        if case .byteBuffer(let buffer) = part { bytes += String(buffer: buffer) }
    }
    return bytes
}

private func theFlow(_ fixture: ConnectionFixture, _ path: String) throws -> Flow {
    try #require(fixture.store.allFlows().first { $0.path == path })
}

private let ok = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"

private final class StageWriter: DownstreamResponseWriter {
    let channel: Channel
    let version: HTTPWireVersion
    var eventLoop: EventLoop { channel.eventLoop }
    var isWritable: Bool { channel.isWritable }
    var isActive: Bool { channel.isActive }
    var heads: [HTTPResponseHead] = []
    var body = ""
    var bodyParts = 0
    var ends = 0
    var finishes = 0
    init(channel: Channel, version: HTTPWireVersion = .http1_1) { self.channel = channel; self.version = version }
    func write(_ part: HTTPServerResponsePart) -> EventLoopFuture<Void> {
        switch part {
        case .head(let head): heads.append(head)
        case .body(.byteBuffer(let bytes)): body += String(buffer: bytes); bodyParts += 1
        case .body(.fileRegion): bodyParts += 1
        case .end: ends += 1
        }
        return channel.eventLoop.makeSucceededVoidFuture()
    }
    func flush() { channel.flush() }
    func setRequestReading(_ enabled: Bool) {}
    func responseFinished() { finishes += 1 }
    func abort(_ error: Error) {}
}
