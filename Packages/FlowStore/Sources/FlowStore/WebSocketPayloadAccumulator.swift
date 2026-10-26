import Foundation
import os

public struct WebSocketOwnedPayload: ~Copyable, Sendable {
    let cell: WebSocketPayloadAccumulator
    public let kind: WebSocketPayloadKind
    public let complete: Bool
    public let truncated: Bool
    init(cell: WebSocketPayloadAccumulator, kind: WebSocketPayloadKind, complete: Bool, truncated: Bool) {
        self.cell = cell; self.kind = kind; self.complete = complete; self.truncated = truncated
    }
    private var revokesOnDeinit = true
    deinit { if revokesOnDeinit { cell.forceRevoke() } }
    consuming func prepared() -> WebSocketStoredPayload? {
        guard let count = cell.handoffToStore() else { return nil }
        revokesOnDeinit = false
        return WebSocketStoredPayload(cell: cell, count: count, complete: complete, truncated: truncated)
    }
}

/// One live cell remains registered in FlowStore even after take(), until publication or revoke.
public final class WebSocketPayloadAccumulator: Sendable {
    private struct State {
        var bytes = Data()
        var charge: WebSocketCharge?
        var revoked = false
        var sealed = false
        var storeOwned = false
        var truncated = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    let token: WebSocketSessionToken
    let eventID: UInt64
    let epoch: UInt64
    let kind: WebSocketPayloadKind
    private let limit: Int
    private let budget: WebSocketMemoryBudget
    private let metadata: WebSocketCharge
    init(token: WebSocketSessionToken, eventID: UInt64, epoch: UInt64, kind: WebSocketPayloadKind,
         limit: Int, budget: WebSocketMemoryBudget, metadata: WebSocketCharge) {
        self.token = token; self.eventID = eventID; self.epoch = epoch; self.kind = kind
        self.limit = max(0, limit); self.budget = budget; self.metadata = metadata
    }
    public func append(_ bytes: Data, expectedEpoch: UInt64) -> Bool {
        guard expectedEpoch == epoch else { return false }
        let count: Int? = state.withLock { state in
            guard !state.revoked && !state.sealed else { return nil }
            return min(bytes.count, limit - state.bytes.count)
        }
        guard let count, let reservation = budget.reserve(category: .working, bytes: count) else { return false }
        var charge: WebSocketCharge? = reservation.consumeOwner()
        // No budget lock is held while the revocation/copy lock is acquired.
        return state.withLockUnchecked { state in
            guard !state.revoked && !state.sealed else { return false }
            let actual = min(count, limit - state.bytes.count)
            // Concurrent appends cannot leave spare charges. Retry without copying.
            guard actual == count else { return false }
            state.bytes.append(contentsOf: bytes.prefix(count))
            if let previous = state.charge { previous.absorb(charge!) } else { state.charge = charge }
            charge = nil // Do not leave a publishing thread holding a second charge owner.
            state.truncated = state.truncated || count < bytes.count
            return true
        }
    }
    public func take(kind: WebSocketPayloadKind, complete: Bool, truncated: Bool) -> WebSocketOwnedPayload? {
        let result: Bool? = state.withLock { state in
            guard !state.revoked && !state.sealed && kind == self.kind else { return nil }
            state.sealed = true
            return state.truncated || truncated
        }
        guard let result else { return nil }
        return WebSocketOwnedPayload(cell: self, kind: kind, complete: complete, truncated: result)
    }
    /// Cancel producer-owned bytes. Consuming Store handoff ends this handle's authority.
    public func revoke() { revoke(producerOnly: true) }
    func forceRevoke() { revoke(producerOnly: false) }
    private func revoke(producerOnly: Bool) {
        state.withLock { state in
            guard !producerOnly || !state.storeOwned else { return }
            // Keep disposal inside the cell's exclusion boundary: a second revoker must
            // not return while another thread holds a detached Data/charge disposal local.
            // This runs outside the Store lock. Budget release never calls a cell/store.
            state.revoked = true; state.bytes = Data(); state.charge = nil
        }
    }
    func transferToRetained(using budget: WebSocketMemoryBudget) -> Bool {
        guard budget === self.budget else { return false }
        let request: (Int, Bool)? = state.withLock { state in
            guard state.sealed && !state.revoked else { return nil }
            return (state.bytes.count, state.charge?.category == .retained)
        }
        guard let request else { return false }
        if request.1 { return true }
        guard let reservation = budget.reserve(category: .retained, bytes: request.0) else { return false }
        var destination: WebSocketCharge? = reservation.consumeOwner()
        return state.withLockUnchecked { state in
            guard !state.revoked else { return false }
            state.charge = destination // Release working charge before unlocking the cell.
            destination = nil // The registered cell is now the only retained-charge owner.
            return true
        }
    }
    var retainedRequirement: Int { state.withLock { $0.revoked || $0.charge?.category == .retained ? 0 : $0.bytes.count } }
    var retainedCount: Int { state.withLock { $0.revoked ? 0 : $0.bytes.count } }
    func handoffToStore() -> Int? {
        state.withLock { state in
            guard state.sealed && !state.revoked && !state.storeOwned, state.charge?.category == .retained else { return nil }
            // Serialize producer cancellation with consuming handoff, before admission.
            // Store force-revocation remains valid for pending, active and retiring cells.
            state.storeOwned = true
            return state.bytes.count
        }
    }
    func copyBytes(offset: Int, maxBytes: Int) -> (bytes: Data, total: Int)? {
        state.withLock { state in
            guard !state.revoked, offset >= 0, offset <= state.bytes.count else { return nil }
            let count = min(maxBytes, state.bytes.count - offset)
            let bytes = state.bytes.withUnsafeBytes { raw in
                count == 0 ? Data() : Data(bytes: raw.baseAddress!.advanced(by: offset), count: count)
            }
            return (bytes, state.bytes.count)
        }
    }
}

/// A reference to the same revocable cell, never a detached Data/charge alias.
struct WebSocketStoredPayload: Sendable {
    let cell: WebSocketPayloadAccumulator
    let count: Int
    let complete: Bool
    let truncated: Bool
}

public struct WebSocketEventBatch: ~Copyable, Sendable {
    public var metadata: WebSocketEventMetadata
    public let stamp: WebSocketCaptureStamp
    var application: WebSocketOwnedPayload?
    var wirePayload: WebSocketOwnedPayload?
    public init(metadata: WebSocketEventMetadata, stamp: WebSocketCaptureStamp,
                application: consuming WebSocketOwnedPayload? = nil, wirePayload: consuming WebSocketOwnedPayload? = nil) {
        self.metadata = metadata; self.stamp = stamp; self.application = application; self.wirePayload = wirePayload
    }
}
