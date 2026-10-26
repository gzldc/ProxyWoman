import FlowStore
import Foundation
import Testing

@testable import AppCore

private func target(_ path: String) -> HTTPMessageTarget {
    HTTPMessageTarget(scheme: "https", host: "a.test", port: 443, method: "GET", pathAndQuery: path)
}

private func original(
    requestHeaders: [HeaderField] = [], responseHeaders: [HeaderField] = [], status: Int = 200, responseBody: String = "abc"
) -> Flow {
    var flow = Flow(id: 1, scheme: "https", method: "GET", host: "a.test", port: 443, path: "/p")
    flow.state = .completed
    flow.messages[.downstreamRequest] = HTTPMessageSnapshot(
        boundary: .downstreamRequest, head: .request(target("/p"), headers: requestHeaders), bodyState: .complete)
    flow.messages[.upstreamResponse] = HTTPMessageSnapshot(
        boundary: .upstreamResponse, head: .response(status: status, reason: nil, headers: responseHeaders),
        body: HTTPBodySlice(ref: .memory(Data(responseBody.utf8)), offset: 0, count: responseBody.utf8.count),
        bodyState: .complete)
    return flow
}

private func response(
    _ status: Int, headers: [HeaderField] = [], body: String = "abc"
) -> HTTPMessageSnapshot {
    HTTPMessageSnapshot(
        boundary: .downstreamResponse, head: .response(status: status, reason: nil, headers: headers),
        body: HTTPBodySlice(ref: .memory(Data(body.utf8)), offset: 0, count: body.utf8.count), bodyState: .complete)
}

@Suite(.productionChinese) struct ExecuteDiffTests {
    @Test func diffListsTargetStatusHeadersAndBodySizes() {
        var flow = original(
            requestHeaders: [HeaderField(name: "Keep", value: "1"), HeaderField(name: "Gone", value: "g")],
            responseHeaders: [HeaderField(name: "Content-Type", value: "a")])
        let long = String(repeating: "z", count: 300)
        flow.executeOverlay = ExecuteOverlay(
            request: HTTPMessageSnapshot(
                boundary: .upstreamRequest,
                head: .request(target("/q"), headers: [HeaderField(name: "keep", value: "1"), HeaderField(name: "New", value: "n")]),
                bodyState: .complete),
            response: response(
                404, headers: [HeaderField(name: "content-type", value: long)], body: "abcdef"))
        let report = ExecuteDiff.compare(flow)
        #expect(report.request == [
            .init(text: "地址：https://a.test/p → https://a.test/q"),
            .init(text: "删除 Header：Gone: g"),
            .init(text: "新增 Header：New: n"),
        ])
        #expect(report.response == [
            .init(text: "状态码：200 → 404"),
            .init(text: "修改 Header content-type：a → " + String(repeating: "z", count: 200)),
            .init(text: "正文：3 字节 → 6 字节"),
        ])
        #expect(!report.isEmpty)
    }

    @Test func diffOfAReplacedResponseSaysSo() {
        var flow = original()
        flow.executeOverlay = ExecuteOverlay(response: response(200, body: "abc"), responseIsLocal: true)
        let report = ExecuteDiff.compare(flow)
        #expect(report.request.isEmpty)
        #expect(report.response == [
            .init(text: "响应整个换成了规则返回的响应"),
        ])
    }

    @Test func sameSizeDifferentContentIsStillABodyChange() {
        var flow = original()
        flow.executeOverlay = ExecuteOverlay(response: response(200, body: "xyz"))
        #expect(ExecuteDiff.compare(flow).response == [.init(text: "正文：3 字节 → 3 字节")])
    }

    @Test func diffWithoutChangesIsEmpty() {
        var flow = original()
        #expect(ExecuteDiff.compare(flow).isEmpty)
        flow.executeOverlay = ExecuteOverlay(response: response(200, body: "abc"))
        #expect(ExecuteDiff.compare(flow).isEmpty)
    }
}
