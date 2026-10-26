import FlowStore
import RulesEngine
import NIOCore
import NIOEmbedded
import NIOHTTP1
import Testing
@testable import ProxyCore

@Suite(.productionChinese) struct HTTPMessageTranslationTests {
    @Test(arguments: [HTTPMethod.GET, .HEAD])
    func h2ResponseKeepsHTTP11ReusableIncludingBodyless(method: HTTPMethod) throws {
        let original = HTTPResponseHead(version: .http2, status: .ok)
        let translated = try HTTPMessageTranslation.response(original, requestMethod: method,
            source: .http2, destination: .http1_1, endStream: false)
        #expect(translated.isKeepAlive)
        #expect(!translated.headers.contains(name: "connection"))
        #expect(translated.headers["transfer-encoding"] == (method == .HEAD ? [] : ["chunked"]))
    }

    private let target = RequestTarget(host: "::1", port: 8080, originForm: "/path?q=1", defaultPort: 80)

    @Test func nominatedRequestLengthCannotLeaveAnUnframedHTTP10Body() throws {
        let original = HTTPRequestHead(version: .http1_0, method: .GET, uri: "/", headers:
            HTTPHeaders([("Connection", "Content-Length"), ("Content-Length", "3")]))
        #expect(throws: HTTPTranslationError.self) {
            try HTTPMessageTranslation.request(original, target: target, source: .http1_0, destination: .http1_0, endStream: false)
        }
        let head = try HTTPMessageTranslation.request(original, target: target, source: .http1_0, destination: .http1_1, endStream: false)
        let channel = EmbeddedChannel(handler: HTTPMessageTranslation.requestEncoder())
        defer { _ = try? channel.finish() }
        try channel.writeOutbound(HTTPClientRequestPart.head(head))
        try channel.writeOutbound(HTTPClientRequestPart.body(.byteBuffer(ByteBuffer(string: "abc"))))
        try channel.writeOutbound(HTTPClientRequestPart.end(nil))
        let bytes = try drain(channel)
        #expect(!bytes.lowercased().contains("content-length"))
        #expect(bytes.hasSuffix("\r\n\r\n3\r\nabc\r\n0\r\n\r\n"))
        #expect(original.headers.first(name: "content-length") == "3")
    }

    @Test(arguments: [HTTPMethod.GET, .POST, .DELETE])
    func openH2RequestUsesChunkedEvenWithLengthAndLateTrailers(method: HTTPMethod) throws {
        let original = HTTPRequestHead(version: .init(major: 2, minor: 0), method: method, uri: "/path?q=1",
                                       headers: HTTPHeaders([("Content-Length", "3"), ("Content-Encoding", "gzip")]))
        let head = try HTTPMessageTranslation.request(original, target: target, source: .http2, destination: .http1_1, endStream: false)
        #expect(head.version == .http1_1)
        #expect(head.uri == "/path?q=1")
        #expect(head.headers.first(name: "host") == "[::1]:8080")
        #expect(head.headers.first(name: "transfer-encoding") == "chunked")
        #expect(head.headers.first(name: "content-length") == nil)
        #expect(head.headers.first(name: "content-encoding") == "gzip")
        #expect(original.headers.first(name: "content-length") == "3")
        #expect(!original.headers.contains(name: "host"))
        let channel = EmbeddedChannel(handler: HTTPMessageTranslation.requestEncoder())
        defer { _ = try? channel.finish() }
        try channel.writeOutbound(HTTPClientRequestPart.head(head))
        try channel.writeOutbound(HTTPClientRequestPart.body(.byteBuffer(ByteBuffer(string: "abc"))))
        let trailers = HTTPHeaders([("X-End", "a"), ("X-End", "b")])
        try channel.writeOutbound(HTTPClientRequestPart.end(HTTPMessageTranslation.trailers(trailers, destination: .http1_1, bodyAllowed: true)))
        let bytes = try drain(channel)
        #expect(bytes.hasPrefix("\(method.rawValue) /path?q=1 HTTP/1.1\r\n"))
        #expect(!bytes.contains("HTTP/2.0"))
        #expect(bytes.hasSuffix("\r\n\r\n3\r\nabc\r\n0\r\nX-End: a\r\nX-End: b\r\n\r\n"))
    }

    @Test func openH2ResponseWithLengthKeepsLateTrailerWirePosition() throws {
        let original = HTTPResponseHead(version: .init(major: 2, minor: 0), status: .ok, headers: HTTPHeaders([("Content-Length", "3")]))
        let head = try HTTPMessageTranslation.response(original, requestMethod: .GET, source: .http2, destination: .http1_1, endStream: false)
        #expect(original.headers.first(name: "content-length") == "3")
        #expect(head.headers.first(name: "content-length") == nil)
        let channel = EmbeddedChannel(handler: HTTPMessageTranslation.responseEncoder())
        defer { _ = try? channel.finish() }
        try channel.writeOutbound(HTTPServerResponsePart.head(head))
        try channel.writeOutbound(HTTPServerResponsePart.body(.byteBuffer(ByteBuffer(string: "abc"))))
        try channel.writeOutbound(HTTPServerResponsePart.end(HTTPMessageTranslation.trailers(HTTPHeaders([("X-End", "yes")]), destination: .http1_1, bodyAllowed: true)))
        let bytes = try drain(channel)
        #expect(bytes.hasPrefix("HTTP/1.1 200 OK\r\n"))
        #expect(bytes.hasSuffix("\r\n\r\n3\r\nabc\r\n0\r\nX-End: yes\r\n\r\n"))
    }

    @Test(arguments: [HTTPWireVersion.http1_0, .http1_1])
    func initialEndStreamProducesAnEmptyMessage(destination: HTTPWireVersion) throws {
        let request = HTTPRequestHead(version: .init(major: 2, minor: 0), method: .POST, uri: "/")
        let head = try HTTPMessageTranslation.request(request, target: target, source: .http2, destination: destination, endStream: true)
        #expect(head.headers.first(name: "content-length") == "0")
        #expect(!head.headers.contains(name: "transfer-encoding"))
        let response = try HTTPMessageTranslation.response(.init(version: .init(major: 2, minor: 0), status: .ok), requestMethod: .GET,
                                                          source: .http2, destination: destination, endStream: true)
        #expect(response.headers.first(name: "content-length") == "0")
        #expect(!response.headers.contains(name: "transfer-encoding"))
    }

    @Test(arguments: [(HTTPMethod.HEAD, 200, true), (.HEAD, 103, false), (.HEAD, 204, false), (.GET, 100, false), (.GET, 103, false), (.GET, 204, false), (.GET, 304, true)])
    func bodyForbiddenResponsesHaveNoChunksButKeepLegalRepresentationLength(method: HTTPMethod, status: Int, lengthAllowed: Bool) throws {
        let original = HTTPResponseHead(version: .init(major: 2, minor: 0), status: .init(statusCode: status),
                                        headers: HTTPHeaders([("Content-Length", "42"), ("Trailer", "X-End")]))
        let head = try HTTPMessageTranslation.response(original, requestMethod: method, source: .http2, destination: .http1_1, endStream: false)
        #expect(head.headers.first(name: "content-length") == (lengthAllowed ? "42" : nil))
        #expect(!head.headers.contains(name: "transfer-encoding"))
        #expect(!head.headers.contains(name: "trailer"))
        #expect(try HTTPMessageTranslation.trailers(HTTPHeaders([("X-End", "captured")]), destination: .http1_1, bodyAllowed: false) == nil)
        let channel = EmbeddedChannel(handler: HTTPMessageTranslation.responseEncoder())
        defer { _ = try? channel.finish() }
        try channel.writeOutbound(HTTPServerResponsePart.head(head))
        try channel.writeOutbound(HTTPServerResponsePart.end(nil))
        let first = try drain(channel)
        #expect(first.hasSuffix("\r\n\r\n"))
        #expect(!first.contains("0\r\n\r\n"))
        let next = HTTPResponseHead(version: .http1_1, status: .ok, headers: HTTPHeaders([("Content-Length", "2")]))
        try channel.writeOutbound(HTTPServerResponsePart.head(next))
        try channel.writeOutbound(HTTPServerResponsePart.body(.byteBuffer(ByteBuffer(string: "ok"))))
        try channel.writeOutbound(HTTPServerResponsePart.end(nil))
        #expect(try drain(channel) == "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok")
        #expect(original.headers.first(name: "content-length") == "42")
    }

    @Test func http10CannotSendChunkedOrTrailersAndUnknownRequestLengthFails() throws {
        let head = try HTTPMessageTranslation.response(.init(version: .http1_1, status: .ok, headers: HTTPHeaders([("Transfer-Encoding", "chunked"), ("Trailer", "X-End")])),
            requestMethod: .GET, source: .http1_1, destination: .http1_0, endStream: false)
        #expect(head.version == .http1_0)
        #expect(!head.headers.contains(name: "transfer-encoding"))
        #expect(!head.headers.contains(name: "trailer"))
        #expect(head.headers.first(name: "connection") == "close")
        #expect(try HTTPMessageTranslation.trailers(HTTPHeaders([("X-End", "a")]), destination: .http1_0, bodyAllowed: true) == nil)
        #expect(throws: HTTPTranslationError.self) {
            try HTTPMessageTranslation.request(.init(version: .init(major: 2, minor: 0), method: .GET, uri: "/"), target: target,
                source: .http2, destination: .http1_0, endStream: false)
        }
        let fixed = try HTTPMessageTranslation.request(.init(version: .init(major: 2, minor: 0), method: .GET, uri: "/", headers: HTTPHeaders([("Content-Length", "3")])),
            target: target, source: .http2, destination: .http1_0, endStream: false)
        #expect(fixed.headers.first(name: "content-length") == "3")
        #expect(!fixed.headers.contains(name: "transfer-encoding"))
    }

    @Test func hopFieldsAreRemovedWhileCookieAndSetCookieOrderRemain() throws {
        let fields = HTTPHeaders([("Connection", "keep-alive, X-Hop"), ("X-First", "1"), ("X-Hop", "secret"), ("Keep-Alive", "timeout=5"),
                                  ("Proxy-Connection", "keep-alive"), ("TE", "trailers"), ("Cookie", "a=1"), ("X-Middle", "2"), ("Cookie", "b=2")])
        let original = HTTPRequestHead(version: .http1_1, method: .OPTIONS, uri: "*", headers: fields)
        let h2 = try HTTPMessageTranslation.request(original, target: .init(host: "example.com", port: 80, originForm: "*", defaultPort: 80),
            source: .http1_1, destination: .http2, endStream: true)
        #expect(h2.uri == "*")
        #expect(h2.headers.map(\.name) == ["x-first", "te", "cookie", "x-middle", "cookie", "host"])
        #expect(h2.headers.first(name: "te") == "trailers")
        let h1 = try HTTPMessageTranslation.request(h2, target: .init(host: "example.com", port: 80, originForm: "*", defaultPort: 80),
            source: .http2, destination: .http1_1, endStream: true)
        #expect(h1.uri == "*")
        #expect(h1.headers["cookie"] == ["a=1; b=2"])
        #expect(original.headers.first(name: "X-Hop") == "secret")
        let response = try HTTPMessageTranslation.response(.init(version: .http1_1, status: .ok,
            headers: HTTPHeaders([("Set-Cookie", "a=1"), ("X-Between", "yes"), ("Set-Cookie", "b=2"), ("Content-Encoding", "br")])),
            requestMethod: .GET, source: .http1_1, destination: .http2, endStream: false)
        #expect(response.headers.map(\.name) == ["set-cookie", "x-between", "set-cookie", "content-encoding"])
        #expect(response.headers["set-cookie"] == ["a=1", "b=2"])
        #expect(response.headers.first(name: "content-encoding") == "br")
    }

    @Test(arguments: ["gzip", "trailers, gzip", "trailers;q=1", ""])
    func invalidTEIsRejectedForH2(value: String) {
        #expect(throws: HTTPTranslationError.self) {
            try HTTPMessageTranslation.request(.init(version: .http1_1, method: .GET, uri: "/", headers: HTTPHeaders([("TE", value)])),
                target: target, source: .http1_1, destination: .http2, endStream: false)
        }
    }

    @Test(arguments: ["gzip", "gzip, chunked", "compress"])
    func unsupportedTransferCodingFailsBeforeH2Head(value: String) {
        #expect(throws: HTTPTranslationError.self) {
            try HTTPMessageTranslation.response(.init(version: .http1_1, status: .ok, headers: HTTPHeaders([("Transfer-Encoding", value)])),
                requestMethod: .GET, source: .http1_1, destination: .http2, endStream: false)
        }
    }

    @Test(arguments: ["custom; p=\"unterminated, chunked", "custom; p=\"escape\\"])
    func malformedTransferParameterQuotesCannotBecomeATargetHead(value: String) {
        #expect(throws: HTTPTranslationError.self) {
            try HTTPMessageTranslation.response(.init(version: .http1_1, status: .ok, headers: HTTPHeaders([("Transfer-Encoding", value)])),
                requestMethod: .GET, source: .http1_1, destination: .http1_1, endStream: false)
        }
    }

    @Test func decodedChunkedBecomesH2EntityWithoutRemovingContentEncoding() throws {
        let response = try HTTPMessageTranslation.response(.init(version: .http1_1, status: .ok,
            headers: HTTPHeaders([("Transfer-Encoding", "chunked"), ("Content-Encoding", "gzip")])),
            requestMethod: .GET, source: .http1_1, destination: .http2, endStream: false)
        #expect(response.version == .init(major: 2, minor: 0))
        #expect(!response.headers.contains(name: "transfer-encoding"))
        #expect(response.headers.first(name: "content-encoding") == "gzip")
    }

    @Test(arguments: ["-1", "+3", "3x", "18446744073709551616", "3, 4", ""])
    func invalidContentLengthCannotBecomeTargetFraming(value: String) {
        #expect(throws: HTTPTranslationError.self) {
            try HTTPMessageTranslation.request(.init(version: .http1_1, method: .POST, uri: "/", headers: HTTPHeaders([("Content-Length", value)])),
                target: target, source: .http1_1, destination: .http2, endStream: false)
        }
    }

    @Test(arguments: [("Bad Name", "x"), (":path", "/"), ("X", "bad\r\ninjected: x"), ("X", "bad\u{0}"), ("X", "bad\u{7f}")])
    func illegalRegularHeadersFailRatherThanReachAnEncoder(name: String, value: String) {
        #expect(throws: HTTPTranslationError.self) {
            try HTTPMessageTranslation.request(.init(version: .http1_1, method: .GET, uri: "/", headers: HTTPHeaders([(name, value)])),
                target: target, source: .http1_1, destination: .http2, endStream: true)
        }
        #expect(throws: HTTPTranslationError.self) {
            try HTTPMessageTranslation.trailers(HTTPHeaders([(name, value)]), destination: .http2, bodyAllowed: true)
        }
    }

    // MARK: Explicit body length

    @Test(arguments: [
        (HTTPWireVersion.http1_1, HTTPWireVersion.http1_1, HTTPHeaders([("Transfer-Encoding", "chunked")])),
        (.http1_1, .http1_0, HTTPHeaders([("Content-Length", "99")])),
        (.http2, .http1_1, HTTPHeaders([("content-length", "99")])),
        (.http1_1, .http2, HTTPHeaders([("Transfer-Encoding", "gzip, chunked")])),
        // Source framing that would be invalid is replaced, not validated.
        (.http1_1, .http1_1, HTTPHeaders([("Content-Length", "1"), ("Transfer-Encoding", "chunked")])),
    ])
    func explicitRequestLengthReplacesSourceFraming(source: HTTPWireVersion, destination: HTTPWireVersion,
                                                    framing: HTTPHeaders) throws {
        var original = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/", headers: framing)
        original.headers.add(name: "X-Kept", value: "1")
        let unchanged = original
        let head = try HTTPMessageTranslation.request(original, target: target, source: source, destination: destination,
                                                      endStream: false, bodyLength: 5)
        #expect(head.headers["content-length"] == ["5"])
        #expect(!head.headers.contains(name: "transfer-encoding"))
        #expect(head.headers["x-kept"] == ["1"])
        if destination == .http2 { #expect(head.headers.contains { $0.name == "content-length" }) }
        #expect(original == unchanged)
    }

    @Test func explicitZeroLengthKeepsABodylessRequestBodyless() throws {
        let original = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/")
        let head = try HTTPMessageTranslation.request(original, target: target, source: .http2, destination: .http1_1,
                                                      endStream: false, bodyLength: 0)
        #expect(!head.headers.contains(name: "content-length"))
        #expect(!head.headers.contains(name: "transfer-encoding"))
        let declared = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/",
                                       headers: HTTPHeaders([("Transfer-Encoding", "chunked")]))
        let empty = try HTTPMessageTranslation.request(declared, target: target, source: .http1_1, destination: .http1_1,
                                                       endStream: false, bodyLength: 0)
        #expect(empty.headers["content-length"] == ["0"])
        #expect(!empty.headers.contains(name: "transfer-encoding"))
    }

    @Test(arguments: [HTTPWireVersion.http1_0, .http1_1, .http2])
    func explicitResponseLengthReplacesSourceFramingAndStaysReusable(destination: HTTPWireVersion) throws {
        let original = HTTPResponseHead(version: .http1_1, status: .ok,
                                        headers: HTTPHeaders([("Transfer-Encoding", "chunked"), ("X-Kept", "1")]))
        let head = try HTTPMessageTranslation.response(original, requestMethod: .GET, source: .http1_1,
                                                       destination: destination, endStream: false, bodyLength: 7)
        #expect(head.headers["content-length"] == ["7"])
        #expect(!head.headers.contains(name: "transfer-encoding"))
        #expect(head.headers["x-kept"] == ["1"])
        switch destination {
        case .http1_0: #expect(head.headers["connection"] == ["keep-alive"])
        case .http1_1: #expect(!head.headers.contains(name: "connection"))
        case .http2: #expect(head.headers.contains { $0.name == "content-length" })
        }
    }

    @Test(arguments: [
        (HTTPMethod.HEAD, HTTPResponseStatus.ok, ["7"]),
        (.GET, .notModified, ["7"]),
        (.GET, .noContent, []),
    ])
    func explicitResponseLengthOnABodylessResponseOnlyDescribesTheRepresentation(
        method: HTTPMethod, status: HTTPResponseStatus, expected: [String]
    ) throws {
        let original = HTTPResponseHead(version: .http1_1, status: status, headers: HTTPHeaders([("Content-Length", "3")]))
        let head = try HTTPMessageTranslation.response(original, requestMethod: method, source: .http1_1,
                                                       destination: .http1_1, endStream: false, bodyLength: 7)
        #expect(head.headers["content-length"] == expected)
        #expect(!head.headers.contains(name: "transfer-encoding"))
    }

    @Test func nilLengthKeepsTodaysSourceFraming() throws {
        let original = HTTPResponseHead(version: .http1_1, status: .ok, headers: HTTPHeaders([("Transfer-Encoding", "chunked")]))
        let implicit = try HTTPMessageTranslation.response(original, requestMethod: .GET, source: .http1_1,
                                                           destination: .http1_1, endStream: false)
        let explicitNil = try HTTPMessageTranslation.response(original, requestMethod: .GET, source: .http1_1,
                                                              destination: .http1_1, endStream: false, bodyLength: nil)
        #expect(implicit == explicitNil)
        #expect(implicit.headers["transfer-encoding"] == ["chunked"])
    }

    @Test func explicitLengthStillRejectsInvalidFields() {
        let original = HTTPResponseHead(version: .http1_1, status: .ok, headers: HTTPHeaders([("Bad Name", "1")]))
        #expect(throws: HTTPTranslationError.invalidHeader) {
            try HTTPMessageTranslation.response(original, requestMethod: .GET, source: .http1_1,
                                                destination: .http1_1, endStream: false, bodyLength: 1)
        }
    }

    @Test func trailerHopAndFramingFieldsAreNotForwardedAsMetadata() throws {
        let original = HTTPHeaders([("X-End", "1"), ("Connection", "X-Hop"), ("X-Hop", "no"), ("Content-Length", "3"), ("Transfer-Encoding", "chunked"), ("X-End", "2")])
        let result = try #require(try HTTPMessageTranslation.trailers(original, destination: .http2, bodyAllowed: true))
        #expect(result.map(\.name) == ["x-end", "x-end"])
        #expect(result["x-end"] == ["1", "2"])
        #expect(original.first(name: "content-length") == "3")
    }

    private func drain(_ channel: EmbeddedChannel) throws -> String {
        var bytes = ""
        while let part = try channel.readOutbound(as: IOData.self) {
            if case .byteBuffer(let buffer) = part { bytes += String(decoding: buffer.readableBytesView, as: UTF8.self) }
            else { Issue.record("unexpected file region") }
        }
        return bytes
    }
}


extension HTTPMessageTranslationTests {
    @Test(arguments: [HTTPWireVersion.http1_0, .http1_1], [false, true])
    func fullBodyNominatedLengthSurvivesFinalEncoder(destination: HTTPWireVersion, replaced: Bool) throws {
        for response in [false, true] {
            let fields = HTTPHeaders([("Connection", "Content-Length"), ("Content-Length", "3")])
            let entity = replaced ? "hello" : "abc"
            let semantic: HTTPMessageHead = response ? .response(status: 200, reason: nil, headers: fields.fields)
                : .request(.init(scheme: "http", host: "example.test", port: 80, method: "POST", pathAndQuery: "/"), headers: fields.fields)
            let plan = try BreakpointFraming.plan(original: semantic, edited: semantic,
                body: .init(length: Int64(entity.utf8.count), complete: true, changed: replaced),
                source: .http1_1, target: destination, requestMethod: response ? "GET" : "POST")
            let channel = EmbeddedChannel()
            defer { _ = try? channel.finish() }
            if response {
                try channel.pipeline.syncOperations.addHandlers(HTTPMessageTranslation.responseEncoder(), HTTP1TransferCodingFramer<HTTPResponseHead>())
                let head = try HTTPMessageTranslation.response(.init(version: .http1_1, status: .ok, headers: fields), requestMethod: .GET,
                    source: .http1_1, destination: destination, endStream: false, framingPlan: plan)
                try channel.writeOutbound(HTTPServerResponsePart.head(head))
                try channel.writeOutbound(HTTPServerResponsePart.body(.byteBuffer(ByteBuffer(string: entity))))
                try channel.writeOutbound(HTTPServerResponsePart.end(nil))
            } else {
                try channel.pipeline.syncOperations.addHandlers(HTTPMessageTranslation.requestEncoder(), HTTP1TransferCodingFramer<HTTPRequestHead>())
                let head = try HTTPMessageTranslation.request(.init(version: .http1_1, method: .POST, uri: "/", headers: fields),
                    target: .init(host: "example.test", port: 80, originForm: "/", defaultPort: 80),
                    source: .http1_1, destination: destination, endStream: false, framingPlan: plan)
                try channel.writeOutbound(HTTPClientRequestPart.head(head))
                try channel.writeOutbound(HTTPClientRequestPart.body(.byteBuffer(ByteBuffer(string: entity))))
                try channel.writeOutbound(HTTPClientRequestPart.end(nil))
            }
            let wire = try drain(channel)
            #expect(wire.lowercased().contains("content-length: \(entity.utf8.count)\r\n"))
            #expect(wire.hasSuffix("\r\n\r\n" + entity))
            #expect(!wire.lowercased().contains("connection: content-length"))
        }
    }

    @Test(arguments: [HTTPWireVersion.http1_0, .http2])
    func fullBodyOpaqueCompoundCodingCannotBecomeUnlabelledBytes(destination: HTTPWireVersion) throws {
        let head = HTTPMessageHead.response(status: 200, reason: nil, headers: [.init(name: "Transfer-Encoding", value: "gzip, chunked")])
        #expect(throws: HTTPTranslationError.self) {
            let plan = try BreakpointFraming.plan(original: head, edited: head,
                body: .init(length: 6, complete: true, changed: false), source: .http1_1, target: destination, requestMethod: "GET")
            _ = try HTTPMessageTranslation.response(.init(version: .http1_1, status: .ok, headers: HTTPHeaders(fields: head.headers)),
                requestMethod: .GET, source: .http1_1, destination: destination, endStream: false, framingPlan: plan)
        }
    }
}
