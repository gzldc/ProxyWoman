import FlowStore
import Foundation
import Testing

@testable import RulesEngine

private func header(_ name: String, _ value: String) -> HeaderField { HeaderField(name: name, value: value) }

private func message(
    _ boundary: HTTPMessageBoundary, status: Int, body: BodyRef? = nil, state: HTTPBodyState = .complete
) -> HTTPMessageSnapshot {
    HTTPMessageSnapshot(
        boundary: boundary, head: .response(status: status, reason: nil, headers: []),
        body: body.map { HTTPBodySlice(ref: $0, offset: 0, count: $0.size) }, bodyState: state,
        observedBytes: UInt64(body?.size ?? 0), transferState: .finished)
}

private func requestMessage(_ boundary: HTTPMessageBoundary, path: String) -> HTTPMessageSnapshot {
    HTTPMessageSnapshot(
        boundary: boundary,
        head: .request(HTTPMessageTarget(scheme: "https", host: "a.test", port: 443, method: "GET", pathAndQuery: path), headers: []),
        bodyState: .complete, transferState: .finished)
}

private func spilledBody(_ text: String) throws -> BodyRef {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("flow-originals-\(UUID().uuidString).txt")
    try Data(text.utf8).write(to: url)
    return .file(url, size: text.utf8.count)
}

private let textHeaders = [header("Content-Type", "text/plain")]

@Suite struct FlowOriginalsTests {
    @Test func requestAndResponseFollowTheLiveMatcherChoice() {
        var flow = ExecuteFixtures.flow(path: "/original", status: 200)
        flow.messages[.upstreamRequest] = requestMessage(.upstreamRequest, path: "/modified")
        flow.messages[.generatedResponse] = message(.generatedResponse, status: 599)
        let upstream = FlowOriginals.of(flow)
        #expect(upstream?.request.target?.pathAndQuery == "/original")
        #expect(upstream?.response?.status == 200)
        #expect(upstream?.hadOriginResponse == true)

        var generated = ExecuteFixtures.flow(status: nil)
        generated.messages[.generatedResponse] = message(.generatedResponse, status: 502)
        let local = FlowOriginals.of(generated)
        #expect(local?.response?.status == 502)
        #expect(local?.hadOriginResponse == false)

        var compose = ExecuteFixtures.flow(path: "/ignored", status: 500)
        compose.provenance = FlowProvenance(source: .compose(sendID: UUID(), sourceFlowID: nil, sourceBoundary: nil))
        compose.messages[.composeSubmitted] = requestMessage(.composeSubmitted, path: "/submitted")
        compose.messages[.composeDelivered] = message(.composeDelivered, status: 201)
        let composed = FlowOriginals.of(compose)
        #expect(composed?.request.target?.pathAndQuery == "/submitted")
        #expect(composed?.response?.status == 201)
        #expect(composed?.facts.app == .notApplicable)
    }

    @Test func inProgressFlowHasNoOriginals() {
        #expect(FlowOriginals.of(ExecuteFixtures.flow(state: .inProgress)) == nil)
    }

    @Test func tunnelFlowIsMarkedAndHasNoResponse() {
        let originals = FlowOriginals.of(ExecuteFixtures.tunnel(7, host: "t.test"))
        #expect(originals?.isTunnel == true)
        #expect(originals?.response == nil)
        #expect(originals?.completion.state == .tunnel)
        #expect(originals?.hadOriginResponse == false)
        #expect(FlowOriginals.of(ExecuteFixtures.flow())?.isTunnel == false)
    }

    @Test func legacyFlowProjectsHeadersAndBodies() {
        var flow = Flow(id: 1, startedAt: ExecuteFixtures.epoch, scheme: "https", method: "POST", host: "a.test", port: 443, path: "/old")
        flow.requestHeaders = [header("X-A", "1")]
        flow.requestBody = .memory(Data("req".utf8))
        flow.statusCode = 404
        flow.responseHeaders = [header("X-B", "2")]
        flow.responseBody = .memory(Data("resp".utf8))
        flow.state = .completed
        let originals = FlowOriginals.of(flow)
        #expect(originals?.request.target?.method == "POST")
        #expect(originals?.request.headers == [header("X-A", "1")])
        #expect(originals?.request.body.size == 3)
        #expect(originals?.response?.status == 404)
        #expect(originals?.response?.headers == [header("X-B", "2")])
        #expect((try? originals?.response?.body.load(maxBytes: 100)) == Data("resp".utf8))
        #expect(originals?.hadOriginResponse == true)
    }

    @Test func peekReadsSpilledBodyOnlyWhenAllowed() throws {
        var flow = ExecuteFixtures.flow(responseHeaders: textHeaders)
        flow.messages[.upstreamResponse] = message(.upstreamResponse, status: 200, body: try spilledBody("hello"))
        let body = try #require(FlowOriginals.of(flow)?.response?.body)
        #expect(body.peek(headers: textHeaders, allowDisk: false, limits: RulesLimits()) == .skipped(.bodySkippedOnDisk))
        guard case .text(let text) = body.peek(headers: textHeaders, allowDisk: true, limits: RulesLimits()) else {
            Issue.record("expected text")
            return
        }
        #expect(text == "hello")
    }

    @Test func peekOfTruncatedBodyIsTooLarge() {
        var flow = ExecuteFixtures.flow()
        flow.messages[.upstreamResponse] = message(.upstreamResponse, status: 200, body: .memory(Data("abc".utf8)), state: .truncated)
        let body = FlowOriginals.of(flow)?.response?.body
        #expect(body?.peek(headers: [], allowDisk: true, limits: RulesLimits()) == .skipped(.bodyTooLarge))
        #expect(body?.peek(headers: [], allowDisk: false, limits: RulesLimits()) == .skipped(.bodyTooLarge))
    }

    @Test func peekOfUnfinishedBodyIsStreaming() {
        var flow = ExecuteFixtures.flow()
        flow.messages[.upstreamResponse] = message(.upstreamResponse, status: 200, body: .memory(Data("abc".utf8)), state: .pending)
        let body = FlowOriginals.of(flow)?.response?.body
        #expect(body?.peek(headers: [], allowDisk: true, limits: RulesLimits()) == .skipped(.bodySkippedStreaming))
        flow.messages[.upstreamResponse] = message(.upstreamResponse, status: 200, state: .incomplete)
        #expect(FlowOriginals.of(flow)?.response?.body.peek(headers: [], allowDisk: true, limits: RulesLimits()) == .skipped(.bodySkippedStreaming))
    }

    @Test func peekOverTheConditionCapIsTooLarge() {
        let limits = RulesLimits()
        let big = Data(repeating: 0x61, count: limits.conditionBodyBytes + 1)
        let flow = ExecuteFixtures.flow(responseHeaders: textHeaders, responseBody: big)
        let body = FlowOriginals.of(flow)?.response?.body
        #expect(body?.peek(headers: textHeaders, allowDisk: true, limits: limits) == .skipped(.bodyTooLarge))
    }

    @Test func loadStopsAtMaxBytes() throws {
        let flow = ExecuteFixtures.flow(responseBody: Data("0123456789".utf8))
        let body = try #require(FlowOriginals.of(flow)?.response?.body)
        #expect(body.size == 10)
        #expect(try body.load(maxBytes: 4) == Data("0123".utf8))
        #expect(try body.load(maxBytes: 100) == Data("0123456789".utf8))
        let empty = try #require(FlowOriginals.of(ExecuteFixtures.flow())?.request.body)
        #expect(empty.size == 0)
        #expect(try empty.load(maxBytes: 10).isEmpty)
    }

    @Test func completionFactsMatchTheFlow() {
        var flow = ExecuteFixtures.flow(comment: "note")
        flow.bytesReceived = 321
        flow.provenance.rulesModified = true
        let originals = FlowOriginals.of(flow)
        #expect(originals?.completion == CompletionFacts(state: .completed, durationMilliseconds: 250, responseWireBytes: 321))
        #expect(originals?.facts.comment == "note")
        #expect(originals?.facts.rulesModified == true)
        #expect(originals?.facts.requestStartedAt == ExecuteFixtures.epoch)

        var generated = ExecuteFixtures.flow(status: nil)
        generated.bytesReceived = 99
        generated.messages[.generatedResponse] = message(.generatedResponse, status: 502)
        #expect(FlowOriginals.of(generated)?.completion.responseWireBytes == nil)

        var failed = ExecuteFixtures.flow(status: nil, state: .failed("boom"))
        failed.completedAt = nil
        #expect(FlowOriginals.of(failed)?.completion == CompletionFacts(state: .failed, durationMilliseconds: 0, responseWireBytes: nil))
    }
}
