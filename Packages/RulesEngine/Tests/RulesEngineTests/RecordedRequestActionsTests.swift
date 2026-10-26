import FlowStore
import Foundation
import Testing

@testable import RulesEngine

/// Spec R8F2-6: request-side actions of a rule judged at the response change only the recorded request.
@Suite("Recorded request actions")
struct RecordedRequestActionsTests {
    private static let ok = ConditionRow(field: .statusCode, op: .inRange, value: "200-299")

    private func target(path: String = "/v1/items?a=1") -> HTTPMessageTarget {
        HTTPMessageTarget(scheme: "https", host: "a.test", port: 443, method: "GET", pathAndQuery: path)
    }

    private func requestHead(
        headers: [HeaderField] = [HeaderField(name: "Accept", value: "*/*")]
    ) -> HTTPMessageHead { .request(target(), headers: headers) }

    private let responseHead = HTTPMessageHead.response(status: 200, reason: "OK", headers: [])

    private func makeRule(rows: [ConditionRow] = [Self.ok], _ actions: RuleAction...) -> Rule {
        Rule(name: "r", conditions: ConditionGroup(rows: rows), actions: actions)
    }

    private func decide(
        _ rule: Rule, more: [Rule] = [], request: HTTPMessageHead? = nil
    ) throws -> (request: RequestRuleDecision, response: ResponseRuleDecision) {
        let snapshot = RuleSnapshot(revision: 3, rules: [rule] + more)
        let cache = PatternCache(budget: RegexBudget(clock: { .zero }))
        let head = request ?? requestHead()
        let p1 = try RuleEvaluator.request(head, snapshot: snapshot, cache: cache)
        let p2 = try RuleEvaluator.response(responseHead, after: p1, snapshot: snapshot, cache: cache)
        return (p1, p2)
    }

    private let setRequestHeader = RuleAction(
        .editHeaders(direction: .request, operations: [.set(name: "X-Copy", value: "1")]))

    @Test func requestHeaderEditIsRecordedAndLeavesTheDecisionAlone() throws {
        let rule = makeRule(setRequestHeader)
        let (p1, p2) = try decide(rule)
        #expect(p1.effectiveHead == requestHead())
        #expect(p1.route == .original)
        #expect(!p1.rulesModified)
        #expect(p2.recordedRequestActions == [RecordedRequestAction(ruleID: rule.id, actionIndex: 0, kind: setRequestHeader.kind)])
        #expect(p2.effectiveHead == responseHead)
        #expect(!p2.rulesModified)
        #expect(p2.matches.outcomes == [RuleOutcome(ruleID: rule.id, code: .requestActionVisibleOnly)])
        #expect(p2.matches.ruleIDs == [rule.id])
    }

    @Test func severalActionsAreLabelledAndResponseSideStillRuns() throws {
        let response = RuleAction(.editHeaders(direction: .response, operations: [.set(name: "X-R", value: "1")]))
        let rule = makeRule(setRequestHeader, response)
        let (_, p2) = try decide(rule)
        #expect(p2.effectiveHead.headers == [HeaderField(name: "X-R", value: "1")])
        #expect(p2.rulesModified)
        #expect(
            p2.matches.outcomes == [
                RuleOutcome(ruleID: rule.id, code: .requestActionVisibleOnly, actionIndex: 0),
                RuleOutcome(ruleID: rule.id, code: .applied, actionIndex: 1),
            ])
        #expect(p2.recordedRequestActions.map(\.actionIndex) == [0])
    }

    @Test(arguments: [
        ActionKind.breakpoint(direction: .request, mode: .headers),
        .mapRemote(MapRemoteAction(targetScheme: "https", targetHost: "b.test", targetPort: 443, path: .preserve)),
        .rewriteBody(direction: .request, BodyRewriteAction(find: "a", replacement: "b")),
    ])
    func actionsThatCannotActOnARecordAreSkippedAndCutNothing(kind: ActionKind) throws {
        let skipped = makeRule(RuleAction(kind, isFinal: true))
        let after = Rule(
            name: "after", conditions: ConditionGroup(rows: [Self.ok]),
            actions: [RuleAction(.editHeaders(direction: .response, operations: [.set(name: "X-After", value: "1")]))])
        let (_, p2) = try decide(skipped, more: [after])
        #expect(p2.recordedRequestActions.isEmpty)
        #expect(p2.breakpoint == nil)
        #expect(p2.carry.finalStop == nil)
        #expect(
            p2.matches.outcomes == [
                RuleOutcome(ruleID: skipped.id, code: .requestActionSkippedAtResponse),
                RuleOutcome(ruleID: after.id, code: .applied),
            ])
        // The next rule still ran: nothing was cut.
        #expect(p2.effectiveHead.headers == [HeaderField(name: "X-After", value: "1")])
    }

    @Test func aFinalActionBeforeARequestActionSkipsIt() throws {
        let finalStatus = RuleAction(.rewriteStatus(RewriteStatusAction(status: 500)), isFinal: true)
        let rule = makeRule(finalStatus, setRequestHeader)
        let (_, p2) = try decide(rule)
        #expect(p2.recordedRequestActions.isEmpty)
        #expect(p2.matches.outcomes.map(\.code) == [.applied, .finalStop, .skippedAfterFinal])
        #expect(p2.matches.outcomes.last == RuleOutcome(ruleID: rule.id, code: .skippedAfterFinal, actionIndex: 1))
    }

    @Test func aRuleJudgedAtTheRequestPointKeepsRunningItsRequestActionsOnTheWire() throws {
        let atRequest = makeRule(rows: [ConditionRow(field: .method, op: .equals, value: "GET")], setRequestHeader)
        let (p1, p2) = try decide(atRequest)
        #expect(p1.effectiveHead.headers.contains(HeaderField(name: "X-Copy", value: "1")))
        #expect(p2.recordedRequestActions.isEmpty)
    }

    // MARK: applying to a record

    @Test func headerCookieQueryAndURLEditsApplyInOrder() {
        let actions: [ActionKind] = [
            .editHeaders(direction: .request, operations: [.set(name: "X-A", value: "1")]),
            .editCookies(direction: .request, operations: [.set(name: "sid", value: "9")]),
            .modifyQuery(QueryEditAction(operations: [.set(name: "b", value: "2")])),
            .modifyURL(URLEditAction(mode: .set, replacement: "https://b.test/new?z=1")),
        ]
        let recorded = actions.enumerated().map { RecordedRequestAction(ruleID: UUID(), actionIndex: $0, kind: $1) }
        let edited = RecordedRequestEditing.apply(
            recorded, to: requestHead(), cache: PatternCache(budget: RegexBudget(clock: { .zero })))
        guard case .request(let moved, let headers) = edited else {
            Issue.record("not a request")
            return
        }
        #expect(moved.host == "b.test")
        #expect(moved.pathAndQuery == "/new?z=1")
        #expect(headers.contains(HeaderField(name: "X-A", value: "1")))
        #expect(headers.contains { $0.name == "Cookie" && $0.value.contains("sid=9") })
    }

    @Test func queryEditAlonePatchesTheRecordedPath() {
        let kind = ActionKind.modifyQuery(QueryEditAction(operations: [.set(name: "b", value: "2")]))
        let edited = RecordedRequestEditing.apply(
            [RecordedRequestAction(ruleID: UUID(), actionIndex: 0, kind: kind)], to: requestHead())
        #expect(edited.requestTarget?.pathAndQuery == "/v1/items?a=1&b=2")
    }

    @Test func kindsThatCannotApplyLeaveTheRecordAlone() {
        let kind = ActionKind.delay(milliseconds: 5)
        let head = requestHead()
        #expect(RecordedRequestEditing.apply([RecordedRequestAction(ruleID: UUID(), actionIndex: 0, kind: kind)], to: head) == head)
        #expect(RecordedRequestEditing.apply([], to: head) == head)
        #expect(!RecordedRequestEditing.appliesToRecord(kind))
        #expect(RecordedRequestEditing.appliesToRecord(setRequestHeader.kind))
    }

    // MARK: Execute

    @Test func executeShowsTheEditInTheOverlayRequestAndRecordsTheOutcome() async throws {
        let edit = ExecuteFixtures.rule(
            "edit", rows: [Self.ok],
            .editHeaders(direction: .request, operations: [.set(name: "X-Copy", value: "1")]))
        let flow = ExecuteFixtures.flow(requestHeaders: [HeaderField(name: "Accept", value: "*/*")])
        let result = try await ExecuteEngine.run(
            flow, snapshot: ExecuteFixtures.snapshot(edit), environment: ExecuteFixtures.environment())
        let request = try #require(result.overlay?.request)
        #expect(request.headers == [HeaderField(name: "Accept", value: "*/*"), HeaderField(name: "X-Copy", value: "1")])
        #expect(request.target == flow.messages[.downstreamRequest]?.target)
        #expect(result.matches?.outcomes == [RuleOutcome(ruleID: edit.id, code: .requestActionVisibleOnly)])
        #expect(result.overlay?.response == nil)
        #expect(result.notApplicableActions == 0)
    }

    @Test func executeRecordsSkippedKindsWithoutAnOverlay() async throws {
        let skipped = ExecuteFixtures.rule(
            "skip", rows: [Self.ok],
            .mapRemote(MapRemoteAction(targetScheme: "https", targetHost: "b.test", targetPort: 443, path: .preserve)))
        let result = try await ExecuteEngine.run(
            ExecuteFixtures.flow(), snapshot: ExecuteFixtures.snapshot(skipped), environment: ExecuteFixtures.environment())
        #expect(result.overlay == nil)
        #expect(result.matches?.outcomes == [RuleOutcome(ruleID: skipped.id, code: .requestActionSkippedAtResponse)])
    }
}

extension HTTPMessageHead {
    fileprivate var requestTarget: HTTPMessageTarget? {
        if case .request(let target, _) = self { return target }
        return nil
    }
}
