import Foundation

/// Which message a field belongs to.
public enum ConditionSide: Sendable { case request, response, both, neither }

/// The sections of the field menu.
public enum ConditionFieldGroup: Sendable, CaseIterable { case common, request, response, connection, afterCompletion, other }

/// What kind of value a field is compared with.
public enum ConditionValueKind: Sendable, Equatable {
    case none, text, number, date, bool
    case choice([String])
}

extension ConditionField {
    public var side: ConditionSide {
        switch self {
        case .allSessions, .durationMs, .rulesModified, .comment, .sessionState: .neither
        case .url, .scheme, .host, .port, .method, .path, .appProtocol, .cookie, .tlsVersion, .magicString: .both
        case .queryString, .pathAndQuery, .queryParam, .requestHeader, .requestCookie, .requestBody, .requestBodySize,
            .requestTime, .requestDate, .clientHTTPVersion, .clientTLSVersion, .clientIP, .clientApp:
            .request
        case .statusCode, .responseHeader, .responseCookie, .responseBody, .responseBodySize, .upstreamHTTPVersion,
            .upstreamTLSVersion, .certificate, .remoteIP:
            .response
        }
    }

    public var group: ConditionFieldGroup {
        switch self {
        case .allSessions, .url, .scheme, .host, .port, .method, .path, .statusCode: .common
        case .queryString, .pathAndQuery, .queryParam, .requestHeader, .requestCookie, .requestBody, .requestBodySize,
            .requestTime, .requestDate:
            .request
        case .responseHeader, .responseCookie, .responseBody: .response
        case .cookie: .request
        case .clientHTTPVersion, .upstreamHTTPVersion, .clientTLSVersion, .upstreamTLSVersion, .certificate, .clientIP,
            .remoteIP, .clientApp, .appProtocol, .tlsVersion:
            .connection
        case .responseBodySize, .sessionState, .durationMs: .afterCompletion
        case .rulesModified, .comment, .magicString: .other
        }
    }

    /// Whether the row names a key (a header, a cookie, a query parameter, a certificate part, an app part).
    public var takesName: Bool {
        switch self {
        case .queryParam, .requestHeader, .responseHeader, .requestCookie, .responseCookie, .cookie, .certificate,
            .clientApp:
            true
        default: false
        }
    }

    /// Whether the row may leave its key empty: an empty header / cookie key means "any header / cookie",
    /// an empty app key means the whole process (`Name:PID`).
    public var nameIsOptional: Bool {
        switch self {
        case .requestHeader, .responseHeader, .requestCookie, .responseCookie, .cookie, .clientApp: true
        default: false
        }
    }

    /// Whether the key is a header or cookie name, which the row's `nameCaseSensitive` applies to.
    public var hasKeyCaseOption: Bool {
        switch self {
        case .requestHeader, .responseHeader, .requestCookie, .responseCookie, .cookie: true
        default: false
        }
    }

    /// How the key was compared before the row had a setting for it: header names ignored case, cookie names did not.
    /// A row saved then carries no setting and keeps this (R8F2-T1a).
    public var legacyNameCaseSensitive: Bool {
        switch self {
        case .requestCookie, .responseCookie: true
        default: false
        }
    }

    /// The seven fields R1 knew.
    public var isLegacyField: Bool {
        switch self {
        case .allSessions, .scheme, .host, .port, .method, .pathAndQuery, .statusCode: true
        default: false
        }
    }

    public func valueKind(name: String?) -> ConditionValueKind {
        switch self {
        case .allSessions: .none
        case .scheme: .choice(["https", "http"])
        case .url, .host, .method, .path, .queryString, .pathAndQuery, .queryParam, .requestHeader, .responseHeader,
            .requestCookie, .responseCookie, .cookie, .requestBody, .responseBody, .requestTime, .clientTLSVersion,
            .upstreamTLSVersion, .tlsVersion, .clientIP, .remoteIP, .comment, .magicString,
            .clientHTTPVersion, .upstreamHTTPVersion:
            .text
        case .certificate:
            // The six original keys are text; the new items follow `CertificateField.valueKind`.
            switch name.flatMap({ CertificateField(conditionKey: $0) })?.valueKind {
            case .validity?: .choice(["valid", "invalid"])
            case .number?: .number
            case .date?: .date
            case .text?, nil: .text
            }
        case .port, .statusCode, .requestBodySize, .responseBodySize, .durationMs: .number
        case .clientApp: name == "pid" ? .number : .text
        case .requestDate: .date
        case .rulesModified: .bool
        case .sessionState: .choice(["opened", "closed", "paused"])
        case .appProtocol: .choice(["http", "websocket", "rpc", "grpc", "sse", "socketio"])
        }
    }

    /// The values a `choice` field reads besides the ones it offers: the old session states.
    public static let legacySessionStates = ["completed", "failed", "tunnel"]

    /// What a row of a `choice` field may hold: the offered values, and the old ones saved rows still carry.
    func acceptedChoices(name: String?) -> [String] {
        switch self {
        case .clientHTTPVersion, .upstreamHTTPVersion: return ["h1", "h2"]  // Saved rows; the field reads as text now.
        case .sessionState: return ["opened", "closed", "paused"] + Self.legacySessionStates
        default:
            guard case .choice(let offered) = valueKind(name: name) else { return [] }
            return offered
        }
    }

    /// The names a row of this field may carry, or nil when any text goes.
    public static func allowedNames(for field: ConditionField) -> [String]? {
        switch field {
        case .certificate:
            // The 17 items of spec section 12.4, then the original keys that are not among them.
            CertificateField.allCases.map(\.rawValue)
                + LegacyCertificateKey.allCases.map(\.rawValue).filter { CertificateField(conditionKey: $0) == nil }
        case .clientApp: ["name", "path", "pid"]
        default: nil
        }
    }
}

extension ConditionOperator {
    /// Produced only by migration and the old editor.
    public var isLegacyOnly: Bool {
        switch self {
        case .hostPattern, .wildcard, .regexWhole: true
        default: false
        }
    }

    // The four sets of spec §12.3, in the reference menu groups (a rule between groups).
    private static let equality: [ConditionOperator] = [.equals, .notEquals]
    private static let containment: [ConditionOperator] = [.contains, .notContains]
    private static let ends: [ConditionOperator] = [.startsWith, .endsWith]
    private static let emptiness: [ConditionOperator] = [.isEmpty, .isNotEmpty]
    private static let existence: [ConditionOperator] = [.exists, .doesNotExist]
    private static let textSet: [[ConditionOperator]] = [equality, containment, ends, emptiness, [.regex]]
    private static let keyValueSet: [[ConditionOperator]] = [equality, containment, ends, emptiness, existence, [.regex]]
    private static let numberSet: [[ConditionOperator]] = [
        equality, [.greaterOrEqual, .greaterThan], [.lessOrEqual, .lessThan], emptiness, [.regex],
    ]
    private static let dateSet: [[ConditionOperator]] = [
        equality, [.afterOrEqual, .after], [.beforeOrEqual, .before], emptiness,
    ]

    /// The comparisons a new row of this field offers, in the reference menu groups (spec §12.3); never an
    /// old-style one. Empty for a field without a comparison (all sessions, magic string).
    public static func fiddlerOperators(for field: ConditionField, name: String?) -> [[ConditionOperator]] {
        switch field {
        case .allSessions, .magicString: return []
        case .scheme, .appProtocol, .sessionState, .rulesModified: return [[.equals]]
        case .requestHeader, .responseHeader, .requestCookie, .responseCookie, .cookie: return keyValueSet
        case .statusCode, .port, .requestBodySize, .responseBodySize, .durationMs: return numberSet
        case .requestDate: return dateSet
        case .clientApp: return name == "pid" ? numberSet : textSet
        case .certificate:
            // Validity is a choice (value `valid` / `invalid`, see `CertificateField`); the rest follow their kind.
            switch name.flatMap({ CertificateField(conditionKey: $0) })?.valueKind {
            case .validity?: return [[.equals]]
            case .number?: return numberSet
            case .date?: return dateSet
            case .text?, nil: return textSet
            }
        default: return textSet
        }
    }

    /// The comparison a row starts with after its field (or key) was picked: contains for text and
    /// key-value fields, equals for the others.
    public static func defaultOperator(for field: ConditionField, name: String?) -> ConditionOperator {
        switch fiddlerOperators(for: field, name: name) {
        case let sets where sets.joined().contains(.contains): .contains
        default: field == .magicString ? .contains : .equals
        }
    }

    /// What the field took before R8F2; saved rows keep these, so `allowed` still accepts them.
    private static func legacyAllowed(for field: ConditionField, name: String?) -> [ConditionOperator] {
        switch field.valueKind(name: name) {
        case .none: return []
        case .text: return [.equals, .notEquals, .contains, .notContains, .startsWith, .endsWith, .isEmpty, .isNotEmpty, .regex]
        case .number:
            let numeric: [ConditionOperator] = [
                .equals, .notEquals, .greaterThan, .greaterOrEqual, .lessThan, .lessOrEqual, .inRange,
            ]
            // The result column is matched as text too (spec §5.2).
            return field == .statusCode ? numeric + [.contains, .startsWith, .regex] : numeric
        case .date: return [.equals, .notEquals, .before, .after, .inRange]
        case .bool, .choice: return [.equals, .notEquals]
        }
    }

    /// Everything a row of this field may carry: the reference comparisons first, then the ones saved rows
    /// still use (`isLegacyForField`). Evaluation and validation accept exactly this list.
    public static func allowed(for field: ConditionField, name: String?) -> [ConditionOperator] {
        let current = fiddlerOperators(for: field, name: name).flatMap { $0 }
        if current.isEmpty { return field == .magicString ? [.contains] : [] }
        let legacy = legacyAllowed(for: field, name: name).filter { !current.contains($0) }
        return current + legacy
    }

    /// Whether the comparison is accepted only for old rows: the editor shows it as "old style" and never offers it.
    public static func isLegacyForField(_ op: ConditionOperator, field: ConditionField, name: String?) -> Bool {
        let current = fiddlerOperators(for: field, name: name).flatMap { $0 }
        if current.isEmpty { return false }
        return !current.contains(op) && allowed(for: field, name: name).contains(op)
    }
}

extension ConditionRow {
    /// Whether the row is a magic string that runs a regular expression.
    var runsMagicStringRegex: Bool {
        field == .magicString && MagicStringCondition.parse(value)?.usesRegex == true
    }

    /// When the row can be judged: the field's point, except an SSE protocol row, which needs the response's Content-Type.
    /// An RPC protocol row stays at the request point on purpose, so a rule that only asks for RPC (a `SOAPAction`
    /// or `Connect-Protocol-Version` header, a request Content-Type) can still act on the request. The response
    /// Content-Type counts toward RPC only when the whole rule is judged later (for example it also has a
    /// status-code row), because only then does the evaluator get a response (see `MessageFields.isRPC`).
    public var knowablePoint: EvaluationPoint {
        if field == .appProtocol, value.lowercased() == "sse" { return .response }
        if field == .sessionState {
            // Opened and paused are known once the request is; closed (and the old values) at completion.
            return ["opened", "paused"].contains(value.lowercased()) ? .request : .completion
        }
        return field.knowablePoint
    }

    public enum EvaluationPath: Sendable, Equatable {
        /// R1 can say the row: it keeps the old matcher, bit for bit.
        case legacy(RuleMatcher)
        case current
    }

    /// Which evaluator reads the row (D4). A row on the old path that the old matcher cannot read
    /// (`isLegacyNeverMatching`) is `.current` here but must never match, as in R1; the evaluator checks that first.
    public var evaluationPath: EvaluationPath {
        if case .matcher(let matcher) = legacyReading { return .legacy(matcher) }
        return .current
    }
}
