import FlowStore
import Foundation
import NIOCore
import RulesEngine

/// Collects a request or response body whose rules have body conditions (D12), so the conditions can read it and
/// the message then continues with exactly these bytes (`ExchangeRuleContinuation.network(head:body:)`, or the
/// response's exact body).
/// The body goes through `BreakpointBodyCollector` into an exact spool; once complete it is read and
/// decoded in a `Task` (never on the event loop) and handed on with its `BodyPeek`.
///
/// Only created when `BodyPeekRules.classify` said `.collect`: a known length within
/// `conditionBodyBytes`. Deadlines: `rewriteSeconds` without a new chunk (as `ExchangeBodyRewriter`),
/// `conditionBodyTotalSeconds` (60 s) in all. Confined to `loop`; the decode task captures only Sendable values. No
/// callback fires after `abandon()` or after the gate resolved.
final class ExchangeBodyPeeker: ExchangeBodyGate {
    private enum Phase { case collecting, decoding, resolved }

    /// `BodyPeek.decode` with the run's limits; injectable so tests can observe where it runs.
    static let standardDecode: @Sendable (Data, [HeaderField], RulesLimits) -> BodyPeek = {
        BodyPeek.decode($0, headers: $1, limits: $2)
    }

    private let loop: EventLoop
    private let messageDirection: HTTPMessageDirection
    private let io: BodyFileIO
    private let limits: RulesLimits
    private let expectedLength: Int64
    private let headers: [HeaderField]
    private let decode: @Sendable (Data, [HeaderField], RulesLimits) -> BodyPeek
    private let changed: () -> Void
    private let completed: (ExactBodySource, BodyPeek) -> Void
    private let failed: (BodyRewriteFailure) -> Void

    private var phase = Phase.collecting
    private var collector: BreakpointBodyCollector?
    /// Body bytes taken from the client so far: once there are any, the request can only continue
    /// with the complete collected body.
    private(set) var received: Int64 = 0
    private(set) var receivedEnd = false
    private var timer: Scheduled<Void>?
    private var overallTimer: Scheduled<Void>?
    private var deadlineGeneration = 0
    private var collected: ExactBodySource?
    private var decoding: Task<Void, Never>?

    var direction: HTTPMessageDirection? { messageDirection }
    var isCollecting: Bool { phase == .collecting }
    var canRead: Bool { isCollecting && !receivedEnd && collector?.canRead == true }
    var timerCount: Int { loop.preconditionInEventLoop(); return timer == nil ? 0 : 1 }
    var overallTimerCount: Int { loop.preconditionInEventLoop(); return overallTimer == nil ? 0 : 1 }

    /// Throws `BodyRewriteFailure.tooLarge` for a length over `conditionBodyBytes` (the caller's
    /// `classify` already refuses it), or the spool's `OwnedFileError` when its budget cannot be
    /// reserved; nothing is held then.
    init(loop: EventLoop, io: BodyFileIO, limits: RulesLimits, expectedLength: Int64, headers: [HeaderField],
         direction: HTTPMessageDirection = .request,
         decode: @escaping @Sendable (Data, [HeaderField], RulesLimits) -> BodyPeek = ExchangeBodyPeeker.standardDecode,
         changed: @escaping () -> Void,
         completed: @escaping (_ collected: ExactBodySource, _ peek: BodyPeek) -> Void,
         failed: @escaping (BodyRewriteFailure) -> Void) throws {
        guard expectedLength <= Int64(limits.conditionBodyBytes) else { throw BodyRewriteFailure.tooLarge }
        self.loop = loop; self.io = io; self.limits = limits; self.messageDirection = direction
        self.expectedLength = expectedLength; self.headers = headers; self.decode = decode
        self.changed = changed; self.completed = completed; self.failed = failed
        collector = try BreakpointBodyCollector(expectedLength: expectedLength, io: io)
    }

    /// Arms the idle and the overall deadline, and lets the owner route queued parts.
    func start() {
        loop.preconditionInEventLoop()
        guard phase == .collecting, timer == nil else { return }
        armDeadline()
        overallTimer = loop.assumeIsolated().scheduleTask(in: .seconds(ExchangeBodyRewriter.deadlineSeconds(limits.conditionBodyTotalSeconds))) { [weak self] in
            guard let self, self.phase == .collecting else { return }
            self.overallTimer = nil
            self.fail(.timedOut)
        }
        changed()
    }

    private func armDeadline() {
        timer?.cancel()
        deadlineGeneration += 1
        let generation = deadlineGeneration
        timer = loop.assumeIsolated().scheduleTask(in: .seconds(ExchangeBodyRewriter.deadlineSeconds(limits.rewriteSeconds))) { [weak self] in
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
        received += count
        guard received <= expectedLength else {
            fail(.tooLarge)
            return loop.makeFailedFuture(OwnedFileError(.fileTooLarge))
        }
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
                self.phase = .decoding
                self.changed()
                // The owner may have reacted to `changed` by giving everything up.
                if self.phase == .decoding { self.beginDecode(source) }
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

    /// Reads and decodes the collected body in a task. The memory it needs (the wire bytes plus the
    /// decoded text, each up to the cap) is reserved first; without it, or when the read fails, the
    /// peek is unknown (`bodySkippedUnavailable`) and the collected body still continues.
    private func beginDecode(_ source: ExactBodySource) {
        let reservation: OwnedFileReservation
        do { reservation = try io.budgets.reserve(category: .editor, bytes: source.size + 2 * Int64(limits.conditionBodyBytes)) }
        catch { hand(.skipped(.bodySkippedUnavailable)); return }
        let headers = self.headers, limits = self.limits, decode = self.decode, size = source.size
        let promise = loop.makePromise(of: BodyPeek.self)
        decoding = promise.completeWithTask {
            var body = Data()
            body.reserveCapacity(Int(size))
            while Int64(body.count) < size {
                try Task.checkCancellation()
                let chunk = try await source.read(offset: Int64(body.count), maxBytes: 65_536)
                guard !chunk.isEmpty else { throw OwnedFileError(.shortRead) }
                body.append(chunk)
            }
            return decode(body, headers, limits)
        }
        promise.futureResult.assumeIsolated().whenComplete { [weak self] result in
            // The task has settled: nothing reads the source any more.
            reservation.release()
            guard let self, self.phase == .decoding else { return }
            self.decoding = nil
            switch result {
            case .success(let peek): self.hand(peek)
            case .failure: self.hand(.skipped(.bodySkippedUnavailable))
            }
        }
    }

    private func hand(_ peek: BodyPeek) {
        guard let source = collected else { assertionFailure("a peek hands on the collected body"); return }
        collected = nil
        resolve()
        completed(source, peek)
    }

    private func fail(_ failure: BodyRewriteFailure) {
        guard phase != .resolved else { return }
        resolve()
        failed(failure)
    }

    /// Releases what this gate owns. A decode in flight keeps its reservation until it settles.
    private func resolve() {
        phase = .resolved
        collector?.cancel(); collector = nil
        timer?.cancel(); timer = nil
        overallTimer?.cancel(); overallTimer = nil
        decoding?.cancel(); decoding = nil
        collected?.cancel(); collected = nil
    }
}
