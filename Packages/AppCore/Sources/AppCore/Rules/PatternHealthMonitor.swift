import Foundation
import Observation
import RulesEngine

/// Tells the windows when a regular expression was switched off by its circuit breaker, so a
/// rule or an Allow/Block entry that silently stopped matching is marked in the list. The
/// revision changes on every trip; views that read `isDisabled` while building their body update
/// when it does. Saving a rule re-enables its patterns and changes the list itself.
@MainActor @Observable public final class PatternHealthMonitor {
    public private(set) var revision = 0
    @ObservationIgnored private let cache: PatternCache

    public init(cache: PatternCache = .shared) {
        self.cache = cache
        // The observer lives as long as the cache; `weak self` lets this monitor go first.
        cache.addDisableObserver { [weak self] in
            Task { @MainActor in self?.revision += 1 }
        }
    }

    /// True when a regular expression of `matcher` is switched off.
    public func isDisabled(_ matcher: RuleMatcher) -> Bool {
        _ = revision  // registers the read with Observation
        return matcher.hasDisabledPattern(in: cache)
    }

    /// True when a regular expression in one of the rule's condition rows is switched off.
    public func isDisabled(_ rule: Rule) -> Bool {
        _ = revision  // registers the read with Observation
        return rule.conditions.rows.contains { $0.legacyMatcher?.hasDisabledPattern(in: cache) ?? false }
    }
}
