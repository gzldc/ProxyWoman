import Foundation
import FlowStore
import os

/// Reservation and buffer ownership remain together through queue and consumer lifetime.
final class ObservationChunkStorage: Sendable {
    let bytes: Data
    let payload: WebSocketReservation
    let metadata: WebSocketReservation
    let stamp: WebSocketCaptureStamp
    let direction: WebSocketDirection
    let observedAt: Date
    let monotonic: UInt64
    let baseOffset: UInt32
    init(bytes: Data, payload: consuming WebSocketReservation, metadata: consuming WebSocketReservation,
         stamp: WebSocketCaptureStamp, direction: WebSocketDirection, observedAt: Date, monotonic: UInt64, baseOffset: UInt32) {
        self.bytes = bytes; self.payload = payload; self.metadata = metadata; self.stamp = stamp
        self.direction = direction; self.observedAt = observedAt; self.monotonic = monotonic; self.baseOffset = baseOffset
    }
}
struct ObservationChunk: ~Copyable, Sendable {
    let sequence: UInt64
    let storage: ObservationChunkStorage
}
enum ObservationInput: ~Copyable, Sendable {
    case chunk(ObservationChunk)
    case eof(WebSocketTransportEnd)
}
struct ObservationReadPermit: ~Copyable {
    fileprivate let mailbox: ObservationMailbox
    fileprivate let bytes: Int
    fileprivate let chunks: Int
    fileprivate var committed = false
    deinit { if !committed { mailbox.returnPreparation(bytes: bytes) } }
}
struct PreparedObservationRead: ~Copyable {
    var permit: ObservationReadPermit
    let chunks: [ObservationChunkStorage]
    init(permit: consuming ObservationReadPermit, chunks: [ObservationChunkStorage]) { self.permit = permit; self.chunks = chunks }
}

/// M never calls Budget/Store/entry gate, nor executes a continuation or user callback.
/// Queue ownership is extracted before destruction; preparing + queued + in-flight share cap.
final class ObservationMailbox: Sendable {
    private struct End: Sendable { let value: WebSocketTransportEnd; let after: UInt64; var delivered = false }
    private struct State: Sendable {
        var queue: [(UInt64, ObservationChunkStorage)] = []
        var bytes = 0
        var committed: UInt64 = 0
        var consumed: UInt64 = 0
        var inFlight: (sequence: UInt64, bytes: Int)?
        var cancelled = false
        var wakePending = false
        var epoch: UInt64 = 0
        var clientEnd: End?
        var serverEnd: End?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let envelope: WebSocketReservation?
    private let limit: Int
    let wakes: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    init(limits: WebSocketLimits, envelope: consuming WebSocketReservation? = nil) {
        self.envelope = envelope
        limit = max(0, limits.sessionMailboxBytes)
        (wakes, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }
    var hasDeliveredBothEnds: Bool { state.withLock { $0.clientEnd?.delivered == true && $0.serverEnd?.delivered == true } }
    var isCancelled: Bool { state.withLock { $0.cancelled } }
    var heldBytes: Int { state.withLock { $0.bytes } }
    var isFinished: Bool { state.withLock { $0.cancelled || ($0.clientEnd?.delivered == true && $0.serverEnd?.delivered == true) } }
    func tryReserveRead(byteCount: Int, chunkCount: Int) -> ObservationReadPermit? {
        guard byteCount > 0 else { return nil }
        let admitted = state.withLock { state in
            guard !state.cancelled, chunkCount > 0, byteCount <= limit - state.bytes,
                  UInt64(chunkCount) <= UInt64.max - state.committed else { state.cancelled = true; return false }
            state.bytes += byteCount
            return true
        }
        // The entry caller performs queue extraction/cancellation after leaving E.
        if !admitted { return nil }
        return ObservationReadPermit(mailbox: self, bytes: byteCount, chunks: chunkCount)
    }
    fileprivate func returnPreparation(bytes: Int) { state.withLock { $0.bytes -= bytes } }
    func abandonRead(_ permit: consuming ObservationReadPermit) { _ = consume permit }
    func publishRead(_ read: consuming PreparedObservationRead) -> Bool {
        // Retain the original array until after unlocking, including a failed publication.
        let chunks = read.chunks
        let count = read.permit.chunks
        let accepted = state.withLock { state in
            guard !state.cancelled, chunks.count == count else { return false }
            for chunk in chunks {
                state.committed += 1
                state.queue.append((state.committed, chunk))
            }
            return true
        }
        if accepted { read.permit.committed = true }
        return accepted
    }
    func markTransportEnded(_ end: WebSocketTransportEnd) {
        state.withLock { state in
            let record = End(value: end, after: state.committed)
            switch end.direction {
            case .clientToServer: if state.clientEnd == nil { state.clientEnd = record }
            case .serverToClient: if state.serverEnd == nil { state.serverEnd = record }
            }
        }
    }
    func take() -> ObservationInput? {
        let result = state.withLock { state -> (UInt64, ObservationChunkStorage?, WebSocketTransportEnd?) in
            guard !state.cancelled, state.inFlight == nil else { return (0, nil, nil) }
            let a = state.clientEnd, b = state.serverEnd
            if let a, !a.delivered, a.after <= state.consumed,
               b == nil || b!.delivered || b!.after > state.consumed || a.after <= b!.after {
                state.clientEnd?.delivered = true; return (0, nil, a.value)
            }
            if let b, !b.delivered, b.after <= state.consumed {
                state.serverEnd?.delivered = true; return (0, nil, b.value)
            }
            guard !state.queue.isEmpty else { return (0, nil, nil) }
            let (sequence, storage) = state.queue.removeFirst()
            state.inFlight = (sequence, storage.bytes.count)
            return (sequence, storage, nil)
        }
        if let storage = result.1 { return .chunk(.init(sequence: result.0, storage: storage)) }
        if let end = result.2 { return .eof(end) }
        return nil
    }
    /// Consumer must release its actual chunk/storage first, then acknowledge its sequence.
    func finishChunk(sequence: UInt64) {
        state.withLock { state in
            guard let current = state.inFlight, current.sequence == sequence else { return }
            state.bytes -= current.bytes; state.inFlight = nil; state.consumed = sequence
        }
    }
    func requestWakeup() -> Bool {
        state.withLock { state in
            guard !state.wakePending else { return false }
            state.wakePending = true; return true
        }
    }
    func signal() { if requestWakeup() { continuation.yield(()) } }
    func finishDrain() -> Bool {
        state.withLock { state in
            state.wakePending = false
            let ready = state.cancelled || !state.queue.isEmpty
                || (state.clientEnd.map { !$0.delivered && $0.after <= state.consumed } ?? false)
                || (state.serverEnd.map { !$0.delivered && $0.after <= state.consumed } ?? false)
            if ready { state.wakePending = true }
            return ready
        }
    }
    func cancel() {
        let removed = state.withLock { state -> [(UInt64, ObservationChunkStorage)] in
            state.cancelled = true
            let removed = state.queue; state.queue.removeAll()
            for (_, chunk) in removed { state.bytes -= chunk.bytes.count }
            return removed
        }
        withExtendedLifetime(removed) {}
    }
    func recordingChanged(epoch: UInt64) { state.withLock { $0.epoch = max($0.epoch, epoch) }; signal() }
    /// Only the supervisor calls this after Task.value; abort never fabricates or loses EOF.
    func claimRemainingEnds() -> [WebSocketTransportEnd] {
        state.withLock { state in
            var ends: [WebSocketTransportEnd] = []
            if let end = state.clientEnd, !end.delivered { ends.append(end.value); state.clientEnd?.delivered = true }
            if let end = state.serverEnd, !end.delivered { ends.append(end.value); state.serverEnd?.delivered = true }
            return ends
        }
    }
    func finishWakeStream() { continuation.finish() }
}
