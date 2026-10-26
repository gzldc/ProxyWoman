import FlowStore
import Foundation
import Testing

@testable import RulesEngine

private func id(_ n: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!
}

// One legacy action of each kind.
private let file = MapLocalAction(assetID: id(900), status: 200, headers: [])
private let directory = MapLocalDirectoryAction(bookmark: Data([1]), displayName: "dir")
private let remote = MapRemoteAction(targetScheme: "https", targetHost: "b.test", targetPort: 443, path: .preserve)
private let headerEdits = LegacyRuleAction.editHeaders(direction: .request, operations: [.set(name: "X-A", value: "1")])
private let responseBreakpoint = LegacyRuleAction.breakpoint(direction: .response, mode: .fullBody)
private let bodyRewrite = LegacyRuleAction.rewriteBody(
    direction: .response, BodyRewriteAction(find: "a", replacement: "b", syntax: .regex, caseSensitive: false))
private let statusRewrite = LegacyRuleAction.rewriteStatus(RewriteStatusAction(status: 500, includeLocalResponses: true))
private let plainStatus = RewriteStatusAction(status: 500)

private let sevenActions: [LegacyRuleAction] = [
    .mapLocal(file), .mapLocalDirectory(directory), .mapRemote(remote), headerEdits, responseBreakpoint, bodyRewrite,
    statusRewrite,
]

private func legacy(
    _ n: Int = 1, name: String = "r", enabled: Bool = true, order: Int = 0, matcher: RuleMatcher = RuleMatcher(),
    action: LegacyRuleAction = statusRewrite
) -> LegacyRule {
    LegacyRule(id: id(n), name: name, enabled: enabled, order: order, matcher: matcher, action: action)
}

private func migrated(_ matcher: RuleMatcher, action: LegacyRuleAction = statusRewrite) -> Rule {
    Rule(migrating: legacy(matcher: matcher, action: action))
}

private func thrown(_ body: () throws -> Void) -> RuleValidationError? {
    do {
        try body()
        return nil
    } catch let error as RuleValidationError {
        return error
    } catch {
        Issue.record("unexpected error \(error)")
        return nil
    }
}

private func row(
    _ field: ConditionField, _ op: ConditionOperator, _ value: String, caseSensitive: Bool = false
) -> ConditionRow {
    ConditionRow(field: field, op: op, value: value, caseSensitive: caseSensitive)
}

/// A response-direction rule that the old editor can show, built straight from rows.
private func rowsRule(
    _ rows: [ConditionRow], mode: ConditionGroup.Mode = .all, occurrence: Occurrence = .any,
    actions: [RuleAction] = [RuleAction(.rewriteStatus(plainStatus))]
) -> Rule {
    Rule(name: "r", conditions: ConditionGroup(mode: mode, occurrence: occurrence, rows: rows), actions: actions)
}

@Suite("RuleMigrationMapping")
struct RuleMigrationMappingTests {
    // MARK: Rows

    @Test func fullMatcherMapsToSixRowsInFixedOrder() {
        let matcher = RuleMatcher(
            scheme: "https", hostPattern: "*.a.test", port: 8443, method: "POST", path: .prefix("/api/"),
            statusRange: 400...499)
        let rule = Rule(migrating: legacy(matcher: matcher))
        #expect(rule.conditions.mode == .all)
        #expect(rule.conditions.occurrence == .any)
        #expect(
            rule.conditions.rows == [
                ConditionRow(field: .scheme, op: .equals, value: "https", caseSensitive: false),
                ConditionRow(field: .host, op: .hostPattern, value: "*.a.test", caseSensitive: false),
                ConditionRow(field: .port, op: .equals, value: "8443", caseSensitive: false),
                ConditionRow(field: .method, op: .equals, value: "POST", caseSensitive: true),
                ConditionRow(field: .pathAndQuery, op: .startsWith, value: "/api/", caseSensitive: true),
                ConditionRow(field: .statusCode, op: .inRange, value: "400-499", caseSensitive: false),
            ])
        #expect(rule.conditions.rows.allSatisfy { $0.name == nil })
    }

    @Test func eachFieldMakesOnlyItsOwnRow() {
        let cases: [(RuleMatcher, [ConditionRow])] = [
            (RuleMatcher(), []),
            (RuleMatcher(scheme: "HTTP"), [row(.scheme, .equals, "HTTP")]),
            (RuleMatcher(port: 443), [row(.port, .equals, "443")]),
            (RuleMatcher(method: "get"), [row(.method, .equals, "get", caseSensitive: true)]),
            (RuleMatcher(statusRange: 200...200), [row(.statusCode, .inRange, "200-200")]),
            (RuleMatcher(hostPattern: "a.test"), [row(.host, .hostPattern, "a.test")]),
        ]
        for (matcher, expected) in cases {
            #expect(migrated(matcher).conditions.rows == expected, "\(matcher)")
        }
    }

    @Test func hostSyntaxesUseLegacyOperators() {
        let cases: [(PatternSyntax, String, ConditionOperator)] = [
            (.literal, "*.A.test.", .hostPattern),
            (.literal, "[::1]", .hostPattern),
            (.wildcard, "api.*.test", .wildcard),
            (.regex, #"(api|www)\.a\.test"#, .regexWhole),
        ]
        for (syntax, value, op) in cases {
            let rows = migrated(RuleMatcher(hostPattern: value, hostSyntax: syntax)).conditions.rows
            // The value is kept as typed; the host row is never case-sensitive (decision D2).
            #expect(rows == [ConditionRow(field: .host, op: op, value: value, caseSensitive: false)], "\(syntax)")
        }
    }

    @Test func pathModesMapToOperators() {
        let cases: [(PathMatch, ConditionOperator?, String)] = [
            (.any, nil, ""),
            (.exact("/a?b=1"), .equals, "/a?b=1"),
            (.prefix("/api/"), .startsWith, "/api/"),
            (.wildcard("/v?/*"), .wildcard, "/v?/*"),
            (.regex("/v[0-9]+/.*"), .regexWhole, "/v[0-9]+/.*"),
        ]
        for (path, op, value) in cases {
            let rows = migrated(RuleMatcher(path: path)).conditions.rows
            if let op {
                #expect(rows == [ConditionRow(field: .pathAndQuery, op: op, value: value, caseSensitive: true)])
            } else {
                #expect(rows.isEmpty)
            }
        }
    }

    // MARK: Actions and identity

    @Test func actionMappingCoversAllSevenKinds() {
        let prefixMatcher = RuleMatcher(path: .prefix("/files/"))
        let cases: [(LegacyRuleAction, RuleMatcher, ActionKind)] = [
            (.mapLocal(file), RuleMatcher(), .returnFile(file)),
            (.mapLocalDirectory(directory), prefixMatcher, .returnDirectory(directory, pathPrefix: "/files/")),
            (.mapRemote(remote), RuleMatcher(), .mapRemote(remote)),
            (
                headerEdits, RuleMatcher(),
                .editHeaders(direction: .request, operations: [.set(name: "X-A", value: "1")])
            ),
            (responseBreakpoint, RuleMatcher(), .breakpoint(direction: .response, mode: .fullBody)),
            (
                bodyRewrite, RuleMatcher(),
                .rewriteBody(
                    direction: .response,
                    BodyRewriteAction(find: "a", replacement: "b", syntax: .regex, caseSensitive: false))
            ),
            (
                statusRewrite, RuleMatcher(),
                .rewriteStatus(RewriteStatusAction(status: 500, includeLocalResponses: true))
            ),
        ]
        #expect(cases.count == 7)
        for (action, matcher, expected) in cases {
            let rule = Rule(migrating: legacy(matcher: matcher, action: action))
            #expect(rule.actions == [RuleAction(expected, isFinal: false)], "\(action)")
            // Nothing is ticked by migration; returning a file is final by nature, not by a tick.
            #expect(rule.actions.allSatisfy { !$0.isFinal })
        }
        // The directory rule keeps its path row beside the action's own prefix.
        let rule = Rule(migrating: legacy(matcher: prefixMatcher, action: .mapLocalDirectory(directory)))
        #expect(rule.conditions.rows == [row(.pathAndQuery, .startsWith, "/files/", caseSensitive: true)])
        #expect(rule.actions.first?.kind == .returnDirectory(directory, pathPrefix: "/files/"))
    }

    @Test func idNameEnabledAndOrderArePreserved() {
        for (enabled, order) in [(true, 0), (false, 7), (true, -3)] {
            let old = legacy(42, name: "规则 “A”  ", enabled: enabled, order: order, matcher: RuleMatcher(port: 80))
            let rule = Rule(migrating: old)
            #expect(rule.id == old.id)
            #expect(rule.name == "规则 “A”  ")
            #expect(rule.enabled == enabled)
            #expect(rule.order == order)
            #expect(rule.groupID == nil)
            #expect(rule.note == nil)
            #expect(rule.conditions.mode == .all)
            #expect(rule.conditions.occurrence == .any)
            #expect(rule.actions.count == 1)
        }
    }

    @Test func compatInitEqualsMigratingInit() {
        let matchers = [
            RuleMatcher(),
            RuleMatcher(scheme: "https", hostPattern: "*.a.test", port: 8443, method: "POST", path: .prefix("/files/")),
            RuleMatcher(hostPattern: "a.*", path: .regex("/x"), hostSyntax: .wildcard),
        ]
        for (index, action) in sevenActions.enumerated() {
            let matcher = matchers[index % matchers.count]
            let compat = Rule(
                id: id(index), name: "n\(index)", enabled: index % 2 == 0, order: index, matcher: matcher,
                action: action)
            let old = LegacyRule(
                id: id(index), name: "n\(index)", enabled: index % 2 == 0, order: index, matcher: matcher,
                action: action)
            #expect(compat == Rule(migrating: old), "\(action)")
        }
    }

    // MARK: The single-action view

    private static let roundTripMatchers: [RuleMatcher] = [
        RuleMatcher(),
        RuleMatcher(scheme: "https"),
        RuleMatcher(hostPattern: "a.test"),
        RuleMatcher(hostPattern: "*.a.test"),
        RuleMatcher(hostPattern: "[::1]"),
        RuleMatcher(hostPattern: "*.a.test", hostSyntax: .wildcard),
        RuleMatcher(hostPattern: #"(api|www)\.a\.test"#, hostSyntax: .regex),
        RuleMatcher(port: 8443),
        RuleMatcher(method: "POST"),
        RuleMatcher(path: .exact("/a?b=1")),
        RuleMatcher(path: .prefix("/api/")),
        RuleMatcher(path: .wildcard("/v?/*")),
        RuleMatcher(path: .regex("/v[0-9]+/.*")),
        RuleMatcher(statusRange: 400...499),
        RuleMatcher(
            scheme: "https", hostPattern: "*.a.test", port: 8443, method: "POST", path: .prefix("/api/"),
            statusRange: 400...499),
        RuleMatcher(scheme: "http", hostPattern: "x.test", hostSyntax: .wildcard),
    ]

    @Test func simpleViewRoundTripsEveryMigratedRule() {
        var checked = 0
        for action in sevenActions {
            var matchers = Self.roundTripMatchers
            if case .mapLocalDirectory = action {
                // A directory rule is only well formed with a prefix path; add the shapes that have one.
                matchers = [
                    RuleMatcher(path: .prefix("/files/")),
                    RuleMatcher(scheme: "https", hostPattern: "a.test", port: 443, path: .prefix("/")),
                    RuleMatcher(hostPattern: "*.a.test", path: .prefix("/a/b/"), hostSyntax: .wildcard),
                ]
            }
            for matcher in matchers {
                let old = legacy(matcher: matcher, action: action)
                #expect(
                    Rule(migrating: old).simple == SimpleRule(matcher: old.matcher, action: old.action, mode: .all),
                    "\(action) \(matcher)")
                checked += 1
            }
        }
        #expect(checked >= 7 * 3)
    }

    @Test func simpleViewCarriesTheModeAndIgnoresRowOrder() {
        let rows = [row(.pathAndQuery, .startsWith, "/api/", caseSensitive: true), row(.scheme, .equals, "https")]
        for mode in ConditionGroup.Mode.allCases {
            #expect(
                rowsRule(rows, mode: mode).simple
                    == SimpleRule(
                        matcher: RuleMatcher(scheme: "https", path: .prefix("/api/")),
                        action: .rewriteStatus(plainStatus), mode: mode),
                "\(mode)")
        }
        // No rows: every session, whatever the mode.
        #expect(
            rowsRule([], mode: .none).simple
                == SimpleRule(matcher: RuleMatcher(), action: .rewriteStatus(plainStatus), mode: .none))
    }

    @Test func simpleIsNilForMultiActionExtraRowsOccurrenceAndUserFinal() {
        let base = migrated(RuleMatcher(scheme: "https", path: .prefix("/api/")))
        #expect(base.simple != nil)

        var twoActions = base
        twoActions.actions.append(RuleAction(.breakpoint(direction: .response, mode: .headers)))
        #expect(twoActions.simple == nil)

        var noActions = base
        noActions.actions = []
        #expect(noActions.simple == nil)

        var ticked = base
        ticked.actions[0].isFinal = true
        #expect(ticked.simple == nil)

        var occurrence = base
        occurrence.conditions.occurrence = .times(1...2)
        #expect(occurrence.simple == nil)

        // A second row for a fixed field the matcher can only hold once.
        var twoHosts = base
        twoHosts.conditions.rows += [row(.host, .hostPattern, "a.test"), row(.host, .hostPattern, "b.test")]
        #expect(twoHosts.simple == nil)
        var twoSchemes = base
        twoSchemes.conditions.rows.append(row(.scheme, .equals, "http"))
        #expect(twoSchemes.simple == nil)

        // Rows with no old matcher: an operator the field does not take, an unreadable value. They go
        // onto a rule with no rows, so a clash with another row of the same field cannot be the cause.
        let bare = migrated(RuleMatcher())
        #expect(bare.simple != nil)
        for unreadable in [
            row(.method, .startsWith, "P", caseSensitive: true),
            row(.method, .equals, "POST", caseSensitive: false),
            row(.port, .equals, "http"),
            row(.statusCode, .inRange, "500-400"),
            row(.statusCode, .equals, "404"),
            row(.pathAndQuery, .equals, "/a", caseSensitive: false),
            row(.host, .equals, "a.test"),
        ] {
            var odd = bare
            odd.conditions.rows.append(unreadable)
            #expect(odd.simple == nil, "\(unreadable)")
        }

        // An all-sessions row is not one of the six fixed fields; reading it as nothing would change
        // what a group in any / none mode matches.
        var everything = base
        everything.conditions.rows.append(row(.allSessions, .equals, ""))
        #expect(everything.simple == nil)
    }

    @Test func simpleIsNilWhenDirectoryPrefixDiffersFromThePathRow() {
        let action = RuleAction(.returnDirectory(directory, pathPrefix: "/files/"))
        func rule(_ rows: [ConditionRow]) -> Rule { rowsRule(rows, actions: [action]) }

        let same = rule([row(.pathAndQuery, .startsWith, "/files/", caseSensitive: true)])
        #expect(
            same.simple
                == SimpleRule(
                    matcher: RuleMatcher(path: .prefix("/files/")), action: .mapLocalDirectory(directory), mode: .all))

        #expect(rule([row(.pathAndQuery, .startsWith, "/other/", caseSensitive: true)]).simple == nil)
        #expect(rule([row(.pathAndQuery, .startsWith, "/files/x/", caseSensitive: true)]).simple == nil)
        #expect(rule([row(.pathAndQuery, .equals, "/files/", caseSensitive: true)]).simple == nil)
        #expect(rule([row(.pathAndQuery, .wildcard, "/files/*", caseSensitive: true)]).simple == nil)
        // The path row is missing: the old editor has no place for a prefix on its own.
        #expect(rule([row(.host, .hostPattern, "a.test")]).simple == nil)
        #expect(rule([]).simple == nil)

        // A legacy directory rule whose path is not a prefix (it never passed validation) is not
        // editable either.
        let broken = Rule(
            migrating: legacy(matcher: RuleMatcher(path: .exact("/files/")), action: .mapLocalDirectory(directory)))
        #expect(broken.simple == nil)
    }

    // MARK: Validation

    private static let validMatchers: [RuleMatcher] =
        roundTripMatchers + [
            RuleMatcher(hostPattern: "0:0:0:0:0:0:0:1"),
            RuleMatcher(scheme: "HTTPS", port: 1),
            RuleMatcher(port: 65_535, statusRange: 100...599),
        ]

    @Test func migratedRulesValidateLikeTheLegacyRules() {
        var validChecked = 0
        for action in sevenActions {
            for matcher in Self.validMatchers {
                var matcher = matcher
                if case .mapLocalDirectory = action { matcher.path = .prefix("/files/") }
                if action.direction == .request { matcher.statusRange = nil }
                let old = legacy(matcher: matcher, action: action)
                #expect(thrown { try old.validate() } == nil, "legacy \(action) \(matcher)")
                #expect(thrown { try Rule(migrating: old).validate() } == nil, "\(action) \(matcher)")
                validChecked += 1
            }
        }
        #expect(validChecked > 0)

        let longValue = String(repeating: "a", count: RulesLimits().fieldBytes + 1)
        let badDirectory = MapLocalDirectoryAction(bookmark: Data(), displayName: "d")
        let invalid: [LegacyRule] = [
            legacy(name: longValue),
            legacy(matcher: RuleMatcher(scheme: "ftp")),
            legacy(matcher: RuleMatcher(hostPattern: "a b")),
            legacy(matcher: RuleMatcher(hostPattern: "*.*.a.test")),
            legacy(matcher: RuleMatcher(hostPattern: "a/b", hostSyntax: .wildcard)),
            legacy(matcher: RuleMatcher(hostPattern: "(", hostSyntax: .regex)),
            legacy(matcher: RuleMatcher(hostPattern: "(a+)+", hostSyntax: .regex)),
            legacy(matcher: RuleMatcher(hostPattern: longValue)),
            legacy(matcher: RuleMatcher(port: 0)),
            legacy(matcher: RuleMatcher(port: 65_536)),
            legacy(matcher: RuleMatcher(port: -1)),
            legacy(matcher: RuleMatcher(method: "G ET")),
            legacy(matcher: RuleMatcher(path: .exact("/a#b"))),
            legacy(matcher: RuleMatcher(path: .prefix("/a b"))),
            legacy(matcher: RuleMatcher(path: .wildcard(#"/a\x"#))),
            legacy(matcher: RuleMatcher(path: .regex("[a-"))),
            legacy(matcher: RuleMatcher(path: .regex("(a+)+"))),
            legacy(matcher: RuleMatcher(path: .exact(longValue))),
            legacy(matcher: RuleMatcher(statusRange: 50...60)),
            legacy(matcher: RuleMatcher(statusRange: 100...700)),
            legacy(matcher: RuleMatcher(statusRange: -5...200)),
            legacy(action: .mapLocal(MapLocalAction(assetID: id(900), status: 100, headers: []))),
            legacy(
                action: .mapRemote(
                    MapRemoteAction(targetScheme: "ftp", targetHost: "b.test", targetPort: 443, path: .preserve))),
            legacy(
                action: .mapRemote(
                    MapRemoteAction(targetScheme: "https", targetHost: "b c", targetPort: 443, path: .preserve))),
            legacy(
                action: .mapRemote(
                    MapRemoteAction(targetScheme: "https", targetHost: "b.test", targetPort: 0, path: .preserve))),
            legacy(
                action: .mapRemote(
                    MapRemoteAction(targetScheme: "https", targetHost: "b.test", targetPort: 443, path: .replace("x")))),
            legacy(
                action: .editHeaders(
                    direction: .response,
                    operations: [.set(name: "X-A", value: "1"), .set(name: "Bad Name", value: "1")])),
            legacy(action: .rewriteBody(direction: .response, BodyRewriteAction(find: "", replacement: "x"))),
            legacy(
                action: .rewriteBody(
                    direction: .response, BodyRewriteAction(find: "(", replacement: "x", syntax: .regex))),
            legacy(action: .rewriteStatus(RewriteStatusAction(status: 100))),
            legacy(matcher: RuleMatcher(path: .prefix("/files/")), action: .mapLocalDirectory(badDirectory)),
            legacy(matcher: RuleMatcher(path: .exact("/files/")), action: .mapLocalDirectory(directory)),
            legacy(matcher: RuleMatcher(path: .prefix("/files")), action: .mapLocalDirectory(directory)),
            legacy(matcher: RuleMatcher(path: .prefix("files/")), action: .mapLocalDirectory(directory)),
            legacy(matcher: RuleMatcher(), action: .mapLocalDirectory(directory)),
            // Both a matcher problem and an action problem: the matcher is reported, as before.
            legacy(
                matcher: RuleMatcher(port: 0),
                action: .rewriteStatus(RewriteStatusAction(status: 100))),
            // A status range on a request-side rule.
            legacy(matcher: RuleMatcher(statusRange: 400...499), action: .mapRemote(remote)),
            legacy(matcher: RuleMatcher(statusRange: 400...499), action: .mapLocal(file)),
            legacy(matcher: RuleMatcher(statusRange: 400...499), action: headerEdits),
            legacy(
                matcher: RuleMatcher(statusRange: 400...499), action: .breakpoint(direction: .request, mode: .headers)),
            legacy(
                matcher: RuleMatcher(statusRange: 400...499),
                action: .rewriteBody(direction: .request, BodyRewriteAction(find: "a", replacement: "b"))),
            // The action's own problem is reported before the judgment point.
            legacy(
                matcher: RuleMatcher(statusRange: 400...499),
                action: .mapRemote(
                    MapRemoteAction(targetScheme: "ftp", targetHost: "b", targetPort: 1, path: .preserve))),
        ]
        var statusRangeCases = 0
        for old in invalid {
            let expected = thrown { try old.validate() }
            let actual = thrown { try Rule(migrating: old).validate() }
            guard let expected else {
                Issue.record("legacy rule unexpectedly valid: \(old)")
                continue
            }
            if expected.code == .statusRangeNotAllowed {
                // The one intended difference: the old rule refused a request-side action under a status range;
                // the new rule saves it (spec R8F2-6) and the editor warns.
                #expect(actual == nil, "\(old.action)")
                statusRangeCases += 1
            } else {
                #expect(actual == expected, "\(old)")
            }
        }
        #expect(statusRangeCases == 5)
    }

    // MARK: Evaluation

    private static let gridMatchers: [RuleMatcher] = [
        RuleMatcher(),
        RuleMatcher(scheme: "https"),
        RuleMatcher(scheme: "HTTP"),
        RuleMatcher(hostPattern: "api.example.com"),
        RuleMatcher(hostPattern: "API.Example.COM."),
        RuleMatcher(hostPattern: "*.example.com"),
        RuleMatcher(hostPattern: "*"),
        RuleMatcher(hostPattern: "[::1]"),
        RuleMatcher(hostPattern: "0:0:0:0:0:0:0:1"),
        RuleMatcher(hostPattern: "::1"),
        RuleMatcher(hostPattern: "*.example.com", hostSyntax: .wildcard),
        RuleMatcher(hostPattern: "api.*.com", hostSyntax: .wildcard),
        RuleMatcher(hostPattern: "0:0:0:0:0:0:0:1", hostSyntax: .wildcard),
        RuleMatcher(hostPattern: #"(api|www)\.example\.com"#, hostSyntax: .regex),
        RuleMatcher(hostPattern: #"API\.EXAMPLE\.COM"#, hostSyntax: .regex),
        RuleMatcher(hostPattern: "[0-9a-f:]+", hostSyntax: .regex),
        RuleMatcher(port: 443),
        RuleMatcher(port: 8080),
        RuleMatcher(method: "GET"),
        RuleMatcher(method: "get"),
        RuleMatcher(path: .exact("/v1/items?a=1")),
        RuleMatcher(path: .exact("/v1/items")),
        RuleMatcher(path: .prefix("/v1/")),
        RuleMatcher(path: .prefix("/files/")),
        RuleMatcher(path: .wildcard("/v1/*")),
        RuleMatcher(path: .wildcard("/v1/items?a=?")),
        RuleMatcher(path: .regex(#"/v[0-9]+/items\?a=1"#)),
        RuleMatcher(path: .regex("/V1/.*")),
        RuleMatcher(statusRange: 400...499),
        RuleMatcher(statusRange: 200...299),
        RuleMatcher(statusRange: 200...200),
        RuleMatcher(scheme: "https", hostPattern: "*.example.com", port: 443, method: "GET", path: .prefix("/v1/")),
        RuleMatcher(
            scheme: "https", hostPattern: "api.example.com", port: 443, method: "GET",
            path: .regex(#"/v[0-9]+/items.*"#), statusRange: 200...299),
        RuleMatcher(scheme: "http", hostPattern: "[::1]", port: 8080, method: "POST", statusRange: 400...499),
    ]

    private static let gridTargets: [HTTPMessageTarget] = [
        HTTPMessageTarget(
            scheme: "https", host: "api.example.com", port: 443, method: "GET", pathAndQuery: "/v1/items?a=1"),
        HTTPMessageTarget(scheme: "https", host: "example.com", port: 443, method: "GET", pathAndQuery: "/"),
        HTTPMessageTarget(
            scheme: "HTTPS", host: "API.EXAMPLE.COM.", port: 443, method: "GET", pathAndQuery: "/v1/items"),
        HTTPMessageTarget(
            scheme: "http", host: "www.example.com", port: 8080, method: "POST", pathAndQuery: "/files/a.txt"),
        HTTPMessageTarget(scheme: "http", host: "::1", port: 8080, method: "POST", pathAndQuery: "/V1/x"),
        HTTPMessageTarget(scheme: "http", host: "[::1]", port: 8080, method: "GET", pathAndQuery: "/v1/items?a=2"),
        HTTPMessageTarget(
            scheme: "https", host: "0:0:0:0:0:0:0:1", port: 443, method: "get", pathAndQuery: "/v2/items?a=1"),
        HTTPMessageTarget(scheme: "https", host: "localhost", port: 8443, method: "DELETE", pathAndQuery: ""),
    ]

    @Test func conditionsEvaluateLikeTheLegacyMatcher() {
        #expect(Self.gridMatchers.count >= 25)
        #expect(Self.gridTargets.count >= 6)
        // A clock that never advances: no pattern can run out of time, so every answer is matched / noMatch.
        let cache = PatternCache(budget: RegexBudget(clock: { .zero }))
        var checked = 0
        var matched = 0
        for matcher in Self.gridMatchers {
            let rule = migrated(matcher)
            for target in Self.gridTargets {
                for status in [nil, 200, 404] as [Int?] {
                    let expected = matcher.evaluate(target, status: status, cache: cache)
                    let actual = rule.conditions.evaluate(target, status: status, cache: cache)
                    #expect(actual == expected, "\(matcher) \(target.url) \(String(describing: status))")
                    checked += 1
                    if expected == .matched { matched += 1 }
                }
            }
        }
        #expect(checked == Self.gridMatchers.count * Self.gridTargets.count * 3)
        // The grid is not vacuous: it contains both kinds of answer, plenty of each.
        #expect(matched > 40)
        #expect(checked - matched > 40)
    }

    // MARK: Annotation rules

    private var redMark: ActionKind { .mark(MarkAction(background: "#FF3B30", text: "slow")) }

    @Test func annotationRuleIsSimpleAnnotationNotSimple() {
        let matcher = RuleMatcher(hostPattern: "a.test")
        let rule = Rule(id: id(1), name: "r", enabled: true, order: 0, matcher: matcher, annotation: redMark)
        #expect(rule.simple == nil)
        let expected = SimpleAnnotationRule(matcher: matcher, kind: redMark, mode: .all)
        #expect(rule.simpleAnnotation == expected)
        #expect(rule.oldEditorForm == .annotation(expected))
        for kind in [ActionKind.comment(CommentAction(text: "x")), .hide] {
            let other = Rule(id: id(1), name: "r", enabled: true, order: 0, matcher: matcher, annotation: kind)
            #expect(other.simpleAnnotation?.kind == kind)
        }
    }

    @Test func twoActionsFinalTickOrOccurrenceMakeItNotSimple() {
        let base = Rule(id: id(1), name: "r", enabled: true, order: 0, matcher: RuleMatcher(), annotation: redMark)
        var two = base
        two.actions.append(RuleAction(.hide))
        #expect(two.simpleAnnotation == nil)
        #expect(two.oldEditorForm == nil)
        var ticked = base
        ticked.actions[0].isFinal = true
        #expect(ticked.simpleAnnotation == nil)
        var occurrence = base
        occurrence.conditions.occurrence = .times(2...3)
        #expect(occurrence.simpleAnnotation == nil)
        var twoRows = base
        twoRows.conditions.rows = [
            ConditionRow(field: .host, op: .hostPattern, value: "a.test"),
            ConditionRow(field: .host, op: .hostPattern, value: "b.test"),
        ]
        #expect(twoRows.simpleAnnotation == nil)
    }

    @Test func legacyRuleIsNeverSimpleAnnotation() {
        let rule = Rule(
            id: id(1), name: "r", enabled: true, order: 0, matcher: RuleMatcher(), action: .mapRemote(remote))
        #expect(rule.simpleAnnotation == nil)
        #expect(rule.oldEditorForm == .legacy(rule.simple!))
    }

    @Test func annotationInitBuildsTheRowsMigrationBuilds() {
        let matcher = RuleMatcher(
            scheme: "https", hostPattern: "*.a.test", method: "GET", path: .prefix("/api/"), hostSyntax: .wildcard)
        let annotated = Rule(id: id(1), name: "r", enabled: true, order: 3, matcher: matcher, annotation: .hide)
        let legacyBuilt = Rule(id: id(1), name: "r", enabled: true, order: 3, matcher: matcher, action: statusRewrite)
        #expect(annotated.conditions == legacyBuilt.conditions)
        #expect(annotated.order == 3)
        #expect(annotated.actions == [RuleAction(.hide)])
    }
}
