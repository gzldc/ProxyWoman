import Foundation
import Testing

@testable import RulesEngine

private func rule(_ rows: [ConditionRow], mode: ConditionGroup.Mode = .all) -> Rule {
    Rule(
        name: "r", conditions: ConditionGroup(mode: mode, rows: rows),
        // A mark is allowed at every judgment point, so only the rows decide (task 5 limits completion rules to
        // annotations).
        actions: [RuleAction(.mark(MarkAction(background: "#FF3B30")))])
}

private func failure(_ rows: [ConditionRow], limits: RulesLimits = RulesLimits()) -> RuleValidationError? {
    do {
        try rule(rows).validate(limits: limits)
        return nil
    } catch let error as RuleValidationError {
        return error
    } catch {
        Issue.record("unexpected error \(error)")
        return nil
    }
}

private func row(
    _ field: ConditionField, _ op: ConditionOperator, _ value: String = "", name: String? = nil,
    caseSensitive: Bool = false
) -> ConditionRow {
    ConditionRow(field: field, name: name, op: op, value: value, caseSensitive: caseSensitive)
}

private func at(_ index: Int) -> RuleValidationError.Field { .conditionRow(index: index) }

@Suite("Condition row validation")
struct ConditionRowValidationTests {
    @Test func validNewRowsPass() {
        #expect(failure([row(.url, .contains, "api")]) == nil)
        #expect(failure([row(.requestHeader, .equals, "1", name: "X-Test")]) == nil)
        #expect(failure([row(.durationMs, .greaterThan, "1000")]) == nil)
        #expect(failure([row(.requestDate, .inRange, "2026-10-01..2026-10-31")]) == nil)
        #expect(failure([row(.rulesModified, .equals, "true")]) == nil)
        #expect(failure([row(.sessionState, .equals, "failed")]) == nil)
        #expect(failure([row(.clientApp, .equals, "123", name: "pid")]) == nil)
        #expect(failure([row(.certificate, .contains, "x", name: "subject")]) == nil)
        #expect(failure([row(.host, .notEquals, "a.test"), row(.method, .equals, "get")]) == nil)
        #expect(failure([row(.scheme, .equals, "https", caseSensitive: true)]) == nil)
    }

    @Test func regexFindCompilesAndRejectsInvalidPattern() {
        #expect(failure([row(.url, .regex, "a.*b")]) == nil)
        #expect(failure([row(.url, .regex, "(")]) == RuleValidationError(code: .invalidRegex, field: at(0)))
        #expect(failure([row(.url, .regex, "")]) == RuleValidationError(code: .invalidRegex, field: at(0)))
        #expect(
            failure([row(.host, .equals, "a"), row(.responseBody, .regex, "[")])
                == RuleValidationError(code: .invalidRegex, field: at(1)))
    }

    @Test func riskyRegexIsTooComplex() {
        #expect(
            failure([row(.url, .regex, "(a+)+$")]) == RuleValidationError(code: .regexTooComplex, field: at(0)))
    }

    @Test func queryParamRowNeedsAName() {
        #expect(
            failure([row(.queryParam, .isEmpty)]) == RuleValidationError(code: .conditionNameRequired, field: at(0)))
        #expect(
            failure([row(.certificate, .equals, "x")])
                == RuleValidationError(code: .conditionNameRequired, field: at(0)))
    }

    @Test func headerCookieAndProcessKeysMayBeEmpty() {
        // R8F2: an empty key means any header / cookie, or the whole process.
        #expect(failure([row(.host, .equals, "a"), row(.requestHeader, .equals, "1")]) == nil)
        #expect(failure([row(.responseCookie, .equals, "1", name: "")]) == nil)
        #expect(failure([row(.clientApp, .equals, "x")]) == nil)
    }

    @Test func nameOnUnnamedFieldIsRejected() {
        #expect(
            failure([row(.url, .equals, "a", name: "x")])
                == RuleValidationError(code: .unexpectedConditionName, field: at(0)))
        #expect(
            failure([row(.durationMs, .equals, "1", name: "x")])
                == RuleValidationError(code: .unexpectedConditionName, field: at(0)))
    }

    @Test func certificateNameMustBeKnown() {
        for name in ["subject", "issuer", "serialNumber", "sha256Fingerprint", "notBefore", "notAfter"] {
            #expect(failure([row(.certificate, .contains, "x", name: name)]) == nil, "\(name)")
        }
        #expect(
            failure([row(.certificate, .contains, "x", name: "Subject")])
                == RuleValidationError(code: .invalidConditionName, field: at(0)))
        #expect(
            failure([row(.clientApp, .equals, "x", name: "bundle")])
                == RuleValidationError(code: .invalidConditionName, field: at(0)))
    }

    @Test func numberRowsRejectNonNumbers() {
        for value in ["abc", "", "-1", "1.5", "1 ", "1234567890123456789"] {
            #expect(
                failure([row(.durationMs, .greaterThan, value)])
                    == RuleValidationError(code: .invalidConditionValue, field: at(0)), "\(value)")
        }
        #expect(
            failure([row(.clientApp, .equals, "abc", name: "pid")])
                == RuleValidationError(code: .invalidConditionValue, field: at(0)))
        #expect(
            failure([row(.port, .notEquals, "x")]) == RuleValidationError(code: .invalidConditionValue, field: at(0)))
    }

    @Test func rangeNeedsLowAtMostHigh() {
        #expect(failure([row(.requestBodySize, .inRange, "10-20")]) == nil)
        #expect(failure([row(.requestBodySize, .inRange, "20-20")]) == nil)
        for value in ["20-10", "10", "a-b", "10-", ""] {
            #expect(
                failure([row(.requestBodySize, .inRange, value)])
                    == RuleValidationError(code: .invalidConditionValue, field: at(0)), "\(value)")
        }
    }

    @Test func dateRowsNeedYYYYMMDD() {
        #expect(failure([row(.requestDate, .before, "2026-10-23")]) == nil)
        #expect(failure([row(.requestDate, .equals, "2026-10-23")]) == nil)
        for value in ["2026-1-1", "23/10/2026", "2026-02-30", "", "2026-10-23T10:00"] {
            #expect(
                failure([row(.requestDate, .after, value)])
                    == RuleValidationError(code: .invalidConditionValue, field: at(0)), "\(value)")
        }
    }

    @Test func dateRangeUsesDoubleDots() {
        #expect(failure([row(.requestDate, .inRange, "2026-10-01..2026-10-01")]) == nil)
        for value in ["2026-10-01", "2026-10-01-2026-10-31", "2026-10-31..2026-10-01", "2026-10-01..x"] {
            #expect(
                failure([row(.requestDate, .inRange, value)])
                    == RuleValidationError(code: .invalidConditionValue, field: at(0)), "\(value)")
        }
    }

    @Test func boolRowsAcceptOnlyTrueFalse() {
        #expect(failure([row(.rulesModified, .notEquals, "false")]) == nil)
        for value in ["yes", "True", "1", ""] {
            #expect(
                failure([row(.rulesModified, .equals, value)])
                    == RuleValidationError(code: .invalidConditionValue, field: at(0)), "\(value)")
        }
    }

    @Test func choiceRowsAcceptOnlyTheirValues() {
        for value in ["completed", "failed", "tunnel"] { #expect(failure([row(.sessionState, .equals, value)]) == nil) }
        for value in ["http", "websocket", "grpc", "socketio", "sse"] {
            #expect(failure([row(.appProtocol, .equals, value)]) == nil)
        }
        for field in [ConditionField.clientHTTPVersion, .upstreamHTTPVersion] {
            #expect(failure([row(field, .equals, "h1")]) == nil)
            #expect(failure([row(field, .notEquals, "h2")]) == nil)
            // R8F2: the version is text now (HTTP/1.1, HTTP/2); the old labels stay readable.
            #expect(failure([row(field, .equals, "h3")]) == nil)
        }
        #expect(
            failure([row(.sessionState, .equals, "done")])
                == RuleValidationError(code: .invalidConditionValue, field: at(0)))
        #expect(failure([row(.appProtocol, .equals, "SSE")]) == nil)
        #expect(failure([row(.sessionState, .equals, "Failed")]) == nil)
        #expect(failure([row(.clientHTTPVersion, .equals, "H2")]) == nil)
        #expect(ConditionRow(field: .appProtocol, op: .equals, value: "SSE").knowablePoint == .response)
        // The scheme keeps R1's code and field.
        #expect(
            failure([row(.scheme, .notEquals, "ftp")]) == RuleValidationError(code: .invalidScheme, field: .scheme))
        #expect(failure([row(.scheme, .notEquals, "HTTP")]) == nil)
    }

    @Test func operatorNotAllowedForFieldIsInvalidOperator() {
        #expect(failure([row(.durationMs, .contains, "1")]) == RuleValidationError(code: .invalidOperator, field: at(0)))
        #expect(failure([row(.url, .greaterThan, "1")]) == RuleValidationError(code: .invalidOperator, field: at(0)))
        #expect(failure([row(.requestDate, .contains, "x")]) == RuleValidationError(code: .invalidOperator, field: at(0)))
        #expect(failure([row(.rulesModified, .startsWith, "true")]) == RuleValidationError(code: .invalidOperator, field: at(0)))
        #expect(failure([row(.url, .hostPattern, "a")]) == RuleValidationError(code: .invalidOperator, field: at(0)))
        #expect(failure([row(.url, .wildcard, "a")]) == RuleValidationError(code: .invalidOperator, field: at(0)))
        #expect(failure([row(.host, .before, "a")]) == RuleValidationError(code: .invalidOperator, field: at(0)))
    }

    @Test func isEmptyIgnoresTheValue() {
        #expect(failure([row(.requestBody, .isEmpty)]) == nil)
        #expect(failure([row(.requestBody, .isNotEmpty, "ignored (")]) == nil)
        #expect(failure([row(.requestHeader, .isEmpty, name: "X")]) == nil)
        #expect(failure([row(.url, .equals, "")]) == nil)
    }

    @Test func statusRangeStillLimitedTo100To599() {
        #expect(failure([row(.statusCode, .inRange, "200-299")]) == nil)
        #expect(failure([row(.statusCode, .inRange, "99-200")]) == RuleValidationError(code: .invalidStatusRange, field: .statusRange))
        #expect(failure([row(.statusCode, .inRange, "200-600")]) == RuleValidationError(code: .invalidStatusRange, field: .statusRange))
        // New comparisons on the status code.
        #expect(failure([row(.statusCode, .equals, "404")]) == nil)
        #expect(failure([row(.statusCode, .greaterOrEqual, "400")]) == nil)
        #expect(failure([row(.statusCode, .startsWith, "4")]) == nil)
        #expect(failure([row(.statusCode, .contains, "4")]) == nil)
        #expect(failure([row(.statusCode, .regex, "4..")]) == nil)
        #expect(
            failure([row(.statusCode, .greaterThan, "x")])
                == RuleValidationError(code: .invalidConditionValue, field: at(0)))
    }

    @Test func valueLongerThanFieldBytesIsTooLong() {
        var limits = RulesLimits()
        limits.fieldBytes = 8
        #expect(failure([row(.url, .contains, "123456789")], limits: limits) == RuleValidationError(code: .fieldTooLong, field: at(0)))
        #expect(failure([row(.url, .contains, "12345678")], limits: limits) == nil)
        #expect(
            failure([row(.requestHeader, .equals, "1", name: "123456789")], limits: limits)
                == RuleValidationError(code: .fieldTooLong, field: at(0)))
    }

    @Test func nameLongerThanFieldBytesIsTooLong() {
        var limits = RulesLimits()
        limits.fieldBytes = 8
        #expect(
            failure([row(.requestCookie, .isEmpty, name: "123456789")], limits: limits)
                == RuleValidationError(code: .fieldTooLong, field: at(0)))
    }

    @Test func legacyClassificationIsOneDecision() {
        // (row, usesLegacyChecks, isLegacyNeverMatching, evaluation path is .legacy)
        let cases: [(ConditionRow, Bool, Bool, Bool)] = [
            (row(.host, .hostPattern, "a.test"), true, false, true),
            (row(.host, .hostPattern, "a.test", caseSensitive: true), true, true, false),
            (row(.pathAndQuery, .hostPattern, "/a", caseSensitive: true), true, true, false),
            (row(.scheme, .regexWhole, "https"), true, true, false),
            (row(.port, .equals, "abc"), true, true, false),
            (row(.port, .equals, "443"), true, false, true),
            (row(.statusCode, .inRange, "x"), true, true, false),
            (row(.statusCode, .inRange, "200-299"), true, false, true),
            (row(.host, .contains, "a"), false, false, false),
            (row(.method, .equals, "get"), false, false, false),
            (row(.url, .wildcard, "a"), false, false, false),
        ]
        for (row, legacy, neverMatches, isLegacyPath) in cases {
            #expect(row.usesLegacyChecks == legacy, "\(row)")
            #expect(row.isLegacyNeverMatching == neverMatches, "\(row)")
            if case .legacy = row.evaluationPath {
                #expect(isLegacyPath, "\(row)")
            } else {
                #expect(!isLegacyPath, "\(row)")
            }
        }
    }

    @Test func thirtyThreeRowsAreTooMany() {
        let rows = (0..<33).map { _ in row(.url, .contains, "a") }
        #expect(failure(rows) == RuleValidationError(code: .tooManyConditions, field: .conditions))
        #expect(failure(Array(rows.prefix(32))) == nil)
    }

    @Test func legacyRowsKeepTheirErrors() {
        #expect(failure([row(.host, .hostPattern, "bad host!")]) == RuleValidationError(code: .invalidHostPattern, field: .hostPattern))
        #expect(failure([row(.host, .wildcard, "a\\x")]) == RuleValidationError(code: .invalidWildcard, field: .hostPattern))
        #expect(failure([row(.host, .regexWhole, "(")]) == RuleValidationError(code: .invalidRegex, field: .hostPattern))
        #expect(failure([row(.pathAndQuery, .regexWhole, "(", caseSensitive: true)]) == RuleValidationError(code: .invalidRegex, field: .path))
        #expect(failure([row(.scheme, .equals, "ftp")]) == RuleValidationError(code: .invalidScheme, field: .scheme))
        #expect(failure([row(.port, .equals, "70000")]) == RuleValidationError(code: .invalidPort, field: .port))
        #expect(failure([row(.port, .equals, "abc")]) == RuleValidationError(code: .invalidPort, field: .port))
        #expect(failure([row(.statusCode, .inRange, "x")]) == RuleValidationError(code: .invalidStatusRange, field: .statusRange))
        #expect(failure([row(.method, .equals, "a b", caseSensitive: true)]) == RuleValidationError(code: .invalidMethod, field: .method))
        // A legacy operator the old matcher cannot read stays invalidOperator on its old field.
        #expect(failure([row(.host, .hostPattern, "a.test", caseSensitive: true)]) == RuleValidationError(code: .invalidOperator, field: .hostPattern))
        #expect(failure([row(.pathAndQuery, .hostPattern, "/a", caseSensitive: true)]) == RuleValidationError(code: .invalidOperator, field: .path))
    }
}
