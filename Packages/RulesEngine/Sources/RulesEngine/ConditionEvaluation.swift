import FlowStore
import Foundation

extension ConditionRow {
    /// How a row reads as an old, single-field matcher.
    enum LegacyReading: Equatable {
        case matcher(RuleMatcher)
        /// The field, comparison and case option do not go together in R1.
        case unsupported
        /// The combination is fine, but the value is not a whole number (port) or `lo-hi` (status).
        case unreadableValue
    }

    /// Reads the row as the old matcher with exactly this one field set, so evaluating the row is
    /// evaluating that matcher: host, path and status comparisons keep their old semantics bit for bit.
    ///
    /// R1 can say these (field, comparison, case-sensitive): scheme equals false; host
    /// hostPattern / wildcard / regexWhole false; port equals (any); method equals true; pathAndQuery
    /// equals / startsWith / wildcard / regexWhole true; statusCode inRange (any); allSessions
    /// (anything). The case flag of a port, a status and an all-sessions row has no meaning, so it is
    /// not part of the identity of the row.
    var legacyReading: LegacyReading {
        switch field {
        case .allSessions:
            return .matcher(RuleMatcher())
        case .scheme:
            guard op == .equals, !caseSensitive else { return .unsupported }
            return .matcher(RuleMatcher(scheme: value))
        case .host:
            guard !caseSensitive else { return .unsupported }
            switch op {
            case .hostPattern: return .matcher(RuleMatcher(hostPattern: value, hostSyntax: .literal))
            case .wildcard: return .matcher(RuleMatcher(hostPattern: value, hostSyntax: .wildcard))
            case .regexWhole: return .matcher(RuleMatcher(hostPattern: value, hostSyntax: .regex))
            default: return .unsupported
            }
        case .port:
            guard op == .equals else { return .unsupported }
            guard let port = Self.wholeNumber(value.utf8[...]) else { return .unreadableValue }
            return .matcher(RuleMatcher(port: port))
        case .method:
            guard op == .equals, caseSensitive else { return .unsupported }
            return .matcher(RuleMatcher(method: value))
        case .pathAndQuery:
            guard caseSensitive else { return .unsupported }
            switch op {
            case .equals: return .matcher(RuleMatcher(path: .exact(value)))
            case .startsWith: return .matcher(RuleMatcher(path: .prefix(value)))
            case .wildcard: return .matcher(RuleMatcher(path: .wildcard(value)))
            case .regexWhole: return .matcher(RuleMatcher(path: .regex(value)))
            default: return .unsupported
            }
        case .statusCode:
            guard op == .inRange else { return .unsupported }
            guard let range = Self.statusRange(value) else { return .unreadableValue }
            return .matcher(RuleMatcher(statusRange: range))
        default:
            return .unsupported
        }
    }

    /// The old matcher equivalent to this row, or nil when R1 cannot express the row (an operator the
    /// field does not take, or a port or status value that cannot be read).
    public var legacyMatcher: RuleMatcher? {
        if case .matcher(let matcher) = legacyReading { return matcher }
        return nil
    }

    /// Plain ASCII digits only (no sign, no space), at most nine of them so the value cannot overflow.
    private static func wholeNumber(_ digits: Substring.UTF8View) -> Int? {
        guard !digits.isEmpty, digits.count <= 9 else { return nil }
        var number = 0
        for byte in digits {
            guard byte >= 0x30, byte <= 0x39 else { return nil }
            number = number * 10 + Int(byte - 0x30)
        }
        return number
    }

    /// `lo-hi` with `lo <= hi`, nothing else. Whether the numbers are HTTP status codes is validation's call.
    private static func statusRange(_ text: String) -> ClosedRange<Int>? {
        let bytes = text.utf8
        guard let dash = bytes.firstIndex(of: 0x2D),
            let low = wholeNumber(bytes[..<dash]),
            let high = wholeNumber(bytes[bytes.index(after: dash)...]),
            low <= high
        else { return nil }
        return low...high
    }
}

extension ConditionGroup {
    /// The latest point at which any row gets its value: the rule can only be judged then. No rows
    /// means every session, which is known from the start.
    public var judgmentPoint: EvaluationPoint {
        rows.reduce(EvaluationPoint.connect) { max($0, $1.knowablePoint) }
    }

    /// Whether the rows, combined by `mode`, match. `status` is nil while a request is judged; a
    /// status row then never matches.
    ///
    /// Rows without a regular expression run first and the regular-expression rows last (each group in
    /// the order written), so a cheap row that settles the answer keeps the regular expression from
    /// running at all. `all` stops at the first row that does not match, `any` and `none` at the first
    /// that does (`none` then does not match). A regular expression that ran out of time or is switched
    /// off decides the whole group, whatever the mode: the group does not match, and says why. That
    /// keeps a timeout from reading as "no row matched" in `none` mode. A group with no rows matches.
    /// A row R1 cannot interpret (see `ConditionRow.legacyMatcher`) never matches, in any mode: the
    /// group stops there with `.noMatch`.
    public func evaluate(
        _ target: HTTPMessageTarget, status: Int?, cache: PatternCache = .shared
    ) -> RuleMatchResult {
        guard !rows.isEmpty else { return .matched }
        for pass in 0..<2 {
            let regexPass = pass == 1
            for row in rows where (row.op == .regexWhole) == regexPass {
                guard let matcher = row.legacyMatcher else { return .noMatch }
                switch matcher.evaluate(target, status: status, cache: cache) {
                case .matched:
                    switch mode {
                    case .all: break
                    case .any: return .matched
                    case .none: return .noMatch
                    }
                case .noMatch:
                    if mode == .all { return .noMatch }
                case .patternTimedOut: return .patternTimedOut
                case .patternDisabled: return .patternDisabled
                }
            }
        }
        return mode == .any ? .noMatch : .matched
    }
}
