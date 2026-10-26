import Foundation
import FlowStore
import os

public enum WebSocketWorkDecision: Sendable, Equatable { case allowed, stopSession, stopDirection }

/// Store-shared token buckets. Failed admission never queues work or removes shared history.
public final class WebSocketWorkLimiter: Sendable {
    let limits: WebSocketLimits
    private let budget: WebSocketMemoryBudget
    private let now: @Sendable () -> UInt64
    private let state: OSAllocatedUnfairLock<State>
    private final class Metadata: Sendable {
        let reservation: WebSocketReservation
        init(_ reservation: consuming WebSocketReservation) { self.reservation = reservation }
    }
    private struct Bucket: Sendable {
        let rate: Int
        var tokens: Int
        var last: UInt64
        var fractional: UInt64 = 0
        init(_ rate: Int, _ time: UInt64) { self.rate = max(0, rate); tokens = max(0, rate); last = time }
        mutating func refill(_ time: UInt64) {
            guard time > last else { return }
            let elapsed = time - last; last = time
            if elapsed >= 1_000_000_000 { tokens = rate; fractional = 0; return }
            let product = UInt64(rate).multipliedFullWidth(by: elapsed)
            let quotient = UInt64(1_000_000_000).dividingFullWidth(product)
            let remainder = quotient.remainder + fractional
            let added = Int(quotient.quotient + remainder / 1_000_000_000)
            fractional = remainder % 1_000_000_000
            if added >= rate - tokens { tokens = rate; fractional = 0 } else { tokens += added }
        }
    }
    private struct Entry: Sendable {
        let metadata: Metadata
        var frames: Bucket
        var expanded: Bucket
        var native: Bucket
    }
    private struct State: Sendable {
        var entries: [UUID: Entry] = [:]
        var expanded: Bucket
        var native: Bucket
    }
    public init(limits: WebSocketLimits, budget: WebSocketMemoryBudget,
                now: @escaping @Sendable () -> UInt64) {
        self.limits = limits; self.budget = budget; self.now = now
        let time = now()
        state = OSAllocatedUnfairLock(initialState: State(expanded: Bucket(limits.storeExpandedPerSecond, time),
                                                        native: Bucket(limits.storeNativePerSecond, time)))
    }
    public func admit(session: UUID, frames: Int, expandedBytes: Int, nativeOperations: Int) -> WebSocketWorkDecision {
        guard frames >= 0, expandedBytes >= 0, nativeOperations >= 0 else { return .stopSession }
        let time = now()
        // Budget and limiter locks are never nested. A rejected race candidate dies outside the lock.
        let needsEntry = state.withLock { $0.entries[session] == nil }
        let candidate: Metadata?
        if needsEntry, let reservation = budget.reserve(category: .metadata, bytes: 512) {
            candidate = Metadata(reservation)
        } else { candidate = nil }
        return withExtendedLifetime(candidate) {
            state.withLock { state in
                if state.entries[session] == nil {
                    guard state.entries.count < max(0, limits.observingSessions), let candidate else { return .stopSession }
                    state.entries[session] = Entry(metadata: candidate, frames: Bucket(limits.sessionFramesPerSecond, time),
                        expanded: Bucket(limits.sessionExpandedPerSecond, time), native: Bucket(limits.sessionNativePerSecond, time))
                }
                var entry = state.entries[session]!
                entry.frames.refill(time); entry.expanded.refill(time); entry.native.refill(time)
                state.expanded.refill(time); state.native.refill(time)
                defer { state.entries[session] = entry }
                guard frames <= entry.frames.tokens else { return .stopSession }
                guard expandedBytes <= entry.expanded.tokens, expandedBytes <= state.expanded.tokens,
                      nativeOperations <= entry.native.tokens, nativeOperations <= state.native.tokens else { return .stopDirection }
                entry.frames.tokens -= frames; entry.expanded.tokens -= expandedBytes; entry.native.tokens -= nativeOperations
                state.expanded.tokens -= expandedBytes; state.native.tokens -= nativeOperations
                return .allowed
            }
        }
    }
    public func remove(session: UUID) {
        let removed = state.withLock { $0.entries.removeValue(forKey: session) }
        withExtendedLifetime(removed) {}
    }
}
