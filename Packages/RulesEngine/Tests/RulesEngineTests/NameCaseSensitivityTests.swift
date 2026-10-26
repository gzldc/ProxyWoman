import FlowStore
import Foundation
import Testing

@testable import RulesEngine

private func f(_ name: String, _ value: String) -> HeaderField { HeaderField(name: name, value: value) }

/// R8F2 T8: the key "Aa" switch of header, query and cookie edits. nil keeps the original behaviour
/// (headers case-insensitive, query and cookie names exact), so saved rules and traffic do not change.
@Suite("Name case sensitivity")
struct NameCaseSensitivityTests {
    private func json<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private func headers(_ edits: [HeaderEdit], _ fields: [HeaderField]) -> [HeaderField] {
        fields.applying(edits, allowance: RegexAllowance(), cache: PatternCache()).headers
    }

    // MARK: headers

    @Test func headerNilAndFalseAreCaseInsensitive() {
        let message = [f("X-Token", "a")]
        #expect(headers([.set(name: "x-token", value: "b")], message) == [f("x-token", "b")])
        #expect(headers([.set(name: "x-token", value: "b", nameCaseSensitive: false)], message) == [f("x-token", "b")])
        #expect(headers([.remove(name: "x-token", nameCaseSensitive: false)], message) == [])
    }

    @Test func headerTrueMatchesExactCaseOnly() {
        let message = [f("X-Token", "a"), f("x-token", "b")]
        #expect(headers([.remove(name: "x-token", nameCaseSensitive: true)], message) == [f("X-Token", "a")])
        #expect(
            headers([.set(name: "x-token", value: "v", nameCaseSensitive: true)], message)
                == [f("X-Token", "a"), f("x-token", "v")])
        #expect(
            headers([.set(name: "X-TOKEN", value: "v", nameCaseSensitive: true)], message)
                == message + [f("X-TOKEN", "v")])
        #expect(
            headers([.addIfMissing(name: "x-token", value: "v", nameCaseSensitive: true)], [f("X-Token", "a")])
                == [f("X-Token", "a"), f("x-token", "v")])
        #expect(
            headers([.appendToValue(name: "x-token", text: "!", nameCaseSensitive: true)], message)
                == [f("X-Token", "a"), f("x-token", "b!")])
        #expect(
            headers(
                [.findReplace(name: "x-token", find: "b", replacement: "c", caseSensitive: true, nameCaseSensitive: true)], message)
                == [f("X-Token", "a"), f("x-token", "c")])
        #expect(
            headers([.regex(name: "X-Token", pattern: "a|b", replacement: "z", caseSensitive: true, nameCaseSensitive: true)], message)
                == [f("X-Token", "z"), f("x-token", "b")])
    }

    // MARK: query

    private func query(_ edits: [QueryEdit], _ target: String) -> String { QueryEditing.apply(edits, to: target) }

    @Test func queryNilAndTrueAreExactAndFalseIgnoresCase() {
        let target = "/p?Key=1&key=2"
        #expect(query([.remove(name: "key")], target) == "/p?Key=1")
        #expect(query([.remove(name: "key", nameCaseSensitive: true)], target) == "/p?Key=1")
        #expect(query([.remove(name: "key", nameCaseSensitive: false)], target) == "/p")
        #expect(query([.set(name: "KEY", value: "v", nameCaseSensitive: false)], target) == "/p?KEY=v")
        #expect(query([.addIfMissing(name: "KEY", value: "v", nameCaseSensitive: false)], target) == target)
        #expect(query([.addIfMissing(name: "KEY", value: "v")], target) == target + "&KEY=v")
        #expect(query([.appendToValue(name: "KEY", text: "!", nameCaseSensitive: false)], target) == "/p?Key=1!&key=2!")
        #expect(query([.appendToValue(name: "KEY", text: "!")], target) == target)
        #expect(
            query([.findReplace(name: "KEY", find: "2", replacement: "9", caseSensitive: true, nameCaseSensitive: false)], target)
                == "/p?Key=1&key=9")
        #expect(
            query([.regex(name: "KEY", pattern: "1", replacement: "9", caseSensitive: true, nameCaseSensitive: false)], target)
                == "/p?Key=9&key=2")
    }

    // MARK: cookies

    private func request(_ edits: [CookieEdit], _ cookie: String) -> [HeaderField] {
        CookieEditing.applyToRequest(edits, headers: [f("Cookie", cookie)], allowance: RegexAllowance(), cache: PatternCache())
            .headers
    }

    @Test func cookieNilAndTrueAreExactAndFalseIgnoresCase() {
        let cookie = "Sid=1; sid=2"
        #expect(request([.remove(name: "sid")], cookie) == [f("Cookie", "Sid=1")])
        #expect(request([.remove(name: "sid", nameCaseSensitive: true)], cookie) == [f("Cookie", "Sid=1")])
        #expect(request([.remove(name: "sid", nameCaseSensitive: false)], cookie) == [])
        #expect(request([.addIfMissing(name: "SID", value: "v", nameCaseSensitive: false)], cookie) == [f("Cookie", cookie)])
        #expect(request([.addIfMissing(name: "SID", value: "v")], cookie) == [f("Cookie", cookie + "; SID=v")])
        #expect(
            request([.appendToValue(name: "SID", text: "!", nameCaseSensitive: false)], cookie) == [f("Cookie", "Sid=1!; sid=2!")])
    }

    @Test func responseCookieHonoursTheFlag() {
        let fields = [f("Set-Cookie", "Sid=1; Path=/"), f("Set-Cookie", "sid=2")]
        let edited = CookieEditing.applyToResponse(
            [.remove(name: "SID", nameCaseSensitive: false)], headers: fields, allowance: RegexAllowance(), cache: PatternCache())
        #expect(edited.headers == [])
        let untouched = CookieEditing.applyToResponse(
            [.remove(name: "SID")], headers: fields, allowance: RegexAllowance(), cache: PatternCache())
        #expect(untouched.headers == fields)
    }

    // MARK: storage

    @Test func theFlagIsOnlyWrittenWhenSet() throws {
        #expect(try json(HeaderEdit.set(name: "A", value: "b")) == #"{"set":{"name":"A","value":"b"}}"#)
        #expect(try json(QueryEdit.remove(name: "a")) == #"{"remove":{"name":"a"}}"#)
        #expect(try json(CookieEdit.set(name: "a", value: "b")) == #"{"set":{"name":"a","value":"b"}}"#)
        #expect(
            try json(HeaderEdit.set(name: "A", value: "b", nameCaseSensitive: true))
                == #"{"set":{"name":"A","nameCaseSensitive":true,"value":"b"}}"#)
        #expect(
            try json(QueryEdit.findReplace(name: nil, find: "a", replacement: "b", caseSensitive: true, nameCaseSensitive: false))
                .contains(#""nameCaseSensitive":false"#))
    }

    @Test func oldFilesDecodeWithNoFlagAndFlagsRoundTrip() throws {
        let old = Data(#"{"set":{"name":"A","value":"b"}}"#.utf8)
        #expect(try JSONDecoder().decode(HeaderEdit.self, from: old) == .set(name: "A", value: "b"))
        let oldQuery = Data(#"{"findReplace":{"find":"a","replacement":"b","caseSensitive":true}}"#.utf8)
        #expect(
            try JSONDecoder().decode(QueryEdit.self, from: oldQuery)
                == .findReplace(name: nil, find: "a", replacement: "b", caseSensitive: true))
        let edits: [HeaderEdit] = [
            .set(name: "A", value: "b", nameCaseSensitive: false), .remove(name: "A", nameCaseSensitive: true),
            .regex(name: "A", pattern: "x", replacement: "y", caseSensitive: false, nameCaseSensitive: true),
        ]
        let data = try JSONEncoder().encode(edits)
        #expect(try JSONDecoder().decode([HeaderEdit].self, from: data) == edits)
        let kind = ActionKind.modifyQuery(QueryEditAction(operations: [.remove(name: "a", nameCaseSensitive: false)]))
        #expect(try JSONDecoder().decode(ActionKind.self, from: JSONEncoder().encode(kind)) == kind)
        let cookies = ActionKind.editCookies(direction: .request, operations: [.remove(name: "a", nameCaseSensitive: false)])
        #expect(try JSONDecoder().decode(ActionKind.self, from: JSONEncoder().encode(cookies)) == cookies)
    }

    @Test func settingTheFlagKeepsTheRest() {
        let edit = HeaderEdit.regex(name: "A", pattern: "x", replacement: "y", caseSensitive: false)
        let flagged = edit.settingNameCaseSensitive(true)
        #expect(flagged.nameCaseSensitive == true && flagged.matchesNameExactly)
        #expect(flagged.settingNameCaseSensitive(nil) == edit)
        #expect(QueryEdit.add(name: "a", value: "b").matchesNameExactly)
        #expect(!QueryEdit.add(name: "a", value: "b", nameCaseSensitive: false).matchesNameExactly)
        #expect(CookieEdit.remove(name: "a").settingNameCaseSensitive(false).nameCaseSensitive == false)
    }
}
