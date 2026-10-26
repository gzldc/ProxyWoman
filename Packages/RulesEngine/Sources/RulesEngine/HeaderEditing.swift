import FlowStore
import Foundation

struct HeaderEditResult: Equatable {
    var headers: [HeaderField]
    /// The headers differ from the ones the edits started from.
    var changed: Bool
    /// The action looks fields up (append to value, find and replace, regex) and none of those edits
    /// touched a field.
    var matchedNothing: Bool
    /// The first regular-expression problem (timeout or disabled pattern); that edit was skipped.
    var patternProblem: RuleOutcomeCode?
}

extension HeaderEdit {
    /// The three methods that existed before R5: they always count as a modification.
    var isLegacyMethod: Bool {
        switch self {
        case .set, .append, .remove: nameCaseSensitive == nil
        case .addIfMissing, .appendToValue, .findReplace, .regex: false
        }
    }
}

extension Array where Element == HeaderField {
    /// The fields after applying `operations` in order. The old three methods behave exactly as in
    /// `applying(_:)`; the others work on the bytes of each field value, names matching ASCII
    /// case-insensitively.
    func applying(_ operations: [HeaderEdit], allowance: RegexAllowance, cache: PatternCache) -> HeaderEditResult {
        var fields = self
        var lookups = 0
        var touched = 0
        var problem: RuleOutcomeCode?
        // An empty key means "all keys": protected, Connection-nominated and pseudo fields are never touched.
        let isGuarded = HTTPMutationValidator.guardedFieldCheck(for: self)
        for operation in operations {
            switch operation {
            case .set(let name, let value, _) where name.isEmpty:
                for index in fields.indices where !isGuarded(fields[index].name) {
                    fields[index] = HeaderField(name: fields[index].name, value: value)
                }
            case .remove(let name, _) where name.isEmpty:
                fields.removeAll { !isGuarded($0.name) }
            case .append(let name, _, _) where name.isEmpty:
                continue  // validation refuses it: adding a field needs a name
            case .addIfMissing(let name, _, _) where name.isEmpty:
                continue  // validation refuses it: "if not present" needs a name
            case .set, .append, .remove:
                let before = fields
                fields = fields.applying([operation])
                // An old method that changed something is a match, so it never reads as "no match".
                if !Self.sameBytes(fields, before) { touched += 1 }
            case .addIfMissing(let name, let value, _):
                if !fields.contains(where: { Self.isNamed($0, name, exact: operation.matchesNameExactly) }) {
                    fields.append(HeaderField(name: name, value: value))
                }
            case .appendToValue(let name, let text, _):
                lookups += 1
                for index in fields.indices
                where Self.matches(fields[index], name, isGuarded, exact: operation.matchesNameExactly) {
                    touched += 1
                    fields[index] = HeaderField(name: fields[index].name, value: fields[index].value + text)
                }
            case .findReplace(let name, let find, let replacement, let caseSensitive, _):
                lookups += 1
                touched += Self.rewrite(&fields, named: name, isGuarded, exact: operation.matchesNameExactly) {
                    LiteralReplace.apply($0, find: find, replacement: replacement, caseSensitive: caseSensitive)
                }
            case .regex(let name, let pattern, let replacement, let caseSensitive, _):
                lookups += 1
                guard let compiled = try? cache.regex(pattern, mode: .find, caseInsensitive: !caseSensitive) else {
                    continue  // an unreadable pattern never applies, as in the conditions
                }
                var found: RuleOutcomeCode?
                touched += Self.rewrite(&fields, named: name, isGuarded, exact: operation.matchesNameExactly) { value in
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
        return HeaderEditResult(
            headers: fields, changed: !Self.sameBytes(fields, self), matchedNothing: lookups > 0 && touched == 0,
            patternProblem: problem)
    }

    private static func sameBytes(_ a: [HeaderField], _ b: [HeaderField]) -> Bool {
        a.count == b.count
            && zip(a, b).allSatisfy { bytesEqual($0.name, $1.name) && bytesEqual($0.value, $1.value) }
    }

    private static func isNamed(_ field: HeaderField, _ name: String, exact: Bool = false) -> Bool {
        exact
            ? bytesEqual(field.name, name)
            : bytesEqual(ByteText.asciiLowercased(field.name), ByteText.asciiLowercased(name))
    }

    /// A field the key selects: the same name, or (empty key) any field the edit may touch.
    private static func matches(
        _ field: HeaderField, _ name: String, _ isGuarded: (String) -> Bool, exact: Bool
    ) -> Bool {
        name.isEmpty ? !isGuarded(field.name) : isNamed(field, name, exact: exact)
    }

    /// Rewrites the value of each field of that name; returns how many values changed.
    private static func rewrite(
        _ fields: inout [HeaderField], named name: String, _ isGuarded: (String) -> Bool, exact: Bool,
        _ transform: (String) -> String
    ) -> Int {
        var changed = 0
        for index in fields.indices where matches(fields[index], name, isGuarded, exact: exact) {
            let value = fields[index].value
            let replaced = transform(value)
            if !bytesEqual(replaced, value) {
                fields[index] = HeaderField(name: fields[index].name, value: replaced)
                changed += 1
            }
        }
        return changed
    }
}
