import FlowStore
import Foundation
import Testing

@testable import RulesEngine

private func header(_ name: String, _ value: String) -> HeaderField { HeaderField(name: name, value: value) }

private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

/// A finished legacy flow (no message boundaries): the old request* / response* projection only.
private func legacy(
    _ id: Int, host: String = "a.test", path: String = "/", status: Int? = 200, headers: [HeaderField] = []
) -> Flow {
    var flow = Flow(id: id, startedAt: epoch, scheme: "https", method: "GET", host: host, port: 443, path: path)
    flow.requestHeaders = headers
    flow.statusCode = status
    flow.state = .completed
    flow.completedAt = epoch.addingTimeInterval(0.2)
    return flow
}

private func request(
    _ boundary: HTTPMessageBoundary, path: String, headers: [HeaderField] = [], body: BodyRef? = nil
) -> HTTPMessageSnapshot {
    let target = HTTPMessageTarget(scheme: "https", host: "a.test", port: 443, method: "GET", pathAndQuery: path)
    return HTTPMessageSnapshot(
        boundary: boundary, head: .request(target, headers: headers),
        body: body.map { HTTPBodySlice(ref: $0, offset: 0, count: $0.size) }, bodyState: .complete,
        observedBytes: UInt64(body?.size ?? 0), transferState: .finished)
}

private func response(
    _ boundary: HTTPMessageBoundary, status: Int, headers: [HeaderField] = [], body: BodyRef? = nil,
    state: HTTPBodyState = .complete
) -> HTTPMessageSnapshot {
    HTTPMessageSnapshot(
        boundary: boundary, head: .response(status: status, reason: nil, headers: headers),
        body: body.map { HTTPBodySlice(ref: $0, offset: 0, count: $0.size) }, bodyState: state,
        observedBytes: UInt64(body?.size ?? 0), transferState: .finished)
}

private func row(_ field: ConditionField, _ op: ConditionOperator, _ value: String = "", name: String? = nil) -> ConditionRow {
    ConditionRow(field: field, name: name, op: op, value: value)
}

private func group(_ rows: ConditionRow..., mode: ConditionGroup.Mode = .all) -> ConditionGroup {
    ConditionGroup(mode: mode, rows: rows)
}

private let textType = [header("Content-Type", "text/plain")]

@Suite struct LiveMatcherTests {
    @Test func countsMatchingFinishedFlows() {
        let flows = [legacy(1, host: "a.test"), legacy(2, host: "b.test"), legacy(3, host: "a.test")]
        let report = LiveMatcher.evaluate(group(row(.host, .equals, "a.test")), over: flows)
        #expect(report == LiveMatchReport(matchedIDs: [1, 3], scanned: 3, skippedInProgress: 0, skippedLargeBodies: 0))
    }

    @Test func readsTheOriginalRequestNotTheModifiedOne() {
        var flow = legacy(1, path: "/modified", headers: [header("X-Mode", "modified")])
        flow.messages[.downstreamRequest] = request(.downstreamRequest, path: "/original", headers: [header("X-Mode", "original")])
        flow.messages[.upstreamRequest] = request(.upstreamRequest, path: "/modified", headers: [header("X-Mode", "modified")])
        #expect(LiveMatcher.evaluate(group(row(.path, .equals, "/original")), over: [flow]).matchedIDs == [1])
        #expect(LiveMatcher.evaluate(group(row(.path, .equals, "/modified")), over: [flow]).matchedIDs.isEmpty)
        #expect(LiveMatcher.evaluate(group(row(.requestHeader, .equals, "original", name: "X-Mode")), over: [flow]).matchedIDs == [1])
    }

    @Test func responseReadsUpstreamThenGeneratedThenLegacy() {
        var upstream = legacy(1, status: 500)
        upstream.messages[.downstreamRequest] = request(.downstreamRequest, path: "/")
        upstream.messages[.upstreamResponse] = response(.upstreamResponse, status: 200)
        upstream.messages[.generatedResponse] = response(.generatedResponse, status: 599)
        var generated = legacy(2, status: 500)
        generated.messages[.downstreamRequest] = request(.downstreamRequest, path: "/")
        generated.messages[.generatedResponse] = response(.generatedResponse, status: 502)
        let old = legacy(3, status: 404)
        let flows = [upstream, generated, old]
        func ids(_ status: String) -> [Int] {
            LiveMatcher.evaluate(group(row(.statusCode, .equals, status)), over: flows).matchedIDs
        }
        #expect(ids("200") == [1])
        #expect(ids("502") == [2])
        #expect(ids("404") == [3])
        #expect(ids("500").isEmpty && ids("599").isEmpty)
    }

    @Test func composeFlowsReadSubmittedAndDelivered() {
        var flow = legacy(1, path: "/ignored", status: 500)
        flow.provenance = FlowProvenance(source: .compose(sendID: UUID(), sourceFlowID: nil, sourceBoundary: nil))
        flow.messages[.downstreamRequest] = request(.downstreamRequest, path: "/downstream")
        flow.messages[.composeSubmitted] = request(.composeSubmitted, path: "/submitted")
        flow.messages[.upstreamResponse] = response(.upstreamResponse, status: 500)
        flow.messages[.composeDelivered] = response(.composeDelivered, status: 201)
        let report = LiveMatcher.evaluate(
            group(row(.path, .equals, "/submitted"), row(.statusCode, .equals, "201")), over: [flow])
        #expect(report.matchedIDs == [1])
        #expect(LiveMatcher.evaluate(group(row(.path, .equals, "/downstream")), over: [flow]).matchedIDs.isEmpty)
    }

    /// A request that has been sent but not answered: no status, no response, no completion.
    private func inFlight(_ id: Int, host: String = "a.test", path: String = "/", paused: Bool = false) -> Flow {
        var flow = Flow(id: id, startedAt: epoch, scheme: "https", method: "GET", host: host, port: 443, path: path)
        flow.messages[.downstreamRequest] = request(.downstreamRequest, path: path)
        flow.isPausedAtBreakpoint = paused
        return flow
    }

    @Test func inFlightSessionsAreJudgedOnWhatHasArrived() {
        let flows = [legacy(1), inFlight(2), legacy(3)]
        let all = LiveMatcher.evaluate(ConditionGroup(), over: flows)
        #expect(all == LiveMatchReport(matchedIDs: [1, 2, 3], scanned: 3, skippedInProgress: 0, skippedLargeBodies: 0))
        #expect(LiveMatcher.evaluate(group(row(.host, .equals, "a.test")), over: flows).matchedIDs == [1, 2, 3])
        #expect(LiveMatcher.evaluate(group(row(.path, .equals, "/x")), over: [inFlight(2, path: "/x")]).matchedIDs == [2])
    }

    @Test func rowsNeedingUnavailableDataDoNotMatchInFlightSessions() {
        let flow = inFlight(1)
        for unavailable in [
            row(.statusCode, .equals, "200"), row(.statusCode, .notEquals, "200"), row(.durationMs, .greaterThan, "0"),
            row(.responseBody, .contains, "x"), row(.responseBody, .notContains, "x"), row(.responseBodySize, .greaterThan, "-1"),
        ] {
            #expect(LiveMatcher.evaluate(group(unavailable), over: [flow]).matchedIDs.isEmpty, "\(unavailable.field)")
        }
    }

    @Test func sessionStateOpenedPausedClosed() {
        let flows = [legacy(1), inFlight(2), inFlight(3, paused: true)]
        func ids(_ state: String) -> [Int] {
            LiveMatcher.evaluate(group(row(.sessionState, .equals, state)), over: flows).matchedIDs
        }
        #expect(ids("opened") == [2])
        #expect(ids("paused") == [3])
        #expect(ids("closed") == [1])
        var failed = legacy(4)
        failed.state = .failed("boom")
        #expect(LiveMatcher.evaluate(group(row(.sessionState, .equals, "closed")), over: [failed]).matchedIDs == [4])
        // The old values keep reading the finished exchange only.
        #expect(LiveMatcher.evaluate(group(row(.sessionState, .equals, "completed")), over: flows).matchedIDs == [1])
        #expect(LiveMatcher.evaluate(group(row(.sessionState, .equals, "failed")), over: [failed, inFlight(5)]).matchedIDs == [4])
    }

    @Test func inFlightResponseHeadMatchesStatusButNotBody() {
        var flow = inFlight(1)
        flow.messages[.upstreamResponse] = response(.upstreamResponse, status: 200, state: .pending)
        #expect(LiveMatcher.evaluate(group(row(.statusCode, .equals, "200")), over: [flow]).matchedIDs == [1])
        let body = LiveMatcher.evaluate(group(row(.responseBody, .contains, "x")), over: [flow])
        #expect(body.matchedIDs.isEmpty && body.skippedLargeBodies == 0)
    }

    @Test func sseResponseStaysOpenedUntilItEnds() {
        var flow = inFlight(1)
        flow.messages[.upstreamResponse] = response(
            .upstreamResponse, status: 200, headers: [header("Content-Type", "text/event-stream")], state: .pending)
        #expect(LiveMatcher.evaluate(group(row(.sessionState, .equals, "opened")), over: [flow]).matchedIDs == [1])
        #expect(LiveMatcher.evaluate(group(row(.sessionState, .equals, "closed")), over: [flow]).matchedIDs.isEmpty)
        #expect(LiveMatcher.evaluate(group(row(.durationMs, .greaterThan, "0")), over: [flow]).matchedIDs.isEmpty)
    }

    /// A 101 that finished its HTTP exchange while the WebSocket session it opened is still going.
    private func upgraded(_ id: Int) -> Flow {
        var flow = legacy(id, status: 101)
        flow.messages[.downstreamRequest] = request(.downstreamRequest, path: "/")
        flow.messages[.upstreamResponse] = response(.upstreamResponse, status: 101)
        return flow
    }

    @Test func openWebSocketSessionCountsAsOpenedNotClosed() {
        let flow = upgraded(1)
        func ids(_ conditions: ConditionGroup, open: Set<Int>) -> [Int] {
            LiveMatcher.evaluate(conditions, over: [flow], openWebSocketFlowIDs: open).matchedIDs
        }
        // While the session is open: opened, never closed; duration and response size stay unknown.
        #expect(ids(group(row(.sessionState, .equals, "opened")), open: [1]) == [1])
        #expect(ids(group(row(.sessionState, .equals, "closed")), open: [1]).isEmpty)
        #expect(ids(group(row(.durationMs, .greaterThan, "0")), open: [1]).isEmpty)
        #expect(ids(group(row(.responseBodySize, .equals, "0")), open: [1]).isEmpty)
        #expect(ids(group(row(.statusCode, .equals, "101")), open: [1]) == [1])
        // After the session closes the flow reads as finished again.
        #expect(ids(group(row(.sessionState, .equals, "closed")), open: []) == [1])
        #expect(ids(group(row(.sessionState, .equals, "opened")), open: []).isEmpty)
        #expect(ids(group(row(.durationMs, .greaterThan, "0")), open: []) == [1])
        #expect(ids(group(row(.responseBodySize, .equals, "0")), open: []) == [1])
    }

    @Test func requestBodyOfAnInFlightSessionWithoutASnapshotIsPendingNotEmpty() {
        var flow = Flow(id: 1, startedAt: epoch, scheme: "https", method: "POST", host: "a.test", port: 443, path: "/")
        flow.state = .inProgress
        #expect(flow.messages.isEmpty)
        for condition in [row(.requestBody, .notContains, "x"), row(.requestBody, .contains, "x"), row(.requestBody, .equals, "")] {
            let report = LiveMatcher.evaluate(group(condition), over: [flow])
            #expect(report.matchedIDs.isEmpty, "\(condition.op)")
            #expect(report.skippedLargeBodies == 0)
        }
    }

    @Test func tunnelsAreNeverMatched() {
        var tunnel = legacy(1)
        tunnel.method = "CONNECT"
        tunnel.state = .tunnel
        let report = LiveMatcher.evaluate(group(row(.method, .equals, "GET"), mode: .none), over: [tunnel])
        #expect(report.matchedIDs.isEmpty && report.scanned == 1)
    }

    private func onDiskBody() throws -> (BodyRef, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pw-live-\(UUID().uuidString)")
        let store = FlowStore(bodyDirectory: directory)
        let capture = store.makeBodyCapture()
        capture.append([UInt8](repeating: 0x61, count: 600_000))
        capture.append([UInt8](repeating: 0x61, count: 600_000))
        let body = try #require(capture.finish().body)
        guard case .managed(let handle) = body, handle.isOnDisk else {
            Issue.record("expected a spilled body")
            return (body, directory)
        }
        return (body, directory)
    }

    @Test func bodyOnDiskIsSkippedAndCounted() throws {
        let (body, directory) = try onDiskBody()
        defer { try? FileManager.default.removeItem(at: directory) }
        var flow = legacy(1)
        flow.messages[.downstreamRequest] = request(.downstreamRequest, path: "/")
        flow.messages[.upstreamResponse] = response(.upstreamResponse, status: 200, headers: textType, body: body)
        let contains = group(row(.responseBody, .contains, "a"))
        let report = LiveMatcher.evaluate(contains, over: [flow])
        #expect(report == LiveMatchReport(matchedIDs: [], scanned: 1, skippedInProgress: 0, skippedLargeBodies: 1))
        // An unknown row is not "no row matches": the none combination does not match either.
        let none = LiveMatcher.evaluate(group(row(.responseBody, .contains, "zzz"), mode: .none), over: [flow])
        #expect(none.matchedIDs.isEmpty && none.skippedLargeBodies == 1)
        // A condition that never reads the body does not skip it.
        let headersOnly = LiveMatcher.evaluate(group(row(.statusCode, .equals, "200")), over: [flow])
        #expect(headersOnly.matchedIDs == [1] && headersOnly.skippedLargeBodies == 0)
    }

    @Test func inMemoryBodyIsMatched() {
        var flow = legacy(1)
        flow.messages[.downstreamRequest] = request(
            .downstreamRequest, path: "/", headers: textType, body: .memory(Data("ping".utf8)))
        flow.messages[.upstreamResponse] = response(
            .upstreamResponse, status: 200, headers: textType, body: .memory(Data("hello world".utf8)))
        let report = LiveMatcher.evaluate(
            group(row(.responseBody, .contains, "hello"), row(.requestBody, .equals, "ping")), over: [flow])
        #expect(report == LiveMatchReport(matchedIDs: [1], scanned: 1, skippedInProgress: 0, skippedLargeBodies: 0))
        // A legacy flow reads its requestBody / responseBody.
        var old = legacy(2)
        old.responseHeaders = textType
        old.responseBody = .memory(Data("hello legacy".utf8))
        #expect(LiveMatcher.evaluate(group(row(.responseBody, .contains, "legacy")), over: [old]).matchedIDs == [2])
    }

    @Test func truncatedBodyIsSkippedAsLarge() {
        var flow = legacy(1)
        flow.messages[.upstreamResponse] = response(
            .upstreamResponse, status: 200, headers: textType, body: .memory(Data("hel".utf8)), state: .truncated)
        let report = LiveMatcher.evaluate(group(row(.responseBody, .contains, "hel")), over: [flow])
        #expect(report.matchedIDs.isEmpty && report.skippedLargeBodies == 1)
    }

    @Test func streamingAndUnavailableBodiesAreSkippedAndCounted() {
        for state in [HTTPBodyState.pending, .incomplete, .unavailable] {
            var flow = legacy(1)
            flow.messages[.upstreamResponse] = response(
                .upstreamResponse, status: 200, headers: textType, body: .memory(Data("hel".utf8)), state: state)
            let report = LiveMatcher.evaluate(group(row(.responseBody, .contains, "hel")), over: [flow])
            #expect(report.matchedIDs.isEmpty && report.skippedLargeBodies == 1, "\(state)")
        }
    }

    @Test func completionFieldsUseTheFinishedFlow() {
        var slow = legacy(1)
        slow.completedAt = epoch.addingTimeInterval(1.5)
        slow.messages[.upstreamResponse] = response(.upstreamResponse, status: 200)
        slow.bytesReceived = 2048
        var failed = legacy(2)
        failed.state = .failed("reset")
        let flows = [slow, failed]
        #expect(LiveMatcher.evaluate(group(row(.durationMs, .greaterThan, "1000")), over: flows).matchedIDs == [1])
        #expect(LiveMatcher.evaluate(group(row(.sessionState, .equals, "failed")), over: flows).matchedIDs == [2])
        #expect(LiveMatcher.evaluate(group(row(.sessionState, .equals, "completed")), over: flows).matchedIDs == [1])
        #expect(LiveMatcher.evaluate(group(row(.responseBodySize, .greaterThan, "2000")), over: flows).matchedIDs == [1])
        #expect(LiveMatcher.evaluate(group(row(.responseBodySize, .lessThan, "2000")), over: flows).matchedIDs == [2])
    }

    @Test func ruleFieldsUseProvenanceAndComment() {
        var changed = legacy(1)
        changed.provenance = FlowProvenance(rulesModified: true)
        changed.comment = "slow upstream"
        let plain = legacy(2)
        let flows = [changed, plain]
        #expect(LiveMatcher.evaluate(group(row(.rulesModified, .equals, "true")), over: flows).matchedIDs == [1])
        #expect(LiveMatcher.evaluate(group(row(.rulesModified, .equals, "false")), over: flows).matchedIDs == [2])
        #expect(LiveMatcher.evaluate(group(row(.comment, .contains, "slow")), over: flows).matchedIDs == [1])
    }

    @Test func connectionFieldsUseRecordedMetadata() {
        var flow = legacy(1)
        flow.clientIP = "192.168.1.5"
        flow.remoteIP = "93.184.216.34"
        flow.transport = HTTPTransportMetadata(
            downstreamRequest: .http2, upstreamRequest: .http1_1, downstreamTLSVersion: "TLS 1.3",
            upstreamTLSVersion: "TLS 1.2")
        flow.client = ClientApp(pid: 42, name: "curl", executablePath: "/usr/bin/curl")
        flow.upstreamCertificate = CertificateSummary(
            subject: "CN=a.test", issuer: "CN=Test CA", serialNumber: "01", sha256Fingerprint: String(repeating: "A", count: 64),
            notBefore: epoch, notAfter: epoch.addingTimeInterval(3600))
        let rows = [
            row(.clientIP, .equals, "192.168.1.5"), row(.remoteIP, .equals, "93.184.216.34"),
            row(.clientHTTPVersion, .equals, "h2"), row(.upstreamHTTPVersion, .equals, "h1"),
            row(.clientTLSVersion, .equals, "TLS 1.3"), row(.upstreamTLSVersion, .equals, "TLS 1.2"),
            row(.clientApp, .equals, "curl", name: "name"), row(.certificate, .contains, "a.test", name: "subject"),
        ]
        for one in rows {
            #expect(LiveMatcher.evaluate(group(one), over: [flow]).matchedIDs == [1], "\(one.field)")
        }
        // Nothing recorded: the row is unknown, not a match.
        #expect(LiveMatcher.evaluate(group(row(.clientIP, .equals, "192.168.1.5")), over: [legacy(2)]).matchedIDs.isEmpty)
    }

    @Test func occurrenceIsIgnored() {
        let limited = ConditionGroup(occurrence: .times(2...2), rows: [row(.host, .equals, "a.test")])
        #expect(LiveMatcher.evaluate(limited, over: [legacy(1), legacy(2), legacy(3)]).matchedIDs == [1, 2, 3])
    }

    @Test func cancelledStopsEarlyAndReportsPartial() {
        let flows = (1...200).map { legacy($0) }
        let report = LiveMatcher.evaluate(ConditionGroup(), over: flows, isCancelled: { true })
        #expect(report.scanned == 64)
        #expect(report.matchedIDs == Array(1...64))
    }

    @Test func notCancelledScansEverything() {
        let flows = (1...200).map { legacy($0) }
        #expect(LiveMatcher.evaluate(ConditionGroup(), over: flows).scanned == 200)
    }

    @Test func emptyConditionsMatchEveryFlowIncludingInFlight() {
        var running = legacy(3)
        running.state = .inProgress
        let report = LiveMatcher.evaluate(ConditionGroup(), over: [legacy(1), legacy(2), running])
        #expect(report.matchedIDs == [1, 2, 3])
    }
}
