import Foundation
import Testing

@testable import RulesEngine

@Suite("Condition catalogue")
struct ConditionCatalogTests {
    private static let legacyFields: [ConditionField] = [
        .allSessions, .scheme, .host, .port, .method, .pathAndQuery, .statusCode,
    ]

    @Test func everyFieldHasAGroupSideAndValueKind() {
        #expect(ConditionField.allCases.count == 37)
        for field in ConditionField.allCases {
            _ = field.side
            _ = field.group
            _ = field.valueKind(name: nil)
            #expect(ConditionFieldGroup.allCases.contains(field.group), "\(field)")
        }
        #expect(ConditionFieldGroup.allCases.count == 6)
    }

    @Test func appendedRawValuesNeverReorderExistingOnes() {
        #expect(
            ConditionField.allCases.prefix(7).map(\.rawValue)
                == ["allSessions", "scheme", "host", "port", "method", "pathAndQuery", "statusCode"])
        #expect(
            ConditionOperator.allCases.prefix(6).map(\.rawValue)
                == ["equals", "startsWith", "inRange", "hostPattern", "wildcard", "regexWhole"])
        #expect(
            ConditionField.allCases.dropFirst(7).map(\.rawValue) == [
                "url", "path", "queryString", "queryParam", "requestHeader", "responseHeader", "requestCookie",
                "responseCookie", "requestBody", "responseBody", "requestBodySize", "responseBodySize", "sessionState",
                "durationMs", "requestTime", "requestDate", "clientHTTPVersion", "upstreamHTTPVersion",
                "clientTLSVersion", "upstreamTLSVersion", "certificate", "clientIP", "remoteIP", "clientApp",
                "appProtocol", "rulesModified", "comment", "cookie", "tlsVersion", "magicString",
            ])
        #expect(
            ConditionOperator.allCases.dropFirst(6).map(\.rawValue) == [
                "notEquals", "contains", "notContains", "endsWith", "isEmpty", "isNotEmpty", "regex", "greaterThan",
                "greaterOrEqual", "lessThan", "lessOrEqual", "before", "after", "exists", "doesNotExist",
                "afterOrEqual", "beforeOrEqual",
            ])
        #expect(ConditionOperator.allCases.count == 23)
    }

    @Test func legacyFieldsAreTheFirstSeven() {
        for field in ConditionField.allCases {
            #expect(field.isLegacyField == Self.legacyFields.contains(field), "\(field)")
        }
    }

    @Test func afterCompletionFieldsAreExactlyDurationSizeAndState() {
        let completion = ConditionField.allCases.filter { $0.knowablePoint == .completion }
        #expect(Set(completion) == [.responseBodySize, .sessionState, .durationMs])
        let grouped = ConditionField.allCases.filter { $0.group == .afterCompletion }
        #expect(Set(grouped) == [.responseBodySize, .sessionState, .durationMs])
    }

    @Test func knowablePointTable() {
        let p0: [ConditionField] = [
            .allSessions, .url, .scheme, .host, .port, .method, .requestTime, .requestDate, .clientIP, .clientApp,
            .rulesModified, .comment,
        ]
        let p1: [ConditionField] = [
            .path, .queryString, .queryParam, .requestHeader, .requestCookie, .requestBody, .requestBodySize,
            .clientHTTPVersion, .clientTLSVersion, .appProtocol, .pathAndQuery, .magicString,
        ]
        let p2: [ConditionField] = [
            .statusCode, .responseHeader, .responseCookie, .responseBody, .upstreamHTTPVersion, .upstreamTLSVersion,
            .certificate, .remoteIP, .cookie, .tlsVersion,
        ]
        let p3: [ConditionField] = [.responseBodySize, .sessionState, .durationMs]
        for field in p0 { #expect(field.knowablePoint == .connect, "\(field)") }
        for field in p1 { #expect(field.knowablePoint == .request, "\(field)") }
        for field in p2 { #expect(field.knowablePoint == .response, "\(field)") }
        for field in p3 { #expect(field.knowablePoint == .completion, "\(field)") }
        #expect(p0.count + p1.count + p2.count + p3.count == ConditionField.allCases.count)
    }

    @Test func sseProtocolRowIsJudgedAtTheResponse() {
        func row(_ value: String) -> ConditionRow { ConditionRow(field: .appProtocol, op: .equals, value: value) }
        #expect(row("sse").knowablePoint == .response)
        #expect(row("SSE").knowablePoint == .response)
        #expect(row("websocket").knowablePoint == .request)
        #expect(row("http").knowablePoint == .request)
        #expect(ConditionRow(field: .host, op: .contains, value: "sse").knowablePoint == .connect)
    }

    @Test func judgmentPointIsTheLatestRowPoint() {
        let host = ConditionRow(field: .host, op: .contains, value: "a")
        let header = ConditionRow(field: .requestHeader, name: "X", op: .equals, value: "1")
        let status = ConditionRow(field: .statusCode, op: .equals, value: "200")
        let sse = ConditionRow(field: .appProtocol, op: .equals, value: "sse")
        let duration = ConditionRow(field: .durationMs, op: .greaterThan, value: "100")
        #expect(ConditionGroup().judgmentPoint == .connect)
        #expect(ConditionGroup(rows: [host]).judgmentPoint == .connect)
        #expect(ConditionGroup(rows: [host, header]).judgmentPoint == .request)
        #expect(ConditionGroup(rows: [host, status, header]).judgmentPoint == .response)
        #expect(ConditionGroup(rows: [host, sse]).judgmentPoint == .response)
        #expect(ConditionGroup(rows: [sse, duration, host]).judgmentPoint == .completion)
    }

    private static let textOps: [ConditionOperator] = [
        .equals, .notEquals, .contains, .notContains, .startsWith, .endsWith, .isEmpty, .isNotEmpty, .regex,
    ]
    private static let numberOps: [ConditionOperator] = [
        .equals, .notEquals, .greaterThan, .greaterOrEqual, .lessThan, .lessOrEqual, .inRange,
    ]
    private static let dateOps: [ConditionOperator] = [.equals, .notEquals, .before, .after, .inRange]
    private static let choiceOps: [ConditionOperator] = [.equals, .notEquals]

    /// R8F2: `allowed` is the Fiddler set plus whatever saved rows used before (see FiddlerConditionOperatorTests).
    private func accepts(_ field: ConditionField, _ name: String?, _ old: [ConditionOperator]) -> Bool {
        Set(old).isSubset(of: ConditionOperator.allowed(for: field, name: name))
    }

    @Test func allowedOperatorsPerValueKind() {
        let text: [ConditionField] = [
            .url, .host, .path, .queryString, .queryParam, .requestHeader, .responseHeader, .requestCookie,
            .responseCookie, .requestBody, .responseBody, .certificate, .clientTLSVersion, .upstreamTLSVersion,
            .clientIP, .remoteIP, .comment, .requestTime, .method, .clientHTTPVersion, .upstreamHTTPVersion,
        ]
        for field in text { #expect(accepts(field, "n", Self.textOps), "\(field)") }
        let number: [ConditionField] = [.port, .requestBodySize, .responseBodySize, .durationMs]
        for field in number { #expect(accepts(field, nil, Self.numberOps), "\(field)") }
        #expect(accepts(.clientApp, "pid", Self.numberOps))
        #expect(accepts(.clientApp, "name", Self.textOps))
        #expect(accepts(.clientApp, "path", Self.textOps))
        #expect(accepts(.requestDate, nil, Self.dateOps))
        let choice: [ConditionField] = [.scheme, .sessionState, .appProtocol, .rulesModified]
        for field in choice { #expect(accepts(field, nil, Self.choiceOps), "\(field)") }
        #expect(ConditionOperator.allowed(for: .allSessions, name: nil) == [])
        #expect(accepts(.statusCode, nil, Self.numberOps + [.contains, .startsWith, .regex]))
    }

    @Test func legacyOnlyOperatorsAreNeverOffered() {
        #expect(Set(ConditionOperator.allCases.filter(\.isLegacyOnly)) == [.hostPattern, .wildcard, .regexWhole])
        for field in ConditionField.allCases {
            for name in [nil, "pid", "name", "subject"] {
                let offered = ConditionOperator.allowed(for: field, name: name)
                #expect(!offered.contains { $0.isLegacyOnly }, "\(field)")
            }
        }
    }

    @Test func takesNameFields() {
        let named: Set<ConditionField> = [
            .queryParam, .requestHeader, .responseHeader, .requestCookie, .responseCookie, .cookie, .certificate,
            .clientApp,
        ]
        for field in ConditionField.allCases { #expect(field.takesName == named.contains(field), "\(field)") }
        #expect(
            ConditionField.allowedNames(for: .certificate)
                == CertificateField.allCases.map(\.rawValue) + ["subject", "issuer", "notBefore", "notAfter"])
        #expect(ConditionField.allowedNames(for: .clientApp) == ["name", "path", "pid"])
        #expect(ConditionField.allowedNames(for: .requestHeader) == nil)
        #expect(ConditionField.allowedNames(for: .host) == nil)
    }

    @Test func clientAppPidIsNumeric() {
        #expect(ConditionField.clientApp.valueKind(name: "pid") == .number)
        #expect(ConditionField.clientApp.valueKind(name: "name") == .text)
        #expect(ConditionField.clientApp.valueKind(name: nil) == .text)
        #expect(ConditionField.statusCode.valueKind(name: nil) == .number)
        #expect(ConditionField.requestDate.valueKind(name: nil) == .date)
        #expect(ConditionField.rulesModified.valueKind(name: nil) == .bool)
        #expect(ConditionField.allSessions.valueKind(name: nil) == .none)
        #expect(ConditionField.sessionState.valueKind(name: nil) == .choice(["opened", "closed", "paused"]))
        #expect(
            ConditionField.appProtocol.valueKind(name: nil)
                == .choice(["http", "websocket", "rpc", "grpc", "sse", "socketio"]))
        #expect(ConditionField.clientHTTPVersion.valueKind(name: nil) == .text)
        #expect(ConditionField.scheme.valueKind(name: nil) == .choice(["https", "http"]))
    }

    @Test func evaluationPathKeepsR1RowsOnTheOldPath() {
        func path(_ row: ConditionRow) -> ConditionRow.EvaluationPath { row.evaluationPath }
        #expect(path(ConditionRow(field: .scheme, op: .equals, value: "https")) == .legacy(RuleMatcher(scheme: "https")))
        #expect(path(ConditionRow(field: .scheme, op: .equals, value: "https", caseSensitive: true)) == .current)
        #expect(path(ConditionRow(field: .method, op: .equals, value: "GET", caseSensitive: true)) == .legacy(RuleMatcher(method: "GET")))
        #expect(path(ConditionRow(field: .method, op: .equals, value: "GET")) == .current)
        #expect(path(ConditionRow(field: .host, op: .contains, value: "a")) == .current)
        #expect(path(ConditionRow(field: .url, op: .contains, value: "a")) == .current)
        #expect(path(ConditionRow(field: .statusCode, op: .equals, value: "200")) == .current)
        #expect(path(ConditionRow(field: .statusCode, op: .inRange, value: "200-299")) == .legacy(RuleMatcher(statusRange: 200...299)))
    }
}

@Suite("Condition values")
struct ConditionValuesTests {
    private let utc = TimeZone(identifier: "UTC")!

    @Test func wholeNumbers() {
        #expect(ConditionValues.wholeNumber("0") == 0)
        #expect(ConditionValues.wholeNumber("123456789012345678") == 123_456_789_012_345_678)
        #expect(ConditionValues.wholeNumber("1234567890123456789") == nil)
        #expect(ConditionValues.wholeNumber("") == nil)
        #expect(ConditionValues.wholeNumber("-1") == nil)
        #expect(ConditionValues.wholeNumber("+1") == nil)
        #expect(ConditionValues.wholeNumber(" 1") == nil)
        #expect(ConditionValues.wholeNumber("1.5") == nil)
    }

    @Test func numberRanges() {
        #expect(ConditionValues.numberRange("1-5") == 1...5)
        #expect(ConditionValues.numberRange("5-5") == 5...5)
        #expect(ConditionValues.numberRange("5-1") == nil)
        #expect(ConditionValues.numberRange("5") == nil)
        #expect(ConditionValues.numberRange("-5") == nil)
        #expect(ConditionValues.numberRange("1-2-3") == nil)
    }

    @Test func days() throws {
        let day = try #require(ConditionValues.day("2026-10-23", timeZone: utc))
        #expect(day.start == Date(timeIntervalSince1970: 1_792_713_600))
        #expect(day.duration == 86_400)
        #expect(ConditionValues.day("2026-02-30", timeZone: utc) == nil)
        #expect(ConditionValues.day("2026-13-01", timeZone: utc) == nil)
        #expect(ConditionValues.day("2026-1-01", timeZone: utc) == nil)
        #expect(ConditionValues.day("20261023", timeZone: utc) == nil)
        #expect(ConditionValues.day("2026-10-23 ", timeZone: utc) == nil)
        let tokyo = try #require(ConditionValues.day("2026-10-23", timeZone: TimeZone(identifier: "Asia/Tokyo")!))
        #expect(tokyo.start == day.start - 9 * 3600)
        // A 23-hour day (spring forward in New York) still ends at the next local midnight.
        let newYork = TimeZone(identifier: "America/New_York")!
        let short = try #require(ConditionValues.day("2026-03-08", timeZone: newYork))
        #expect(short.duration == 23 * 3600)
    }

    @Test func dayRanges() throws {
        let range = try #require(ConditionValues.dayRange("2026-10-22..2026-10-23", timeZone: utc))
        #expect(range.duration == 2 * 86_400)
        #expect(ConditionValues.dayRange("2026-10-23..2026-10-23", timeZone: utc)?.duration == 86_400)
        #expect(ConditionValues.dayRange("2026-10-23..2026-10-22", timeZone: utc) == nil)
        #expect(ConditionValues.dayRange("2026-10-23", timeZone: utc) == nil)
        #expect(ConditionValues.dayRange("2026-10-23...2026-10-24", timeZone: utc) == nil)
        #expect(ConditionValues.dayRange("2026-10-23..bad", timeZone: utc) == nil)
    }
}
