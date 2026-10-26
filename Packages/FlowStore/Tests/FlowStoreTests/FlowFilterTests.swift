import Foundation
import Testing

@testable import FlowStore

private func makeFlow(
    _ id: Int,
    method: String = "GET",
    host: String = "x.com",
    path: String = "/",
    status: Int? = nil,
    contentType: String? = nil,
    client: String? = nil,
    state: FlowState = .completed
) -> Flow {
    var f = Flow(id: id, scheme: "https", method: method, host: host, port: 443, path: path)
    f.statusCode = status
    f.state = state
    if let contentType { f.responseHeaders = [HeaderField(name: "Content-Type", value: contentType)] }
    if let client { f.client = ClientApp(pid: 100, name: client) }
    return f
}

@Suite struct FlowFilterTests {
    @Test func suppliedSummaryIdentifiesAttemptWithoutClaimingVerification() {
        let flow = makeFlow(1, status: 400)
        let summary = WebSocketSummary(handshake: WebSocketHandshake(assessment: .invalid))
        #expect(FlowProtocol.of(flow, webSocketSummary: summary) == .websocket)
        #expect(FlowProtocol.of(flow, webSocketSummary: nil) == .https)
    }

    @Test func classifyContentType() {
        #expect(ContentKind.classify(contentType: "application/json; charset=utf-8") == .json)
        #expect(ContentKind.classify(contentType: "application/problem+json") == .json)
        #expect(ContentKind.classify(contentType: "text/html") == .html)
        #expect(ContentKind.classify(contentType: "TEXT/HTML; charset=UTF-8") == .html)
        #expect(ContentKind.classify(contentType: "application/xml") == .xml)
        #expect(ContentKind.classify(contentType: "application/atom+xml") == .xml)
        #expect(ContentKind.classify(contentType: "application/javascript") == .javascript)
        #expect(ContentKind.classify(contentType: "text/javascript") == .javascript)
        #expect(ContentKind.classify(contentType: "text/css") == .css)
        #expect(ContentKind.classify(contentType: "image/webp") == .image)
        #expect(ContentKind.classify(contentType: "image/svg+xml") == .image)
        #expect(ContentKind.classify(contentType: "font/woff2") == .font)
        #expect(ContentKind.classify(contentType: "application/font-woff") == .font)
        #expect(ContentKind.classify(contentType: "video/mp4") == .media)
        #expect(ContentKind.classify(contentType: "audio/mpeg") == .media)
        #expect(ContentKind.classify(contentType: "text/plain") == .text)
        #expect(ContentKind.classify(contentType: "application/octet-stream") == .other)
        #expect(ContentKind.classify(contentType: "") == .other)
        #expect(ContentKind.classify(contentType: nil) == .other)
    }

    @Test func statusClassOfFlow() {
        #expect(StatusClass.of(makeFlow(1, status: 101)) == .informational)
        #expect(StatusClass.of(makeFlow(1, status: 200)) == .success)
        #expect(StatusClass.of(makeFlow(1, status: 304)) == .redirect)
        #expect(StatusClass.of(makeFlow(1, status: 404)) == .clientError)
        #expect(StatusClass.of(makeFlow(1, status: 503)) == .serverError)
        #expect(StatusClass.of(makeFlow(1, state: .failed("x"))) == .failed)
        #expect(StatusClass.of(makeFlow(1, state: .inProgress)) == nil)
        #expect(StatusClass.of(makeFlow(1, state: .tunnel)) == nil)
    }

    @Test func emptyFilterMatchesEverything() {
        #expect(FlowFilter().matches(makeFlow(1)))
        #expect(FlowFilter().matches(makeFlow(2, state: .inProgress)))
    }

    @Test func textFilterMatchesURLCaseInsensitively() {
        let flow = makeFlow(1, path: "/api/users?id=1")
        var filter = FlowFilter()
        filter.text = "API/USERS"
        #expect(filter.matches(flow))
        filter.text = "nomatch"
        #expect(!filter.matches(flow))
        filter.text = "   "
        #expect(filter.matches(flow))
    }

    @Test func methodStatusKindFiltersCombineWithAND() {
        let post404 = makeFlow(1, method: "POST", status: 404, contentType: "application/json")
        let get404 = makeFlow(2, method: "GET", status: 404, contentType: "application/json")
        let post200 = makeFlow(3, method: "POST", status: 200, contentType: "application/json")
        let post404Html = makeFlow(4, method: "POST", status: 404, contentType: "text/html")

        var filter = FlowFilter()
        filter.methods = ["POST"]
        filter.statusClasses = [.clientError]
        #expect([post404, get404, post200, post404Html].filter(filter.matches).map(\.id) == [1, 4])

        filter.contentKinds = [.json]
        #expect([post404, get404, post200, post404Html].filter(filter.matches).map(\.id) == [1])

        filter.contentKinds = [.json, .html]
        filter.methods = []
        #expect([post404, get404, post200, post404Html].filter(filter.matches).map(\.id) == [1, 2, 4])
    }

    @Test func contentKindFilterUsesResponseContentTypeOnly() {
        var request = makeFlow(1)
        request.requestHeaders = [HeaderField(name: "Content-Type", value: "application/json")]
        var filter = FlowFilter()
        filter.contentKinds = [.json]
        #expect(!filter.matches(request))
        filter.contentKinds = [.other]
        #expect(filter.matches(request))
    }

    @Test func failedFlowMatchesFailedStatusClass() {
        let failed = makeFlow(1, state: .failed("x"))
        let ok = makeFlow(2, status: 200)
        let pending = makeFlow(3, state: .inProgress)
        var filter = FlowFilter()
        filter.statusClasses = [.failed]
        #expect(filter.matches(failed))
        #expect(!filter.matches(ok))
        #expect(!filter.matches(pending))
    }

    @Test func scopeHostAndApp() {
        let curlA = makeFlow(1, host: "a.com", client: "curl")
        let unknownB = makeFlow(2, host: "b.com")
        var filter = FlowFilter()

        filter.scope = .host("a.com")
        #expect(filter.matches(curlA))
        #expect(!filter.matches(unknownB))

        filter.scope = .app("curl")
        #expect(filter.matches(curlA))
        #expect(!filter.matches(unknownB))

        filter.scope = .app("未知")
        #expect(!filter.matches(curlA))
        #expect(filter.matches(unknownB))
    }

    @Test func scopeAppHostNeedsBothTheAppAndTheHost() {
        var filter = FlowFilter()
        filter.scope = .appHost(app: "curl", host: "a.com")
        #expect(filter.matches(makeFlow(1, host: "a.com", client: "curl")))
        #expect(!filter.matches(makeFlow(2, host: "b.com", client: "curl")))
        #expect(!filter.matches(makeFlow(3, host: "a.com", client: "Safari")))
        #expect(!filter.matches(makeFlow(4, host: "a.com")))

        filter.scope = .appHost(app: FlowGrouping.unknownApp, host: "a.com")
        #expect(filter.matches(makeFlow(4, host: "a.com")))
    }

    @Test func groupingHostsOfOneApp() {
        let flows = [
            makeFlow(1, host: "b.com", client: "curl"),
            makeFlow(2, host: "a.com", client: "curl"),
            makeFlow(3, host: "a.com", client: "curl"),
            makeFlow(4, host: "c.com"),
        ]
        #expect(
            FlowGrouping.hosts(flows, ofApp: "curl")
                == [GroupCount(name: "a.com", count: 2), GroupCount(name: "b.com", count: 1)])
        #expect(FlowGrouping.hosts(flows, ofApp: FlowGrouping.unknownApp) == [GroupCount(name: "c.com", count: 1)])
        #expect(FlowGrouping.hosts(flows, ofApp: "Safari").isEmpty)
    }

    @Test func groupingCountsHostsAndApps() {
        let flows = [
            makeFlow(1, host: "b.com", client: "curl"),
            makeFlow(2, host: "a.com", client: "curl"),
            makeFlow(3, host: "a.com"),
        ]
        #expect(FlowGrouping.hosts(flows) == [GroupCount(name: "a.com", count: 2), GroupCount(name: "b.com", count: 1)])
        #expect(FlowGrouping.apps(flows) == [GroupCount(name: "curl", count: 2), GroupCount(name: "未知", count: 1)])
        #expect(FlowGrouping.hosts([]).isEmpty)
    }

    // MARK: hidden, marks, rules-modified, comment

    @Test func hiddenFlowsNeverMatchByDefault() {
        var flow = makeFlow(1)
        flow.isHidden = true
        var filter = FlowFilter()
        #expect(!filter.matches(flow))
        filter.includeHidden = true
        #expect(filter.matches(flow))
    }

    @Test func hasMarkMatchesEitherMark() {
        var filter = FlowFilter()
        filter.hasMark = true
        var none = makeFlow(1)
        var ruleOnly = makeFlow(2)
        ruleOnly.ruleMark = FlowMark(background: "#112233", source: .rule(id: UUID(), name: "r"))
        var manualOnly = makeFlow(3)
        manualOnly.manualMark = FlowMark(background: "#445566", source: .manual)
        #expect(!filter.matches(none))
        #expect(filter.matches(ruleOnly))
        #expect(filter.matches(manualOnly))
        filter.hasMark = false
        none.comment = nil
        #expect(filter.matches(none))
    }

    @Test func rulesModifiedUsesTheProvenanceFlag() {
        var filter = FlowFilter()
        filter.rulesModified = true
        var flow = makeFlow(1)
        #expect(!filter.matches(flow))
        flow.provenance.rulesModified = true
        #expect(filter.matches(flow))
    }

    @Test func filterRulesModifiedCountsTheOverlay() {
        var filter = FlowFilter()
        filter.rulesModified = true
        var flow = makeFlow(1)
        #expect(!flow.provenance.rulesModified)
        flow.execute = ExecuteRecord(
            runID: UUID(), executedAt: Date(timeIntervalSince1970: 0),
            matches: RuleMatchSummary(revision: 1, ruleIDs: [], total: 0),
            baseline: ExecuteFieldValues(), written: ExecuteFieldValues(comment: "c"))
        #expect(!filter.matches(flow), "an Execute record without an overlay is an annotation, not a modification")
        flow.executeOverlay = ExecuteOverlay(
            response: HTTPMessageSnapshot(
                boundary: .downstreamResponse, head: .response(status: 200, reason: nil, headers: [])))
        #expect(filter.matches(flow))
    }

    @Test func commentContainsIsCaseInsensitiveAndTrimmed() {
        var flow = makeFlow(1)
        flow.comment = "Slow Login"
        var filter = FlowFilter()
        filter.commentContains = " login "
        #expect(filter.matches(flow))
        filter.commentContains = "LOGIN"
        #expect(filter.matches(flow))
        filter.commentContains = "logout"
        #expect(!filter.matches(flow))
        flow.comment = nil
        filter.commentContains = "login"
        #expect(!filter.matches(flow))
        filter.commentContains = "   \t "
        #expect(filter.matches(flow))
        flow.comment = "anything"
        #expect(filter.matches(flow))
    }

    @Test func newConditionsCombineWithAnd() {
        var filter = FlowFilter()
        filter.hasMark = true
        filter.rulesModified = true
        filter.commentContains = "slow"
        var flow = makeFlow(1)
        flow.manualMark = FlowMark(background: "#445566", source: .manual)
        flow.provenance.rulesModified = true
        flow.comment = "Slow"
        #expect(filter.matches(flow))
        var noComment = flow
        noComment.comment = "fast"
        #expect(!filter.matches(noComment))
        var noMark = flow
        noMark.manualMark = nil
        #expect(!filter.matches(noMark))
        var unmodified = flow
        unmodified.provenance.rulesModified = false
        #expect(!filter.matches(unmodified))
        var hidden = flow
        hidden.isHidden = true
        #expect(!filter.matches(hidden))
    }

    @Test func defaultFilterEqualsAFreshFilter() {
        #expect(FlowFilter() == FlowFilter())
        var changed = FlowFilter()
        changed.includeHidden = true
        #expect(changed != FlowFilter())
        changed = FlowFilter()
        changed.commentContains = "x"
        #expect(changed != FlowFilter())
    }

    @Test func idsFilterKeepsOnlyListedFlows() {
        var filter = FlowFilter()
        filter.ids = [1, 3]
        #expect(filter.matches(makeFlow(1)))
        #expect(!filter.matches(makeFlow(2)))
        #expect(filter.matches(makeFlow(3)))
    }

    @Test func nilIdsMeansNoRestriction() {
        let filter = FlowFilter()
        #expect(filter.ids == nil)
        #expect(filter.matches(makeFlow(42)))
    }

    @Test func emptyIdsMatchNothing() {
        var filter = FlowFilter()
        filter.ids = []
        #expect(!filter.matches(makeFlow(1)))
    }

    @Test func idsCombineWithOtherConditionsByAnd() {
        var filter = FlowFilter()
        filter.ids = [1, 2]
        filter.methods = ["POST"]
        #expect(!filter.matches(makeFlow(1, method: "GET")))
        #expect(filter.matches(makeFlow(2, method: "POST")))
        #expect(!filter.matches(makeFlow(3, method: "POST")))
    }

    @Test func filterWithIdsIsNotEqualToDefault() {
        var filter = FlowFilter()
        filter.ids = []
        #expect(FlowFilter() != filter)
    }
}
