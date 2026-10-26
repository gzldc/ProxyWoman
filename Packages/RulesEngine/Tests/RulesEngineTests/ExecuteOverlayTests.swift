import FlowStore
import Foundation
import Testing

@testable import RulesEngine

// MARK: helpers

private func header(_ name: String, _ value: String) -> HeaderField { HeaderField(name: name, value: value) }
private let markRed = ActionKind.mark(MarkAction(background: "#FF3B30"))
private func setHeader(_ name: String, _ value: String, on direction: HTTPMessageDirection = .request) -> ActionKind {
    .editHeaders(direction: direction, operations: [.set(name: name, value: value)])
}
private func replaceBody(_ find: String, _ replacement: String, on direction: HTTPMessageDirection) -> ActionKind {
    .rewriteBody(direction: direction, BodyRewriteAction(find: find, replacement: replacement))
}
private func codes(_ matches: RuleMatchSummary?, of rule: Rule) -> [RuleOutcomeCode] {
    (matches?.outcomes ?? []).filter { $0.ruleID == rule.id }.map(\.code)
}
private func target(_ snapshot: HTTPMessageSnapshot?) -> HTTPMessageTarget? { snapshot?.target }
private func reason(_ snapshot: HTTPMessageSnapshot?) -> String? {
    if case .response(_, let reason, _)? = snapshot?.head { return reason }
    return nil
}
private func body(_ snapshot: HTTPMessageSnapshot?) throws -> Data? { try snapshot?.body?.load() }
private func text(_ string: String) -> Data { Data(string.utf8) }
private let gzippedHello = Data(base64Encoded: "H4sIAAAAAAAC/8tIzcnJBwCGphA2BQAAAA==")!

/// Counts the bodies the builder asks the store for.
private final class BodyCounter: @unchecked Sendable {  // guarded by `lock`
    private let lock = NSLock()
    private var made = 0
    var count: Int { lock.withLock { made } }
    func make(_ data: Data) -> BodyRef {
        lock.withLock { made += 1 }
        return .memory(data)
    }
}

private func environment(
    assets: ManagedAssetStore? = nil, limits: RulesLimits = RulesLimits(), counter: BodyCounter? = nil
) -> ExecuteEnvironment {
    var environment = ExecuteFixtures.environment(assets: assets, limits: limits)
    if let counter { environment.makeBody = { counter.make($0) } }
    return environment
}

private func run(_ flow: Flow, _ snapshot: RuleSnapshot, environment: ExecuteEnvironment = environment())
    async throws -> ExecuteFlowResult
{
    try await ExecuteEngine.run(flow, snapshot: snapshot, environment: environment)
}

private func build(_ flow: Flow, _ snapshot: RuleSnapshot, environment: ExecuteEnvironment = environment())
    async throws -> ExecuteOverlayBuilder.Built
{
    let evaluation = try await ExecuteEngine.evaluate(flow, snapshot: snapshot, environment: environment)
    return try await ExecuteOverlayBuilder.build(evaluation, snapshot: snapshot, environment: environment)
}

private func temporaryFile(_ data: Data) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("execute-overlay-\(UUID().uuidString)")
    try data.write(to: url)
    return url
}

@Suite("Execute overlay")
struct ExecuteOverlayTests {
    // MARK: request side

    @Test func headerEditShowsInTheOverlayRequest() async throws {
        let flow = ExecuteFixtures.flow(requestHeaders: [header("Accept", "*/*")], responseBody: text("ok"))
        let edit = ExecuteFixtures.rule("edit", setHeader("X-E", "1"))
        let result = try await run(flow, ExecuteFixtures.snapshot(edit))
        let request = try #require(result.overlay?.request)
        #expect(request.boundary == .upstreamRequest)
        #expect(request.headers == [header("Accept", "*/*"), header("X-E", "1")])
        #expect(request.target == flow.messages[.downstreamRequest]?.target)
        #expect(request.transferState == .finished)
        #expect(request.wireVersion == nil)
        #expect(request.bodyState == .complete)
        #expect(result.overlay?.response == nil)
        #expect(codes(result.matches, of: edit) == [.applied])
    }

    @Test func modifyURLMovesTheTargetAndSanitisesHeaders() async throws {
        let flow = ExecuteFixtures.flow(requestHeaders: [
            header("Host", "a.test"), header("Cookie", "c=1"), header("Authorization", "Bearer t"),
            header("Accept", "x"),
        ])
        let move = ExecuteFixtures.rule(
            "move", .modifyURL(URLEditAction(mode: .findReplace, find: "a.test", replacement: "b.test")))
        let moved = try #require(try await run(flow, ExecuteFixtures.snapshot(move)).overlay?.request)
        #expect(target(moved)?.host == "b.test")
        #expect(target(moved)?.pathAndQuery == "/")
        #expect(moved.headers == [header("Accept", "x")])

        let keeping = ExecuteFixtures.rule(
            "keep",
            .modifyURL(
                URLEditAction(mode: .findReplace, find: "a.test", replacement: "b.test", preserveCredentials: true)))
        let kept = try #require(try await run(flow, ExecuteFixtures.snapshot(keeping)).overlay?.request)
        #expect(target(kept)?.host == "b.test")
        #expect(kept.headers == [header("Cookie", "c=1"), header("Authorization", "Bearer t"), header("Accept", "x")])
    }

    @Test func requestBodyRewriteProducesManagedBodyWithFixedLength() async throws {
        let flow = ExecuteFixtures.flow(
            method: "POST",
            requestHeaders: [
                header("Content-Type", "text/plain"), header("Content-Encoding", "gzip"),
                header("Content-Length", "\(gzippedHello.count)"), header("Digest", "sha-256=x"),
            ],
            requestBody: gzippedHello)
        let rewrite = ExecuteFixtures.rule("rewrite", replaceBody("hello", "goodbye!", on: .request))
        let counter = BodyCounter()
        let result = try await run(flow, ExecuteFixtures.snapshot(rewrite), environment: environment(counter: counter))
        let request = try #require(result.overlay?.request)
        #expect(request.headers == [header("Content-Type", "text/plain"), header("Content-Length", "8")])
        #expect(try body(request) == text("goodbye!"))
        #expect(request.bodyState == .complete)
        #expect(request.observedBytes == 8)
        #expect(counter.count == 1)
        #expect(codes(result.matches, of: rewrite) == [.applied])
    }

    @Test func unchangedRequestHasNoRequestOverlay() async throws {
        let flow = ExecuteFixtures.flow(requestHeaders: [header("X-E", "1")])
        let same = ExecuteFixtures.rule("same", setHeader("X-E", "1"))
        let marker = ExecuteFixtures.rule("mark", markRed)
        let result = try await run(flow, ExecuteFixtures.snapshot(same, marker))
        #expect(result.overlay == nil)
        #expect(codes(result.matches, of: marker) == [.applied])
    }

    @Test func localRouteDoesNotSanitiseOrMoveTheRequest() async throws {
        let flow = ExecuteFixtures.flow(requestHeaders: [header("Host", "a.test"), header("Cookie", "c=1")])
        let move = ExecuteFixtures.rule(
            "move", .modifyURL(URLEditAction(mode: .findReplace, find: "a.test", replacement: "b.test")),
            setHeader("X-E", "1"))
        let preset = ExecuteFixtures.rule("preset", .returnPreset(PresetResponse(preset: .notFound404)))
        let result = try await run(flow, ExecuteFixtures.snapshot(move, preset))
        let request = try #require(result.overlay?.request)
        #expect(request.target == flow.messages[.downstreamRequest]?.target)
        #expect(request.headers == [header("Host", "a.test"), header("Cookie", "c=1"), header("X-E", "1")])
        #expect(result.overlay?.response?.status == 404)
    }

    // MARK: response side

    @Test func statusRewriteFillsTheReason() async throws {
        let notFound = ExecuteFixtures.rule("404", .rewriteStatus(RewriteStatusAction(status: 404)))
        let response = try #require(try await run(ExecuteFixtures.flow(), ExecuteFixtures.snapshot(notFound)).overlay?.response)
        #expect(response.boundary == .downstreamResponse)
        #expect(response.status == 404)
        #expect(reason(response) == "Not Found")
        #expect(try await run(ExecuteFixtures.flow(), ExecuteFixtures.snapshot(notFound)).overlay?.responseIsLocal == false)

        let unusual = ExecuteFixtures.rule("299", .rewriteStatus(RewriteStatusAction(status: 299)))
        let odd = try #require(try await run(ExecuteFixtures.flow(), ExecuteFixtures.snapshot(unusual)).overlay?.response)
        #expect(odd.status == 299)
        #expect(reason(odd) == "")
    }

    @Test func responseHeaderEditKeepsTheOriginalBodySlice() async throws {
        let flow = ExecuteFixtures.flow(responseHeaders: [header("Content-Type", "text/plain")], responseBody: text("abc"))
        let edit = ExecuteFixtures.rule("edit", setHeader("X-R", "1", on: .response))
        let counter = BodyCounter()
        let result = try await run(flow, ExecuteFixtures.snapshot(edit), environment: environment(counter: counter))
        let response = try #require(result.overlay?.response)
        #expect(response.headers == [header("Content-Type", "text/plain"), header("X-R", "1")])
        #expect(response.body == flow.messages[.upstreamResponse]?.body)
        #expect(response.observedBytes == 3)
        #expect(counter.count == 0)
        #expect(result.overlay?.request == nil)
    }

    @Test func responseBodyRewriteReplacesTheBody() async throws {
        let flow = ExecuteFixtures.flow(
            responseHeaders: [header("Content-Type", "text/html"), header("ETag", "\"x\""), header("Content-Length", "5")],
            responseBody: text("hello"))
        let rewrite = ExecuteFixtures.rule("rewrite", replaceBody("hello", "bye", on: .response))
        let result = try await run(flow, ExecuteFixtures.snapshot(rewrite))
        let response = try #require(result.overlay?.response)
        #expect(response.headers == [header("Content-Type", "text/html"), header("Content-Length", "3")])
        #expect(try body(response) == text("bye"))
        #expect(response.observedBytes == 3)
        #expect(response.bodyState == .complete)
        #expect(codes(result.matches, of: rewrite) == [.applied])
    }

    @Test func localResponseReplacesTheWholeResponse() async throws {
        let assets = try await AssetFixture.make(text("file body"))
        defer { assets.remove() }
        let flow = ExecuteFixtures.flow(responseHeaders: [header("Server", "origin")], responseBody: text("origin"))

        let file = ExecuteFixtures.rule(
            "file", .returnFile(MapLocalAction(assetID: assets.id, headers: [header("Content-Type", "text/plain")])))
        let served = try #require(
            try await run(flow, ExecuteFixtures.snapshot(file), environment: environment(assets: assets.store))
                .overlay?.response)
        #expect(served.status == 200)
        #expect(reason(served) == "OK")
        #expect(served.headers == [header("Content-Type", "text/plain"), header("Content-Length", "9")])
        #expect(try body(served) == text("file body"))

        let hand = ExecuteFixtures.rule(
            "hand", .returnHandwritten(HandwrittenResponse(text: "HTTP/1.1 418 Teapot\r\nX-Hand: 1\r\n\r\nshort")))
        let written = try #require(try await run(flow, ExecuteFixtures.snapshot(hand)).overlay?.response)
        #expect(written.status == 418)
        #expect(reason(written) == "Teapot")
        #expect(written.headers.contains(header("X-Hand", "1")))
        #expect(!written.headers.contains(header("Server", "origin")))
        #expect(try body(written) == text("short"))

        let preset = ExecuteFixtures.rule("preset", .returnPreset(PresetResponse(preset: .notFound404)))
        let snapshot = ExecuteFixtures.snapshot(preset)
        let evaluation = try await ExecuteEngine.evaluate(flow, snapshot: snapshot, environment: environment())
        let local = try #require(evaluation.local)
        let canned = try #require(try await run(flow, snapshot).overlay?.response)
        #expect(canned.status == 404)
        #expect(canned.headers == local.headers)
        #expect((try body(canned) ?? Data()) == local.body)
        #expect(try await run(flow, snapshot).overlay?.responseIsLocal == true)
        #expect(try await run(flow, ExecuteFixtures.snapshot(hand)).overlay?.responseIsLocal == true)
    }

    @Test func responseOverlayAfterLocalResponseCarriesHigherRulesEdits() async throws {
        let higher = ExecuteFixtures.rule("higher", setHeader("X-A", "1", on: .response))
        let preset = ExecuteFixtures.rule("preset", .returnPreset(PresetResponse(preset: .notFound404)))
        let snapshot = ExecuteFixtures.snapshot(higher, preset)
        let evaluation = try await ExecuteEngine.evaluate(ExecuteFixtures.flow(), snapshot: snapshot, environment: environment())
        let local = try #require(evaluation.local)
        let response = try #require(try await run(ExecuteFixtures.flow(), snapshot).overlay?.response)
        #expect(response.status == 404)
        // Live frames a local response last (`Content-Length` after the rules' edits), so Execute does the same.
        let framing = local.headers.filter { $0.name.lowercased() == "content-length" }
        #expect(!framing.isEmpty)
        #expect(response.headers == local.headers.filter { $0.name.lowercased() != "content-length" } + [header("X-A", "1")] + framing)
        #expect((try body(response) ?? Data()) == local.body)
    }

    @Test func localResponseGetsTheRealContentLengthAsLiveFramesIt() async throws {
        // The rule's own text claims a wrong length; live frames it with the real length.
        let hand = ExecuteFixtures.rule(
            "hand",
            .returnHandwritten(HandwrittenResponse(
                text: "HTTP/1.1 200 OK\r\nContent-Length: 99\r\nX-Hand: 1\r\n\r\nshort")))
        let response = try #require(try await run(ExecuteFixtures.flow(), ExecuteFixtures.snapshot(hand)).overlay?.response)
        #expect(response.headers.filter { $0.name.lowercased() == "content-length" } == [header("Content-Length", "5")])
        #expect(response.headers.last == header("Content-Length", "5"))
        #expect(!response.headers.contains { $0.name.lowercased() == "transfer-encoding" })

        let noContent = ExecuteFixtures.rule(
            "none", .returnHandwritten(HandwrittenResponse(text: "HTTP/1.1 204 No Content\r\nX-Hand: 1\r\n\r\n")))
        let empty = try #require(
            try await run(ExecuteFixtures.flow(), ExecuteFixtures.snapshot(noContent)).overlay?.response)
        #expect(!empty.headers.contains { $0.name.lowercased() == "content-length" })
    }

    @Test func unchangedResponseHasNoResponseOverlay() async throws {
        let flow = ExecuteFixtures.flow(
            responseHeaders: [header("Content-Type", "text/plain"), header("X-R", "1")], responseBody: text("hello"))
        let same = ExecuteFixtures.rule("same", setHeader("X-R", "1", on: .response))
        let miss = ExecuteFixtures.rule("miss", replaceBody("absent", "x", on: .response))
        let result = try await run(flow, ExecuteFixtures.snapshot(same, miss))
        #expect(result.overlay == nil)
        #expect(codes(result.matches, of: miss) == [.bodyNoMatch])
    }

    @Test func noResponseAndNoLocalRouteMeansNoResponseOverlay() async throws {
        let flow = ExecuteFixtures.flow(status: nil)
        let response = ExecuteFixtures.rule("response", setHeader("X-R", "1", on: .response))
        let request = ExecuteFixtures.rule("request", setHeader("X-E", "1"))
        let result = try await run(flow, ExecuteFixtures.snapshot(response, request))
        #expect(result.overlay?.response == nil)
        #expect(result.overlay?.request?.headers == [header("X-E", "1")])
    }

    @Test func failedFlowWithGeneratedResponseGetsAnOverlayResponse() async throws {
        let flow = ExecuteFixtures.flow(status: nil, state: .failed("connection refused"))
        let preset = ExecuteFixtures.rule("preset", .returnPreset(PresetResponse(preset: .notFound404)))
        let result = try await run(flow, ExecuteFixtures.snapshot(preset))
        let response = try #require(result.overlay?.response)
        #expect(response.status == 404)
        #expect(reason(response) == "Not Found")
        #expect(result.overlay?.request == nil)
    }

    // MARK: body boundaries

    @Test func truncatedRecordedBodyIsNotRewritten() async throws {
        var flow = ExecuteFixtures.flow(responseHeaders: [header("Content-Type", "text/plain")], responseBody: text("hello"))
        flow.messages[.upstreamResponse]?.bodyState = .truncated
        let rewrite = ExecuteFixtures.rule("rewrite", replaceBody("hello", "bye", on: .response))
        let counter = BodyCounter()
        let result = try await run(flow, ExecuteFixtures.snapshot(rewrite), environment: environment(counter: counter))
        #expect(result.overlay == nil)
        #expect(codes(result.matches, of: rewrite) == [.bodySkippedTooLarge])
        #expect(counter.count == 0)
    }

    @Test func overCapBodyIsNotRead() async throws {
        // A body that cannot be read: reading it would say `bodySkippedUnavailable`.
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("execute-missing-\(UUID().uuidString)")
        var flow = ExecuteFixtures.flow(responseHeaders: [header("Content-Type", "text/plain")])
        flow.messages[.upstreamResponse]?.body = HTTPBodySlice(ref: .file(missing, size: 100), offset: 0, count: 100)
        let rewrite = ExecuteFixtures.rule("rewrite", replaceBody("hello", "bye", on: .response))
        let limits = RulesLimits(rewriteBodyBytes: 8)
        let result = try await run(flow, ExecuteFixtures.snapshot(rewrite), environment: environment(limits: limits))
        #expect(result.overlay == nil)
        #expect(codes(result.matches, of: rewrite) == [.bodySkippedTooLarge])

        // Contrast: under the cap the same body is read, and cannot be.
        let roomy = try await run(flow, ExecuteFixtures.snapshot(rewrite))
        #expect(codes(roomy.matches, of: rewrite) == [.bodySkippedUnavailable])
    }

    @Test func spilledBodyIsReadAndRewritten() async throws {
        let url = try temporaryFile(text("hello world"))
        defer { try? FileManager.default.removeItem(at: url) }
        var flow = ExecuteFixtures.flow(responseHeaders: [header("Content-Type", "text/plain")])
        flow.messages[.upstreamResponse]?.body = HTTPBodySlice(ref: .file(url, size: 11), offset: 0, count: 11)
        let rewrite = ExecuteFixtures.rule("rewrite", replaceBody("hello", "bye", on: .response))
        let result = try await run(flow, ExecuteFixtures.snapshot(rewrite))
        #expect(try body(result.overlay?.response) == text("bye world"))
        #expect(codes(result.matches, of: rewrite) == [.applied])
    }

    @Test func binaryBodyIsSkippedNotText() async throws {
        let flow = ExecuteFixtures.flow(responseHeaders: [header("Content-Type", "image/png")], responseBody: text("hello"))
        let rewrite = ExecuteFixtures.rule("rewrite", replaceBody("hello", "bye", on: .response))
        let counter = BodyCounter()
        let result = try await run(flow, ExecuteFixtures.snapshot(rewrite), environment: environment(counter: counter))
        #expect(result.overlay == nil)
        #expect(codes(result.matches, of: rewrite) == [.bodySkippedNotText])
        #expect(counter.count == 0)
    }

    @Test func rewriteOutcomesReplaceTheProvisionalApplied() async throws {
        let flow = ExecuteFixtures.flow(
            method: "POST", requestHeaders: [header("Content-Type", "text/plain")], requestBody: text("hello"),
            responseHeaders: [header("Content-Type", "text/plain")], responseBody: text("hello"))
        let request = ExecuteFixtures.rule("request", replaceBody("absent", "x", on: .request))
        let response = ExecuteFixtures.rule("response", replaceBody("hello", "bye", on: .response))
        let snapshot = ExecuteFixtures.snapshot(request, response)
        let evaluation = try await ExecuteEngine.evaluate(flow, snapshot: snapshot, environment: environment())
        #expect(codes(evaluation.matches, of: request) == [.applied])
        #expect(codes(evaluation.matches, of: response) == [.applied])
        let built = try await ExecuteOverlayBuilder.build(evaluation, snapshot: snapshot, environment: environment())
        #expect(codes(built.matches, of: request) == [.bodyNoMatch])
        #expect(codes(built.matches, of: response) == [.applied])
        #expect(built.matches?.ruleIDs == evaluation.matches?.ruleIDs)
    }

    @Test func rewrittenBodyFlagsModifiedOnlyWhenBytesChanged() async throws {
        let flow = ExecuteFixtures.flow(responseHeaders: [header("Content-Type", "text/plain")], responseBody: text("hello"))
        let changed = try await build(
            flow, ExecuteFixtures.snapshot(ExecuteFixtures.rule("bye", replaceBody("hello", "bye", on: .response))))
        #expect(changed.rulesModified)
        #expect(changed.overlay?.response != nil)

        let noMatch = try await build(
            flow, ExecuteFixtures.snapshot(ExecuteFixtures.rule("miss", replaceBody("absent", "x", on: .response))))
        #expect(!noMatch.rulesModified)
        #expect(noMatch.overlay == nil)

        // Replaced by the same text: the action ran, the bytes did not change.
        let same = ExecuteFixtures.rule("same", replaceBody("hello", "hello", on: .response))
        let unchanged = try await build(flow, ExecuteFixtures.snapshot(same))
        #expect(!unchanged.rulesModified)
        #expect(unchanged.overlay == nil)
        #expect(codes(unchanged.matches, of: same) == [.applied])

        // A header edit alone is a modification.
        let headerEdit = try await build(
            flow, ExecuteFixtures.snapshot(ExecuteFixtures.rule("edit", setHeader("X-R", "1", on: .response))))
        #expect(headerEdit.rulesModified)
    }

    // MARK: cancellation and resources

    @Test func cancellationStopsBeforeCreatingBodies() async throws {
        let flow = ExecuteFixtures.flow(
            method: "POST", requestHeaders: [header("Content-Type", "text/plain")], requestBody: text("hello"),
            responseHeaders: [header("Content-Type", "text/plain")], responseBody: text("hello"))
        let snapshot = ExecuteFixtures.snapshot(
            ExecuteFixtures.rule("request", replaceBody("hello", "bye", on: .request)),
            ExecuteFixtures.rule("response", replaceBody("hello", "bye", on: .response)))
        let evaluation = try await ExecuteEngine.evaluate(flow, snapshot: snapshot, environment: environment())

        let counter = BodyCounter()
        let cancelledEnvironment = environment(counter: counter)
        let task = Task { () async throws -> ExecuteOverlayBuilder.Built in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ExecuteOverlayBuilder.build(evaluation, snapshot: snapshot, environment: cancelledEnvironment)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(counter.count == 0)

        // Contrast: uncancelled, both sides get a body.
        let built = try await ExecuteOverlayBuilder.build(evaluation, snapshot: snapshot, environment: cancelledEnvironment)
        #expect(built.overlay?.request != nil && built.overlay?.response != nil)
        #expect(counter.count == 2)
    }

    @Test func bodiesAreCreatedOnlyForChangedSides() async throws {
        let flow = ExecuteFixtures.flow(
            method: "POST", requestHeaders: [header("Content-Type", "text/plain")], requestBody: text("hello"),
            responseHeaders: [header("Content-Type", "text/plain")], responseBody: text("hello"))
        let counter = BodyCounter()
        let rewriteRequest = ExecuteFixtures.snapshot(
            ExecuteFixtures.rule("request", replaceBody("hello", "bye", on: .request)))
        let rewritten = try await run(flow, rewriteRequest, environment: environment(counter: counter))
        #expect(counter.count == 1)
        #expect(rewritten.overlay?.response == nil)
        #expect(try body(rewritten.overlay?.request) == text("bye"))

        let headersOnly = ExecuteFixtures.snapshot(
            ExecuteFixtures.rule("request", setHeader("X-E", "1")),
            ExecuteFixtures.rule("response", setHeader("X-R", "1", on: .response)))
        let edited = try await run(flow, headersOnly, environment: environment(counter: counter))
        #expect(counter.count == 1)
        #expect(edited.overlay?.request?.body == flow.messages[.downstreamRequest]?.body)
        #expect(edited.overlay?.response?.body == flow.messages[.upstreamResponse]?.body)
    }
}
