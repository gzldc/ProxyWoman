import FlowStore
import Foundation
import Testing

@testable import RulesEngine

private func header(_ name: String, _ value: String) -> HeaderField { HeaderField(name: name, value: value) }

private let utc = TimeZone(identifier: "UTC")!
/// 2026-10-25 12:00:00 UTC.
private let noon = Date(timeIntervalSince1970: 1_792_929_600)

private func input(
    path: String = "/v1/items?a=1", requestHeaders: [HeaderField] = [], status: Int? = nil,
    responseHeaders: [HeaderField] = [], facts: ExchangeFacts = ExchangeFacts(requestStartedAt: noon, timeZone: utc),
    completion: CompletionFacts? = nil
) -> ConditionInput {
    ConditionInput(
        target: HTTPMessageTarget(scheme: "https", host: "api.example.com", port: 443, method: "GET", pathAndQuery: path),
        requestHeaders: requestHeaders, response: status.map { ($0, responseHeaders) }, facts: facts,
        completion: completion)
}

private func result(_ row: ConditionRow, _ input: ConditionInput, mode: ConditionGroup.Mode = .all) -> RuleMatchResult {
    ConditionGroup(mode: mode, rows: [row]).evaluate(
        input, allowance: RegexAllowance(total: .seconds(100)), cache: PatternCache(budget: RegexBudget(clock: { .zero })))
        .result
}

private func hit(_ row: ConditionRow, _ input: ConditionInput) -> Bool { result(row, input) == .matched }

private struct Case: Sendable, CustomStringConvertible {
    var row: ConditionRow
    var expected: Bool
    var description: String { "\(row.field) \(row.op) '\(row.value)' name=\(row.name ?? "nil") -> \(expected)" }
    init(_ field: ConditionField, _ op: ConditionOperator, name: String? = nil, cs: Bool = false, nameCS: Bool = false,
         _ expected: Bool) {
        self.init(field, op, "", name: name, cs: cs, nameCS: nameCS, expected)
    }
    init(_ field: ConditionField, _ op: ConditionOperator, _ value: String, name: String? = nil,
         cs: Bool = false, nameCS: Bool = false, _ expected: Bool) {
        row = ConditionRow(field: field, name: name, op: op, value: value, caseSensitive: cs, nameCaseSensitive: nameCS)
        self.expected = expected
    }
}

@Suite("FiddlerConditionSemantics")
struct FiddlerConditionSemanticsTests {
    // MARK: request headers

    private var requestInput: ConditionInput {
        input(requestHeaders: [
            header("Accept", "text/html"), header("accept", "application/json"), header("X-Empty", ""),
            header("Cookie", "sid=Abc; Theme=dark"), header("Cookie", "sid=zzz"),
        ])
    }

    @Test func requestHeaderTable() {
        let cases: [Case] = [
            // A key: any same-named header may satisfy; names ignore case by default.
            Case(.requestHeader, .equals, "text/html", name: "ACCEPT", true),
            Case(.requestHeader, .equals, "application/json", name: "accept", true),
            Case(.requestHeader, .equals, "nope", name: "accept", false),
            Case(.requestHeader, .contains, "json", name: "Accept", true),
            Case(.requestHeader, .startsWith, "text", name: "Accept", true),
            Case(.requestHeader, .endsWith, "json", name: "Accept", true),
            Case(.requestHeader, .regex, "^application/", name: "Accept", true),
            Case(.requestHeader, .regex, "^zzz", name: "Accept", false),
            // Negative forms: none of the values satisfies the positive form.
            Case(.requestHeader, .notEquals, "text/html", name: "Accept", false),
            Case(.requestHeader, .notEquals, "other", name: "Accept", true),
            Case(.requestHeader, .notContains, "json", name: "Accept", false),
            Case(.requestHeader, .notContains, "xml", name: "Accept", true),
            // Aa on the name.
            Case(.requestHeader, .contains, "json", name: "ACCEPT", nameCS: true, false),
            Case(.requestHeader, .contains, "json", name: "accept", nameCS: true, true),
            // Aa on the value.
            Case(.requestHeader, .equals, "TEXT/HTML", name: "Accept", cs: true, false),
            Case(.requestHeader, .equals, "TEXT/HTML", name: "Accept", cs: false, true),
            // Emptiness: a missing header reads as the empty string, as before.
            Case(.requestHeader, .isEmpty, name: "X-Empty", true),
            Case(.requestHeader, .isNotEmpty, name: "X-Empty", false),
            Case(.requestHeader, .isEmpty, name: "X-Missing", true),
            Case(.requestHeader, .isNotEmpty, name: "Accept", true),
            Case(.requestHeader, .notEquals, "", name: "X-Missing", false),
            // Existence.
            Case(.requestHeader, .exists, name: "X-Empty", true),
            Case(.requestHeader, .exists, name: "X-Missing", false),
            Case(.requestHeader, .doesNotExist, name: "X-Missing", true),
            Case(.requestHeader, .doesNotExist, name: "Accept", false),
            Case(.requestHeader, .exists, name: "x-empty", nameCS: true, false),
            // An empty key means any header.
            Case(.requestHeader, .equals, "text/html", true),
            Case(.requestHeader, .contains, "dark", true),  // inside the Cookie header
            Case(.requestHeader, .contains, "not anywhere", false),
            Case(.requestHeader, .notContains, "not anywhere", true),
            Case(.requestHeader, .notContains, "text/html", false),
            Case(.requestHeader, .exists, true),
            Case(.requestHeader, .doesNotExist, false),
        ]
        for c in cases { #expect(hit(c.row, requestInput) == c.expected, "\(c)") }
    }

    @Test func anyHeaderOnNoHeadersAtAll() {
        let none = input()
        #expect(!hit(ConditionRow(field: .requestHeader, op: .exists), none))
        #expect(hit(ConditionRow(field: .requestHeader, op: .doesNotExist), none))
        #expect(hit(ConditionRow(field: .requestHeader, op: .notContains, value: "x"), none))
    }

    @Test func requestCookieTable() {
        let cases: [Case] = [
            Case(.requestCookie, .equals, "Abc", name: "sid", true),
            Case(.requestCookie, .equals, "zzz", name: "SID", true),  // same-named cookie in the second header
            Case(.requestCookie, .equals, "zzz", name: "SID", nameCS: true, false),
            Case(.requestCookie, .equals, "dark", name: "theme", true),
            Case(.requestCookie, .equals, "dark", name: "theme", nameCS: true, false),
            Case(.requestCookie, .notEquals, "Abc", name: "sid", false),
            Case(.requestCookie, .contains, "bc", name: "sid", true),
            Case(.requestCookie, .exists, name: "sid", true),
            Case(.requestCookie, .exists, name: "nope", false),
            Case(.requestCookie, .doesNotExist, name: "nope", true),
            Case(.requestCookie, .isEmpty, name: "nope", true),
            Case(.requestCookie, .equals, "dark", true),  // any cookie
            Case(.requestCookie, .contains, "zz", true),
            Case(.requestCookie, .notContains, "dark", false),
            Case(.requestCookie, .exists, true),
            Case(.requestCookie, .regex, "^A", name: "sid", true),
        ]
        for c in cases { #expect(hit(c.row, requestInput) == c.expected, "\(c)") }
        #expect(!hit(ConditionRow(field: .requestCookie, op: .exists), input()))
    }

    // MARK: response headers, cookies, cookie

    private var responseInput: ConditionInput {
        input(
            requestHeaders: [header("Cookie", "sid=req1; lang=en")], status: 200,
            responseHeaders: [
                header("Content-Type", "text/html"), header("Set-Cookie", "sid=resp1; Path=/; HttpOnly"),
                header("set-cookie", "token=t0k; Secure"), header("X-Multi", "a"), header("X-Multi", "b"),
            ])
    }

    @Test func responseSideTable() {
        let cases: [Case] = [
            Case(.responseHeader, .equals, "b", name: "x-multi", true),
            Case(.responseHeader, .equals, "a", name: "x-multi", true),
            Case(.responseHeader, .notEquals, "a", name: "x-multi", false),
            Case(.responseHeader, .exists, name: "Content-Type", true),
            Case(.responseHeader, .doesNotExist, name: "Content-Type", false),
            Case(.responseHeader, .contains, "t0k", true),  // any header: inside Set-Cookie
            Case(.responseCookie, .equals, "resp1", name: "sid", true),
            Case(.responseCookie, .equals, "req1", name: "sid", false),
            Case(.responseCookie, .equals, "t0k", name: "TOKEN", true),
            Case(.responseCookie, .equals, "t0k", name: "TOKEN", nameCS: true, false),
            Case(.responseCookie, .exists, name: "token", true),
            Case(.responseCookie, .doesNotExist, name: "lang", true),
            Case(.responseCookie, .equals, "t0k", true),  // any Set-Cookie
            // `cookie` reads the request's Cookie or the response's Set-Cookie.
            Case(.cookie, .equals, "req1", name: "sid", true),
            Case(.cookie, .equals, "resp1", name: "sid", true),
            Case(.cookie, .equals, "other", name: "sid", false),
            Case(.cookie, .notEquals, "req1", name: "sid", false),
            Case(.cookie, .notEquals, "other", name: "sid", true),
            Case(.cookie, .equals, "en", name: "lang", true),
            Case(.cookie, .equals, "t0k", name: "token", true),
            Case(.cookie, .exists, name: "token", true),
            Case(.cookie, .exists, name: "lang", true),
            Case(.cookie, .doesNotExist, name: "nope", true),
            Case(.cookie, .contains, "t0", true),
            Case(.cookie, .exists, true),
        ]
        for c in cases { #expect(hit(c.row, responseInput) == c.expected, "\(c)") }
    }

    @Test func responseFieldsAreUnknownBeforeTheResponse() {
        let early = requestInputWithCookie
        for field in [ConditionField.responseHeader, .responseCookie, .cookie] {
            #expect(result(ConditionRow(field: field, op: .exists), early) == .noMatch, "\(field)")
            #expect(result(ConditionRow(field: field, op: .doesNotExist), early) == .noMatch, "\(field)")
        }
    }

    private var requestInputWithCookie: ConditionInput { input(requestHeaders: [header("Cookie", "a=b")]) }

    // MARK: TLS version

    @Test func tlsVersionReadsClientOrRemote() {
        func facts(_ client: String?, _ upstream: String?) -> ConditionInput {
            input(facts: ExchangeFacts(clientTLSVersion: client, upstreamTLSVersion: upstream, requestStartedAt: noon, timeZone: utc))
        }
        let cases: [(ConditionRow, String?, String?, Bool)] = [
            (ConditionRow(field: .tlsVersion, op: .equals, value: "TLS 1.3"), "TLS 1.2", "TLS 1.3", true),
            (ConditionRow(field: .tlsVersion, op: .equals, value: "TLS 1.3"), "TLS 1.3", "TLS 1.2", true),
            (ConditionRow(field: .tlsVersion, op: .equals, value: "TLS 1.3"), "TLS 1.2", "TLS 1.2", false),
            (ConditionRow(field: .tlsVersion, op: .equals, value: "TLS 1.3"), "TLS 1.3", nil, true),
            (ConditionRow(field: .tlsVersion, op: .equals, value: "TLS 1.3"), nil, "TLS 1.3", true),
            (ConditionRow(field: .tlsVersion, op: .notEquals, value: "TLS 1.3"), "TLS 1.3", "TLS 1.2", false),
            (ConditionRow(field: .tlsVersion, op: .notEquals, value: "TLS 1.3"), "TLS 1.2", "TLS 1.2", true),
            (ConditionRow(field: .tlsVersion, op: .contains, value: "1.2"), "TLS 1.3", "TLS 1.2", true),
            (ConditionRow(field: .tlsVersion, op: .regex, value: "1\\.[23]$"), "TLS 1.0", "TLS 1.1", false),
            (ConditionRow(field: .tlsVersion, op: .isNotEmpty), "TLS 1.0", nil, true),
            // Nothing known at all: the row is unknown, so it does not match, in either direction.
            (ConditionRow(field: .tlsVersion, op: .equals, value: "TLS 1.3"), nil, nil, false),
            (ConditionRow(field: .tlsVersion, op: .notEquals, value: "TLS 1.3"), nil, nil, false),
        ]
        for (row, client, upstream, expected) in cases {
            #expect(hit(row, facts(client, upstream)) == expected, "\(row.op) \(row.value) \(client ?? "-") \(upstream ?? "-")")
        }
        #expect(ConditionField.tlsVersion.knowablePoint == .response)
    }

    // MARK: numbers

    @Test func numberTable() {
        let done = CompletionFacts(state: .completed, durationMilliseconds: 1500, responseWireBytes: 2048)
        let full = input(
            requestHeaders: [header("Content-Length", "120")], status: 404, completion: done)
        let cases: [Case] = [
            Case(.statusCode, .equals, "404", true), Case(.statusCode, .notEquals, "404", false),
            Case(.statusCode, .greaterOrEqual, "404", true), Case(.statusCode, .greaterThan, "404", false),
            Case(.statusCode, .lessOrEqual, "404", true), Case(.statusCode, .lessThan, "404", false),
            Case(.statusCode, .lessThan, "500", true),
            Case(.statusCode, .isEmpty, false), Case(.statusCode, .isNotEmpty, true),
            Case(.statusCode, .regex, "^4\\d\\d$", true), Case(.statusCode, .regex, "^5", false),
            Case(.statusCode, .contains, "04", true),  // old text comparison stays
            Case(.requestBodySize, .equals, "120", true), Case(.requestBodySize, .greaterThan, "120", false),
            Case(.requestBodySize, .greaterOrEqual, "120", true), Case(.requestBodySize, .regex, "^1", true),
            Case(.requestBodySize, .inRange, "100-200", true),  // old shape
            Case(.requestBodySize, .isNotEmpty, true),
            Case(.responseBodySize, .equals, "2048", true), Case(.responseBodySize, .lessThan, "2048", false),
            Case(.durationMs, .greaterOrEqual, "1500", true), Case(.durationMs, .lessOrEqual, "1499", false),
            Case(.durationMs, .regex, "^15", true), Case(.durationMs, .isNotEmpty, true),
        ]
        for c in cases { #expect(hit(c.row, full) == c.expected, "\(c)") }
    }

    @Test func numbersThatAreNotThereAreEmpty() {
        // No response yet: the status is empty. No Content-Length: the size is empty.
        let bare = input()
        #expect(hit(ConditionRow(field: .statusCode, op: .isEmpty), bare))
        #expect(!hit(ConditionRow(field: .statusCode, op: .isNotEmpty), bare))
        #expect(hit(ConditionRow(field: .requestBodySize, op: .isEmpty), bare))
        #expect(!hit(ConditionRow(field: .requestBodySize, op: .isNotEmpty), bare))
        #expect(!hit(ConditionRow(field: .requestBodySize, op: .equals, value: "0"), bare))
        let noWire = input(completion: CompletionFacts(state: .failed, durationMilliseconds: 5, responseWireBytes: nil))
        #expect(hit(ConditionRow(field: .responseBodySize, op: .isEmpty), noWire))
        #expect(!hit(ConditionRow(field: .responseBodySize, op: .isNotEmpty), noWire))
        #expect(hit(ConditionRow(field: .durationMs, op: .isNotEmpty), noWire))
        // Regex needs a value to read.
        #expect(!hit(ConditionRow(field: .statusCode, op: .regex, value: ".*"), bare))
    }

    @Test func processIDIsANumberAndTheProcessIsText() {
        let app = ClientApp(pid: 1234, name: "Safari", executablePath: "/Applications/Safari.app")
        let known = input(facts: ExchangeFacts(app: .known(app), requestStartedAt: noon, timeZone: utc))
        let unknown = input(facts: ExchangeFacts(app: .unknown, requestStartedAt: noon, timeZone: utc))
        let cases: [Case] = [
            Case(.clientApp, .equals, "Safari:1234", true), Case(.clientApp, .equals, "safari:1234", true),
            Case(.clientApp, .equals, "safari:1234", cs: true, false),
            Case(.clientApp, .startsWith, "Safari", true), Case(.clientApp, .endsWith, ":1234", true),
            Case(.clientApp, .contains, "Chrome", false), Case(.clientApp, .notContains, "Chrome", true),
            Case(.clientApp, .regex, "^Safari:\\d+$", true), Case(.clientApp, .isNotEmpty, true),
            Case(.clientApp, .equals, "Safari", name: "name", true),
            Case(.clientApp, .equals, "1234", name: "pid", true),
            Case(.clientApp, .greaterThan, "1000", name: "pid", true),
            Case(.clientApp, .inRange, "1-2000", name: "pid", true),
            Case(.clientApp, .contains, "Safari.app", name: "path", true),
        ]
        for c in cases { #expect(hit(c.row, known) == c.expected, "\(c)") }
        #expect(!hit(ConditionRow(field: .clientApp, op: .contains, value: "Safari"), unknown))
        #expect(!hit(ConditionRow(field: .clientApp, op: .notContains, value: "Safari"), unknown))
    }

    // MARK: dates

    @Test func requestDateTable() {
        // The request is at 2026-10-25 12:00 UTC.
        let cases: [Case] = [
            Case(.requestDate, .equals, "2026-10-25", true), Case(.requestDate, .equals, "2026-10-24", false),
            Case(.requestDate, .notEquals, "2026-10-25", false), Case(.requestDate, .notEquals, "2026-10-26", true),
            Case(.requestDate, .afterOrEqual, "2026-10-25", true), Case(.requestDate, .afterOrEqual, "2026-10-24", true),
            Case(.requestDate, .afterOrEqual, "2026-10-26", false),
            Case(.requestDate, .after, "2026-10-25", false), Case(.requestDate, .after, "2026-10-24", true),
            Case(.requestDate, .beforeOrEqual, "2026-10-25", true), Case(.requestDate, .beforeOrEqual, "2026-10-26", true),
            Case(.requestDate, .beforeOrEqual, "2026-10-24", false),
            Case(.requestDate, .before, "2026-10-25", false), Case(.requestDate, .before, "2026-10-26", true),
            Case(.requestDate, .isEmpty, false), Case(.requestDate, .isNotEmpty, true),
            Case(.requestDate, .inRange, "2026-10-01..2026-10-25", true),  // old shape
        ]
        for c in cases { #expect(hit(c.row, input()) == c.expected, "\(c)") }
    }

    // MARK: HTTP version

    @Test func httpVersionIsTextWithOldLabelsKept() {
        func facts(_ v: HTTPWireVersion?) -> ConditionInput {
            input(facts: ExchangeFacts(clientHTTPVersion: v, upstreamHTTPVersion: v, requestStartedAt: noon, timeZone: utc))
        }
        let cases: [(HTTPWireVersion, ConditionOperator, String, Bool)] = [
            (.http1_0, .equals, "HTTP/1.0", true), (.http1_0, .equals, "HTTP/1.1", false),
            (.http1_1, .equals, "HTTP/1.1", true), (.http1_1, .equals, "http/1.1", true),
            (.http1_1, .contains, "1.1", true), (.http1_1, .startsWith, "HTTP/1", true),
            (.http2, .equals, "HTTP/2", true), (.http2, .notEquals, "HTTP/2", false),
            (.http2, .endsWith, "/2", true), (.http2, .regex, "^HTTP/2$", true),
            (.http2, .isNotEmpty, "", true),
            // Old rows: coarse labels, both HTTP/1 versions are h1.
            (.http1_0, .equals, "h1", true), (.http1_1, .equals, "h1", true), (.http2, .equals, "h1", false),
            (.http2, .equals, "h2", true), (.http2, .notEquals, "h2", false), (.http1_1, .notEquals, "h2", true),
            (.http1_1, .equals, "H1", true),
        ]
        for (version, op, value, expected) in cases {
            for field in [ConditionField.clientHTTPVersion, .upstreamHTTPVersion] {
                let row = ConditionRow(field: field, op: op, value: value)
                #expect(hit(row, facts(version)) == expected, "\(field) \(version) \(op) \(value)")
            }
        }
        #expect(!hit(ConditionRow(field: .clientHTTPVersion, op: .equals, value: "HTTP/2"), input()))
    }

    // MARK: protocol

    @Test func protocolTable() {
        func proto(_ value: String, _ request: [HeaderField], path: String = "/", response: [HeaderField]? = nil) -> Bool {
            hit(
                ConditionRow(field: .appProtocol, op: .equals, value: value),
                input(path: path, requestHeaders: request, status: response == nil ? nil : 200, responseHeaders: response ?? []))
        }
        let ws = [header("Upgrade", "websocket"), header("Connection", "Upgrade")]
        // Plain HTTP and each class.
        #expect(proto("http", []))
        #expect(proto("websocket", ws))
        #expect(proto("socketio", [], path: "/socket.io/?EIO=4"))
        #expect(proto("grpc", [header("Content-Type", "application/grpc+proto")]))
        #expect(proto("sse", [], response: [header("Content-Type", "text/event-stream; charset=utf-8")]))
        // RPC cues: request Content-Type, response Content-Type, request headers.
        let rpcTypes = [
            "application/json-rpc", "application/x-thrift", "application/vnd.apache.thrift.binary",
            "application/x-protobuf", "application/protobuf", "application/connect+json", "application/connect+proto",
            "application/soap+xml; charset=utf-8",
        ]
        for type in rpcTypes {
            #expect(proto("rpc", [header("Content-Type", type)]), "\(type)")
            #expect(proto("rpc", [], response: [header("Content-Type", type)]), "\(type)")
            #expect(!proto("http", [header("Content-Type", type)]), "\(type)")
        }
        #expect(proto("rpc", [header("Connect-Protocol-Version", "1")]))
        #expect(proto("rpc", [header("SOAPAction", "\"urn:x\"")]))
        #expect(!proto("rpc", [header("Content-Type", "application/json")]))
        #expect(!proto("rpc", [header("Content-Type", "text/xml")]))
        // gRPC is not RPC, even though a gRPC body is Protobuf.
        #expect(!proto("rpc", [header("Content-Type", "application/grpc")]))
        // Priority: websocket > socketio > grpc > rpc > sse > http.
        #expect(proto("websocket", ws + [header("Content-Type", "application/grpc")], path: "/socket.io/"))
        #expect(proto("socketio", [header("Content-Type", "application/grpc")], path: "/socket.io/"))
        #expect(proto("grpc", [header("Content-Type", "application/grpc"), header("SOAPAction", "x")]))
        #expect(proto("rpc", [header("SOAPAction", "x")], response: [header("Content-Type", "text/event-stream")]))
        #expect(proto("sse", [header("Content-Type", "application/json")], response: [header("Content-Type", "text/event-stream")]))
        // notEquals still works (old rows).
        #expect(hit(ConditionRow(field: .appProtocol, op: .notEquals, value: "rpc"), input()))
    }

    @Test func protocolRowJudgmentPoints() {
        func point(_ value: String) -> EvaluationPoint { ConditionRow(field: .appProtocol, op: .equals, value: value).knowablePoint }
        #expect(point("sse") == .response)
        #expect(point("rpc") == .request)
        #expect(point("http") == .request)
    }

    @Test func rpcRuleJudgmentPointDecidesWhatCountsAsEvidence() {
        let rpc = ConditionRow(field: .appProtocol, op: .equals, value: "rpc")
        let status = ConditionRow(field: .statusCode, op: .equals, value: "200")
        // An rpc-only rule is judged at the request, with request cues only.
        #expect(ConditionGroup(rows: [rpc]).judgmentPoint == .request)
        #expect(hit(rpc, input(requestHeaders: [header("SOAPAction", "x")])))
        #expect(hit(rpc, input(requestHeaders: [header("Connect-Protocol-Version", "1")])))
        #expect(!hit(rpc, input()))
        // rpc plus a status row is judged at the response, where the response Content-Type counts.
        let group = ConditionGroup(rows: [rpc, status])
        #expect(group.judgmentPoint == .response)
        let cache = PatternCache(budget: RegexBudget(clock: { .zero }))
        func verdict(_ i: ConditionInput) -> RuleMatchResult {
            group.evaluate(i, allowance: RegexAllowance(total: .seconds(100)), cache: cache).result
        }
        #expect(verdict(input(status: 200, responseHeaders: [header("Content-Type", "application/json-rpc")])) == .matched)
        #expect(verdict(input(status: 200, responseHeaders: [header("Content-Type", "application/json")])) == .noMatch)
    }

    // MARK: session state

    @Test func sessionStateTable() {
        let done = CompletionFacts(state: .completed, durationMilliseconds: 1, responseWireBytes: 1)
        let failed = CompletionFacts(state: .failed, durationMilliseconds: 1, responseWireBytes: nil)
        let paused = ExchangeFacts(requestStartedAt: noon, timeZone: utc, isPausedAtBreakpoint: true)
        // (value, op, input, expected)
        let cases: [(String, ConditionOperator, ConditionInput, Bool)] = [
            ("opened", .equals, input(), true), ("opened", .equals, input(status: 200), true),
            ("opened", .equals, input(completion: done), false), ("opened", .equals, input(completion: failed), false),
            ("opened", .notEquals, input(), false),
            ("closed", .equals, input(), false), ("closed", .equals, input(completion: done), true),
            ("closed", .equals, input(completion: failed), true), ("closed", .notEquals, input(completion: done), false),
            ("paused", .equals, input(), false), ("paused", .equals, input(facts: paused), true),
            ("opened", .equals, input(facts: paused), false), ("closed", .equals, input(facts: paused), false),
            ("paused", .notEquals, input(facts: paused), false),
            // Old values keep their meaning: they read the finished exchange only.
            ("completed", .equals, input(completion: done), true), ("completed", .equals, input(completion: failed), false),
            ("failed", .equals, input(completion: failed), true), ("failed", .notEquals, input(completion: failed), false),
            ("completed", .notEquals, input(completion: failed), true),
            ("completed", .equals, input(), false), ("completed", .notEquals, input(), false),
            ("tunnel", .equals, input(completion: CompletionFacts(state: .tunnel, durationMilliseconds: 1, responseWireBytes: nil)), true),
            ("OPENED", .equals, input(), true),
        ]
        for (value, op, subject, expected) in cases {
            #expect(hit(ConditionRow(field: .sessionState, op: op, value: value), subject) == expected, "\(value) \(op)")
        }
    }

    // MARK: unchanged readers

    @Test func untouchedFieldsStillBehave() {
        let cases: [Case] = [
            Case(.url, .contains, "api.example.com", true), Case(.host, .equals, "api.example.com", true),
            Case(.path, .startsWith, "/v1", true), Case(.method, .equals, "get", true),
            Case(.scheme, .equals, "https", true), Case(.scheme, .notEquals, "https", false),
            Case(.requestTime, .startsWith, "12:00:00", true),
            Case(.comment, .isEmpty, true), Case(.rulesModified, .equals, "false", true),
        ]
        for c in cases { #expect(hit(c.row, input()) == c.expected, "\(c)") }
    }

    @Test func magicStringReadsTheUrlAndAnUnreadableOneNeverMatches() {
        let row = ConditionRow(field: .magicString, op: .contains, value: "items")
        #expect(result(row, input()) == .matched)
        #expect(result(row, input(), mode: .none) == .noMatch)
        let unreadable = ConditionRow(field: .magicString, op: .contains, value: "")
        #expect(result(unreadable, input()) == .noMatch)
        #expect(result(unreadable, input(), mode: .none) == .noMatch)
    }
}
