import Foundation
import os

/// How many exchanges matched each rule's conditions, for the occurrence option ("only the k-th to
/// m-th hit"). Kept in memory, shared by every exchange; the owner resets a rule when it is saved or
/// when the user clears the counts. Locked; nothing else runs under the lock.
public final class RuleHitCounter: Sendable {
    private let counts = OSAllocatedUnfairLock(initialState: [UUID: Int]())
    /// The CONNECT point's hits, apart from the exchanges' so a CONNECT never shifts a rule's occurrence
    /// window at the requests inside it (R4 T7 ruling).
    private let connectCounts = OSAllocatedUnfairLock(initialState: [UUID: Int]())

    public init() {}

    /// Counts one hit and returns the rule's count including it, starting at 1.
    @discardableResult public func recordHit(_ id: UUID) -> Int {
        counts.withLock { counts in
            let count = counts[id, default: 0] + 1
            counts[id] = count
            return count
        }
    }

    public func count(_ id: UUID) -> Int { counts.withLock { $0[id] ?? 0 } }

    /// Counts one CONNECT-point hit and returns the rule's CONNECT count including it, starting at 1.
    @discardableResult public func recordConnectHit(_ id: UUID) -> Int {
        connectCounts.withLock { counts in
            let count = counts[id, default: 0] + 1
            counts[id] = count
            return count
        }
    }

    public func connectCount(_ id: UUID) -> Int { connectCounts.withLock { $0[id] ?? 0 } }

    public func reset(_ id: UUID) {
        counts.withLock { _ = $0.removeValue(forKey: id) }
        connectCounts.withLock { _ = $0.removeValue(forKey: id) }
    }

    public func resetAll() {
        counts.withLock { $0.removeAll() }
        connectCounts.withLock { $0.removeAll() }
    }

    /// Every rule with at least one hit.
    public func snapshot() -> [UUID: Int] { counts.withLock { $0 } }
}
