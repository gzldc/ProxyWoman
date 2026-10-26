import FlowStore
import Foundation
import os
import Testing
@testable import AppCore

/// Records every call; each `send` waits until the test answers it with `finish`.
final class FakeComposeClient: ComposeClient, Sendable {
    private struct State {
        var sent: [ComposeOutgoingRequest] = []
        var cancelled: [UUID] = []
        var waiting: [UUID: CheckedContinuation<ComposeOutcome, Never>] = [:]
        var arrivals: [CheckedContinuation<Void, Never>] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    /// When set, every send is answered at once with this outcome instead of waiting for `finish`.
    private let immediate: ComposeOutcome?

    init(answering immediate: ComposeOutcome? = nil) {
        self.immediate = immediate
    }

    var sent: [ComposeOutgoingRequest] { state.withLock { $0.sent } }
    var cancelled: [UUID] { state.withLock { $0.cancelled } }

    func send(_ request: ComposeOutgoingRequest) async -> ComposeOutcome {
        if let immediate {
            state.withLock { $0.sent.append(request) }
            return immediate
        }
        return await withCheckedContinuation { continuation in
            let arrivals = state.withLock { state in
                state.sent.append(request)
                state.waiting[request.id] = continuation
                defer { state.arrivals.removeAll() }
                return state.arrivals
            }
            arrivals.forEach { $0.resume() }
        }
    }

    func cancel(_ id: UUID) {
        state.withLock { $0.cancelled.append(id) }
    }

    /// Returns once `count` sends reached the client (no sleeping).
    func waitForSends(_ count: Int) async {
        while state.withLock({ $0.sent.count }) < count {
            await withCheckedContinuation { continuation in
                let ready = state.withLock { state -> Bool in
                    if state.sent.count >= count { return true }
                    state.arrivals.append(continuation)
                    return false
                }
                if ready { continuation.resume() }
            }
        }
    }

    func finish(_ id: UUID, with outcome: ComposeOutcome) {
        let continuation = state.withLock { $0.waiting.removeValue(forKey: id) }
        continuation?.resume(returning: outcome)
    }
}

private let okResponse = ComposeResponseSnapshot(
    status: 201, reason: "Created", headers: [HeaderField(name: "Content-Type", value: "text/plain")],
    body: Data("done".utf8), bodyBytes: 4, truncated: false, trailers: [])

@MainActor @Suite(.productionChinese, .timeLimit(.minutes(1))) struct ComposeViewModelTests {
    @Test func sendShowsResponseAndFlowLink() async throws {
        let client = FakeComposeClient()
        let model = ComposeViewModel(draft: ComposeDraft(method: "GET", url: "https://h/p?a=%2F"), client: client)
        #expect(model.phase == .idle && model.canSend && model.result == nil)

        let sending = Task { await model.send() }
        await client.waitForSends(1)
        #expect(model.phase == .sending && !model.canSend)
        let request = try #require(client.sent.first)
        #expect(request.method == "GET" && request.url == "https://h/p?a=%2F" && !request.applyRules)

        client.finish(request.id, with: ComposeOutcome(flowID: 42, response: okResponse, delivery: .answered))
        await sending.value
        #expect(model.phase == .done && model.canSend)
        let result = try #require(model.result)
        #expect(result.response == okResponse && !result.isPartial && result.failureMessage == nil)
        #expect(result.flowID == 42 && result.elapsed != nil)
        #expect(result.deliveryNotice == nil)
    }

    @Test func cancelWhileSending() async throws {
        let client = FakeComposeClient()
        let model = ComposeViewModel(draft: ComposeDraft(method: "POST", url: "https://h/", body: .text("x")), client: client)
        let sending = Task { await model.send() }
        await client.waitForSends(1)
        let request = try #require(client.sent.first)

        model.cancel()
        #expect(client.cancelled == [request.id])
        // The outcome comes from the send, not from the cancel request.
        #expect(model.phase == .sending)

        let failure = ComposeOutcomeFailure(code: "compose.cancelled", message: "已取消。")
        client.finish(request.id, with: ComposeOutcome(flowID: 9, failure: failure, delivery: .unknown))
        await sending.value
        #expect(model.phase == .failed && model.canSend)
        let result = try #require(model.result)
        #expect(result.failureMessage == "已取消。" && result.response == nil && result.flowID == 9)
        #expect(result.deliveryNotice == ComposeResultPresentation.deliveryUnknownText)

        // Cancelling again with nothing running does not reach the client.
        model.cancel()
        #expect(client.cancelled == [request.id])
    }

    @Test func aCompleteResponseWinsOverALateCancel() async throws {
        let client = FakeComposeClient()
        let model = ComposeViewModel(draft: ComposeDraft(method: "GET", url: "https://h/"), client: client)
        let sending = Task { await model.send() }
        await client.waitForSends(1)
        let request = try #require(client.sent.first)
        model.cancel()
        client.finish(request.id, with: ComposeOutcome(flowID: 1, response: okResponse, delivery: .answered))
        await sending.value
        #expect(model.phase == .done && model.result?.response == okResponse)
    }

    @Test func partialResponseIsLabelledIncomplete() async throws {
        let client = FakeComposeClient()
        let model = ComposeViewModel(draft: ComposeDraft(method: "GET", url: "https://h/"), client: client)
        let sending = Task { await model.send() }
        await client.waitForSends(1)
        let request = try #require(client.sent.first)
        let partial = ComposeResponseSnapshot(status: 200, reason: "OK", headers: [], body: Data("par".utf8), bodyBytes: 3,
                                              truncated: false, trailers: [])
        let failure = ComposeOutcomeFailure(code: "compose.timeout", message: "超时。")
        client.finish(request.id, with: ComposeOutcome(flowID: 5, failure: failure, partialResponse: partial, delivery: .answered))
        await sending.value
        #expect(model.phase == .failed)
        let result = try #require(model.result)
        #expect(result.isPartial && result.response == partial && result.failureMessage == "超时。")
        #expect(result.partialNotice == ComposeResultPresentation.partialText)
        #expect(result.deliveryNotice == nil)
    }

    @Test func editingDuringSendKeepsTheFrozenRequestAndASecondSendIsRefused() async throws {
        let client = FakeComposeClient()
        let model = ComposeViewModel(draft: ComposeDraft(method: "GET", url: "https://h/a"), client: client)
        let first = Task { await model.send() }
        await client.waitForSends(1)
        model.draft.setURL("https://h/b")
        model.draft.method = "DELETE"
        await model.send()
        #expect(client.sent.count == 1)
        #expect(client.sent[0].url == "https://h/a" && client.sent[0].method == "GET")

        client.finish(client.sent[0].id, with: ComposeOutcome(flowID: 1, response: okResponse, delivery: .answered))
        await first.value
        let second = Task { await model.send() }
        await client.waitForSends(2)
        // Every send is a new id (a new flow); the edited draft is what goes out now.
        #expect(client.sent[1].id != client.sent[0].id)
        #expect(client.sent[1].url == "https://h/b" && client.sent[1].method == "DELETE")
        // The previous result stays visible until the new one arrives.
        #expect(model.result?.flowID == 1)
        client.finish(client.sent[1].id, with: ComposeOutcome(flowID: 2, response: okResponse, delivery: .answered))
        await second.value
        #expect(model.result?.flowID == 2)
    }

    @Test func anInvalidDraftIsNotSent() async {
        let client = FakeComposeClient()
        let model = ComposeViewModel(draft: ComposeDraft(method: "GET", url: "ftp://h/"), client: client)
        #expect(!model.canSend)
        #expect(model.issues.map(\.code) == [.unsupportedScheme])
        await model.send()
        #expect(client.sent.isEmpty && model.phase == .idle)
    }

    // MARK: Replay (controller ruling: only GET/HEAD/OPTIONS are sent on open)

    @Test func replaySendsOnlySafeMethodsImmediately() {
        for method in ["GET", "HEAD", "OPTIONS"] {
            #expect(ComposeReplay.sendsImmediately(method: method), "\(method)")
        }
        // Methods are case-sensitive (RFC 9110 §9.1): any other spelling is an unknown method.
        for method in ["get", "Head", "options", "gEt", "POST", "PUT", "PATCH", "DELETE", "post", "PROPFIND", "", "GET ", "TRACE"] {
            #expect(!ComposeReplay.sendsImmediately(method: method), "\(method)")
        }
    }

    @Test func replayOfASafeMethodSendsOnceOnOpen() async throws {
        let client = FakeComposeClient()
        let model = ComposeViewModel(draft: ComposeDraft(method: "GET", url: "https://h/r"), client: client)
        let opening = Task { await model.replayOnOpen() }
        await client.waitForSends(1)
        let request = try #require(client.sent.first)
        #expect(request.method == "GET" && model.draft.method == "GET")
        #expect(model.notice == nil && model.phase == .sending)
        client.finish(request.id, with: ComposeOutcome(flowID: 3, response: okResponse, delivery: .answered))
        await opening.value
        #expect(model.phase == .done && client.sent.count == 1)
    }

    @Test func replayOfAnUnsafeMethodWaitsForSend() async throws {
        // Answers at once, so a wrongly sent replay fails the expectations instead of hanging.
        let client = FakeComposeClient(answering: ComposeOutcome(flowID: 4, response: okResponse, delivery: .answered))
        let model = ComposeViewModel(draft: ComposeDraft(method: "post", url: "https://h/r", body: .none), client: client)
        await model.replayOnOpen()
        #expect(client.sent.isEmpty && model.phase == .idle && model.canSend)
        #expect(model.draft.method == "post")
        #expect(model.notice == ComposeReplay.heldNotice(method: "post"))
        #expect(model.notice?.contains("post") == true)

        // The user's own Send goes out and clears the hint.
        await model.send()
        #expect(model.notice == nil && model.phase == .done)
        #expect(client.sent.count == 1 && client.sent[0].method == "post")
    }

    @Test func replayOfALowercaseGetOpensTheDraftWithoutSending() async {
        // Answers at once, so a wrongly sent replay fails the expectations instead of hanging.
        let client = FakeComposeClient(answering: ComposeOutcome(flowID: 5, response: okResponse, delivery: .answered))
        let model = ComposeViewModel(draft: ComposeDraft(method: "get", url: "https://h/r"), client: client)
        await model.replayOnOpen()
        #expect(client.sent.isEmpty && model.phase == .idle)
        // The stored method is never rewritten.
        #expect(model.draft.method == "get")
        #expect(model.notice == ComposeReplay.heldNotice(method: "get"))
    }

    @Test func replayOfAnInvalidDraftSaysWhyNothingWasSent() async {
        let client = FakeComposeClient()
        let model = ComposeViewModel(draft: ComposeDraft(method: "GET", url: "https://h/p?a=%ZZ"), client: client)
        await model.replayOnOpen()
        #expect(client.sent.isEmpty && model.phase == .idle)
        #expect(model.notice == ComposeReplay.notSentNotice)
    }

    // MARK: Phase fix F2 — a pristine empty draft shows no URL error yet

    @Test func aPristineEmptyDraftHidesTheURLErrorUntilEditedOrSent() async {
        let client = FakeComposeClient()
        let model = ComposeViewModel(draft: ComposeDraft(), client: client)
        #expect(model.issues.contains { $0.field == .url && $0.severity == .error })
        #expect(!model.shownIssues.contains { $0.field == .url })
        #expect(!model.canSend && model.isSendEnabled)
        // Send explains instead of sending.
        await model.send()
        #expect(client.sent.isEmpty && model.phase == .idle)
        #expect(model.shownIssues.contains { $0.field == .url && $0.severity == .error })
        #expect(!model.isSendEnabled)
    }

    @Test func editingTheURLShowsItsErrorEvenWhenEmptiedAgain() {
        let model = ComposeViewModel(draft: ComposeDraft(), client: FakeComposeClient())
        model.setURL("h")
        #expect(model.draft.url == "h")
        #expect(model.shownIssues.contains { $0.field == .url })
        model.setURL("")
        #expect(model.shownIssues.contains { $0.field == .url })
        #expect(!model.isSendEnabled)
    }

    @Test func aFilledDraftShowsEveryIssueAtOnce() {
        let invalid = ComposeViewModel(draft: ComposeDraft(method: "GET", url: "ftp://h/"), client: FakeComposeClient())
        #expect(invalid.shownIssues == invalid.issues && !invalid.isSendEnabled)
        // Only the untouched empty URL is held back; other fields still say what is wrong.
        let badMethod = ComposeViewModel(draft: ComposeDraft(method: "G T"), client: FakeComposeClient())
        #expect(badMethod.shownIssues.map(\.field) == [.method])
        #expect(!badMethod.isSendEnabled)
    }
}
