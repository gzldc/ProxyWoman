import FlowStore
import Foundation

enum URLEditFailure: Error, Equatable { case invalidResult, patternTimedOut, patternDisabled, inputTooLarge }

/// Byte-wise text equality (UTF-8), like R3's `TextComparison`: canonically equivalent but differently
/// encoded strings are different.
func bytesEqual(_ a: String, _ b: String) -> Bool { a.utf8.elementsEqual(b.utf8) }
func bytesEqual(_ a: [String], _ b: [String]) -> Bool {
    a.count == b.count && zip(a, b).allSatisfy { bytesEqual($0, $1) }
}

/// Searching and splitting on ASCII separators in the UTF-8 bytes. `Character` based APIs see a
/// separator followed by a combining mark as one grapheme, so they would miss it. Separators are ASCII,
/// so every slice is valid UTF-8 again.
enum ByteText {
    static func string(_ bytes: ArraySlice<UInt8>) -> String { String(decoding: bytes, as: UTF8.self) }

    /// Splits on `separator`, keeping empty pieces (`""` gives one empty piece).
    static func split(_ text: String, _ separator: UInt8) -> [String] {
        Array(text.utf8).split(separator: separator, omittingEmptySubsequences: false).map { string($0) }
    }

    /// The text before and after the first (or last) `separator`, or nil.
    static func partition(_ text: String, _ separator: UInt8, last: Bool = false) -> (before: String, after: String)? {
        let bytes = Array(text.utf8)
        guard let index = last ? bytes.lastIndex(of: separator) : bytes.firstIndex(of: separator) else { return nil }
        return (string(bytes[..<index]), string(bytes[(index + 1)...]))
    }

    /// Without leading and trailing spaces and tabs.
    static func trimmed(_ text: String) -> String {
        var bytes = Array(text.utf8)[...]
        while let first = bytes.first, first == 32 || first == 9 { bytes = bytes.dropFirst() }
        while let last = bytes.last, last == 32 || last == 9 { bytes = bytes.dropLast() }
        return string(bytes)
    }

    static func asciiLowercased(_ text: String) -> String {
        String(decoding: text.utf8.map { $0 >= 65 && $0 <= 90 ? $0 + 32 : $0 }, as: UTF8.self)
    }
}

/// Literal text replacement shared by the URL, query and cookie edits: every occurrence, no
/// pattern syntax, `caseSensitive` decides whether letter case matters.
enum LiteralReplace {
    static func apply(_ text: String, find: String, replacement: String, caseSensitive: Bool) -> String {
        guard !find.isEmpty else { return text }
        let options: String.CompareOptions = caseSensitive ? [.literal] : [.literal, .caseInsensitive]
        return text.replacingOccurrences(of: find, with: replacement, options: options)
    }
}

/// Pure transforms for the "modify URL" action: the target is edited as its full URL text.
enum URLEditing {
    static func apply(
        _ action: URLEditAction, to target: HTTPMessageTarget, allowance: RegexAllowance, cache: PatternCache,
        limits: RulesLimits = RulesLimits()
    ) -> Result<HTTPMessageTarget, URLEditFailure> {
        let current = text(of: target)
        let edited: String
        switch action.mode {
        case .set:
            edited = action.replacement
        case .append:
            edited = current + action.replacement
        case .findReplace:
            edited = LiteralReplace.apply(
                current, find: action.find, replacement: action.replacement, caseSensitive: action.caseSensitive)
        case .regex:
            guard
                let pattern = try? cache.regex(action.find, mode: .find, caseInsensitive: !action.caseSensitive)
            else { return .failure(.invalidResult) }
            switch pattern.replacingMatches(
                in: current, template: action.replacement, allowance: allowance, outputLimit: limits.fieldBytes) {
            case .replaced(let text): edited = text
            case .noMatch: return .success(target)
            case .timedOut: return .failure(.patternTimedOut)
            case .disabled: return .failure(.patternDisabled)
            case .inputTooLong: return .failure(.inputTooLarge)
            }
        }
        if bytesEqual(edited, current) { return .success(target) }
        guard edited.utf8.count <= limits.fieldBytes, let parsed = parse(edited, method: target.method) else {
            return .failure(.invalidResult)
        }
        return .success(parsed)
    }

    /// `scheme://host[:port]/path?query`; the default port is left out.
    static func text(of target: HTTPMessageTarget) -> String { target.url }

    /// An absolute `http(s)` URL without userinfo or fragment.
    static func parse(_ text: String, method: String) -> HTTPMessageTarget? {
        let bytes = Array(text.utf8)
        guard !bytes.contains(35) else { return nil }  // "#"
        guard let schemeEnd = (0..<max(bytes.count - 2, 0)).first(where: {
            bytes[$0] == 58 && bytes[$0 + 1] == 47 && bytes[$0 + 2] == 47
        }) else { return nil }
        let scheme = ByteText.asciiLowercased(ByteText.string(bytes[..<schemeEnd]))
        guard scheme == "http" || scheme == "https" else { return nil }
        let rest = Array(bytes[(schemeEnd + 3)...])
        let authorityEnd = rest.firstIndex { $0 == 47 || $0 == 63 } ?? rest.count  // "/" or "?"
        let authority = Array(rest[..<authorityEnd])
        var tail = Array(rest[authorityEnd...])
        if tail.first != 47 { tail.insert(47, at: 0) }
        guard !authority.contains(64) else { return nil }  // "@"

        var host = authority[...]
        var portBytes: ArraySlice<UInt8>?
        if authority.first == 91 {  // "["
            guard let close = authority.firstIndex(of: 93) else { return nil }
            host = authority[...close]
            let after = authority[(close + 1)...]
            if !after.isEmpty {
                guard after.first == 58 else { return nil }
                portBytes = after.dropFirst()
            }
        } else if let colon = authority.lastIndex(of: 58) {
            host = authority[..<colon]
            portBytes = authority[(colon + 1)...]
        }
        var port = scheme == "https" ? 443 : 80
        if let portBytes {
            guard !portBytes.isEmpty, portBytes.count <= 5, portBytes.allSatisfy({ $0 >= 48 && $0 <= 57 }),
                let value = Int(ByteText.string(portBytes)), (1...65_535).contains(value)
            else { return nil }
            port = value
        }
        let lowered = ByteText.asciiLowercased(ByteText.string(host))
        let pathAndQuery = ByteText.string(tail[...])
        guard HTTPMutationValidator.hostError(lowered) == nil else { return nil }
        guard HTTPMutationValidator.pathError(pathAndQuery, method: method) == nil else { return nil }
        return HTTPMessageTarget(
            scheme: scheme, host: lowered, port: port, method: method, pathAndQuery: pathAndQuery)
    }
}
