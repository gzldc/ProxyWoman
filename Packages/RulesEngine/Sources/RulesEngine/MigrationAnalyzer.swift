import Foundation

/// Finds the pairs of old rules whose behaviour can change when a rule file moves to Rules 2.0, for the
/// one-time upgrade notice (spec 5.6.3, 5.6.4). Pure: no I/O, no state.
///
/// A pair is a higher-priority rule R and a lower-priority rule L, both enabled (D13: a disabled rule
/// has no behaviour to change). The analysis errs on the side of listing: a pair is left out only when
/// the matchers are provably disjoint (see `mayOverlap`), so a pair may be listed that never differs in
/// practice, and a pair that does differ is never missing.
///
/// - Class 1 (`finalAction`): R is a Map Local or Map Local Directory. It is a final action now, so L
///   stops running on every request R and L both match.
/// - Class 2 (`laterSeesEarlier`): L reads what R changed, or R reads what L changed.
///   - R is a Map Remote and L tests something the Map Remote rewrites (scheme, host, port, and the path
///     when the Map Remote replaces it). L used to read the original request; now it reads the moved
///     one, so a request it matched before may no longer match, and one it did not match may start to.
///     Nothing is listed when L can be shown to meet neither the requests R applies to nor the requests
///     R sends.
///   - R is a status rewrite and L has a status range: L now reads the rewritten status.
///   - Extension (spec 5.5.2, "P2 reads the final request"): R is judged at the response (it has a
///     status range) and L, below it, is a Map Remote. The response point reads the request after every
///     request-point action, including L's, so R's scheme, host, port and path conditions now see the
///     moved request. Same test as the first bullet with the roles swapped.
/// - Class 3 (`sequentialRewrite`): both are status rewrites, or R is a Map Remote and L a Map Remote or
///   a Map Local. The first one that could act used to win and the other was `shadowed`; now both run.
///
/// Other pairs are never listed: a Header edit, breakpoint or body rewrite changes nothing a later
/// condition reads (conditions cannot see headers or bodies in R1), and a rule judged at the request is
/// evaluated before the lower rules run. The same pair can fall under several classes; each is listed.
public enum MigrationAnalyzer {
    /// `rules` are the old rules in old evaluation order (`order`, then array position). The result is
    /// sorted by (position of R, position of L, class).
    public static func report(for rules: [LegacyRule]) -> MigrationReport {
        var pairs: [MigrationPair] = []
        forEachPair(in: rules) { pairs.append($0) }
        return MigrationReport(pairs: pairs)
    }

    /// The pairs of `report(for:)`, one at a time and in the same order, without holding the list (it is
    /// quadratic in the number of rules).
    package static func forEachPair(in rules: [LegacyRule], _ body: (MigrationPair) -> Void) {
        let enabled = rules.filter(\.enabled)
        for (position, higher) in enabled.enumerated() where canChangeALowerRule(higher) {
            for lower in enabled[(position + 1)...] {
                // Each pair's classes come out in class order and the loops walk positions in order, so
                // the list needs no sorting.
                for changeClass in changeClasses(higher: higher, lower: lower) {
                    body(MigrationPair(changeClass: changeClass, higherRuleID: higher.id, lowerRuleID: lower.id))
                }
            }
        }
    }

    /// False only when no class can apply whatever the lower rule is (the cheap exit for the O(n^2) walk).
    private static func canChangeALowerRule(_ rule: LegacyRule) -> Bool {
        switch rule.action {
        case .mapLocal, .mapLocalDirectory, .mapRemote, .rewriteStatus: true
        case .editHeaders, .breakpoint, .rewriteBody: rule.matcher.statusRange != nil
        }
    }

    private static func changeClasses(higher: LegacyRule, lower: LegacyRule) -> [MigrationChangeClass] {
        var classes: [MigrationChangeClass] = []
        if stopsLowerRule(higher, lower) { classes.append(.finalAction) }
        if lowerRuleReadsAChange(higher, lower) { classes.append(.laterSeesEarlier) }
        if rewritesRunInSequence(higher, lower) { classes.append(.sequentialRewrite) }
        return classes
    }

    // MARK: classes

    private static func stopsLowerRule(_ higher: LegacyRule, _ lower: LegacyRule) -> Bool {
        switch higher.action {
        case .mapLocal, .mapLocalDirectory: mayOverlap(higher.matcher, lower.matcher, ignoringStatus: true)
        case .mapRemote, .editHeaders, .breakpoint, .rewriteBody, .rewriteStatus: false
        }
    }

    private static func lowerRuleReadsAChange(_ higher: LegacyRule, _ lower: LegacyRule) -> Bool {
        switch higher.action {
        case .mapRemote(let remote):
            if mapRemote(remote, appliedTo: higher.matcher, mayChangeWhatIsTestedBy: lower.matcher) { return true }
        case .rewriteStatus:
            if lower.matcher.statusRange != nil, mayOverlap(higher.matcher, lower.matcher, ignoringStatus: true) {
                return true
            }
        case .mapLocal, .mapLocalDirectory, .editHeaders, .breakpoint, .rewriteBody:
            break
        }
        // The extension: a rule judged at the response reads the request the lower Map Remote moved.
        if higher.matcher.statusRange != nil, case .mapRemote(let remote) = lower.action {
            return mapRemote(remote, appliedTo: lower.matcher, mayChangeWhatIsTestedBy: higher.matcher)
        }
        return false
    }

    private static func rewritesRunInSequence(_ higher: LegacyRule, _ lower: LegacyRule) -> Bool {
        switch (higher.action, lower.action) {
        case (.rewriteStatus, .rewriteStatus):
            // Two rewrites of one response need a status both ranges contain.
            return mayOverlap(higher.matcher, lower.matcher, ignoringStatus: false)
        case (.mapRemote, .mapRemote), (.mapRemote, .mapLocal), (.mapRemote, .mapLocalDirectory):
            return mayOverlap(higher.matcher, lower.matcher, ignoringStatus: true)
        default:
            return false
        }
    }

    // MARK: Map Remote

    /// Whether a rule with the conditions `tested` can answer differently once `remote` has moved the
    /// request, for a Map Remote that applies to the requests `matcher` accepts.
    ///
    /// A rule that tests none of what the Map Remote rewrites reads the same request either way. One
    /// that does can be affected if it can accept a request the Map Remote applies to (it matched the
    /// original request and may not match the moved one) or a request the Map Remote produces (it did
    /// not match the original and may match the moved one); it is left out only when it can be shown to
    /// meet neither.
    private static func mapRemote(
        _ remote: MapRemoteAction, appliedTo matcher: RuleMatcher, mayChangeWhatIsTestedBy tested: RuleMatcher
    ) -> Bool {
        var testsARewrittenField = tested.scheme != nil || tested.hostPattern != nil || tested.port != nil
        if case .replace = remote.path, tested.path != .any { testsARewrittenField = true }
        guard testsARewrittenField else { return false }
        return mayOverlap(tested, matcher, ignoringStatus: true)
            || mayOverlap(tested, requests(sentBy: remote, from: matcher), ignoringStatus: true)
    }

    /// What the requests a Map Remote sends look like: its target scheme, host and port; its replacement
    /// path, or the path the original requests had; the method of the original requests.
    private static func requests(sentBy remote: MapRemoteAction, from matcher: RuleMatcher) -> RuleMatcher {
        var target = RuleMatcher(
            scheme: remote.targetScheme, hostPattern: remote.targetHost, port: remote.targetPort,
            method: matcher.method, path: matcher.path)
        if case .replace(let replacement) = remote.path { target.path = .exact(replacement) }
        return target
    }

    // MARK: overlap

    /// False only when no request (and, unless `ignoringStatus`, no response status) can satisfy both
    /// matchers. True means "not provably disjoint", so a wildcard or regular expression meets anything
    /// its other fields allow.
    ///
    /// Provably disjoint: both have a scheme (compared without regard to case), a port or a method (as
    /// written) and the values differ; two literal hosts that no host satisfies together; paths whose
    /// exact or prefix texts exclude each other; status ranges that share no status.
    package static func mayOverlap(_ a: RuleMatcher, _ b: RuleMatcher, ignoringStatus: Bool) -> Bool {
        if let x = a.scheme, let y = b.scheme, x.lowercased() != y.lowercased() { return false }
        if let x = a.port, let y = b.port, x != y { return false }
        if let x = a.method, let y = b.method, x != y { return false }
        if !ignoringStatus, let x = a.statusRange, let y = b.statusRange, !x.overlaps(y) { return false }
        if let x = a.hostPattern, let y = b.hostPattern, a.hostSyntax == .literal, b.hostSyntax == .literal,
            literalHostsCannotMeet(x, y)
        {
            return false
        }
        return !pathsCannotMeet(a.path, b.path)
    }

    /// A literal host pattern as `HostPattern.matches` reads it.
    private enum LiteralHost {
        case anyHost
        case host(String)
        /// `*.x`, kept as `.x`: any host with at least one more label in front of `x`.
        case subdomains(suffix: String)
    }

    private static func literalHost(_ pattern: String) -> LiteralHost? {
        let normalized = HostPattern.normalize(pattern)
        if normalized == "*" { return .anyHost }
        if normalized.hasPrefix("*.") {
            let suffix = String(normalized.dropFirst())
            // A star anywhere else is not a form `HostPattern` knows; do not claim to understand it.
            return suffix.count > 1 && !suffix.contains("*") ? .subdomains(suffix: suffix) : nil
        }
        guard !normalized.isEmpty, !normalized.contains("*") else { return nil }
        return .host(RuleMatcher.canonicalIPv6(normalized) ?? normalized)
    }

    private static func literalHostsCannotMeet(_ first: String, _ second: String) -> Bool {
        guard let left = literalHost(first), let right = literalHost(second) else { return false }
        switch (left, right) {
        case (.anyHost, _), (_, .anyHost):
            return false
        case (.host(let a), .host(let b)):
            return a != b
        case (.host(let host), .subdomains(let suffix)), (.subdomains(let suffix), .host(let host)):
            return !(host.count > suffix.count && host.hasSuffix(suffix))
        case (.subdomains(let a), .subdomains(let b)):
            // A host ends with both suffixes only if one suffix ends with the other.
            return !(a.hasSuffix(b) || b.hasSuffix(a))
        }
    }

    /// The matcher compares the raw bytes of path and query, so the proof does too.
    private static func pathsCannotMeet(_ a: PathMatch, _ b: PathMatch) -> Bool {
        switch (a, b) {
        case (.exact(let x), .exact(let y)):
            return !x.utf8.elementsEqual(y.utf8)
        case (.exact(let x), .prefix(let prefix)), (.prefix(let prefix), .exact(let x)):
            return !x.utf8.starts(with: prefix.utf8)
        case (.prefix(let x), .prefix(let y)):
            return !(x.utf8.starts(with: y.utf8) || y.utf8.starts(with: x.utf8))
        case (.any, _), (_, .any), (.wildcard, _), (_, .wildcard), (.regex, _), (_, .regex):
            return false
        }
    }
}
