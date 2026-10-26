import Foundation
import Testing

@testable import FlowStore

@Suite struct ExportTests {
    @Test func unknownTransportDoesNotInventHTTP1() throws {
        let flow = Flow(id: 1, scheme: "http", method: "GET", host: "example.com", port: 80, path: "/")
        #expect(flow.transport == .init())
        #expect(flow.requestTrailers.isEmpty)
        #expect(flow.responseTrailers.isEmpty)
        let data = try HARExporter.export([flow], creatorName: "Test", creatorVersion: "1")
        let entry = try #require(try harEntries(data).first)
        #expect((entry["request"] as? [String: Any])?["httpVersion"] as? String == "")
        #expect((entry["response"] as? [String: Any])?["httpVersion"] as? String == "")
    }

    @Test func asymmetricTransportIsExported() throws {
        var asymmetric = makeFlow(host: "example.com", path: "/")
        asymmetric.transport = .init(downstreamRequest: .http1_1, downstreamResponse: .http1_0,
                                     upstreamRequest: .http1_1, upstreamResponse: .http1_0)
        var translated = makeFlow(id: 2, host: "example.com", path: "/translated")
        translated.transport = .init(downstreamRequest: .http2, downstreamResponse: .http2,
                                    upstreamRequest: .http1_1, upstreamResponse: .http1_0,
                                    downstreamStreamID: 3, upstreamStreamID: 7)
        let entries = try harEntries(HARExporter.export([asymmetric, translated], creatorName: "Test", creatorVersion: "1"))
        #expect((entries[0]["request"] as? [String: Any])?["httpVersion"] as? String == "HTTP/1.1")
        #expect((entries[0]["response"] as? [String: Any])?["httpVersion"] as? String == "HTTP/1.0")
        #expect((entries[1]["request"] as? [String: Any])?["httpVersion"] as? String == "HTTP/2")
        #expect((entries[1]["response"] as? [String: Any])?["httpVersion"] as? String == "HTTP/2")
        let metadata = try #require(entries[1]["_proxywoman"] as? [String: Any])
        #expect(metadata["upstreamRequestVersion"] as? String == "HTTP/1.1")
        #expect(metadata["upstreamResponseVersion"] as? String == "HTTP/1.0")
        #expect(metadata["downstreamStreamID"] as? Int == 3)
        #expect(metadata["upstreamStreamID"] as? Int == 7)
        let unknown = Flow(id: 3, scheme: "http", method: "GET", host: "example.com", port: 80, path: "/")
        let unknownEntry = try #require(try harEntries(HARExporter.export([unknown], creatorName: "Test", creatorVersion: "1")).first)
        let unknownMetadata = try #require(unknownEntry["_proxywoman"] as? [String: Any])
        #expect(unknownMetadata["upstreamRequestVersion"] == nil)
        #expect(unknownMetadata["upstreamResponseVersion"] == nil)
        #expect(unknownMetadata["downstreamStreamID"] == nil)
        #expect(unknownMetadata["upstreamStreamID"] == nil)
    }

    @Test func trailersRemainOrdered() throws {
        var flow = makeFlow(host: "example.com", path: "/")
        flow.requestHeaders = [.init(name: "X-Initial", value: "request")]
        flow.responseHeaders = [.init(name: "X-Initial", value: "response")]
        flow.requestTrailers = [.init(name: "X-Trailer", value: "a"), .init(name: "X-Trailer", value: "b")]
        flow.responseTrailers = [.init(name: "X-End", value: "1"), .init(name: "X-Other", value: "2"), .init(name: "X-End", value: "3")]
        let entry = try #require(try harEntries(HARExporter.export([flow], creatorName: "Test", creatorVersion: "1")).first)
        let metadata = try #require(entry["_proxywoman"] as? [String: Any])
        #expect(metadata["requestTrailers"] as? [[String: String]] == [["name": "X-Trailer", "value": "a"], ["name": "X-Trailer", "value": "b"]])
        #expect(metadata["responseTrailers"] as? [[String: String]] == [["name": "X-End", "value": "1"], ["name": "X-Other", "value": "2"], ["name": "X-End", "value": "3"]])
        #expect((entry["request"] as? [String: Any])?["headers"] as? [[String: String]] == [["name": "X-Initial", "value": "request"]])
        #expect((entry["response"] as? [String: Any])?["headers"] as? [[String: String]] == [["name": "X-Initial", "value": "response"]])
    }

    private func makeFlow(
        id: Int = 1,
        scheme: String = "https",
        method: String = "GET",
        host: String,
        port: Int = 443,
        path: String,
        headers: [HeaderField] = []
    ) -> Flow {
        var flow = Flow(id: id, startedAt: Date(timeIntervalSince1970: 1_700_000_000.5),
             scheme: scheme, method: method, host: host, port: port, path: path, requestHeaders: headers)
        flow.transport = .init(downstreamRequest: .http1_1, downstreamResponse: .http1_1)
        return flow
    }

    @Test func curlForGetOmitsMethodAndHostHeader() {
        let get = makeFlow(host: "api.x.com", path: "/v1?a=1", headers: [
            HeaderField(name: "Host", value: "api.x.com"),
            HeaderField(name: "Accept", value: "*/*"),
        ])
        #expect(CurlExporter.command(for: get) == "curl 'https://api.x.com/v1?a=1' \\\n  -H 'Accept: */*'")
    }

    @Test func curlForPostIncludesMethodBodyAndEscapesQuotes() {
        var post = makeFlow(method: "POST", host: "x.com", path: "/p", headers: [
            HeaderField(name: "Content-Type", value: "application/json"),
            HeaderField(name: "Content-Length", value: "13"),
        ])
        post.requestBody = .memory(Data(#"{"n":"it's"}"#.utf8))
        #expect(CurlExporter.command(for: post) ==
            "curl -X POST 'https://x.com/p' \\\n  -H 'Content-Type: application/json' \\\n  --data-binary '{\"n\":\"it'\\''s\"}'")
    }

    @Test func curlKeepsHostHeaderThatDiffersFromUrlHost() {
        let flow = makeFlow(host: "10.0.0.1", port: 8443, path: "/", headers: [
            HeaderField(name: "Host", value: "virtual.example"),
            HeaderField(name: "host", value: "10.0.0.1:8443"),
        ])
        #expect(CurlExporter.command(for: flow) == "curl 'https://10.0.0.1:8443/' \\\n  -H 'Host: virtual.example'")
    }

    @Test func curlForGetWithBodyKeepsExplicitGet() {
        var get = makeFlow(host: "x.com", path: "/search")
        get.requestBody = .memory(Data(#"{"q":1}"#.utf8))
        #expect(CurlExporter.command(for: get) == "curl -X GET 'https://x.com/search' \\\n  --data-binary '{\"q\":1}'")
    }

    @Test func curlForGetWithBinaryBodyDoesNotForceGet() {
        var get = makeFlow(host: "x.com", path: "/bin")
        get.requestBody = .memory(Data([0xFF, 0xFE]))
        #expect(!CurlExporter.command(for: get).contains("-X GET"))
    }

    @Test func curlForHeadUsesDashI() {
        let head = makeFlow(method: "HEAD", host: "x.com", path: "/ping")
        #expect(CurlExporter.command(for: head) == "curl -I 'https://x.com/ping'")
    }

    @Test func curlOmitsNonUTF8BodyWithComment() {
        var post = makeFlow(method: "PUT", host: "x.com", path: "/up")
        post.requestBody = .memory(Data([0xFF, 0xFE, 0x00, 0x80, 0x81]))
        #expect(CurlExporter.command(for: post) == "curl -X PUT 'https://x.com/up' \\\n  # request body omitted: binary (5 bytes)")
    }

    @Test func curlEscapesQuoteInUrlAndHeaderValue() {
        let flow = makeFlow(host: "x.com", path: "/q?n=it's", headers: [HeaderField(name: "X-A", value: "it's")])
        #expect(CurlExporter.command(for: flow) == "curl 'https://x.com/q?n=it'\\''s' \\\n  -H 'X-A: it'\\''s'")
    }

    @Test func harContainsEntriesWithRequestAndResponse() throws {
        let json = Data(#"{"ok":true}"#.utf8)
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0xFF, 0x00])

        var first = makeFlow(id: 1, host: "api.x.com", path: "/v1?a=1&b=%E4%B8%AD", headers: [
            HeaderField(name: "Cookie", value: "sid=abc; theme=dark"),
        ])
        first.completedAt = first.startedAt.addingTimeInterval(0.25)
        first.statusCode = 200
        first.statusReason = "OK"
        first.responseHeaders = [
            HeaderField(name: "Content-Type", value: "application/json"),
            HeaderField(name: "Set-Cookie", value: "k=v; Path=/; HttpOnly"),
        ]
        first.responseBody = .memory(json)
        first.state = .completed

        var second = makeFlow(id: 2, host: "x.com", path: "/logo.png")
        second.completedAt = second.startedAt.addingTimeInterval(0.1)
        second.statusCode = 200
        second.statusReason = "OK"
        second.responseHeaders = [HeaderField(name: "Content-Type", value: "image/png")]
        second.responseBody = .memory(png)
        second.state = .completed

        var tunnel = makeFlow(id: 3, method: "CONNECT", host: "secret.com", path: "")
        tunnel.state = .tunnel

        let data = try HARExporter.export([first, tunnel, second], creatorName: "ProxyWoman", creatorVersion: "0.1")
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let log = try #require(root["log"] as? [String: Any])
        #expect(log["version"] as? String == "1.2")
        let creator = try #require(log["creator"] as? [String: Any])
        #expect(creator["name"] as? String == "ProxyWoman")
        #expect(creator["version"] as? String == "0.1")
        let entries = try #require(log["entries"] as? [[String: Any]])
        #expect(entries.count == 2)

        let request = try #require(entries[0]["request"] as? [String: Any])
        #expect(request["method"] as? String == "GET")
        #expect(request["url"] as? String == first.url)
        #expect(request["httpVersion"] as? String == "HTTP/1.1")
        let query = try #require(request["queryString"] as? [[String: String]])
        #expect(query == [["name": "a", "value": "1"], ["name": "b", "value": "中"]])
        let requestCookies = try #require(request["cookies"] as? [[String: String]])
        #expect(requestCookies == [["name": "sid", "value": "abc"], ["name": "theme", "value": "dark"]])
        #expect(request["headersSize"] as? Int == -1)
        #expect(request["bodySize"] as? Int == 0)

        let response = try #require(entries[0]["response"] as? [String: Any])
        #expect(response["status"] as? Int == 200)
        #expect(response["statusText"] as? String == "OK")
        #expect(response["redirectURL"] as? String == "")
        #expect(response["bodySize"] as? Int == json.count)
        let responseCookies = try #require(response["cookies"] as? [[String: String]])
        #expect(responseCookies == [["name": "k", "value": "v"]])
        let content = try #require(response["content"] as? [String: Any])
        #expect(content["mimeType"] as? String == "application/json")
        #expect(content["text"] as? String == #"{"ok":true}"#)
        #expect(content["size"] as? Int == json.count)
        #expect(content["encoding"] == nil)

        let binary = try #require((entries[1]["response"] as? [String: Any])?["content"] as? [String: Any])
        #expect(binary["encoding"] as? String == "base64")
        #expect(binary["text"] as? String == png.base64EncodedString())
        #expect(binary["size"] as? Int == png.count)

        // 1_700_000_000.5 = 2023-11-14T22:13:20.500Z
        #expect(entries[0]["startedDateTime"] as? String == "2023-11-14T22:13:20.500Z")
        #expect(entries[0]["time"] as? Double == 250)
        let timings = try #require(entries[0]["timings"] as? [String: Double])
        #expect(timings == ["send": 0, "wait": 250, "receive": 0])
    }

    @Test func harHandlesPostBodyRedirectAndIncompleteFlow() throws {
        var post = makeFlow(method: "POST", host: "x.com", path: "/login", headers: [
            HeaderField(name: "Content-Type", value: "application/x-www-form-urlencoded"),
        ])
        post.requestBody = .memory(Data("u=1&p=2".utf8))
        post.completedAt = post.startedAt.addingTimeInterval(0.01)
        post.statusCode = 302
        post.statusReason = "Found"
        post.responseHeaders = [HeaderField(name: "Location", value: "https://x.com/home")]
        post.state = .completed

        let pending = makeFlow(id: 2, host: "slow.com", path: "/")

        let data = try HARExporter.export([post, pending], creatorName: "ProxyWoman", creatorVersion: "0.1")
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let entries = try #require((root["log"] as? [String: Any])?["entries"] as? [[String: Any]])
        #expect(entries.count == 2)

        let postRequest = try #require(entries[0]["request"] as? [String: Any])
        let postData = try #require(postRequest["postData"] as? [String: Any])
        #expect(postData["mimeType"] as? String == "application/x-www-form-urlencoded")
        #expect(postData["text"] as? String == "u=1&p=2")
        #expect(postRequest["bodySize"] as? Int == 7)
        let postResponse = try #require(entries[0]["response"] as? [String: Any])
        #expect(postResponse["redirectURL"] as? String == "https://x.com/home")

        #expect(entries[1]["time"] as? Double == 0)
        let pendingResponse = try #require(entries[1]["response"] as? [String: Any])
        #expect(pendingResponse["status"] as? Int == 0)
        #expect(pendingResponse["statusText"] as? String == "")
        let pendingContent = try #require(pendingResponse["content"] as? [String: Any])
        #expect(pendingContent["size"] as? Int == 0)
        let pendingTimings = try #require(entries[1]["timings"] as? [String: Double])
        #expect(pendingTimings["wait"] == 0)
        #expect((entries[1]["request"] as? [String: Any])?["postData"] == nil)
    }

    @Test func harExportsUnloadableBodyAsEmptyContent() throws {
        var flow = makeFlow(host: "x.com", path: "/big")
        flow.completedAt = flow.startedAt.addingTimeInterval(1)
        flow.statusCode = 200
        flow.responseHeaders = [HeaderField(name: "Content-Type", value: "text/plain")]
        flow.responseBody = .file(URL(fileURLWithPath: "/nonexistent/proxywoman-body"), size: 99)
        flow.state = .completed

        let data = try HARExporter.export([flow], creatorName: "ProxyWoman", creatorVersion: "0.1")
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let entries = try #require((root["log"] as? [String: Any])?["entries"] as? [[String: Any]])
        let response = try #require(entries.first?["response"] as? [String: Any])
        let content = try #require(response["content"] as? [String: Any])
        #expect(content["size"] as? Int == 0)
        #expect(content["text"] as? String == "")
    }

    @Test func harDecodesCompressedResponseWithInjectedDecoder() throws {
        let raw = Data([0x1F, 0x8B, 0x08, 0x00, 0x01, 0x02, 0x03, 0x04])
        var flow = makeFlow(host: "x.com", path: "/z")
        flow.completedAt = flow.startedAt.addingTimeInterval(0.1)
        flow.statusCode = 200
        flow.responseHeaders = [
            HeaderField(name: "Content-Type", value: "text/plain"),
            HeaderField(name: "Content-Encoding", value: "gzip"),
        ]
        flow.responseBody = .memory(raw)
        flow.state = .completed

        let data = try HARExporter.export([flow], creatorName: "ProxyWoman", creatorVersion: "0.1") { _, encoding in
            encoding == "gzip" ? Data("hello".utf8) : nil
        }
        let content = try harContent(data)
        #expect(content["text"] as? String == "hello")
        #expect(content["size"] as? Int == 5)
        #expect(content["compression"] as? Int == raw.count - 5)
        #expect(content["encoding"] == nil)
        let response = try #require(try harEntries(data).first?["response"] as? [String: Any])
        #expect(response["bodySize"] as? Int == raw.count)
    }

    @Test func harKeepsRawBodyWhenDecoderReturnsNilOrNoEncodingHeader() throws {
        let raw = Data([0x1F, 0x8B, 0x08, 0x00])
        var encoded = makeFlow(host: "x.com", path: "/z")
        encoded.statusCode = 200
        encoded.responseHeaders = [HeaderField(name: "Content-Encoding", value: "br")]
        encoded.responseBody = .memory(raw)

        var plain = makeFlow(id: 2, host: "x.com", path: "/p")
        plain.statusCode = 200
        plain.responseBody = .memory(raw)

        var calls = 0
        let data = try HARExporter.export([encoded, plain], creatorName: "ProxyWoman", creatorVersion: "0.1") { _, _ in
            calls += 1
            return nil
        }
        let entries = try harEntries(data)
        for entry in entries {
            let content = try #require((entry["response"] as? [String: Any])?["content"] as? [String: Any])
            #expect(content["encoding"] as? String == "base64")
            #expect(content["text"] as? String == raw.base64EncodedString())
            #expect(content["size"] as? Int == raw.count)
            #expect(content["compression"] == nil)
        }
        // 只有带 Content-Encoding 头的响应才会调用解码器。
        #expect(calls == 1)
    }

    private func harEntries(_ data: Data) throws -> [[String: Any]] {
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require((root["log"] as? [String: Any])?["entries"] as? [[String: Any]])
    }

    private func harContent(_ data: Data) throws -> [String: Any] {
        try #require((try harEntries(data).first?["response"] as? [String: Any])?["content"] as? [String: Any])
    }

    @Test func harSkipsFailedConnectFlows() throws {
        var failed = makeFlow(id: 1, method: "CONNECT", host: "bad.example", path: "")
        failed.state = .failed("握手失败")
        failed.completedAt = failed.startedAt
        var get = makeFlow(id: 2, host: "x.com", path: "/")
        get.state = .completed
        let data = try HARExporter.export([failed, get], creatorName: "P", creatorVersion: "0.1")
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let entries = try #require((root["log"] as? [String: Any])?["entries"] as? [[String: Any]])
        #expect(entries.count == 1)
        #expect((entries.first?["request"] as? [String: Any])?["url"] as? String == "https://x.com/")
    }
}

extension ExportTests {
    @Test func webSocketProjectionPreservesLegacyDecoderAndHTTPDuration() throws {
        let store = wsStore(); let token = try wsSession(store)
        var flow = try #require(store.flow(token.flowID)); flow.statusCode = 101
        flow.completedAt = flow.startedAt.addingTimeInterval(0.25)
        let old = try HARExporter.export([flow], creatorName: "Test", creatorVersion: "1") { _, _ in nil }
        let labelled = try HARExporter.export([flow], creatorName: "Test", creatorVersion: "1", decodeBody: { _, _ in nil })
        #expect(old == labelled)
        let data = try HARExporter.export([flow], creatorName: "Test", creatorVersion: "1", webSocketSummaryForFlow: { (flow: Flow) in
            store.webSocketToken(flowID: flow.id).flatMap { store.webSocketHARSummary(token: $0) }
        }) { _, _ in nil }
        let entry = try #require(try harEntries(data).first)
        let ws = try #require(entry["_proxywomanWebSocket"] as? [String: Any])
        #expect(ws["schemaVersion"] as? Int == 1 && ws["messagesIncluded"] as? Bool == false)
        #expect(entry["time"] as? Double == 250)
        let legacy = try #require(try harEntries(old).first)
        #expect(legacy["_proxywomanWebSocket"] == nil)
    }
}

extension ExportTests {
    @Test func webSocketHARSupplierDomainsAndNilAfterClearAreTruthful() throws {
        let store = wsStore(), token = try wsSession(store)
        store.recordWebSocketState(.observedBytes(direction: .clientToServer, wire: 13, application: 7, lowerBound: true), token: token)
        let flow = try #require(store.flow(token.flowID))
        let data = try HARExporter.export([flow], creatorName: "Test", creatorVersion: "1", webSocketSummaryForFlow: { _ in store.webSocketHARSummary(token: token) }, decodeBody: { _, _ in nil })
        let entry = try #require(try harEntries(data).first), summary = try #require(entry["_proxywomanWebSocket"] as? [String: Any])
        #expect(summary["wireByteDomain"] as? String == "observedDecryptedPostHTTPIncludingFrameAndMask")
        #expect(summary["applicationByteDomain"] as? String == "decodedTextBinaryExcludingControl")
        #expect(summary["clientWireBytes"] as? Int == 13 && summary["clientApplicationBytes"] as? Int == 7 && summary["lowerBound"] as? Bool == true)
        #expect(summary["handshake"] == nil && summary["messages"] == nil)
        store.clear()
        #expect(store.webSocketHARSummary(token: token) == nil)
        let absent = try HARExporter.export([flow], creatorName: "Test", creatorVersion: "1", webSocketSummaryForFlow: { _ in store.webSocketHARSummary(token: token) })
        #expect(try harEntries(absent).first?["_proxywomanWebSocket"] == nil)
    }
}

extension ExportTests {
    @Test func webSocketHARIncludesSourceTimesClosePresencePauseIntervalsAndActualLimits() throws {
        var limits = WebSocketLimits(); limits.quantumBytes = 12345
        let store = wsStore(limits), token = try wsSession(store)
        let start = Date(timeIntervalSince1970: 1_700_000_000.125), end = Date(timeIntervalSince1970: 1_700_000_001.375)
        store.recordWebSocketState(.pausedInterval(start: start, end: nil), token: token)
        store.recordWebSocketState(.pausedInterval(start: start, end: end), token: token)
        store.recordWebSocketState(.closeFrame(direction: .clientToServer, code: 1000), token: token)
        store.recordWebSocketState(.closeFrame(direction: .serverToClient, code: nil), token: token)
        for direction in [WebSocketDirection.clientToServer, .serverToClient] { store.endWebSocket(token: token, transport: .init(direction: direction, at: end, monotonic: 1)) }
        let flow = try #require(store.flow(token.flowID))
        let data = try HARExporter.export([flow], creatorName: "Test", creatorVersion: "1", webSocketSummaryForFlow: { _ in store.webSocketHARSummary(token: token) })
        let summary = try #require(try harEntries(data).first?["_proxywomanWebSocket"] as? [String: Any])
        #expect(summary["openedAt"] as? String != nil)
        #expect(summary["closedAt"] as? String == "2023-11-14T22:13:21.375Z")
        #expect(summary["clientCompletedClose"] as? Bool == true && summary["serverCompletedClose"] as? Bool == true)
        #expect(summary["clientCloseCode"] as? Int == 1000 && summary["serverCloseCode"] == nil)
        let paused = try #require(summary["pausedIntervals"] as? [String: Any])
        #expect(paused["totalCount"] as? Int == 1 && paused["firstStartedAt"] as? String == "2023-11-14T22:13:20.125Z")
        #expect(paused["lastEndedAt"] as? String == "2023-11-14T22:13:21.375Z")
        let configured = try #require(summary["limits"] as? [String: Any])
        #expect(configured["quantumBytes"] as? Int == 12345 && configured["messageWireBytes"] as? Int == 16_777_216)
        #expect(configured["nativeBytes"] as? Int == 16_777_216 && configured["readerPayloadBytes"] as? Int == 262_144)
    }
}

// MARK: - Boundary snapshots

private let exportTarget = HTTPMessageTarget(
    scheme: "https", host: "example.com", port: 443, method: "POST", pathAndQuery: "/edit?q=1")

private func request(
    _ boundary: HTTPMessageBoundary, target: HTTPMessageTarget = exportTarget, headers: [HeaderField],
    version: HTTPWireVersion?, body: HTTPBodySlice? = nil, state: HTTPBodyState = .complete, observed: UInt64 = 0
) -> HTTPMessageSnapshot {
    HTTPMessageSnapshot(
        boundary: boundary, head: .request(target, headers: headers), wireVersion: version, body: body,
        bodyState: state, observedBytes: observed, transferState: .finished)
}

private func response(
    _ boundary: HTTPMessageBoundary, status: Int, headers: [HeaderField], version: HTTPWireVersion?,
    body: HTTPBodySlice? = nil, state: HTTPBodyState = .complete, observed: UInt64 = 0
) -> HTTPMessageSnapshot {
    HTTPMessageSnapshot(
        boundary: boundary, head: .response(status: status, reason: status == 201 ? "Created" : "OK", headers: headers),
        wireVersion: version, body: body, bodyState: state, observedBytes: observed, transferState: .finished)
}

private func har(_ flow: Flow) throws -> [String: Any] {
    let data = try HARExporter.export([flow], creatorName: "Test", creatorVersion: "1")
    let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let log = try #require(root["log"] as? [String: Any])
    return try #require((log["entries"] as? [[String: Any]])?.first)
}

@Suite struct BoundaryExportTests {
    private func rewrittenFlow(_ store: FlowStore) -> Flow {
        let original = store.makeManagedBody(Data("original-body".utf8))
        let rewritten = store.makeManagedBody(Data("rewritten".utf8))
        let upstream = store.makeManagedBody(Data("origin-reply".utf8))
        let client = store.makeManagedBody(Data("mapped-reply".utf8))
        var flow = Flow(id: 1, scheme: "https", method: "POST", host: "example.com", port: 443, path: "/edit?q=1")
        flow.provenance = .passive
        flow.messages = [
            .downstreamRequest: request(
                .downstreamRequest, headers: [.init(name: "X-Who", value: "client"), .init(name: "X-Dup", value: "1"), .init(name: "X-Dup", value: "2")],
                version: .http2, body: .init(ref: original, offset: 0, count: 13), observed: 13),
            .upstreamRequest: request(
                .upstreamRequest,
                target: .init(scheme: "http", host: "mapped.test", port: 8080, method: "POST", pathAndQuery: "/other"),
                headers: [.init(name: "X-Who", value: "proxy")], version: .http1_1,
                body: .init(ref: rewritten, offset: 0, count: 9), observed: 9),
            .upstreamResponse: response(
                .upstreamResponse, status: 200, headers: [.init(name: "X-Who", value: "origin")], version: .http1_1,
                body: .init(ref: upstream, offset: 0, count: 12), observed: 12),
            .downstreamResponse: response(
                .downstreamResponse, status: 201, headers: [.init(name: "X-Who", value: "rewritten")], version: .http2,
                body: .init(ref: client, offset: 0, count: 12), observed: 12),
        ]
        return flow
    }

    @Test func harExportsTheClientVisibleMessageAndKeepsTheOriginsSeparate() throws {
        let env = TestEnvironment()
        defer { env.cleanUp() }
        let entry = try har(rewrittenFlow(env.store))
        let request = try #require(entry["request"] as? [String: Any])
        let response = try #require(entry["response"] as? [String: Any])
        #expect(request["url"] as? String == "https://example.com/edit?q=1")
        #expect(request["httpVersion"] as? String == "HTTP/2")
        #expect((request["headers"] as? [[String: String]])?.map { $0["value"] } == ["client", "1", "2"])
        #expect((request["postData"] as? [String: Any])?["text"] as? String == "original-body")
        #expect(response["status"] as? Int == 201)
        #expect(response["httpVersion"] as? String == "HTTP/2")
        #expect((response["headers"] as? [[String: String]])?.first?["value"] == "rewritten")
        #expect((response["content"] as? [String: Any])?["text"] as? String == "mapped-reply")

        let metadata = try #require(entry["_proxywoman"] as? [String: Any])
        let boundaries = try #require(metadata["boundaries"] as? [String: [String: Any]])
        #expect(boundaries["upstreamResponse"]?["status"] as? Int == 200)
        #expect(boundaries["upstreamResponse"]?["wireVersion"] as? String == "HTTP/1.1")
        #expect(boundaries["downstreamResponse"]?["status"] as? Int == 201)
        #expect(boundaries["upstreamRequest"]?["url"] as? String == "http://mapped.test:8080/other")
        #expect(boundaries["upstreamRequest"]?["bodyBytes"] as? Int == 9)
        #expect((metadata["provenance"] as? [String: Any])?["source"] as? String == "passive")
        // The origin's body never appears in the client-visible response.
        let text = String(decoding: try HARExporter.export([rewrittenFlow(env.store)], creatorName: "T", creatorVersion: "1"), as: UTF8.self)
        #expect(!text.contains("origin-reply"))
    }

    @Test func mapLocalHasNoFabricatedUpstreamAndNamesTheAssetWithoutAPath() throws {
        let env = TestEnvironment()
        defer { env.cleanUp() }
        let assetID = UUID()
        var flow = Flow(id: 1, scheme: "https", method: "GET", host: "example.com", port: 443, path: "/")
        flow.provenance = FlowProvenance(generatedResponse: GeneratedResponseSource(assetID: assetID, size: 6))
        let body = env.store.makeManagedBody(Data("local!".utf8))
        flow.messages = [
            .downstreamRequest: request(.downstreamRequest, target: .init(scheme: "https", host: "example.com", port: 443, method: "GET", pathAndQuery: "/"), headers: [], version: .http1_1),
            .generatedResponse: response(.generatedResponse, status: 200, headers: [], version: nil, body: .init(ref: body, offset: 0, count: 6), observed: 6),
            .downstreamResponse: response(.downstreamResponse, status: 200, headers: [], version: .http1_1, body: .init(ref: body, offset: 0, count: 6), observed: 6),
        ]
        let entry = try har(flow)
        let metadata = try #require(entry["_proxywoman"] as? [String: Any])
        let boundaries = try #require(metadata["boundaries"] as? [String: [String: Any]])
        #expect(boundaries["upstreamRequest"] == nil)
        #expect(boundaries["upstreamResponse"] == nil)
        #expect(metadata["upstreamRequestVersion"] == nil)
        let generated = try #require((metadata["provenance"] as? [String: Any])?["generatedResponse"] as? [String: Any])
        #expect(generated["assetID"] as? String == assetID.uuidString)
        #expect(generated["size"] as? Int == 6)
        let text = String(decoding: try HARExporter.export([flow], creatorName: "T", creatorVersion: "1"), as: UTF8.self)
        #expect(!text.contains(env.directory.path))
    }

    @Test func composeExportsVirtualEndpointsWithEmptyHTTPVersion() throws {
        let sendID = UUID()
        var flow = Flow(id: 1, scheme: "https", method: "GET", host: "example.com", port: 443, path: "/")
        flow.provenance = FlowProvenance(source: .compose(sendID: sendID, sourceFlowID: 4, sourceBoundary: .upstreamRequest))
        flow.messages = [
            .composeSubmitted: request(.composeSubmitted, headers: [.init(name: "A", value: "b")], version: nil),
            .upstreamRequest: request(.upstreamRequest, headers: [.init(name: "A", value: "b")], version: .http1_1),
            .upstreamResponse: response(.upstreamResponse, status: 200, headers: [], version: .http1_1),
            .composeDelivered: response(.composeDelivered, status: 200, headers: [], version: nil),
        ]
        let entry = try har(flow)
        #expect((entry["request"] as? [String: Any])?["httpVersion"] as? String == "")
        #expect((entry["response"] as? [String: Any])?["httpVersion"] as? String == "")
        let provenance = try #require((entry["_proxywoman"] as? [String: Any])?["provenance"] as? [String: Any])
        #expect(provenance["source"] as? String == "compose")
        #expect(provenance["virtualClient"] as? Bool == true)
        #expect(provenance["composeSendID"] as? String == sendID.uuidString)
        #expect(provenance["composeSourceFlowID"] as? Int == 4)
        #expect(provenance["composeSourceBoundary"] as? String == "upstreamRequest")
        #expect(provenance["rulesDisabled"] == nil)
        let boundaries = try #require((entry["_proxywoman"] as? [String: Any])?["boundaries"] as? [String: [String: Any]])
        #expect(boundaries["upstreamRequest"]?["wireVersion"] as? String == "HTTP/1.1")
    }

    @Test func composeSendWithRulesSwitchedOffSaysSo() throws {
        var flow = Flow(id: 1, scheme: "http", method: "GET", host: "example.com", port: 80, path: "/")
        flow.provenance = FlowProvenance(source: .compose(sendID: UUID(), sourceFlowID: nil, sourceBoundary: nil), rulesDisabled: true)
        let entry = try har(flow)
        let provenance = try #require((entry["_proxywoman"] as? [String: Any])?["provenance"] as? [String: Any])
        #expect(provenance["rulesDisabled"] as? Bool == true)
    }

    @Test func legacyFlowKeepsItsProjectionAndUnknownProvenance() throws {
        var flow = Flow(id: 1, scheme: "https", method: "GET", host: "example.com", port: 443, path: "/")
        flow.statusCode = 204
        let entry = try har(flow)
        #expect((entry["response"] as? [String: Any])?["status"] as? Int == 204)
        #expect((entry["request"] as? [String: Any])?["httpVersion"] as? String == "")
        let metadata = try #require(entry["_proxywoman"] as? [String: Any])
        #expect(metadata["boundaries"] == nil)
        #expect((metadata["provenance"] as? [String: Any])?["known"] as? Bool == false)
    }

    @Test func partialBodiesAreMarkedAndNeverLookLikeAnEmptyComplete() throws {
        let env = TestEnvironment()
        defer { env.cleanUp() }
        let body = env.store.makeManagedBody(Data(repeating: 7, count: 100))
        var flow = Flow(id: 1, scheme: "https", method: "POST", host: "example.com", port: 443, path: "/edit?q=1")
        flow.provenance = .passive
        flow.messages = [
            .downstreamRequest: request(.downstreamRequest, headers: [], version: .http1_1, body: .init(ref: body, offset: 0, count: 100), observed: 100),
            .upstreamRequest: request(.upstreamRequest, headers: [], version: .http1_1, body: .init(ref: body, offset: 0, count: 40), state: .incomplete, observed: 40),
            .downstreamResponse: response(.downstreamResponse, status: 200, headers: [], version: .http1_1, state: .unavailable, observed: 9),
        ]
        let entry = try har(flow)
        let boundaries = try #require((entry["_proxywoman"] as? [String: Any])?["boundaries"] as? [String: [String: Any]])
        #expect(boundaries["upstreamRequest"]?["bodyState"] as? String == "incomplete")
        #expect(boundaries["upstreamRequest"]?["observedBytes"] as? Int == 40)
        #expect(boundaries["upstreamRequest"]?["bodyBytes"] as? Int == 40)
        #expect(boundaries["downstreamRequest"]?["bodyState"] as? String == "complete")
        #expect(boundaries["downstreamResponse"]?["bodyState"] as? String == "unavailable")
        #expect(boundaries["downstreamResponse"]?["observedBytes"] as? Int == 9)
        #expect(((entry["response"] as? [String: Any])?["bodySize"] as? Int) == 9)
    }

    @Test func curlSelectsTheOriginalOrTheEffectiveRequestExplicitly() throws {
        let env = TestEnvironment()
        defer { env.cleanUp() }
        let flow = rewrittenFlow(env.store)
        let original = try #require(CurlExporter.command(for: flow, boundary: .downstreamRequest))
        let effective = try #require(CurlExporter.command(for: flow, boundary: .upstreamRequest))
        #expect(original == "curl -X POST 'https://example.com/edit?q=1' \\\n  -H 'X-Who: client' \\\n  -H 'X-Dup: 1' \\\n  -H 'X-Dup: 2' \\\n  --data-binary 'original-body'")
        #expect(effective == "curl -X POST 'http://mapped.test:8080/other' \\\n  -H 'X-Who: proxy' \\\n  --data-binary 'rewritten'")
        // The defaulted call keeps the old flow-field reconstruction.
        var legacy = flow
        legacy.requestBody = .memory(Data("legacy".utf8))
        #expect(CurlExporter.command(for: legacy).contains("--data-binary 'legacy'"))
        #expect(CurlExporter.command(for: flow, boundary: .composeSubmitted) == nil)
    }

    @Test func curlNeverSendsAnIncompleteBodyAsIfItWereWhole() throws {
        let env = TestEnvironment()
        defer { env.cleanUp() }
        let body = env.store.makeManagedBody(Data(repeating: 65, count: 100))
        var flow = Flow(id: 1, scheme: "https", method: "POST", host: "example.com", port: 443, path: "/edit?q=1")
        flow.messages[.upstreamRequest] = request(.upstreamRequest, headers: [], version: .http1_1, body: .init(ref: body, offset: 0, count: 40), state: .incomplete, observed: 40)
        let command = try #require(CurlExporter.command(for: flow, boundary: .upstreamRequest))
        #expect(!command.contains("--data-binary"))
        #expect(command.contains("incomplete"))
    }

    @Test func aBodyThatCannotBeReadIsReportedNotExportedAsEmpty() throws {
        let env = TestEnvironment()
        defer { env.cleanUp() }
        let id = env.store.begin { Flow(id: $0, scheme: "https", method: "POST", host: "example.com", port: 443, path: "/edit?q=1") }
        let body = env.store.makeManagedBody(Data("secret-body".utf8))
        let slice = HTTPBodySlice(ref: body, offset: 0, count: 11)
        env.store.update(id) {
            $0.provenance = .passive
            $0.messages[.downstreamRequest] = request(.downstreamRequest, headers: [], version: .http1_1, body: slice, observed: 11)
            $0.messages[.downstreamResponse] = response(.downstreamResponse, status: 200, headers: [], version: .http1_1, body: slice, observed: 11)
        }
        let flow = try #require(env.store.flow(id))
        env.store.clear()  // revokes the body: the slice is complete on paper but unreadable
        let command = try #require(CurlExporter.command(for: flow, boundary: .downstreamRequest))
        #expect(!command.contains("--data-binary"))
        #expect(command.contains("unreadable"))
        let entry = try har(flow)
        let boundaries = try #require((entry["_proxywoman"] as? [String: Any])?["boundaries"] as? [String: [String: Any]])
        #expect(boundaries["downstreamRequest"]?["bodyReadFailed"] as? Bool == true)
        #expect(boundaries["downstreamResponse"]?["bodyReadFailed"] as? Bool == true)
        #expect(((entry["request"] as? [String: Any])?["postData"] as? [String: Any])?["comment"] as? String == "body unreadable")
        #expect((((entry["response"] as? [String: Any])?["content"]) as? [String: Any])?["comment"] as? String == "body unreadable")
    }

    /// rules-compose T2 minor: the legacy (no boundary snapshots) paths used to turn a read error
    /// into an empty body, in both exporters.
    @Test func aLegacyFlowBodyThatCannotBeReadIsReportedNotExportedAsEmpty() throws {
        let env = TestEnvironment()
        defer { env.cleanUp() }
        let id = env.store.begin { Flow(id: $0, scheme: "https", method: "POST", host: "example.com", port: 443, path: "/edit") }
        let body = env.store.makeManagedBody(Data("secret-body".utf8))
        env.store.update(id) {
            $0.requestBody = body
            $0.responseBody = body
            $0.statusCode = 200
        }
        let flow = try #require(env.store.flow(id))
        #expect(flow.messages.isEmpty, "this is a legacy flow")
        env.store.clear()  // revokes the body
        let command = CurlExporter.command(for: flow)
        #expect(!command.contains("--data-binary"))
        #expect(command.contains("unreadable"))
        let entry = try har(flow)
        #expect(((entry["request"] as? [String: Any])?["postData"] as? [String: Any])?["comment"] as? String == "body unreadable")
        #expect((((entry["response"] as? [String: Any])?["content"]) as? [String: Any])?["comment"] as? String == "body unreadable")
    }
}

@Suite struct TrafficToolsExportTests {
    @Test func harOmitsTrafficToolsWhenEmpty() throws {
        var flow = Flow(id: 1, scheme: "https", method: "GET", host: "example.com", port: 443, path: "/")
        flow.provenance = .passive
        let entry = try har(flow)
        let provenance = try #require((entry["_proxywoman"] as? [String: Any])?["provenance"] as? [String: Any])
        #expect(provenance["trafficTools"] == nil)
    }

    @Test func harExportsTrafficTools() throws {
        let id = UUID()
        let runID = UUID()
        var flow = Flow(id: 1, scheme: "https", method: "GET", host: "example.com", port: 443, path: "/")
        flow.provenance = .passive
        flow.provenance.tools = TrafficToolsProvenance(
            blockedByEntry: id, noCaching: true, networkCondition: "preset.lte",
            repeatRun: RepeatRunTag(runID: runID, index: 2, total: 5))
        let entry = try har(flow)
        let provenance = try #require((entry["_proxywoman"] as? [String: Any])?["provenance"] as? [String: Any])
        let tools = try #require(provenance["trafficTools"] as? [String: Any])
        #expect(tools["blockedByEntry"] as? String == id.uuidString)
        #expect(tools["noCaching"] as? Bool == true)
        #expect(tools["networkCondition"] as? String == "preset.lte")
        #expect(tools["repeatRunID"] as? String == runID.uuidString)
        #expect(tools["repeatIndex"] as? Int == 2)
        #expect(tools["repeatTotal"] as? Int == 5)
    }

    @Test func harDoesNotExportTrafficToolsForUnknownFlows() throws {
        var flow = Flow(id: 1, scheme: "https", method: "GET", host: "example.com", port: 443, path: "/")
        flow.provenance = FlowProvenance(isKnown: false, tools: .init(noCaching: true))
        let entry = try har(flow)
        let provenance = try #require((entry["_proxywoman"] as? [String: Any])?["provenance"] as? [String: Any])
        #expect(provenance["known"] as? Bool == false)
        #expect(provenance["trafficTools"] == nil)
    }
}
