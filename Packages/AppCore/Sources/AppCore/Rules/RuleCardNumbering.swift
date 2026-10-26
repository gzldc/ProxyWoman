import FlowStore
import Foundation
import RulesEngine

/// Numbers the outcomes of a rule by the card a person reads in the editor, not by the stored action index the engine
/// reports (one stored action can show as several cards). The document of a rule is built once per rule id and
/// revision and reused until either changes, so a list of results does not rebuild it on every render.
@MainActor public final class RuleCardNumbering {
    private struct Entry {
        var revision: UInt64
        var firstCards: [Int]
        var lastCards: [Int]
    }

    private var entries: [UUID: Entry] = [:]
    private var latestRevision: UInt64 = 0
    /// How many rules have a document kept (for tests).
    var cachedRuleCount: Int { entries.count }
    /// How many documents were built (for tests).
    private(set) var builds = 0

    public init() {}

    /// The 0-based card of `rule`'s stored action `stored` for an outcome of `code`; nil when there is no such rule or
    /// action (the caller keeps the stored number). Stop outcomes (`finalStop`, `skippedAfterFinal`) name the last card of
    /// the action, where the stop tick lives; every other outcome its first.
    public func index(rule: Rule?, revision: UInt64, stored: Int, code: RuleOutcomeCode) -> Int? {
        // A newer rules revision makes every older document unusable: forget them, so a deleted rule leaves nothing behind.
        if revision > latestRevision {
            latestRevision = revision
            entries = entries.filter { $0.value.revision == revision }
        }
        guard let rule else { return nil }
        let entry: Entry
        if let cached = entries[rule.id], cached.revision == revision {
            entry = cached
        } else {
            let document = RuleDocument(rule: rule)
            builds += 1
            entry = Entry(revision: revision, firstCards: document.storedActionOwners(), lastCards: document.storedActionLastCards())
            entries[rule.id] = entry
        }
        let cards = Self.stopCodes.contains(code) ? entry.lastCards : entry.firstCards
        return cards.indices.contains(stored) ? cards[stored] : nil
    }

    private static let stopCodes: Set<RuleOutcomeCode> = [.finalStop, .skippedAfterFinal]
}
