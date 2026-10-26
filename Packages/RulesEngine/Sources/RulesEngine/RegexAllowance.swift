import os

/// The regular-expression time one exchange may spend in total (8 ms by default), shared by every
/// row of every rule at every evaluation point. Locked; the lock is never held while a match runs.
public final class RegexAllowance: Sendable {
    private let total: Duration
    private let clock: @Sendable () -> Duration
    private let used = OSAllocatedUnfairLock(initialState: Duration.zero)

    public init(
        total: Duration = .milliseconds(8), clock: @escaping @Sendable () -> Duration = RegexBudget.monotonicNow
    ) {
        self.total = total
        self.clock = clock
    }

    /// What is left, never negative.
    public var remaining: Duration { used.withLock { Swift.max(total - $0, .zero) } }

    func now() -> Duration { clock() }

    func consume(_ elapsed: Duration) {
        guard elapsed > .zero else { return }
        used.withLock { $0 += elapsed }
    }
}
