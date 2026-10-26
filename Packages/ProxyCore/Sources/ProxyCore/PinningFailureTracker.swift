import Foundation
import os

/// Evidence from a failed client-side TLS handshake, after observing a framed ClientHello.
enum PinningFailureEvidence: Sendable, Equatable {
    case certificateRejected
    case interrupted
    case unrelated
}

/// Shared by a server's connections. The lock protects all pending interruption timestamps;
/// successful handshakes and unrelated failures break a host's sequence.
final class PinningFailureTracker: Sendable {
    private let window: TimeInterval
    private let capacity: Int
    private let interruptions = OSAllocatedUnfairLock<[String: TimeInterval]>(initialState: [:])

    init(window: TimeInterval = 30, capacity: Int = 1024) {
        self.window = max(0, window)
        self.capacity = max(1, capacity)
    }

    /// `now` is monotonic uptime, never a wall-clock date. Returns true only when the evidence
    /// suffices for automatic passthrough; diagnostics are recorded independently by the caller.
    func recordFailure(host: String, evidence: PinningFailureEvidence, now: TimeInterval) -> Bool {
        let host = HostPattern.normalize(host)
        guard !host.isEmpty else { return false }
        return interruptions.withLock { pending in
            pending = pending.filter { now >= $0.value && now - $0.value <= window }
            switch evidence {
            case .unrelated:
                pending.removeValue(forKey: host)
                return false
            case .certificateRejected:
                pending.removeValue(forKey: host)
                return true
            case .interrupted:
                if pending.removeValue(forKey: host) != nil { return true }
                if pending.count >= capacity,
                   let oldest = pending.min(by: { $0.value < $1.value })?.key {
                    pending.removeValue(forKey: oldest)
                }
                pending[host] = now
                return false
            }
        }
    }

    func recordSuccess(host: String) {
        interruptions.withLock { pending in
            _ = pending.removeValue(forKey: HostPattern.normalize(host))
        }
    }
}
