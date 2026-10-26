import os

public enum WebSocketMemoryCategory: String, Codable, Sendable, CaseIterable {
    case retained, working, mailbox, native, metadata
}

/// Unique public ownership. Internal references are never exposed to clients.
public struct WebSocketReservation: ~Copyable, Sendable {
    let owner: WebSocketCharge
    public var category: WebSocketMemoryCategory { owner.category }
    public var bytes: Int { owner.bytes }
    init(_ owner: WebSocketCharge) { self.owner = owner }
    public consuming func release() {}
    consuming func consumeOwner() -> WebSocketCharge { owner }
}

/// Mutations only occur under the owning accumulator's lock, before ownership is moved.
/// A charge has exactly one resource owner, despite the implementation's reference wrapper.
final class WebSocketCharge: @unchecked Sendable {
    let budget: WebSocketMemoryBudget
    let category: WebSocketMemoryCategory
    var bytes: Int
    init(budget: WebSocketMemoryBudget, category: WebSocketMemoryCategory, bytes: Int) {
        self.budget = budget; self.category = category; self.bytes = bytes
    }
    func absorb(_ other: WebSocketCharge) {
        precondition(budget === other.budget && category == other.category)
        bytes += other.bytes; other.bytes = 0
    }
    deinit { if bytes > 0 { budget.release(category: category, bytes: bytes) } }
}

public final class WebSocketMemoryBudget: Sendable {
    private let caps: [WebSocketMemoryCategory: Int]
    private let used = OSAllocatedUnfairLock(initialState: [WebSocketMemoryCategory: Int]())
    public init(limits: WebSocketLimits = .init()) {
        caps = [.retained: max(0, limits.retainedBytes), .working: max(0, limits.workingBytes),
                .mailbox: max(0, limits.mailboxBytes), .native: max(0, limits.nativeBytes), .metadata: max(0, limits.metadataBytes)]
    }
    public func usedBytes(category: WebSocketMemoryCategory) -> Int { used.withLock { $0[category, default: 0] } }
    public func reserve(category: WebSocketMemoryCategory, bytes: Int) -> WebSocketReservation? {
        guard bytes >= 0 else { return nil }
        let accepted = used.withLock { used in
            let count = used[category, default: 0]
            guard bytes <= caps[category, default: 0] - count else { return false }
            used[category] = count + bytes
            return true
        }
        return accepted ? WebSocketReservation(WebSocketCharge(budget: self, category: category, bytes: bytes)) : nil
    }
    fileprivate func release(category: WebSocketMemoryCategory, bytes: Int) {
        used.withLock { used in
            precondition(bytes >= 0 && bytes <= used[category, default: 0])
            used[category, default: 0] -= bytes
        }
    }
    public func reserveHandshakeMetadata(headCount: Int, headerFieldCount: Int, scalarStringCount: Int,
                                         containerCount: Int, utf8Bytes: Int) -> WebSocketReservation? {
        guard let cost = Self.handshakeCost(headCount: headCount, headerFieldCount: headerFieldCount,
            scalarStringCount: scalarStringCount, containerCount: containerCount, utf8Bytes: utf8Bytes) else { return nil }
        return reserve(category: .metadata, bytes: cost)
    }
    static func handshakeCost(headCount: Int, headerFieldCount: Int, scalarStringCount: Int, containerCount: Int, utf8Bytes: Int) -> Int? {
        var total = 0
        for (count, unit) in [(headCount,512), (headerFieldCount,128), (scalarStringCount,64), (containerCount,64), (utf8Bytes,2)] {
            guard count >= 0 else { return nil }
            let (cost, overflow) = count.multipliedReportingOverflow(by: unit)
            let (sum, overflow2) = total.addingReportingOverflow(cost)
            guard !overflow && !overflow2 else { return nil }; total = sum
        }
        let (rounded, overflow) = total.addingReportingOverflow(63)
        return overflow ? nil : rounded / 64 * 64
    }
    public func transferToRetained(_ payload: consuming WebSocketOwnedPayload) -> WebSocketOwnedPayload? {
        guard payload.cell.transferToRetained(using: self) else { payload.cell.forceRevoke(); return nil }
        return payload
    }
}
