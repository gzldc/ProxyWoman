import Foundation

/// Where in an exchange's life a rule is evaluated. A condition's field decides the earliest point
/// at which it has a value; a rule judges at the latest point among its rows.
public enum EvaluationPoint: Int, Comparable, Codable, Sendable {
    /// The CONNECT line (or the first thing known about a connection).
    case connect = 0
    /// The request head.
    case request
    /// The response head.
    case response
    /// The finished exchange.
    case completion

    public static func < (lhs: EvaluationPoint, rhs: EvaluationPoint) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// What a condition row looks at. Raw values are stored in `rules.json`; append, never reorder.
public enum ConditionField: String, Codable, Sendable, CaseIterable, Hashable {
    case allSessions, scheme, host, port, method, pathAndQuery, statusCode
    // Rules 2.0 R3. Appended after the seven above; never reorder.
    case url, path, queryString, queryParam, requestHeader, responseHeader, requestCookie, responseCookie
    case requestBody, responseBody, requestBodySize, responseBodySize, sessionState, durationMs, requestTime
    case requestDate, clientHTTPVersion, upstreamHTTPVersion, clientTLSVersion, upstreamTLSVersion, certificate
    case clientIP, remoteIP, clientApp, appProtocol, rulesModified, comment
    // Rules 2.0 R8F2. Appended; never reorder. `cookie` reads the request Cookie or the response Set-Cookie,
    // `tlsVersion` the client's or the remote's; `magicString` is the Classic auto-responder match string.
    case cookie, tlsVersion, magicString

    /// The earliest point at which the field has a value.
    public var knowablePoint: EvaluationPoint {
        switch self {
        case .allSessions, .url, .scheme, .host, .port, .method, .requestTime, .requestDate, .clientIP, .clientApp,
            .rulesModified, .comment:
            .connect
        case .path, .queryString, .queryParam, .requestHeader, .requestCookie, .requestBody, .requestBodySize,
            .clientHTTPVersion, .clientTLSVersion, .appProtocol, .pathAndQuery, .magicString:
            .request
        case .statusCode, .responseHeader, .responseCookie, .responseBody, .upstreamHTTPVersion, .upstreamTLSVersion,
            .certificate, .remoteIP, .cookie, .tlsVersion:
            .response
        case .responseBodySize, .sessionState, .durationMs: .completion
        }
    }
}

/// How a row compares the field with its value. Raw values are stored in `rules.json`.
public enum ConditionOperator: String, Codable, Sendable, CaseIterable, Hashable {
    case equals, startsWith, inRange
    /// Old-style operators: produced only by migration and the old editor, never offered for new rows.
    case hostPattern, wildcard, regexWhole
    // Rules 2.0 R3. Appended after the six above; never reorder.
    case notEquals, contains, notContains, endsWith, isEmpty, isNotEmpty, regex
    case greaterThan, greaterOrEqual, lessThan, lessOrEqual, before, after
    // Rules 2.0 R8F2. Appended; never reorder.
    case exists, doesNotExist, afterOrEqual, beforeOrEqual
}

public struct ConditionRow: Codable, Sendable, Equatable, Hashable {
    public var field: ConditionField
    /// The key of a header, cookie, query parameter and the like; unused by the current fields.
    public var name: String?
    public var op: ConditionOperator
    public var value: String
    public var caseSensitive: Bool
    /// Whether the key (a header or cookie name) is compared with case. Nil, which every file saved before the key
    /// existed decodes as, is what each field did then: header names without case, cookie names with it
    /// (`effectiveNameCaseSensitive`). A row the editor writes stores an explicit value.
    public var nameCaseSensitive: Bool?

    public init(
        field: ConditionField, name: String? = nil, op: ConditionOperator, value: String = "",
        caseSensitive: Bool = false, nameCaseSensitive: Bool? = nil
    ) {
        self.field = field
        self.name = name
        self.op = op
        self.value = value
        self.caseSensitive = caseSensitive
        self.nameCaseSensitive = nameCaseSensitive
    }

    private enum CodingKeys: String, CodingKey {
        case field, name, op, value, caseSensitive, nameCaseSensitive
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        field = try container.decode(ConditionField.self, forKey: .field)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        op = try container.decode(ConditionOperator.self, forKey: .op)
        value = try container.decode(String.self, forKey: .value)
        caseSensitive = try container.decode(Bool.self, forKey: .caseSensitive)
        nameCaseSensitive = try container.decodeIfPresent(Bool.self, forKey: .nameCaseSensitive)
    }

    /// The comparison the row really uses: its own setting, else the field's behaviour before the setting existed.
    public var effectiveNameCaseSensitive: Bool { nameCaseSensitive ?? field.legacyNameCaseSensitive }

    /// Same keys and order as the synthesized encoding before `nameCaseSensitive` existed; the new key is
    /// written only when it is set, so an old file round-trips byte for byte.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(field, forKey: .field)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encode(op, forKey: .op)
        try container.encode(value, forKey: .value)
        try container.encode(caseSensitive, forKey: .caseSensitive)
        try container.encodeIfPresent(nameCaseSensitive, forKey: .nameCaseSensitive)
    }
}

/// Which of a rule's matching exchanges the rule acts on.
public enum Occurrence: Codable, Sendable, Equatable, Hashable {
    case any
    /// Only the n-th matching exchange for n in the range (1-based).
    case times(ClosedRange<Int>)
}

public struct ConditionGroup: Codable, Sendable, Equatable, Hashable {
    public enum Mode: String, Codable, Sendable, CaseIterable {
        /// Every row must match.
        case all
        /// At least one row must match.
        case any
        /// No row may match.
        case none
    }

    public var mode: Mode
    public var occurrence: Occurrence
    /// No rows means every session.
    public var rows: [ConditionRow]

    public init(mode: Mode = .all, occurrence: Occurrence = .any, rows: [ConditionRow] = []) {
        self.mode = mode
        self.occurrence = occurrence
        self.rows = rows
    }
}

extension ConditionGroup {
    /// Whether the rows, combined by `mode`, match the current message (`ConditionEvaluator`). This is
    /// what `RuleEvaluator` uses; `evaluate(_:status:cache:)` stays for the frozen oracle and old tests.
    public func evaluate(
        _ input: ConditionInput, allowance: RegexAllowance, cache: PatternCache = .shared,
        limits: RulesLimits = RulesLimits()
    ) -> ConditionVerdict {
        ConditionEvaluator.evaluate(self, input, allowance: allowance, cache: cache, limits: limits)
    }
}
