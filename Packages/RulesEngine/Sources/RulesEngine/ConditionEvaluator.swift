import FlowStore
import Foundation

/// Judges a condition group against the current message (D4, D5, D11). Pure and synchronous: it never
/// throws, never blocks and takes only `Sendable` values, so it may run on any thread (D13).
///
/// A row on the old path (`ConditionRow.evaluationPath == .legacy`) is the R1 matcher, bit for bit,
/// on the current target and status. Every other row reads the current message through
/// `MessageFields`, compares with `TextComparison` / `NumberComparison` / `DateComparison`, and runs
/// a regular expression in find mode out of the exchange's `RegexAllowance`.
enum ConditionEvaluator {
    /// One row's answer.
    private enum RowResult {
        case matched, noMatch
        /// The row has nothing to look at yet, or the value is not known; the code says why, when the
        /// user should be told (D19).
        case unknown(RuleOutcomeCode?)
        /// A regular expression ran out of time or is switched off: it decides the whole group.
        case problem(RuleMatchResult)
        /// The row cannot be read (a stored row validation would refuse): it never matches, and as in
        /// R1 the group stops there with `.noMatch`, whatever the mode.
        case unreadable
    }

    /// What a row's field reads on the current message.
    private enum FieldValue {
        case text(String)
        case number(Int)
        case date(Date)
        case bool(Bool)
        /// One of the field's fixed values, compared without regard to case.
        case choice(String)
        /// Every value the field has on the message (a header or cookie of that name can repeat). `present`
        /// says whether there was any; `values` is then never empty: a missing one reads as the empty string,
        /// as a single value always did.
        case multi(values: [String], present: Bool)
        case unknown(RuleOutcomeCode?)
        case unreadable
    }

    /// Cheap rows first, then the regular-expression and body rows, each in the order written. `all`
    /// stops at the first row that does not match, `any` at the first that does, `none` at the first
    /// that does (and then does not match). A row whose value is unknown does not match: `all` and
    /// `none` stop there with `.noMatch` (nothing seen, so "no row matches" cannot be said), `any`
    /// goes on and says why only if no other row matches (D5). A pattern problem decides the group
    /// whatever the mode, as in R1. No rows match every session.
    static func evaluate(
        _ group: ConditionGroup, _ input: ConditionInput, allowance: RegexAllowance, cache: PatternCache,
        limits: RulesLimits = RulesLimits()
    ) -> ConditionVerdict {
        guard !group.rows.isEmpty else { return ConditionVerdict(result: .matched) }
        var notes: [RuleOutcomeCode] = []
        for pass in 0..<2 {
            let expensivePass = pass == 1
            for row in group.rows where isExpensive(row) == expensivePass {
                switch evaluate(row, input, allowance: allowance, cache: cache, limits: limits) {
                case .unreadable:
                    return ConditionVerdict(result: .noMatch, notes: notes)
                case .problem(let problem):
                    return ConditionVerdict(result: problem, notes: notes)
                case .matched:
                    switch group.mode {
                    case .all: break
                    case .any: return ConditionVerdict(result: .matched)
                    case .none: return ConditionVerdict(result: .noMatch, notes: notes)
                    }
                case .noMatch:
                    if group.mode == .all { return ConditionVerdict(result: .noMatch, notes: notes) }
                case .unknown(let code):
                    if let code, !notes.contains(code) { notes.append(code) }
                    if group.mode != .any { return ConditionVerdict(result: .noMatch, notes: notes) }
                }
            }
        }
        return group.mode == .any ? ConditionVerdict(result: .noMatch, notes: notes) : ConditionVerdict(result: .matched)
    }

    /// Regular expressions and bodies cost the most, so a cheaper row may settle the group first.
    private static func isExpensive(_ row: ConditionRow) -> Bool {
        row.op == .regex || row.op == .regexWhole || row.field == .requestBody || row.field == .responseBody
            || row.runsMagicStringRegex
    }

    private static func evaluate(
        _ row: ConditionRow, _ input: ConditionInput, allowance: RegexAllowance, cache: PatternCache,
        limits: RulesLimits
    ) -> RowResult {
        // R1 refuses these rows and never matches them; they must not reach the new comparisons.
        if row.isLegacyNeverMatching { return .unreadable }
        if case .legacy(let matcher) = row.evaluationPath {
            switch matcher.evaluate(input.target, status: input.response?.status, cache: cache) {
            case .matched: return .matched
            case .noMatch: return .noMatch
            case let problem: return .problem(problem)
            }
        }
        // The Classic match string has no comparison of its own: whatever operator the row stores is ignored.
        if row.field == .magicString { return magicString(row, input, allowance: allowance, cache: cache) }
        let name = (row.name?.isEmpty ?? true) ? nil : row.name
        guard ConditionOperator.allowed(for: row.field, name: name).contains(row.op) else { return .unreadable }
        if row.op == .isEmpty || row.op == .isNotEmpty, case .number = row.field.valueKind(name: name) {
            // A number that is not there (no response, size unknown) is empty; one that is, is not.
            switch value(of: row, name: name, input) {
            case .unknown(let code) where code != .appUnknown: return (row.op == .isEmpty) ? .matched : .noMatch
            case .unknown(let code): return .unknown(code)
            case .unreadable: return .unreadable
            default: return (row.op == .isEmpty) ? .noMatch : .matched
            }
        }
        switch value(of: row, name: name, input) {
        case .unknown(let code):
            return .unknown(code)
        case .multi(let values, let present):
            return compareMulti(row, values: values, present: present, allowance: allowance, cache: cache)
        case .unreadable:
            return .unreadable
        case .text(let text):
            if row.field == .requestBody || row.field == .responseBody, row.op == .regex {
                return compareBody(row, text: text, cache: cache, limits: limits, cap: input.bodyRegexLimit)
            }
            return compare(row, text: text, allowance: allowance, cache: cache)
        case .number(let number):
            // The result column also compares as text (spec §5.2).
            if [.contains, .startsWith, .regex].contains(row.op) {
                return compare(row, text: String(number), allowance: allowance, cache: cache)
            }
            return answer(NumberComparison.test(row.op, actual: number, expected: row.value))
        case .date(let date):
            if row.op == .isEmpty { return .noMatch }
            if row.op == .isNotEmpty { return .matched }
            return answer(
                DateComparison.test(row.op, actual: date, expected: row.value, timeZone: input.facts.timeZone))
        case .bool(let actual):
            let expected: Bool
            switch row.value.lowercased() {
            case "true": expected = true
            case "false": expected = false
            default: return .unreadable
            }
            return answer(equality(row.op, actual == expected))
        case .choice(let actual):
            let expected = row.value.lowercased()
            guard row.field.acceptedChoices(name: name).contains(expected) else { return .unreadable }
            return answer(equality(row.op, actual.lowercased() == expected))
        }
    }

    /// The Classic match string against the request's URL, method and headers (spec section 12.5). A string
    /// that does not parse never matches.
    private static func magicString(
        _ row: ConditionRow, _ input: ConditionInput, allowance: RegexAllowance, cache: PatternCache
    ) -> RowResult {
        guard let condition = MagicStringCondition.parse(row.value) else { return .unreadable }
        let target = input.target
        if let method = condition.method, target.method.uppercased() != method { return .noMatch }
        let url = target.url
        switch condition.test {
        case .all:
            return .matched
        case .contains(let text):
            return TextComparison.test(.contains, actual: url, expected: text, caseSensitive: false) ? .matched : .noMatch
        case .exact(let text):
            return TextComparison.test(.equals, actual: url, expected: text, caseSensitive: true) ? .matched : .noMatch
        case .notContains(let text):
            return TextComparison.test(.notContains, actual: url, expected: text, caseSensitive: false)
                ? .matched : .noMatch
        case .regex(let pattern):
            return compare(
                ConditionRow(field: .url, op: .regex, value: pattern), text: url, allowance: allowance, cache: cache)
        case .header(let name, let value):
            let values = MessageFields.headerValues(name, in: input.requestHeaders, nameCaseSensitive: false)
            guard let value else { return values.isEmpty ? .noMatch : .matched }
            return values.contains { TextComparison.test(.contains, actual: $0, expected: value, caseSensitive: false) }
                ? .matched : .noMatch
        }
    }

    /// A key-value field with several values: a positive comparison holds when any value satisfies it, a
    /// negative one (`notEquals`, `notContains`) when none satisfies the positive form; `exists` / `doesNotExist`
    /// ask whether there was a value at all. A pattern problem on any value decides the row.
    private static func compareMulti(
        _ row: ConditionRow, values: [String], present: Bool, allowance: RegexAllowance, cache: PatternCache
    ) -> RowResult {
        switch row.op {
        case .exists: return present ? .matched : .noMatch
        case .doesNotExist: return present ? .noMatch : .matched
        default: break
        }
        var positive = row
        switch row.op {
        case .notEquals: positive.op = .equals
        case .notContains: positive.op = .contains
        default: break
        }
        var anyMatched = false
        for text in values {
            switch compare(positive, text: text, allowance: allowance, cache: cache) {
            case .matched: anyMatched = true
            case .noMatch: break
            case let other: return other
            }
            if anyMatched { break }
        }
        return (positive.op == row.op ? anyMatched : !anyMatched) ? .matched : .noMatch
    }

    private static func compare(
        _ row: ConditionRow, text: String, allowance: RegexAllowance, cache: PatternCache
    ) -> RowResult {
        guard row.op == .regex else {
            return TextComparison.test(row.op, actual: text, expected: row.value, caseSensitive: row.caseSensitive)
                ? .matched : .noMatch
        }
        guard let pattern = try? cache.regex(row.value, mode: .find, caseInsensitive: !row.caseSensitive) else {
            return .unreadable
        }
        switch pattern.matches(text, allowance: allowance) {
        case .matched: return .matched
        // Text over the input cap is a miss, not a timeout (D11).
        case .noMatch, .inputTooLong: return .noMatch
        case .timedOut: return .problem(.patternTimedOut)
        case .disabled: return .problem(.patternDisabled)
        }
    }

    /// A body regular expression runs in find mode under the body budget and breaker, outside the
    /// exchange's allowance (D11); text over the body cap is a miss, as for any regular expression.
    private static func compareBody(
        _ row: ConditionRow, text: String, cache: PatternCache, limits: RulesLimits, cap: Duration?
    ) -> RowResult {
        guard let pattern = try? cache.bodyRegex(row.value, caseInsensitive: !row.caseSensitive) else {
            return .unreadable
        }
        switch pattern.matchesBody(text, maxInputBytes: limits.conditionBodyBytes, maxDuration: cap) {
        case .matched: return .matched
        case .noMatch, .inputTooLong: return .noMatch
        case .timedOut: return .problem(.patternTimedOut)
        case .disabled: return .problem(.patternDisabled)
        }
    }

    private static func equality(_ op: ConditionOperator, _ equal: Bool) -> Bool? {
        switch op {
        case .equals: equal
        case .notEquals: !equal
        default: nil
        }
    }

    /// Nil: the expected value cannot be read for this comparison.
    private static func answer(_ outcome: Bool?) -> RowResult {
        guard let outcome else { return .unreadable }
        return outcome ? .matched : .noMatch
    }

    // MARK: reading the current message

    private static func value(of row: ConditionRow, name: String?, _ input: ConditionInput) -> FieldValue {
        let target = input.target
        let facts = input.facts
        switch row.field {
        case .allSessions:
            return .unreadable  // Always the old path.
        case .url: return .text(target.url)
        case .host: return .text(normalizedHost(target.host))
        case .port: return .number(target.port)
        case .scheme: return .choice(target.scheme)
        case .method: return .text(target.method)
        case .path: return .text(MessageFields.path(of: target.pathAndQuery))
        case .queryString: return .text(MessageFields.queryString(of: target.pathAndQuery))
        case .pathAndQuery: return .text(target.pathAndQuery)
        case .queryParam:
            guard let name else { return .unreadable }
            return .text(MessageFields.queryParam(name, inPathAndQuery: target.pathAndQuery) ?? "")
        case .requestHeader:
            return multi(MessageFields.headerValues(name, in: input.requestHeaders, nameCaseSensitive: row.effectiveNameCaseSensitive))
        case .requestCookie:
            return multi(
                MessageFields.cookieValues(
                    name, inRequestHeaders: input.requestHeaders, nameCaseSensitive: row.effectiveNameCaseSensitive))
        case .responseHeader:
            guard let response = input.response else { return .unknown(nil) }
            return multi(MessageFields.headerValues(name, in: response.headers, nameCaseSensitive: row.effectiveNameCaseSensitive))
        case .responseCookie:
            guard let response = input.response else { return .unknown(nil) }
            return multi(
                MessageFields.setCookieValues(
                    name, inResponseHeaders: response.headers, nameCaseSensitive: row.effectiveNameCaseSensitive))
        case .cookie:
            guard let response = input.response else { return .unknown(nil) }
            return multi(
                MessageFields.cookieValues(
                    name, inRequestHeaders: input.requestHeaders, nameCaseSensitive: row.effectiveNameCaseSensitive)
                    + MessageFields.setCookieValues(
                        name, inResponseHeaders: response.headers, nameCaseSensitive: row.effectiveNameCaseSensitive))
        case .tlsVersion:
            let known = [facts.clientTLSVersion, facts.upstreamTLSVersion].compactMap { $0 }
            return known.isEmpty ? .unknown(nil) : .multi(values: known, present: true)
        case .magicString:
            return .unreadable  // Judged by `magicString(_:_:allowance:cache:)` before any value is read.
        case .statusCode:
            guard let response = input.response else { return .unknown(nil) }
            return .number(response.status)
        case .requestBodySize:
            guard let length = declaredLength(input.requestHeaders) else { return .unknown(.unknownSize) }
            return .number(length)
        case .clientHTTPVersion: return httpVersion(facts.clientHTTPVersion, row: row)
        case .upstreamHTTPVersion: return httpVersion(facts.upstreamHTTPVersion, row: row)
        case .clientTLSVersion: return facts.clientTLSVersion.map { .text($0) } ?? .unknown(nil)
        case .upstreamTLSVersion: return facts.upstreamTLSVersion.map { .text($0) } ?? .unknown(nil)
        case .clientIP: return facts.clientIP.map { .text($0) } ?? .unknown(nil)
        case .remoteIP: return facts.remoteIP.map { .text($0) } ?? .unknown(nil)
        case .certificate:
            guard let name else { return .unreadable }
            guard let certificate = facts.certificate else { return .unknown(nil) }
            return certificatePart(name, of: certificate, at: facts.requestStartedAt)
        case .clientApp:
            switch facts.app {
            case .unknown: return .unknown(.appUnknown)
            case .notApplicable: return .unknown(nil)
            case .known(let app):
                guard let name else { return .text("\(app.name):\(app.pid)") }
                switch name {
                case "name": return .text(app.name)
                case "path": return .text(app.executablePath ?? "")
                case "pid": return .number(Int(app.pid))
                default: return .unreadable
                }
            }
        case .requestTime: return .text(timeText(facts.requestStartedAt, timeZone: facts.timeZone))
        case .requestDate: return .date(facts.requestStartedAt)
        case .appProtocol:
            // An SSE row needs the response's Content-Type (its judgment point is the response).
            if input.response == nil, row.value.lowercased() == "sse" { return .unknown(nil) }
            return .choice(
                MessageFields.appProtocol(
                    requestHeaders: input.requestHeaders, target: target, responseHeaders: input.response?.headers))
        case .rulesModified: return .bool(facts.rulesModified)
        case .comment: return .text(facts.comment ?? "")
        case .sessionState:
            // The old values (completed, failed, tunnel) read the finished exchange, as before.
            if ConditionField.legacySessionStates.contains(row.value.lowercased()) {
                return input.completion.map { .choice($0.state.rawValue) } ?? .unknown(nil)
            }
            if input.completion != nil { return .choice("closed") }
            return .choice(facts.isPausedAtBreakpoint ? "paused" : "opened")
        case .durationMs: return input.completion.map { .number($0.durationMilliseconds) } ?? .unknown(nil)
        case .responseBodySize:
            // What came over the wire; nothing did when there was no response.
            guard let completion = input.completion else { return .unknown(nil) }
            return completion.responseWireBytes.map { .number($0) } ?? .unknown(.unknownSize)
        case .requestBody: return peekValue(input.requestBody)
        case .responseBody: return peekValue(input.responseBody)
        }
    }

    private static func multi(_ values: [String]) -> FieldValue {
        .multi(values: values.isEmpty ? [""] : values, present: !values.isEmpty)
    }

    /// `HTTP/1.0`, `HTTP/1.1`, `HTTP/2` as text; a saved row that says `h1` / `h2` keeps the coarse reading.
    private static func httpVersion(_ version: HTTPWireVersion?, row: ConditionRow) -> FieldValue {
        guard let version else { return .unknown(nil) }
        if ["h1", "h2"].contains(row.value.lowercased()), row.op == .equals || row.op == .notEquals {
            return .choice(MessageFields.httpVersionLabel(version))
        }
        return .text(MessageFields.httpVersionText(version))
    }

    /// A body that is there compares as text (none as the empty string); one that was not read is
    /// unknown, and says why when it was skipped.
    private static func peekValue(_ peek: BodyPeek) -> FieldValue {
        switch peek {
        case .notCollected: .unknown(nil)
        case .empty: .text("")
        case .text(let text), .readOnlyText(let text): .text(text)
        case .skipped(let code): .unknown(code)
        }
    }

    /// Lowercase, no brackets or trailing dot, IPv6 in its canonical spelling: as `RuleMatcher` reads a host.
    private static func normalizedHost(_ host: String) -> String {
        let normalized = HostPattern.normalize(host)
        return RuleMatcher.canonicalIPv6(normalized) ?? normalized
    }

    /// The `Content-Length` of a message without `Transfer-Encoding`; nil when there is none or it is not
    /// a plain whole number.
    fileprivate static func declaredLength(_ headers: [HeaderField]) -> Int? {
        guard headers.values(for: "transfer-encoding").isEmpty, let first = headers.values(for: "content-length").first
        else { return nil }
        return ConditionValues.wholeNumber(first.trimmingCharacters(in: CharacterSet(charactersIn: " \t")))
    }

    /// The six original keys read exactly as they always did (dates as UTC `yyyy-MM-dd'T'HH:mm:ss'Z'` text, D9);
    /// every other key is one of the 17 `CertificateField` items. Validity is judged at `now`, the time the
    /// exchange began.
    private static func certificatePart(_ name: String, of certificate: CertificateSummary, at now: Date) -> FieldValue {
        if let legacy = LegacyCertificateKey(conditionKey: name) { return .text(legacy.text(in: certificate)) }
        guard let item = CertificateField(conditionKey: name) else { return .unreadable }
        switch item.value(in: certificate, now: now) {
        case .unknown: return .unknown(nil)
        case .number(let number): return .number(number)
        case .date(let date): return .date(date)
        case .bool(let valid): return .choice(valid ? "valid" : "invalid")
        case .text(let text):
            // Alternative names are tried one by one: any matching name matches.
            if item == .subjectAlternativeName { return multi(item.textCandidates(in: certificate)) }
            return .text(text)
        }
    }

    /// `HH:mm:ss.SSS` in `timeZone`, the list's default time column (D6). Milliseconds are cut, not
    /// rounded, after the time is taken to the nearest microsecond so a stored `.123` stays `.123`.
    static func timeText(_ date: Date, timeZone: TimeZone) -> String {
        let micros = (date.timeIntervalSince1970 * 1_000_000).rounded()
        let millis = (micros / 1000).rounded(.down)
        let seconds = (millis / 1000).rounded(.down)
        let fraction = Int(millis - seconds * 1000)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.hour, .minute, .second], from: Date(timeIntervalSince1970: seconds))
        return String(format: "%02d:%02d:%02d.%03d", parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0, fraction)
    }
}

extension ConditionEvaluator {
    /// Whether `group` could match once more is known (the request-body pre-pass, D12): false only when
    /// the rows that are already decidable rule it out. Body rows, regular-expression rows, rows judged
    /// after the request head and rows whose value is unknown or unreadable all count as "possibly
    /// true", so the answer errs towards true. No regular expression runs.
    static func mayMatch(
        _ group: ConditionGroup, _ input: ConditionInput, cache: PatternCache, through point: EvaluationPoint = .request
    ) -> Bool {
        guard !group.rows.isEmpty else { return true }
        var possible = false
        for row in group.rows {
            let answer: Bool?
            if row.field == .requestBody || row.field == .responseBody || row.op == .regex || row.op == .regexWhole
                || row.runsMagicStringRegex || row.knowablePoint > point
            {
                answer = nil
            } else {
                switch evaluate(row, input, allowance: RegexAllowance(), cache: cache, limits: RulesLimits()) {
                case .matched: answer = true
                case .noMatch: answer = false
                case .unknown, .problem, .unreadable: answer = nil
                }
            }
            switch (group.mode, answer) {
            case (.all, false?), (.none, true?): return false
            case (.any, true?), (.any, nil): possible = true
            default: break
            }
        }
        // `all` / `none`: nothing ruled it out. `any`: some row is or may be true.
        return group.mode != .any || possible
    }
}

/// The texts the condition rows compare, for callers that suggest values: one implementation, so a suggestion is exactly
/// what the row will read.
public enum ConditionFieldText {
    /// What the request-time row compares: `HH:mm:ss.SSS` in `timeZone`.
    public static func requestTime(_ date: Date, timeZone: TimeZone = .current) -> String {
        ConditionEvaluator.timeText(date, timeZone: timeZone)
    }

    /// What the request-size row reads: the `Content-Length` of a message without `Transfer-Encoding`; nil otherwise.
    public static func declaredRequestLength(_ headers: [HeaderField]) -> Int? {
        ConditionEvaluator.declaredLength(headers)
    }
}
