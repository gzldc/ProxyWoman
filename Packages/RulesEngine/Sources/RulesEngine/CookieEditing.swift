import FlowStore
import Foundation

struct CookieEditResult: Equatable {
    var headers: [HeaderField]
    /// The first regular-expression problem (timeout or disabled pattern); that edit was skipped.
    var patternProblem: RuleOutcomeCode?
}

/// Pure transforms for the "edit cookies" action. Names are matched case-sensitively.
enum CookieEditing {
    /// Edits the `Cookie` fields. Without a real change the headers come back untouched; otherwise
    /// every `Cookie` field is merged into one at the position of the first.
    static func applyToRequest(
        _ edits: [CookieEdit], headers: [HeaderField], allowance: RegexAllowance, cache: PatternCache
    ) -> CookieEditResult {
        let positions = headers.indices.filter { isNamed(headers[$0], "cookie") }
        var cookies: [Cookie] = positions.flatMap { index in
            ByteText.split(headers[index].value, 59).compactMap { piece -> Cookie? in
                let trimmed = ByteText.trimmed(piece)
                return trimmed.isEmpty ? nil : Cookie(raw: trimmed, origin: index)
            }
        }
        let original = cookies
        var editor = Editor(allowance: allowance, cache: cache, collapsesDuplicates: true)
        for edit in edits { editor.apply(edit, to: &cookies) }
        guard !bytesEqual(cookies.map(\.raw), original.map(\.raw)) else {
            return CookieEditResult(headers: headers, patternProblem: editor.problem)
        }

        var result: [HeaderField] = []
        for (index, field) in headers.enumerated() {
            guard positions.contains(index) else {
                result.append(field)
                continue
            }
            if index == positions.first, !cookies.isEmpty {
                result.append(HeaderField(name: field.name, value: cookies.map(\.raw).joined(separator: "; ")))
            }
        }
        if positions.isEmpty {
            result.append(HeaderField(name: "Cookie", value: cookies.map(\.raw).joined(separator: "; ")))
        }
        return CookieEditResult(headers: result, patternProblem: editor.problem)
    }

    /// Edits the first `name=value` pair of each `Set-Cookie` field and leaves its attributes alone.
    static func applyToResponse(
        _ edits: [CookieEdit], headers: [HeaderField], allowance: RegexAllowance, cache: PatternCache
    ) -> CookieEditResult {
        let positions = headers.indices.filter { isNamed(headers[$0], "set-cookie") }
        var cookies = positions.map { Cookie(raw: headers[$0].value, origin: $0) }
        let original = cookies
        var editor = Editor(allowance: allowance, cache: cache, collapsesDuplicates: false)
        for edit in edits { editor.apply(edit, to: &cookies) }
        guard !Self.unchanged(cookies, original) else { return CookieEditResult(headers: headers, patternProblem: editor.problem) }

        let survivors = Dictionary(uniqueKeysWithValues: cookies.compactMap { cookie in cookie.origin.map { ($0, cookie) } })
        var result: [HeaderField] = []
        for (index, field) in headers.enumerated() {
            guard positions.contains(index) else {
                result.append(field)
                continue
            }
            if let cookie = survivors[index] { result.append(HeaderField(name: field.name, value: cookie.raw)) }
        }
        for cookie in cookies where cookie.origin == nil {
            result.append(HeaderField(name: "Set-Cookie", value: cookie.raw))
        }
        return CookieEditResult(headers: result, patternProblem: editor.problem)
    }

    private static func unchanged(_ cookies: [Cookie], _ original: [Cookie]) -> Bool {
        cookies.count == original.count
            && cookies.indices.allSatisfy {
                cookies[$0].origin == original[$0].origin && bytesEqual(cookies[$0].raw, original[$0].raw)
            }
    }

    private static func isNamed(_ field: HeaderField, _ lowercased: String) -> Bool {
        bytesEqual(ByteText.asciiLowercased(field.name), lowercased)
    }
}

/// One cookie pair (request) or one `Set-Cookie` field value (response), kept as written until an
/// edit changes it. `origin` is the index of the header field it came from; new cookies have none.
private struct Cookie: Equatable {
    var raw: String
    var origin: Int?

    /// The `name=value` part and the attributes (starting at the first `;`, or empty).
    private var parts: (pair: String, attributes: String) {
        guard let (pair, rest) = ByteText.partition(raw, 59) else { return (raw, "") }
        return (pair, ";" + rest)
    }

    var name: String {
        let pair = parts.pair
        return ByteText.trimmed(ByteText.partition(pair, 61)?.before ?? pair)
    }

    var value: String? {
        ByteText.partition(parts.pair, 61).map { ByteText.trimmed($0.after) }
    }

    func replacingValue(_ new: String) -> Cookie {
        var copy = self
        copy.raw = name + "=" + new + parts.attributes
        return copy
    }
}

private struct Editor {
    let allowance: RegexAllowance
    let cache: PatternCache
    let collapsesDuplicates: Bool
    var problem: RuleOutcomeCode?

    init(allowance: RegexAllowance, cache: PatternCache, collapsesDuplicates: Bool) {
        self.allowance = allowance
        self.cache = cache
        self.collapsesDuplicates = collapsesDuplicates
    }

    mutating func apply(_ edit: CookieEdit, to cookies: inout [Cookie]) {
        let exact = edit.matchesNameExactly
        switch edit {
        case .set(let name, let value, _) where name.isEmpty:
            for index in cookies.indices where cookies[index].value.map({ !bytesEqual($0, value) }) ?? true {
                cookies[index] = cookies[index].replacingValue(value)
            }
        case .remove(let name, _) where name.isEmpty:
            cookies.removeAll()
        case .addIfMissing(let name, _, _) where name.isEmpty:
            return  // validation refuses it: "if not present" needs a name
        case .set(let name, let value, _):
            let matches = cookies.indices.filter { Self.sameName(cookies[$0].name, name, exact: exact) }
            guard let first = matches.first else {
                cookies.append(Cookie(raw: name + "=" + value, origin: nil))
                return
            }
            for index in collapsesDuplicates ? [first] : matches where cookies[index].value.map({ !bytesEqual($0, value) }) ?? true {
                cookies[index] = cookies[index].replacingValue(value)
            }
            if collapsesDuplicates { for index in matches.dropFirst().reversed() { cookies.remove(at: index) } }
        case .addIfMissing(let name, let value, _):
            if !cookies.contains(where: { Self.sameName($0.name, name, exact: exact) }) {
                cookies.append(Cookie(raw: name + "=" + value, origin: nil))
            }
        case .remove(let name, _):
            cookies.removeAll { Self.sameName($0.name, name, exact: exact) }
        case .appendToValue(let name, let text, _):
            Self.rewriteValues(&cookies, named: name, exact: exact) { $0 + text }
        case .findReplace(let name, let find, let replacement, let caseSensitive, _):
            Self.rewriteValues(&cookies, named: name, exact: exact) {
                LiteralReplace.apply($0, find: find, replacement: replacement, caseSensitive: caseSensitive)
            }
        case .regex(let name, let pattern, let replacement, let caseSensitive, _):
            guard let compiled = try? cache.regex(pattern, mode: .find, caseInsensitive: !caseSensitive) else {
                return  // an unreadable pattern never applies, as in R3's conditions
            }
            let allowance = allowance
            var found: RuleOutcomeCode?
            Self.rewriteValues(&cookies, named: name, exact: exact) { value in
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

    private static func sameName(_ a: String, _ b: String, exact: Bool) -> Bool {
        exact ? bytesEqual(a, b) : bytesEqual(ByteText.asciiLowercased(a), ByteText.asciiLowercased(b))
    }

    private static func rewriteValues(
        _ cookies: inout [Cookie], named name: String?, exact: Bool, _ transform: (String) -> String
    ) {
        for index in cookies.indices {
            guard name.map({ $0.isEmpty || sameName(cookies[index].name, $0, exact: exact) }) ?? true, let value = cookies[index].value else { continue }
            let replaced = transform(value)
            if !bytesEqual(replaced, value) { cookies[index] = cookies[index].replacingValue(replaced) }
        }
    }
}
