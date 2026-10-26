import Foundation
import Testing
import FlowStore
@testable import RulesEngine

private func target(
    _ scheme: String = "https", host: String = "api.example.com", port: Int = 443,
    method: String = "POST", path: String = "/v1/items?a=1"
) -> HTTPMessageTarget {
    HTTPMessageTarget(scheme: scheme, host: host, port: port, method: method, pathAndQuery: path)
}

private func request(_ target: HTTPMessageTarget = target(), _ headers: [HeaderField] = []) -> HTTPMessageHead {
    .request(target, headers: headers)
}

private func response(_ status: Int = 200, _ headers: [HeaderField] = []) -> HTTPMessageHead {
    .response(status: status, reason: nil, headers: headers)
}

private func field(_ name: String, _ value: String) -> HeaderField { HeaderField(name: name, value: value) }

private let unchangedBody = HTTPBodyDescriptor(length: 5, complete: true, changed: false)

private func failure(_ body: () throws -> Void) -> HTTPMutationError? {
    do { try body(); return nil } catch let error as HTTPMutationError { return error } catch { return nil }
}

@Suite("HTTPMutationValidator.validate")
struct HeadValidationTests {
    @Test func validDuplicateFieldsSurvive() throws {
        let head = response(200, [field("Set-Cookie", "a=1"), field("Set-Cookie", "b=2"), field("X", "")])
        try HTTPMutationValidator.validate(head: head, body: unchangedBody)
    }

    @Test func headerInjectionAndControlCharactersFailBeforeTheHead() {
        let cases: [(HeaderField, HTTPMutationError)] = [
            (field("X", "a\r\nInjected: 1"), .init(code: .invalidHeaderValue, field: .headerValue(name: "X"))),
            (field("X", "a\nb"), .init(code: .invalidHeaderValue, field: .headerValue(name: "X"))),
            (field("X", "a\u{0}b"), .init(code: .invalidHeaderValue, field: .headerValue(name: "X"))),
            (field("X", "a\u{7F}b"), .init(code: .invalidHeaderValue, field: .headerValue(name: "X"))),
            (field("Bad Name", "v"), .init(code: .invalidHeaderName, field: .header(name: "Bad Name"))),
            (field("", "v"), .init(code: .invalidHeaderName, field: .header(name: ""))),
            (field("X:Y", "v"), .init(code: .invalidHeaderName, field: .header(name: "X:Y"))),
            (field("X\r\nY", "v"), .init(code: .invalidHeaderName, field: .header(name: "X\r\nY"))),
            (field(":path", "/x"), .init(code: .protectedHeader, field: .header(name: ":path"))),
        ]
        for (header, expected) in cases {
            #expect(failure { try HTTPMutationValidator.validate(head: response(200, [header]), body: unchangedBody) } == expected)
        }
        // Horizontal tab and UTF-8 text are legitimate field content.
        #expect(failure { try HTTPMutationValidator.validate(head: response(200, [field("X", "a\tb \u{00E9}")]), body: unchangedBody) } == nil)
    }

    @Test func headerBlockLimitsAre64KiBAnd256Fields() {
        let fields256 = (0..<256).map { field("X-\($0)", "v") }
        #expect(failure { try HTTPMutationValidator.validate(head: response(200, fields256), body: unchangedBody) } == nil)
        let fields257 = (0..<257).map { field("X-\($0)", "v") }
        #expect(failure { try HTTPMutationValidator.validate(head: response(200, fields257), body: unchangedBody) }
                == .init(code: .tooManyHeaderFields, field: .headers))
        // name + value + 32 per field, as the transport counts it.
        let exact = field("X", String(repeating: "v", count: 65_536 - 32 - 1))
        #expect(failure { try HTTPMutationValidator.validate(head: response(200, [exact]), body: unchangedBody) } == nil)
        let over = field("X", String(repeating: "v", count: 65_536 - 32))
        #expect(failure { try HTTPMutationValidator.validate(head: response(200, [over]), body: unchangedBody) }
                == .init(code: .headerBlockTooLarge, field: .headers))
        let limits = RulesLimits(headerBytes: 100, headerFields: 2)
        #expect(failure { try HTTPMutationValidator.validate(head: response(200, [field("A", "1"), field("B", "2"), field("C", "3")]), body: unchangedBody, limits: limits) }
                == .init(code: .tooManyHeaderFields, field: .headers))
    }

    @Test func trailerBlockUsesTheSameLimitsAndRules() {
        let ok = HTTPBodyDescriptor(length: 1, complete: true, changed: false, trailers: [field("X-Sum", "1")])
        #expect(failure { try HTTPMutationValidator.validate(head: response(), body: ok) } == nil)
        let injected = HTTPBodyDescriptor(length: 1, complete: true, changed: false, trailers: [field("X-Sum", "1\r\nA: b")])
        #expect(failure { try HTTPMutationValidator.validate(head: response(), body: injected) }
                == .init(code: .invalidHeaderValue, field: .trailer(name: "X-Sum")))
        let framing = HTTPBodyDescriptor(length: 1, complete: true, changed: false, trailers: [field("Content-Length", "1")])
        #expect(failure { try HTTPMutationValidator.validate(head: response(), body: framing) }
                == .init(code: .protectedHeader, field: .trailer(name: "Content-Length")))
        let many = HTTPBodyDescriptor(length: 1, complete: true, changed: false, trailers: (0..<257).map { field("T-\($0)", "v") })
        #expect(failure { try HTTPMutationValidator.validate(head: response(), body: many) }
                == .init(code: .tooManyHeaderFields, field: .trailers))
    }

    @Test func statusMustBeAFinal200To599AndNeverSwitchingProtocols() {
        for status in [200, 204, 299, 301, 404, 599] {
            #expect(failure { try HTTPMutationValidator.validate(head: response(status), body: unchangedBody) } == nil, "\(status)")
        }
        for status in [0, 99, 100, 101, 103, 199, 600, 1000, -1] {
            #expect(failure { try HTTPMutationValidator.validate(head: response(status), body: unchangedBody) }
                    == .init(code: .invalidStatus, field: .status), "\(status)")
        }
        let reason = HTTPMessageHead.response(status: 200, reason: "OK\r\nX: y", headers: [])
        #expect(failure { try HTTPMutationValidator.validate(head: reason, body: unchangedBody) }
                == .init(code: .invalidReason, field: .reason))
    }

    @Test func requestTargetValidation() {
        func code(_ target: HTTPMessageTarget) -> HTTPMutationError? {
            failure { try HTTPMutationValidator.validate(head: request(target), body: unchangedBody) }
        }
        #expect(code(target()) == nil)
        #expect(code(target(method: "TRACE")) == nil)
        #expect(code(target(method: "PURGE")) == nil)
        #expect(code(target("http", host: "::1", port: 8080)) == nil)
        #expect(code(target("http", host: "2001:db8::1", port: 80)) == nil)
        #expect(code(target("http", host: "127.0.0.1", port: 80, method: "OPTIONS", path: "*")) == nil)
        #expect(code(target(method: "CONNECT")) == .init(code: .connectNotAllowed, field: .method))
        #expect(code(target(method: "GE T")) == .init(code: .invalidMethod, field: .method))
        #expect(code(target(method: "")) == .init(code: .invalidMethod, field: .method))
        #expect(code(target(method: "G\r\nET")) == .init(code: .invalidMethod, field: .method))
        #expect(code(target("ftp")) == .init(code: .invalidScheme, field: .scheme))
        #expect(code(target(host: "user:pw@host.test")) == .init(code: .userinfoNotAllowed, field: .host))
        #expect(code(target(host: "host.test#frag")) == .init(code: .fragmentNotAllowed, field: .host))
        #expect(code(target(host: "")) == .init(code: .invalidHost, field: .host))
        #expect(code(target(host: "a b.test")) == .init(code: .invalidHost, field: .host))
        #expect(code(target(host: "a\r\nb")) == .init(code: .invalidHost, field: .host))
        #expect(code(target(host: "bad:host")) == .init(code: .invalidHost, field: .host))
        #expect(code(target(host: "host.test/x")) == .init(code: .invalidHost, field: .host))
        #expect(code(target(port: 0)) == .init(code: .invalidPort, field: .port))
        #expect(code(target(port: 65_536)) == .init(code: .invalidPort, field: .port))
        #expect(code(target(path: "")) == .init(code: .invalidPath, field: .path))
        #expect(code(target(path: "noslash")) == .init(code: .invalidPath, field: .path))
        #expect(code(target(path: "/a b")) == .init(code: .invalidPath, field: .path))
        #expect(code(target(path: "/a\r\nHost: x")) == .init(code: .invalidPath, field: .path))
        #expect(code(target(path: "/a#frag")) == .init(code: .fragmentNotAllowed, field: .path))
        #expect(code(target(path: "http://other.test/x")) == .init(code: .invalidPath, field: .path))
    }

    @Test func framingHeadersMustBeConsistentButCapturedManagedFieldsAreLegal() {
        // A captured request legitimately carries Host, Content-Length, Expect, Connection.
        let captured = request(target(), [
            field("Host", "api.example.com"), field("Content-Length", "5"), field("Expect", "100-continue"),
            field("Connection", "keep-alive"), field("Keep-Alive", "timeout=5"), field("TE", "trailers"),
        ])
        #expect(failure { try HTTPMutationValidator.validate(head: captured, body: unchangedBody) } == nil)
        func code(_ headers: [HeaderField], body: HTTPBodyDescriptor = unchangedBody) -> HTTPMutationError? {
            failure { try HTTPMutationValidator.validate(head: request(target(), headers), body: body) }
        }
        #expect(code([field("Content-Length", "abc")]) == .init(code: .invalidContentLength, field: .contentLength))
        #expect(code([field("Content-Length", "-1")]) == .init(code: .invalidContentLength, field: .contentLength))
        #expect(code([field("Content-Length", "5"), field("Content-Length", "6")]) == .init(code: .invalidContentLength, field: .contentLength))
        #expect(code([field("Content-Length", "5, 5")]) == nil)
        #expect(code([field("Content-Length", "5"), field("Transfer-Encoding", "chunked")]) == .init(code: .invalidFraming, field: .contentLength))
        #expect(code([field("Connection", "a,,b")]) == .init(code: .invalidHeaderValue, field: .headerValue(name: "Connection")))
    }

    @Test func zeroLengthBodyIsLegal() throws {
        let empty = HTTPBodyDescriptor(length: 0, complete: true, changed: true)
        try HTTPMutationValidator.validate(head: request(target(), [field("Content-Length", "0")]), body: empty)
        let normalized = try HTTPMutationValidator.normalizeEdited(head: request(target(), [field("Content-Length", "9")]), body: empty)
        #expect(normalized.headers.values(for: "Content-Length").isEmpty)
    }

    @Test func changedBodyMustBeCompleteAndLengthMustBeNonNegative() {
        let partial = HTTPBodyDescriptor(length: 3, complete: false, changed: true, encodingChoice: .retainEncodedBytes)
        #expect(failure { try HTTPMutationValidator.validate(head: request(), body: partial) } == .init(code: .bodyIncomplete, field: .body))
        let negative = HTTPBodyDescriptor(length: -1, complete: true, changed: true)
        #expect(failure { try HTTPMutationValidator.validate(head: request(), body: negative) } == .init(code: .invalidContentLength, field: .body))
        let unknownLength = HTTPBodyDescriptor(length: nil, complete: true, changed: true)
        #expect(failure { try HTTPMutationValidator.validate(head: request(), body: unknownLength) } == nil)
    }
}

@Suite("HTTPMutationValidator.edits")
struct EditValidationTests {
    @Test func protectedFieldsCannotBeEdited() {
        let names = ["Host", "host", "Connection", "Proxy-Connection", "Proxy-Authorization", "Proxy-Authenticate",
                     "Keep-Alive", "Upgrade", "TE", "Transfer-Encoding", "Content-Length", "Trailer", "Expect", ":authority", ":Status"]
        for name in names {
            for operation in [HeaderEdit.set(name: name, value: "x"), .append(name: name, value: "x"), .remove(name: name)] {
                let error = failure { try HTTPMutationValidator.validateEdits([operation], originalHeaders: []) }
                #expect(error == .init(code: .protectedHeader, field: .header(name: name)), "\(name)")
            }
        }
    }

    @Test func connectionNominatedFieldsAreProtected() {
        let original = [field("Connection", "keep-alive, X-Hop , close"), field("X-Hop", "1")]
        #expect(failure { try HTTPMutationValidator.validateEdits([.set(name: "x-hop", value: "2")], originalHeaders: original) }
                == .init(code: .nominatedHeader, field: .header(name: "x-hop")))
        #expect(failure { try HTTPMutationValidator.validateEdits([.remove(name: "X-HOP")], originalHeaders: original) }
                == .init(code: .nominatedHeader, field: .header(name: "X-HOP")))
        #expect(failure { try HTTPMutationValidator.validateEdits([.set(name: "X-Other", value: "2")], originalHeaders: original) } == nil)
    }

    @Test func ordinaryFieldsAreEditable() {
        let operations: [HeaderEdit] = [
            .set(name: "Content-Type", value: "text/plain"), .append(name: "Set-Cookie", value: "a=1"),
            .append(name: "Set-Cookie", value: "b=2"), .remove(name: "Authorization"), .set(name: "Cookie", value: "k=v"),
            .set(name: "Content-Encoding", value: "gzip"), .set(name: "ETag", value: "\"x\""),
        ]
        #expect(failure { try HTTPMutationValidator.validateEdits(operations, originalHeaders: []) } == nil)
    }

    @Test func invalidNamesAndValuesFailWithFieldIdentity() {
        #expect(failure { try HTTPMutationValidator.validateEdits([.set(name: "Bad Name", value: "v")], originalHeaders: []) }
                == .init(code: .invalidHeaderName, field: .header(name: "Bad Name")))
        #expect(failure { try HTTPMutationValidator.validateEdits([.append(name: "", value: "v")], originalHeaders: []) }
                == .init(code: .invalidHeaderName, field: .header(name: "")))
        // An empty name is "all keys" (R8F2) for the edits that have no field to add.
        #expect(failure { try HTTPMutationValidator.validateEdits([.remove(name: "")], originalHeaders: []) } == nil)
        #expect(failure { try HTTPMutationValidator.validateEdits([.append(name: "X", value: "a\u{0}")], originalHeaders: []) }
                == .init(code: .invalidHeaderValue, field: .headerValue(name: "X")))
    }

    @Test func upgradeCandidatesProtectHandshakeFields() {
        let upgrade = [field("Connection", "Upgrade"), field("Upgrade", "websocket"),
                       field("Sec-WebSocket-Key", "k"), field("Sec-WebSocket-Extensions", "permessage-deflate")]
        for name in ["Sec-WebSocket-Key", "sec-websocket-protocol", "Sec-WebSocket-Extensions", "Upgrade", "Connection"] {
            #expect(failure { try HTTPMutationValidator.validateEdits([.set(name: name, value: "z")], originalHeaders: upgrade) }
                    == .init(code: .protectedHeader, field: .header(name: name)), "\(name)")
        }
        // Without an upgrade the Sec-WebSocket-* names are ordinary.
        #expect(failure { try HTTPMutationValidator.validateEdits([.set(name: "Sec-WebSocket-Key", value: "z")], originalHeaders: []) } == nil)
        // A flag lets a response to an upgrade request keep the same protection.
        #expect(failure { try HTTPMutationValidator.validateEdits([.set(name: "Sec-WebSocket-Accept", value: "z")], originalHeaders: [], upgradeCandidate: true) }
                == .init(code: .protectedHeader, field: .header(name: "Sec-WebSocket-Accept")))
        #expect(failure { try HTTPMutationValidator.validateEdits([.append(name: "X-Trace", value: "1")], originalHeaders: upgrade) } == nil)
    }
}

@Suite("HTTPMutationValidator.validateEdit")
struct TableEditValidationTests {
    private let original = request(target(), [
        field("Host", "api.example.com"), field("Content-Length", "5"), field("Expect", "100-continue"),
        field("Connection", "keep-alive, X-Hop"), field("X-Hop", "1"), field("Accept", "*/*"), field("Set-Cookie", "a=1"),
    ])

    @Test func unchangedManagedHeadersAreAccepted() throws {
        var headers = original.headers
        headers.append(field("X-New", "1"))
        headers.removeAll { $0.name == "Accept" }
        let edited = HTTPMessageHead.request(target(method: "PUT", path: "/other?q=1&q=2"), headers: headers)
        try HTTPMutationValidator.validateEdit(original: original, edited: edited, body: unchangedBody)
    }

    @Test func changingRemovingOrAddingProtectedFieldsIsRejected() {
        func code(_ edit: (inout [HeaderField]) -> Void) -> HTTPMutationError? {
            var headers = original.headers
            edit(&headers)
            return failure { try HTTPMutationValidator.validateEdit(original: original, edited: .request(target(), headers: headers), body: unchangedBody) }
        }
        #expect(code { $0[0].value = "evil.test" } == .init(code: .protectedHeader, field: .header(name: "Host")))
        #expect(code { $0.removeAll { $0.name == "Content-Length" } } == .init(code: .protectedHeader, field: .header(name: "Content-Length")))
        #expect(code { $0.append(field("Content-Length", "5")) } == .init(code: .protectedHeader, field: .header(name: "Content-Length")))
        #expect(code { $0.append(field("Transfer-Encoding", "chunked")) } == .init(code: .protectedHeader, field: .header(name: "Transfer-Encoding")))
        #expect(code { $0.append(field("Upgrade", "websocket")) } == .init(code: .protectedHeader, field: .header(name: "Upgrade")))
        #expect(code { $0.append(field("proxy-authorization", "Basic x")) } == .init(code: .protectedHeader, field: .header(name: "proxy-authorization")))
        #expect(code { $0.removeAll { $0.name == "Expect" } } == .init(code: .protectedHeader, field: .header(name: "Expect")))
        #expect(code { $0[4].value = "2" } == .init(code: .nominatedHeader, field: .header(name: "X-Hop")))
        #expect(code { $0.removeAll { $0.name == "Connection" } } == .init(code: .protectedHeader, field: .header(name: "Connection")))
        #expect(code { $0.append(field(":authority", "x")) } == .init(code: .protectedHeader, field: .header(name: ":authority")))
        // Case changes of an unchanged protected value are not edits of its content.
        #expect(code { $0[0].name = "HOST" } == nil)
    }

    @Test func editedTargetAndHeadsAreStructurallyValidated() {
        func code(_ edited: HTTPMessageHead) -> HTTPMutationError? {
            failure { try HTTPMutationValidator.validateEdit(original: original, edited: edited, body: unchangedBody) }
        }
        let headers = original.headers
        #expect(code(.request(target(method: "CONNECT"), headers: headers)) == .init(code: .connectNotAllowed, field: .method))
        #expect(code(.request(target(host: "u@h.test"), headers: headers)) == .init(code: .userinfoNotAllowed, field: .host))
        #expect(code(.request(target(path: "/x#f"), headers: headers)) == .init(code: .fragmentNotAllowed, field: .path))
        #expect(code(.request(target("https", host: "other.test", port: 8443), headers: headers)) == nil)
        #expect(code(response(200, headers)) == .init(code: .messageKindMismatch, field: .message))
    }

    @Test func responseEditsKeepStatusFinalAndProtectedFieldsFixed() throws {
        let originalResponse = response(200, [field("Content-Length", "5"), field("Content-Type", "text/plain"), field("Set-Cookie", "a=1"), field("Set-Cookie", "b=2")])
        try HTTPMutationValidator.validateEdit(
            original: originalResponse, edited: response(418, [field("Content-Length", "5"), field("Content-Type", "x/y"), field("Set-Cookie", "a=1"), field("Set-Cookie", "b=2"), field("Set-Cookie", "c=3")]),
            body: unchangedBody)
        #expect(failure { try HTTPMutationValidator.validateEdit(original: originalResponse, edited: response(101, originalResponse.headers), body: unchangedBody) }
                == .init(code: .invalidStatus, field: .status))
        #expect(failure { try HTTPMutationValidator.validateEdit(original: originalResponse, edited: response(200, [field("Content-Length", "99")]), body: unchangedBody) }
                == .init(code: .protectedHeader, field: .header(name: "Content-Length")))
    }

    @Test func upgradeCandidateKeepsHandshakeFieldsFixed() {
        let upgrade = request(target("http", host: "ws.test", port: 80, method: "GET", path: "/chat"), [
            field("Connection", "Upgrade"), field("Upgrade", "websocket"), field("Sec-WebSocket-Key", "k")])
        let changed = HTTPMessageHead.request(target("http", host: "ws.test", port: 80, method: "GET", path: "/chat"), headers: [
            field("Connection", "Upgrade"), field("Upgrade", "websocket"), field("Sec-WebSocket-Key", "other")])
        #expect(failure { try HTTPMutationValidator.validateEdit(original: upgrade, edited: changed, body: unchangedBody) }
                == .init(code: .protectedHeader, field: .header(name: "Sec-WebSocket-Key")))
    }
}

@Suite("HTTPMutationValidator.normalizeEdited")
struct NormalizeEditedTests {
    private let digests = [
        field("Content-MD5", "abc"), field("Digest", "sha-256=x"), field("Content-Digest", "sha-256=:x:"),
        field("Repr-Digest", "sha-256=:x:"), field("Trailer", "X-Sum"), field("ETag", "\"v1\""),
        field("Content-Type", "text/plain"), field("Content-Length", "9"), field("Transfer-Encoding", "chunked"),
    ]

    @Test func unchangedBodyKeepsEverything() throws {
        let head = response(200, digests.filter { !["Content-Length", "Transfer-Encoding"].contains($0.name) })
        #expect(try HTTPMutationValidator.normalizeEdited(head: head, body: unchangedBody) == head)
    }

    @Test func changedBodyDropsStaleIntegrityAndFramingFields() throws {
        let body = HTTPBodyDescriptor(length: 3, complete: true, changed: true, trailers: [field("X-Sum", "1")])
        let result = try HTTPMutationValidator.normalizeEdited(head: response(200, digests), body: body)
        #expect(result.headers == [field("Content-Type", "text/plain")])
        let requestResult = try HTTPMutationValidator.normalizeEdited(head: request(target(), digests), body: body)
        // Only responses lose ETag; a request's validators are unrelated to the replaced entity.
        #expect(requestResult.headers.values(for: "ETag") == ["\"v1\""])
        #expect(requestResult.headers.values(for: "Digest").isEmpty)
        #expect(requestResult.headers.values(for: "Trailer").isEmpty)
    }

    @Test func changedBodyTrailersAreDropped() throws {
        let body = HTTPBodyDescriptor(length: 3, complete: true, changed: true, trailers: [field("X-Sum", "1")])
        let normalized = try HTTPMutationValidator.normalize(head: response(), body: body)
        #expect(normalized.trailers.isEmpty)
        let kept = try HTTPMutationValidator.normalize(
            head: response(), body: HTTPBodyDescriptor(length: 3, complete: true, changed: false, trailers: [field("X-Sum", "1")]))
        #expect(kept.trailers == [field("X-Sum", "1")])
    }

    @Test func changedBodyWithContentEncodingNeedsAnExplicitChoice() throws {
        let head = response(200, [field("Content-Encoding", "gzip"), field("Content-Type", "x/y")])
        let undecided = HTTPBodyDescriptor(length: 3, complete: true, changed: true)
        #expect(failure { _ = try HTTPMutationValidator.normalizeEdited(head: head, body: undecided) }
                == .init(code: .encodingChoiceRequired, field: .contentEncoding))
        let retained = try HTTPMutationValidator.normalizeEdited(
            head: head, body: HTTPBodyDescriptor(length: 3, complete: true, changed: true, encodingChoice: .retainEncodedBytes))
        #expect(retained.headers.values(for: "Content-Encoding") == ["gzip"])
        let removed = try HTTPMutationValidator.normalizeEdited(
            head: head, body: HTTPBodyDescriptor(length: 3, complete: true, changed: true, encodingChoice: .removeEncoding))
        #expect(removed.headers.values(for: "Content-Encoding").isEmpty)
        #expect(removed.headers.values(for: "Content-Type") == ["x/y"])
        // Identity or absent encodings need no decision.
        _ = try HTTPMutationValidator.normalizeEdited(head: response(200, [field("Content-Encoding", "identity")]), body: undecided)
        _ = try HTTPMutationValidator.normalizeEdited(head: response(), body: undecided)
        // Choosing while nothing changed is meaningless but harmless.
        let unchanged = HTTPBodyDescriptor(length: 3, complete: true, changed: false, encodingChoice: .removeEncoding)
        #expect(try HTTPMutationValidator.normalizeEdited(head: head, body: unchanged) == head)
    }

    @Test func normalizedHeadIsRevalidated() {
        let body = HTTPBodyDescriptor(length: 3, complete: true, changed: true)
        #expect(failure { _ = try HTTPMutationValidator.normalizeEdited(head: response(101), body: body) } == .init(code: .invalidStatus, field: .status))
        #expect(failure { _ = try HTTPMutationValidator.normalizeEdited(head: request(target(host: "u@h")), body: body) } == .init(code: .userinfoNotAllowed, field: .host))
        #expect(failure { _ = try HTTPMutationValidator.normalizeEdited(head: response(200, [field("X", "a\r\nb")]), body: body) }
                == .init(code: .invalidHeaderValue, field: .headerValue(name: "X")))
    }
}
