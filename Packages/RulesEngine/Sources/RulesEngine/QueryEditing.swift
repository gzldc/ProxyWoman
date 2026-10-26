import FlowStore
import Foundation

/// Pure transforms for the "modify query" action. Only the text after the first `?` is rewritten;
/// parameters are matched by their raw, undecoded names, case-sensitively unless an edit says otherwise.
enum QueryEditing {
    struct Edited: Equatable {
        var pathAndQuery: String
        /// The first regular-expression problem (timeout or disabled pattern); that edit was skipped.
        var patternProblem: RuleOutcomeCode?
    }

    /// The edits without look-up by regular expression limits: the shared cache and a fresh allowance.
    static func apply(_ edits: [QueryEdit], to pathAndQuery: String) -> String {
        apply(edits, to: pathAndQuery, allowance: RegexAllowance(), cache: PatternCache.shared).pathAndQuery
    }

    static func apply(
        _ edits: [QueryEdit], to pathAndQuery: String, allowance: RegexAllowance, cache: PatternCache
    ) -> Edited {
        guard pathAndQuery != "*" else { return Edited(pathAndQuery: pathAndQuery) }
        let path: String
        var segments: [String]
        if let (before, query) = ByteText.partition(pathAndQuery, 63) {  // "?"
            path = before
            segments = query.isEmpty ? [] : ByteText.split(query, 38)  // "&"
        } else {
            path = pathAndQuery
            segments = []
        }
        let original = segments
        var problem: RuleOutcomeCode?
        for edit in edits { apply(edit, to: &segments, allowance: allowance, cache: cache, problem: &problem) }
        guard !bytesEqual(segments, original) else { return Edited(pathAndQuery: pathAndQuery, patternProblem: problem) }
        return Edited(
            pathAndQuery: segments.isEmpty ? path : path + "?" + segments.joined(separator: "&"),
            patternProblem: problem)
    }

    /// Characters a query name or value may hold: printable ASCII without space and `#`.
    /// Whether a name may be empty is the caller's decision.
    static func isValidComponent(_ text: String) -> Bool {
        text.utf8.allSatisfy { $0 > 32 && $0 < 127 && $0 != 35 }
    }

    private static func split(_ segment: String) -> (name: String, value: String?) {
        guard let (name, value) = ByteText.partition(segment, 61) else { return (segment, nil) }  // "="
        return (name, value)
    }

    /// Whether the key selects this segment: the same raw name, or (empty key) any non-empty parameter.
    private static func selects(_ key: String?, segment: String, name: String, exact: Bool) -> Bool {
        guard let key, !key.isEmpty else { return !segment.isEmpty }
        return sameName(name, key, exact: exact)
    }

    private static func sameName(_ a: String, _ b: String, exact: Bool) -> Bool {
        exact ? bytesEqual(a, b) : bytesEqual(ByteText.asciiLowercased(a), ByteText.asciiLowercased(b))
    }

    private static func apply(
        _ edit: QueryEdit, to segments: inout [String], allowance: RegexAllowance, cache: PatternCache,
        problem: inout RuleOutcomeCode?
    ) {
        let exact = edit.matchesNameExactly
        switch edit {
        case .set(let name, let value, _) where name.isEmpty:
            for index in segments.indices where !segments[index].isEmpty {
                segments[index] = split(segments[index]).name + "=" + value
            }
        case .remove(let name, _) where name.isEmpty:
            segments.removeAll()  // empty pieces (`a=1&&b`) go too, so no bare "?" is left behind
        case .addIfMissing(let name, _, _) where name.isEmpty:
            return  // validation refuses it: "if not present" needs a name
        case .set(let name, let value, _):
            let new = name + "=" + value
            let matches = segments.indices.filter { sameName(split(segments[$0]).name, name, exact: exact) }
            guard let first = matches.first else {
                segments.append(new)
                return
            }
            segments[first] = new
            for index in matches.dropFirst().reversed() { segments.remove(at: index) }
        case .add(let name, let value, _):
            segments.append(name + "=" + value)
        case .addIfMissing(let name, let value, _):
            if !segments.contains(where: { sameName(split($0).name, name, exact: exact) }) { segments.append(name + "=" + value) }
        case .remove(let name, _):
            segments.removeAll { sameName(split($0).name, name, exact: exact) }
        case .appendToValue(let name, let text, _):
            rewriteValues(&segments, named: name, exact: exact) { $0 + text }
        case .findReplace(let name, let find, let replacement, let caseSensitive, _):
            rewriteValues(&segments, named: name, exact: exact) {
                LiteralReplace.apply($0, find: find, replacement: replacement, caseSensitive: caseSensitive)
            }
        case .regex(let name, let pattern, let replacement, let caseSensitive, _):
            guard let compiled = try? cache.regex(pattern, mode: .find, caseInsensitive: !caseSensitive) else {
                return  // an unreadable pattern never applies, as in the conditions
            }
            var found: RuleOutcomeCode?
            rewriteValues(&segments, named: name, exact: exact) { value in
                switch compiled.replacingMatches(in: value, template: replacement, allowance: allowance) {
                case .replaced(let text): return text
                case .noMatch, .inputTooLong: return value
                case .timedOut:
                    found = found ?? .patternTimedOut
                    return value
                case .disabled:
                    found = found ?? .patternDisabled
                    return value
                }
            }
            problem = problem ?? found
        }
    }

    /// Rewrites the value of each parameter the key selects (a bare `flag` has no value to rewrite).
    private static func rewriteValues(
        _ segments: inout [String], named key: String?, exact: Bool, _ transform: (String) -> String
    ) {
        for index in segments.indices {
            let (name, value) = split(segments[index])
            guard let value, selects(key, segment: segments[index], name: name, exact: exact) else { continue }
            let replaced = transform(value)
            if !bytesEqual(replaced, value) { segments[index] = name + "=" + replaced }
        }
    }
}
