import FlowStore
import Foundation
import Testing

@testable import RulesEngine

private func rule(_ rows: [ConditionRow] = [], _ actions: [RuleAction]) -> Rule {
    Rule(name: "r", conditions: ConditionGroup(rows: rows), actions: actions)
}

private func rule(_ actions: [RuleAction]) -> Rule { rule([], actions) }

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

private func code(_ action: ActionKind, limits: RulesLimits = RulesLimits()) -> RuleValidationError.Code? {
    failure(rule([RuleAction(action)]), limits: limits)?.code
}

private func url(_ mode: URLEditAction.Mode, find: String = "", replacement: String = "") -> ActionKind {
    .modifyURL(URLEditAction(mode: mode, find: find, replacement: replacement))
}

private func query(_ operations: [QueryEdit]) -> ActionKind { .modifyQuery(QueryEditAction(operations: operations)) }
private func cookies(_ operations: [CookieEdit], _ direction: HTTPMessageDirection = .request) -> ActionKind {
    .editCookies(direction: direction, operations: operations)
}

@Suite("R4 action validation")
struct ActionValidationV2Tests {
    // MARK: modify URL

    @Test func modifyURLSetNeedsAnAbsoluteURL() {
        #expect(code(url(.set, replacement: "https://b.test/x?y=1")) == nil)
        for bad in ["", "/x", "ftp://b.test/", "https://u@b.test/", "https://b.test/#f"] {
            #expect(code(url(.set, replacement: bad)) == .invalidURLEdit, "\(bad)")
        }
        #expect(failure(rule([RuleAction(url(.set, replacement: "x"))]))?.field == .action(index: 0))
    }

    @Test func modifyURLFindMustBeNonEmptyAndShort() {
        #expect(code(url(.findReplace, find: "a", replacement: "b")) == nil)
        #expect(code(url(.findReplace, find: "")) == .emptyEditFind)
        #expect(code(url(.regex, find: "")) == .emptyEditFind)
        let limits = RulesLimits()
        #expect(code(url(.findReplace, find: String(repeating: "a", count: limits.fieldBytes))) == nil)
        #expect(code(url(.findReplace, find: String(repeating: "a", count: limits.fieldBytes + 1))) == .findTooLong)
    }

    @Test func modifyURLRegexMustCompile() {
        #expect(code(url(.regex, find: "a(b)+", replacement: "$1")) == nil)
        #expect(code(url(.regex, find: "(")) == .invalidRegex)
        #expect(code(url(.regex, find: "(a+)+$")) == .regexTooComplex)
    }

    // MARK: modify query

    @Test func modifyQueryNeedsOperations() {
        #expect(code(query([])) == .invalidQueryEdit)
        #expect(code(query(Array(repeating: .remove(name: "a"), count: 64))) == nil)
        #expect(code(query(Array(repeating: .remove(name: "a"), count: 65))) == .invalidQueryEdit)
    }

    @Test func queryNamesAndValuesMustBeRawQuerySafe() {
        #expect(code(query([.set(name: "a", value: "1"), .add(name: "b%20c", value: "x=y?z"), .remove(name: "c")])) == nil)
        #expect(code(query([.set(name: "a", value: "")])) == nil)
        let bad: [QueryEdit] = [
            // An empty name is "all keys" for set and remove (R8F2); adding a parameter needs a name.
            .add(name: "", value: "1"), .addIfMissing(name: "", value: "1"),
            .set(name: "a b", value: "1"), .set(name: "a#", value: "1"), .set(name: "é", value: "1"),
            .set(name: "a&b", value: "1"), .add(name: "a=b", value: "1"), .remove(name: "a&b"),
            .set(name: "a", value: "1&b=2"), .add(name: "a", value: "x y"), .add(name: "a", value: "#"),
            .add(name: "a", value: "é"),
        ]
        for edit in bad { #expect(code(query([edit])) == .invalidQueryEdit, "\(edit)") }
    }

    @Test func queryFindReplace() {
        #expect(code(query([.findReplace(name: nil, find: "a b", replacement: "c", caseSensitive: true)])) == nil)
        #expect(code(query([.findReplace(name: "n", find: "a", replacement: "", caseSensitive: false)])) == nil)
        #expect(
            code(query([.findReplace(name: nil, find: "", replacement: "c", caseSensitive: true)])) == .emptyEditFind)
        #expect(
            code(query([.findReplace(name: "a&b", find: "a", replacement: "c", caseSensitive: true)]))
                == .invalidQueryEdit)
        #expect(
            code(query([.findReplace(name: nil, find: "a", replacement: "c&d", caseSensitive: true)]))
                == .invalidQueryEdit)
        #expect(
            code(query([.findReplace(name: nil, find: String(repeating: "a", count: 8193), replacement: "", caseSensitive: true)]))
                == .findTooLong)
    }

    // MARK: edit cookies

    @Test func cookieNeedsOperations() {
        #expect(code(cookies([])) == .invalidCookieEdit)
        #expect(code(cookies([.set(name: "sid", value: "abc"), .addIfMissing(name: "a", value: ""), .remove(name: "b")])) == nil)
        #expect(code(cookies([.set(name: "sid", value: "abc")], .response)) == nil)
    }

    @Test func cookieNameRejectsSemicolonAndEquals() {
        for name in ["a=b", "a;b", "a,b", "a b", "a\tb", "a\r", "a\nb", "a\u{0}", "a\u{7F}"] {
            #expect(code(cookies([.set(name: name, value: "v")])) == .invalidCookieEdit, "\(name.debugDescription)")
            #expect(code(cookies([.addIfMissing(name: name, value: "v")])) == .invalidCookieEdit)
            #expect(code(cookies([.remove(name: name)])) == .invalidCookieEdit)
        }
        // An empty name is "all keys" (R8F2), except where a name is needed.
        #expect(code(cookies([.set(name: "", value: "v")])) == nil)
        #expect(code(cookies([.remove(name: "")])) == nil)
        #expect(code(cookies([.addIfMissing(name: "", value: "v")])) == .invalidCookieEdit)
    }

    @Test func cookieValueRejectsSemicolonAndLineBreaks() {
        for value in ["a;b", "a\rb", "a\nb"] {
            for direction in [HTTPMessageDirection.request, .response] {
                #expect(code(cookies([.set(name: "a", value: value)], direction)) == .invalidCookieEdit)
            }
            #expect(code(cookies([.addIfMissing(name: "a", value: value)])) == .invalidCookieEdit)
        }
        #expect(code(cookies([.set(name: "a", value: "x=y\"z")])) == nil)
    }

    @Test func cookieFindReplaceAndRegex() {
        #expect(code(cookies([.findReplace(name: nil, find: "a", replacement: "b", caseSensitive: true)])) == nil)
        #expect(code(cookies([.findReplace(name: "s", find: "", replacement: "b", caseSensitive: true)])) == .emptyEditFind)
        #expect(
            code(cookies([.findReplace(name: "s;", find: "a", replacement: "b", caseSensitive: true)]))
                == .invalidCookieEdit)
        #expect(
            code(cookies([.findReplace(name: nil, find: "a", replacement: "b;c", caseSensitive: true)]))
                == .invalidCookieEdit)
        #expect(code(cookies([.regex(name: nil, pattern: "a+", replacement: "$0", caseSensitive: true)])) == nil)
        #expect(code(cookies([.regex(name: nil, pattern: "", replacement: "", caseSensitive: true)])) == .emptyEditFind)
        #expect(code(cookies([.regex(name: nil, pattern: "(", replacement: "", caseSensitive: true)])) == .invalidRegex)
        #expect(
            code(cookies([.regex(name: nil, pattern: "(a+)+$", replacement: "", caseSensitive: true)]))
                == .regexTooComplex)
    }

    // MARK: delay

    @Test func delayBounds() {
        #expect(code(.delay(milliseconds: 0)) == nil)
        #expect(code(.delay(milliseconds: 60_000)) == nil)
        #expect(code(.delay(milliseconds: -1)) == .invalidDelay)
        #expect(code(.delay(milliseconds: 60_001)) == .invalidDelay)
        #expect(code(.delay(milliseconds: 11), limits: RulesLimits(delayMillisecondsMax: 10)) == .invalidDelay)
    }

    // MARK: generated responses

    @Test func handwrittenResponse() {
        let ok = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\nhi"
        #expect(code(.returnHandwritten(HandwrittenResponse(text: ok))) == nil)
        for bad in ["", "HTTP/2 200 OK", "HTTP/1.1 199 X", "HTTP/1.1 204 No\r\n\r\nbody", "HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n"] {
            #expect(code(.returnHandwritten(HandwrittenResponse(text: bad))) == .invalidHandwrittenResponse, "\(bad)")
        }
        #expect(failure(rule([RuleAction(.returnHandwritten(HandwrittenResponse(text: "x")))]))?.field == .action(index: 0))
    }

    @Test func handwrittenResponseSizeBoundary() {
        let head = "HTTP/1.1 200 OK\r\n\r\n"
        let limits = RulesLimits(handwrittenResponseBytes: 64)
        let exact = head + String(repeating: "a", count: 64 - head.utf8.count)
        #expect(exact.utf8.count == 64)
        #expect(code(.returnHandwritten(HandwrittenResponse(text: exact)), limits: limits) == nil)
        #expect(
            code(.returnHandwritten(HandwrittenResponse(text: exact + "a")), limits: limits)
                == .handwrittenResponseTooLarge)
    }

    @Test func presetResponse() {
        #expect(code(.returnPreset(PresetResponse(preset: .notFound404))) == nil)
        #expect(code(.returnPreset(PresetResponse(preset: .notFound404, body: "gone"))) == nil)
        #expect(code(.returnPreset(PresetResponse(preset: .found302, location: "https://b.test/"))) == nil)
        #expect(code(.returnPreset(PresetResponse(preset: .found302))) == .presetNeedsLocation)
        #expect(code(.returnPreset(PresetResponse(preset: .found302, location: ""))) == .presetNeedsLocation)
        #expect(code(.returnPreset(PresetResponse(preset: .found302, location: "a\r\nb"))) == .invalidPresetField)
        #expect(code(.returnPreset(PresetResponse(preset: .noContent204, body: "x"))) == .invalidPresetField)
        for preset in PresetResponse.Preset.allCases {
            let location = PresetResponse(preset: preset).requiresLocation ? "https://b.test/" : nil
            #expect(code(.returnPreset(PresetResponse(preset: preset, location: location))) == nil, "\(preset)")
        }
    }

    @Test func closeConnectionAlwaysValid() {
        #expect(code(.closeConnection(.graceful)) == nil)
        #expect(code(.closeConnection(.reset)) == nil)
    }

    // MARK: connect-only rules

    private let noDecrypt = RuleAction(.noDecrypt)
    private let tunnel = RuleAction(.returnConnectTunnel)

    @Test func connectOnlyRuleMustBeJudgedAtConnect() {
        let error = failure(rule([ConditionRow(field: .path, op: .equals, value: "/a")], [noDecrypt]))
        #expect(error == RuleValidationError(code: .connectActionCondition, field: .conditions))
        let tunnelError = failure(rule([ConditionRow(field: .pathAndQuery, op: .equals, value: "/a", caseSensitive: true)], [tunnel]))
        #expect(tunnelError == RuleValidationError(code: .connectActionCondition, field: .conditions))
        // A rule judged at the response is refused on its conditions: request-side actions are no longer refused there.
        let late = failure(rule([ConditionRow(field: .statusCode, op: .equals, value: "200")], [noDecrypt]))
        #expect(late == RuleValidationError(code: .connectActionCondition, field: .conditions))
    }

    @Test func connectOnlyAllowsTheWhitelist() {
        let rows: [ConditionRow] = [
            ConditionRow(field: .allSessions, op: .equals),
            ConditionRow(field: .url, op: .startsWith, value: "https://a.test/"),
            ConditionRow(field: .scheme, op: .equals, value: "https"),
            ConditionRow(field: .host, op: .equals, value: "a.test"),
            ConditionRow(field: .port, op: .equals, value: "443"),
            ConditionRow(field: .clientIP, op: .equals, value: "127.0.0.1"),
            ConditionRow(field: .clientApp, name: "name", op: .contains, value: "curl"),
        ]
        for row in rows {
            #expect(failure(rule([row], [noDecrypt])) == nil, "\(row.field)")
            #expect(failure(rule([row], [tunnel])) == nil, "\(row.field)")
        }
        #expect(failure(rule(rows, [noDecrypt])) == nil)
        #expect(failure(rule([], [noDecrypt])) == nil)
    }

    @Test func connectOnlyRejectsBodyAndHeaderRows() {
        let rows: [ConditionRow] = [
            ConditionRow(field: .method, op: .equals, value: "GET", caseSensitive: true),
            ConditionRow(field: .requestHeader, name: "X-A", op: .equals, value: "1"),
            ConditionRow(field: .requestBody, op: .contains, value: "x"),
            ConditionRow(field: .queryString, op: .contains, value: "x"),
            ConditionRow(field: .requestCookie, name: "a", op: .equals, value: "1"),
            ConditionRow(field: .durationMs, op: .greaterThan, value: "1"),
        ]
        for row in rows {
            let valid = failure(rule([ConditionRow(field: .host, op: .equals, value: "a.test"), row], [noDecrypt]))
            // The completion row meets the completion check first; the others the connect whitelist.
            let expected: RuleValidationError.Code =
                row.field == .durationMs ? .actionNotAllowedAtCompletion : .connectActionCondition
            #expect(valid?.code == expected, "\(row.field)")
        }
    }

    @Test func connectOnlyMixedWithRequestActionsRejected() {
        let modify = RuleAction(url(.set, replacement: "https://b.test/"))
        #expect(
            failure(rule([], [noDecrypt, modify])) == RuleValidationError(code: .connectActionMixed, field: .action(index: 1)))
        #expect(
            failure(rule([], [modify, tunnel])) == RuleValidationError(code: .connectActionMixed, field: .action(index: 0)))
        for other in [
            RuleAction(.delay(milliseconds: 10)), RuleAction(.returnPreset(PresetResponse(preset: .notFound404))),
            RuleAction(.rewriteStatus(RewriteStatusAction(status: 500))),
        ] where other.kind.direction == .request {
            #expect(failure(rule([], [noDecrypt, other]))?.code == .connectActionMixed, "\(other.kind)")
        }
        // Two connect-only actions agree with each other.
        #expect(failure(rule([], [noDecrypt, tunnel])) == nil)
    }

    @Test func connectOnlyMixedWithAnnotationsAndCloseAllowed() {
        let mark = RuleAction(.mark(MarkAction(background: "#FF3B30")))
        let comment = RuleAction(.comment(CommentAction(mode: .append, text: "x")))
        let actions = [noDecrypt, mark, comment, RuleAction(.hide), RuleAction(.closeConnection(.reset))]
        #expect(failure(rule([], actions)) == nil)
        #expect(failure(rule([], [RuleAction(.closeConnection(.graceful)), tunnel])) == nil)
    }

    @Test func rulesWithoutConnectOnlyActionsAreNotRestricted() {
        let rows = [ConditionRow(field: .path, op: .equals, value: "/a")]
        let actions = [RuleAction(url(.set, replacement: "https://b.test/")), RuleAction(.closeConnection(.reset))]
        #expect(failure(rule(rows, actions)) == nil)
    }

    // MARK: patterns

    @Test func preparePatternsCompilesTheEditRegexes() {
        let cache = PatternCache()
        let target = rule([
            RuleAction(url(.regex, find: "a+", replacement: "b")),
            RuleAction(cookies([.regex(name: nil, pattern: "c+", replacement: "d", caseSensitive: true)])),
            RuleAction(url(.findReplace, find: "(", replacement: "")),
        ])
        #expect(cache.count == 0)
        target.preparePatterns(in: cache)
        #expect(cache.count == 2)
        // An uncompilable one is skipped, not fatal.
        rule([RuleAction(url(.regex, find: "(", replacement: ""))]).preparePatterns(in: cache)
        #expect(cache.count == 2)
    }

    // MARK: size limits

    @Test func presetFieldsAreBounded() {
        let limits = RulesLimits()
        let max = limits.handwrittenResponseBytes
        #expect(code(.returnPreset(PresetResponse(preset: .notFound404, body: String(repeating: "a", count: max)))) == nil)
        #expect(
            code(.returnPreset(PresetResponse(preset: .notFound404, body: String(repeating: "a", count: max + 1))))
                == .handwrittenResponseTooLarge)
        // Counted in bytes: 21846 three-byte characters are 65538 bytes.
        #expect(
            code(.returnPreset(PresetResponse(preset: .notFound404, body: String(repeating: "中", count: 21_846))))
                == .handwrittenResponseTooLarge)
        let field = limits.fieldBytes
        let long = String(repeating: "a", count: field - 20)
        #expect(code(.returnPreset(PresetResponse(preset: .found302, location: "https://b.test/" + String(long.prefix(field - 15))))) == nil)
        #expect(
            code(.returnPreset(PresetResponse(preset: .found302, location: String(repeating: "a", count: field + 1))))
                == .invalidPresetField)
        #expect(code(.returnPreset(PresetResponse(preset: .unauthorized401, challenge: String(repeating: "a", count: field)))) == nil)
        #expect(
            code(.returnPreset(PresetResponse(preset: .unauthorized401, challenge: String(repeating: "中", count: field / 3 + 1))))
                == .invalidPresetField)
    }

    @Test func editValuesAreBoundedInBytes() {
        let field = RulesLimits().fieldBytes
        let atLimit = String(repeating: "a", count: field)
        let over = String(repeating: "a", count: field + 1)
        let wide = String(repeating: "中", count: field / 3 + 1)  // multi-byte, over the limit
        #expect(code(url(.findReplace, find: "a", replacement: atLimit)) == nil)
        #expect(code(url(.findReplace, find: "a", replacement: over)) == .fieldTooLong)
        #expect(code(url(.regex, find: "a", replacement: over)) == .fieldTooLong)
        #expect(code(url(.set, replacement: "https://b.test/" + over)) == .fieldTooLong)
        #expect(code(query([.set(name: "a", value: atLimit)])) == nil)
        #expect(code(query([.set(name: "a", value: over)])) == .fieldTooLong)
        #expect(code(query([.add(name: over, value: "")])) == .fieldTooLong)
        #expect(code(query([.remove(name: over)])) == .fieldTooLong)
        #expect(code(query([.findReplace(name: nil, find: "a", replacement: over, caseSensitive: true)])) == .fieldTooLong)
        #expect(code(query([.set(name: "a", value: wide)])) == .fieldTooLong)
        #expect(code(cookies([.set(name: "a", value: atLimit)])) == nil)
        #expect(code(cookies([.set(name: "a", value: over)])) == .fieldTooLong)
        #expect(code(cookies([.set(name: "a", value: wide)])) == .fieldTooLong)
        #expect(code(cookies([.set(name: over, value: "")])) == .fieldTooLong)
        #expect(code(cookies([.findReplace(name: nil, find: "a", replacement: over, caseSensitive: true)])) == .fieldTooLong)
        #expect(code(cookies([.regex(name: nil, pattern: "a", replacement: over, caseSensitive: true)])) == .fieldTooLong)
    }

    @Test func noDecryptWithResponseActionIsMixed() {
        let status = RuleAction(.rewriteStatus(RewriteStatusAction(status: 500)))
        #expect(
            failure(rule([], [RuleAction(.noDecrypt), status]))
                == RuleValidationError(code: .connectActionMixed, field: .action(index: 1)))
    }

    @Test func requestActionAtTheResponseIsValidButItsContentIsStillChecked() {
        let late = [ConditionRow(field: .statusCode, op: .equals, value: "200")]
        #expect(failure(rule(late, [RuleAction(.delay(milliseconds: 1))])) == nil)
        #expect(failure(rule(late, [RuleAction(.delay(milliseconds: -1))]))?.code == .invalidDelay)
    }
}

// MARK: Rules 2.0 R5: header edit methods

private func headers(_ operations: [HeaderEdit], _ direction: HTTPMessageDirection = .request) -> ActionKind {
    .editHeaders(direction: direction, operations: operations)
}

@Suite("R5 header edit validation")
struct HeaderEditValidationTests {
    @Test func headerFindReplaceNeedsFind() {
        #expect(code(headers([.findReplace(name: "X", find: "a", replacement: "b", caseSensitive: true)])) == nil)
        let empty = headers([.findReplace(name: "X", find: "", replacement: "b", caseSensitive: true)])
        #expect(code(empty) == .emptyEditFind)
        #expect(failure(rule([RuleAction(empty)]))?.field == .action(index: 0))
        #expect(code(headers([.regex(name: "X", pattern: "", replacement: "b", caseSensitive: true)])) == .emptyEditFind)
        let limits = RulesLimits()
        let long = String(repeating: "a", count: limits.fieldBytes + 1)
        #expect(code(headers([.findReplace(name: "X", find: long, replacement: "", caseSensitive: true)])) == .findTooLong)
    }

    @Test func headerRegexMustCompile() {
        #expect(code(headers([.regex(name: "X", pattern: "a(b)+", replacement: "$1", caseSensitive: true)])) == nil)
        #expect(code(headers([.regex(name: "X", pattern: "(", replacement: "b", caseSensitive: true)])) == .invalidRegex)
    }

    @Test func headerNewMethodsStillRejectProtectedNames() {
        for name in ["Host", "Content-Length", "Transfer-Encoding"] {
            let operations: [HeaderEdit] = [
                .appendToValue(name: name, text: "x"), .addIfMissing(name: name, value: "x"),
                .findReplace(name: name, find: "a", replacement: "b", caseSensitive: true),
                .regex(name: name, pattern: "a", replacement: "b", caseSensitive: true),
            ]
            for operation in operations {
                #expect(throws: HTTPMutationError.self, "\(name) \(operation)") {
                    try HTTPMutationValidator.validateEdits([operation], originalHeaders: [])
                }
                let failed = failure(rule([RuleAction(headers([operation]))]))
                #expect(failed?.code == .invalidHeaderEdit, "\(name) \(operation)")
                #expect(failed?.mutation?.code == .protectedHeader, "\(name) \(operation)")
            }
        }
    }

    @Test func headerReplacementMustBeAValidValue() {
        let bad = headers([.findReplace(name: "X", find: "a", replacement: "b\nc", caseSensitive: true)])
        #expect(code(bad) == .invalidHeaderEdit)
        #expect(failure(rule([RuleAction(bad)]))?.mutation?.code == .invalidHeaderValue)
        #expect(code(headers([.appendToValue(name: "X", text: "a\r")])) == .invalidHeaderEdit)
        #expect(code(headers([.addIfMissing(name: "X", value: "a\u{0}")])) == .invalidHeaderEdit)
    }
}

@Suite("R5 body edit validation")
struct BodyEditValidationTests {
    private func body(_ action: BodyRewriteAction) -> ActionKind { .rewriteBody(direction: .response, action) }

    @Test func setValueAllowsEmptyFind() {
        #expect(code(body(BodyRewriteAction(find: "", replacement: "x", operation: .setValue))) == nil)
        #expect(code(body(BodyRewriteAction(find: "", replacement: "", operation: .clear))) == nil)
        // An unusable find text is not looked at.
        #expect(code(body(BodyRewriteAction(find: "(", replacement: "x", syntax: .regex, operation: .setValue))) == nil)
    }

    @Test func findReplaceStillRequiresFind() {
        #expect(code(body(BodyRewriteAction(find: "", replacement: "x"))) == .emptyFind)
        #expect(code(body(BodyRewriteAction(find: "(", replacement: "x", syntax: .regex))) == .invalidRegex)
    }

    @Test func setValueReplacementTooLongIsRefused() {
        let limits = RulesLimits()
        let long = String(repeating: "a", count: limits.fieldBytes + 1)
        #expect(code(body(BodyRewriteAction(find: "", replacement: long, operation: .setValue))) != nil)
    }
}
