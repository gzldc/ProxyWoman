import Foundation
import os

/// Holds the current `TrafficPolicy` for the proxy. The lock only guards value copies.
public final class TrafficPolicyProvider: Sendable {
    private struct State {
        var policy: TrafficPolicy
        var revision: UInt64
    }

    private let state: OSAllocatedUnfairLock<State>
    private let patternCache: PatternCache

    public init(_ initial: TrafficPolicy = TrafficPolicy(), patternCache: PatternCache = .shared) {
        state = OSAllocatedUnfairLock(initialState: State(policy: initial, revision: 1))
        self.patternCache = patternCache
    }

    public func current() -> TrafficPolicy { state.withLock { $0.policy } }

    /// Starts at 1; every `publish` adds 1.
    public var revision: UInt64 { state.withLock { $0.revision } }

    @discardableResult
    public func publish(_ next: TrafficPolicy) -> UInt64 {
        // New or changed entries get their patterns compiled and their regex breakers reset, like a
        // saved rule; entries that did not change keep their circuit breaker as it is.
        let previous = current()
        for (old, new) in [(previous.allowEntries, next.allowEntries), (previous.blockEntries, next.blockEntries)] {
            let known = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for entry in new where entry.enabled {
                if let existing = known[entry.id], existing.enabled, existing.matcher == entry.matcher { continue }
                entry.matcher.preparePatterns(in: patternCache)
            }
        }
        return state.withLock { state in
            state.policy = next
            state.revision += 1
            return state.revision
        }
    }
}
