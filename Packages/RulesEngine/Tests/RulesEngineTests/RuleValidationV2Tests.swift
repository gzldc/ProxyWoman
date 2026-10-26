import FlowStore
import Foundation
import Testing

@testable import RulesEngine

private func id(_ n: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!
}

// One valid action of each kind; direction is what the tests vary.
private let returnFile = RuleAction(.returnFile(MapLocalAction(assetID: id(900), status: 200, headers: [])))
private func returnDirectory(_ prefix: String) -> RuleAction {
    RuleAction(
        .returnDirectory(MapLocalDirectoryAction(bookmark: Data([1]), displayName: "dir"), pathPrefix: prefix))
}
private let mapRemote = RuleAction(
    .mapRemote(MapRemoteAction(targetScheme: "https", targetHost: "b.test", targetPort: 443, path: .preserve)))
private func editHeaders(_ direction: HTTPMessageDirection) -> RuleAction {
    RuleAction(.editHeaders(direction: direction, operations: [.set(name: "X-A", value: "1")]))
}
private func breakpoint(_ direction: HTTPMessageDirection) -> RuleAction {
    RuleAction(.breakpoint(direction: direction, mode: .headers))
}
private func rewriteBody(_ direction: HTTPMessageDirection) -> RuleAction {
    RuleAction(.rewriteBody(direction: direction, BodyRewriteAction(find: "a", replacement: "b")))
}
private let rewriteStatus = RuleAction(.rewriteStatus(RewriteStatusAction(status: 500)))

private func scheme(_ value: String) -> ConditionRow { ConditionRow(field: .scheme, op: .equals, value: value) }
private func method(_ value: String) -> ConditionRow {
    ConditionRow(field: .method, op: .equals, value: value, caseSensitive: true)
}
private func path(_ value: String, _ op: ConditionOperator = .equals) -> ConditionRow {
    ConditionRow(field: .pathAndQuery, op: op, value: value, caseSensitive: true)
}
private func host(_ value: String, _ op: ConditionOperator = .hostPattern) -> ConditionRow {
    ConditionRow(field: .host, op: op, value: value)
}
private func port(_ value: String) -> ConditionRow { ConditionRow(field: .port, op: .equals, value: value) }
private func status(_ value: String) -> ConditionRow { ConditionRow(field: .statusCode, op: .inRange, value: value) }

private func rule(
    _ rows: [ConditionRow] = [], mode: ConditionGroup.Mode = .all, actions: [RuleAction] = [rewriteStatus],
    name: String = "r"
) -> Rule {
    Rule(name: name, conditions: ConditionGroup(mode: mode, rows: rows), actions: actions)
}

/// The thrown validation error, or nil when the rule is valid.
private func failure(_ rule: Rule, limits: RulesLimits = RulesLimits()) -> RuleValidationError? {
    do {
        try rule.validate(limits: limits)
        return nil
    } catch let error as RuleValidationError {
        return error
    } catch {
        Issue.record("unexpected error \(error)")
        return nil
    }
}

private func structureFailure(
    _ snapshot: RuleSnapshot, limits: RulesLimits = RulesLimits(), enforcingRuleCount: Bool = true
) -> RuleValidationError? {
    do {
        try snapshot.validateStructure(limits: limits, enforcingRuleCount: enforcingRuleCount)
        return nil
    } catch let error as RuleValidationError {
        return error
    } catch {
        Issue.record("unexpected error \(error)")
        return nil
    }
}

private func group(_ n: Int, parent: Int? = nil) -> RuleGroup {
    RuleGroup(id: id(n), name: "g\(n)", parentID: parent.map(id))
}

private func listed(_ n: Int, in groupNumber: Int? = nil) -> Rule {
    Rule(id: id(n), name: "r\(n)", groupID: groupNumber.map(id), actions: [rewriteStatus])
}

@Suite("RuleValidationV2")
struct RuleValidationV2Tests {
    // MARK: Rows

    @Test func aWellFormedRulePasses() {
        let rows = [scheme("https"), host("*.a.test"), method("GET"), path("/api/", .startsWith)]
        #expect(failure(rule(rows)) == nil)
        #expect(failure(rule([])) == nil)
        #expect(failure(rule([ConditionRow(field: .allSessions, op: .equals)])) == nil)
        #expect(failure(rule([ConditionRow(field: .port, op: .equals, value: "8443")])) == nil)
    }

    @Test func rowOperatorMustSuitField() {
        // Old-style operators the old matcher cannot read keep the old field.
        let legacy: [(ConditionRow, RuleValidationError.Field)] = [
            (ConditionRow(field: .scheme, op: .regexWhole, value: "https"), .scheme),
            (ConditionRow(field: .host, op: .hostPattern, value: "a.test", caseSensitive: true), .hostPattern),
        ]
        for (row, field) in legacy {
            #expect(failure(rule([row])) == RuleValidationError(code: .invalidOperator, field: field), "\(row)")
        }
        // Comparisons that do not suit a field are reported on the row (R3).
        let current: [ConditionRow] = [
            ConditionRow(field: .pathAndQuery, op: .inRange, value: "1-2", caseSensitive: true),
            ConditionRow(field: .port, op: .startsWith, value: "44"),
            ConditionRow(field: .scheme, op: .contains, value: "http"),
        ]
        for row in current {
            #expect(
                failure(rule([row])) == RuleValidationError(code: .invalidOperator, field: .conditionRow(index: 0)),
                "\(row)")
        }
    }

    @Test func combinationsR1RefusedAreNewPathRowsInR3() {
        let rows: [ConditionRow] = [
            ConditionRow(field: .method, op: .startsWith, value: "G", caseSensitive: true),
            ConditionRow(field: .method, op: .equals, value: "GET", caseSensitive: false),
            ConditionRow(field: .pathAndQuery, op: .equals, value: "/a", caseSensitive: false),
            ConditionRow(field: .scheme, op: .equals, value: "https", caseSensitive: true),
            ConditionRow(field: .host, op: .equals, value: "a.test"),
            ConditionRow(field: .statusCode, op: .equals, value: "404"),
        ]
        for row in rows { #expect(failure(rule([row])) == nil, "\(row)") }
    }

    @Test func aBadRowIsReportedEvenBesideGoodRows() {
        let rows = [scheme("https"), ConditionRow(field: .port, op: .startsWith, value: "44")]
        #expect(failure(rule(rows)) == RuleValidationError(code: .invalidOperator, field: .conditionRow(index: 1)))
    }

    @Test func invalidPortAndStatusValuesUseTheLegacyCodes() {
        for value in ["abc", "", "0", "65536", "70000", "-1"] {
            #expect(
                failure(rule([ConditionRow(field: .port, op: .equals, value: value)]))
                    == RuleValidationError(code: .invalidPort, field: .port), "port \(value)")
        }
        for value in ["abc", "", "404", "500-400", "50-60", "100-700", "99-100", "0-0", "400-"] {
            #expect(
                failure(rule([status(value)]))
                    == RuleValidationError(code: .invalidStatusRange, field: .statusRange), "status \(value)")
        }
        #expect(failure(rule([status("100-599")], actions: [rewriteStatus])) == nil)
        #expect(failure(rule([ConditionRow(field: .port, op: .equals, value: "65535")])) == nil)
        #expect(failure(rule([ConditionRow(field: .port, op: .equals, value: "1")])) == nil)
    }

    @Test func rowValuesReuseTheLegacyCodes() {
        let cases: [(ConditionRow, RuleValidationError)] = [
            (scheme("ftp"), RuleValidationError(code: .invalidScheme, field: .scheme)),
            (host("a b"), RuleValidationError(code: .invalidHostPattern, field: .hostPattern)),
            (host("a/b", .wildcard), RuleValidationError(code: .invalidWildcard, field: .hostPattern)),
            (method("G ET"), RuleValidationError(code: .invalidMethod, field: .method)),
            (path("/a#b"), RuleValidationError(code: .invalidPath, field: .path)),
            (path("/a b", .startsWith), RuleValidationError(code: .invalidPath, field: .path)),
            (path(#"/a\x"#, .wildcard), RuleValidationError(code: .invalidWildcard, field: .path)),
            (
                path(String(repeating: "a", count: RulesLimits().fieldBytes + 1)),
                RuleValidationError(code: .fieldTooLong, field: .path)
            ),
        ]
        for (row, expected) in cases {
            #expect(failure(rule([row])) == expected, "\(row)")
        }
    }

    @Test func invalidRegexRowReportsTheSameCodeAsTheLegacyMatcher() {
        let cases: [(ConditionRow, RuleMatcher)] = [
            (host("(", .regexWhole), RuleMatcher(hostPattern: "(", hostSyntax: .regex)),
            (host("(a+)+", .regexWhole), RuleMatcher(hostPattern: "(a+)+", hostSyntax: .regex)),
            (path("[a-", .regexWhole), RuleMatcher(path: .regex("[a-"))),
            (path("(a+)+", .regexWhole), RuleMatcher(path: .regex("(a+)+"))),
        ]
        for (row, matcher) in cases {
            var legacy: RuleValidationError?
            do { try matcher.validate() } catch let error as RuleValidationError { legacy = error } catch {}
            #expect(legacy != nil)
            #expect(failure(rule([row])) == legacy, "\(row)")
        }
        #expect(failure(rule([host("(", .regexWhole)]))?.code == .invalidRegex)
        #expect(failure(rule([path("(a+)+", .regexWhole)]))?.code == .regexTooComplex)
        #expect(failure(rule([path(#"/v[0-9]+/.*"#, .regexWhole)])) == nil)
    }

    @Test func tooManyRows() {
        let limits = RulesLimits(ruleConditionRows: 2)
        let rows = [scheme("https"), method("GET"), path("/")]
        #expect(
            failure(rule(rows), limits: limits) == RuleValidationError(code: .tooManyConditions, field: .conditions))
        #expect(failure(rule(Array(rows.prefix(2))), limits: limits) == nil)
        // The default limit is 32 rows.
        let many = Array(repeating: scheme("https"), count: 33)
        #expect(failure(rule(many))?.code == .tooManyConditions)
        #expect(failure(rule(Array(many.prefix(32)))) == nil)
    }

    // MARK: Actions

    @Test func noActions() {
        #expect(
            failure(rule(actions: [])) == RuleValidationError(code: .noActions, field: .action(index: 0)))
    }

    @Test func tooManyActions() {
        let limits = RulesLimits(ruleActions: 2)
        let three = [rewriteStatus, editHeaders(.response), breakpoint(.response)]
        #expect(
            failure(rule(actions: three), limits: limits)
                == RuleValidationError(code: .tooManyActions, field: .action(index: 2)))
        #expect(failure(rule(actions: Array(three.prefix(2))), limits: limits) == nil)
        let many = Array(repeating: editHeaders(.response), count: 17)
        #expect(failure(rule(actions: many))?.code == .tooManyActions)
        #expect(failure(rule(actions: Array(many.prefix(16)))) == nil)
    }

    @Test func actionPayloadsReuseTheLegacyChecks() {
        let badStatus = RuleAction(.returnFile(MapLocalAction(assetID: id(900), status: 100, headers: [])))
        #expect(failure(rule(actions: [badStatus])) == RuleValidationError(code: .invalidStatus, field: .mapStatus))
        let badTarget = RuleAction(
            .mapRemote(MapRemoteAction(targetScheme: "ftp", targetHost: "b.test", targetPort: 443, path: .preserve)))
        #expect(
            failure(rule(actions: [badTarget])) == RuleValidationError(code: .invalidTarget, field: .targetScheme))
        let badStatusRewrite = RuleAction(.rewriteStatus(RewriteStatusAction(status: 100)))
        #expect(
            failure(rule(actions: [badStatusRewrite]))
                == RuleValidationError(code: .invalidStatus, field: .rewriteStatus))
        let emptyFind = RuleAction(
            .rewriteBody(direction: .response, BodyRewriteAction(find: "", replacement: "x")))
        #expect(failure(rule(actions: [emptyFind])) == RuleValidationError(code: .emptyFind, field: .bodyFind))
        let badRegex = RuleAction(
            .rewriteBody(direction: .response, BodyRewriteAction(find: "(", replacement: "x", syntax: .regex)))
        #expect(failure(rule(actions: [badRegex])) == RuleValidationError(code: .invalidRegex, field: .bodyFind))
        let badHeader = RuleAction(
            .editHeaders(
                direction: .response, operations: [.set(name: "X-A", value: "1"), .set(name: "Bad Name", value: "1")]))
        let headerError = failure(rule(actions: [badHeader]))
        #expect(headerError?.code == .invalidHeaderEdit && headerError?.field == .headerEdit(index: 1))
        #expect(headerError?.mutation != nil)
        // The second action is checked too.
        #expect(
            failure(rule(actions: [rewriteStatus, badStatusRewrite]))
                == RuleValidationError(code: .invalidStatus, field: .rewriteStatus))
    }

    @Test func nameLengthUsesTheFieldLimit() {
        let limits = RulesLimits()
        #expect(failure(rule(name: String(repeating: "n", count: limits.fieldBytes))) == nil)
        #expect(
            failure(rule(name: String(repeating: "n", count: limits.fieldBytes + 1)))
                == RuleValidationError(code: .fieldTooLong, field: .name))
    }

    @Test func directoryPrefixMustBeSlashed() {
        for prefix in ["static", "/static", "static/", "", "x/"] {
            #expect(
                failure(rule(actions: [returnDirectory(prefix)]))
                    == RuleValidationError(code: .directoryNeedsPrefix, field: .path), "\(prefix)")
        }
        for prefix in ["/static/", "/", "/a/b/"] {
            #expect(failure(rule(actions: [returnDirectory(prefix)])) == nil, "\(prefix)")
        }
        // The rows are free: the prefix belongs to the action, not to a path row.
        #expect(failure(rule([host("a.test")], actions: [returnDirectory("/static/")])) == nil)
        // The directory itself is still checked.
        let noBookmark = RuleAction(
            .returnDirectory(MapLocalDirectoryAction(bookmark: Data(), displayName: "d"), pathPrefix: "/s/"))
        #expect(
            failure(rule(actions: [noBookmark])) == RuleValidationError(code: .invalidDirectory, field: .directory))
    }

    // MARK: Judgment points

    @Test func p2RuleWithRequestActionIsAccepted() {
        // Spec R8F2-6: such a rule saves (the editor warns); at run time the action only touches the recorded request.
        let requestSide = [
            mapRemote, returnFile, returnDirectory("/s/"), editHeaders(.request), breakpoint(.request),
            rewriteBody(.request),
        ]
        for action in requestSide {
            #expect(failure(rule([status("400-499")], actions: [action])) == nil, "\(action.kind)")
        }
        #expect(
            failure(
                rule([path("/a"), status("400-499")], actions: [rewriteStatus, editHeaders(.response), mapRemote]))
                == nil)
        #expect(failure(rule([scheme("https"), status("400-499")], mode: .any, actions: [mapRemote])) == nil)
        #expect(failure(rule([status("400-499")], mode: .none, actions: [breakpoint(.request)])) == nil)
    }

    @Test func p2RuleWithResponseActionsIsAccepted() {
        let actions = [editHeaders(.response), breakpoint(.response), rewriteBody(.response), rewriteStatus]
        #expect(failure(rule([status("400-499")], actions: actions)) == nil)
        #expect(failure(rule([scheme("https"), status("500-599")], actions: [rewriteStatus])) == nil)
    }

    @Test func p1RuleMayCarryBothDirections() {
        let actions = [editHeaders(.request), mapRemote, editHeaders(.response), breakpoint(.response), rewriteStatus]
        #expect(failure(rule([path("/api/", .startsWith)], actions: actions)) == nil)
        #expect(failure(rule([host("a.test")], actions: actions)) == nil)
        #expect(failure(rule([], actions: actions)) == nil)
    }

    @Test func aResponseJudgedRuleMayEndWithARequestAction() {
        #expect(failure(rule([status("200-299")], actions: [rewriteStatus, rewriteStatus, mapRemote])) == nil)
    }

    // MARK: Structure

    @Test func groupDepthLimitIsThree() {
        let three = RuleSnapshot(
            revision: 1, groups: [group(1), group(2, parent: 1), group(3, parent: 2)], rules: [])
        #expect(structureFailure(three) == nil)
        let four = RuleSnapshot(
            revision: 1, groups: [group(1), group(2, parent: 1), group(3, parent: 2), group(4, parent: 3)], rules: [])
        #expect(structureFailure(four) == RuleValidationError(code: .groupTooDeep, field: .group))
        // The order in the array does not matter.
        let reversed = RuleSnapshot(
            revision: 1, groups: [group(4, parent: 3), group(3, parent: 2), group(2, parent: 1), group(1)], rules: [])
        #expect(structureFailure(reversed)?.code == .groupTooDeep)
        // The limit comes from the injected table.
        #expect(structureFailure(three, limits: RulesLimits(groupDepth: 2))?.code == .groupTooDeep)
        #expect(structureFailure(four, limits: RulesLimits(groupDepth: 4)) == nil)
        // A rule inside the deepest allowed group is fine.
        let withRule = RuleSnapshot(
            revision: 1, groups: [group(1), group(2, parent: 1), group(3, parent: 2)], rules: [listed(10, in: 3)])
        #expect(structureFailure(withRule) == nil)
    }

    @Test func unknownGroupParentIsRejected() {
        let snapshot = RuleSnapshot(revision: 1, groups: [group(1), group(2, parent: 99)], rules: [])
        #expect(structureFailure(snapshot) == RuleValidationError(code: .unknownGroup, field: .group))
    }

    @Test func aRuleInAMissingGroupIsRejected() {
        let snapshot = RuleSnapshot(
            revision: 1, groups: [group(1)], rules: [listed(10, in: 1), listed(11, in: 42)])
        #expect(structureFailure(snapshot) == RuleValidationError(code: .unknownGroup, field: .group))
        let rootOnly = RuleSnapshot(revision: 1, rules: [listed(10, in: 42)])
        #expect(structureFailure(rootOnly)?.code == .unknownGroup)
        #expect(
            structureFailure(RuleSnapshot(revision: 1, groups: [group(1)], rules: [listed(10, in: 1), listed(11)]))
                == nil)
    }

    @Test func groupCycleIsRejected() {
        let selfParent = RuleSnapshot(revision: 1, groups: [group(1, parent: 1)], rules: [])
        #expect(structureFailure(selfParent) == RuleValidationError(code: .groupCycle, field: .group))
        let pair = RuleSnapshot(revision: 1, groups: [group(1, parent: 2), group(2, parent: 1)], rules: [])
        #expect(structureFailure(pair) == RuleValidationError(code: .groupCycle, field: .group))
        // A cycle reached from a group that hangs below it, and one that is longer than the depth limit.
        let below = RuleSnapshot(
            revision: 1, groups: [group(3, parent: 1), group(1, parent: 2), group(2, parent: 1)], rules: [])
        #expect(structureFailure(below)?.code == .groupCycle)
        let ring = RuleSnapshot(
            revision: 1,
            groups: [
                group(1, parent: 5), group(2, parent: 1), group(3, parent: 2), group(4, parent: 3), group(5, parent: 4),
            ],
            rules: [])
        #expect(structureFailure(ring)?.code == .groupCycle)
    }

    @Test func duplicateIDsAreRejected() {
        let twoRules = RuleSnapshot(revision: 1, rules: [listed(10), listed(10)])
        #expect(structureFailure(twoRules) == RuleValidationError(code: .duplicateID, field: .group))
        let twoGroups = RuleSnapshot(revision: 1, groups: [group(1), group(1)], rules: [])
        #expect(structureFailure(twoGroups) == RuleValidationError(code: .duplicateID, field: .group))
        // A group id repeated deeper in the tree, where a walk from the root would enter it once.
        let nested = RuleSnapshot(
            revision: 1, groups: [group(1), group(2, parent: 1), group(2, parent: 1)], rules: [])
        #expect(structureFailure(nested)?.code == .duplicateID)
        // A rule and a group may share a number: they are different kinds of thing.
        let mixed = RuleSnapshot(revision: 1, groups: [group(1)], rules: [listed(1)])
        #expect(structureFailure(mixed) == nil)
    }

    @Test func ruleCountLimitUsesInjectedLimits() {
        let three = RuleSnapshot(revision: 1, rules: [listed(1), listed(2), listed(3)])
        #expect(
            structureFailure(three, limits: RulesLimits(ruleCount: 2))
                == RuleValidationError(code: .tooManyRules, field: .group))
        #expect(structureFailure(three, limits: RulesLimits(ruleCount: 3)) == nil)
        #expect(structureFailure(RuleSnapshot(revision: 1, rules: [])) == nil)
        // The default is 500.
        let big = RuleSnapshot(revision: 1, rules: (1...501).map { listed($0) })
        #expect(structureFailure(big)?.code == .tooManyRules)
        #expect(structureFailure(RuleSnapshot(revision: 1, rules: (1...500).map { listed($0) })) == nil)
    }

    @Test func ruleCountCanBeSkippedForLoading() {
        let three = RuleSnapshot(revision: 1, rules: [listed(1), listed(2), listed(3)])
        #expect(structureFailure(three, limits: RulesLimits(ruleCount: 2), enforcingRuleCount: false) == nil)
        // Skipping the count does not skip the rest.
        let broken = RuleSnapshot(revision: 1, rules: [listed(1), listed(1), listed(3)])
        #expect(
            structureFailure(broken, limits: RulesLimits(ruleCount: 2), enforcingRuleCount: false)?.code == .duplicateID
        )
    }

    @Test func aVeryLongGroupChainEndsInOneError() {
        // Every group is looked at once, however long the chain above it.
        let groups = (1...2_000).map { group($0, parent: $0 == 1 ? nil : $0 - 1) }
        #expect(structureFailure(RuleSnapshot(revision: 1, groups: groups, rules: []))?.code == .groupTooDeep)
    }

    // MARK: Preparing patterns

    @Test func preparingCompilesRowAndBodyPatternsAndSwitchesThemBackOn() throws {
        let cache = PatternCache(
            budget: BodyTestClock().budget(maxDuration: .milliseconds(2)),
            bodyBudget: BodyTestClock().budget(maxDuration: .milliseconds(5)))
        let slowTarget = HTTPMessageTarget(
            scheme: "https", host: catastrophicInput, port: 443, method: "GET", pathAndQuery: "/api/x")
        let body = BodyRewriteAction(find: catastrophicFind, replacement: "x", syntax: .regex)
        let candidate = rule(
            [host(catastrophicFind, .regexWhole), path("/api/*", .wildcard), scheme("https")],
            actions: [RuleAction(.rewriteBody(direction: .response, body))])
        candidate.preparePatterns(in: cache)
        // The row's wildcard and regex are compiled; so is the body search.
        #expect(cache.count == 2)
        let compiled = try cache.bodyPattern(body)
        for _ in 0..<3 {
            #expect(compiled.replace(in: catastrophicInput, with: "x", scope: .all) == .timedOut)
            // The cheap rows match, so the regex row is reached and runs out of time.
            #expect(candidate.conditions.evaluate(slowTarget, status: nil, cache: cache) != .matched)
        }
        #expect(cache.isBodyPatternDisabled(body))
        #expect(cache.isRegexDisabled(catastrophicFind, caseInsensitive: true))
        // Publishing the rule again forgets the strikes of both.
        candidate.preparePatterns(in: cache)
        #expect(!cache.isBodyPatternDisabled(body))
        #expect(!cache.isRegexDisabled(catastrophicFind, caseInsensitive: true))
    }

    @Test func preparingSkipsPatternsThatCannotBeCompiled() {
        let cache = PatternCache()
        let broken = rule(
            [host("(", .regexWhole), path("[a-", .regexWhole), method("G"), port("x")],
            actions: [
                RuleAction(
                    .rewriteBody(direction: .response, BodyRewriteAction(find: "(", replacement: "x", syntax: .regex)))
            ])
        broken.preparePatterns(in: cache)
        #expect(cache.count == 0)
    }

    // MARK: Annotation actions

    private func mark(_ background: String = "#FF3B30", foreground: String? = nil, text: String? = nil) -> RuleAction {
        RuleAction(.mark(MarkAction(background: background, foreground: foreground, text: text)))
    }
    private func comment(_ mode: CommentAction.Mode, _ text: String = "", _ replacement: String = "") -> RuleAction {
        RuleAction(.comment(CommentAction(mode: mode, text: text, replacement: replacement)))
    }

    @Test func annotationActionsAreAllowedAtEveryJudgmentPoint() {
        for action in [mark(), comment(.append, "x"), RuleAction(.hide)] {
            #expect(failure(rule([status("404-404")], actions: [action])) == nil)
            #expect(failure(rule([host("a.test")], actions: [action])) == nil)
        }
        #expect(failure(rule([status("404-404")], actions: [mapRemote])) == nil)
    }

    @Test func markColourMustBeSixHexDigits() {
        #expect(
            failure(rule(actions: [mark("red")])) == RuleValidationError(code: .invalidMarkColor, field: .markColor))
        #expect(
            failure(rule(actions: [mark(foreground: "#12")]))
                == RuleValidationError(code: .invalidMarkColor, field: .markForeground))
        #expect(failure(rule(actions: [mark("ff3b30", foreground: "#ffffff")])) == nil)
    }

    @Test func markColourMayBeTheNoColourChoices() {
        // "unchanged" ("") and "default" are accepted for either colour; they never produce a mark on their own.
        for color in [MarkAction.unchangedColor, MarkAction.defaultColor] {
            #expect(failure(rule(actions: [mark(color, foreground: color)])) == nil)
            #expect(MarkAction(background: color, foreground: color).flowMark(ruleID: UUID(), ruleName: "r") == nil)
        }
        // A real background with a no-colour text keeps the mark and drops the text colour.
        let mark = MarkAction(background: "#ff3b30", foreground: MarkAction.defaultColor).flowMark(ruleID: UUID(), ruleName: "r")
        #expect(mark?.background == "#FF3B30")
        #expect(mark?.foreground == nil)
    }

    @Test func markTextLimitUsesInjectedLimits() {
        var limits = RulesLimits()
        limits.markTextBytes = 4
        #expect(failure(rule(actions: [mark(text: "abcd")]), limits: limits) == nil)
        #expect(
            failure(rule(actions: [mark(text: "abcde")]), limits: limits)
                == RuleValidationError(code: .markTextTooLong, field: .markText))
        #expect(
            failure(rule(actions: [mark(text: String(repeating: "x", count: 257))]))
                == RuleValidationError(code: .markTextTooLong, field: .markText))
        #expect(RulesLimits().markTextBytes == 256)
    }

    @Test func commentSetAndAppendNeedText() {
        for mode in [CommentAction.Mode.set, .append] {
            #expect(
                failure(rule(actions: [comment(mode)]))
                    == RuleValidationError(code: .emptyComment, field: .commentText))
            #expect(failure(rule(actions: [comment(mode, "x")])) == nil)
        }
    }

    @Test func commentFindNeedsText() {
        #expect(
            failure(rule(actions: [comment(.findReplace, "", "y")]))
                == RuleValidationError(code: .emptyCommentFind, field: .commentFind))
        #expect(failure(rule(actions: [comment(.findReplace, "x", "")])) == nil)
    }

    @Test func commentClearNeedsNothing() {
        #expect(failure(rule(actions: [comment(.clear)])) == nil)
        #expect(failure(rule(actions: [RuleAction(.hide)])) == nil)
    }

    @Test func commentTextAndReplacementHaveTheCap() {
        var limits = RulesLimits()
        limits.commentBytes = 4
        #expect(RulesLimits().commentBytes == 4096)
        #expect(failure(rule(actions: [comment(.append, "abcd")]), limits: limits) == nil)
        #expect(
            failure(rule(actions: [comment(.append, "abcde")]), limits: limits)
                == RuleValidationError(code: .commentTooLong, field: .commentText))
        #expect(
            failure(rule(actions: [comment(.findReplace, "a", "abcde")]), limits: limits)
                == RuleValidationError(code: .commentTooLong, field: .commentText))
        #expect(
            failure(rule(actions: [comment(.findReplace, "abcde", "a")]), limits: limits)
                == RuleValidationError(code: .commentTooLong, field: .commentFind))
    }

    @Test func ruleWithSixteenAnnotationActionsIsValid() {
        let actions = (0..<16).map { _ in mark() }
        #expect(failure(rule(actions: actions)) == nil)
        #expect(failure(rule(actions: actions + [mark()])) != nil)
    }
}

@Suite("Rules 2.0 R3 judgment point validation")
struct RuleValidationR3Tests {
    private func rule(_ rows: [ConditionRow], actions: [RuleAction]) -> Rule {
        Rule(name: "r", conditions: ConditionGroup(rows: rows), actions: actions)
    }

    @Test func ruleJudgedAtTheResponseAcceptsRequestActions() {
        let judged = [ConditionRow(field: .responseHeader, name: "X", op: .equals, value: "1")]
        #expect(failure(rule(judged, actions: [rewriteStatus, mapRemote])) == nil)
        #expect(failure(rule(judged, actions: [rewriteStatus])) == nil)
    }

    @Test func judgmentCheckUsesAtLeastResponse() {
        // A rule judged after completion gets the completion point's own, stricter check (task 5).
        let completed = [ConditionRow(field: .durationMs, op: .greaterThan, value: "10")]
        #expect(
            failure(rule(completed, actions: [mark, editHeaders(.request)]))
                == RuleValidationError(code: .actionNotAllowedAtCompletion, field: .action(index: 1)))
        #expect(
            failure(rule(completed, actions: [editHeaders(.request)]))
                == RuleValidationError(code: .actionNotAllowedAtCompletion, field: .action(index: 0)))
    }

    // MARK: the completion point

    private var completed: [ConditionRow] { [ConditionRow(field: .durationMs, op: .greaterThan, value: "1000")] }
    private var mark: RuleAction { RuleAction(.mark(MarkAction(background: "#FF3B30"))) }
    private var comment: RuleAction { RuleAction(.comment(CommentAction(mode: .append, text: "slow"))) }

    @Test func completionRuleRejectsTransportActions() {
        let transport: [RuleAction] = [
            returnFile, returnDirectory("/static/"), mapRemote, editHeaders(.request), editHeaders(.response),
            breakpoint(.request), breakpoint(.response), rewriteBody(.request), rewriteBody(.response), rewriteStatus,
        ]
        for action in transport {
            #expect(
                failure(rule(completed, actions: [action]))
                    == RuleValidationError(code: .actionNotAllowedAtCompletion, field: .action(index: 0)),
                "\(action.kind)")
            // The same action is fine on a rule judged earlier (control).
            let earlier = action.kind.direction == .request ? [method("GET")] : [status("200-299")]
            #expect(failure(rule(earlier, actions: [action])) == nil, "\(action.kind)")
        }
        for state in ["completed", "failed", "tunnel"] {
            let row = ConditionRow(field: .sessionState, op: .equals, value: state)
            #expect(failure(rule([row], actions: [rewriteStatus]))?.code == .actionNotAllowedAtCompletion)
        }
        let size = ConditionRow(field: .responseBodySize, op: .greaterThan, value: "100")
        #expect(failure(rule([size], actions: [rewriteStatus]))?.code == .actionNotAllowedAtCompletion)
    }

    @Test func completionRuleAllowsMarkCommentHide() {
        #expect(failure(rule(completed, actions: [mark])) == nil)
        #expect(failure(rule(completed, actions: [comment])) == nil)
        #expect(failure(rule(completed, actions: [RuleAction(.hide)])) == nil)
        #expect(failure(rule(completed, actions: [mark, comment, RuleAction(.hide)])) == nil)
        #expect(failure(rule(completed, actions: [RuleAction(.mark(MarkAction(background: "red")))]))?.code == .invalidMarkColor)
    }

    @Test func completionViolationPointsAtTheFirstOffendingAction() {
        #expect(
            failure(rule(completed, actions: [mark, comment, rewriteStatus, editHeaders(.request)]))
                == RuleValidationError(code: .actionNotAllowedAtCompletion, field: .action(index: 2)))
        #expect(
            failure(rule(completed, actions: [mark, editHeaders(.response), mapRemote]))
                == RuleValidationError(code: .actionNotAllowedAtCompletion, field: .action(index: 1)))
    }

    @Test func mixedP1AndP3RowsJudgeAtP3() {
        let rows = [
            ConditionRow(field: .requestHeader, name: "X-A", op: .equals, value: "1"),
            ConditionRow(field: .durationMs, op: .greaterThan, value: "1000"),
        ]
        #expect(ConditionGroup(rows: rows).judgmentPoint == .completion)
        #expect(
            failure(rule(rows, actions: [editHeaders(.request)]))
                == RuleValidationError(code: .actionNotAllowedAtCompletion, field: .action(index: 0)))
        #expect(failure(rule(rows, actions: [mark])) == nil)
        // Without the duration row the same rule is judged at the request and may edit headers.
        #expect(failure(rule(Array(rows.prefix(1)), actions: [editHeaders(.request)])) == nil)
    }
}

@Suite("Rules 2.0 R4 judgment point validation")
struct RuleValidationR4Tests {
    private func rule(_ rows: [ConditionRow], actions: [RuleAction]) -> Rule {
        Rule(name: "r", conditions: ConditionGroup(rows: rows), actions: actions)
    }

    private var responseRows: [ConditionRow] { [ConditionRow(field: .responseHeader, name: "X", op: .equals, value: "1")] }
    private var completedRows: [ConditionRow] { [ConditionRow(field: .durationMs, op: .greaterThan, value: "1000")] }
    private var newRequestActions: [RuleAction] {
        [
            RuleAction(.delay(milliseconds: 10)),
            RuleAction(.modifyURL(URLEditAction(mode: .set, replacement: "https://b.test/"))),
            RuleAction(.returnPreset(PresetResponse(preset: .notFound404))),
            RuleAction(.closeConnection(.reset)),
            RuleAction(.noDecrypt),
        ]
    }

    @Test func newRequestActionsAcceptedAtResponseJudgment() {
        for action in newRequestActions {
            // A connect-only action still needs conditions known at the CONNECT point.
            let expected: RuleValidationError? =
                action.kind == .noDecrypt ? RuleValidationError(code: .connectActionCondition, field: .conditions) : nil
            #expect(failure(rule(responseRows, actions: [rewriteStatus, action])) == expected, "\(action.kind)")
            #expect(failure(rule([method("GET")], actions: [action]))?.code != .actionNotAllowedAtJudgmentPoint)
        }
    }

    @Test func responseCookieEditAllowedAtResponseJudgment() {
        let response = RuleAction(.editCookies(direction: .response, operations: [.set(name: "a", value: "1")]))
        let request = RuleAction(.editCookies(direction: .request, operations: [.set(name: "a", value: "1")]))
        #expect(failure(rule(responseRows, actions: [response])) == nil)
        #expect(failure(rule(responseRows, actions: [request])) == nil)
    }

    @Test func completionJudgmentRejectsNewActions() {
        let cookie = RuleAction(.editCookies(direction: .response, operations: [.set(name: "a", value: "1")]))
        for action in newRequestActions + [cookie] {
            #expect(
                failure(rule(completedRows, actions: [action]))
                    == RuleValidationError(code: .actionNotAllowedAtCompletion, field: .action(index: 0)),
                "\(action.kind)")
        }
    }

    @Test func ruleActionLimitStillSixteen() {
        let delay = RuleAction(.delay(milliseconds: 1))
        #expect(failure(rule([], actions: Array(repeating: delay, count: 16))) == nil)
        #expect(
            failure(rule([], actions: Array(repeating: delay, count: 17)))
                == RuleValidationError(code: .tooManyActions, field: .action(index: 16)))
    }

    @Test func legacyActionsStillPassUnchanged() {
        let legacy = [
            returnFile, returnDirectory("/static/"), mapRemote, editHeaders(.request), editHeaders(.response),
            breakpoint(.request), rewriteBody(.response), rewriteStatus,
        ]
        for action in legacy {
            let rows = action.kind.direction == .response ? [status("200-299")] : [method("GET")]
            #expect(failure(rule(rows, actions: [action])) == nil, "\(action.kind)")
        }
        // The frozen old rule type validates exactly as before.
        let old = LegacyRule(
            id: id(1), name: "o", enabled: true, order: 0, matcher: RuleMatcher(), action: .rewriteStatus(RewriteStatusAction(status: 500)))
        #expect(throws: Never.self) { try old.validate() }
        let bad = LegacyRule(
            id: id(2), name: "o", enabled: true, order: 0, matcher: RuleMatcher(),
            action: .rewriteStatus(RewriteStatusAction(status: 99)))
        #expect(throws: RuleValidationError.self) { try bad.validate() }
    }
}
