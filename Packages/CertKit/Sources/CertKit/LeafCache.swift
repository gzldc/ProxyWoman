import Foundation
import os

/// A leaf certificate plus the private key it was issued for, ready to hand to a TLS stack.
public struct LeafIdentity: Sendable {
    public var certificateDER: [UInt8]
    /// PKCS#8/SEC1 DER as produced by `P256.Signing.PrivateKey.derRepresentation`.
    public var privateKeyDER: [UInt8]

    public init(certificateDER: [UInt8], privateKeyDER: [UInt8]) {
        self.certificateDER = certificateDER
        self.privateKeyDER = privateKeyDER
    }
}

/// Thread-safe least-recently-used cache of issued leaf identities, keyed by host.
final class LeafCache: Sendable {
    private struct Entry {
        var identity: LeafIdentity
        var lastUsed: UInt64
    }

    private struct State {
        var entries: [String: Entry] = [:]
        var tick: UInt64 = 0
    }

    private let capacity: Int
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(capacity: Int = 1000) {
        self.capacity = max(1, capacity)
    }

    var count: Int { state.withLock { $0.entries.count } }

    /// Returns the cached identity (marking it most recently used), or nil.
    func get(_ host: String) -> LeafIdentity? {
        state.withLock { state in
            guard var entry = state.entries[host] else { return nil }
            state.tick += 1
            entry.lastUsed = state.tick
            state.entries[host] = entry
            return entry.identity
        }
    }

    /// Stores `identity` unless `host` is already cached; returns whichever identity is cached
    /// afterwards, so callers that raced to issue the same host converge on one certificate.
    func insertIfAbsent(_ identity: LeafIdentity, for host: String) -> LeafIdentity {
        state.withLock { state in
            state.tick += 1
            if var existing = state.entries[host] {
                existing.lastUsed = state.tick
                state.entries[host] = existing
                return existing.identity
            }
            state.entries[host] = Entry(identity: identity, lastUsed: state.tick)
            if state.entries.count > capacity,
                let oldest = state.entries.min(by: { $0.value.lastUsed < $1.value.lastUsed })?.key
            {
                state.entries.removeValue(forKey: oldest)
            }
            return identity
        }
    }
}
