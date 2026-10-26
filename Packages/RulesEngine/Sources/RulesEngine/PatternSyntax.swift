/// How a rule's host or path text is interpreted. `literal` keeps the original exact/prefix
/// semantics; `wildcard` and `regex` are whole-string matches.
public enum PatternSyntax: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
    case literal, wildcard, regex
}

/// Why a wildcard or regular-expression pattern was refused.
public enum PatternError: Error, Sendable, Equatable {
    case empty
    case tooLong
    case invalidEscape
    case invalidRegex
    case regexTooComplex
}
