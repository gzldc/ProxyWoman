import FlowStore
import Foundation
import Testing

@testable import RulesEngine

/// `https://api.example.com:443 GET /v1/items?a=1` unless told otherwise.
private func target(
    host: String = "api.example.com", scheme: String = "https", port: Int = 443, method: String = "GET",
    path: String = "/v1/items?a=1"
) -> HTTPMessageTarget {
    HTTPMessageTarget(scheme: scheme, host: host, port: port, method: method, pathAndQuery: path)
}

/// The pattern `(a|aa)+c` never finishes on this host or path under the fake clock.
private let slowRegex = "(a|aa)+c"
private let slowHost = String(repeating: "a", count: 60) + "b"
private let slowPath = "/" + String(repeating: "a", count: 60) + "b"

private func scheme(_ value: String) -> ConditionRow { ConditionRow(field: .scheme, op: .equals, value: value) }
private func method(_ value: String) -> ConditionRow {
    ConditionRow(field: .method, op: .equals, value: value, caseSensitive: true)
}
private func port(_ value: String) -> ConditionRow { ConditionRow(field: .port, op: .equals, value: value) }
private func host(_ value: String, _ op: ConditionOperator = .hostPattern) -> ConditionRow {
    ConditionRow(field: .host, op: op, value: value)
}
private func path(_ value: String, _ op: ConditionOperator = .equals) -> ConditionRow {
    ConditionRow(field: .pathAndQuery, op: op, value: value, caseSensitive: true)
}
private func status(_ value: String) -> ConditionRow { ConditionRow(field: .statusCode, op: .inRange, value: value) }

private func group(_ mode: ConditionGroup.Mode, _ rows: ConditionRow...) -> ConditionGroup {
    ConditionGroup(mode: mode, rows: rows)
}

@Suite("ConditionEvaluation")
struct ConditionEvaluationTests {
    // MARK: Modes

    @Test func zeroRowsMatchInEveryMode() {
        for mode in ConditionGroup.Mode.allCases {
            let empty = ConditionGroup(mode: mode)
            #expect(empty.evaluate(target(), status: nil) == .matched, "\(mode)")
            #expect(empty.evaluate(target(), status: 404) == .matched, "\(mode)")
        }
    }

    @Test func allModeNeedsEveryRow() {
        #expect(group(.all, scheme("https"), method("GET")).evaluate(target(), status: nil) == .matched)
        #expect(group(.all, scheme("https"), method("POST")).evaluate(target(), status: nil) == .noMatch)
        #expect(group(.all, scheme("http"), method("POST")).evaluate(target(), status: nil) == .noMatch)
    }

    @Test func anyModeNeedsOneRow() {
        #expect(group(.any, scheme("http"), method("GET")).evaluate(target(), status: nil) == .matched)
        #expect(group(.any, scheme("https"), method("POST")).evaluate(target(), status: nil) == .matched)
        #expect(group(.any, scheme("http"), method("POST")).evaluate(target(), status: nil) == .noMatch)
    }

    @Test func noneModeNeedsNoRow() {
        #expect(group(.none, scheme("http"), method("POST")).evaluate(target(), status: nil) == .matched)
        #expect(group(.none, scheme("https"), method("POST")).evaluate(target(), status: nil) == .noMatch)
        #expect(group(.none, scheme("https"), method("GET")).evaluate(target(), status: nil) == .noMatch)
    }

    // MARK: Fields

    @Test func statusRowNeverMatchesWithoutStatus() {
        let rows = group(.all, status("400-499"))
        #expect(rows.evaluate(target(), status: nil) == .noMatch)
        #expect(rows.evaluate(target(), status: 404) == .matched)
        #expect(rows.evaluate(target(), status: 200) == .noMatch)
        #expect(rows.evaluate(target(), status: 400) == .matched)
        #expect(rows.evaluate(target(), status: 499) == .matched)
        #expect(rows.evaluate(target(), status: 500) == .noMatch)
        // A status row beside a request-time field: the request is judged only once there is a status.
        #expect(group(.all, scheme("https"), status("200-299")).evaluate(target(), status: nil) == .noMatch)
        #expect(group(.any, scheme("https"), status("200-299")).evaluate(target(), status: nil) == .matched)
    }

    @Test func hostPatternRowKeepsLegacyHostSemantics() {
        let star = group(.all, host("*.example.com"))
        #expect(star.evaluate(target(host: "a.example.com"), status: nil) == .matched)
        #expect(star.evaluate(target(host: "a.b.example.com"), status: nil) == .matched)
        #expect(star.evaluate(target(host: "example.com"), status: nil) == .noMatch)
        // Case and one trailing dot do not matter.
        #expect(
            group(.all, host("API.Example.com")).evaluate(target(host: "api.example.com."), status: nil) == .matched)
        // Spellings of one IPv6 address are one host.
        let v6 = group(.all, host("2001:db8::1"))
        #expect(v6.evaluate(target(host: "[2001:0db8:0:0:0:0:0:1]"), status: nil) == .matched)
        #expect(v6.evaluate(target(host: "2001:db8:0:0:0:0:0:1"), status: nil) == .matched)
        #expect(v6.evaluate(target(host: "[2001:0db8:0:0:0:0:0:2]"), status: nil) == .noMatch)
    }

    @Test func wildcardAndRegexHostRowsAreWholeStringMatches() {
        let wildcard = group(.all, host("api-?.example.com", .wildcard))
        #expect(wildcard.evaluate(target(host: "API-1.example.com."), status: nil) == .matched)
        #expect(wildcard.evaluate(target(host: "api-12.example.com"), status: nil) == .noMatch)
        let regex = group(.all, host(#"(a|b)\.example\.com"#, .regexWhole))
        #expect(regex.evaluate(target(host: "B.example.com"), status: nil) == .matched)
        #expect(regex.evaluate(target(host: "xa.example.com"), status: nil) == .noMatch)
    }

    @Test func portMethodAndPathRowsFollowTheLegacyFields() {
        #expect(group(.all, port("443")).evaluate(target(), status: nil) == .matched)
        #expect(group(.all, port("8443")).evaluate(target(), status: nil) == .noMatch)
        // Methods and paths are case-sensitive; schemes are not.
        #expect(group(.all, method("get")).evaluate(target(), status: nil) == .noMatch)
        #expect(group(.all, scheme("HTTPS")).evaluate(target(), status: nil) == .matched)
        #expect(group(.all, path("/v1/items?a=1")).evaluate(target(), status: nil) == .matched)
        #expect(group(.all, path("/V1/items?a=1")).evaluate(target(), status: nil) == .noMatch)
        #expect(group(.all, path("/v1/", .startsWith)).evaluate(target(), status: nil) == .matched)
        #expect(group(.all, path("/v1/", .startsWith)).evaluate(target(path: "/v2/items"), status: nil) == .noMatch)
        #expect(group(.all, path("/v1/*?a=*", .wildcard)).evaluate(target(), status: nil) == .matched)
        #expect(group(.all, path("/v[0-9]+/items.*", .regexWhole)).evaluate(target(), status: nil) == .matched)
        #expect(group(.all, path("/v[0-9]+/items", .regexWhole)).evaluate(target(), status: nil) == .noMatch)
    }

    @Test func aRowEvaluatesLikeItsLegacyMatcher() throws {
        let rows = [
            scheme("http"), scheme("https"), host("*.example.com"), host("example.com"), port("443"), port("80"),
            method("GET"), method("POST"), path("/v1/items?a=1"), path("/v1/", .startsWith),
            path("/v1/*", .wildcard), path("/v1/.*", .regexWhole), status("200-299"), status("400-499"),
            ConditionRow(field: .allSessions, op: .equals),
        ]
        let targets = [target(), target(host: "example.com", scheme: "http", port: 80, method: "POST", path: "/x")]
        for row in rows {
            let matcher = try #require(row.legacyMatcher, "\(row)")
            for candidate in targets {
                for code in [nil, 200, 404] as [Int?] {
                    #expect(
                        group(.all, row).evaluate(candidate, status: code) == matcher.evaluate(candidate, status: code),
                        "\(row) \(candidate) \(String(describing: code))")
                }
            }
        }
    }

    @Test func aRowThatCannotBeInterpretedNeverMatches() {
        let broken = [
            ConditionRow(field: .method, op: .startsWith, value: "G", caseSensitive: true),
            port("abc"),
            status("500-400"),
        ]
        for mode in ConditionGroup.Mode.allCases {
            for row in broken {
                #expect(
                    ConditionGroup(mode: mode, rows: [row]).evaluate(target(), status: 404) == .noMatch,
                    "\(mode) \(row)")
            }
        }
    }

    // MARK: Pattern problems

    @Test func regexRowsRunAfterCheapRows() throws {
        let cache = PatternCache(budget: StepClock().budget)
        let slow = target(host: slowHost)
        let regex = host(slowRegex, .regexWhole)
        // The cheap row is written second, but it runs first and ends the evaluation.
        #expect(group(.all, regex, method("POST")).evaluate(slow, status: nil, cache: cache) == .noMatch)
        #expect(try cache.regex(slowRegex, caseInsensitive: true).timeoutCount == 0)
        // Once the cheap row matches, the regex row is reached and times out.
        #expect(group(.all, regex, method("GET")).evaluate(slow, status: nil, cache: cache) == .patternTimedOut)
        #expect(try cache.regex(slowRegex, caseInsensitive: true).timeoutCount == 1)
    }

    @Test func aMatchedCheapRowEndsAnyModeBeforeTheRegexRuns() throws {
        let cache = PatternCache(budget: StepClock().budget)
        let rows = group(.any, host(slowRegex, .regexWhole), method("GET"))
        #expect(rows.evaluate(target(host: slowHost), status: nil, cache: cache) == .matched)
        #expect(try cache.regex(slowRegex, caseInsensitive: true).timeoutCount == 0)
    }

    @Test func aMatchedCheapRowEndsNoneModeBeforeTheRegexRuns() throws {
        let cache = PatternCache(budget: StepClock().budget)
        let rows = group(.none, host(slowRegex, .regexWhole), method("GET"))
        #expect(rows.evaluate(target(host: slowHost), status: nil, cache: cache) == .noMatch)
        #expect(try cache.regex(slowRegex, caseInsensitive: true).timeoutCount == 0)
    }

    @Test func timeoutInNoneModeIsNotAMatch() {
        let slow = target(host: slowHost, path: slowPath)
        let regexRows = [host(slowRegex, .regexWhole), path("/(a|aa)+c", .regexWhole)]
        for regex in regexRows {
            for mode in ConditionGroup.Mode.allCases {
                // A fresh cache each time: the first run of the row times out, nothing is disabled yet.
                let cache = PatternCache(budget: StepClock().budget)
                #expect(
                    ConditionGroup(mode: mode, rows: [regex]).evaluate(slow, status: nil, cache: cache)
                        == .patternTimedOut, "\(mode) \(regex.field)")
                // Beside a cheap row that does not settle the answer, the result is the same.
                let settle: ConditionRow = mode == .all ? method("GET") : method("POST")
                let cache2 = PatternCache(budget: StepClock().budget)
                #expect(
                    ConditionGroup(mode: mode, rows: [settle, regex]).evaluate(slow, status: nil, cache: cache2)
                        == .patternTimedOut, "\(mode) \(regex.field) with a cheap row")
            }
        }
    }

    @Test func disabledRegexIsReportedInEveryMode() {
        let slow = target(host: slowHost)
        let regex = host(slowRegex, .regexWhole)
        let cache = PatternCache(budget: StepClock().budget)
        for _ in 0..<3 {
            #expect(group(.all, regex).evaluate(slow, status: nil, cache: cache) == .patternTimedOut)
        }
        for mode in ConditionGroup.Mode.allCases {
            #expect(
                ConditionGroup(mode: mode, rows: [regex]).evaluate(slow, status: nil, cache: cache) == .patternDisabled,
                "\(mode)")
            // Even an input the pattern could handle is not matched while it is switched off.
            #expect(
                ConditionGroup(mode: mode, rows: [regex]).evaluate(target(host: "aac"), status: nil, cache: cache)
                    == .patternDisabled, "\(mode)")
        }
    }

    @Test func aRegexRowThatFinishesInTimeIsAnOrdinaryAnswer() {
        let cache = PatternCache(budget: StepClock().budget)
        let regex = host(#"(a|aa)+c"#, .regexWhole)
        #expect(group(.all, regex).evaluate(target(host: "aac"), status: nil, cache: cache) == .matched)
        #expect(group(.none, regex).evaluate(target(host: "aac"), status: nil, cache: cache) == .noMatch)
        #expect(group(.none, regex).evaluate(target(host: "b"), status: nil, cache: cache) == .matched)
    }

    // MARK: Judgment point

    @Test func judgmentPointIsLatestRowPoint() {
        #expect(group(.all, scheme("https")).judgmentPoint == .connect)
        #expect(group(.all, scheme("https"), path("/")).judgmentPoint == .request)
        #expect(group(.all, path("/"), status("400-499")).judgmentPoint == .response)
        #expect(group(.any, status("400-499"), scheme("https")).judgmentPoint == .response)
        #expect(ConditionGroup().judgmentPoint == .connect)
        #expect(ConditionGroup(mode: .none).judgmentPoint == .connect)
        #expect(group(.all, ConditionRow(field: .allSessions, op: .equals)).judgmentPoint == .connect)
    }

    // MARK: The single-field legacy matcher

    @Test func legacyMatcherMapsEveryAllowedCombination() {
        let cases: [(ConditionRow, RuleMatcher)] = [
            (ConditionRow(field: .scheme, op: .equals, value: "https"), RuleMatcher(scheme: "https")),
            (
                ConditionRow(field: .host, op: .hostPattern, value: "*.a.test"),
                RuleMatcher(hostPattern: "*.a.test", hostSyntax: .literal)
            ),
            (
                ConditionRow(field: .host, op: .wildcard, value: "a-?.test"),
                RuleMatcher(hostPattern: "a-?.test", hostSyntax: .wildcard)
            ),
            (
                ConditionRow(field: .host, op: .regexWhole, value: "(a|b)\\.test"),
                RuleMatcher(hostPattern: "(a|b)\\.test", hostSyntax: .regex)
            ),
            (ConditionRow(field: .port, op: .equals, value: "8443"), RuleMatcher(port: 8443)),
            (
                ConditionRow(field: .method, op: .equals, value: "POST", caseSensitive: true),
                RuleMatcher(method: "POST")
            ),
            (
                ConditionRow(field: .pathAndQuery, op: .equals, value: "/a?b=1", caseSensitive: true),
                RuleMatcher(path: .exact("/a?b=1"))
            ),
            (
                ConditionRow(field: .pathAndQuery, op: .startsWith, value: "/api/", caseSensitive: true),
                RuleMatcher(path: .prefix("/api/"))
            ),
            (
                ConditionRow(field: .pathAndQuery, op: .wildcard, value: "/api/*", caseSensitive: true),
                RuleMatcher(path: .wildcard("/api/*"))
            ),
            (
                ConditionRow(field: .pathAndQuery, op: .regexWhole, value: "/api/.*", caseSensitive: true),
                RuleMatcher(path: .regex("/api/.*"))
            ),
            (ConditionRow(field: .statusCode, op: .inRange, value: "400-499"), RuleMatcher(statusRange: 400...499)),
            (ConditionRow(field: .statusCode, op: .inRange, value: "200-200"), RuleMatcher(statusRange: 200...200)),
            (ConditionRow(field: .allSessions, op: .equals), RuleMatcher()),
        ]
        for (row, expected) in cases {
            #expect(row.legacyMatcher == expected, "\(row)")
        }
        // Port and status rows read the same whatever the case flag says; so does "all sessions".
        #expect(
            ConditionRow(field: .port, op: .equals, value: "80", caseSensitive: true).legacyMatcher
                == RuleMatcher(port: 80))
        #expect(
            ConditionRow(field: .statusCode, op: .inRange, value: "500-599", caseSensitive: true).legacyMatcher
                == RuleMatcher(statusRange: 500...599))
        #expect(
            ConditionRow(field: .allSessions, op: .inRange, value: "x", caseSensitive: true).legacyMatcher
                == RuleMatcher())
    }

    @Test func legacyMatcherIsNilForUnsupportedCombinations() {
        let unsupported: [ConditionRow] = [
            ConditionRow(field: .method, op: .startsWith, value: "G", caseSensitive: true),
            ConditionRow(field: .method, op: .equals, value: "GET", caseSensitive: false),
            ConditionRow(field: .method, op: .regexWhole, value: "G.*", caseSensitive: true),
            ConditionRow(field: .pathAndQuery, op: .equals, value: "/a", caseSensitive: false),
            ConditionRow(field: .pathAndQuery, op: .startsWith, value: "/a", caseSensitive: false),
            ConditionRow(field: .pathAndQuery, op: .hostPattern, value: "/a", caseSensitive: true),
            ConditionRow(field: .pathAndQuery, op: .inRange, value: "1-2", caseSensitive: true),
            ConditionRow(field: .scheme, op: .equals, value: "https", caseSensitive: true),
            ConditionRow(field: .scheme, op: .startsWith, value: "http"),
            ConditionRow(field: .host, op: .equals, value: "a.test"),
            ConditionRow(field: .host, op: .startsWith, value: "a."),
            ConditionRow(field: .host, op: .hostPattern, value: "a.test", caseSensitive: true),
            ConditionRow(field: .host, op: .regexWhole, value: "a.*", caseSensitive: true),
            ConditionRow(field: .port, op: .startsWith, value: "44"),
            ConditionRow(field: .port, op: .inRange, value: "1-2"),
            ConditionRow(field: .statusCode, op: .equals, value: "404"),
            ConditionRow(field: .statusCode, op: .regexWhole, value: "4.."),
        ]
        for row in unsupported {
            #expect(row.legacyMatcher == nil, "\(row)")
        }
    }

    @Test func legacyMatcherIsNilWhenAPortOrStatusValueCannotBeRead() {
        for value in ["", "abc", "44 3", " 443", "+443", "-1", "4.5", "12345678901234567890"] {
            #expect(ConditionRow(field: .port, op: .equals, value: value).legacyMatcher == nil, "port \(value)")
        }
        for value in [
            "", "abc", "404", "500-400", "-", "400-", "-499", "400--499", "4-5-6", "+400-499", "400-+499", "4 0-499",
            "400-499 ", "99999999999-100000000000",
        ] {
            #expect(
                ConditionRow(field: .statusCode, op: .inRange, value: value).legacyMatcher == nil, "status \(value)")
        }
        // Values outside the HTTP ranges can still be read; validation is what rejects them.
        #expect(ConditionRow(field: .port, op: .equals, value: "70000").legacyMatcher == RuleMatcher(port: 70000))
        #expect(ConditionRow(field: .port, op: .equals, value: "0").legacyMatcher == RuleMatcher(port: 0))
        #expect(
            ConditionRow(field: .statusCode, op: .inRange, value: "50-60").legacyMatcher
                == RuleMatcher(statusRange: 50...60))
    }
}
