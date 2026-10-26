import FlowStore
import Foundation
import RulesEngine
import os

/// "How many captured flows would these conditions match?" for an editor that is being typed into (D21).
/// Each call debounces, then reads the newest flows from the store and judges them on a background task, so
/// the main actor never waits for it. A newer call cancels the one before; a cancelled task throws
/// `CancellationError` and never yields a report.
public struct LiveMatchService: Sendable {
    /// The flows a count looks at.
    public static let flowLimit = 5000

    private let debounce: Duration
    private let sleep: @Sendable (Duration) async throws -> Void
    private let current = Current()
    /// Test probe: called before each evaluation pass of `updates` (not for skipped ticks).
    var evaluationProbe: (@Sendable () -> Void)?

    /// Waits on the real clock. Deliberately an overload rather than a default argument: a default-argument
    /// `@Sendable async` closure, called from the App's debug build, aborted in `updates` with "freed pointer was
    /// not the last allocation".
    public init(debounce: Duration = .milliseconds(300)) {
        self.init(debounce: debounce, sleep: { try await Task.sleep(for: $0) })
    }

    public init(debounce: Duration = .milliseconds(300), sleep: @escaping @Sendable (Duration) async throws -> Void) {
        self.debounce = debounce
        self.sleep = sleep
    }

    /// The returned task can be cancelled; calling again cancels the previous one.
    public func count(_ conditions: ConditionGroup, store: FlowStore) -> Task<LiveMatchReport, Error> {
        let debounce = debounce
        let sleep = sleep
        let task = Task<LiveMatchReport, Error> {
            try await sleep(debounce)
            try Task.checkCancellation()
            let report = Self.evaluate(conditions, store: store)
            try Task.checkCancellation()
            return report
        }
        current.replace(with: { task.cancel() })
        return task
    }

    /// A count that keeps itself fresh while the editor is open: sessions in flight finish, pause at a breakpoint
    /// or resume, and new ones arrive. It counts once after the debounce, then once per `interval`, and yields only
    /// when the report differs. A tick whose store has not changed since the last pass (`FlowStore.changeStamp`) skips the
    /// pass, so a quiet store costs one lock acquisition a second. It reads the store
    /// by polling on purpose: `FlowStore.changes()` has a single subscriber, which belongs to the list. Ending
    /// the stream (or cancelling the consuming task) stops it.
    public func updates(
        _ conditions: ConditionGroup, store: FlowStore, interval: Duration = .seconds(1)
    ) -> AsyncStream<LiveMatchReport> {
        let debounce = debounce
        let sleep = sleep
        let probe = evaluationProbe
        let (stream, continuation) = AsyncStream<LiveMatchReport>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let task = Task {
            var last: LiveMatchReport?
            var lastStamp: FlowChangeStamp?
            var wait = debounce
            while !Task.isCancelled {
                do { try await sleep(wait) } catch { break }
                wait = interval
                // Read before the flows, so a change racing the pass shows up as a new stamp on the next tick.
                let stamp = store.changeStamp
                if stamp == lastStamp { continue }
                lastStamp = stamp
                probe?()
                let report = Self.evaluate(conditions, store: store)
                if Task.isCancelled { break }
                if report != last {
                    last = report
                    continuation.yield(report)
                }
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    /// The newest flows judged together with the sessions whose WebSocket is still open (an upgrade's HTTP exchange
    /// ends with its 101, but the session it opened has not ended).
    private static func evaluate(_ conditions: ConditionGroup, store: FlowStore) -> LiveMatchReport {
        let open = store.openWebSocketFlowIDs()
        let flows = store.recentFlows(limit: flowLimit)
        return LiveMatcher.evaluate(
            conditions, over: flows, openWebSocketFlowIDs: open, isCancelled: { Task.isCancelled })
    }

    /// Cancels whatever count is pending or running.
    public func cancel() { current.replace(with: nil) }

    /// The last call's cancel handle; shared by every copy of the service.
    private final class Current: Sendable {
        private let cancelLast = OSAllocatedUnfairLock<(@Sendable () -> Void)?>(initialState: nil)

        func replace(with next: (@Sendable () -> Void)?) {
            cancelLast.withLock { last in
                last?()
                last = next
            }
        }
    }
}
