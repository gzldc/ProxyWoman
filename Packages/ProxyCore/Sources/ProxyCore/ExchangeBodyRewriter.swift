import FlowStore
import Foundation
import NIOCore
import RulesEngine

/// Why an automatic body rewrite ended the exchange (or, for `cancelled`, was given up).
enum BodyRewriteFailure: Error, Equatable {
    /// An unknown-length body grew past `rewriteBodyBytes` (a known length over it is never collected).
    case tooLarge
    /// No body bytes arrived for `rewriteSeconds` (the idle deadline), or collecting took longer than
    /// `rewriteTotalSeconds` in all (the overall safety cap).
    case timedOut
    /// The body could not be collected: spool budget, disk, I/O, or a truncated message.
    case unavailable
    /// Part of the shared interface; nothing produces it yet (an abandoned gate reports nothing).
    case cancelled
}

/// A collected body ready to continue through the reviewed exact-body path, with the final outcome
/// of each body rule.
struct BodyRewriteCompletion {
    let continuation: BreakpointBodyContinuation
    let outcomes: [RuleOutcome]
}

/// Collects one message body (through `BreakpointBodyCollector`), rewrites it in a `Task` (never on
/// the event loop) and writes the result to a new exact spool, then hands a
/// `BreakpointBodyContinuation` to `completed`. The direction is a parameter, so request bodies use
/// the same machine.
///
/// Confined to `loop`: every mutable property is only touched there (asserted). The transform task
/// captures only immutable, Sendable values. Each piece of file or memory work keeps what it
/// reserved until it has settled, even after `abandon()`; no callback fires after resolution.
final class ExchangeBodyRewriter: ExchangeBodyGate {
    private enum Phase { case collecting, transforming, writing, resolved }

    private let loop: EventLoop
    private let io: BodyFileIO
    private let limits: RulesLimits
    private let cache: PatternCache
    private let messageDirection: HTTPMessageDirection
    /// The rule steps in order; the owner settles them itself when it abandons an unresolved gate.
    let steps: [BodyRewriteStep]
    private let effectiveHead: HTTPMessageHead
    private let sourceVersion: HTTPWireVersion
    private let changed: () -> Void
    private let completed: (BodyRewriteCompletion) -> Void
    private let failed: (BodyRewriteFailure, [RuleOutcome]) -> Void

    private var phase = Phase.collecting
    private var collector: BreakpointBodyCollector?
    private var received: Int64 = 0
    private(set) var receivedEnd = false
    private var timer: Scheduled<Void>?
    /// The overall safety cap, armed once by `start()` and never re-armed.
    private var overallTimer: Scheduled<Void>?
    /// Bumped each time the idle deadline is re-armed; a timer from an earlier arming is ignored.
    private var deadlineGeneration = 0
    /// The collected original, from the end of collection until it is handed on or given up.
    private var collected: ExactBodySource?
    private var transform: Task<Void, Never>?
    private var replacement: ExactBodySpool?

    var direction: HTTPMessageDirection? { messageDirection }
    var isCollecting: Bool { phase == .collecting }
    var canRead: Bool { isCollecting && !receivedEnd && collector?.canRead == true }
    var timerCount: Int { loop.preconditionInEventLoop(); return timer == nil ? 0 : 1 }
    var overallTimerCount: Int { loop.preconditionInEventLoop(); return overallTimer == nil ? 0 : 1 }

    /// Throws `BodyRewriteFailure.tooLarge` for a known length over `rewriteBodyBytes`, or the
    /// spool's `OwnedFileError` when its budget cannot be reserved; nothing is held then.
    /// `collected` is a body already collected in full (a request body peeked for conditions): the
    /// gate then skips collection, takes ownership of it once created, and rewrites it on `start()`.
    init(loop: EventLoop, io: BodyFileIO, limits: RulesLimits, cache: PatternCache,
         direction: HTTPMessageDirection, steps: [BodyRewriteStep], effectiveHead: HTTPMessageHead,
         expectedLength: Int64?, sourceVersion: HTTPWireVersion, collected: ExactBodySource? = nil,
         changed: @escaping () -> Void,
         completed: @escaping (BodyRewriteCompletion) -> Void,
         failed: @escaping (BodyRewriteFailure, [RuleOutcome]) -> Void) throws {
        let length = collected?.size ?? expectedLength
        if let length, length > Int64(limits.rewriteBodyBytes) { throw BodyRewriteFailure.tooLarge }
        self.loop = loop; self.io = io; self.limits = limits; self.cache = cache
        self.messageDirection = direction; self.steps = steps; self.effectiveHead = effectiveHead
        self.sourceVersion = sourceVersion
        self.changed = changed; self.completed = completed; self.failed = failed
        if let collected {
            self.collected = collected
            received = collected.size; receivedEnd = true; phase = .transforming
        } else {
            collector = try BreakpointBodyCollector(expectedLength: expectedLength, io: io)
        }
    }

    /// A configured deadline held to 1 second ... 1 day: zero or negative values would fire at
    /// once and fail a healthy exchange, and an absurd one is no deadline at all.
    static func deadlineSeconds(_ configured: Int) -> Int64 {
        Int64(min(max(configured, 1), 86_400))
    }

    /// Arms the idle deadline (`rewriteSeconds` without a new body chunk) and the overall cap
    /// (`rewriteTotalSeconds` for the whole collection), and lets the owner route queued parts. A gate
    /// created with a collected body starts its rewrite instead.
    func start() {
        loop.preconditionInEventLoop()
        if phase == .transforming, transform == nil, let collected {
            changed()
            if phase == .transforming { beginTransform(collected) }
            return
        }
        guard phase == .collecting, timer == nil else { return }
        armDeadline()
        overallTimer = loop.assumeIsolated().scheduleTask(in: .seconds(Self.deadlineSeconds(limits.rewriteTotalSeconds))) { [weak self] in
            guard let self, self.phase == .collecting else { return }
            self.overallTimer = nil
            self.fail(.timedOut)
        }
        changed()
    }

    /// (Re)starts the idle countdown. A slow but steady transfer, such as one shaped by the network
    /// conditions, never trips it; an origin that goes quiet for `rewriteSeconds` does. The byte cap
    /// bounds how much a trickle can hold, and the overall cap bounds for how long.
    private func armDeadline() {
        timer?.cancel()
        deadlineGeneration += 1
        let generation = deadlineGeneration
        timer = loop.assumeIsolated().scheduleTask(in: .seconds(Self.deadlineSeconds(limits.rewriteSeconds))) { [weak self] in
            guard let self, self.phase == .collecting, self.deadlineGeneration == generation else { return }
            self.timer = nil
            self.fail(.timedOut)
        }
    }

    @discardableResult
    func append(_ bytes: ByteBuffer) -> EventLoopFuture<Void> {
        loop.preconditionInEventLoop()
        guard isCollecting, !receivedEnd, let collector else { return loop.makeFailedFuture(OwnedFileError(.cancelled)) }
        let count = Int64(bytes.readableBytes)
        guard received + count <= Int64(limits.rewriteBodyBytes) else {
            fail(.tooLarge)
            return loop.makeFailedFuture(OwnedFileError(.fileTooLarge))
        }
        received += count
        if count > 0, timer != nil { armDeadline() }
        let future = collector.append(bytes)
        future.assumeIsolated().whenComplete { [weak self] result in
            guard let self, self.phase == .collecting else { return }
            if case .failure(let error) = result { self.failBodyCallback(error, operation: nil) } else { self.changed() }
        }
        changed()
        return future
    }

    func finishBody(trailers: [HeaderField]) {
        loop.preconditionInEventLoop()
        guard isCollecting, !receivedEnd, let collector else { return }
        receivedEnd = true
        collector.finish(trailers: trailers).assumeIsolated().whenComplete { [weak self] result in
            guard let self, self.phase == .collecting else {
                if case .success(let source) = result { source.cancel() }
                return
            }
            switch result {
            case .failure(let error): self.failBodyCallback(error, operation: nil)
            case .success(let source):
                self.collector = nil
                self.timer?.cancel(); self.timer = nil
                self.overallTimer?.cancel(); self.overallTimer = nil
                self.collected = source
                self.phase = .transforming
                self.changed()
                // The owner may have reacted to `changed` by giving everything up.
                if self.phase == .transforming { self.beginTransform(source) }
            }
        }
        changed()
    }

    func failBodyCallback(_ error: Error, operation: UUID?) {
        loop.preconditionInEventLoop()
        guard isCollecting else { return }
        fail((error as? OwnedFileError)?.code == .fileTooLarge ? .tooLarge : .unavailable)
    }

    func abandon() {
        loop.preconditionInEventLoop()
        guard phase != .resolved else { return }
        resolve()
    }

    // MARK: transform

    /// Reserves the transform's memory up front; without it the original continues untouched and the
    /// rules say the memory budget was busy.
    /// Plain bodies need the original, the text and the result (3 x size). An encoded body's
    /// decoded text and result can each reach the rewrite cap whatever its wire size, so it
    /// reserves size + 2 x `rewriteBodyBytes`.
    private func beginTransform(_ source: ExactBodySource) {
        let reservation: OwnedFileReservation
        do {
            let (bytes, overflow) = encodingChoice == .removeEncoding
                ? source.size.addingReportingOverflow(2 * Int64(limits.rewriteBodyBytes))
                : source.size.multipliedReportingOverflow(by: 3)
            guard !overflow else { throw OwnedFileError(.capacityExceeded) }
            reservation = try io.budgets.reserve(category: .editor, bytes: bytes)
        } catch {
            completeUnchanged(skipped(.bodySkippedBusy))
            return
        }
        let steps = self.steps, limits = self.limits, cache = self.cache, size = source.size
        let contentType = effectiveHead.headers.values(for: "content-type").first
        let encodings = effectiveHead.headers.values(for: "content-encoding")
        let contentEncoding = encodings.isEmpty ? nil : encodings.joined(separator: ", ")
        let promise = loop.makePromise(of: BodyRewriteResult.self)
        transform = promise.completeWithTask {
            var body = Data()
            body.reserveCapacity(Int(size))
            while Int64(body.count) < size {
                try Task.checkCancellation()
                let chunk = try await source.read(offset: Int64(body.count), maxBytes: 65_536)
                guard !chunk.isEmpty else { throw OwnedFileError(.shortRead) }
                body.append(chunk)
            }
            return try await BodyRewriter.apply(steps: steps, to: body, contentType: contentType,
                                                contentEncoding: contentEncoding, limits: limits, cache: cache)
        }
        promise.futureResult.assumeIsolated().whenComplete { [weak self] result in
            // The task has settled: nothing reads the source any more.
            guard let self, self.phase == .transforming else { reservation.release(); return }
            self.transform = nil
            switch result {
            case .success(.rewritten(let data, let outcomes)):
                self.writeReplacement(data, outcomes: outcomes, reservation: reservation)
            case .success(.unchanged(let outcomes)):
                reservation.release()
                self.completeUnchanged(outcomes)
            case .failure:
                reservation.release()
                self.completeUnchanged(self.skipped(.bodySkippedUnavailable))
            }
        }
    }

    /// The rewritten bytes go to a new exact spool in bounded chunks. The memory reservation stays
    /// until the buffer is no longer referenced by pending writes. A failure here keeps the
    /// original: it is still complete on disk.
    private func writeReplacement(_ data: Data, outcomes: [RuleOutcome], reservation: OwnedFileReservation) {
        let spool: ExactBodySpool
        do { spool = try ExactBodySpool(category: .breakpoint, expectedLength: Int64(data.count), limits: io.limits, io: io) }
        catch {
            reservation.release()
            completeUnchanged(skipped(.bodySkippedUnavailable))
            return
        }
        replacement = spool
        phase = .writing
        write(data, offset: 0, spool: spool, outcomes: outcomes, reservation: reservation)
    }

    private func write(_ data: Data, offset: Int, spool: ExactBodySpool, outcomes: [RuleOutcome],
                       reservation: OwnedFileReservation) {
        if offset == data.count {
            spool.finish(trailers: []).assumeIsolated().whenComplete { [weak self] result in
                reservation.release()
                guard let self, self.phase == .writing else {
                    if case .success(let source) = result { source.cancel() }
                    return
                }
                self.replacement = nil
                switch result {
                case .failure: self.completeUnchanged(self.skipped(.bodySkippedUnavailable))
                case .success(let source): self.complete(rewritten: source, outcomes: outcomes)
                }
            }
            return
        }
        let count = min(data.count - offset, max(1, min(65_536, io.limits.ioChunkBytes)))
        let start = data.startIndex + offset
        spool.append(ByteBuffer(bytes: data[start..<(start + count)])).assumeIsolated().whenComplete { [weak self] result in
            guard let self, self.phase == .writing else {
                spool.cancel(); reservation.release()
                return
            }
            switch result {
            case .failure:
                spool.cancel(); reservation.release()
                self.replacement = nil
                self.completeUnchanged(self.skipped(.bodySkippedUnavailable))
            case .success:
                self.write(data, offset: offset + count, spool: spool, outcomes: outcomes, reservation: reservation)
            }
        }
    }

    // MARK: settlement

    private func skipped(_ code: RuleOutcomeCode) -> [RuleOutcome] {
        steps.map { RuleOutcome(ruleID: $0.ruleID, code: code, actionIndex: $0.actionIndex) }
    }

    private var encodingChoice: BodyEncodingChoice {
        effectiveHead.headers.contains { $0.name.lowercased() == "content-encoding" && BodyContentCodec.hasRealEncoding($0.value) }
            ? .removeEncoding : .unchanged
    }

    /// The original bytes continue as they arrived (original encoding and trailers).
    private func completeUnchanged(_ outcomes: [RuleOutcome]) {
        guard let original = collected else { assertionFailure("an unchanged completion needs the collected body"); return }
        collected = nil
        resolve()
        let descriptor = HTTPBodyDescriptor(length: original.size, complete: true, changed: false, trailers: original.trailers)
        completed(.init(continuation: .init(source: original, original: effectiveHead, descriptor: descriptor,
                                            bytesChanged: false, version: sourceVersion), outcomes: outcomes))
    }

    /// The rewritten plaintext replaces the original, which is given up.
    private func complete(rewritten source: ExactBodySource, outcomes: [RuleOutcome]) {
        guard let original = collected else {
            assertionFailure("a rewritten completion needs the collected body")
            source.cancel(); return
        }
        collected = nil
        original.cancel()
        resolve()
        let descriptor = HTTPBodyDescriptor(length: source.size, complete: true, changed: true,
                                            encodingChoice: encodingChoice, trailers: original.trailers)
        completed(.init(continuation: .init(source: source, original: effectiveHead, descriptor: descriptor,
                                            bytesChanged: true, version: sourceVersion), outcomes: outcomes))
    }

    private func fail(_ failure: BodyRewriteFailure) {
        guard phase != .resolved else { return }
        resolve()
        failed(failure, skipped(.rejected))
    }

    /// Releases what this gate owns. In-flight file and transform work keeps its own reservations
    /// and releases them when it settles.
    private func resolve() {
        phase = .resolved
        collector?.cancel(); collector = nil
        timer?.cancel(); timer = nil
        overallTimer?.cancel(); overallTimer = nil
        transform?.cancel(); transform = nil
        collected?.cancel(); collected = nil
        replacement?.cancel(); replacement = nil
    }
}
