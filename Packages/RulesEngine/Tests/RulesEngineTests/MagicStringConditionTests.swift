import FlowStore
import Foundation
import Testing

@testable import RulesEngine

private let utc = TimeZone(identifier: "UTC")!

private func input(
    method: String = "GET", path: String = "/v1/Items?a=1", requestHeaders: [HeaderField] = [],
    certificate: CertificateSummary? = nil, startedAt: Date = Date(timeIntervalSince1970: 1_500_000)
) -> ConditionInput {
    ConditionInput(
        target: HTTPMessageTarget(scheme: "https", host: "api.example.com", port: 443, method: method, pathAndQuery: path),
        requestHeaders: requestHeaders, response: (200, []),
        facts: ExchangeFacts(certificate: certificate, requestStartedAt: startedAt, timeZone: utc))
}

private func result(_ row: ConditionRow, _ input: ConditionInput) -> RuleMatchResult {
    ConditionGroup(rows: [row]).evaluate(
        input, allowance: RegexAllowance(total: .seconds(100)), cache: PatternCache(budget: RegexBudget(clock: { .zero })))
        .result
}

private func magic(_ value: String, op: ConditionOperator = .contains) -> ConditionRow {
    ConditionRow(field: .magicString, op: op, value: value)
}

@Suite("MagicStringCondition")
struct MagicStringConditionTests {
    // MARK: parser

    @Test func parseTable() {
        let table: [(String, MagicStringCondition?)] = [
            ("", nil),
            ("*", .init(test: .all)),
            ("api.example", .init(test: .contains("api.example"))),
            ("EXACT:https://a.test/x", .init(test: .exact("https://a.test/x"))),
            ("exact:X", .init(test: .exact("X"))),
            ("EXACT:", nil),
            ("NOT:/admin", .init(test: .notContains("/admin"))),
            ("NOT:", nil),
            ("REGEX:items/\\d+", .init(test: .regex("items/\\d+"))),
            ("REGEX:(?-i)Items", .init(test: .regex("(?-i)Items"))),
            ("REGEX:", nil),
            ("METHOD:GET api", .init(method: "GET", test: .contains("api"))),
            ("method:post EXACT:https://a.test/", .init(method: "POST", test: .exact("https://a.test/"))),
            ("METHOD:GET NOT:x", .init(method: "GET", test: .notContains("x"))),
            ("METHOD:GET REGEX:a+", .init(method: "GET", test: .regex("a+"))),
            ("METHOD:DELETE *", .init(method: "DELETE", test: .all)),
            ("METHOD:GET", .init(method: "GET", test: .all)),
            ("METHOD:  api", nil),
            ("METHOD:G@T api", nil),
            ("HEADER:X-Test=abc", .init(test: .header(name: "X-Test", value: "abc"))),
            ("HEADER:X-Test=", .init(test: .header(name: "X-Test", value: ""))),
            ("HEADER:X-Test", .init(test: .header(name: "X-Test", value: nil))),
            ("HEADER:X=a=b", .init(test: .header(name: "X", value: "a=b"))),
            ("HEADER:", nil),
            ("HEADER:=v", nil),
            ("METHOD:GET HEADER:X", .init(method: "GET", test: .header(name: "X", value: nil))),
        ]
        for (text, expected) in table {
            #expect(MagicStringCondition.parse(text) == expected, "\(text)")
        }
    }

    // MARK: evaluation

    @Test func evaluationTable() {
        let headers = [HeaderField(name: "X-Test", value: "Alpha-Beta"), HeaderField(name: "Accept", value: "*/*")]
        let table: [(String, String, Bool)] = [
            ("*", "GET", true),
            ("API.EXAMPLE", "GET", true),
            ("v1/items", "GET", true),
            ("nope", "GET", false),
            ("EXACT:https://api.example.com/v1/Items?a=1", "GET", true),
            ("EXACT:https://api.example.com/v1/items?a=1", "GET", false),  // case counts
            ("EXACT:/v1/Items", "GET", false),
            ("NOT:/admin", "GET", true),
            ("NOT:V1/ITEMS", "GET", false),
            ("REGEX:items/?\\?a=\\d", "GET", true),  // ignores case by default
            ("REGEX:(?-i)items", "GET", false),  // case on again
            ("REGEX:(?-i)Items", "GET", true),
            ("REGEX:^https://api", "GET", true),
            ("METHOD:GET api", "GET", true),
            ("METHOD:get api", "GET", true),
            ("METHOD:POST api", "GET", false),
            ("METHOD:POST api", "POST", true),
            ("METHOD:GET NOT:items", "GET", false),
            ("METHOD:GET", "GET", true),
            ("METHOD:GET", "PUT", false),
            ("HEADER:x-test=alpha", "GET", true),
            ("HEADER:X-Test=gamma", "GET", false),
            ("HEADER:X-Test", "GET", true),
            ("HEADER:X-Missing", "GET", false),
            ("METHOD:PUT HEADER:X-Test", "GET", false),
        ]
        for (text, method, expected) in table {
            let answer = result(magic(text), input(method: method, requestHeaders: headers))
            #expect(answer == (expected ? .matched : .noMatch), "\(text) \(method)")
        }
    }

    @Test func invalidStringNeverMatchesAndOperatorIsIgnored() {
        #expect(result(magic(""), input()) == .noMatch)
        #expect(result(magic("EXACT:"), input()) == .noMatch)
        for op in [ConditionOperator.contains, .equals, .notContains, .regex, .isEmpty] {
            #expect(result(magic("api.example", op: op), input()) == .matched, "\(op)")
        }
    }

    @Test func regexProblemsDecideTheGroup() {
        let slow = PatternCache(budget: RegexBudget(maxDuration: .milliseconds(1), clock: Self.stepping()))
        let path = "/" + String(repeating: "a", count: 60) + "b"
        let verdict = ConditionGroup(rows: [magic("REGEX:/(a|aa)+c")]).evaluate(
            input(path: path), allowance: RegexAllowance(total: .seconds(100)), cache: slow)
        #expect(verdict.result == .noMatch || verdict.result == .patternTimedOut || verdict.result == .patternDisabled)
    }

    private static func stepping() -> @Sendable () -> Duration {
        let ticks = ClockTicks()
        return { ticks.next() }
    }

    // MARK: validation and catalog

    @Test func validation() throws {
        let limits = RulesLimits()
        func issue(_ row: ConditionRow) -> RuleValidationError.Code? {
            row.validationIssue(limits: limits)?.code
        }
        #expect(issue(magic("api")) == nil)
        #expect(issue(magic("api", op: .equals)) == nil)  // the stored comparison is ignored
        #expect(issue(magic("")) == .invalidConditionValue)
        #expect(issue(magic("EXACT:")) == .invalidConditionValue)
        #expect(issue(magic("REGEX:(")) == .invalidRegex)
        #expect(issue(magic(String(repeating: "a", count: limits.fieldBytes + 1))) == .fieldTooLong)
        var named = magic("api")
        named.name = "x"
        #expect(issue(named) == .unexpectedConditionName)
    }

    @Test func catalog() {
        #expect(ConditionOperator.fiddlerOperators(for: .magicString, name: nil).isEmpty)
        #expect(ConditionOperator.defaultOperator(for: .magicString, name: nil) == .contains)
        #expect(ConditionOperator.allowed(for: .magicString, name: nil) == [.contains])
        #expect(ConditionField.magicString.knowablePoint == .request)
        #expect(ConditionField.magicString.valueKind(name: nil) == .text)
    }

    @Test func rowRoundTripsAndPreparesItsRegex() throws {
        let row = magic("REGEX:(?-i)Items")
        let data = try JSONEncoder().encode(row)
        #expect(try JSONDecoder().decode(ConditionRow.self, from: data) == row)
        let cache = PatternCache(budget: RegexBudget(clock: { .zero }))
        Rule(name: "r", conditions: ConditionGroup(rows: [row]), actions: [RuleAction(.hide)]).preparePatterns(in: cache)
        #expect(MagicStringCondition.parse(row.value)?.regexPattern == "(?-i)Items")
    }
}

private final class ClockTicks: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func next() -> Duration {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return .milliseconds(count * 10)
    }
}

// MARK: certificate wiring

@Suite("CertificateConditionWiring")
struct CertificateConditionWiringTests {
    private static let before = Date(timeIntervalSince1970: 1_000_000)
    private static let after = Date(timeIntervalSince1970: 2_000_000)
    private static let inside = Date(timeIntervalSince1970: 1_500_000)

    private static func cert(trusted: Bool? = true) -> CertificateSummary {
        CertificatesFixture.summary(before: before, after: after, trusted: trusted)
    }

    private func answer(_ name: String, _ op: ConditionOperator, _ value: String, cert: CertificateSummary? = Self.cert(),
        at now: Date = Self.inside) -> RuleMatchResult
    {
        result(ConditionRow(field: .certificate, name: name, op: op, value: value), input(certificate: cert, startedAt: now))
    }

    @Test func allowedNamesAreTheSeventeenThenTheOldOnes() {
        let names = ConditionField.allowedNames(for: .certificate)
        #expect(names == CertificateField.allCases.map(\.rawValue) + ["subject", "issuer", "notBefore", "notAfter"])
        #expect(Set(names ?? []).count == names?.count)
    }

    @Test func textItems() {
        #expect(answer("subjectCommonName", .equals, "A.TEST") == .matched)
        #expect(answer("issuerOrganization", .contains, "root") == .matched)
        #expect(answer("subjectCountry", .equals, "DE") == .noMatch)
        #expect(answer("friendlyName", .isEmpty, "") == .matched)
        #expect(answer("friendlyName", .contains, "x") == .noMatch)
        #expect(answer("sha1Fingerprint", .equals, "cd") == .matched)
        #expect(answer("sha256Fingerprint", .equals, "ab") == .matched)
        #expect(answer("serialNumber", .startsWith, "0a") == .matched)
        #expect(answer("signature", .regex, "^sha256With") == .matched)
        #expect(answer("subjectCommonName", .equals, "a.test", cert: nil) == .noMatch)
    }

    @Test func alternativeNamesMatchWhenAnyNameDoes() {
        #expect(answer("subjectAlternativeName", .equals, "b.test") == .matched)
        #expect(answer("subjectAlternativeName", .equals, "a.test") == .matched)
        #expect(answer("subjectAlternativeName", .equals, "c.test") == .noMatch)
        #expect(answer("subjectAlternativeName", .contains, "B.TE") == .matched)
        #expect(answer("subjectAlternativeName", .notEquals, "a.test") == .noMatch)  // one name equals it
        #expect(answer("subjectAlternativeName", .notEquals, "z.test") == .matched)
        #expect(answer("subjectAlternativeName", .regex, "^b\\.") == .matched)
        var none = Self.cert()
        none.subjectAlternativeNames = []
        #expect(answer("subjectAlternativeName", .isEmpty, "", cert: none) == .matched)
        #expect(answer("subjectAlternativeName", .equals, "a.test", cert: none) == .noMatch)
    }

    @Test func versionIsANumber() {
        #expect(answer("version", .equals, "3") == .matched)
        #expect(answer("version", .greaterOrEqual, "3") == .matched)
        #expect(answer("version", .lessThan, "3") == .noMatch)
        #expect(answer("version", .isNotEmpty, "") == .matched)
        var unread = Self.cert()
        unread.version = nil
        #expect(answer("version", .isEmpty, "", cert: unread) == .matched)
        #expect(answer("version", .equals, "3", cert: unread) == .noMatch)
    }

    @Test func datesAreDays() {
        // 1_000_000 s and 2_000_000 s after the epoch, read as local days in the test zone (UTC).
        #expect(answer("issueDate", .equals, "1970-01-12") == .matched)
        #expect(answer("expirationDate", .equals, "1970-01-24") == .matched)
        #expect(answer("expirationDate", .afterOrEqual, "1970-01-24") == .matched)
        #expect(answer("expirationDate", .after, "1970-01-24") == .noMatch)
        #expect(answer("expirationDate", .before, "1970-02-01") == .matched)
        #expect(answer("issueDate", .beforeOrEqual, "1970-01-12") == .matched)
        #expect(answer("issueDate", .isNotEmpty, "") == .matched)
    }

    @Test func validityNeedsTimeInPeriodAndATrustedUpstream() {
        #expect(answer("validity", .equals, "valid") == .matched)
        #expect(answer("validity", .equals, "invalid") == .noMatch)
        #expect(answer("validity", .equals, "valid", at: Date(timeIntervalSince1970: 3_000_000)) == .noMatch)
        #expect(answer("validity", .equals, "invalid", at: Date(timeIntervalSince1970: 3_000_000)) == .matched)
        #expect(answer("validity", .equals, "invalid", cert: Self.cert(trusted: false)) == .matched)
        #expect(answer("validity", .equals, "valid", cert: Self.cert(trusted: nil)) == .matched)
        // Not one of the two values: unreadable, never matches.
        #expect(answer("validity", .equals, "maybe") == .noMatch)
    }

    @Test func originalKeysReadAsBefore() {
        let iso = { (date: Date) in date.formatted(.iso8601) }
        #expect(answer("subject", .contains, "O=Acme") == .matched)
        #expect(answer("issuer", .equals, "CN=Root, O=Rootco, C=DE") == .matched)
        #expect(answer("serialNumber", .equals, "0A1B") == .matched)
        #expect(answer("sha256Fingerprint", .equals, "AB") == .matched)
        #expect(answer("notBefore", .equals, iso(Self.before)) == .matched)
        #expect(answer("notAfter", .startsWith, "1970-01-24") == .matched)
        #expect(answer("notAfter", .equals, "1970-01-24") == .noMatch)  // still text, not a day
    }

    @Test func operatorsAndValueKindsPerItem() {
        func ops(_ name: String?) -> [ConditionOperator] {
            ConditionOperator.fiddlerOperators(for: .certificate, name: name).flatMap { $0 }
        }
        #expect(ops("validity") == [.equals])
        #expect(ops("version").contains(.greaterOrEqual))
        #expect(ops("version").contains(.regex))
        #expect(ops("issueDate").contains(.afterOrEqual))
        #expect(!ops("issueDate").contains(.regex))
        #expect(ops("friendlyName").contains(.contains))
        #expect(ops("subject") == ops("friendlyName"))
        #expect(ops(nil) == ops("friendlyName"))
        #expect(ConditionOperator.defaultOperator(for: .certificate, name: "friendlyName") == .contains)
        #expect(ConditionOperator.defaultOperator(for: .certificate, name: "validity") == .equals)
        #expect(ConditionOperator.defaultOperator(for: .certificate, name: "version") == .equals)
        #expect(ConditionField.certificate.valueKind(name: "validity") == .choice(["valid", "invalid"]))
        #expect(ConditionField.certificate.valueKind(name: "version") == .number)
        #expect(ConditionField.certificate.valueKind(name: "expirationDate") == .date)
        #expect(ConditionField.certificate.valueKind(name: "subjectAlternativeName") == .text)
        #expect(ConditionField.certificate.valueKind(name: "notAfter") == .text)
        #expect(ConditionField.certificate.valueKind(name: nil) == .text)
        // Old rows keep every comparison they could have.
        for op in [ConditionOperator.equals, .notEquals, .contains, .startsWith, .regex] {
            #expect(ConditionOperator.allowed(for: .certificate, name: "subject").contains(op))
        }
    }

    @Test func validationPerItem() {
        let limits = RulesLimits()
        func code(_ name: String, _ op: ConditionOperator, _ value: String) -> RuleValidationError.Code? {
            ConditionRow(field: .certificate, name: name, op: op, value: value).validationIssue(limits: limits)?.code
        }
        #expect(code("friendlyName", .contains, "x") == nil)
        #expect(code("validity", .equals, "valid") == nil)
        #expect(code("validity", .equals, "bogus") == .invalidConditionValue)
        #expect(code("validity", .contains, "valid") == .invalidOperator)
        #expect(code("version", .greaterOrEqual, "3") == nil)
        #expect(code("version", .greaterOrEqual, "x") == .invalidConditionValue)
        #expect(code("expirationDate", .before, "2026-10-25") == nil)
        #expect(code("expirationDate", .before, "soon") == .invalidConditionValue)
        #expect(code("notAfter", .equals, "anything") == nil)
        #expect(code("bogus", .equals, "x") == .invalidConditionName)
    }
}

enum CertificatesFixture {
    static func summary(before: Date, after: Date, trusted: Bool?) -> CertificateSummary {
        CertificateSummary(
            subject: "CN=a.test, O=Acme, C=US", issuer: "CN=Root, O=Rootco, C=DE", serialNumber: "0A1B",
            sha256Fingerprint: "AB", notBefore: before, notAfter: after, version: 3, sha1Fingerprint: "CD",
            issuerCommonName: "Root", issuerOrganization: "Rootco", issuerCountry: "DE",
            subjectCommonName: "a.test", subjectOrganization: "Acme", subjectCountry: "US",
            subjectAlternativeNames: ["a.test", "b.test"], publicKey: "RSA 2048 00",
            signature: "sha256WithRSAEncryption 11", isTrusted: trusted)
    }
}
