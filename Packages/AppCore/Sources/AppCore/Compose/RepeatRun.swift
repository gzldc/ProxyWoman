import FlowStore
import Foundation
import Localization
import Observation

/// What a repeat run sends: how many times, how many at once, and the pause a lane keeps after
/// each of its sends. Out-of-range values are rejected (`isValid`) or pulled in (`clamped`).
public struct RepeatOptions: Equatable, Sendable {
    public static let countRange = 1...1000
    public static let concurrencyRange = 1...10
    public static let intervalMillisecondsRange = 0...60_000

    public var count = 10
    public var concurrency = 1
    public var intervalMilliseconds = 0
    /// Run the published rules on each send (off by default, like a Compose send).
    public var applyRules = false

    public init() {}

    public var isValid: Bool {
        Self.countRange.contains(count) && Self.concurrencyRange.contains(concurrency)
            && Self.intervalMillisecondsRange.contains(intervalMilliseconds)
    }

    public func clamped() -> RepeatOptions {
        var options = self
        options.count = min(max(count, Self.countRange.lowerBound), Self.countRange.upperBound)
        options.concurrency = min(max(concurrency, Self.concurrencyRange.lowerBound), Self.concurrencyRange.upperBound)
        options.intervalMilliseconds = min(max(intervalMilliseconds, Self.intervalMillisecondsRange.lowerBound),
                                           Self.intervalMillisecondsRange.upperBound)
        return options
    }
}

/// The three numeric fields of the sheet.
public enum RepeatField: Sendable, CaseIterable {
    case count, concurrency, interval

    public var range: ClosedRange<Int> {
        switch self {
        case .count: RepeatOptions.countRange
        case .concurrency: RepeatOptions.concurrencyRange
        case .interval: RepeatOptions.intervalMillisecondsRange
        }
    }
}

/// Why a field's text cannot be used.
public enum RepeatFieldIssue: Equatable, Sendable {
    case notANumber
    case outOfRange(ClosedRange<Int>)
}

/// `total` is the requested count; the other counters only grow, and when a run ended
/// `started == finished` (a cancelled run never starts the sends it did not get to).
public struct RepeatProgress: Equatable, Sendable {
    public var total = 0
    public var started = 0
    public var succeeded = 0
    public var failed = 0
    public var cancelled = 0

    public init(total: Int = 0, started: Int = 0, succeeded: Int = 0, failed: Int = 0, cancelled: Int = 0) {
        self.total = total
        self.started = started
        self.succeeded = succeeded
        self.failed = failed
        self.cancelled = cancelled
    }

    public var finished: Int { succeeded + failed + cancelled }
}

/// One failed send of a run: its 1-based index in the run, the machine code and the localized
/// message the client reported. Index 0 is the run itself (no send was made).
public struct RepeatFailure: Equatable, Sendable {
    public var index: Int
    public var code: String
    public var message: String

    public init(index: Int, code: String, message: String) {
        self.index = index
        self.code = code
        self.message = message
    }
}

/// Repeating a request that is not a plain read can repeat its side effects, so those methods need
/// an explicit confirmation. It is the Replay classification (case-sensitive), not a second one.
public enum RepeatSafety {
    public static func requiresConfirmation(method: String) -> Bool {
        !ComposeReplay.sendsImmediately(method: method)
    }
}

/// One repeat run over the Compose client: the draft is frozen when the run starts and every send
/// is a normal Compose send carrying a `RepeatRunTag`. `concurrency` lanes each take the next
/// index (1...count, never beyond it), send, count the outcome and then wait `interval` before
/// taking another. A cancel stops every lane from taking indexes, asks the client to cancel the
/// sends in flight (a send that already completed keeps its result) and wakes lanes that wait.
@MainActor @Observable public final class RepeatRunModel {
    public enum Phase: Equatable, Sendable {
        case ready, running, finished, cancelled
    }

    /// The failures kept; later ones are counted in `progress.failed` only.
    public static let failureLimit = 20
    public static let invalidDraftCode = "repeat.invalidDraft"

    public let runID: UUID
    public var confirmedUnsafe = false
    public private(set) var phase = Phase.ready
    public private(set) var progress = RepeatProgress()
    /// The first `failureLimit` failed sends, in the order they ended.
    public private(set) var failures: [RepeatFailure] = []
    /// The flows the run's sends were recorded as, in the order they ended.
    public private(set) var flowIDs: [Int] = []

    private var storedOptions: RepeatOptions
    /// What each field shows, as typed; every edit is parsed at once (no commit step to wait for).
    private var fieldTexts: [RepeatField: String] = [:]
    /// The frozen request the run repeats (read-only; the sheet shows its method and URL).
    @ObservationIgnored public let draft: ComposeDraft
    @ObservationIgnored private let client: any ComposeClient
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private var nextIndex = 1
    @ObservationIgnored private var inFlight: Set<UUID> = []
    @ObservationIgnored private var cancelRequested = false
    @ObservationIgnored private var runTask: Task<Void, Never>?

    public init(
        draft: ComposeDraft, client: any ComposeClient, options: RepeatOptions = RepeatOptions(), runID: UUID = UUID(),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.draft = draft
        self.client = client
        self.storedOptions = options
        self.runID = runID
        self.sleep = sleep
        syncTexts()
    }

    /// Editable only while the run is `ready`; a started run keeps the options it started with.
    public var options: RepeatOptions {
        get { storedOptions }
        set {
            guard phase == .ready else { return }
            // The confirmation names a count; another count asks again.
            if newValue.count != storedOptions.count { confirmedUnsafe = false }
            // Texts are rewritten only when a number changed, so an unfinished entry survives a toggle.
            let numbersChanged = newValue.count != storedOptions.count || newValue.concurrency != storedOptions.concurrency
                || newValue.intervalMilliseconds != storedOptions.intervalMilliseconds
            storedOptions = newValue
            if numbersChanged { syncTexts() }
        }
    }

    /// The text of `field` as the sheet shows it.
    public func text(of field: RepeatField) -> String { fieldTexts[field] ?? "" }

    /// Takes what the user typed. A whole number (even one out of range) becomes the option at once, so
    /// the confirmation and Start always see the value on screen; anything else leaves the option as
    /// it was and blocks Start (`issue(of:)`). Ignored once the run started.
    public func setText(_ text: String, of field: RepeatField) {
        guard phase == .ready else { return }
        fieldTexts[field] = text
        guard let value = Self.parse(text) else { return }
        switch field {
        case .count:
            if value != storedOptions.count { confirmedUnsafe = false }
            storedOptions.count = value
        case .concurrency: storedOptions.concurrency = value
        case .interval: storedOptions.intervalMilliseconds = value
        }
    }

    public func issue(of field: RepeatField) -> RepeatFieldIssue? {
        guard let value = Self.parse(text(of: field)) else { return .notANumber }
        return field.range.contains(value) ? nil : .outOfRange(field.range)
    }

    /// The localized inline error for `field`, nil when its text is usable.
    public func message(of field: RepeatField) -> String? {
        switch issue(of: field) {
        case nil: nil
        case .notANumber?: L10n.string("repeat.sheet.error.notNumber")
        case .outOfRange(let range)?: L10n.format("repeat.sheet.error.range", range.lowerBound, range.upperBound)
        }
    }

    private static func parse(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.allSatisfy({ $0.isASCII && $0.isNumber || $0 == "-" || $0 == "+" }) else { return nil }
        return Int(trimmed)
    }

    private func syncTexts() {
        fieldTexts = [.count: String(storedOptions.count), .concurrency: String(storedOptions.concurrency),
                      .interval: String(storedOptions.intervalMilliseconds)]
    }

    public var requiresConfirmation: Bool { RepeatSafety.requiresConfirmation(method: draft.method) }

    public var canStart: Bool {
        phase == .ready && RepeatField.allCases.allSatisfy { issue(of: $0) == nil } && storedOptions.isValid
            && (!requiresConfirmation || confirmedUnsafe)
    }

    /// Runs to the end or until `cancel()`; the run starts at most once.
    public func start() async {
        guard canStart else { return }
        let options = storedOptions
        phase = .running
        progress = RepeatProgress(total: options.count)
        // The draft is frozen here: one request is built, every send copies it with its own id and tag.
        guard let template = draft.outgoingRequest(id: UUID()) else {
            failures = [RepeatFailure(index: 0, code: Self.invalidDraftCode,
                                      message: L10n.string("repeat.failure.invalidDraft"))]
            phase = .finished
            return
        }
        let task = Task { @MainActor in await self.runLanes(options, template: template) }
        runTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            Task { @MainActor in self.cancel() }
        }
        runTask = nil
        let stoppedEarly = progress.started < progress.total || progress.cancelled > 0
        phase = cancelRequested && stoppedEarly ? .cancelled : .finished
    }

    /// Stops taking new sends, asks the client to cancel the ones in flight and wakes waiting lanes.
    public func cancel() {
        guard phase == .running, !cancelRequested else { return }
        cancelRequested = true
        for id in inFlight { client.cancel(id) }
        runTask?.cancel()
    }

    // MARK: Lanes

    private func runLanes(_ options: RepeatOptions, template: ComposeOutgoingRequest) async {
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<min(options.concurrency, options.count) {
                group.addTask { await self.runLane(options, template: template) }
            }
        }
    }

    private func runLane(_ options: RepeatOptions, template: ComposeOutgoingRequest) async {
        while !cancelRequested, nextIndex <= options.count {
            let index = nextIndex
            nextIndex += 1
            var request = template
            request.id = UUID()
            request.applyRules = options.applyRules
            request.repeatTag = RepeatRunTag(runID: runID, index: index, total: options.count)
            progress.started += 1
            inFlight.insert(request.id)
            let outcome = await client.send(request)
            inFlight.remove(request.id)
            record(outcome, index: index)
            // A lane with nothing left to take does not wait: the run would only end later.
            guard options.intervalMilliseconds > 0, !cancelRequested, nextIndex <= options.count else { continue }
            do {
                try await sleep(.milliseconds(options.intervalMilliseconds))
            } catch {
                return
            }
        }
    }

    private func record(_ outcome: ComposeOutcome, index: Int) {
        if let flowID = outcome.flowID { flowIDs.append(flowID) }
        guard let failure = outcome.failure else {
            progress.succeeded += 1
            return
        }
        if failure.isCancellation {
            progress.cancelled += 1
            return
        }
        progress.failed += 1
        if failures.count < Self.failureLimit {
            failures.append(RepeatFailure(index: index, code: failure.code, message: failure.message))
        }
    }
}
