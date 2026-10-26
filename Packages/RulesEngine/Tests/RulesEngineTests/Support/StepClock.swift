import Foundation

@testable import RulesEngine

/// A monotonic clock that advances a fixed step on every read, so a 2 ms budget runs out on its own.
/// Tests hand `budget` to a private `PatternCache`; `PatternCache.shared` is never touched.
final class StepClock: @unchecked Sendable {  // guarded by `lock`
    private let lock = NSLock()
    private var now: Duration = .zero
    func read() -> Duration {
        lock.withLock {
            now += .milliseconds(1)
            return now
        }
    }
    var budget: RegexBudget {
        RegexBudget(maxDuration: .milliseconds(2), maxStrikes: 3, clock: { [self] in read() })
    }
}
