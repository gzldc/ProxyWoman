import Foundation
import os

/// The published rule snapshot. `current()` only copies an immutable reference under a short lock:
/// no file I/O, encoding or UI work ever runs while it is held. Only the repository publishes, and
/// only after its configuration was durably written.
///
/// The global rules switch (`setEnabled`) is a flag beside the snapshot: switched off, `active()`
/// offers no snapshot, so new exchanges run exactly as without any rules (no edits, no Map, no
/// breakpoint). The published rules are never deleted or rewritten by it.
public final class RuleSnapshotProvider: Sendable {
    private struct State: Sendable {
        var snapshot: RuleSnapshot
        var enabled = true
        /// `snapshot.requirements.connect`, kept beside it so the CONNECT path reads one flag.
        var connect: Bool
        var reads = ReadCounts()
    }

    /// How often each accessor handed out a snapshot or was asked for one (tests check what a path read).
    /// Counted in debug builds only, so the production hot path does no bookkeeping.
    package struct ReadCounts: Sendable, Equatable {
        package var active = 0
        package var connect = 0
        package init(active: Int = 0, connect: Int = 0) {
            self.active = active
            self.connect = connect
        }
    }
    private let state: OSAllocatedUnfairLock<State>
    /// The cache this provider prepares patterns in; body rewrites run their searches here so editing
    /// a rule's body search (or switching the rule off and on) re-enables a disabled one for the
    /// exchanges that use it.
    package let patternCache: PatternCache
    /// How many exchanges matched each rule, for the occurrence option. A rule's count starts over
    /// when a publish changes or removes it.
    public let hits = RuleHitCounter()

    /// Starts with `initial` (empty: rules disabled) until a repository load or save publishes.
    public init(_ initial: RuleSnapshot = RuleSnapshot(revision: 0, rules: []), patternCache: PatternCache = .shared) {
        _ = initial.evaluationOrder
        _ = initial.requirements
        state = OSAllocatedUnfairLock(initialState: State(snapshot: initial, connect: initial.requirements.connect))
        self.patternCache = patternCache
    }

    /// The published rules, whether or not they are switched on.
    public func current() -> RuleSnapshot {
        state.withLock { $0.snapshot }
    }

    /// The snapshot new exchanges use, or nil while all rules are switched off.
    public func active() -> RuleSnapshot? {
        state.withLock {
            #if DEBUG
            $0.reads.active += 1
            #endif
            return $0.enabled ? $0.snapshot : nil
        }
    }

    /// The snapshot a CONNECT uses: the active one, but only when one of its rules runs at the CONNECT point
    /// (`SnapshotRequirements.connect`). Nil otherwise, so a CONNECT under rules that never run there reads one
    /// flag and does nothing else.
    public func activeAtConnect() -> RuleSnapshot? {
        state.withLock {
            #if DEBUG
            $0.reads.connect += 1
            #endif
            return $0.enabled && $0.connect ? $0.snapshot : nil
        }
    }

    package var readCounts: ReadCounts { state.withLock { $0.reads } }

    public var isEnabled: Bool { state.withLock { $0.enabled } }

    /// Applies to every exchange admitted afterwards; exchanges already admitted keep their snapshot.
    public func setEnabled(_ enabled: Bool) {
        state.withLock { $0.enabled = enabled }
    }

    /// First compiles the condition rows and body searches of every enabled rule that is new, was
    /// switched on, or whose conditions or body searches changed (so the first request does not, and so
    /// editing the conditions, or switching a rule off and on, brings its timed-out regular expressions
    /// back). Then starts the hit count of every changed or removed rule over, works the evaluation order
    /// out once, and swaps the snapshot.
    ///
    /// A rule's position (`order`, `groupID`) is not part of what it is: the editor renumbers the rules
    /// below an insert, a delete or a move, and that must neither start their counts over nor switch their
    /// patterns back on. Any other difference counts as the rule having been saved.
    package func publish(_ snapshot: RuleSnapshot) {
        let previous = current()
        let previousRules = Dictionary(previous.rules.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for rule in snapshot.rules where rule.enabled {
            if let old = previousRules[rule.id], old.enabled, !old.patternsDiffer(from: rule) { continue }
            rule.preparePatterns(in: patternCache)
        }
        let publishedRules = Dictionary(snapshot.rules.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for (id, rule) in previousRules where !(publishedRules[id]?.isSameRule(as: rule) ?? false) {
            hits.reset(id)
        }
        _ = snapshot.evaluationOrder
        let connect = snapshot.requirements.connect
        state.withLock {
            $0.snapshot = snapshot
            $0.connect = connect
        }
    }
}

extension Rule {
    /// The rule as saved, ignoring where it sits: equal for a rule that only moved or was renumbered.
    fileprivate func isSameRule(as other: Rule) -> Bool {
        var moved = other
        moved.order = order
        moved.groupID = groupID
        return self == moved
    }

    /// Whether the patterns the rule compiles (condition rows, body searches, URL / header / cookie edit regexes) differ from `other`'s.
    fileprivate func patternsDiffer(from other: Rule) -> Bool {
        conditions != other.conditions || bodySearches != other.bodySearches || editRegexes != other.editRegexes
    }

    private var bodySearches: [BodyRewriteAction] {
        actions.compactMap { action in
            if case .rewriteBody(_, let rewrite) = action.kind, rewrite.operation == .findReplace { rewrite } else { nil }
        }
    }
}
