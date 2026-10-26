import Foundation
import Testing
@testable import AppCore

/// One raw URL and what its query table must show. `query` is the raw query (between `?` and `#`).
@Suite(.productionChinese) struct RawQueryCase: Sendable, CustomTestStringConvertible {
    let label: String
    let url: String
    let query: String
    let rows: [EditableQueryRowExpectation]
    var testDescription: String { label }
}

@Suite(.productionChinese) struct EditableQueryRowExpectation: Equatable, Sendable {
    let name: String
    let value: String?
}

private func row(_ name: String, _ value: String?) -> EditableQueryRowExpectation {
    EditableQueryRowExpectation(name: name, value: value)
}

private let rawCases: [RawQueryCase] = [
    RawQueryCase(label: "repeated keys keep order", url: "https://h/p?a=1&a=2&b=3&a=4",
                 query: "a=1&a=2&b=3&a=4", rows: [row("a", "1"), row("a", "2"), row("b", "3"), row("a", "4")]),
    RawQueryCase(label: "empty value", url: "https://h/p?a=&b=2",
                 query: "a=&b=2", rows: [row("a", ""), row("b", "2")]),
    RawQueryCase(label: "no equals sign", url: "https://h/p?flag&x=1&flag",
                 query: "flag&x=1&flag", rows: [row("flag", nil), row("x", "1"), row("flag", nil)]),
    RawQueryCase(label: "%2F and %2f stay encoded", url: "https://h/p?b=%2F&c=%2f",
                 query: "b=%2F&c=%2f", rows: [row("b", "/"), row("c", "/")]),
    RawQueryCase(label: "plus is not rewritten", url: "https://h/p?x=a+b&y=%2B&z=%20",
                 query: "x=a+b&y=%2B&z=%20", rows: [row("x", "a+b"), row("y", "+"), row("z", " ")]),
    RawQueryCase(label: "non-ASCII raw and encoded", url: "https://h/p?q=é&r=%C3%A9&名=値",
                 query: "q=é&r=%C3%A9&名=値", rows: [row("q", "é"), row("r", "é"), row("名", "値")]),
    RawQueryCase(label: "trailing ampersand", url: "https://h/p?a=1&",
                 query: "a=1&", rows: [row("a", "1")]),
    RawQueryCase(label: "fragment is not part of the query", url: "https://h/p?a=1&b=2#frag?x=1&y",
                 query: "a=1&b=2", rows: [row("a", "1"), row("b", "2")]),
    RawQueryCase(label: "doubled and leading ampersands", url: "https://h/p?&a=1&&b=2",
                 query: "&a=1&&b=2", rows: [row("a", "1"), row("b", "2")]),
    RawQueryCase(label: "equals inside the value", url: "https://h/p?t=abc==&k=v=w",
                 query: "t=abc==&k=v=w", rows: [row("t", "abc=="), row("k", "v=w")]),
    RawQueryCase(label: "invalid escape shown raw", url: "https://h/p?bad=%ZZ&ok=%41",
                 query: "bad=%ZZ&ok=%41", rows: [row("bad", "%ZZ"), row("ok", "A")]),
    RawQueryCase(label: "question mark with empty query", url: "https://h/p?", query: "", rows: []),
]

@Suite(.productionChinese) struct EditableQueryTests {
    @Test(arguments: rawCases)
    func editableQueryRoundTripsRawBytes(_ testCase: RawQueryCase) {
        let draft = ComposeDraft(method: "GET", url: testCase.url)
        #expect(draft.url == testCase.url)
        #expect(draft.query.rawValue == testCase.query)
        #expect(draft.query.rows.map { row($0.name, $0.value) } == testCase.rows)
        let query = EditableQuery(raw: testCase.query)
        #expect(query.rawValue == testCase.query)
    }

    @Test func editingOneQueryRowReencodesOnlyThatRow() throws {
        var draft = ComposeDraft(method: "GET", url: "http://h/p?a=%2F&b=x+y&a=%2f&flag&n=%C3%A9#top")
        let second = try #require(draft.query.rows.dropFirst().first)
        draft.setQueryValue(second.id, "x y&z=é")
        #expect(draft.url == "http://h/p?a=%2F&b=x%20y%26z%3D%C3%A9&a=%2f&flag&n=%C3%A9#top")
        let edited = try #require(draft.query.rows.first { $0.id == second.id })
        // The table keeps exactly what was typed.
        #expect(edited.name == "b" && edited.value == "x y&z=é")

        let flag = try #require(draft.query.rows.first { $0.name == "flag" })
        draft.setQueryValue(flag.id, nil)
        #expect(draft.url == "http://h/p?a=%2F&b=x%20y%26z%3D%C3%A9&a=%2f&flag&n=%C3%A9#top")
        draft.setQueryValue(flag.id, "")
        #expect(draft.url == "http://h/p?a=%2F&b=x%20y%26z%3D%C3%A9&a=%2f&flag=&n=%C3%A9#top")

        // A key with reserved characters is encoded too; its value and the other rows stay byte-identical.
        let first = try #require(draft.query.rows.first)
        draft.setQueryName(first.id, "a b=")
        #expect(draft.url == "http://h/p?a%20b%3D=%2F&b=x%20y%26z%3D%C3%A9&a=%2f&flag=&n=%C3%A9#top")
        // Editing the other half back to its own text keeps its original escape (phase fix m1).
        draft.setQueryValue(first.id, "/")
        #expect(draft.url == "http://h/p?a%20b%3D=%2F&b=x%20y%26z%3D%C3%A9&a=%2f&flag=&n=%C3%A9#top")
        draft.setQueryValue(first.id, "//")
        #expect(draft.url == "http://h/p?a%20b%3D=%2F/&b=x%20y%26z%3D%C3%A9&a=%2f&flag=&n=%C3%A9#top")
    }

    @Test func urlAndQueryTableSyncBothWays() throws {
        var draft = ComposeDraft(method: "GET", url: "https://h/p?a=1&b=2")
        let ids = draft.query.rows.map(\.id)

        // URL → table: typing in the URL keeps the identity of every row in place.
        draft.setURL("https://h/p?a=12&b=2")
        #expect(draft.query.rows.map(\.id) == ids)
        #expect(draft.query.rows.map(\.value) == ["12", "2"])
        draft.setURL("https://h/p?a=12&b=2&c")
        #expect(Array(draft.query.rows.map(\.id).prefix(2)) == ids)
        #expect(draft.query.rows.last?.name == "c" && draft.query.rows.last?.value == nil)

        // Table → URL: an unfinished escape stays as typed in the table and is encoded in the URL.
        let b = try #require(draft.query.rows.first { $0.name == "b" })
        draft.setQueryValue(b.id, "50%")
        #expect(draft.url == "https://h/p?a=12&b=50%25&c")
        #expect(draft.query.rows.first { $0.id == b.id }?.value == "50%")
        draft.setQueryValue(b.id, "50% o")
        #expect(draft.url == "https://h/p?a=12&b=50%25%20o&c")
        #expect(draft.query.rows.map(\.id).prefix(2) == ids.prefix(2))

        // Adding and removing rows edits the URL; the fragment stays where it was.
        draft.setURL("https://h/p#frag")
        #expect(draft.query.rows.isEmpty)
        let added = draft.appendQueryRow(name: "k", value: "v w")
        #expect(draft.url == "https://h/p?k=v%20w#frag")
        draft.removeQueryRow(added)
        #expect(draft.url == "https://h/p#frag")

        // A URL typed back in place (as the URL field does) re-reads the rows from its bytes.
        draft.setURL("https://h/p?x=%2F#frag")
        #expect(draft.query.rows.map(\.value) == ["/"])
        #expect(draft.url == "https://h/p?x=%2F#frag")
    }

    /// Editing one cell re-encodes only that half of the row; the other half and the separators
    /// keep their exact bytes, including escapes whose decoded text would encode differently.
    @Test func editingOneHalfOfARowKeepsTheOtherHalfByteExact() throws {
        var draft = ComposeDraft(method: "GET", url: "http://h/p?q=a%2Bb&c=%2f&x=%E9&flag&e=&k%20y=v#f")
        func id(_ index: Int) -> UUID { draft.query.rows[index].id }

        // Name only: values `%2B`, `%2f` and the non-UTF-8 `%E9` are untouched.
        draft.setQueryName(id(0), "q2")
        draft.setQueryName(id(1), "c d")
        draft.setQueryName(id(2), "y")
        #expect(draft.url == "http://h/p?q2=a%2Bb&c%20d=%2f&y=%E9&flag&e=&k%20y=v#f")
        #expect(draft.query.rows[0].name == "q2" && draft.query.rows[0].value == "a+b")

        // A row without "=" stays without it when its name changes; an empty value stays empty.
        draft.setQueryName(id(3), "flag2")
        draft.setQueryName(id(4), "e2")
        #expect(draft.url == "http://h/p?q2=a%2Bb&c%20d=%2f&y=%E9&flag2&e2=&k%20y=v#f")
        #expect(draft.query.rows[3].value == nil && draft.query.rows[4].value == "")

        // Value only: the raw name `k%20y` is untouched.
        draft.setQueryValue(id(5), "w+x")
        #expect(draft.url == "http://h/p?q2=a%2Bb&c%20d=%2f&y=%E9&flag2&e2=&k%20y=w+x#f")
        draft.setQueryValue(id(2), "é")
        #expect(draft.url == "http://h/p?q2=a%2Bb&c%20d=%2f&y=%C3%A9&flag2&e2=&k%20y=w+x#f")
        // Giving a bare row a value adds "=" after its untouched name; nil removes it again.
        draft.setQueryValue(id(3), "1")
        #expect(draft.url == "http://h/p?q2=a%2Bb&c%20d=%2f&y=%C3%A9&flag2=1&e2=&k%20y=w+x#f")
        draft.setQueryValue(id(3), nil)
        #expect(draft.url == "http://h/p?q2=a%2Bb&c%20d=%2f&y=%C3%A9&flag2&e2=&k%20y=w+x#f")

        // Both halves of one row, and nothing of the others.
        draft.setQueryName(id(0), "q")
        draft.setQueryValue(id(0), "a b")
        #expect(draft.url == "http://h/p?q=a%20b&c%20d=%2f&y=%C3%A9&flag2&e2=&k%20y=w+x#f")
    }

    // MARK: Phase fix m1 — untouched characters keep their escapes

    @Test func appendingToAValueKeepsAnUntouchedPercent2B() throws {
        var draft = ComposeDraft(method: "GET", url: "https://h/p?q=a%2Bb&s=a%20b&m=a+b%2Bc")
        let rows = draft.query.rows
        #expect(rows.map(\.value) == ["a+b", "a b", "a+b+c"])
        draft.setQueryValue(rows[0].id, "a+bc")
        draft.setQueryValue(rows[1].id, "a bc")
        draft.setQueryValue(rows[2].id, "a+b+cd")
        // `%2B` stays `%2B` (never a form-decoded space), `%20` stays `%20`, a literal `+` stays `+`.
        #expect(draft.url == "https://h/p?q=a%2Bbc&s=a%20bc&m=a+b%2Bcd")
        #expect(draft.query.rows.map(\.value) == ["a+bc", "a bc", "a+b+cd"])
    }

    @Test func insertingAndDeletingInsideAValueReencodesOnlyTheChangedPart() throws {
        var draft = ComposeDraft(method: "GET", url: "https://h/p?q=a%2Bb%2Fc%C3%A9")
        let id = try #require(draft.query.rows.first).id
        #expect(draft.query.rows[0].value == "a+b/cé")
        draft.setQueryValue(id, "a+xb/cé")
        #expect(draft.url == "https://h/p?q=a%2Bxb%2Fc%C3%A9")
        draft.setQueryValue(id, "a+x b/cé")
        #expect(draft.url == "https://h/p?q=a%2Bx%20b%2Fc%C3%A9")
        draft.setQueryValue(id, "a+b/cé")
        #expect(draft.url == "https://h/p?q=a%2Bb%2Fc%C3%A9")
        // A newly typed `+` is the user's own `+`.
        draft.setQueryValue(id, "a+b/cé+")
        #expect(draft.url == "https://h/p?q=a%2Bb%2Fc%C3%A9+")
    }

    @Test func retypingTheOriginalTextRestoresTheOriginalBytes() throws {
        var draft = ComposeDraft(method: "GET", url: "https://h/p?a%2Bk=a%2Bb")
        let id = try #require(draft.query.rows.first).id
        // Deleting the `+` and typing it again gives back the original `%2B`, not a literal `+`.
        draft.setQueryValue(id, "ab")
        #expect(draft.url == "https://h/p?a%2Bk=ab")
        draft.setQueryValue(id, "a+b")
        #expect(draft.url == "https://h/p?a%2Bk=a%2Bb")
        draft.setQueryName(id, "")
        draft.setQueryName(id, "a+k")
        #expect(draft.url == "https://h/p?a%2Bk=a%2Bb")
        // Any other text containing `+` is not the original: the typed `+` is literal.
        draft.setQueryValue(id, "+")
        #expect(draft.url == "https://h/p?a%2Bk=+")
    }
}
