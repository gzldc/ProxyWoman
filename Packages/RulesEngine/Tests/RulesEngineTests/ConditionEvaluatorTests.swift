import FlowStore
import Foundation
import Testing

@testable import RulesEngine

private func target(
    host: String = "api.example.com", scheme: String = "https", port: Int = 443, method: String = "GET",
    path: String = "/v1/items?a=1"
) -> HTTPMessageTarget {
    HTTPMessageTarget(scheme: scheme, host: host, port: port, method: method, pathAndQuery: path)
}

private func header(_ name: String, _ value: String) -> HeaderField { HeaderField(name: name, value: value) }

private func input(
    _ target: HTTPMessageTarget = target(), headers: [HeaderField] = [], status: Int? = nil,
    responseHeaders: [HeaderField] = [], facts: ExchangeFacts = ExchangeFacts()
) -> ConditionInput {
    ConditionInput(
        target: target, requestHeaders: headers, response: status.map { ($0, responseHeaders) }, facts: facts)
}

private func calmCache() -> PatternCache { PatternCache(budget: RegexBudget(clock: { .zero })) }

private func row(
    _ field: ConditionField, _ op: ConditionOperator, _ value: String = "", name: String? = nil,
    caseSensitive: Bool = false
) -> ConditionRow {
    ConditionRow(field: field, name: name, op: op, value: value, caseSensitive: caseSensitive)
}

private func verdict(
    _ rows: [ConditionRow], mode: ConditionGroup.Mode = .all, _ input: ConditionInput = input(),
    allowance: RegexAllowance = RegexAllowance(total: .seconds(100)), cache: PatternCache = calmCache()
) -> ConditionVerdict {
    ConditionGroup(mode: mode, rows: rows).evaluate(input, allowance: allowance, cache: cache)
}

private func matches(
    _ rows: [ConditionRow], mode: ConditionGroup.Mode = .all, _ input: ConditionInput = input()
) -> Bool {
    verdict(rows, mode: mode, input).result == .matched
}

private func matches(_ single: ConditionRow, _ input: ConditionInput = input()) -> Bool {
    matches([single], input)
}

/// Counts the reads of an allowance's clock: every regular-expression row reads it twice.
private final class CountingClock: @unchecked Sendable {  // guarded by `lock`
    private let lock = NSLock()
    private var count = 0
    var reads: Int { lock.withLock { count } }
    func read() -> Duration {
        lock.withLock {
            count += 1
            return .zero
        }
    }
}

/// A clock whose reads the test scripts: every read returns the next value.
private final class ScriptedClock: @unchecked Sendable {  // guarded by `lock`
    private let lock = NSLock()
    private var values: [Duration]
    init(_ millis: [Int]) { values = millis.map { .milliseconds($0) } }
    func read() -> Duration { lock.withLock { values.isEmpty ? .seconds(1000) : values.removeFirst() } }
}

private let slowRegex = "(a|aa)+c"
private let slowPath = "/" + String(repeating: "a", count: 60) + "b"

@Suite("ConditionEvaluator")
struct ConditionEvaluatorTests {
    // MARK: the old path

    @Test func migratedRowsKeepTheLegacyPath() {
        let rows: [ConditionRow] = [
            row(.allSessions, .equals),
            row(.scheme, .equals, "HTTPS"),
            row(.scheme, .equals, "http"),
            row(.host, .hostPattern, "*.example.com"),
            row(.host, .hostPattern, "example.com"),
            row(.host, .hostPattern, "API.Example.com."),
            row(.host, .wildcard, "api?.example.*"),
            row(.host, .wildcard, "*.example.com"),
            row(.host, .regexWhole, "api[0-9]*\\.example\\.com"),
            row(.host, .regexWhole, "example"),
            row(.port, .equals, "443"),
            row(.port, .equals, "8443"),
            row(.method, .equals, "GET", caseSensitive: true),
            row(.method, .equals, "get", caseSensitive: true),
            row(.pathAndQuery, .equals, "/v1/items?a=1", caseSensitive: true),
            row(.pathAndQuery, .startsWith, "/v1", caseSensitive: true),
            row(.pathAndQuery, .startsWith, "/V1", caseSensitive: true),
            row(.pathAndQuery, .wildcard, "/v1/*", caseSensitive: true),
            row(.pathAndQuery, .regexWhole, "/v1/.*", caseSensitive: true),
            row(.pathAndQuery, .regexWhole, "items", caseSensitive: true),
            row(.statusCode, .inRange, "400-499"),
            row(.statusCode, .inRange, "200-200"),
        ]
        let targets = [
            target(),
            target(host: "API2.example.com.", scheme: "HTTP", port: 8443, method: "get", path: "/V1/items"),
            target(host: "example.com", path: "/other"),
            target(host: "[::1]", path: "*"),
        ]
        let statuses: [Int?] = [nil, 200, 404]
        for row in rows {
            guard let matcher = row.legacyMatcher else {
                Issue.record("not a legacy row: \(row)")
                continue
            }
            for target in targets {
                for status in statuses {
                    let cache = calmCache()
                    let expected = matcher.evaluate(target, status: status, cache: cache)
                    let actual = verdict([row], input(target, status: status), cache: cache)
                    #expect(actual == ConditionVerdict(result: expected, notes: []), "\(row) \(target) \(String(describing: status))")
                }
            }
        }
        // Whole groups of old rows: the new entry gives the old group's answer in every mode.
        for mode in ConditionGroup.Mode.allCases {
            for pair in [[rows[3], rows[12]], [rows[4], rows[9]], [rows[8], rows[20]], [rows[18], rows[1]]] {
                for target in targets {
                    for status in statuses {
                        let group = ConditionGroup(mode: mode, rows: pair)
                        let expected = group.evaluate(target, status: status, cache: calmCache())
                        let actual = group.evaluate(
                            input(target, status: status), allowance: RegexAllowance(), cache: calmCache())
                        #expect(actual.result == expected, "\(mode) \(pair) \(target)")
                        #expect(actual.notes.isEmpty)
                    }
                }
            }
        }
    }

    @Test func legacyRowsTheOldMatcherCannotReadNeverMatch() {
        // An unreadable port and an unreadable status range: R1 refuses them and never matches them.
        let port = row(.port, .equals, "x")
        let status = row(.statusCode, .inRange, "500-400")
        #expect(port.isLegacyNeverMatching && status.isLegacyNeverMatching)
        for mode in ConditionGroup.Mode.allCases {
            #expect(verdict([port], mode: mode).result == .noMatch)
            #expect(verdict([status], mode: mode, input(status: 450)).result == .noMatch)
            #expect(verdict([port, row(.allSessions, .equals)], mode: mode).result == .noMatch)
        }
    }

    // MARK: the request target

    @Test func methodEqualsCaseInsensitiveIsTheNewPath() {
        let new = row(.method, .equals, "get")
        let old = row(.method, .equals, "get", caseSensitive: true)
        #expect(matches(new))
        #expect(!matches(old))
        #expect(matches(row(.method, .notEquals, "post")))
    }

    @Test func hostContainsNormalisesTheHost() {
        let shouting = input(target(host: "EXAMPLE.com."))
        #expect(matches(row(.host, .contains, "example"), shouting))
        #expect(matches(row(.host, .contains, "example", caseSensitive: true), shouting))
        #expect(matches(row(.host, .endsWith, ".com", caseSensitive: true), shouting))
        #expect(matches(row(.host, .equals, "::1"), input(target(host: "[0:0::1]"))))
    }

    @Test func urlContainsReadsTheFullUrlWithQuery() {
        #expect(matches(row(.url, .contains, "example.com/v1/items?a=1")))
        #expect(matches(row(.url, .equals, "https://api.example.com/v1/items?a=1")))
        #expect(matches(row(.url, .contains, ":8443/"), input(target(port: 8443))))
        #expect(!matches(row(.url, .contains, "b=2")))
    }

    @Test func pathPortSchemeAndQueryStringRows() {
        let request = input(target(scheme: "http", port: 8080, path: "/a/b?x=1&y=2#frag"))
        #expect(matches(row(.path, .equals, "/a/b"), request))
        #expect(matches(row(.queryString, .equals, "x=1&y=2"), request))
        #expect(matches(row(.port, .greaterThan, "8000"), request))
        #expect(matches(row(.port, .inRange, "8000-8100"), request))
        #expect(matches(row(.scheme, .notEquals, "https"), request))
        #expect(matches(row(.scheme, .equals, "HTTP", caseSensitive: true), request))
        #expect(matches(row(.pathAndQuery, .contains, "y=2"), request))
        #expect(matches(row(.queryString, .isEmpty), input(target(path: "/plain"))))
    }

    @Test func queryParamEqualsDecodes() {
        let request = input(target(path: "/s?q=hello%20world&n%61me=x+y&empty="))
        #expect(matches(row(.queryParam, .equals, "hello world", name: "q"), request))
        #expect(matches(row(.queryParam, .equals, "x+y", name: "name"), request))
        #expect(matches(row(.queryParam, .isEmpty, name: "empty"), request))
        // A missing parameter is the empty string.
        #expect(matches(row(.queryParam, .isEmpty, name: "missing"), request))
        #expect(matches(row(.queryParam, .notContains, "x", name: "missing"), request))
        #expect(!matches(row(.queryParam, .equals, "hello world", name: "Q"), request))
    }

    // MARK: headers, cookies and the response

    @Test func absentHeaderComparesAsEmptyString() {
        #expect(matches(row(.requestHeader, .notContains, "x", name: "X-Absent")))
        #expect(matches(row(.requestHeader, .isEmpty, name: "X-Absent")))
        #expect(!matches(row(.requestHeader, .isNotEmpty, name: "X-Absent")))
        #expect(!matches(row(.requestHeader, .equals, "x", name: "X-Absent")))
        #expect(matches(row(.requestHeader, .notEquals, "x", name: "X-Absent")))
        // A number comparison on an absent value has nothing to compare.
        #expect(!matches(row(.requestBodySize, .greaterOrEqual, "0")))
        let present = input(status: 200)
        #expect(matches(row(.responseHeader, .isEmpty, name: "X-Absent"), present))
        #expect(matches(row(.responseCookie, .notContains, "a", name: "sid"), present))
    }

    @Test func requestHeaderReadsTheCurrentHeaders() {
        let request = input(headers: [header("x-token", "Bearer ABC"), header("X-Token", "second")])
        #expect(matches(row(.requestHeader, .equals, "bearer abc", name: "X-Token"), request))
        #expect(!matches(row(.requestHeader, .equals, "bearer abc", name: "X-Token", caseSensitive: true), request))
        #expect(matches(row(.requestHeader, .startsWith, "Bearer", name: "X-TOKEN", caseSensitive: true), request))
        // R8F2: a repeated header matches when any of its values does.
        #expect(matches(row(.requestHeader, .contains, "second", name: "X-Token"), request))
    }

    @Test func responseFieldsAreUnknownBeforeTheResponse() {
        let rows = [
            row(.responseHeader, .isEmpty, name: "Server"),
            row(.responseHeader, .notContains, "x", name: "Server"),
            row(.responseCookie, .notEquals, "1", name: "sid"),
            row(.statusCode, .notEquals, "200"),
            row(.statusCode, .lessThan, "600"),
        ]
        for single in rows {
            #expect(verdict([single]) == ConditionVerdict(result: .noMatch, notes: []), "\(single)")
            #expect(verdict([single], mode: .none) == ConditionVerdict(result: .noMatch, notes: []), "\(single)")
        }
    }

    @Test func responseFieldsReadTheResponse() {
        let response = input(status: 200, responseHeaders: [header("Server", "nginx/1.25")])
        #expect(matches(row(.responseHeader, .startsWith, "nginx", name: "server"), response))
        #expect(matches(row(.responseHeader, .regex, "\\d+\\.\\d+", name: "Server"), response))
    }

    @Test func cookieRows() {
        let request = input(
            headers: [header("Cookie", "a=1; sid=abc=def"), header("cookie", "sid=later")], status: 200,
            responseHeaders: [
                header("Set-Cookie", "theme=dark; Path=/"), header("Set-Cookie", "token=xyz; HttpOnly"),
            ])
        #expect(matches(row(.requestCookie, .equals, "abc=def", name: "sid"), request))
        // A row without a setting keeps the old comparison (cookie names exact, R8F2-T1a); a row that says so ignores case.
        #expect(matches(row(.requestCookie, .isEmpty, name: "SID"), request))
        #expect(
            !matches(
                ConditionRow(field: .requestCookie, name: "SID", op: .isEmpty, nameCaseSensitive: false), request))
        #expect(
            matches(
                ConditionRow(field: .requestCookie, name: "SID", op: .isEmpty, nameCaseSensitive: true), request))
        #expect(matches(row(.responseCookie, .equals, "xyz", name: "token"), request))
        #expect(matches(row(.responseCookie, .equals, "dark", name: "theme"), request))
        #expect(!matches(row(.responseCookie, .contains, "Path", name: "theme"), request))
    }

    @Test func statusCodeNumericAndTextComparisons() {
        let notFound = input(status: 404)
        let failed = input(status: 503)
        #expect(matches(row(.statusCode, .equals, "404"), notFound))
        #expect(!matches(row(.statusCode, .equals, "404"), failed))
        #expect(matches(row(.statusCode, .greaterOrEqual, "500"), failed))
        #expect(!matches(row(.statusCode, .greaterOrEqual, "500"), notFound))
        #expect(matches(row(.statusCode, .contains, "4"), notFound))
        #expect(!matches(row(.statusCode, .contains, "4"), failed))
        #expect(matches(row(.statusCode, .startsWith, "5"), failed))
        #expect(matches(row(.statusCode, .regex, "^4\\d\\d$"), notFound))
        #expect(!matches(row(.statusCode, .regex, "^4\\d\\d$"), failed))
        // The old inclusive range stays the old matcher's.
        #expect(matches(row(.statusCode, .inRange, "400-499"), notFound))
    }

    // MARK: sizes

    @Test func requestBodySizeFromContentLength() {
        let sized = input(headers: [header("Content-Length", " 2048 ")])
        #expect(matches(row(.requestBodySize, .greaterThan, "1024"), sized))
        #expect(matches(row(.requestBodySize, .inRange, "2048-2048"), sized))
        #expect(!matches(row(.requestBodySize, .lessThan, "1024"), sized))
        #expect(verdict([row(.requestBodySize, .lessThan, "1024")], sized).notes.isEmpty)
    }

    @Test func requestBodySizeUnknownNotesUnknownSize() {
        let unknownInputs = [
            input(),
            input(headers: [header("Transfer-Encoding", "chunked"), header("Content-Length", "10")]),
            input(headers: [header("Content-Length", "ten")]),
            input(headers: [header("Content-Length", "-1")]),
        ]
        for request in unknownInputs {
            #expect(
                verdict([row(.requestBodySize, .lessThan, "100")], request)
                    == ConditionVerdict(result: .noMatch, notes: [.unknownSize]))
            #expect(
                verdict([row(.requestBodySize, .notEquals, "5")], mode: .none, request)
                    == ConditionVerdict(result: .noMatch, notes: [.unknownSize]))
        }
    }

    // MARK: connection facts

    @Test func certificateFieldByName() {
        let certificate = CertificateSummary(
            subject: "CN=api.example.com", issuer: "CN=Example CA", serialNumber: "0A1B",
            sha256Fingerprint: String(repeating: "AB", count: 32),
            notBefore: Date(timeIntervalSince1970: 1_700_000_000), notAfter: Date(timeIntervalSince1970: 1_800_000_000))
        let tls = input(status: 200, facts: ExchangeFacts(certificate: certificate))
        #expect(matches(row(.certificate, .contains, "api.example", name: "subject"), tls))
        #expect(matches(row(.certificate, .equals, "cn=example ca", name: "issuer"), tls))
        #expect(matches(row(.certificate, .equals, "0a1b", name: "serialNumber"), tls))
        #expect(matches(row(.certificate, .startsWith, "ABAB", name: "sha256Fingerprint", caseSensitive: true), tls))
        #expect(matches(row(.certificate, .equals, "2023-11-14T22:13:20Z", name: "notBefore"), tls))
        #expect(matches(row(.certificate, .startsWith, "2027-01-15", name: "notAfter"), tls))
        #expect(!matches(row(.certificate, .contains, "api", name: "issuer"), tls))
    }

    @Test func certificateUnknownWhenNoTLS() {
        let plain = input(status: 200)
        for single in [row(.certificate, .isEmpty, name: "subject"), row(.certificate, .notContains, "x", name: "issuer")] {
            #expect(verdict([single], plain) == ConditionVerdict(result: .noMatch, notes: []))
            #expect(verdict([single], mode: .none, plain) == ConditionVerdict(result: .noMatch, notes: []))
        }
    }

    @Test func connectionFactsAreTextOrChoice() {
        let facts = ExchangeFacts(
            clientIP: "192.168.1.20", remoteIP: "2001:db8::1", clientHTTPVersion: .http1_1, upstreamHTTPVersion: .http2,
            clientTLSVersion: "TLS 1.3", upstreamTLSVersion: "TLS 1.2")
        let request = input(status: 200, facts: facts)
        #expect(matches(row(.clientIP, .startsWith, "192.168."), request))
        #expect(matches(row(.remoteIP, .contains, "db8"), request))
        #expect(matches(row(.clientHTTPVersion, .equals, "h1"), request))
        #expect(matches(row(.clientHTTPVersion, .equals, "H1", caseSensitive: true), request))
        #expect(matches(row(.upstreamHTTPVersion, .notEquals, "h1"), request))
        #expect(matches(row(.clientTLSVersion, .equals, "tls 1.3"), request))
        #expect(matches(row(.upstreamTLSVersion, .contains, "1.2"), request))
        // Nothing recorded: unknown, without a note.
        for single in [row(.clientIP, .isEmpty), row(.upstreamTLSVersion, .notEquals, "x"), row(.clientHTTPVersion, .notEquals, "h2")] {
            #expect(verdict([single], mode: .none, input(status: 200)) == ConditionVerdict(result: .noMatch, notes: []))
        }
    }

    @Test func clientAppNameVsPidVsPath() {
        let app = ClientApp(pid: 4242, name: "Safari", executablePath: "/Applications/Safari.app/Contents/MacOS/Safari")
        let request = input(facts: ExchangeFacts(app: .known(app)))
        #expect(matches(row(.clientApp, .equals, "safari", name: "name"), request))
        #expect(matches(row(.clientApp, .contains, "Safari.app", name: "path", caseSensitive: true), request))
        #expect(matches(row(.clientApp, .equals, "4242", name: "pid"), request))
        #expect(matches(row(.clientApp, .greaterThan, "4000", name: "pid"), request))
        #expect(!matches(row(.clientApp, .contains, "4242", name: "name"), request))
        let noPath = input(facts: ExchangeFacts(app: .known(ClientApp(pid: 1, name: "curl"))))
        #expect(matches(row(.clientApp, .isEmpty, name: "path"), noPath))
    }

    @Test func unknownAppNotesAppUnknown() {
        let unknown = input(facts: ExchangeFacts(app: .unknown))
        #expect(
            verdict([row(.clientApp, .notEquals, "x", name: "name")], unknown)
                == ConditionVerdict(result: .noMatch, notes: [.appUnknown]))
        // Two unknown rows, one note.
        #expect(
            verdict(
                [row(.clientApp, .equals, "x", name: "name"), row(.clientApp, .equals, "1", name: "pid")], mode: .any,
                unknown) == ConditionVerdict(result: .noMatch, notes: [.appUnknown]))
    }

    @Test func virtualClientRowsNeverMatchAndNoNote() {
        let virtual = input(facts: ExchangeFacts(app: .notApplicable))
        for single in [row(.clientApp, .notEquals, "x", name: "name"), row(.clientApp, .isEmpty, name: "path"), row(.clientIP, .isEmpty)] {
            for mode in ConditionGroup.Mode.allCases {
                #expect(verdict([single], mode: mode, virtual) == ConditionVerdict(result: .noMatch, notes: []))
            }
        }
    }

    @Test func requestDateAndTimeUseTheInjectedTimeZone() throws {
        let started = try Date("2026-10-23T23:30:15Z", strategy: .iso8601).addingTimeInterval(0.123)
        let utc = try #require(TimeZone(identifier: "UTC"))
        let shanghai = try #require(TimeZone(identifier: "Asia/Shanghai"))
        let inUTC = input(facts: ExchangeFacts(requestStartedAt: started, timeZone: utc))
        let inShanghai = input(facts: ExchangeFacts(requestStartedAt: started, timeZone: shanghai))
        #expect(matches(row(.requestTime, .equals, "23:30:15.123"), inUTC))
        #expect(matches(row(.requestTime, .equals, "07:30:15.123"), inShanghai))
        #expect(matches(row(.requestTime, .startsWith, "07:"), inShanghai))
        #expect(matches(row(.requestDate, .equals, "2026-10-23"), inUTC))
        #expect(matches(row(.requestDate, .equals, "2026-10-24"), inShanghai))
        #expect(matches(row(.requestDate, .after, "2026-10-23"), inShanghai))
        #expect(matches(row(.requestDate, .before, "2026-10-24"), inUTC))
        #expect(matches(row(.requestDate, .inRange, "2026-10-01..2026-10-23"), inUTC))
        #expect(!matches(row(.requestDate, .inRange, "2026-10-01..2026-10-23"), inShanghai))
        #expect(!matches(row(.requestDate, .equals, "2026-13-01"), inUTC))
    }

    // MARK: the record

    @Test func rulesModifiedReadsFactsAndEarlierRules() {
        let untouched = input()
        let modified = input(facts: ExchangeFacts(rulesModified: true))
        #expect(matches(row(.rulesModified, .equals, "false"), untouched))
        #expect(!matches(row(.rulesModified, .equals, "true"), untouched))
        #expect(matches(row(.rulesModified, .equals, "true"), modified))
        #expect(matches(row(.rulesModified, .notEquals, "false"), modified))
    }

    @Test func commentReadsTheCurrentComment() {
        #expect(matches(row(.comment, .isEmpty)))
        #expect(matches(row(.comment, .notContains, "slow")))
        let commented = input(facts: ExchangeFacts(comment: "Slow login"))
        #expect(matches(row(.comment, .contains, "slow"), commented))
        #expect(!matches(row(.comment, .contains, "slow", caseSensitive: true), commented))
    }

    @Test func appProtocolMatchesPrimaryClassOnly() {
        let websocket = [header("Connection", "Upgrade"), header("Upgrade", "websocket")]
        let socketIO = input(target(path: "/socket.io/?EIO=4"), headers: websocket)
        #expect(matches(row(.appProtocol, .equals, "websocket"), socketIO))
        #expect(!matches(row(.appProtocol, .equals, "socketio"), socketIO))
        #expect(matches(row(.appProtocol, .equals, "SocketIO"), input(target(path: "/socket.io/?EIO=4"))))
        #expect(matches(row(.appProtocol, .equals, "grpc"), input(headers: [header("Content-Type", "application/grpc+proto")])))
        let sse = input(status: 200, responseHeaders: [header("Content-Type", "text/event-stream; charset=utf-8")])
        #expect(matches(row(.appProtocol, .equals, "sse"), sse))
        #expect(!matches(row(.appProtocol, .equals, "http"), sse))
        #expect(matches(row(.appProtocol, .equals, "HTTP")))
        #expect(matches(row(.appProtocol, .notEquals, "grpc")))
        // An SSE row before the response: unknown.
        #expect(verdict([row(.appProtocol, .notEquals, "sse")], mode: .none) == ConditionVerdict(result: .noMatch, notes: []))
    }

    @Test func fieldsOfLaterTasksAreUnknownForNow() {
        for single in [
            row(.requestBody, .isEmpty), row(.responseBody, .notContains, "x"), row(.responseBodySize, .lessThan, "1"),
            row(.sessionState, .notEquals, "failed"), row(.durationMs, .lessThan, "100000"),
        ] {
            #expect(verdict([single], mode: .none, input(status: 200)) == ConditionVerdict(result: .noMatch, notes: []))
        }
    }

    // MARK: combining rows

    @Test func unknownDecidesNoneGroupAsNoMatch() {
        let unknownApp = input(facts: ExchangeFacts(app: .unknown))
        let rows = [row(.method, .equals, "POST"), row(.clientApp, .equals, "x", name: "name")]
        #expect(verdict(rows, mode: .none, unknownApp) == ConditionVerdict(result: .noMatch, notes: [.appUnknown]))
        // A matching row written first decides `none` before the unknown one is looked at.
        let decided = [row(.method, .equals, "GET"), row(.clientApp, .equals, "x", name: "name")]
        #expect(verdict(decided, mode: .none, unknownApp) == ConditionVerdict(result: .noMatch, notes: []))
    }

    @Test func unknownInAnyModeDoesNotHideALaterMatch() {
        let unknownSize = input()
        let rows = [row(.requestBodySize, .greaterThan, "10"), row(.method, .equals, "GET")]
        #expect(verdict(rows, mode: .any, unknownSize) == ConditionVerdict(result: .matched, notes: []))
        let none = [row(.requestBodySize, .greaterThan, "10"), row(.method, .equals, "POST")]
        #expect(verdict(none, mode: .any, unknownSize) == ConditionVerdict(result: .noMatch, notes: [.unknownSize]))
    }

    @Test func unknownInAllModeStopsAsNoMatch() {
        let unknownApp = input(facts: ExchangeFacts(app: .unknown))
        let rows = [
            row(.clientApp, .notEquals, "x", name: "name"), row(.requestBodySize, .greaterThan, "1"),
            row(.method, .equals, "GET"),
        ]
        #expect(verdict(rows, unknownApp) == ConditionVerdict(result: .noMatch, notes: [.appUnknown]))
    }

    @Test func patternProblemStillDecidesTheWholeGroup() {
        let slowInput = input(target(path: slowPath))
        let slowRows = [
            row(.path, .regex, slowRegex, caseSensitive: true),
            row(.pathAndQuery, .regexWhole, "/" + slowRegex, caseSensitive: true),
        ]
        for slow in slowRows {
            for mode in ConditionGroup.Mode.allCases {
                // A row that matches (all), one that does not (any, none) and the slow one.
                let other = mode == .all ? row(.method, .equals, "GET") : row(.method, .equals, "POST")
                let result = verdict(
                    [other, slow], mode: mode, slowInput, cache: PatternCache(budget: StepClock().budget))
                #expect(result.result == .patternTimedOut, "\(mode) \(slow)")
            }
            // Switched off after three timeouts in a row: disabled decides the group the same way.
            let cache = PatternCache(budget: StepClock().budget)
            for _ in 0..<3 { _ = verdict([slow], slowInput, cache: cache) }
            #expect(verdict([slow], mode: .none, slowInput, cache: cache).result == .patternDisabled)
        }
    }

    @Test func cheapRowsRunBeforeRegexRows() {
        let clock = CountingClock()
        let allowance = RegexAllowance(total: .seconds(1), clock: { clock.read() })
        let regexFirst = [row(.url, .regex, "items"), row(.method, .equals, "POST")]
        #expect(verdict(regexFirst, input(), allowance: allowance).result == .noMatch)
        #expect(clock.reads == 0)
        let passing = [row(.url, .regex, "items"), row(.method, .equals, "GET")]
        #expect(verdict(passing, input(), allowance: allowance).result == .matched)
        #expect(clock.reads == 2)
        // `any`: a cheap row that matches settles the group before the regex row.
        #expect(verdict([row(.url, .regex, "zzz"), row(.method, .equals, "GET")], mode: .any, input(), allowance: allowance).result == .matched)
        #expect(clock.reads == 2)
    }

    @Test func exhaustedAllowanceSkipsRemainingRegexRows() {
        // The first regular expression uses 5 ms of a 4 ms allowance; the next one has nothing left.
        let clock = ScriptedClock([0, 5])
        let allowance = RegexAllowance(total: .milliseconds(4), clock: { clock.read() })
        let rows = [row(.url, .regex, "nothing-here"), row(.path, .regex, "v1"), row(.url, .regex, "items")]
        #expect(verdict(rows, mode: .any, input(), allowance: allowance) == ConditionVerdict(result: .patternTimedOut, notes: []))
        #expect(allowance.remaining == .zero)
        // Cheap rows still answer once the allowance is gone.
        #expect(verdict([row(.method, .equals, "GET")], input(), allowance: allowance).result == .matched)
    }

    @Test func regexRowUsesFindSemantics() {
        #expect(matches(row(.url, .regex, "example\\.com/v1")))
        #expect(matches(row(.path, .regex, "^/v1/")))
        #expect(!matches(row(.path, .regex, "^items")))
        #expect(matches(row(.requestHeader, .regex, "^$", name: "X-Absent")))
        #expect(matches(row(.host, .regex, "API", caseSensitive: false)))
        #expect(!matches(row(.host, .regex, "API", caseSensitive: true)))
    }

    @Test func caseSensitiveFlagAppliesToTextRows() {
        let request = input(headers: [header("X-Mode", "Fast")])
        #expect(matches(row(.requestHeader, .equals, "fast", name: "X-Mode"), request))
        #expect(!matches(row(.requestHeader, .equals, "fast", name: "X-Mode", caseSensitive: true), request))
        #expect(matches(row(.requestHeader, .notEquals, "fast", name: "X-Mode", caseSensitive: true), request))
        #expect(matches(row(.path, .endsWith, "ITEMS")))
        #expect(!matches(row(.path, .endsWith, "ITEMS", caseSensitive: true)))
    }

    @Test func emptyGroupMatches() {
        for mode in ConditionGroup.Mode.allCases {
            #expect(verdict([], mode: mode) == ConditionVerdict(result: .matched, notes: []))
        }
    }

    @Test func rowsThatCannotBeReadNeverMatch() {
        // A comparison the field does not take, an unknown certificate part, and a bad regular expression.
        let tls = input(status: 200, facts: ExchangeFacts(certificate: CertificateSummary(
            subject: "s", issuer: "i", serialNumber: "1", sha256Fingerprint: "F", notBefore: .now, notAfter: .now)))
        for single in [
            row(.url, .wildcard, "*"), row(.rulesModified, .contains, "t"), row(.certificate, .isEmpty, name: "owner"),
            row(.url, .regex, "(unclosed"), row(.rulesModified, .equals, "maybe"),
        ] {
            for mode in ConditionGroup.Mode.allCases {
                #expect(verdict([single], mode: mode, tls).result == .noMatch, "\(single) \(mode)")
            }
        }
    }
}

@Suite struct ConditionFieldTextTests {
    @Test func publicTextsAreTheEvaluatorsOwn() {
        let date = Date(timeIntervalSince1970: 1_791_000_000.1239)
        let utc = TimeZone(secondsFromGMT: 0)!
        #expect(ConditionFieldText.requestTime(date, timeZone: utc) == ConditionEvaluator.timeText(date, timeZone: utc))
        #expect(ConditionFieldText.requestTime(date, timeZone: utc).hasSuffix(".123"))
        #expect(ConditionFieldText.declaredRequestLength([HeaderField(name: "content-length", value: "7")]) == 7)
        #expect(ConditionFieldText.declaredRequestLength([HeaderField(name: "content-length", value: "7"), HeaderField(name: "Transfer-Encoding", value: "chunked")]) == nil)
    }
}
