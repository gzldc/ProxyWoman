import Foundation
import Darwin
import NIOCore
import NIOEmbedded
import NIOHTTP1
import Testing
@testable import ProxyCore

@Suite(.productionChinese) struct HTTP1TransferCodingFramerTests {
    @Test func quotedTransferParametersPreserveCommasAndEscapesOnAnUnchangedHop() throws {
        let coding = "custom; p=\"a,b\\\"c\", chunked"
        let head = try HTTPMessageTranslation.response(.init(version: .http1_1, status: .ok,
            headers: HTTPHeaders([("Transfer-Encoding", coding)])), requestMethod: .GET, source: .http1_1, destination: .http1_1, endStream: false)
        let channel = EmbeddedChannel(handlers: [HTTPMessageTranslation.responseEncoder(), HTTP1TransferCodingFramer<HTTPResponseHead>()])
        defer { _ = try? channel.finish() }
        try channel.writeOutbound(HTTPServerResponsePart.head(head))
        try channel.writeOutbound(HTTPServerResponsePart.body(.byteBuffer(ByteBuffer(string: "abc"))))
        try channel.writeOutbound(HTTPServerResponsePart.end(nil))
        let bytes = try drain(channel)
        #expect(String(decoding: bytes, as: UTF8.self) == "HTTP/1.1 200 OK\r\nTransfer-Encoding: custom; p=\"a,b\\\"c\", chunked\r\n\r\n3\r\nabc\r\n0\r\n\r\n")
        let peer = EmbeddedChannel(handlers: [HTTPRequestEncoder(), ByteToMessageHandler(HTTPResponseDecoder())])
        defer { _ = try? peer.finish() }
        try peer.writeOutbound(HTTPClientRequestPart.head(.init(version: .http1_1, method: .GET, uri: "/")))
        try peer.writeOutbound(HTTPClientRequestPart.end(nil))
        try peer.writeInbound(ByteBuffer(bytes: bytes))
        guard case .head(let decoded)? = try peer.readInbound(as: HTTPClientResponsePart.self),
              case .body(let body)? = try peer.readInbound(as: HTTPClientResponsePart.self),
              case .end? = try peer.readInbound(as: HTTPClientResponsePart.self) else { Issue.record("missing decoded compound message"); return }
        #expect(decoded.headers.first(name: "transfer-encoding") == coding)
        #expect(String(decoding: body.readableBytesView, as: UTF8.self) == "abc")
    }

    @Test(arguments: [1, 2, 3])
    func eachFailedBodySubwriteFailsTheOriginalPromise(index: Int) throws {
        let failure = SubwriteFailureHandler()
        let channel = EmbeddedChannel(handlers: [failure, HTTPMessageTranslation.requestEncoder(), HTTP1TransferCodingFramer<HTTPRequestHead>()])
        defer { _ = try? channel.finish() }
        try channel.writeOutbound(HTTPClientRequestPart.head(.init(version: .http1_1, method: .POST, uri: "/", headers: HTTPHeaders([("Transfer-Encoding", "gzip, chunked")]))))
        failure.failAt = index
        let promise = channel.eventLoop.makePromise(of: Void.self)
        channel.writeAndFlush(HTTPClientRequestPart.body(.byteBuffer(ByteBuffer(string: "body"))), promise: promise)
        #expect(throws: FramingSubwriteError.self) { try promise.futureResult.wait() }
        #expect(failure.writes == 3)
    }

    @Test(arguments: [1, 2])
    func failedTerminalSubwritesFailTheEndPromise(index: Int) throws {
        let failure = SubwriteFailureHandler()
        let channel = EmbeddedChannel(handlers: [failure, HTTPMessageTranslation.responseEncoder(), HTTP1TransferCodingFramer<HTTPResponseHead>()])
        defer { _ = try? channel.finish() }
        try channel.writeOutbound(HTTPServerResponsePart.head(.init(version: .http1_1, status: .ok, headers: HTTPHeaders([("Transfer-Encoding", "gzip, chunked")]))))
        failure.failAt = index
        let promise = channel.eventLoop.makePromise(of: Void.self)
        channel.writeAndFlush(HTTPServerResponsePart.end(nil), promise: promise)
        #expect(throws: FramingSubwriteError.self) { try promise.futureResult.wait() }
        #expect(failure.writes == 2)
    }

    @Test func compoundFileRegionPreservesRangeAndFramesWithoutCopying() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("xabcx".utf8).write(to: file)
        let descriptor = open(file.path, O_RDONLY)
        try #require(descriptor >= 0)
        let handle = NIOFileHandle(_deprecatedTakingOwnershipOfDescriptor: descriptor)
        defer { try? handle.close() }
        let region = FileRegion(fileHandle: handle, readerIndex: 1, endIndex: 4)
        let channel = EmbeddedChannel(handlers: [HTTPMessageTranslation.requestEncoder(), HTTP1TransferCodingFramer<HTTPRequestHead>()])
        defer { _ = try? channel.finish() }
        try channel.writeOutbound(HTTPClientRequestPart.head(.init(version: .http1_1, method: .POST, uri: "/", headers: HTTPHeaders([("Transfer-Encoding", "gzip, chunked")]))))
        _ = try drain(channel)
        try channel.writeOutbound(HTTPClientRequestPart.body(.fileRegion(region)))
        guard case .byteBuffer(let prefix)? = try channel.readOutbound(as: IOData.self),
              case .fileRegion(let actual)? = try channel.readOutbound(as: IOData.self),
              case .byteBuffer(let suffix)? = try channel.readOutbound(as: IOData.self) else { Issue.record("missing framed file region"); return }
        #expect(String(decoding: prefix.readableBytesView, as: UTF8.self) == "3\r\n")
        #expect(actual.readerIndex == 1)
        #expect(actual.endIndex == 4)
        #expect(actual.fileHandle === handle)
        #expect(String(decoding: suffix.readableBytesView, as: UTF8.self) == "\r\n")
        try channel.writeOutbound(HTTPClientRequestPart.end(nil))
        #expect(String(decoding: try drain(channel), as: UTF8.self) == "0\r\n\r\n")
    }

    @Test(arguments: [(HTTPMethod.HEAD, 200), (.GET, 103), (.GET, 204), (.GET, 304)])
    func bodylessAndInterimHeadsDoNotLeakCompoundState(method: HTTPMethod, status: Int) throws {
        let channel = EmbeddedChannel(handlers: [HTTPMessageTranslation.responseEncoder(), HTTP1TransferCodingFramer<HTTPResponseHead>()])
        defer { _ = try? channel.finish() }
        let head = try HTTPMessageTranslation.response(.init(version: .http1_1, status: .init(statusCode: status),
            headers: HTTPHeaders([("Transfer-Encoding", "gzip, chunked")])), requestMethod: method, source: .http1_1, destination: .http1_1, endStream: false)
        try channel.writeOutbound(HTTPServerResponsePart.head(head))
        if status != 103 { try channel.writeOutbound(HTTPServerResponsePart.end(nil)) }
        let first = String(decoding: try drain(channel), as: UTF8.self)
        #expect(!first.lowercased().contains("transfer-encoding"))
        #expect(!first.contains("0\r\n\r\n"))
        try channel.writeOutbound(HTTPServerResponsePart.head(.init(version: .http1_1, status: .ok, headers: HTTPHeaders([("Transfer-Encoding", "gzip, chunked")]))))
        try channel.writeOutbound(HTTPServerResponsePart.end(nil))
        #expect(String(decoding: try drain(channel), as: UTF8.self) == "HTTP/1.1 200 OK\r\nTransfer-Encoding: gzip, chunked\r\n\r\n0\r\n\r\n")
    }

    @Test func compoundRequestPreservesCodingAndDecodesAtAnIndependentEndpoint() throws {
        let channel = EmbeddedChannel(handlers: [HTTPMessageTranslation.requestEncoder(), HTTP1TransferCodingFramer<HTTPRequestHead>()])
        defer { _ = try? channel.finish() }
        let head = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/upload", headers: HTTPHeaders([("Host", "example.com"), ("Transfer-Encoding", "gzip, chunked")]))
        try channel.writeOutbound(HTTPClientRequestPart.head(head))
        try channel.writeOutbound(HTTPClientRequestPart.body(.byteBuffer(ByteBuffer())))
        try channel.writeOutbound(HTTPClientRequestPart.body(.byteBuffer(ByteBuffer(bytes: [0x1f, 0x8b, 0, 0xff]))))
        try channel.writeOutbound(HTTPClientRequestPart.end(HTTPHeaders([("X-End", "a"), ("X-End", "b")])))
        let bytes = try drain(channel)
        #expect(bytes == Array("POST /upload HTTP/1.1\r\nHost: example.com\r\nTransfer-Encoding: gzip, chunked\r\n\r\n4\r\n".utf8) + [0x1f, 0x8b, 0, 0xff] + Array("\r\n0\r\nX-End: a\r\nX-End: b\r\n\r\n".utf8))
        let peer = EmbeddedChannel(handler: ByteToMessageHandler(HTTPRequestDecoder()))
        defer { _ = try? peer.finish() }
        try peer.writeInbound(ByteBuffer(bytes: bytes))
        guard case .head(let decoded)? = try peer.readInbound(as: HTTPServerRequestPart.self) else { Issue.record("missing head"); return }
        #expect(decoded.headers.first(name: "transfer-encoding") == "gzip, chunked")
        guard case .body(let body)? = try peer.readInbound(as: HTTPServerRequestPart.self) else { Issue.record("missing body"); return }
        #expect(Array(body.readableBytesView) == [0x1f, 0x8b, 0, 0xff])
        guard case .end(let trailers)? = try peer.readInbound(as: HTTPServerRequestPart.self) else { Issue.record("missing end"); return }
        #expect(trailers?["x-end"] == ["a", "b"])
    }

    @Test func compoundResponseResetsForNextMessageAndDecodesIndependently() throws {
        let channel = EmbeddedChannel(handlers: [HTTPMessageTranslation.responseEncoder(), HTTP1TransferCodingFramer<HTTPResponseHead>()])
        defer { _ = try? channel.finish() }
        try channel.writeOutbound(HTTPServerResponsePart.head(.init(version: .http1_1, status: .ok, headers: HTTPHeaders([("Transfer-Encoding", "gzip, chunked")]))))
        try channel.writeOutbound(HTTPServerResponsePart.body(.byteBuffer(ByteBuffer(string: "opaque"))))
        try channel.writeOutbound(HTTPServerResponsePart.end(HTTPHeaders([("X-End", "yes")])))
        try channel.writeOutbound(HTTPServerResponsePart.head(.init(version: .http1_1, status: .ok, headers: HTTPHeaders([("Content-Length", "2")]))))
        try channel.writeOutbound(HTTPServerResponsePart.body(.byteBuffer(ByteBuffer(string: "ok"))))
        try channel.writeOutbound(HTTPServerResponsePart.end(nil))
        let bytes = try drain(channel)
        #expect(String(decoding: bytes, as: UTF8.self) == "HTTP/1.1 200 OK\r\nTransfer-Encoding: gzip, chunked\r\n\r\n6\r\nopaque\r\n0\r\nX-End: yes\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok")
        let peer = EmbeddedChannel(handlers: [HTTPRequestEncoder(), ByteToMessageHandler(HTTPResponseDecoder())])
        defer { _ = try? peer.finish() }
        for _ in 0..<2 {
            try peer.writeOutbound(HTTPClientRequestPart.head(.init(version: .http1_1, method: .GET, uri: "/")))
            try peer.writeOutbound(HTTPClientRequestPart.end(nil))
        }
        try peer.writeInbound(ByteBuffer(bytes: bytes))
        var bodies: [String] = []
        var heads = 0
        var ends = 0
        while let part = try peer.readInbound(as: HTTPClientResponsePart.self) {
            switch part {
            case .head: heads += 1
            case .body(let buffer): bodies.append(String(decoding: buffer.readableBytesView, as: UTF8.self))
            case .end: ends += 1
            }
        }
        #expect(heads == 2)
        #expect(ends == 2)
        #expect(bodies == ["opaque", "ok"])
    }

    @Test func emptyCompoundMessageWritesOneTerminatorAndRejectsDuplicateEnd() throws {
        let channel = EmbeddedChannel(handlers: [HTTPMessageTranslation.responseEncoder(), HTTP1TransferCodingFramer<HTTPResponseHead>()])
        defer { _ = try? channel.finish() }
        try channel.writeOutbound(HTTPServerResponsePart.head(.init(version: .http1_1, status: .ok, headers: HTTPHeaders([("Transfer-Encoding", "gzip, chunked")]))))
        try channel.writeOutbound(HTTPServerResponsePart.end(nil))
        #expect(String(decoding: try drain(channel), as: UTF8.self).hasSuffix("\r\n\r\n0\r\n\r\n"))
        let promise = channel.eventLoop.makePromise(of: Void.self)
        channel.writeAndFlush(HTTPServerResponsePart.end(nil), promise: promise)
        #expect(throws: HTTPTranslationError.self) { try promise.futureResult.wait() }
        #expect(try drain(channel).isEmpty)
    }

    @Test func invalidLateTrailerFailsPromiseWithoutInjectingBytes() throws {
        let channel = EmbeddedChannel(handlers: [HTTPMessageTranslation.requestEncoder(), HTTP1TransferCodingFramer<HTTPRequestHead>()])
        defer { _ = try? channel.finish() }
        try channel.writeOutbound(HTTPClientRequestPart.head(.init(version: .http1_1, method: .POST, uri: "/", headers: HTTPHeaders([("Transfer-Encoding", "gzip, chunked")]))))
        _ = try drain(channel)
        let promise = channel.eventLoop.makePromise(of: Void.self)
        channel.writeAndFlush(HTTPClientRequestPart.end(HTTPHeaders([("X-End", "bad\r\ninjected")])), promise: promise)
        #expect(throws: HTTPTranslationError.self) { try promise.futureResult.wait() }
        #expect(try drain(channel).isEmpty)
    }

    private func drain(_ channel: EmbeddedChannel) throws -> [UInt8] {
        var bytes: [UInt8] = []
        while let part = try channel.readOutbound(as: IOData.self) {
            if case .byteBuffer(let buffer) = part { bytes += buffer.readableBytesView }
            else { Issue.record("unexpected file region") }
        }
        return bytes
    }
}

private struct FramingSubwriteError: Error {}
private final class SubwriteFailureHandler: ChannelOutboundHandler {
    typealias OutboundIn = IOData
    var failAt: Int? { didSet { writes = 0 } }
    private(set) var writes = 0
    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        writes += 1
        if writes == failAt { promise?.fail(FramingSubwriteError()) }
        else { context.write(data, promise: promise) }
    }
}
