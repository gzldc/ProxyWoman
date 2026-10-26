import FlowStore
import Foundation
import Testing

@testable import RulesEngine

private func f(_ name: String, _ value: String) -> HeaderField { HeaderField(name: name, value: value) }

/// R8F2 T3: the six Fiddler methods and "all keys" for header, cookie and query edits, URL append,
/// comment regex and add-if-missing, the status reason phrase, the new presets and the editor language.
@Suite("R8F2 action editing")
struct ActionEditingR8F2Tests {
    private func json<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    // MARK: headers, all keys

    private func headers(_ edits: [HeaderEdit], _ fields: [HeaderField]) -> HeaderEditResult {
        fields.applying(edits, allowance: RegexAllowance(), cache: PatternCache())
    }

    private var message: [HeaderField] {
        [f("Host", "h"), f("Accept", "a"), f("Content-Length", "3"), f("X-A", "one"), f("x-b", "two")]
    }

    @Test func headerSetOnAllKeysSkipsProtectedFields() {
        let result = headers([.set(name: "", value: "v")], message)
        #expect(result.headers == [f("Host", "h"), f("Accept", "v"), f("Content-Length", "3"), f("X-A", "v"), f("x-b", "v")])
    }

    @Test func headerRemoveOnAllKeysKeepsProtectedFields() {
        let result = headers([.remove(name: "")], message)
        #expect(result.headers == [f("Host", "h"), f("Content-Length", "3")])
    }

    @Test func headerAppendFindReplaceAndRegexOnAllKeys() {
        let appended = headers([.appendToValue(name: "", text: "!")], message)
        #expect(appended.headers == [f("Host", "h"), f("Accept", "a!"), f("Content-Length", "3"), f("X-A", "one!"), f("x-b", "two!")])
        let replaced = headers([.findReplace(name: "", find: "O", replacement: "0", caseSensitive: false)], message)
        #expect(replaced.headers.map(\.value) == ["h", "a", "3", "0ne", "tw0"])
        let sensitive = headers([.findReplace(name: "", find: "O", replacement: "0", caseSensitive: true)], message)
        #expect(sensitive.matchedNothing && !sensitive.changed)
        let regex = headers([.regex(name: "", pattern: "(o)", replacement: "[$1]", caseSensitive: false)], message)
        #expect(regex.headers.map(\.value) == ["h", "a", "3", "[o]ne", "tw[o]"])
    }

    @Test func connectionNominatedFieldsAreSkippedByAllKeys() {
        let result = headers([.set(name: "", value: "v")], [f("Connection", "X-Hop"), f("X-Hop", "1"), f("X-A", "1")])
        #expect(result.headers == [f("Connection", "X-Hop"), f("X-Hop", "1"), f("X-A", "v")])
    }

    @Test func allKeysLeavesPseudoProxyAndUpgradeFieldsAlone() {
        let fields = [f(":authority", "h"), f("Proxy-Authorization", "p"), f("Proxy-Foo", "q"), f("Sec-WebSocket-Key", "k"), f("X-A", "1")]
        let plain = headers([.set(name: "", value: "v")], fields)
        // Without Upgrade only pseudo and proxy-* are protected.
        #expect(plain.headers == [f(":authority", "h"), f("Proxy-Authorization", "p"), f("Proxy-Foo", "q"), f("Sec-WebSocket-Key", "v"), f("X-A", "v")])
        let upgrade = fields + [f("Upgrade", "websocket"), f("Connection", "Upgrade")]
        let guarded = headers([.set(name: "", value: "v")], upgrade)
        #expect(guarded.headers == [f(":authority", "h"), f("Proxy-Authorization", "p"), f("Proxy-Foo", "q"), f("Sec-WebSocket-Key", "k"), f("X-A", "v"), f("Upgrade", "websocket"), f("Connection", "Upgrade")])
        #expect(headers([.remove(name: "")], upgrade).headers.map(\.name) == [":authority", "Proxy-Authorization", "Proxy-Foo", "Sec-WebSocket-Key", "Upgrade", "Connection"])
        #expect(headers([.appendToValue(name: "", text: "!")], upgrade).headers.map(\.value) == ["h", "p", "q", "k", "1!", "websocket", "Upgrade"])
    }

    @Test func emptyStatusReasonIsNoReason() throws {
        #expect(RewriteStatusAction(status: 404, reason: "").reason == nil)
        #expect(RewriteStatusAction(status: 404, reason: "") == RewriteStatusAction(status: 404))
        let decoded = try JSONDecoder().decode(
            RewriteStatusAction.self, from: Data(#"{"includeLocalResponses":false,"reason":"","status":404}"#.utf8))
        #expect(decoded.reason == nil)
        #expect(try json(decoded) == #"{"includeLocalResponses":false,"status":404}"#)
    }

    @Test func addIfMissingAndAppendNeedAKey() throws {
        for edit in [HeaderEdit.addIfMissing(name: "", value: "v"), .append(name: "", value: "v")] {
            #expect(throws: HTTPMutationError.self) { try HTTPMutationValidator.validateEdits([edit], originalHeaders: []) }
            #expect(headers([edit], message).headers == message)
        }
        for edit in [
            HeaderEdit.set(name: "", value: "v"), .remove(name: ""), .appendToValue(name: "", text: "t"),
            .findReplace(name: "", find: "a", replacement: "b", caseSensitive: false),
            .regex(name: "", pattern: "a", replacement: "b", caseSensitive: false),
        ] {
            try HTTPMutationValidator.validateEdits([edit], originalHeaders: [])
        }
        // A named protected field is still refused.
        #expect(throws: HTTPMutationError.self) {
            try HTTPMutationValidator.validateEdits([.set(name: "Host", value: "x")], originalHeaders: [])
        }
    }

    // MARK: cookies

    private func request(_ edits: [CookieEdit], _ cookie: String) -> [HeaderField] {
        CookieEditing.applyToRequest(edits, headers: [f("Cookie", cookie)], allowance: RegexAllowance(), cache: PatternCache())
            .headers
    }

    private func response(_ edits: [CookieEdit], _ fields: [HeaderField]) -> [HeaderField] {
        CookieEditing.applyToResponse(edits, headers: fields, allowance: RegexAllowance(), cache: PatternCache()).headers
    }

    @Test func cookieAppendToValue() {
        #expect(request([.appendToValue(name: "b", text: "x")], "a=1; b=2; b=3") == [f("Cookie", "a=1; b=2x; b=3x")])
        #expect(
            response([.appendToValue(name: "b", text: "x")], [f("Set-Cookie", "b=2; Path=/"), f("Set-Cookie", "a=1")])
                == [f("Set-Cookie", "b=2x; Path=/"), f("Set-Cookie", "a=1")])
    }

    @Test func cookieAllKeys() {
        #expect(request([.set(name: "", value: "z")], "a=1; b=2") == [f("Cookie", "a=z; b=z")])
        #expect(request([.appendToValue(name: "", text: "+")], "a=1; b=2") == [f("Cookie", "a=1+; b=2+")])
        #expect(request([.remove(name: "")], "a=1; b=2") == [])
        #expect(
            response([.set(name: "", value: "z")], [f("Set-Cookie", "a=1; Secure"), f("Set-Cookie", "b=2")])
                == [f("Set-Cookie", "a=z; Secure"), f("Set-Cookie", "b=z")])
        #expect(response([.remove(name: "")], [f("Set-Cookie", "a=1"), f("X", "y")]) == [f("X", "y")])
        // An empty string means every cookie for the look-up methods too.
        #expect(
            request([.findReplace(name: "", find: "1", replacement: "9", caseSensitive: false)], "a=1; b=1")
                == [f("Cookie", "a=9; b=9")])
        #expect(request([.addIfMissing(name: "", value: "z")], "a=1") == [f("Cookie", "a=1")])
    }

    // MARK: query

    private func q(_ edits: [QueryEdit], _ path: String = "/p?a=1&b=2&flag") -> String {
        QueryEditing.apply(edits, to: path, allowance: RegexAllowance(), cache: PatternCache()).pathAndQuery
    }

    @Test func queryAllKeys() {
        #expect(q([.set(name: "", value: "9")]) == "/p?a=9&b=9&flag=9")
        #expect(q([.remove(name: "")]) == "/p")
        #expect(q([.appendToValue(name: "", text: "x")]) == "/p?a=1x&b=2x&flag")
        #expect(q([.findReplace(name: "", find: "1", replacement: "7", caseSensitive: false)]) == "/p?a=7&b=2&flag")
        #expect(q([.set(name: "", value: "9")], "/p") == "/p")
        #expect(q([.set(name: "", value: "9")], "/p?a=1&&b") == "/p?a=9&&b=9")
        #expect(q([.remove(name: "")], "/p?a=1&&b=2") == "/p")
        #expect(q([.remove(name: "")], "/p?&") == "/p")
    }

    @Test func queryAppendToValueAndAddIfMissing() {
        #expect(q([.appendToValue(name: "a", text: "x")]) == "/p?a=1x&b=2&flag")
        #expect(q([.appendToValue(name: "zz", text: "x")]) == "/p?a=1&b=2&flag")
        #expect(q([.addIfMissing(name: "a", value: "9")]) == "/p?a=1&b=2&flag")
        #expect(q([.addIfMissing(name: "c", value: "9")]) == "/p?a=1&b=2&flag&c=9")
        #expect(q([.addIfMissing(name: "c", value: "9")], "/p") == "/p?c=9")
    }

    @Test func queryRegex() {
        #expect(q([.regex(name: "a", pattern: "(\\d)", replacement: "<$1>", caseSensitive: false)]) == "/p?a=<1>&b=2&flag")
        #expect(q([.regex(name: nil, pattern: "\\d", replacement: "#", caseSensitive: false)]) == "/p?a=#&b=#&flag")
        #expect(q([.regex(name: "", pattern: "\\d", replacement: "#", caseSensitive: false)]) == "/p?a=#&b=#&flag")
        #expect(q([.regex(name: "a", pattern: "X", replacement: "#", caseSensitive: false)], "/p?a=x") == "/p?a=#")
        #expect(q([.regex(name: "a", pattern: "X", replacement: "#", caseSensitive: true)], "/p?a=x") == "/p?a=x")
        // An unreadable pattern never applies.
        #expect(q([.regex(name: "a", pattern: "(", replacement: "#", caseSensitive: false)]) == "/p?a=1&b=2&flag")
    }

    @Test func queryEditsRunInOrderThroughTheEvaluatorPath() throws {
        let target = HTTPMessageTarget(scheme: "https", host: "a.com", port: 443, method: "GET", pathAndQuery: "/p?a=1")
        let kind = ActionKind.modifyQuery(
            QueryEditAction(operations: [.addIfMissing(name: "b", value: "2"), .appendToValue(name: "a", text: "0")]))
        let edit = try RuleEvaluator.editedTarget(kind, from: target, EditContext())
        guard case .moved(let remote) = edit else { Issue.record("expected a move, got \(edit)"); return }
        #expect(remote.path == .replace("/p?a=10&b=2"))
    }

    // MARK: URL append

    @Test func urlAppend() throws {
        let target = HTTPMessageTarget(scheme: "https", host: "a.com", port: 443, method: "GET", pathAndQuery: "/x?q=1")
        let result = URLEditing.apply(
            URLEditAction(mode: .append, replacement: "&r=2"), to: target, allowance: RegexAllowance(), cache: PatternCache())
        #expect(try result.get().pathAndQuery == "/x?q=1&r=2")
        // A result that is no URL is refused as for the other modes.
        let bad = URLEditing.apply(
            URLEditAction(mode: .append, replacement: " "), to: target, allowance: RegexAllowance(), cache: PatternCache())
        #expect(bad == .failure(.invalidResult))
        let empty = URLEditing.apply(
            URLEditAction(mode: .append), to: target, allowance: RegexAllowance(), cache: PatternCache())
        #expect(try empty.get() == target)
    }

    // MARK: comment

    @Test func commentRegexAndAddIfMissing() {
        #expect(CommentAction(mode: .addIfMissing, text: "t").applying(to: nil) == "t")
        #expect(CommentAction(mode: .addIfMissing, text: "t").applying(to: "") == "t")
        #expect(CommentAction(mode: .addIfMissing, text: "t").applying(to: "old") == "old")
        let regex = CommentAction(mode: .regex, text: "(\\d+)", replacement: "<$1>")
        #expect(regex.applying(to: "a12b3") == "a<12>b<3>")
        #expect(regex.applying(to: nil) == nil)
        #expect(regex.applying(to: "none") == "none")
        #expect(CommentAction(mode: .regex, text: "(", replacement: "x").applying(to: "keep") == "keep")
        #expect(CommentAction(mode: .regex, text: "ABC", replacement: "-", caseSensitive: false).applying(to: "xabcx") == "x-x")
        #expect(CommentAction(mode: .regex, text: "ABC", replacement: "-", caseSensitive: true).applying(to: "xabcx") == "xabcx")
        #expect(
            CommentAction(mode: .findReplace, text: "ABC", replacement: "-", caseSensitive: false).applying(to: "xabcx")
                == "x-x")
        #expect(CommentAction(mode: .findReplace, text: "ABC", replacement: "-").applying(to: "xabcx") == "xabcx")
    }

    @Test func commentValidation() {
        func code(_ comment: CommentAction) -> RuleValidationError.Code? {
            do {
                try Rule(name: "r", actions: [RuleAction(.comment(comment))]).validate(limits: RulesLimits())
                return nil
            } catch let error as RuleValidationError { return error.code } catch { return nil }
        }
        #expect(code(CommentAction(mode: .regex, text: "a+", replacement: "b")) == nil)
        #expect(code(CommentAction(mode: .regex, text: "", replacement: "b")) == .emptyCommentFind)
        #expect(code(CommentAction(mode: .regex, text: "(", replacement: "b")) == .invalidRegex)
        #expect(code(CommentAction(mode: .addIfMissing, text: "t")) == nil)
        #expect(code(CommentAction(mode: .addIfMissing, text: "")) == .emptyComment)
    }

    @Test func commentCodable() throws {
        // Files from before: no case flag, and the same bytes out.
        let old = #"{"mode":"findReplace","replacement":"b","text":"a"}"#
        let decoded = try JSONDecoder().decode(CommentAction.self, from: Data(old.utf8))
        #expect(decoded == CommentAction(mode: .findReplace, text: "a", replacement: "b"))
        #expect(decoded.caseSensitive)
        #expect(try json(decoded) == old)
        // New shapes round trip.
        for action in [
            CommentAction(mode: .regex, text: "a", replacement: "b", caseSensitive: false),
            CommentAction(mode: .addIfMissing, text: "t"),
        ] {
            let text = try json(action)
            #expect(try JSONDecoder().decode(CommentAction.self, from: Data(text.utf8)) == action)
        }
        #expect(try json(CommentAction(mode: .findReplace, text: "a", replacement: "b", caseSensitive: false)).contains("\"caseSensitive\":false"))
    }

    // MARK: Codable of the edits

    @Test func oldEditShapesDecodeAndEncodeUnchanged() throws {
        let cookies: [(CookieEdit, String)] = [
            (.set(name: "a", value: "1"), #"{"set":{"name":"a","value":"1"}}"#),
            (.addIfMissing(name: "a", value: "1"), #"{"addIfMissing":{"name":"a","value":"1"}}"#),
            (.remove(name: "a"), #"{"remove":{"name":"a"}}"#),
            (
                .findReplace(name: nil, find: "f", replacement: "r", caseSensitive: false),
                #"{"findReplace":{"caseSensitive":false,"find":"f","replacement":"r"}}"#
            ),
        ]
        for (edit, text) in cookies {
            #expect(try JSONDecoder().decode(CookieEdit.self, from: Data(text.utf8)) == edit)
            #expect(try json(edit) == text)
        }
        let queries: [(QueryEdit, String)] = [
            (.set(name: "a", value: "1"), #"{"set":{"name":"a","value":"1"}}"#),
            (.add(name: "a", value: "1"), #"{"add":{"name":"a","value":"1"}}"#),
            (.remove(name: "a"), #"{"remove":{"name":"a"}}"#),
            (
                .findReplace(name: "a", find: "f", replacement: "r", caseSensitive: true),
                #"{"findReplace":{"caseSensitive":true,"find":"f","name":"a","replacement":"r"}}"#
            ),
        ]
        for (edit, text) in queries {
            #expect(try JSONDecoder().decode(QueryEdit.self, from: Data(text.utf8)) == edit)
            #expect(try json(edit) == text)
        }
        let url = #"{"caseSensitive":false,"find":"","mode":"set","preserveCredentials":false,"replacement":"http://a/"}"#
        #expect(try json(try JSONDecoder().decode(URLEditAction.self, from: Data(url.utf8))) == url)
    }

    @Test func newEditShapesRoundTrip() throws {
        let cookies: [CookieEdit] = [.appendToValue(name: "a", text: "t"), .appendToValue(name: "", text: "t")]
        for edit in cookies { #expect(try JSONDecoder().decode(CookieEdit.self, from: Data(try json(edit).utf8)) == edit) }
        let queries: [QueryEdit] = [
            .regex(name: "a", pattern: "p", replacement: "r", caseSensitive: false),
            .regex(name: nil, pattern: "p", replacement: "r", caseSensitive: true),
            .addIfMissing(name: "a", value: "v"), .appendToValue(name: "a", text: "t"),
        ]
        for edit in queries { #expect(try JSONDecoder().decode(QueryEdit.self, from: Data(try json(edit).utf8)) == edit) }
        let url = URLEditAction(mode: .append, replacement: "x")
        #expect(try JSONDecoder().decode(URLEditAction.self, from: Data(try json(url).utf8)) == url)
        #expect(try json(url).contains("\"mode\":\"append\""))
    }

    // MARK: validation

    private func code(_ kind: ActionKind) -> RuleValidationError.Code? {
        do {
            try Rule(name: "r", actions: [RuleAction(kind)]).validate(limits: RulesLimits())
            return nil
        } catch let error as RuleValidationError { return error.code } catch { return nil }
    }

    @Test func queryAndCookieValidationOfTheNewForms() {
        func query(_ edit: QueryEdit) -> ActionKind { .modifyQuery(QueryEditAction(operations: [edit])) }
        func cookie(_ edit: CookieEdit) -> ActionKind { .editCookies(direction: .request, operations: [edit]) }
        // Valid.
        let valid: [ActionKind] = [
            query(.set(name: "", value: "v")), query(.remove(name: "")), query(.appendToValue(name: "", text: "t")),
            query(.appendToValue(name: "a", text: "t")), query(.addIfMissing(name: "a", value: "v")),
            query(.regex(name: nil, pattern: "a+", replacement: "b", caseSensitive: false)),
            query(.regex(name: "", pattern: "a+", replacement: "b", caseSensitive: false)),
            cookie(.set(name: "", value: "v")), cookie(.remove(name: "")), cookie(.appendToValue(name: "", text: "t")),
            cookie(.appendToValue(name: "a", text: "t")),
            .modifyURL(URLEditAction(mode: .append, replacement: "&x=1")),
        ]
        for kind in valid { #expect(code(kind) == nil, "\(kind)") }
        // Invalid.
        #expect(code(query(.addIfMissing(name: "", value: "v"))) == .invalidQueryEdit)
        #expect(code(query(.add(name: "", value: "v"))) == .invalidQueryEdit)
        #expect(code(query(.appendToValue(name: "a", text: "a&b"))) == .invalidQueryEdit)
        #expect(code(query(.regex(name: nil, pattern: "(", replacement: "", caseSensitive: false))) == .invalidRegex)
        #expect(code(query(.regex(name: nil, pattern: "", replacement: "", caseSensitive: false))) == .emptyEditFind)
        #expect(code(cookie(.addIfMissing(name: "", value: "v"))) == .invalidCookieEdit)
        #expect(code(cookie(.appendToValue(name: "a", text: "a;b"))) == .invalidCookieEdit)
        #expect(code(.modifyURL(URLEditAction(mode: .append, replacement: String(repeating: "x", count: 100_000)))) == .fieldTooLong)
    }

    @Test func headerEditsOnAllKeysValidateThroughTheRule() {
        func headerKind(_ edit: HeaderEdit) -> ActionKind { .editHeaders(direction: .request, operations: [edit]) }
        #expect(code(headerKind(.set(name: "", value: "v"))) == nil)
        #expect(code(headerKind(.remove(name: ""))) == nil)
        #expect(code(headerKind(.regex(name: "", pattern: "a", replacement: "b", caseSensitive: false))) == nil)
        #expect(code(headerKind(.addIfMissing(name: "", value: "v"))) == .invalidHeaderEdit)
        #expect(code(headerKind(.append(name: "", value: "v"))) == .invalidHeaderEdit)
    }

    @Test func queryRegexIsPreparedWithTheRule() {
        let rule = Rule(name: "r", actions: [
            RuleAction(.modifyQuery(QueryEditAction(operations: [.regex(name: nil, pattern: "a+", replacement: "", caseSensitive: false)])))
        ])
        #expect(rule.editRegexes == [EditRegex(pattern: "a+", caseInsensitive: true)])
    }

    // MARK: status

    @Test func statusParse() {
        #expect(RewriteStatusAction.parse("404") == RewriteStatusAction(status: 404))
        #expect(RewriteStatusAction.parse(" 404 ") == RewriteStatusAction(status: 404))
        #expect(RewriteStatusAction.parse("404 Not Found") == RewriteStatusAction(status: 404, reason: "Not Found"))
        #expect(RewriteStatusAction.parse("200 Fine  here ")?.reason == "Fine  here")
        #expect(RewriteStatusAction.parse("404 ") == RewriteStatusAction(status: 404))
        #expect(RewriteStatusAction.parse("200", includeLocalResponses: true)?.includeLocalResponses == true)
        for bad in ["", "abc", "99", "199", "600", "1000", "404Not", "4040", "404 bad\r\nreason", "40", "-404", "404\u{7}"] {
            #expect(RewriteStatusAction.parse(bad) == nil, "\(bad.debugDescription)")
        }
        let longest = "404 " + String(repeating: "x", count: 196)
        #expect(RewriteStatusAction.parse(longest) != nil)
        #expect(RewriteStatusAction.parse(longest + "x") == nil)
        #expect(RewriteStatusAction(status: 404, reason: "Not Found").text == "404 Not Found")
        #expect(RewriteStatusAction(status: 404).text == "404")
    }

    @Test func statusCodable() throws {
        let old = #"{"includeLocalResponses":false,"status":404}"#
        let decoded = try JSONDecoder().decode(RewriteStatusAction.self, from: Data(old.utf8))
        #expect(decoded == RewriteStatusAction(status: 404))
        #expect(try json(decoded) == old)
        let withReason = RewriteStatusAction(status: 404, includeLocalResponses: true, reason: "Gone Fishing")
        #expect(try json(withReason) == #"{"includeLocalResponses":true,"reason":"Gone Fishing","status":404}"#)
        #expect(try JSONDecoder().decode(RewriteStatusAction.self, from: Data(try json(withReason).utf8)) == withReason)
    }

    @Test func statusValidationAndEvaluation() throws {
        #expect(code(.rewriteStatus(RewriteStatusAction(status: 404, reason: "Not Found"))) == nil)
        #expect(code(.rewriteStatus(RewriteStatusAction(status: 404, reason: "bad\r\nx"))) == .invalidStatus)
        #expect(code(.rewriteStatus(RewriteStatusAction(status: 404, reason: String(repeating: "x", count: 197)))) == .invalidStatus)

        func decide(_ action: RewriteStatusAction) throws -> ResponseRuleDecision {
            let snapshot = RuleSnapshot(revision: 1, rules: [Rule(name: "s", actions: [RuleAction(.rewriteStatus(action))])])
            let target = HTTPMessageTarget(scheme: "http", host: "a.com", port: 80, method: "GET", pathAndQuery: "/")
            let first = try RuleEvaluator.request(.request(target, headers: []), snapshot: snapshot)
            return try RuleEvaluator.response(.response(status: 200, reason: "OK", headers: []), after: first, snapshot: snapshot)
        }
        let decision = try decide(RewriteStatusAction(status: 404, reason: "Gone Fishing"))
        #expect(decision.statusRewrite == 404)
        #expect(decision.statusReason == "Gone Fishing")
        #expect(decision.effectiveHead == .response(status: 404, reason: "Gone Fishing", headers: []))

        // Without a reason the old behaviour: none carried.
        let plain = try decide(RewriteStatusAction(status: 404))
        #expect(plain.statusReason == nil)
        #expect(plain.effectiveHead == .response(status: 404, reason: nil, headers: []))
    }

    // MARK: presets

    @Test func newPresets() throws {
        let pixel = try PresetResponse(preset: .transparentPixel200).build().get()
        #expect(pixel.status == 200 && pixel.reason == "OK")
        #expect(pixel.headers == [f("Content-Type", "image/gif"), f("Content-Length", "43"), f("Cache-Control", "no-store")])
        // A GIF89a, 1x1, ending with the trailer byte.
        #expect(pixel.body.prefix(6) == Data("GIF89a".utf8))
        #expect(pixel.body.count == 43 && pixel.body.last == 0x3B)
        #expect(Array(pixel.body[6..<10]) == [0x01, 0x00, 0x01, 0x00])

        let digest = try PresetResponse(preset: .digestAuth401).build().get()
        #expect(digest.status == 401 && digest.reason == "Unauthorized")
        #expect(digest.body.isEmpty)
        let challenge = try #require(digest.headers.first { $0.name == "WWW-Authenticate" }?.value)
        #expect(challenge.hasPrefix(#"Digest realm="ProxyWoman", qop="auth", nonce=""#))
        #expect(challenge.contains(#"opaque=""#))
        #expect(digest.headers.map(\.name) == ["Content-Type", "Content-Length", "WWW-Authenticate"])
        // The challenge can be overridden like the Basic one.
        let custom = try PresetResponse(preset: .digestAuth401, challenge: #"Digest realm="x""#).build().get()
        #expect(custom.headers.last == f("WWW-Authenticate", #"Digest realm="x""#))
        // The Basic preset is as before.
        let basic = try PresetResponse(preset: .unauthorized401).build().get()
        #expect(basic.headers.last == f("WWW-Authenticate", #"Basic realm="ProxyWoman""#))

        let unreachable = try PresetResponse(preset: .unreachable502, body: "down").build().get()
        #expect(unreachable.status == 502 && unreachable.reason == "Bad Gateway")
        #expect(unreachable.body == Data("down".utf8))
        let empty = try PresetResponse(preset: .unreachable502).build().get()
        #expect(empty.body.isEmpty)
        #expect(empty.headers == [f("Content-Type", "text/plain; charset=utf-8"), f("Content-Length", "0")])
    }

    @Test func presetRawValuesOnlyGrew() throws {
        let names = PresetResponse.Preset.allCases.map(\.rawValue)
        #expect(names.prefix(17) == [
            "emptyHTML200", "gif200", "noContent204", "movedPermanently301", "found302", "seeOther303", "notModified304",
            "temporaryRedirect307", "permanentRedirect308", "badRequest400", "unauthorized401", "forbidden403",
            "notFound404", "proxyAuthRequired407", "tooManyRequests429", "internalError500", "serviceUnavailable503",
        ])
        #expect(names.suffix(3) == ["transparentPixel200", "digestAuth401", "unreachable502"])
        let old = #"{"preset":"gif200"}"#
        #expect(try JSONDecoder().decode(PresetResponse.self, from: Data(old.utf8)) == PresetResponse(preset: .gif200))
        #expect(try json(PresetResponse(preset: .gif200)) == old)
    }

    // MARK: body editor language

    @Test func bodyEditorLanguage() throws {
        let old = #"{"caseSensitive":true,"find":"a","replacement":"b","scope":"all","syntax":"text"}"#
        let decoded = try JSONDecoder().decode(BodyRewriteAction.self, from: Data(old.utf8))
        #expect(decoded.editorLanguage == nil)
        #expect(try json(decoded) == old)
        var withLanguage = decoded
        withLanguage.editorLanguage = "json"
        #expect(try json(withLanguage) == #"{"caseSensitive":true,"editorLanguage":"json","find":"a","replacement":"b","scope":"all","syntax":"text"}"#)
        #expect(try JSONDecoder().decode(BodyRewriteAction.self, from: Data(try json(withLanguage).utf8)) == withLanguage)
        // It never changes what the rewrite does.
        let buffer = BodyRewriteStep(ruleID: UUID(), action: withLanguage)
        #expect(buffer.action.wholeText == decoded.wholeText)
    }
}
