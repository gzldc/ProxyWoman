import FlowStore
import Foundation
import Testing

@testable import RulesEngine

/// One fixed exchange for the oracle: old rules, as stored before Rules 2.0, and a request head. The
/// legacy evaluator reads the rules as they are; the new one reads them migrated
/// (`Rule(migrating:)`). Each evaluation gets a fresh private cache, so the two evaluators never
/// share regex strikes and `PatternCache.shared` is never touched.
struct OracleScenario: Sendable, CustomTestStringConvertible {
    let name: String
    let rules: [LegacyRule]
    let request: HTTPMessageHead
    let makeCache: @Sendable () -> PatternCache

    init(
        _ name: String, request: HTTPMessageHead = OracleScenarios.get(),
        cache: @escaping @Sendable () -> PatternCache = OracleScenarios.calmCache, _ rules: [LegacyRule]
    ) {
        self.name = name
        self.rules = rules
        self.request = request
        self.makeCache = cache
    }

    var testDescription: String { name }

    var legacySnapshot: LegacyRuleSnapshot { LegacyRuleSnapshot(revision: 11, rules: rules) }
    var migratedSnapshot: RuleSnapshot { RuleSnapshot(revision: 11, rules: rules.map(Rule.init(migrating:))) }

    func legacyRequest() throws -> RequestRuleDecision {
        try LegacyRuleEvaluator.request(request, snapshot: legacySnapshot, cache: makeCache())
    }

    func migratedRequest() throws -> RequestRuleDecision {
        try RuleEvaluator.request(request, snapshot: migratedSnapshot, cache: makeCache())
    }
}

/// What spec 5.6.5 compares between the two evaluators: the head, route, breakpoint, body steps and
/// the match summary, without what Rules 2.0 added (`actionIndex`, `rulesModified`, `carry`).
enum OracleRequestResult: Equatable {
    struct Step: Equatable {
        var ruleID: UUID
        var action: BodyRewriteAction
    }

    struct Code: Equatable {
        var ruleID: UUID
        var code: RuleOutcomeCode
    }

    struct Matches: Equatable {
        var revision: UInt64
        var ruleIDs: [UUID]
        var total: Int
        var omitted: Int
        var outcomes: [Code]

        init(_ summary: RuleMatchSummary) {
            revision = summary.revision
            ruleIDs = summary.ruleIDs
            total = summary.total
            omitted = summary.omitted
            outcomes = summary.outcomes.map { Code(ruleID: $0.ruleID, code: $0.code) }
        }
    }

    case decided(
        effectiveHead: HTTPMessageHead, route: RuleRoute, breakpoint: BreakpointPauseMode?, bodyRewrites: [Step],
        matches: Matches)
    case failed(HTTPMutationError, Matches)
    /// Neither a decision nor a rule evaluation failure; never expected.
    case unexpected(String)

    init(_ evaluate: () throws -> RequestRuleDecision) {
        do {
            let decision = try evaluate()
            self = .decided(
                effectiveHead: decision.effectiveHead, route: decision.route, breakpoint: decision.breakpoint,
                bodyRewrites: decision.bodyRewrites.map { Step(ruleID: $0.ruleID, action: $0.action) },
                matches: Matches(decision.matches))
        } catch let error as RuleEvaluationError {
            self = .failed(error.mutation, Matches(error.matches))
        } catch {
            self = .unexpected("\(error)")
        }
    }

    var matches: Matches? {
        switch self {
        case .decided(_, _, _, _, let matches), .failed(_, let matches): matches
        case .unexpected: nil
        }
    }
}

/// One fixed exchange for the response-point oracle. Each evaluator runs the request point first and
/// hands the response point what it needs: the old one the original request target, the new one the
/// request decision's carry. Each evaluator gets one fresh private cache for both of its points, as
/// one exchange does in the proxy.
struct OracleResponseScenario: Sendable, CustomTestStringConvertible {
    /// The same rules and request, for the request point.
    let requestPoint: OracleScenario
    let response: HTTPMessageHead
    let isLocalResponse: Bool

    init(
        _ name: String, request: HTTPMessageHead = OracleScenarios.get(),
        response: HTTPMessageHead = OracleScenarios.response(), isLocalResponse: Bool = false,
        cache: @escaping @Sendable () -> PatternCache = OracleScenarios.calmCache, _ rules: [LegacyRule]
    ) {
        self.requestPoint = OracleScenario(name, request: request, cache: cache, rules)
        self.response = response
        self.isLocalResponse = isLocalResponse
    }

    var name: String { requestPoint.name }
    var testDescription: String { name }

    /// What ProxyCore passes: the client asked to switch protocols.
    var requestWasUpgradeCandidate: Bool { HTTPMutationValidator.isUpgradeCandidate(requestPoint.request.headers) }

    func legacyResponse() throws -> ResponseRuleDecision {
        guard case .request(let target, _) = requestPoint.request else {
            throw HTTPMutationError(code: .messageKindMismatch, field: .message)
        }
        let cache = requestPoint.makeCache()
        _ = try LegacyRuleEvaluator.request(requestPoint.request, snapshot: requestPoint.legacySnapshot, cache: cache)
        return try LegacyRuleEvaluator.response(
            response, request: target, snapshot: requestPoint.legacySnapshot,
            requestWasUpgradeCandidate: requestWasUpgradeCandidate, isLocalResponse: isLocalResponse, cache: cache)
    }

    func migratedResponse() throws -> ResponseRuleDecision {
        let cache = requestPoint.makeCache()
        let snapshot = requestPoint.migratedSnapshot
        let decision = try RuleEvaluator.request(requestPoint.request, snapshot: snapshot, cache: cache)
        return try RuleEvaluator.response(
            response, after: decision, snapshot: snapshot, requestWasUpgradeCandidate: requestWasUpgradeCandidate,
            isLocalResponse: isLocalResponse, cache: cache)
    }
}

/// What spec 5.6.5 compares at the response point: the head, breakpoint, body steps, status rewrite and
/// the match summary, without what Rules 2.0 added (`actionIndex`, `rulesModified`).
enum OracleResponseResult: Equatable {
    case decided(
        effectiveHead: HTTPMessageHead, breakpoint: BreakpointPauseMode?, bodyRewrites: [OracleRequestResult.Step],
        statusRewrite: Int?, matches: OracleRequestResult.Matches)
    case failed(HTTPMutationError, OracleRequestResult.Matches)
    /// Neither a decision nor a rule evaluation failure; never expected.
    case unexpected(String)

    init(_ evaluate: () throws -> ResponseRuleDecision) {
        do {
            let decision = try evaluate()
            self = .decided(
                effectiveHead: decision.effectiveHead, breakpoint: decision.breakpoint,
                bodyRewrites: decision.bodyRewrites.map {
                    OracleRequestResult.Step(ruleID: $0.ruleID, action: $0.action)
                },
                statusRewrite: decision.statusRewrite, matches: OracleRequestResult.Matches(decision.matches))
        } catch let error as RuleEvaluationError {
            self = .failed(error.mutation, OracleRequestResult.Matches(error.matches))
        } catch {
            self = .unexpected("\(error)")
        }
    }

    var matches: OracleRequestResult.Matches? {
        switch self {
        case .decided(_, _, _, _, let matches), .failed(_, let matches): matches
        case .unexpected: nil
        }
    }

    var statusRewrite: Int? {
        if case .decided(_, _, _, let status, _) = self { return status }
        return nil
    }
}

enum OracleScenarios {
    // MARK: building blocks

    /// `(a|aa)+c` never finishes on a long run of `a` followed by `b` under the stepping clock.
    static let slowHostRegex = "(a|aa)+c"
    static let slowPathRegex = "/(a|aa)+c"
    static let slowHost = String(repeating: "a", count: 60) + "b"
    static let slowPath = "/" + String(repeating: "a", count: 60) + "b"

    /// A private cache whose clock never moves: no pattern ever times out.
    @Sendable static func calmCache() -> PatternCache { PatternCache(budget: RegexBudget(clock: { .zero })) }

    /// A private cache whose clock moves 1 ms per read: `slowHostRegex` / `slowPathRegex` time out.
    @Sendable static func steppingCache() -> PatternCache { PatternCache(budget: StepClock().budget) }

    /// A stepping cache in which `pattern` already timed out three times in a row, so it is switched off.
    static func disabledCache(_ pattern: String, caseInsensitive: Bool, slowInput: String) -> PatternCache {
        let cache = steppingCache()
        if let regex = try? cache.regex(pattern, caseInsensitive: caseInsensitive) {
            for _ in 0..<3 { _ = regex.matches(slowInput) }
        }
        return cache
    }

    static func target(
        host: String = "a.test", scheme: String = "https", port: Int = 443, method: String = "GET",
        path: String = "/v1/items?a=1"
    ) -> HTTPMessageTarget {
        HTTPMessageTarget(scheme: scheme, host: host, port: port, method: method, pathAndQuery: path)
    }

    static func get(
        host: String = "a.test", method: String = "GET", path: String = "/v1/items?a=1", headers: [HeaderField] = []
    ) -> HTTPMessageHead {
        .request(target(host: host, method: method, path: path), headers: headers)
    }

    static func response(_ status: Int = 200, reason: String? = "OK", headers: [HeaderField] = []) -> HTTPMessageHead {
        .response(status: status, reason: reason, headers: headers)
    }

    static func status(_ status: Int, includeLocal: Bool = false) -> LegacyRuleAction {
        .rewriteStatus(RewriteStatusAction(status: status, includeLocalResponses: includeLocal))
    }

    static let upgradeHeaders = [
        HeaderField(name: "Connection", value: "Upgrade"), HeaderField(name: "Upgrade", value: "websocket"),
        HeaderField(name: "Sec-WebSocket-Key", value: "k"),
    ]

    static let switchingHeaders = [
        HeaderField(name: "Connection", value: "Upgrade"), HeaderField(name: "Upgrade", value: "websocket"),
    ]

    static func text(length: String = "5", type: String = "text/plain") -> [HeaderField] {
        [HeaderField(name: "Content-Type", value: type), HeaderField(name: "Content-Length", value: length)]
    }

    static func rule(order: Int = 0, enabled: Bool = true, _ matcher: RuleMatcher, _ action: LegacyRuleAction) -> LegacyRule {
        LegacyRule(id: UUID(), name: "oracle", enabled: enabled, order: order, matcher: matcher, action: action)
    }

    static func rule(order: Int = 0, enabled: Bool = true, _ action: LegacyRuleAction) -> LegacyRule {
        rule(order: order, enabled: enabled, RuleMatcher(), action)
    }

    static func edit(_ direction: HTTPMessageDirection, _ operations: HeaderEdit...) -> LegacyRuleAction {
        .editHeaders(direction: direction, operations: operations)
    }

    static func remote(
        _ host: String, port: Int = 443, path: RemotePathPolicy = .preserve, preserve: Bool = false
    ) -> MapRemoteAction {
        MapRemoteAction(
            targetScheme: "https", targetHost: host, targetPort: port, path: path, preserveCredentials: preserve)
    }

    static let localFile = MapLocalAction(
        assetID: UUID(uuidString: "00000000-0000-0000-0000-00000000F11E")!, status: 201,
        headers: [HeaderField(name: "Content-Type", value: "text/plain")])

    static let directory = MapLocalDirectoryAction(
        bookmark: Data([1, 2, 3]), displayName: "site", headers: [HeaderField(name: "X-Dir", value: "1")])

    static func body(_ find: String = "a", _ replacement: String = "b") -> BodyRewriteAction {
        BodyRewriteAction(find: find, replacement: replacement)
    }

    // MARK: request-point scenarios that must give identical results

    static let requestScenarios: [OracleScenario] = [
        OracleScenario("noRules", []),
        OracleScenario(
            "requestHeaderEditsInRuleOrder", request: get(headers: [HeaderField(name: "Accept", value: "*/*")]),
            [
                rule(order: 1, edit(.request, .set(name: "X-A", value: "second"))),
                rule(order: 0, edit(.request, .set(name: "X-A", value: "first"), .append(name: "x-b", value: "1"))),
                rule(
                    order: 2, RuleMatcher(hostPattern: "elsewhere.test"),
                    edit(.request, .append(name: "X-No", value: "1"))),
                rule(order: 3, edit(.request, .remove(name: "accept"))),
            ]),
        OracleScenario(
            "equalOrderKeepsStoredPosition",
            (1...3).map { rule(order: 3, edit(.request, .append(name: "X", value: "\($0)"))) }),
        OracleScenario(
            "responseHeaderEditAtTheRequestPoint",
            [rule(edit(.response, .set(name: "Access-Control-Allow-Origin", value: "*")))]),
        OracleScenario("mapLocalAlone", [rule(.mapLocal(localFile))]),
        OracleScenario(
            "mapLocalAfterHigherRules",
            [
                rule(order: 0, edit(.request, .append(name: "X-Before", value: "1"))),
                rule(order: 1, .breakpoint(direction: .request, mode: .headers)),
                rule(order: 2, RuleMatcher(path: .prefix("/v1/")), .mapLocal(localFile)),
            ]),
        OracleScenario(
            "mapLocalDirectory", request: get(path: "/files/a/b.txt?x=1"),
            [rule(RuleMatcher(path: .prefix("/files/")), .mapLocalDirectory(directory))]),
        OracleScenario(
            "mapLocalDirectoryUnsafePath", request: get(path: "/files/%2e%2e/secret"),
            [rule(RuleMatcher(path: .prefix("/files/")), .mapLocalDirectory(directory))]),
        OracleScenario(
            "mapRemoteAlone",
            [rule(.mapRemote(remote("b.test", port: 8443, path: .replace("/v2?x=1"), preserve: true)))]),
        OracleScenario(
            "mapRemoteThenRulesWithoutAHost",
            [
                rule(order: 0, .mapRemote(remote("b.test"))),
                rule(order: 1, edit(.request, .append(name: "X-After", value: "1"))),
                rule(
                    order: 2, RuleMatcher(method: "GET", path: .prefix("/v1")),
                    .breakpoint(direction: .request, mode: .fullBody)),
            ]),
        OracleScenario(
            "mapRemoteThenResponseRuleOnTheOldHost",
            [
                rule(order: 0, .mapRemote(remote("b.test"))),
                rule(order: 1, RuleMatcher(hostPattern: "a.test"), edit(.response, .set(name: "X-Cors", value: "1"))),
            ]),
        OracleScenario(
            "requestBreakpointsMerge",
            [
                rule(order: 0, .breakpoint(direction: .request, mode: .headers)),
                rule(order: 1, .breakpoint(direction: .request, mode: .fullBody)),
                rule(order: 2, .breakpoint(direction: .request, mode: .headers)),
            ]),
        OracleScenario(
            "responseBreakpointAtTheRequestPoint", [rule(.breakpoint(direction: .response, mode: .fullBody))]),
        OracleScenario(
            "requestBodyRewrite", request: get(method: "POST", headers: text()),
            [
                rule(order: 0, .rewriteBody(direction: .request, body("a", "b"))),
                rule(order: 1, .rewriteBody(direction: .request, body("b", "c"))),
            ]),
        OracleScenario(
            "requestBodyRewriteNotText", request: get(method: "POST", headers: text(type: "image/png")),
            [rule(.rewriteBody(direction: .request, body()))]),
        OracleScenario(
            "requestBodyRewriteTooLarge", request: get(method: "POST", headers: text(length: "999999999999999999999")),
            [rule(.rewriteBody(direction: .request, body()))]),
        OracleScenario(
            "requestBodyRewriteUnderBreakpoint", request: get(method: "POST", headers: text()),
            [
                rule(order: 0, .rewriteBody(direction: .request, body())),
                rule(order: 1, .breakpoint(direction: .request, mode: .headers)),
            ]),
        OracleScenario(
            "requestBodyRewriteBeforeMapLocal", request: get(method: "POST", headers: text()),
            [
                rule(order: 0, .rewriteBody(direction: .request, body())),
                rule(order: 1, .mapLocal(localFile)),
            ]),
        OracleScenario(
            "requestBodyRewriteWithMapRemote", request: get(method: "POST", headers: text()),
            [
                rule(order: 0, .mapRemote(remote("b.test"))),
                rule(order: 1, .rewriteBody(direction: .request, body())),
            ]),
        OracleScenario(
            "responseBodyAndStatusRewritesAtTheRequestPoint",
            [
                rule(order: 0, .rewriteBody(direction: .response, body())),
                rule(order: 1, .rewriteStatus(RewriteStatusAction(status: 503))),
            ]),
        OracleScenario(
            "upgradeSkipsRoutesBodiesAndBreakpoints", request: get(headers: upgradeHeaders),
            [
                rule(order: 0, .mapRemote(remote("b.test"))),
                rule(order: 1, .mapLocal(localFile)),
                rule(order: 2, RuleMatcher(path: .prefix("/")), .mapLocalDirectory(directory)),
                rule(order: 3, .breakpoint(direction: .request, mode: .fullBody)),
                rule(order: 4, edit(.request, .append(name: "X-T", value: "1"))),
                rule(order: 5, .rewriteBody(direction: .request, body())),
            ]),
        OracleScenario(
            "upgradeHandshakeEditIsRejected", request: get(headers: upgradeHeaders),
            [
                rule(order: 0, edit(.request, .append(name: "X-Ok", value: "1"))),
                rule(order: 1, edit(.request, .set(name: "Sec-WebSocket-Key", value: "z"))),
            ]),
        OracleScenario(
            "pathRegexTimesOut", request: get(path: slowPath), cache: steppingCache,
            [
                rule(
                    order: 0, RuleMatcher(path: .regex(slowPathRegex)),
                    edit(.request, .append(name: "X-Slow", value: "1"))),
                rule(order: 1, edit(.request, .append(name: "X-Fast", value: "1"))),
            ]),
        OracleScenario(
            "hostRegexTimesOut", request: get(host: slowHost), cache: steppingCache,
            [
                rule(
                    order: 0, RuleMatcher(hostPattern: slowHostRegex, hostSyntax: .regex),
                    .mapRemote(remote("b.test"))),
                rule(order: 1, .breakpoint(direction: .request, mode: .headers)),
            ]),
        OracleScenario(
            "pathRegexDisabled", request: get(path: slowPath),
            cache: { disabledCache(slowPathRegex, caseInsensitive: false, slowInput: slowPath) },
            [
                rule(order: 0, edit(.request, .append(name: "X-Fast", value: "1"))),
                rule(order: 1, RuleMatcher(path: .regex(slowPathRegex)), .mapLocal(localFile)),
            ]),
        OracleScenario(
            "regexAndWildcardRowsThatMatch", request: get(host: "api.example.com", path: "/v1/items/42"),
            [
                rule(
                    order: 0,
                    RuleMatcher(
                        hostPattern: "api\\.example\\.com", method: "GET", path: .regex("/v1/items/[0-9]+"),
                        hostSyntax: .regex),
                    edit(.request, .append(name: "X-Regex", value: "1"))),
                rule(
                    order: 1,
                    RuleMatcher(hostPattern: "*.example.com", path: .wildcard("/v1/*"), hostSyntax: .wildcard),
                    edit(.request, .append(name: "X-Wildcard", value: "1"))),
                rule(
                    order: 2, RuleMatcher(scheme: "HTTPS", hostPattern: "*.example.com", port: 443),
                    .breakpoint(direction: .request, mode: .headers)),
            ]),
        OracleScenario(
            "disabledRulesNeverRun",
            [
                rule(enabled: false, .mapRemote(remote("b.test"))),
                rule(enabled: false, .breakpoint(direction: .request, mode: .headers)),
                rule(enabled: false, edit(.request, .append(name: "X", value: "1"))),
                rule(enabled: false, .mapLocal(localFile)),
            ]),
        OracleScenario(
            "rejectedProtectedEdit",
            [
                rule(order: 0, edit(.request, .set(name: "X-Ok", value: "1"))),
                rule(order: 1, .breakpoint(direction: .request, mode: .headers)),
                rule(order: 2, edit(.request, .set(name: "Content-Length", value: "1"))),
                rule(order: 3, edit(.request, .set(name: "X-Never", value: "1"))),
            ]),
        OracleScenario(
            "rejectedBlockLimit",
            (0..<9).map {
                rule(order: $0, edit(.request, .append(name: "X-\($0)", value: String(repeating: "v", count: 8_000))))
            }
                + [rule(order: 9, .breakpoint(direction: .request, mode: .headers))]),
        OracleScenario(
            "statusRangedRulesAtTheRequestPoint",
            [
                // A request rule with a status range never passed validation; stored anyway, it never matches.
                rule(
                    order: 0, RuleMatcher(statusRange: 200...599),
                    edit(.request, .append(name: "X-Never", value: "1"))),
                rule(
                    order: 1, RuleMatcher(statusRange: 500...599), edit(.response, .append(name: "X-Later", value: "1"))
                ),
            ]),
        OracleScenario(
            "responseRulesOfAFailedFlow",
            [
                rule(order: 0, edit(.response, .append(name: "X-R", value: "1"))),
                rule(order: 1, RuleMatcher(hostPattern: "a.test"), .breakpoint(direction: .response, mode: .headers)),
                rule(order: 2, .rewriteBody(direction: .response, body())),
                rule(order: 3, .rewriteStatus(RewriteStatusAction(status: 500, includeLocalResponses: true))),
                rule(order: 4, RuleMatcher(path: .regex("/v1/.*")), edit(.response, .remove(name: "Server"))),
            ]),
        OracleScenario(
            "summaryIsBounded",
            (0..<300).map { rule(order: $0, edit(.request, .set(name: "X-N", value: "\($0)"))) }),
    ]

    // MARK: response-point scenarios that must give identical results

    static let responseScenarios: [OracleResponseScenario] = [
        OracleResponseScenario(
            "noRulesAtTheResponse", response: response(headers: [HeaderField(name: "Server", value: "s")]), []),
        OracleResponseScenario(
            "responseHeaderEditsInRuleOrder", response: response(headers: [HeaderField(name: "Server", value: "s")]),
            [
                rule(order: 1, edit(.response, .set(name: "X-A", value: "second"))),
                rule(order: 0, edit(.response, .set(name: "X-A", value: "first"), .append(name: "x-b", value: "1"))),
                rule(
                    order: 2, RuleMatcher(hostPattern: "elsewhere.test"),
                    edit(.response, .append(name: "X-No", value: "1"))),
                rule(order: 3, edit(.response, .remove(name: "server"))),
            ]),
        OracleResponseScenario(
            "requestAndResponseRulesInterleaved",
            [
                rule(order: 0, edit(.request, .append(name: "X-Req", value: "1"))),
                rule(order: 1, edit(.response, .append(name: "X-Res", value: "1"))),
                rule(order: 2, .breakpoint(direction: .request, mode: .headers)),
                rule(order: 3, .breakpoint(direction: .response, mode: .fullBody)),
            ]),
        OracleResponseScenario(
            "disabledResponseRulesNeverRun",
            [
                rule(enabled: false, edit(.response, .append(name: "X", value: "1"))),
                rule(enabled: false, .breakpoint(direction: .response, mode: .headers)),
                rule(enabled: false, status(500)),
            ]),
        OracleResponseScenario(
            "responseRulesAboveMapLocalOnTheLocalResponse", isLocalResponse: true,
            [
                rule(order: 0, edit(.response, .append(name: "X-A", value: "1"))),
                rule(order: 1, status(503)),
                rule(order: 2, status(500, includeLocal: true)),
                rule(order: 3, .mapLocal(localFile)),
            ]),
        OracleResponseScenario(
            "localResponseStatusRewriteNotOptedIn", isLocalResponse: true,
            [rule(order: 0, status(500)), rule(order: 1, .mapLocal(localFile))]),
        OracleResponseScenario(
            "singleStatusRewrite", response: response(200, reason: "OK", headers: text()), [rule(status(503))]),
        OracleResponseScenario(
            "statusRangedRulesReadTheArrivingStatus", response: response(503),
            [
                rule(order: 0, RuleMatcher(statusRange: 500...599), edit(.response, .append(name: "X-E", value: "1"))),
                rule(order: 1, RuleMatcher(statusRange: 200...299), .breakpoint(direction: .response, mode: .headers)),
                rule(
                    order: 2, RuleMatcher(hostPattern: "a.test", statusRange: 500...503),
                    edit(.response, .append(name: "X-H", value: "1"))),
            ]),
        OracleResponseScenario(
            "statusRangedRuleAboveAStatusRewrite",
            [
                rule(order: 0, RuleMatcher(statusRange: 200...299), edit(.response, .append(name: "X-Ok", value: "1"))),
                rule(order: 1, status(500)),
                // Reads 200 in the old evaluator and 500 in the new one: inside the range either way.
                rule(
                    order: 2, RuleMatcher(statusRange: 200...599), edit(.response, .append(name: "X-Any", value: "1"))),
            ]),
        OracleResponseScenario(
            "upgradeResponseSkipsBreakpointStatusAndBody", request: get(headers: upgradeHeaders),
            response: response(101, reason: "Switching Protocols", headers: switchingHeaders),
            [
                rule(order: 0, .breakpoint(direction: .response, mode: .headers)),
                rule(order: 1, status(500, includeLocal: true)),
                rule(order: 2, edit(.response, .append(name: "X-T", value: "1"))),
                rule(order: 3, .rewriteBody(direction: .response, body())),
            ]),
        OracleResponseScenario(
            "upgradeRequestAnsweredWithAFailure", request: get(headers: upgradeHeaders),
            response: response(400, reason: "Bad Request", headers: text()),
            [
                rule(order: 0, .breakpoint(direction: .response, mode: .fullBody)),
                rule(order: 1, status(500)),
                rule(order: 2, .rewriteBody(direction: .response, body())),
            ]),
        OracleResponseScenario(
            "responseOfferingAnUpgrade",
            response: response(
                headers: [
                    HeaderField(name: "Connection", value: "Upgrade"), HeaderField(name: "Upgrade", value: "h2c"),
                ]),
            [rule(order: 0, .breakpoint(direction: .response, mode: .headers)), rule(order: 1, status(502))]),
        OracleResponseScenario(
            "responseBodyRewrites", response: response(headers: text()),
            [
                rule(order: 0, .rewriteBody(direction: .response, body("a", "b"))),
                rule(order: 1, .rewriteBody(direction: .response, body("b", "c"))),
            ]),
        OracleResponseScenario(
            "responseBodyRewriteForHead", request: get(method: "HEAD"), response: response(headers: text()),
            [rule(.rewriteBody(direction: .response, body()))]),
        OracleResponseScenario(
            "responseBodyRewriteNoContent", response: response(204, reason: "No Content", headers: text()),
            [rule(.rewriteBody(direction: .response, body()))]),
        OracleResponseScenario(
            "responseBodyRewriteZeroLength", response: response(headers: text(length: "0")),
            [rule(.rewriteBody(direction: .response, body()))]),
        OracleResponseScenario(
            "responseBodyRewriteAfterARewriteTo204", response: response(headers: text()),
            [rule(order: 0, status(204)), rule(order: 1, .rewriteBody(direction: .response, body()))]),
        OracleResponseScenario(
            "responseBodyRewriteNotText", response: response(headers: text(type: "image/png")),
            [rule(.rewriteBody(direction: .response, body()))]),
        OracleResponseScenario(
            "responseBodyRewriteTooLarge", response: response(headers: text(length: "999999999999999999999")),
            [rule(.rewriteBody(direction: .response, body()))]),
        OracleResponseScenario(
            "responseBodyRewriteUnderBreakpoint", response: response(headers: text()),
            [
                rule(order: 0, .rewriteBody(direction: .response, body())),
                rule(order: 1, .breakpoint(direction: .response, mode: .headers)),
            ]),
        OracleResponseScenario(
            "responseBreakpointsMerge",
            [
                rule(order: 0, .breakpoint(direction: .response, mode: .headers)),
                rule(order: 1, .breakpoint(direction: .response, mode: .fullBody)),
                rule(order: 2, .breakpoint(direction: .response, mode: .headers)),
            ]),
        OracleResponseScenario(
            "rejectedProtectedResponseEdit",
            [
                rule(order: 0, edit(.response, .set(name: "X-Ok", value: "1"))),
                rule(order: 1, status(500)),
                rule(order: 2, edit(.response, .set(name: "Content-Length", value: "1"))),
                rule(order: 3, edit(.response, .set(name: "X-Never", value: "1"))),
            ]),
        OracleResponseScenario(
            "rejectedResponseBlockLimit",
            (0..<9).map {
                rule(order: $0, edit(.response, .append(name: "X-\($0)", value: String(repeating: "v", count: 8_000))))
            } + [rule(order: 9, status(500))]),
        OracleResponseScenario(
            "rejectedHandshakeFieldOnAnUpgradeAnswer", request: get(headers: upgradeHeaders),
            response: response(400),
            [rule(edit(.response, .set(name: "Sec-WebSocket-Accept", value: "z")))]),
        OracleResponseScenario(
            "statusRangedPathRegexTimesOut", request: get(path: slowPath), cache: steppingCache,
            [
                rule(
                    order: 0, RuleMatcher(path: .regex(slowPathRegex), statusRange: 200...299),
                    edit(.response, .append(name: "X-Slow", value: "1"))),
                rule(order: 1, edit(.response, .append(name: "X-Fast", value: "1"))),
            ]),
        OracleResponseScenario(
            "statusRangedPathRegexDisabled", request: get(path: slowPath),
            cache: { disabledCache(slowPathRegex, caseInsensitive: false, slowInput: slowPath) },
            [
                rule(order: 0, edit(.response, .append(name: "X-Fast", value: "1"))),
                rule(
                    order: 1, RuleMatcher(path: .regex(slowPathRegex), statusRange: 200...299),
                    .breakpoint(direction: .response, mode: .headers)),
            ]),
        OracleResponseScenario(
            "statusRangedPathRegexNotReachedOnAnotherStatus", request: get(path: slowPath),
            response: response(404), cache: steppingCache,
            [
                rule(
                    RuleMatcher(path: .regex(slowPathRegex), statusRange: 200...299),
                    edit(.response, .append(name: "X-Slow", value: "1")))
            ]),
        OracleResponseScenario(
            "mapRemoteThenResponseRuleWithoutAHost",
            [
                rule(order: 0, .mapRemote(remote("b.test"))),
                rule(
                    order: 1, RuleMatcher(path: .prefix("/v1/")),
                    edit(.response, .append(name: "X-After", value: "1"))),
            ]),
        OracleResponseScenario(
            "responseRuleOnTheOldHostAboveMapRemote",
            [
                rule(order: 0, RuleMatcher(hostPattern: "a.test"), edit(.response, .set(name: "X-Cors", value: "1"))),
                rule(order: 1, .mapRemote(remote("b.test"))),
            ]),
        OracleResponseScenario(
            "onlyRequestRules",
            [
                rule(order: 0, edit(.request, .append(name: "X-Req", value: "1"))),
                rule(order: 1, .breakpoint(direction: .request, mode: .headers)),
            ]),
        OracleResponseScenario(
            "responseSummaryIsBounded",
            (0..<300).map { rule(order: $0, edit(.response, .set(name: "X-N", value: "\($0)"))) }),
    ]

    // MARK: intended differences (spec 5.6.3), compared field by field in EvaluatorOracleTests

    /// Class 1: Map Local, then a lower request rule.
    static func classOneMapLocalThenLowerRule() -> (higher: LegacyRule, lower: LegacyRule, scenario: OracleScenario) {
        let higher = rule(order: 0, .mapLocal(localFile))
        let lower = rule(order: 1, edit(.request, .append(name: "X-Lower", value: "1")))
        return (higher, lower, OracleScenario("classOneMapLocalThenLowerRule", [higher, lower]))
    }

    /// Class 2: Map Remote moves the request away from the host a lower rule names.
    static func classTwoMapRemoteThenLowerHostRule() -> (higher: LegacyRule, lower: LegacyRule, scenario: OracleScenario) {
        let higher = rule(order: 0, .mapRemote(remote("b.test")))
        let lower = rule(
            order: 1, RuleMatcher(hostPattern: "a.test"), edit(.request, .append(name: "X-Lower", value: "1")))
        return (higher, lower, OracleScenario("classTwoMapRemoteThenLowerHostRule", [higher, lower]))
    }

    /// Class 3: two Map Remote rules.
    static func classThreeTwoMapRemotes() -> (higher: LegacyRule, lower: LegacyRule, scenario: OracleScenario) {
        let higher = rule(order: 0, .mapRemote(remote("b.test", path: .replace("/first"))))
        let lower = rule(order: 1, .mapRemote(remote("c.test", port: 8443)))
        return (higher, lower, OracleScenario("classThreeTwoMapRemotes", [higher, lower]))
    }

    /// Class 3: Map Remote, then Map Local.
    static func classThreeMapRemoteThenMapLocal() -> (higher: LegacyRule, lower: LegacyRule, scenario: OracleScenario) {
        let higher = rule(order: 0, .mapRemote(remote("b.test")))
        let lower = rule(order: 1, .mapLocal(localFile))
        return (higher, lower, OracleScenario("classThreeMapRemoteThenMapLocal", [higher, lower]))
    }

    /// Class 1 at the response point: Map Local, then a lower response rule on the local response.
    static func classOneLocalResponseLowerHeaderRule() -> (
        higher: LegacyRule, lower: LegacyRule, scenario: OracleResponseScenario
    ) {
        let higher = rule(order: 0, .mapLocal(localFile))
        let lower = rule(order: 1, edit(.response, .append(name: "X-Lower", value: "1")))
        return (
            higher, lower,
            OracleResponseScenario("classOneLocalResponseLowerHeaderRule", isLocalResponse: true, [higher, lower])
        )
    }

    /// Class 2 at the response point: a status rewrite, then a lower rule ranged on the new status.
    static func classTwoStatusThenRangeRule() -> (higher: LegacyRule, lower: LegacyRule, scenario: OracleResponseScenario) {
        let higher = rule(order: 0, status(500))
        let lower = rule(
            order: 1, RuleMatcher(statusRange: 500...599), edit(.response, .append(name: "X-Error", value: "1")))
        return (higher, lower, OracleResponseScenario("classTwoStatusThenRangeRule", [higher, lower]))
    }

    /// Class 2 at the response point: Map Remote moves the request away from the host a lower response
    /// rule names (the CORS example of spec 5.6.3).
    static func classTwoMapRemoteThenResponseRuleOnTheOldHost() -> (
        higher: LegacyRule, lower: LegacyRule, scenario: OracleResponseScenario
    ) {
        let higher = rule(order: 0, .mapRemote(remote("b.test")))
        let lower = rule(
            order: 1, RuleMatcher(hostPattern: "a.test"), edit(.response, .set(name: "X-Cors", value: "1")))
        return (
            higher, lower, OracleResponseScenario("classTwoMapRemoteThenResponseRuleOnTheOldHost", [higher, lower])
        )
    }

    /// Class 2, extended: a rule judged at the response (host and status range) above a lower-priority
    /// Map Remote that moves the request away from the host it names.
    static func classTwoExtensionResponseJudgedRuleAboveALowerURLChanger() -> (
        higher: LegacyRule, lower: LegacyRule, scenario: OracleResponseScenario
    ) {
        let higher = rule(
            order: 0, RuleMatcher(hostPattern: "a.test", statusRange: 500...599),
            edit(.response, .set(name: "X-Error-Origin", value: "a")))
        let lower = rule(order: 1, .mapRemote(remote("b.test")))
        return (
            higher, lower,
            OracleResponseScenario(
                "classTwoExtensionResponseJudgedRuleAboveALowerURLChanger", response: response(503),
                [higher, lower])
        )
    }

    /// Class 3 at the response point: two status rewrites.
    static func classThreeTwoStatusRewrites() -> (higher: LegacyRule, lower: LegacyRule, scenario: OracleResponseScenario) {
        let higher = rule(order: 0, status(500))
        let lower = rule(order: 1, status(404))
        return (higher, lower, OracleResponseScenario("classThreeTwoStatusRewrites", [higher, lower]))
    }
}
