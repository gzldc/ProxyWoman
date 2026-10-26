import FlowStore
import Foundation
import Localization
import Testing
import os

@testable import AppCore

/// A client whose sends are released by the test (`manual`) or answered at once, and that records
/// how many sends were in flight at the same time. `cancel` resolves a waiting send with
/// `compose.cancelled`, like the real service does.
final class RepeatFakeClient: ComposeClient, Sendable {
    enum Mode: Sendable {
        /// Each send waits until the test calls `finish`.
        case manual
        /// Answered at once, after one `Task.yield()` so the lanes interleave.
        case immediate
    }

    private struct State {
        var sent: [ComposeOutgoingRequest] = []
        var cancelled: [UUID] = []
        var waiting: [UUID: CheckedContinuation<ComposeOutcome, Never>] = [:]
        /// Answers (`finish` or `cancel`) that arrived before their send registered its continuation.
        var early: [UUID: ComposeOutcome] = [:]
        var inFlight = 0
        var maxInFlight = 0
        var arrivals: [CheckedContinuation<Void, Never>] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let mode: Mode
    private let failureFor: @Sendable (ComposeOutgoingRequest) -> ComposeOutcomeFailure?

    init(_ mode: Mode, failureFor: @escaping @Sendable (ComposeOutgoingRequest) -> ComposeOutcomeFailure? = { _ in nil }) {
        self.mode = mode
        self.failureFor = failureFor
    }

    static let okOutcome = ComposeOutcome(flowID: 1, response: ComposeResponseSnapshot(
        status: 200, reason: "OK", headers: [], body: Data(), bodyBytes: 0, truncated: false, trailers: []), delivery: .answered)

    var sent: [ComposeOutgoingRequest] { state.withLock { $0.sent } }
    var cancelled: [UUID] { state.withLock { $0.cancelled } }
    var maxInFlight: Int { state.withLock { $0.maxInFlight } }
    var inFlight: Int { state.withLock { $0.inFlight } }

    private func outcome(for request: ComposeOutgoingRequest) -> ComposeOutcome {
        if let failure = failureFor(request) {
            return ComposeOutcome(flowID: nil, failure: failure, delivery: .notSent)
        }
        return Self.okOutcome
    }

    func send(_ request: ComposeOutgoingRequest) async -> ComposeOutcome {
        let result: ComposeOutcome
        switch mode {
        case .immediate:
            let arrivals = state.withLock { state -> [CheckedContinuation<Void, Never>] in
                state.sent.append(request)
                state.inFlight += 1
                state.maxInFlight = max(state.maxInFlight, state.inFlight)
                defer { state.arrivals.removeAll() }
                return state.arrivals
            }
            arrivals.forEach { $0.resume() }
            await Task.yield()
            result = outcome(for: request)
        case .manual:
            result = await withCheckedContinuation { (continuation: CheckedContinuation<ComposeOutcome, Never>) in
                // The continuation is registered (or an early answer applied) before `waitForSends`
                // is woken, so a test that finishes or cancels right after the wake-up cannot miss it.
                let (early, arrivals) = state.withLock { state -> (ComposeOutcome?, [CheckedContinuation<Void, Never>]) in
                    state.sent.append(request)
                    state.inFlight += 1
                    state.maxInFlight = max(state.maxInFlight, state.inFlight)
                    let early = state.early.removeValue(forKey: request.id)
                    if early == nil { state.waiting[request.id] = continuation }
                    defer { state.arrivals.removeAll() }
                    return (early, state.arrivals)
                }
                arrivals.forEach { $0.resume() }
                if let early { continuation.resume(returning: early) }
            }
        }
        state.withLock { $0.inFlight -= 1 }
        return result
    }

    func cancel(_ id: UUID) {
        let cancelled = ComposeOutcome(
            flowID: nil, failure: ComposeOutcomeFailure(code: "compose.cancelled", message: "cancelled", isCancellation: true),
            delivery: .notSent)
        let continuation = state.withLock { state -> CheckedContinuation<ComposeOutcome, Never>? in
            state.cancelled.append(id)
            if let waiting = state.waiting.removeValue(forKey: id) { return waiting }
            state.early[id] = cancelled
            return nil
        }
        continuation?.resume(returning: cancelled)
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

    /// Answers the manual send `id`. If that send has not arrived yet, the answer is kept and
    /// applied when it does.
    func finish(_ id: UUID, failure: ComposeOutcomeFailure? = nil) {
        let outcome = failure.map { ComposeOutcome(flowID: nil, failure: $0, delivery: .notSent) } ?? Self.okOutcome
        let continuation = state.withLock { state -> CheckedContinuation<ComposeOutcome, Never>? in
            if let waiting = state.waiting.removeValue(forKey: id) { return waiting }
            state.early[id] = outcome
            return nil
        }
        continuation?.resume(returning: outcome)
    }
}

/// The injected `sleep`: every call waits at this gate until the test releases it, and a
/// cancelled sleeper throws `CancellationError` like `Task.sleep`.
final class SleepGate: Sendable {
    private struct State {
        var durations: [Duration] = []
        var waiting: [Int: CheckedContinuation<Void, Error>] = [:]
        var cancelledTokens: Set<Int> = []
        var interrupted = 0
        var nextToken = 0
        var arrivals: [CheckedContinuation<Void, Never>] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var durations: [Duration] { state.withLock { $0.durations } }
    var sleepCount: Int { state.withLock { $0.durations.count } }
    var sleepers: Int { state.withLock { $0.waiting.count } }
    /// Sleepers that ended because their task was cancelled.
    var interrupted: Int { state.withLock { $0.interrupted } }

    func sleep(_ duration: Duration) async throws {
        let token = state.withLock { state -> Int in
            state.nextToken += 1
            state.durations.append(duration)
            return state.nextToken
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let (cancelledEarly, arrivals) = state.withLock { state -> (Bool, [CheckedContinuation<Void, Never>]) in
                    if state.cancelledTokens.remove(token) != nil {
                        state.interrupted += 1
                        return (true, [])
                    }
                    state.waiting[token] = continuation
                    defer { state.arrivals.removeAll() }
                    return (false, state.arrivals)
                }
                if cancelledEarly { continuation.resume(throwing: CancellationError()) }
                arrivals.forEach { $0.resume() }
            }
        } onCancel: {
            let continuation = state.withLock { state -> CheckedContinuation<Void, Error>? in
                if let waiting = state.waiting.removeValue(forKey: token) {
                    state.interrupted += 1
                    return waiting
                }
                state.cancelledTokens.insert(token)
                return nil
            }
            continuation?.resume(throwing: CancellationError())
        }
    }

    /// Returns once `count` sleepers wait at the gate.
    func waitForSleepers(_ count: Int) async {
        while state.withLock({ $0.waiting.count }) < count {
            await withCheckedContinuation { continuation in
                let ready = state.withLock { state -> Bool in
                    if state.waiting.count >= count { return true }
                    state.arrivals.append(continuation)
                    return false
                }
                if ready { continuation.resume() }
            }
        }
    }

    func releaseAll() {
        let released = state.withLock { state -> [CheckedContinuation<Void, Error>] in
            defer { state.waiting.removeAll() }
            return Array(state.waiting.values)
        }
        released.forEach { $0.resume() }
    }
}

@MainActor @Suite(.timeLimit(.minutes(1)), .productionChinese) struct RepeatRunModelTests {
    private func draft(method: String = "GET", url: String = "http://127.0.0.1:9/r", applyRules: Bool = false) -> ComposeDraft {
        ComposeDraft(sourceFlowID: 12, method: method, url: url, policy: ComposeDraftPolicy(applyRules: applyRules))
    }

    private func model(
        _ draft: ComposeDraft, _ client: RepeatFakeClient, count: Int = 10, concurrency: Int = 1, interval: Int = 0,
        applyRules: Bool = false, runID: UUID = UUID(), gate: SleepGate = SleepGate()
    ) -> RepeatRunModel {
        var options = RepeatOptions()
        options.count = count
        options.concurrency = concurrency
        options.intervalMilliseconds = interval
        options.applyRules = applyRules
        return RepeatRunModel(draft: draft, client: client, options: options, runID: runID, sleep: { try await gate.sleep($0) })
    }

    // MARK: Options and safety

    @Test func optionsClampAndValidate() {
        let defaults = RepeatOptions()
        #expect(defaults.count == 10 && defaults.concurrency == 1 && defaults.intervalMilliseconds == 0 && !defaults.applyRules)
        #expect(defaults.isValid)
        #expect(RepeatOptions.countRange == 1...1000 && RepeatOptions.concurrencyRange == 1...10
                && RepeatOptions.intervalMillisecondsRange == 0...60_000)

        func options(count: Int = 10, concurrency: Int = 1, interval: Int = 0) -> RepeatOptions {
            var options = RepeatOptions()
            options.count = count
            options.concurrency = concurrency
            options.intervalMilliseconds = interval
            return options
        }
        #expect(!options(count: 0).isValid && options(count: 0).clamped().count == 1)
        #expect(options(count: 1).isValid && options(count: 1000).isValid)
        #expect(!options(count: 1001).isValid && options(count: 1001).clamped().count == 1000)
        #expect(!options(count: -5).isValid && options(count: -5).clamped().count == 1)
        #expect(!options(concurrency: 0).isValid && options(concurrency: 0).clamped().concurrency == 1)
        #expect(options(concurrency: 10).isValid && !options(concurrency: 11).isValid)
        #expect(options(concurrency: 11).clamped().concurrency == 10)
        #expect(!options(concurrency: -1).isValid && options(concurrency: -1).clamped().concurrency == 1)
        #expect(options(interval: 0).isValid && options(interval: 60_000).isValid)
        #expect(!options(interval: -1).isValid && options(interval: -1).clamped().intervalMilliseconds == 0)
        #expect(!options(interval: 60_001).isValid && options(interval: 60_001).clamped().intervalMilliseconds == 60_000)

        var rules = options(count: 2000)
        rules.applyRules = true
        #expect(rules.clamped().applyRules && rules.clamped().isValid)
    }

    // MARK: Typed fields (what the sheet binds to; nothing waits for Return or blur)

    @Test func typedFieldsApplyAtOnceAndTheRunSendsWhatWasTyped() async {
        let client = RepeatFakeClient(.immediate)
        let run = model(draft(), client, count: 10)
        #expect(run.text(of: .count) == "10" && run.text(of: .concurrency) == "1" && run.text(of: .interval) == "0")
        run.setText("3", of: .count)
        run.setText(" 2 ", of: .concurrency)
        run.setText("0", of: .interval)
        #expect(run.options.count == 3 && run.options.concurrency == 2 && run.canStart)
        #expect(run.text(of: .count) == "3", "the typed text is kept as typed")
        await run.start()
        #expect(client.sent.count == 3 && run.progress.total == 3)
    }

    @Test func invalidTypedFieldsBlockStartAndExplainWhy() async {
        let client = RepeatFakeClient(.immediate)
        let run = model(draft(), client)
        for text in ["", "abc", "5.5", "1,000", "0", "1001", "-3", "99999999999999999999"] {
            run.setText(text, of: .count)
            #expect(!run.canStart, "count \"\(text)\" blocks Start")
            #expect(run.issue(of: .count) != nil, "count \"\(text)\"")
        }
        run.setText("abc", of: .count)
        #expect(run.issue(of: .count) == .notANumber)
        #expect(run.message(of: .count) == L10n.string("repeat.sheet.error.notNumber"))
        run.setText("1001", of: .count)
        #expect(run.issue(of: .count) == .outOfRange(1...1000))
        #expect(run.message(of: .count) == L10n.format("repeat.sheet.error.range", 1, 1000))
        run.setText("11", of: .concurrency)
        #expect(run.issue(of: .concurrency) == .outOfRange(1...10) && run.issue(of: .count) != nil)
        run.setText("60001", of: .interval)
        #expect(run.message(of: .interval) == L10n.format("repeat.sheet.error.range", 0, 60_000))
        await run.start()
        #expect(client.sent.isEmpty && run.phase == .ready)

        run.setText("1000", of: .count)
        run.setText("10", of: .concurrency)
        run.setText("60000", of: .interval)
        #expect(run.issue(of: .count) == nil && run.message(of: .count) == nil)
        #expect(run.canStart && run.options.count == 1000 && run.options.concurrency == 10
                && run.options.intervalMilliseconds == 60_000)
    }

    @Test func intervalWaitsWithTheDefaultClockSleep() async {
        // The App builds the model without a sleep; the injected-sleep tests never run that path.
        let client = RepeatFakeClient(.immediate)
        let run = RepeatRunModel(draft: draft(), client: client)
        run.options.count = 4
        run.options.intervalMilliseconds = 1
        await run.start()
        #expect(client.sent.count == 4)
    }

    @Test func confirmationAlwaysNamesTheCountThatWillBeSent() async {
        let client = RepeatFakeClient(.immediate)
        let post = RepeatRunModel(draft: draft(method: "POST"), client: client)
        post.setText("500", of: .count)
        post.confirmedUnsafe = true
        #expect(post.canStart && post.options.count == 500)
        // Typing another count (no Return, no blur) withdraws the confirmation that named 500.
        post.setText("5", of: .count)
        #expect(post.options.count == 5 && !post.confirmedUnsafe && !post.canStart)
        post.confirmedUnsafe = true
        await post.start()
        #expect(client.sent.count == 5 && post.progress.total == 5)
    }

    @Test func fieldTextFollowsOptionsAndLocksWhileRunning() async {
        let client = RepeatFakeClient(.manual)
        let run = model(draft(), client, count: 2)
        run.options.count = 7
        #expect(run.text(of: .count) == "7")
        let started = Task { await run.start() }
        await client.waitForSends(1)
        run.setText("50", of: .count)
        #expect(run.text(of: .count) == "7" && run.options.count == 7, "a started run keeps its fields")
        run.cancel()
        await started.value
    }

    @Test func unsafeMethodRequiresConfirmation() {
        let client = RepeatFakeClient(.immediate)
        let post = RepeatRunModel(draft: draft(method: "POST"), client: client)
        #expect(!post.canStart)
        post.confirmedUnsafe = true
        #expect(post.canStart)
        post.options.count = 0
        #expect(!post.canStart, "an invalid option still blocks a confirmed run")

        for method in ["GET", "HEAD", "OPTIONS"] {
            #expect(RepeatSafety.requiresConfirmation(method: method) == false, "\(method)")
            #expect(RepeatRunModel(draft: draft(method: method), client: client).canStart, "\(method)")
        }
        // Methods are case-sensitive: "get" is an unknown method and needs the confirmation.
        #expect(RepeatSafety.requiresConfirmation(method: "get"))
        #expect(RepeatSafety.requiresConfirmation(method: "DELETE"))
        #expect(!RepeatRunModel(draft: draft(method: "get"), client: client).canStart)
    }

    @Test func startIsRefusedWithoutConfirmation() async {
        let client = RepeatFakeClient(.immediate)
        let post = RepeatRunModel(draft: draft(method: "POST"), client: client)
        await post.start()
        #expect(post.phase == .ready && client.sent.isEmpty && post.progress == RepeatProgress())
    }

    // MARK: Scheduling

    @Test func sendsExactlyCountRequestsWithDistinctIDsAndTags() async {
        let client = RepeatFakeClient(.immediate)
        let runID = UUID()
        // The draft says "rules on"; the run's own option decides.
        let run = model(draft(applyRules: true), client, count: 7, concurrency: 1, applyRules: false, runID: runID)
        #expect(run.phase == .ready)
        await run.start()

        #expect(run.phase == .finished)
        let sent = client.sent
        #expect(sent.count == 7)
        #expect(Set(sent.map(\.id)).count == 7)
        #expect(sent.compactMap { $0.repeatTag?.index } == Array(1...7))
        #expect(sent.allSatisfy { $0.repeatTag?.total == 7 && $0.repeatTag?.runID == runID })
        #expect(sent.allSatisfy { !$0.applyRules && $0.sourceFlowID == 12 && $0.method == "GET" })
        #expect(run.progress == RepeatProgress(total: 7, started: 7, succeeded: 7, failed: 0, cancelled: 0))
        #expect(run.progress.finished == 7)
        #expect(run.flowIDs == Array(repeating: 1, count: 7))

        let withRules = RepeatFakeClient(.immediate)
        await model(draft(applyRules: false), withRules, count: 3, applyRules: true).start()
        #expect(withRules.sent.count == 3 && withRules.sent.allSatisfy(\.applyRules))
    }

    @Test func neverExceedsConcurrency() async {
        let client = RepeatFakeClient(.manual)
        let run = model(draft(), client, count: 7, concurrency: 3)
        let started = Task { await run.start() }
        var finished = 0
        while finished < 7 {
            await client.waitForSends(min(finished + 3, 7))
            #expect(client.inFlight <= 3)
            client.finish(client.sent[finished].id)
            finished += 1
        }
        await started.value
        #expect(client.maxInFlight == 3)
        #expect(client.sent.count == 7 && run.progress.succeeded == 7 && run.phase == .finished)
    }

    @Test func intervalIsAppliedAfterEachSendPerLane() async {
        let client = RepeatFakeClient(.manual)
        let gate = SleepGate()
        let run = model(draft(), client, count: 3, concurrency: 1, interval: 250, gate: gate)
        let started = Task { await run.start() }

        await client.waitForSends(1)
        #expect(gate.sleepCount == 0, "the wait comes after the send, not before it")
        client.finish(client.sent[0].id)
        await gate.waitForSleepers(1)
        #expect(client.sent.count == 1, "no second send while the lane waits")
        #expect(gate.durations == [.milliseconds(250)])
        gate.releaseAll()

        await client.waitForSends(2)
        client.finish(client.sent[1].id)
        await gate.waitForSleepers(1)
        #expect(client.sent.count == 2 && gate.sleepCount == 2)
        gate.releaseAll()

        await client.waitForSends(3)
        client.finish(client.sent[2].id)
        await started.value
        // Nothing is left to send, so the last send is not followed by a wait.
        #expect(gate.sleepCount == 2 && gate.durations.allSatisfy { $0 == .milliseconds(250) })
        #expect(run.phase == .finished && run.progress.succeeded == 3)
    }

    @Test func eachLaneWaitsOnItsOwn() async {
        let client = RepeatFakeClient(.immediate)
        let gate = SleepGate()
        let run = model(draft(), client, count: 4, concurrency: 2, interval: 40, gate: gate)
        let started = Task { await run.start() }
        await gate.waitForSleepers(2)
        #expect(client.sent.count == 2)
        gate.releaseAll()
        await started.value
        #expect(client.sent.count == 4 && gate.sleepCount == 2)
        #expect(run.phase == .finished)

        let quiet = SleepGate()
        await model(draft(), RepeatFakeClient(.immediate), count: 5, concurrency: 2, interval: 0, gate: quiet).start()
        #expect(quiet.sleepCount == 0, "interval 0 never sleeps")
    }

    @Test func cancelStopsNewSendsAndInterruptsIntervalSleep() async {
        let client = RepeatFakeClient(.immediate)
        let gate = SleepGate()
        let run = model(draft(), client, count: 5, concurrency: 1, interval: 60_000, gate: gate)
        let started = Task { await run.start() }
        await gate.waitForSleepers(1)
        #expect(run.phase == .running && client.sent.count == 1)

        run.cancel()
        await started.value // returns without the 60 s elapsing: the sleep was interrupted
        #expect(run.phase == .cancelled)
        #expect(gate.interrupted == 1 && gate.sleepers == 0)
        #expect(client.sent.count == 1, "no new send after the cancel")
        #expect(client.cancelled.isEmpty, "the only send had already ended")
        #expect(run.progress == RepeatProgress(total: 5, started: 1, succeeded: 1, failed: 0, cancelled: 0))
    }

    @Test func cancelAsksTheClientToCancelEveryInFlightSend() async {
        let client = RepeatFakeClient(.manual)
        let run = model(draft(), client, count: 6, concurrency: 3)
        let started = Task { await run.start() }
        await client.waitForSends(3)
        client.finish(client.sent[0].id)
        await client.waitForSends(4)
        let inFlight = Set(client.sent.map(\.id)).subtracting([client.sent[0].id])
        #expect(inFlight.count == 3)

        run.cancel()
        await started.value
        #expect(run.phase == .cancelled)
        #expect(Set(client.cancelled) == inFlight)
        #expect(client.sent.count == 4, "the cancel stopped the lanes from taking more indexes")
        #expect(run.progress == RepeatProgress(total: 6, started: 4, succeeded: 1, failed: 0, cancelled: 3))
        #expect(run.failures.isEmpty, "a cancelled send is not a failure")
        #expect(client.inFlight == 0)
    }

    @Test func cancelWhileNotRunningDoesNothing() async {
        let client = RepeatFakeClient(.immediate)
        let run = model(draft(), client, count: 2)
        run.cancel()
        #expect(run.phase == .ready)
        await run.start()
        #expect(run.phase == .finished && client.sent.count == 2)
        run.cancel()
        #expect(run.phase == .finished)
    }

    @Test func countNeverExceedsTotal() async {
        let client = RepeatFakeClient(.immediate) { request in
            guard let index = request.repeatTag?.index, index % 7 == 0 else { return nil }
            return ComposeOutcomeFailure(code: "upstream.unreachable", message: "no route \(index)")
        }
        let run = model(draft(), client, count: 1000, concurrency: 10)
        await run.start()
        let progress = run.progress
        #expect(run.phase == .finished)
        #expect(progress.total == 1000 && progress.started == 1000)
        #expect(progress.succeeded + progress.failed + progress.cancelled == 1000)
        #expect(progress.finished == 1000 && progress.failed == 142 && progress.succeeded == 858)
        #expect(client.sent.count == 1000 && Set(client.sent.map(\.id)).count == 1000)
        #expect(Set(client.sent.compactMap { $0.repeatTag?.index }) == Set(1...1000))
        #expect(client.maxInFlight <= 10)
        #expect(run.failures.count == 20)
    }

    @Test func failuresAreCountedAndCappedAtTwenty() async {
        let client = RepeatFakeClient(.immediate) { _ in
            ComposeOutcomeFailure(code: "upstream.unreachable", message: "connection refused")
        }
        let run = model(draft(), client, count: 30)
        await run.start()
        #expect(run.progress == RepeatProgress(total: 30, started: 30, succeeded: 0, failed: 30, cancelled: 0))
        #expect(run.failures.count == 20)
        #expect(run.failures.map(\.index) == Array(1...20))
        #expect(run.failures.allSatisfy { $0.code == "upstream.unreachable" && $0.message == "connection refused" })
        #expect(run.flowIDs.isEmpty, "failed sends without a flow add nothing")

        let mixed = RepeatFakeClient(.immediate) { request in
            request.repeatTag?.index == 2
                ? ComposeOutcomeFailure(code: "compose.cancelled", message: "cancelled", isCancellation: true) : nil
        }
        let cancelledRun = model(draft(), mixed, count: 3)
        await cancelledRun.start()
        #expect(cancelledRun.progress == RepeatProgress(total: 3, started: 3, succeeded: 2, failed: 0, cancelled: 1))
        #expect(cancelledRun.failures.isEmpty)
    }

    @Test func cancellationIsTheTypedFlagNotTheCode() async {
        // The count follows `isCancellation`; the machine code is only reported, never matched.
        let client = RepeatFakeClient(.immediate) { request in
            switch request.repeatTag?.index {
            case 1: ComposeOutcomeFailure(code: "any.code", message: "flagged", isCancellation: true)
            case 2: ComposeOutcomeFailure(code: "compose.cancelled", message: "unflagged")
            default: nil
            }
        }
        let run = model(draft(), client, count: 3)
        await run.start()
        #expect(run.progress == RepeatProgress(total: 3, started: 3, succeeded: 1, failed: 1, cancelled: 1))
        #expect(run.failures == [RepeatFailure(index: 2, code: "compose.cancelled", message: "unflagged")])
        #expect(ComposeOutcomeFailure(code: "x", message: "y").isCancellation == false)
    }

    // MARK: Draft and state

    @Test func invalidDraftFinishesImmediately() async {
        let client = RepeatFakeClient(.immediate)
        let run = RepeatRunModel(draft: draft(url: ""), client: client)
        #expect(run.canStart)
        await run.start()
        #expect(run.phase == .finished)
        #expect(client.sent.isEmpty)
        #expect(run.progress.started == 0 && run.progress.finished == 0)
        #expect(run.failures == [RepeatFailure(index: 0, code: "repeat.invalidDraft",
                                               message: L10n.string("repeat.failure.invalidDraft"))])
    }

    @Test func optionsLockedWhileRunning() async {
        let client = RepeatFakeClient(.manual)
        let run = model(draft(), client, count: 2, concurrency: 1)
        run.options.count = 3 // ready: editable
        #expect(run.options.count == 3)
        let started = Task { await run.start() }
        await client.waitForSends(1)
        #expect(run.phase == .running)
        run.options.count = 99
        run.options.concurrency = 5
        #expect(run.options.count == 3 && run.options.concurrency == 1)
        for index in 0..<3 {
            await client.waitForSends(index + 1)
            client.finish(client.sent[index].id)
        }
        await started.value
        #expect(run.phase == .finished && client.sent.count == 3)
        run.options.count = 4
        #expect(run.options.count == 3, "a finished run keeps its options")
        #expect(!run.canStart)
        await run.start()
        #expect(client.sent.count == 3, "a run starts once")
    }

    @Test func theDraftIsFrozenAtStart() async {
        let client = RepeatFakeClient(.manual)
        var original = draft(url: "http://127.0.0.1:9/before")
        let run = model(original, client, count: 2)
        let started = Task { await run.start() }
        await client.waitForSends(1)
        original.setURL("http://127.0.0.1:9/after")
        client.finish(client.sent[0].id)
        await client.waitForSends(2)
        client.finish(client.sent[1].id)
        await started.value
        #expect(client.sent.map(\.url) == ["http://127.0.0.1:9/before", "http://127.0.0.1:9/before"])
    }
}
