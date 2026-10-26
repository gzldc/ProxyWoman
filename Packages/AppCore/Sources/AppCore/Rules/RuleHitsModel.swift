import Foundation
import Observation
import RulesEngine

/// Hit counts shown in the rules window. The model reads through injected closures; the view decides how often
/// to call `refresh`.
@MainActor @Observable public final class RuleHitsModel {
    public private(set) var counts: [UUID: Int] = [:]
    @ObservationIgnored private let count: @Sendable (UUID) -> Int
    @ObservationIgnored private let reset: @Sendable (UUID) -> Void

    public init(count: @escaping @Sendable (UUID) -> Int, reset: @escaping @Sendable (UUID) -> Void) {
        self.count = count
        self.reset = reset
    }

    public func refresh(ids: [UUID]) {
        var next: [UUID: Int] = [:]
        next.reserveCapacity(ids.count)
        for id in ids { next[id] = count(id) }
        if next != counts { counts = next }
    }

    /// Sum over every rule in the group's subtree; ids never read count as 0.
    public func total(for group: UUID, in tree: RuleTree) -> Int {
        tree.ruleIDs(inGroup: group).reduce(0) { $0 + (counts[$1] ?? 0) }
    }

    public func clearAll(ids: [UUID]) {
        for id in ids { reset(id) }
        counts = Dictionary(uniqueKeysWithValues: ids.map { ($0, 0) })
    }
}
