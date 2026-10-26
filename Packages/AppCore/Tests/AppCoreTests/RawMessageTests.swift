import FlowStore
import Foundation
import Testing

@testable import AppCore

@Suite(.productionChinese) struct RawMessageTests {
    @Test func h2AnnotationsStayOutsideMessageAndTrailersKeepOrder() {
        var flow = makeFlow()
        flow.transport.downstreamRequest = .http2
        flow.transport.upstreamResponse = .http2
        flow.statusCode = 200
        flow.requestHeaders = [.init(name: "x-original", value: "client")]
        flow.responseHeaders = [.init(name: "x-original", value: "origin")]
        flow.requestBody = .memory(Data("request-body".utf8))
        flow.responseBody = .memory(Data("response-body".utf8))
        flow.requestTrailers = [.init(name: "x-end", value: "a"), .init(name: "x-end", value: "b")]
        flow.responseTrailers = [.init(name: "x-end", value: "c"), .init(name: "x-end", value: "d")]
        let note = "<HTTP/2 重建文本：根据捕获字段生成，并非二进制帧原文>\r\n\r\n"
        #expect(RawMessage.request(flow) == note + "POST /path?q=1 HTTP/2\r\nx-original: client\r\n\r\nrequest-body\r\n\r\n<已捕获的尾字段>\r\nx-end: a\r\nx-end: b")
        #expect(RawMessage.response(flow) == note + "HTTP/2 200\r\nx-original: origin\r\n\r\nresponse-body\r\n\r\n<已捕获的尾字段>\r\nx-end: c\r\nx-end: d")
    }

    @Test(arguments: [false, true]) func lateMetadataRefreshesRawTextWithoutBodyGrowth(isRequest: Bool) {
        var flow = makeFlow()
        flow.statusCode = 200
        flow.requestBody = .memory(Data("fixed".utf8))
        flow.responseBody = .memory(Data("fixed".utf8))
        let render: (Flow) -> String = { isRequest ? RawMessage.request($0) : RawMessage.response($0) }
        let initial = RawMessagePresentationKey(flow: flow, isRequest: isRequest)
        let originalText = render(flow)
        if isRequest { flow.transport.downstreamRequest = .http2 }
        else { flow.transport.upstreamResponse = .http2 }
        let version = RawMessagePresentationKey(flow: flow, isRequest: isRequest)
        #expect(version != initial)
        #expect(render(flow) != originalText)
        let versionText = render(flow)
        let trailers: [HeaderField] = [.init(name: "x-end", value: "a"), .init(name: "x-end", value: "b")]
        if isRequest { flow.requestTrailers = trailers } else { flow.responseTrailers = trailers }
        let trailing = RawMessagePresentationKey(flow: flow, isRequest: isRequest)
        #expect(trailing != version)
        #expect(render(flow) != versionText)
        #expect(render(flow).hasSuffix("x-end: a\r\nx-end: b"))
        if isRequest { flow.requestTrailers.reverse() } else { flow.responseTrailers.reverse() }
        #expect(RawMessagePresentationKey(flow: flow, isRequest: isRequest) != trailing)
        #expect(render(flow).hasSuffix("x-end: b\r\nx-end: a"))
        #expect(flow.requestBody?.size == 5)
        #expect(flow.responseBody?.size == 5)
    }

    @Test func unknownTransportDoesNotInventHTTP1() {
        var flow = Flow(id: 1, scheme: "http", method: "GET", host: "example.com", port: 80, path: "/")
        flow.statusCode = 200
        #expect(RawMessage.request(flow) == "GET / HTTP/?\r\n\r\n")
        #expect(RawMessage.response(flow) == "HTTP/? 200\r\n\r\n")
    }

    @Test func rawReconstructionUsesOriginalMessageBoundaryVersions() {
        var flow = makeFlow()
        flow.transport = .init(downstreamRequest: .http2, downstreamResponse: .http2,
                               upstreamRequest: .http1_1, upstreamResponse: .http1_0)
        flow.statusCode = 200
        flow.statusReason = "OK"
        #expect(RawMessage.request(flow) == "<HTTP/2 重建文本：根据捕获字段生成，并非二进制帧原文>\r\n\r\nPOST /path?q=1 HTTP/2\r\n\r\n")
        #expect(RawMessage.response(flow) == "HTTP/1.0 200 OK\r\n\r\n")
        flow.transport.upstreamResponse = nil
        #expect(RawMessage.response(flow) == "HTTP/? 200 OK\r\n\r\n")
        flow.transport = .init(downstreamRequest: .http1_1, downstreamResponse: .http1_0,
                               upstreamRequest: .http1_1, upstreamResponse: .http1_0)
        #expect(RawMessage.request(flow).hasPrefix("POST /path?q=1 HTTP/1.1\r\n"))
        #expect(RawMessage.response(flow).hasPrefix("HTTP/1.0 200 OK\r\n"))
    }

    @Test func requestPreservesHeaderOrderDuplicatesAndText() {
        var flow = makeFlow()
        flow.requestHeaders = [
            .init(name: "Host", value: "example.com"), .init(name: "X-Test", value: "a"),
            .init(name: "X-Test", value: "b"),
        ]
        flow.requestBody = .memory(Data("你好".utf8))
        #expect(
            RawMessage.request(flow)
                == "POST /path?q=1 HTTP/1.1\r\nHost: example.com\r\nX-Test: a\r\nX-Test: b\r\n\r\n你好")
    }

    @Test func responseIncludesStatusReasonAndBlankLine() {
        var flow = makeFlow()
        flow.statusCode = 200
        flow.statusReason = "OK"
        flow.responseHeaders = [.init(name: "Content-Type", value: "application/json")]
        flow.responseBody = .memory(Data("{\"ok\":true}".utf8))
        #expect(RawMessage.response(flow) == "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n{\"ok\":true}")
    }

    @Test func emptyBodyStillHasHeaderSeparator() {
        #expect(RawMessage.request(makeFlow()) == "POST /path?q=1 HTTP/1.1\r\n\r\n")
    }

    @Test func binaryBodyIsDescribedWithoutControlCharacters() {
        var flow = makeFlow()
        flow.requestBody = .memory(Data([0, 1, 2]))
        #expect(RawMessage.request(flow) == "POST /path?q=1 HTTP/1.1\r\n\r\n<二进制正文 3 字节>")
    }

    @Test func contentTypeCharsetIsRespected() {
        var flow = makeFlow()
        flow.requestHeaders = [.init(name: "Content-Type", value: "text/plain; charset=iso-8859-1")]
        flow.requestBody = .memory(Data([0x63, 0x61, 0x66, 0xe9]))
        #expect(
            RawMessage.request(flow)
                == "POST /path?q=1 HTTP/1.1\r\nContent-Type: text/plain; charset=iso-8859-1\r\n\r\ncafé")
    }

    @Test func textIsCappedWithoutSplittingUTF8() {
        var flow = makeFlow()
        flow.requestBody = .memory(Data((String(repeating: "a", count: 2 * 1024 * 1024 - 1) + "你尾").utf8))
        let message = RawMessage.request(flow)
        #expect(
            message == "POST /path?q=1 HTTP/1.1\r\n\r\n" + String(repeating: "a", count: 2 * 1024 * 1024 - 1)
                + "\r\n<正文已截断：仅显示前 2 MB>")
    }

    @Test func utf16TextIsNotMistakenForBinaryNULBytes() {
        var flow = makeFlow()
        flow.requestHeaders = [.init(name: "Content-Type", value: "text/plain; charset=utf-16le")]
        flow.requestBody = .memory(Data([0x41, 0x00]))
        #expect(
            RawMessage.request(flow) == "POST /path?q=1 HTTP/1.1\r\nContent-Type: text/plain; charset=utf-16le\r\n\r\nA"
        )
    }

    @Test func spilledBodyLoadsAndCaptureTruncationIsVisible() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("prefix".utf8).write(to: url)
        var flow = makeFlow()
        flow.requestBody = .file(url, size: 6)
        flow.requestBodyTruncated = true
        #expect(RawMessage.request(flow) == "POST /path?q=1 HTTP/1.1\r\n\r\nprefix\r\n<正文记录已截断>")
    }

    @Test func unavailableBodyIsReportedInsteadOfSilentlyEmpty() {
        var flow = makeFlow()
        flow.requestBody = .file(URL(fileURLWithPath: "/tmp/\(UUID().uuidString)/missing"), size: 10)
        #expect(RawMessage.request(flow).contains("<无法读取正文："))
    }

    private func makeFlow() -> Flow {
        var flow = Flow(id: 1, scheme: "https", method: "POST", host: "example.com", port: 443, path: "/path?q=1")
        flow.transport = .init(downstreamRequest: .http1_1, upstreamResponse: .http1_1)
        return flow
    }
}

@Suite(.productionChinese) struct RawMessageBoundaryTests {
    private let target = HTTPMessageTarget(scheme: "https", host: "example.com", port: 443, method: "POST", pathAndQuery: "/path?q=1")

    private func store() -> FlowStore {
        FlowStore(bodyDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("raw-\(UUID().uuidString)"))
    }

    private func flow(_ store: FlowStore) -> Flow {
        let original = store.makeManagedBody(Data("original".utf8))
        let rewritten = store.makeManagedBody(Data("rewritten!".utf8))
        var flow = Flow(id: 1, scheme: "https", method: "POST", host: "example.com", port: 443, path: "/path?q=1")
        flow.requestHeaders = [.init(name: "X-Legacy", value: "legacy")]
        flow.requestBody = original
        flow.messages = [
            .downstreamRequest: HTTPMessageSnapshot(
                boundary: .downstreamRequest,
                head: .request(target, headers: [.init(name: "X-Dup", value: "a"), .init(name: "X-Dup", value: "b")]),
                trailers: [.init(name: "x-t", value: "1"), .init(name: "x-t", value: "2")],
                wireVersion: .http2, body: .init(ref: original, offset: 0, count: 8), bodyState: .complete,
                observedBytes: 8, transferState: .finished),
            .upstreamRequest: HTTPMessageSnapshot(
                boundary: .upstreamRequest,
                head: .request(
                    .init(scheme: "http", host: "mapped.test", port: 80, method: "PUT", pathAndQuery: "/other"),
                    headers: [.init(name: "X-Eff", value: "yes")]),
                wireVersion: .http1_1, body: .init(ref: rewritten, offset: 0, count: 4), bodyState: .incomplete,
                observedBytes: 4, transferState: .partiallySent),
            .upstreamResponse: HTTPMessageSnapshot(
                boundary: .upstreamResponse, head: .response(status: 200, reason: "OK", headers: [.init(name: "X-O", value: "1")]),
                wireVersion: .http1_1, bodyState: .complete, transferState: .finished),
            .downstreamResponse: HTTPMessageSnapshot(
                boundary: .downstreamResponse, head: .response(status: 201, reason: "Created", headers: [.init(name: "X-C", value: "2")]),
                wireVersion: .http2, bodyState: .complete, transferState: .finished),
        ]
        return flow
    }

    @Test func eachBoundaryRendersItsOwnVersionHeadersTrailersAndBody() {
        let flow = flow(store())
        let note = "<HTTP/2 重建文本：根据捕获字段生成，并非二进制帧原文>\r\n\r\n"
        #expect(RawMessage.request(flow, boundary: .downstreamRequest)
            == note + "POST /path?q=1 HTTP/2\r\nX-Dup: a\r\nX-Dup: b\r\n\r\noriginal\r\n\r\n<已捕获的尾字段>\r\nx-t: 1\r\nx-t: 2")
        #expect(RawMessage.request(flow, boundary: .upstreamRequest)
            == "PUT /other HTTP/1.1\r\nX-Eff: yes\r\n\r\nrewr\r\n<正文不完整：传输提前结束>")
        #expect(RawMessage.response(flow, boundary: .upstreamResponse) == "HTTP/1.1 200 OK\r\nX-O: 1\r\n\r\n")
        #expect(RawMessage.response(flow, boundary: .downstreamResponse)
            == note + "HTTP/2 201 Created\r\nX-C: 2\r\n\r\n")
    }

    @Test func defaultedCallKeepsTheLegacyOriginalReconstruction() {
        let flow = flow(store())
        #expect(RawMessage.request(flow) == "POST /path?q=1 HTTP/?\r\nX-Legacy: legacy\r\n\r\noriginal")
        #expect(RawMessage.response(flow) == "响应尚未收到")
    }

    @Test func aBoundaryThatNeverHappenedSaysSoInsteadOfShowingAnotherMessage() {
        var flow = flow(store())
        flow.messages[.upstreamRequest] = nil
        let text = RawMessage.request(flow, boundary: .upstreamRequest)
        #expect(text == "该环节没有消息：请求未发送，或响应由本地生成")
        #expect(RawMessage.response(flow, boundary: .generatedResponse) == text)
    }

    @Test func presentationKeyChangesWithTheSelectedBoundaryAndItsTransfer() {
        var flow = flow(store())
        let original = RawMessagePresentationKey(flow: flow, isRequest: true, boundary: .downstreamRequest)
        let effective = RawMessagePresentationKey(flow: flow, isRequest: true, boundary: .upstreamRequest)
        #expect(original != effective)
        #expect(original != RawMessagePresentationKey(flow: flow, isRequest: true))
        flow.messages[.upstreamRequest]?.observedBytes = 5
        #expect(RawMessagePresentationKey(flow: flow, isRequest: true, boundary: .upstreamRequest) != effective)
    }

    @Test func diagnosticsListBoundariesThatDidNotCarryTheWholeMessage() {
        let withBoundaries = FlowDiagnostics(flow: flow(store()))
        #expect(withBoundaries.incompleteBoundaries == [.upstreamRequest])
        #expect(withBoundaries.provenanceKnown == false)
        var known = flow(store())
        known.provenance = .passive
        #expect(FlowDiagnostics(flow: known).provenanceKnown)
        let legacy = Flow(id: 2, scheme: "http", method: "GET", host: "h", port: 80, path: "/")
        #expect(FlowDiagnostics(flow: legacy).incompleteBoundaries.isEmpty)
    }
}
