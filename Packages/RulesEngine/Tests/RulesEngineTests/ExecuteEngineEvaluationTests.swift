import FlowStore
import Foundation
import Testing

@testable import RulesEngine

// MARK: rows and actions

private func header(_ name: String, _ value: String) -> HeaderField { HeaderField(name: name, value: value) }
private func row(_ field: ConditionField, _ op: ConditionOperator = .equals, _ value: String, name: String? = nil)
    -> ConditionRow
{
    ConditionRow(field: field, name: name, op: op, value: value)
}
private let red = "#FF3B30"
private let markRed = ActionKind.mark(MarkAction(background: red))
private func setHeader(_ name: String, _ value: String, on direction: HTTPMessageDirection = .request) -> ActionKind {
    .editHeaders(direction: direction, operations: [.set(name: name, value: value)])
}
private func append(_ text: String) -> ActionKind { .comment(CommentAction(mode: .append, text: text)) }
private func mark(_ rule: Rule, _ background: String = red) -> FlowAnnotation {
    .mark(FlowMark(background: background, text: nil, source: .rule(id: rule.id, name: rule.name))!)
}
private func outcome(_ rule: Rule, _ code: RuleOutcomeCode, _ index: Int? = nil) -> RuleOutcome {
    RuleOutcome(ruleID: rule.id, code: code, actionIndex: index)
}
private func codes(_ evaluation: ExecuteEvaluation, of rule: Rule) -> [RuleOutcomeCode] {
    (evaluation.matches?.outcomes ?? []).filter { $0.ruleID == rule.id }.map(\.code)
}
private func headers(_ head: HTTPMessageHead?) -> [HeaderField] { head?.headers ?? [] }
private func status(_ head: HTTPMessageHead?) -> Int? {
    if case .response(let status, _, _)? = head { return status }
    return nil
}

private func evaluate(
    _ flow: Flow, _ snapshot: RuleSnapshot, environment: ExecuteEnvironment = ExecuteFixtures.environment()
) async throws -> ExecuteEvaluation {
    try await ExecuteEngine.evaluate(flow, snapshot: snapshot, environment: environment)
}

/// A clock whose reads the test scripts: every read returns the next value.
private final class ScriptedClock: @unchecked Sendable {  // guarded by `lock`
    private let lock = NSLock()
    private var values: [Duration]
    init(_ millis: [Int]) { values = millis.map { .milliseconds($0) } }
    func read() -> Duration { lock.withLock { values.isEmpty ? .seconds(1000) : values.removeFirst() } }
}

@Suite("ExecuteEngine evaluation")
struct ExecuteEngineEvaluationTests {
    // MARK: basics and skips

    @Test func inProgressFlowIsSkipped() async throws {
        let evaluation = try await evaluate(
            ExecuteFixtures.flow(state: .inProgress), ExecuteFixtures.snapshot(ExecuteFixtures.rule("m", markRed)))
        #expect(evaluation.skipped == .inProgress)
        #expect(evaluation.matches == nil)
        #expect(evaluation.annotations.isEmpty)
    }

    @Test func hiddenFlowIsSkipped() async throws {
        var flow = ExecuteFixtures.flow()
        flow.isHidden = true
        let evaluation = try await evaluate(flow, ExecuteFixtures.snapshot(ExecuteFixtures.rule("m", markRed)))
        #expect(evaluation.skipped == .hidden)
        #expect(evaluation.matches == nil)
        #expect(evaluation.annotations.isEmpty)
    }

    @Test func noRulesMeansNoRecords() async throws {
        let evaluation = try await evaluate(ExecuteFixtures.flow(), ExecuteFixtures.snapshot())
        #expect(evaluation.skipped == nil)
        #expect(evaluation.matches == nil)
        #expect(evaluation.annotations.isEmpty)
        #expect(evaluation.notApplicable == 0)
        #expect(evaluation.originals != nil)
    }

    // MARK: conditions read the message as the rules above left it

    @Test func laterRuleSeesEarlierHeaderEdit() async throws {
        let edit = ExecuteFixtures.rule("edit", setHeader("X-Stage", "two"))
        let reader = ExecuteFixtures.rule("reader", rows: [row(.requestHeader, .equals, "two", name: "X-Stage")], markRed)
        let evaluation = try await evaluate(
            ExecuteFixtures.flow(requestHeaders: [header("X-Stage", "one")]), ExecuteFixtures.snapshot(edit, reader))
        #expect(evaluation.annotations == [mark(reader)])
        let fields = headers(evaluation.request?.effectiveHead)
        #expect(fields.contains(header("X-Stage", "two")))
    }

    @Test func laterRuleSeesTheMovedHost() async throws {
        let move = ExecuteFixtures.rule(
            "move", .modifyURL(URLEditAction(mode: .findReplace, find: "a.test", replacement: "b.test")))
        let newHost = ExecuteFixtures.rule("new", rows: [row(.host, .equals, "b.test")], markRed)
        let oldHost = ExecuteFixtures.rule("old", rows: [row(.host, .equals, "a.test")], append("old"))
        let evaluation = try await evaluate(ExecuteFixtures.flow(), ExecuteFixtures.snapshot(move, newHost, oldHost))
        #expect(evaluation.annotations == [mark(newHost)])
        #expect(codes(evaluation, of: oldHost).isEmpty)
        #expect(evaluation.request?.carry?.target.host == "b.test")
    }

    @Test func statusRangeRuleReadsTheRewrittenStatus() async throws {
        let rewrite = ExecuteFixtures.rule("rewrite", .rewriteStatus(RewriteStatusAction(status: 404)))
        let range = ExecuteFixtures.rule(
            "range", rows: [row(.statusCode, .inRange, "400-499")], setHeader("X-Range", "1", on: .response))
        let evaluation = try await evaluate(ExecuteFixtures.flow(status: 200), ExecuteFixtures.snapshot(rewrite, range))
        #expect(status(evaluation.response?.effectiveHead) == 404)
        let fields = headers(evaluation.response?.effectiveHead)
        #expect(fields.contains(header("X-Range", "1")))
        #expect(codes(evaluation, of: range) == [.applied])
    }

    // MARK: points and final actions

    @Test func finalReturnFileCutsLowerRulesButHigherResponseRuleStillRuns() async throws {
        let assets = try await AssetFixture.make(Data("local body".utf8))
        defer { assets.remove() }
        let higher = ExecuteFixtures.rule(
            "A", rows: [row(.method, .equals, "GET")], setHeader("X-A", "1", on: .response))
        let file = ExecuteFixtures.rule(
            "B", .returnFile(MapLocalAction(assetID: assets.id, headers: [header("Content-Type", "text/plain")])))
        let lower = ExecuteFixtures.rule("C", setHeader("X-C", "1"))
        let evaluation = try await evaluate(
            ExecuteFixtures.flow(), ExecuteFixtures.snapshot(higher, file, lower),
            environment: ExecuteFixtures.environment(assets: assets.store))
        #expect(evaluation.local?.body == Data("local body".utf8))
        #expect(codes(evaluation, of: lower).isEmpty)
        #expect(evaluation.matches?.ruleIDs.contains(lower.id) == false)
        #expect(codes(evaluation, of: higher) == [.applied])
        let fields = headers(evaluation.response?.effectiveHead)
        #expect(fields.contains(header("X-A", "1")))
        let requestFields = headers(evaluation.request?.effectiveHead)
        #expect(!requestFields.contains(header("X-C", "1")))
    }

    @Test func localResponseGoesThroughP2WithIsLocalResponse() async throws {
        let preset = ExecuteFixtures.rule("preset", .returnPreset(PresetResponse(preset: .emptyHTML200)))
        let plain = ExecuteFixtures.rule("plain", .rewriteStatus(RewriteStatusAction(status: 503)))
        let skipped = try await evaluate(ExecuteFixtures.flow(), ExecuteFixtures.snapshot(plain, preset))
        #expect(codes(skipped, of: plain) == [.statusSkippedLocal])
        #expect(status(skipped.response?.effectiveHead) == 200)

        let opted = ExecuteFixtures.rule(
            "opted", .rewriteStatus(RewriteStatusAction(status: 503, includeLocalResponses: true)))
        let rewritten = try await evaluate(ExecuteFixtures.flow(), ExecuteFixtures.snapshot(opted, preset))
        #expect(codes(rewritten, of: opted) == [.applied])
        #expect(status(rewritten.response?.effectiveHead) == 503)
        #expect(rewritten.local?.status == 200)
    }

    /// A rule judged at the response answers in place of the captured one: a rule judged at completion reads the answer.
    @Test func completionRulesReadTheResponsePointReplacement() async throws {
        let seen = ExecuteFixtures.rule(
            "seen", rows: [row(.statusCode, .equals, "403"), row(.durationMs, .greaterOrEqual, "0")], markRed)
        let answer = ExecuteFixtures.rule(
            "answer", rows: [row(.statusCode, .equals, "200")], .returnPreset(PresetResponse(preset: .forbidden403)))
        let evaluation = try await evaluate(ExecuteFixtures.flow(status: 200), ExecuteFixtures.snapshot(seen, answer))
        #expect(evaluation.local?.status == 403)
        #expect(codes(evaluation, of: seen).contains(.applied))
    }

    @Test func handwrittenAndPresetBecomeLocalResponses() async throws {
        let handwritten = ExecuteFixtures.rule(
            "hand", .returnHandwritten(HandwrittenResponse(text: "HTTP/1.1 418 Teapot\r\nX-Hand: 1\r\n\r\nshort")))
        let fromHand = try await evaluate(ExecuteFixtures.flow(), ExecuteFixtures.snapshot(handwritten))
        #expect(fromHand.local?.status == 418)
        #expect(fromHand.local?.reason == "Teapot")
        #expect(fromHand.local?.body == Data("short".utf8))
        #expect(fromHand.local?.headers.contains(header("X-Hand", "1")) == true)
        #expect(fromHand.local?.headers.contains(header("Content-Length", "5")) == true)
        #expect(status(fromHand.response?.effectiveHead) == 418)

        let preset = ExecuteFixtures.rule("preset", .returnPreset(PresetResponse(preset: .notFound404)))
        let fromPreset = try await evaluate(ExecuteFixtures.flow(status: 200), ExecuteFixtures.snapshot(preset))
        #expect(fromPreset.local?.status == 404)
        #expect(status(fromPreset.response?.effectiveHead) == 404)
    }

    @Test func closeRouteHasNoResponsePointButCompletionRuns() async throws {
        let failing = ExecuteFixtures.rule("failing", rows: [row(.sessionState, .equals, "failed")], markRed)
        let close = ExecuteFixtures.rule("close", .closeConnection(.reset))
        let response = ExecuteFixtures.rule("response", setHeader("X-R", "1", on: .response))
        let evaluation = try await evaluate(
            ExecuteFixtures.flow(state: .failed("closed")), ExecuteFixtures.snapshot(failing, close, response))
        #expect(evaluation.response == nil)
        #expect(evaluation.local == nil)
        #expect(evaluation.annotations == [mark(failing)])
        #expect(codes(evaluation, of: close) == [.notApplicableOffline, .finalStop])
        #expect(codes(evaluation, of: response).isEmpty)
    }

    @Test func notApplicableFinalStillCutsLowerRules() async throws {
        let close = ExecuteFixtures.rule("close", .closeConnection(.graceful))
        let lower = ExecuteFixtures.rule("lower", markRed)
        let evaluation = try await evaluate(ExecuteFixtures.flow(), ExecuteFixtures.snapshot(close, lower))
        #expect(codes(evaluation, of: close) == [.notApplicableOffline, .finalStop])
        #expect(codes(evaluation, of: lower).isEmpty)
        #expect(evaluation.annotations.isEmpty)
        #expect(evaluation.notApplicable == 1)
    }

    @Test func breakpointAndDelayAreNotApplicableAndNotFinal() async throws {
        let breakpoint = ExecuteFixtures.rule("bp", .breakpoint(direction: .request, mode: .headers))
        let delay = ExecuteFixtures.rule("delay", .delay(milliseconds: 500))
        let responseBreakpoint = ExecuteFixtures.rule("rbp", .breakpoint(direction: .response, mode: .fullBody))
        let lower = ExecuteFixtures.rule("lower", markRed)
        let evaluation = try await evaluate(
            ExecuteFixtures.flow(), ExecuteFixtures.snapshot(breakpoint, delay, responseBreakpoint, lower))
        #expect(codes(evaluation, of: breakpoint) == [.notApplicableOffline])
        #expect(codes(evaluation, of: delay) == [.notApplicableOffline])
        #expect(codes(evaluation, of: responseBreakpoint) == [.notApplicableOffline])
        #expect(evaluation.annotations == [mark(lower)])
        #expect(evaluation.notApplicable == 3)
        #expect(evaluation.request?.breakpoint == nil)
        #expect(evaluation.response?.breakpoint == nil)
    }

    @Test func completionRulesReadRealDurationSizeAndState() async throws {
        let slow = ExecuteFixtures.rule("slow", rows: [row(.durationMs, .greaterThan, "100")], markRed)
        let fast = ExecuteFixtures.rule("fast", rows: [row(.durationMs, .lessThan, "100")], append("fast"))
        let completed = ExecuteFixtures.rule("done", rows: [row(.sessionState, .equals, "completed")], append("done"))
        var flow = ExecuteFixtures.flow()
        flow.completedAt = ExecuteFixtures.epoch.addingTimeInterval(0.25)
        let evaluation = try await evaluate(flow, ExecuteFixtures.snapshot(slow, fast, completed))
        #expect(evaluation.annotations == [mark(slow), .comment(CommentAction(mode: .append, text: "done"))])
        #expect(evaluation.originals?.completion.durationMilliseconds == 250)

        var quick = ExecuteFixtures.flow()
        quick.completedAt = ExecuteFixtures.epoch.addingTimeInterval(0.05)
        let second = try await evaluate(quick, ExecuteFixtures.snapshot(slow, fast))
        #expect(second.annotations == [.comment(CommentAction(mode: .append, text: "fast"))])

        // The response size is what came over the wire (`bytesReceived`), only when the origin answered.
        let big = ExecuteFixtures.rule("big", rows: [row(.responseBodySize, .greaterThan, "400")], markRed)
        var sized = ExecuteFixtures.flow()
        sized.bytesReceived = 500
        let third = try await evaluate(sized, ExecuteFixtures.snapshot(big))
        #expect(third.annotations == [mark(big)])
        sized.bytesReceived = 300
        let fourth = try await evaluate(sized, ExecuteFixtures.snapshot(big))
        #expect(fourth.annotations.isEmpty)
        #expect(fourth.originals?.completion.responseWireBytes == 300)
    }

    @Test func completionSeesCommentsFromEarlierPoints() async throws {
        let p1 = ExecuteFixtures.rule("p1", append("one"))
        let p2 = ExecuteFixtures.rule("p2", rows: [row(.statusCode, .equals, "200")], append("two"))
        let p3 = ExecuteFixtures.rule(
            "p3", rows: [row(.durationMs, .greaterOrEqual, "0"), row(.comment, .equals, "base one two")], markRed)
        let evaluation = try await evaluate(ExecuteFixtures.flow(comment: "base"), ExecuteFixtures.snapshot(p1, p2, p3))
        #expect(evaluation.annotations.last == mark(p3))
        #expect(codes(evaluation, of: p3) == [.applied])
    }

    @Test func rejectedRequestSkipsP2AndStillRunsCompletion() async throws {
        let bad = ExecuteFixtures.rule("bad", .modifyURL(URLEditAction(mode: .set, replacement: "ftp://b.test/p")))
        let response = ExecuteFixtures.rule("response", rows: [row(.statusCode, .equals, "200")], markRed)
        let done = ExecuteFixtures.rule("done", rows: [row(.durationMs, .greaterOrEqual, "0")], append("done"))
        let evaluation = try await evaluate(ExecuteFixtures.flow(), ExecuteFixtures.snapshot(bad, response, done))
        #expect(evaluation.request == nil)
        #expect(evaluation.response == nil)
        #expect(codes(evaluation, of: bad) == [.rejected])
        #expect(codes(evaluation, of: response).isEmpty)
        #expect(evaluation.annotations == [.comment(CommentAction(mode: .append, text: "done"))])
    }

    @Test func tunnelRowsOnlyAnnotate() async throws {
        // A row the tools tunnelled (no rule decided it live): connect-only actions are skipped by the tool and
        // cut nothing, exactly as live, so the lower annotation still applies.
        let marking = ExecuteFixtures.rule("mark", markRed)
        let commenting = ExecuteFixtures.rule("comment", append("tunnel"))
        let noDecrypt = ExecuteFixtures.rule("noDecrypt", rows: [row(.host, .equals, "t.test")], .noDecrypt)
        let lower = ExecuteFixtures.rule("lower", append("lower"))
        let request = ExecuteFixtures.rule("request", setHeader("X-R", "1"))
        let snapshot = ExecuteFixtures.snapshot(marking, commenting, noDecrypt, lower, request)
        let evaluation = try await evaluate(ExecuteFixtures.tunnel(7, host: "t.test"), snapshot)
        #expect(
            evaluation.annotations == [
                mark(marking), .comment(CommentAction(mode: .append, text: "tunnel")),
                .comment(CommentAction(mode: .append, text: "lower")),
            ])
        #expect(codes(evaluation, of: noDecrypt) == [.skippedByTool])
        #expect(codes(evaluation, of: lower) == [.applied])
        #expect(codes(evaluation, of: request).isEmpty)
        #expect(evaluation.request == nil)
        #expect(evaluation.response == nil)
        #expect(evaluation.local == nil)
        #expect(evaluation.notApplicable == 0)

        let hiding = try await evaluate(
            ExecuteFixtures.tunnel(8, host: "t.test"), ExecuteFixtures.snapshot(ExecuteFixtures.rule("hide", .hide)))
        #expect(hiding.annotations == [.hide])
    }

    @Test func tunnelRowARuleDecidedReRunsTheRuleAsFinal() async throws {
        // Live, the no-decrypt rule made this row a tunnel: it fires again, is not applicable offline, and cuts.
        let noDecrypt = ExecuteFixtures.rule("noDecrypt", rows: [row(.host, .equals, "t.test")], .noDecrypt)
        let lower = ExecuteFixtures.rule("lower", append("lower"))
        var tunnel = ExecuteFixtures.tunnel(9, host: "t.test")
        tunnel.provenance.ruleMatches = RuleMatchSummary(
            revision: 1, ruleIDs: [noDecrypt.id], total: 1, outcomes: [outcome(noDecrypt, .applied)])
        let evaluation = try await evaluate(tunnel, ExecuteFixtures.snapshot(noDecrypt, lower))
        #expect(codes(evaluation, of: noDecrypt) == [.notApplicableOffline, .finalStop])
        #expect(codes(evaluation, of: lower).isEmpty)
        #expect(evaluation.annotations.isEmpty)
        #expect(evaluation.notApplicable == 1)
        #expect(ExecuteEngine.connectTool(of: tunnel, rules: [noDecrypt, lower]) == .decrypt)
        // Outcomes that did not decide the tunnel (a mark) leave the tools' decision.
        var marked = ExecuteFixtures.tunnel(10, host: "t.test")
        marked.provenance.ruleMatches = RuleMatchSummary(
            revision: 1, ruleIDs: [lower.id], total: 1, outcomes: [outcome(lower, .applied)])
        #expect(ExecuteEngine.connectTool(of: marked, rules: [noDecrypt, lower]) == .tunnel)
    }

    @Test func failedConnectRowRunsTheConnectPointOnly() async throws {
        // The row live records when a rule closed a CONNECT: failed, method CONNECT, no response.
        let close = ExecuteFixtures.rule("close", rows: [row(.host, .equals, "c.test")], .closeConnection(.reset))
        let marking = ExecuteFixtures.rule("mark", markRed)
        let request = ExecuteFixtures.rule("request", setHeader("X-R", "1"))
        var connectRow = ExecuteFixtures.flow(method: "CONNECT", host: "c.test", path: "", status: nil, state: .failed("closed"))
        connectRow.provenance.ruleMatches = RuleMatchSummary(
            revision: 1, ruleIDs: [close.id], total: 1, outcomes: [outcome(close, .applied)])
        let evaluation = try await evaluate(connectRow, ExecuteFixtures.snapshot(marking, close, request))
        #expect(evaluation.request == nil)
        #expect(evaluation.response == nil)
        #expect(evaluation.annotations == [mark(marking)])
        #expect(codes(evaluation, of: close) == [.notApplicableOffline])
        #expect(codes(evaluation, of: request).isEmpty)
    }

    @Test func noHitsAreCountedAndOccurrenceIsIgnored() async throws {
        var counted = ExecuteFixtures.rule("counted", markRed)
        counted.conditions.occurrence = .times(2...3)
        let evaluation = try await evaluate(ExecuteFixtures.flow(), ExecuteFixtures.snapshot(counted))
        #expect(evaluation.annotations == [mark(counted)])
        #expect(!codes(evaluation, of: counted).contains(.occurrenceSkipped))
    }

    @Test func sharedAllowanceBoundsRegexTimeAcrossPoints() async throws {
        let early = ExecuteFixtures.rule("early", rows: [row(.url, .regex, "a\\.test")], markRed)
        let late = ExecuteFixtures.rule(
            "late", rows: [row(.statusCode, .equals, "200"), row(.host, .regex, "a")], append("late"))
        var environment = ExecuteFixtures.environment()
        // The first regular expression uses 5 ms of a 4 ms allowance; the response point has nothing left.
        environment.makeAllowance = {
            let clock = ScriptedClock([0, 5])
            return RegexAllowance(total: .milliseconds(4), clock: { clock.read() })
        }
        let evaluation = try await evaluate(ExecuteFixtures.flow(), ExecuteFixtures.snapshot(early, late), environment: environment)
        #expect(evaluation.annotations == [mark(early)])
        #expect(codes(evaluation, of: late) == [.patternTimedOut])
    }

    @Test func requestBodyConditionReadsSpilledBody() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("execute-body-\(UUID().uuidString).txt")
        try Data("needle in body".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        var flow = ExecuteFixtures.flow(method: "POST", requestHeaders: [header("Content-Type", "text/plain")])
        let spilled = BodyRef.file(url, size: 14)
        flow.messages[.downstreamRequest]?.body = HTTPBodySlice(ref: spilled, offset: 0, count: 14)
        let reader = ExecuteFixtures.rule("reader", rows: [row(.requestBody, .contains, "needle")], markRed)
        let evaluation = try await evaluate(flow, ExecuteFixtures.snapshot(reader))
        #expect(evaluation.annotations == [mark(reader)])
    }

    @Test func bodyPeekIsSkippedWhenNoRuleReadsBodies() async throws {
        // A body that cannot be read: peeking it would leave `bodySkippedUnavailable` in the carry.
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("execute-missing-\(UUID().uuidString)")
        var flow = ExecuteFixtures.flow(method: "POST", requestHeaders: [header("Content-Type", "text/plain")])
        flow.messages[.downstreamRequest]?.body = HTTPBodySlice(ref: .file(missing, size: 4), offset: 0, count: 4)
        flow.messages[.upstreamResponse]?.body = HTTPBodySlice(ref: .file(missing, size: 4), offset: 0, count: 4)
        let edit = ExecuteFixtures.rule("edit", setHeader("X-E", "1"))
        let snapshot = ExecuteFixtures.snapshot(edit)
        #expect(!snapshot.requirements.requestBody && !snapshot.requirements.responseBody)
        let evaluation = try await evaluate(flow, snapshot)
        #expect(evaluation.request?.carry?.requestBody == .notCollected)
        #expect(evaluation.response?.carry.body == .notCollected)

        // Contrast: a rule that reads the body makes Execute try it.
        let reader = ExecuteFixtures.rule("reader", rows: [row(.requestBody, .contains, "x")], markRed)
        let peeked = try await evaluate(flow, ExecuteFixtures.snapshot(edit, reader))
        #expect(peeked.request?.carry?.requestBody == .skipped(.bodySkippedUnavailable))
    }

    @Test func baselineCommentFeedsTheCommentCondition() async throws {
        let reader = ExecuteFixtures.rule("reader", rows: [row(.comment, .equals, "mine")], markRed)
        let evaluation = try await evaluate(ExecuteFixtures.flow(comment: "mine"), ExecuteFixtures.snapshot(reader))
        #expect(evaluation.annotations == [mark(reader)])

        // After an earlier Execute wrote "mine x", the comment the rules read is the baseline again.
        var executed = ExecuteFixtures.flow(comment: "mine x")
        executed.execute = ExecuteRecord(
            runID: UUID(), executedAt: ExecuteFixtures.epoch, matches: RuleMatchSummary(revision: 1, ruleIDs: [], total: 0),
            baseline: ExecuteFieldValues(comment: "mine"), written: ExecuteFieldValues(comment: "mine x"))
        let again = try await evaluate(executed, ExecuteFixtures.snapshot(reader))
        #expect(again.annotations == [mark(reader)])
    }
}
