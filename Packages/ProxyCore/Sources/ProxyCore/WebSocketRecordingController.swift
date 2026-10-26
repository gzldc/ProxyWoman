import FlowStore
import Foundation
import os

/// C serializes revision admission. Store invokes no recording callback under its own lock.
public final class WebSocketRecordingController: Sendable {
    private final class WeakHandle: Sendable {
        private struct Storage { weak var value: ObservationHandle? }
        private let state: OSAllocatedUnfairLock<Storage>
        var value: ObservationHandle? { state.withLock { $0.value } }
        init(_ value: ObservationHandle) { state = .init(initialState: Storage(value: value)) }
    }
    private struct State {
        var revision: UInt64 = 0
        var handles: [UUID: WeakHandle] = [:]
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let store: FlowStore
    // Payload-free test seam run immediately before the Store call; nil in production.
    private let beforeStoreCall: (@Sendable (UInt64) -> Void)?
    public convenience init(store: FlowStore) { self.init(store: store, beforeStoreCall: nil) }
    init(store: FlowStore, beforeStoreCall: (@Sendable (UInt64) -> Void)?) { self.store = store; self.beforeStoreCall = beforeStoreCall }
    /// C admits the revision; the Store call (a full session scan plus, for Pause, the export
    /// barrier) runs outside C. Order is still preserved: the Store applies a revision only if
    /// it is newer than the last one it applied, so a stale call reaching it late is ignored.
    public func setEnabled(_ enabled: Bool, revision: UInt64) {
        let admitted = state.withLock { state in
            guard revision > state.revision else { return false }
            state.revision = revision; return true
        }
        guard admitted else { return }
        beforeStoreCall?(revision)
        store.setWebSocketRecording(enabled: enabled, revision: revision)
        // Snapshot after the Store call: a handle registered meanwhile read an older epoch.
        let handles = state.withLock { Array($0.handles.values) }
        let epoch = store.webSocketRecordingState().epoch
        for handle in handles { handle.value?.recordingChanged(epoch: epoch) }
    }
    func register(_ handle: ObservationHandle) {
        state.withLock { $0.handles[handle.token.sessionID] = WeakHandle(handle) }
        handle.recordingChanged(epoch: store.webSocketRecordingState().epoch)
    }
    func unregister(_ token: WebSocketSessionToken) { _ = state.withLock { $0.handles.removeValue(forKey: token.sessionID) } }
}
