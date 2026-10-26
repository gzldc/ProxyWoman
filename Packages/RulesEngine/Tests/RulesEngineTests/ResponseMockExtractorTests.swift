import FlowStore
import Foundation
import Testing
@testable import RulesEngine

// MARK: support

private let target = HTTPMessageTarget(scheme: "https", host: "api.test", port: 443, method: "GET", pathAndQuery: "/v1/items?id=1")

private func field(_ name: String, _ value: String) -> HeaderField { HeaderField(name: name, value: value) }

private func slice(_ bytes: Data, offset: Int = 0) -> HTTPBodySlice {
    HTTPBodySlice(ref: .memory(bytes), offset: offset, count: bytes.count - offset)
}

private func response(
    _ boundary: HTTPMessageBoundary = .downstreamResponse, status: Int = 200, headers: [HeaderField] = [],
    body: HTTPBodySlice? = nil, state: HTTPBodyState = .complete, observed: UInt64? = nil,
    transfer: HTTPTransferState = .finished
) -> HTTPMessageSnapshot {
    HTTPMessageSnapshot(
        boundary: boundary, head: .response(status: status, reason: nil, headers: headers), body: body,
        bodyState: state, observedBytes: observed ?? UInt64(body?.count ?? 0), transferState: transfer)
}

private func flow(_ messages: [HTTPMessageSnapshot], method: String = "GET") -> Flow {
    var flow = Flow(id: 1, scheme: "https", method: method, host: "api.test", port: 443, path: "/v1/items?id=1")
    flow.state = .completed
    flow.messages = Dictionary(uniqueKeysWithValues: messages.map { ($0.boundary, $0) })
    return flow
}

private func extract(_ flow: Flow, limits: RulesLimits = RulesLimits()) -> Result<ResponseMockSource, MockBlockReason> {
    ResponseMockExtractor.extract(from: flow, limits: limits)
}

private func blocked(_ flow: Flow, limits: RulesLimits = RulesLimits()) -> MockBlockReason? {
    if case .failure(let reason) = extract(flow, limits: limits) { reason } else { nil }
}

// MARK: tests

@Suite struct ResponseMockExtractorTests {
    @Test func completeSmallBodyExtracts() throws {
        let body = slice(Data("hello".utf8))
        let source = try extract(flow([response(status: 201, headers: [field("Content-Type", "text/plain")], body: body)])).get()
        #expect(source.status == 201 && source.size == 5 && source.body == body)
        #expect(source.headers == [field("Content-Type", "text/plain")])
        #expect(source.displayName == "response-body.bin")
    }

    @Test func prefersDownstreamResponseOverGenerated() throws {
        let downstream = response(status: 200, body: slice(Data("seen".utf8)))
        let generated = response(.generatedResponse, status: 503, body: slice(Data("local".utf8)))
        let source = try extract(flow([generated, downstream])).get()
        #expect(source.status == 200 && source.size == 4)
    }

    @Test func generatedResponseUsedForMapLocalFlow() throws {
        let generated = response(.generatedResponse, status: 202, headers: [field("X-Local", "1")], body: slice(Data("local".utf8)))
        let source = try extract(flow([generated])).get()
        #expect(source.status == 202 && source.size == 5 && source.headers == [field("X-Local", "1")])
    }

    @Test func legacyFlowFallbackWorks() throws {
        var legacy = flow([])
        legacy.statusCode = 404
        legacy.responseHeaders = [field("Content-Type", "text/html")]
        legacy.responseBody = .memory(Data("nope".utf8))
        legacy.bytesReceived = 4
        let source = try extract(legacy).get()
        #expect(source.status == 404 && source.size == 4 && source.headers == [field("Content-Type", "text/html")])
        #expect(try source.body?.load() == Data("nope".utf8))

        legacy.responseBodyTruncated = true
        #expect(blocked(legacy) == .bodyTruncated)
        legacy.responseBodyTruncated = false
        legacy.bytesReceived = 40
        #expect(blocked(legacy) == .bodyIncomplete)
        legacy.bytesReceived = 4
        legacy.state = .failed("reset")
        #expect(blocked(legacy) == .bodyIncomplete)
        legacy.statusCode = nil
        #expect(blocked(legacy) == .noResponse)
    }

    @Test func headersDropHopByHopAndFraming() throws {
        let headers = [
            field("Connection", "keep-alive"), field("Transfer-Encoding", "chunked"), field("Content-Length", "5"),
            field("Keep-Alive", "timeout=5"), field("Proxy-Authenticate", "Basic"), field("Trailer", "X-T"),
            field("TE", "trailers"), field("Upgrade", "h2c"),
            field("Set-Cookie", "a=1"), field("Content-Type", "text/plain"), field("Set-Cookie", "b=2"),
            field("Content-Encoding", "gzip"), field("Cache-Control", "no-store"), field("ETag", "\"x\""),
        ]
        let source = try extract(flow([response(headers: headers, body: slice(Data("hello".utf8)))])).get()
        #expect(source.headers == [
            field("Set-Cookie", "a=1"), field("Content-Type", "text/plain"), field("Set-Cookie", "b=2"),
            field("Content-Encoding", "gzip"), field("Cache-Control", "no-store"), field("ETag", "\"x\""),
        ])
        for name in source.headers.map({ $0.name.lowercased() }) {
            #expect(!ResponseMockExtractor.droppedHeaderNames.contains(name))
        }
        #expect(ResponseMockExtractor.droppedHeaderNames.isSuperset(of: [
            "connection", "keep-alive", "proxy-authenticate", "proxy-authorization", "proxy-connection",
            "te", "trailer", "transfer-encoding", "upgrade", "content-length",
        ]))
    }

    @Test func validatorRejectedHeaderIsDropped() throws {
        // Connection-nominated fields, invalid names/values and pseudo fields are what the shared
        // validator refuses; each is dropped on its own and the rest stay.
        let headers = [
            field("Connection", "close, X-Hop"), field("X-Hop", "1"), field("Bad Name", "1"), field("X-Bad", "a\r\nb"),
            field(":status", "200"), field("Host", "api.test"), field("X-Keep", "yes"),
        ]
        let source = try extract(flow([response(headers: headers)])).get()
        #expect(source.headers == [field("X-Keep", "yes")])
    }

    @Test func connectTunnelBlocked() {
        var tunnel = flow([], method: "CONNECT")
        tunnel.state = .tunnel
        #expect(blocked(tunnel) == .tunnel)
        // Even a snapshot that looks like a response does not make a tunnel mockable.
        #expect(blocked(flow([response()], method: "CONNECT")) == .tunnel)
    }

    @Test func flowWithoutResponseBlocked() {
        #expect(blocked(flow([])) == .noResponse)
        var failed = flow([])
        failed.state = .failed("connection refused")
        #expect(blocked(failed) == .noResponse)
        var running = flow([])
        running.state = .inProgress
        #expect(blocked(running) == .noResponse)
        // Only a request boundary was recorded.
        let request = HTTPMessageSnapshot(boundary: .downstreamRequest, head: .request(target, headers: []))
        #expect(blocked(flow([request])) == .noResponse)
    }

    @Test func websocketUpgradeBlocked() {
        let upgrade = response(status: 101, headers: [field("Connection", "Upgrade"), field("Upgrade", "websocket")])
        #expect(blocked(flow([upgrade])) == .upgrade)
    }

    @Test func status1xxBlocked() {
        for status in [100, 102, 103, 0, 199, 600] {
            #expect(blocked(flow([response(status: status)])) == .statusNotMockable, "\(status)")
        }
    }

    @Test func status3xxAllowed() throws {
        for status in [200, 204, 301, 304, 404, 599] {
            let source = try extract(flow([response(status: status, headers: [field("Location", "/next")])])).get()
            #expect(source.status == status)
        }
    }

    @Test func truncatedBodyBlocked() {
        let kept = slice(Data("abc".utf8))
        #expect(blocked(flow([response(body: kept, state: .truncated, observed: 99)])) == .bodyTruncated)
    }

    @Test func incompleteTransferBlocked() {
        let kept = slice(Data("abc".utf8))
        #expect(blocked(flow([response(body: kept, state: .incomplete)])) == .bodyIncomplete)
        #expect(blocked(flow([response(body: kept, state: .pending)])) == .bodyIncomplete)
        #expect(blocked(flow([response(body: nil, state: .unavailable, observed: 3)])) == .bodyIncomplete)
        for transfer in [HTTPTransferState.observed, .acceptedByWriter, .partiallySent, .failed] {
            #expect(blocked(flow([response(body: kept, transfer: transfer)])) == .bodyIncomplete, "\(transfer)")
        }
    }

    @Test func sliceCountMismatchBlocked() {
        let kept = slice(Data("abc".utf8))
        #expect(blocked(flow([response(body: kept, observed: 5)])) == .bodyIncomplete)
        #expect(blocked(flow([response(body: nil, observed: 5)])) == .bodyIncomplete)
        #expect(blocked(flow([response(body: kept, observed: 2)])) == .bodyIncomplete)
    }

    @Test func bodyOverAssetLimitBlocked() throws {
        var limits = RulesLimits()
        limits.assetFileBytes = 4
        #expect(blocked(flow([response(body: slice(Data("12345".utf8)))]), limits: limits) == .bodyTooLarge)
        let exact = try extract(flow([response(body: slice(Data("1234".utf8)))]), limits: limits).get()
        #expect(exact.size == 4)
        // A prefix kept for a larger body is still a truncated body first.
        #expect(blocked(flow([response(body: slice(Data("12".utf8)), state: .truncated, observed: 99)]), limits: limits) == .bodyTruncated)
    }

    @Test func emptyBodyYieldsNilSliceAndZeroSize() throws {
        let nilBody = try extract(flow([response(body: nil)])).get()
        #expect(nilBody.body == nil && nilBody.size == 0)
        let zeroSlice = try extract(flow([response(body: HTTPBodySlice(ref: .memory(Data()), offset: 0, count: 0))])).get()
        #expect(zeroSlice.body == nil && zeroSlice.size == 0)
    }

    @Test func headResponseWithoutBodyAllowed() throws {
        let head = response(headers: [field("Content-Length", "1234"), field("Content-Type", "image/png")], body: nil)
        let source = try extract(flow([head], method: "HEAD")).get()
        #expect(source.size == 0 && source.body == nil && source.headers == [field("Content-Type", "image/png")])
    }

    @Test func spooledBodySliceKeepsOffset() throws {
        let bytes = Data((0..<100).map { UInt8($0) })
        let kept = slice(bytes, offset: 40)
        let source = try extract(flow([response(body: kept)])).get()
        #expect(source.size == 60 && source.body == kept && source.body?.offset == 40)
        #expect(try source.body?.load() == bytes.suffix(60))
    }
}
