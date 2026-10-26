import Foundation
import RulesEngine

/// Memory admitted for body bytes held by open breakpoint editors: each loaded representation
/// (raw bytes, decoded bytes) is charged once for as long as an editor keeps it. A body larger
/// than `perEditorBytes` is never made editable. This bounds what editors load; it is not a
/// process memory limit.
@MainActor public final class HTTPEditorMemoryBudget {
    public let totalBytes: Int
    public let perEditorBytes: Int
    public private(set) var reservedBytes = 0
    /// The most ever reserved at once.
    public private(set) var peakReservedBytes = 0

    public init(totalBytes: Int, perEditorBytes: Int) {
        self.totalBytes = max(0, totalBytes)
        self.perEditorBytes = max(0, perEditorBytes)
    }

    /// 32 MiB for all editors, 8 MiB per editor by default (`RulesLimits`).
    public convenience init(limits: RulesLimits) {
        self.init(totalBytes: limits.editorMemoryBytes, perEditorBytes: limits.editorBodyBytes)
    }

    /// Nil when `bytes` would exceed the total.
    public func reserve(bytes: Int) -> HTTPEditorReservation? {
        guard bytes >= 0, bytes <= totalBytes - reservedBytes else { return nil }
        reservedBytes += bytes
        peakReservedBytes = max(peakReservedBytes, reservedBytes)
        return HTTPEditorReservation(budget: self, bytes: bytes)
    }

    fileprivate func reserveMore(_ bytes: Int) -> Bool {
        guard bytes <= totalBytes - reservedBytes else { return false }
        reservedBytes += bytes
        peakReservedBytes = max(peakReservedBytes, reservedBytes)
        return true
    }

    fileprivate func give(back bytes: Int) {
        reservedBytes -= bytes
    }
}

/// One editor's share of the budget; released once.
@MainActor public final class HTTPEditorReservation {
    private weak var budget: HTTPEditorMemoryBudget?
    public private(set) var bytes: Int

    fileprivate init(budget: HTTPEditorMemoryBudget, bytes: Int) {
        self.budget = budget
        self.bytes = bytes
    }

    /// Adds `extra` bytes to this reservation; false (nothing changed) when the total would be exceeded.
    public func grow(by extra: Int) -> Bool {
        guard let budget, extra >= 0 else { return false }
        guard budget.reserveMore(extra) else { return false }
        bytes += extra
        return true
    }

    /// Gives back what is no longer held, keeping `count` bytes.
    public func shrink(to count: Int) {
        guard let budget, count >= 0, count < bytes else { return }
        budget.give(back: bytes - count)
        bytes = count
    }

    public func release() {
        guard let budget else { return }
        budget.give(back: bytes)
        self.budget = nil
        bytes = 0
    }
}
