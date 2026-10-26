import Foundation
import Testing

@testable import FlowStore

private func base(compose: Bool = false) -> Flow {
    var flow = Flow(
        id: 7, startedAt: Date(timeIntervalSince1970: 100), scheme: "https", method: "GET", host: "a.test", port: 443,
        path: "/old", requestHeaders: [HeaderField(name: "X-Old", value: "1")])
    flow.statusCode = 200
    flow.statusReason = "OK"
    flow.responseHeaders = [HeaderField(name: "Content-Type", value: "text/plain")]
    flow.requestBody = .memory(Data("req".utf8))
    flow.responseBody = .memory(Data("resp".utf8))
    flow.state = .completed
    flow.comment = "keep"
    let target = HTTPMessageTarget(scheme: "https", host: "a.test", port: 443, method: "GET", pathAndQuery: "/old")
    let boundaries: [HTTPMessageBoundary] =
        compose
        ? [.composeSubmitted, .composeDelivered]
        : [.downstreamRequest, .upstreamRequest, .upstreamResponse, .downstreamResponse]
    for boundary in boundaries {
        let isRequest = boundary == .downstreamRequest || boundary == .upstreamRequest || boundary == .composeSubmitted
        flow.messages[boundary] = HTTPMessageSnapshot(
            boundary: boundary,
            head: isRequest
                ? .request(target, headers: flow.requestHeaders) : .response(status: 200, reason: "OK", headers: flow.responseHeaders),
            bodyState: .complete)
    }
    if compose { flow.provenance = FlowProvenance(source: .compose(sendID: UUID(), sourceFlowID: nil, sourceBoundary: nil)) }
    return flow
}

private func newRequest() -> HTTPMessageSnapshot {
    let target = HTTPMessageTarget(scheme: "http", host: "b.test", port: 8080, method: "POST", pathAndQuery: "/new?x=1")
    return HTTPMessageSnapshot(
        boundary: .upstreamRequest, head: .request(target, headers: [HeaderField(name: "X-New", value: "2")]),
        trailers: [HeaderField(name: "T", value: "1")],
        body: HTTPBodySlice(ref: .memory(Data("newreq".utf8)), offset: 0, count: 6), bodyState: .complete)
}

private func newResponse() -> HTTPMessageSnapshot {
    HTTPMessageSnapshot(
        boundary: .downstreamResponse, head: .response(status: 404, reason: "Not Found", headers: [HeaderField(name: "X", value: "y")]),
        body: HTTPBodySlice(ref: .memory(Data("gone".utf8)), offset: 0, count: 4), bodyState: .truncated)
}

@Suite struct ExecuteViewTests {
    @Test func viewingOverlayProjectsLegacyFieldsAndClientBoundaries() throws {
        var flow = base()
        flow.executeOverlay = ExecuteOverlay(request: newRequest(), response: newResponse())
        let view = flow.viewingExecuteOverlay()
        #expect(view.requestHeaders == [HeaderField(name: "X-New", value: "2")])
        #expect(view.requestTrailers == [HeaderField(name: "T", value: "1")])
        #expect(try view.requestBody?.load() == Data("newreq".utf8))
        #expect(view.requestBodyTruncated == false)
        #expect(view.method == "POST" && view.host == "b.test" && view.port == 8080 && view.scheme == "http")
        #expect(view.path == "/new?x=1")
        #expect(view.statusCode == 404 && view.statusReason == "Not Found")
        #expect(view.responseHeaders == [HeaderField(name: "X", value: "y")])
        #expect(try view.responseBody?.load() == Data("gone".utf8))
        #expect(view.responseBodyTruncated)
        #expect(view.messages[.downstreamRequest]?.target?.pathAndQuery == "/new?x=1")
        #expect(view.messages[.downstreamRequest]?.boundary == .downstreamRequest)
        #expect(view.messages[.downstreamResponse]?.status == 404)
        #expect(view.messages[.upstreamRequest] == flow.messages[.upstreamRequest])
        #expect(view.messages[.upstreamResponse] == flow.messages[.upstreamResponse])
        #expect(view.id == flow.id && view.startedAt == flow.startedAt && view.provenance == flow.provenance)
        #expect(view.comment == "keep" && view.executeOverlay == flow.executeOverlay)
    }

    @Test func viewingOverlayWithOnlyAResponseKeepsTheRequest() {
        var flow = base()
        flow.executeOverlay = ExecuteOverlay(response: newResponse())
        let view = flow.viewingExecuteOverlay()
        #expect(view.requestHeaders == flow.requestHeaders)
        #expect(view.path == "/old" && view.method == "GET")
        #expect(view.messages[.downstreamRequest] == flow.messages[.downstreamRequest])
        #expect(view.statusCode == 404)
    }

    @Test func flowWithoutOverlayViewsAsItself() {
        let flow = base()
        #expect(flow.viewingExecuteOverlay() == flow)
        var empty = flow
        empty.executeOverlay = ExecuteOverlay()
        #expect(empty.viewingExecuteOverlay() == empty)
    }

    @Test func composeFlowReplacesTheComposeBoundaries() {
        var flow = base(compose: true)
        flow.executeOverlay = ExecuteOverlay(request: newRequest(), response: newResponse())
        let view = flow.viewingExecuteOverlay()
        #expect(view.messages[.composeSubmitted]?.boundary == .composeSubmitted)
        #expect(view.messages[.composeSubmitted]?.target?.pathAndQuery == "/new?x=1")
        #expect(view.messages[.composeDelivered]?.status == 404)
        #expect(view.messages[.downstreamRequest] == nil)
    }

    @Test func legacyFlowWithoutBoundariesOnlyGetsTheLegacyProjection() {
        var flow = base()
        flow.messages = [:]
        flow.executeOverlay = ExecuteOverlay(response: newResponse())
        let view = flow.viewingExecuteOverlay()
        #expect(view.messages.isEmpty)
        #expect(view.statusCode == 404)
    }
}
