import Darwin
import FlowStore

/// One session-owned 32 KiB reservation, borrowed synchronously by both directions.
/// This mutable buffer is deliberately non-Sendable and must remain actor-confined.
public final class WebSocketDictionaryScratch {
    public enum AllocationError: Error { case invalidReservation, allocationFailed }
    private let reservation: WebSocketReservation
    private let buffer: UnsafeMutableRawPointer
    private var borrowed = false

    public convenience init(reservation: consuming WebSocketReservation) throws {
        try self.init(reservation: reservation, allocate: { malloc(32768) })
    }
    // Narrow fallible-allocation seam: successful allocations must be free-compatible.
    init(reservation: consuming WebSocketReservation, allocate: () -> UnsafeMutableRawPointer?) throws {
        guard reservation.category == .working, reservation.bytes == 32768 else {
            throw AllocationError.invalidReservation
        }
        guard let buffer = allocate() else { throw AllocationError.allocationFailed }
        self.buffer = buffer
        self.reservation = reservation
    }
    public func withBuffer<R>(_ body: (UnsafeMutableRawBufferPointer) throws -> R) rethrows -> R {
        precondition(!borrowed, "Dictionary scratch cannot be reentered")
        borrowed = true
        defer { borrowed = false }
        return try body(UnsafeMutableRawBufferPointer(start: buffer, count: 32768))
    }
    deinit { free(buffer) }
}
