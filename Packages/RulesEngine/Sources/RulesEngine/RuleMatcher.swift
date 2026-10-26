import Foundation
import FlowStore

public enum PathMatch: Sendable, Equatable, Hashable, Codable {
    case any
    /// The whole origin-form path and query, byte for byte (case-sensitive, no decoding).
    case exact(String)
    /// A scalar-string prefix of path and query; no segment boundary is implied.
    case prefix(String)
    /// A whole-string `WildcardPattern` over the raw path and query (no percent-decoding).
    case wildcard(String)
    /// A whole-string, case-sensitive regular expression over the raw path and query.
    case regex(String)
}

/// All present fields must match (AND).
public struct RuleMatcher: Sendable, Equatable, Hashable, Codable {
    public var scheme: String?
    /// With `hostSyntax == .literal`: exact host or `*.example.com`, with `HostPattern` semantics.
    /// Otherwise a whole-string wildcard or (case-insensitive) regular expression over the host.
    public var hostPattern: String?
    public var port: Int?
    public var method: String?
    public var path: PathMatch
    /// Response rules only.
    public var statusRange: ClosedRange<Int>?
    public var hostSyntax: PatternSyntax

    public init(
        scheme: String? = nil, hostPattern: String? = nil, port: Int? = nil, method: String? = nil,
        path: PathMatch = .any, statusRange: ClosedRange<Int>? = nil, hostSyntax: PatternSyntax = .literal
    ) {
        self.scheme = scheme
        self.hostPattern = hostPattern
        self.port = port
        self.method = method
        self.path = path
        self.statusRange = statusRange
        self.hostSyntax = hostSyntax
    }

    private enum CodingKeys: String, CodingKey {
        case scheme, hostPattern, port, method, path, statusRange, hostSyntax
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        scheme = try container.decodeIfPresent(String.self, forKey: .scheme)
        hostPattern = try container.decodeIfPresent(String.self, forKey: .hostPattern)
        port = try container.decodeIfPresent(Int.self, forKey: .port)
        method = try container.decodeIfPresent(String.self, forKey: .method)
        path = try container.decode(PathMatch.self, forKey: .path)
        statusRange = try container.decodeIfPresent(ClosedRange<Int>.self, forKey: .statusRange)
        hostSyntax = try container.decodeIfPresent(PatternSyntax.self, forKey: .hostSyntax) ?? .literal
    }

    /// Everything but `hostSyntax` is encoded as before; a literal matcher writes no new key, so
    /// rule files without advanced syntax keep their exact bytes.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(scheme, forKey: .scheme)
        try container.encodeIfPresent(hostPattern, forKey: .hostPattern)
        try container.encodeIfPresent(port, forKey: .port)
        try container.encodeIfPresent(method, forKey: .method)
        try container.encode(path, forKey: .path)
        try container.encodeIfPresent(statusRange, forKey: .statusRange)
        if hostSyntax != .literal { try container.encode(hostSyntax, forKey: .hostSyntax) }
    }

    /// True when the host or path uses wildcard or regular-expression syntax (rules file schema 2).
    public var usesAdvancedSyntax: Bool {
        if hostSyntax != .literal { return true }
        switch path {
        case .wildcard, .regex: return true
        case .any, .exact, .prefix: return false
        }
    }

    /// `status` is nil while a request is evaluated; a status range then never matches.
    public func matches(_ target: HTTPMessageTarget, status: Int?, cache: PatternCache = .shared) -> Bool {
        evaluate(target, status: status, cache: cache) == .matched
    }

    /// Like `matches`, but says why a regular expression could not give an answer. The cheap
    /// literal fields are checked first so a pattern problem is only reported for a request the
    /// rule would otherwise have matched.
    public func evaluate(_ target: HTTPMessageTarget, status: Int?, cache: PatternCache = .shared) -> RuleMatchResult {
        if let scheme, scheme.lowercased() != target.scheme.lowercased() { return .noMatch }
        if let port, port != target.port { return .noMatch }
        if let method, method != target.method { return .noMatch }
        if let statusRange {
            guard let status, statusRange.contains(status) else { return .noMatch }
        }
        if let hostPattern {
            let host = hostAccepts(hostPattern, host: target.host, cache: cache)
            if host != .matched { return host }
        }
        switch path {
        case .any: break
        case .exact(let value): if !target.pathAndQuery.utf8.elementsEqual(value.utf8) { return .noMatch }
        case .prefix(let value): if !target.pathAndQuery.utf8.starts(with: value.utf8) { return .noMatch }
        case .wildcard(let value):
            guard let pattern = try? cache.wildcard(value), pattern.matches(target.pathAndQuery) else { return .noMatch }
        case .regex(let value):
            guard let pattern = try? cache.regex(value, caseInsensitive: false) else { return .noMatch }
            let result = Self.result(of: pattern.matches(target.pathAndQuery))
            if result != .matched { return result }
        }
        return .matched
    }

    private static func result(of regex: RegexMatchResult) -> RuleMatchResult {
        switch regex {
        case .matched: .matched
        case .timedOut: .patternTimedOut
        case .disabled: .patternDisabled
        case .noMatch, .inputTooLong: .noMatch
        }
    }

    /// True when a regular expression of this matcher is switched off by its circuit breaker.
    public func hasDisabledPattern(in cache: PatternCache = .shared) -> Bool {
        if hostSyntax == .regex, let hostPattern, cache.isRegexDisabled(hostPattern, caseInsensitive: true) { return true }
        if case .regex(let value) = path, cache.isRegexDisabled(value, caseInsensitive: false) { return true }
        return false
    }

    /// Compiles this matcher's wildcard and regular-expression patterns into the cache and
    /// switches a disabled regex back on. Called when a rule or an Allow/Block entry is published
    /// (saved): editing is the documented way to re-enable a pattern. Invalid patterns are skipped
    /// (validation refuses them before they get here).
    public func preparePatterns(in cache: PatternCache = .shared) {
        switch hostSyntax {
        case .literal: break
        case .wildcard:
            if let hostPattern { _ = try? cache.wildcard(Self.wildcardHostPattern(hostPattern)) }
        case .regex:
            if let hostPattern { try? cache.prepareRegex(hostPattern, caseInsensitive: true) }
        }
        switch path {
        case .any, .exact, .prefix: break
        case .wildcard(let value): _ = try? cache.wildcard(value)
        case .regex(let value): try? cache.prepareRegex(value, caseInsensitive: false)
        }
    }

    /// Longest host (UTF-8 bytes) a host regex is run against.
    static let maxRegexHostBytes = 255

    private func hostAccepts(_ pattern: String, host: String, cache: PatternCache) -> RuleMatchResult {
        switch hostSyntax {
        case .literal:
            return Self.hostMatches(pattern, host: host) ? .matched : .noMatch
        case .wildcard:
            let normalizedHost = Self.normalizedHost(host)
            guard let compiled = try? cache.wildcard(Self.wildcardHostPattern(pattern)) else { return .noMatch }
            return compiled.matches(normalizedHost) ? .matched : .noMatch
        case .regex:
            let normalizedHost = Self.normalizedHost(host)
            guard normalizedHost.utf8.count <= Self.maxRegexHostBytes,
                let compiled = try? cache.regex(pattern, caseInsensitive: true)
            else { return .noMatch }
            return Self.result(of: compiled.matches(normalizedHost))
        }
    }

    /// Lowercase, no brackets or trailing dot, IPv6 in its canonical spelling.
    private static func normalizedHost(_ host: String) -> String {
        let normalized = HostPattern.normalize(host)
        return canonicalIPv6(normalized) ?? normalized
    }

    /// The wildcard compiled for a host: normalized like the host (`*`, `?` and escapes survive).
    static func wildcardHostPattern(_ pattern: String) -> String {
        let normalized = HostPattern.normalize(pattern)
        return canonicalIPv6(normalized) ?? normalized
    }

    /// IPv6 spellings of one address are the same host.
    static func hostMatches(_ pattern: String, host: String) -> Bool {
        HostPattern.matches(canonicalIPv6(HostPattern.normalize(pattern)) ?? pattern,
                            host: canonicalIPv6(HostPattern.normalize(host)) ?? host)
    }

    static func canonicalIPv6(_ text: String) -> String? {
        guard text.contains(":") else { return nil }
        var address = in6_addr()
        guard inet_pton(AF_INET6, text, &address) == 1 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &address, &buffer, socklen_t(buffer.count)) != nil else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    public func validate(limits: RulesLimits = RulesLimits()) throws {
        if let scheme {
            guard ["http", "https"].contains(scheme.lowercased()) else {
                throw RuleValidationError(code: .invalidScheme, field: .scheme)
            }
        }
        if let hostPattern {
            try LegacyRule.check(hostPattern, limits, .hostPattern)
            try validateHost(hostPattern)
        }
        if let port, !(1...65_535).contains(port) {
            throw RuleValidationError(code: .invalidPort, field: .port)
        }
        if let method {
            try LegacyRule.check(method, limits, .method)
            guard HTTPMutationValidator.isToken(method) else {
                throw RuleValidationError(code: .invalidMethod, field: .method)
            }
        }
        switch path {
        case .any: break
        case .exact(let value), .prefix(let value):
            try LegacyRule.check(value, limits, .path)
            guard !value.contains("#"), !value.utf8.contains(where: { $0 <= 32 || $0 == 127 }) else {
                throw RuleValidationError(code: .invalidPath, field: .path)
            }
        case .wildcard(let value):
            try LegacyRule.check(value, limits, .path)
            guard !value.contains("#"), !value.utf8.contains(where: { $0 <= 32 || $0 == 127 }) else {
                throw RuleValidationError(code: .invalidPath, field: .path)
            }
            do { _ = try WildcardPattern(value) } catch {
                throw RuleValidationError(code: .invalidWildcard, field: .path)
            }
        case .regex(let value):
            try LegacyRule.check(value, limits, .path)
            try Self.compileRegex(value, caseInsensitive: false, field: .path)
        }
        if let statusRange, statusRange.lowerBound < 100 || statusRange.upperBound > 599 {
            throw RuleValidationError(code: .invalidStatusRange, field: .statusRange)
        }
    }

    private func validateHost(_ hostPattern: String) throws {
        switch hostSyntax {
        case .literal:
            guard HostPattern.normalizedUserPattern(hostPattern) != nil else {
                throw RuleValidationError(code: .invalidHostPattern, field: .hostPattern)
            }
        case .wildcard:
            let invalid = RuleValidationError(code: .invalidWildcard, field: .hostPattern)
            guard !hostPattern.isEmpty, hostPattern.utf8.count <= Self.maxRegexHostBytes,
                !hostPattern.unicodeScalars.contains(where: { $0.properties.isWhitespace || $0 == "/" })
            else { throw invalid }
            do { _ = try WildcardPattern(Self.wildcardHostPattern(hostPattern)) } catch { throw invalid }
        case .regex:
            try Self.compileRegex(hostPattern, caseInsensitive: true, field: .hostPattern)
        }
    }

    /// Compiles the pattern once to check it. Validation is free of side effects: it neither fills
    /// the shared cache nor re-enables a disabled pattern (the editor validates on every keystroke);
    /// `preparePatterns` does both when the rule is published.
    private static func compileRegex(
        _ pattern: String, caseInsensitive: Bool, field: RuleValidationError.Field
    ) throws {
        do {
            _ = try RegexPattern(pattern, caseInsensitive: caseInsensitive)
        } catch PatternError.regexTooComplex {
            throw RuleValidationError(code: .regexTooComplex, field: field)
        } catch {
            throw RuleValidationError(code: .invalidRegex, field: field)
        }
    }
}

/// The answer of one rule matcher for one request or response. A pattern problem is a miss, but
/// it is told apart from an ordinary miss so it can be shown instead of silently ignored.
public enum RuleMatchResult: Sendable, Equatable {
    case matched, noMatch
    /// A regular expression ran out of time on this input.
    case patternTimedOut
    /// A regular expression was switched off by its circuit breaker earlier.
    case patternDisabled
}
