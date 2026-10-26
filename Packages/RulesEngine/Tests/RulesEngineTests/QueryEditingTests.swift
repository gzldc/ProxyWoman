import Foundation
import Testing

@testable import RulesEngine

@Suite("QueryEditing")
struct QueryEditingTests {
    @Test func queryEditTouchesOnlyTheQuerySegment() {
        let result = QueryEditing.apply([.set(name: "a", value: "9")], to: "/p;x=1?a=1&b=2")
        #expect(result == "/p;x=1?a=9&b=2")
        #expect(Array(result.utf8.prefix(7)) == Array("/p;x=1?".utf8))
    }

    @Test func setCollapsesDuplicatesToTheFirstPosition() {
        #expect(QueryEditing.apply([.set(name: "a", value: "9")], to: "/p?a=1&b=2&a=3") == "/p?a=9&b=2")
    }

    @Test func setAppendsWhenMissing() {
        #expect(QueryEditing.apply([.set(name: "c", value: "3")], to: "/p?a=1") == "/p?a=1&c=3")
        #expect(QueryEditing.apply([.set(name: "c", value: "3")], to: "/p") == "/p?c=3")
    }

    @Test func addAlwaysAppends() {
        #expect(QueryEditing.apply([.add(name: "a", value: "2")], to: "/p?a=1") == "/p?a=1&a=2")
    }

    @Test func removeDropsEveryOccurrence() {
        #expect(QueryEditing.apply([.remove(name: "a")], to: "/p?a=1&b=2&a=3") == "/p?b=2")
    }

    @Test func removeLastParamDropsTheQuestionMark() {
        #expect(QueryEditing.apply([.remove(name: "a")], to: "/p?a=1") == "/p")
    }

    @Test func findReplaceOnValuesOnlyOfNamedParam() {
        let edit = QueryEdit.findReplace(name: "a", find: "x", replacement: "y", caseSensitive: true)
        #expect(QueryEditing.apply([edit], to: "/p?a=xx&x=x&b=x") == "/p?a=yy&x=x&b=x")
    }

    @Test func findReplaceHonoursCase() {
        let insensitive = QueryEdit.findReplace(name: "a", find: "X", replacement: "y", caseSensitive: false)
        #expect(QueryEditing.apply([insensitive], to: "/p?a=x") == "/p?a=y")
        let sensitive = QueryEdit.findReplace(name: "a", find: "X", replacement: "y", caseSensitive: true)
        #expect(QueryEditing.apply([sensitive], to: "/p?a=x") == "/p?a=x")
    }

    @Test func nilNameReplacesInEveryValue() {
        let edit = QueryEdit.findReplace(name: nil, find: "1", replacement: "9", caseSensitive: true)
        #expect(QueryEditing.apply([edit], to: "/p?a=1&b=21&flag") == "/p?a=9&b=29&flag")
    }

    @Test func namesMatchTheRawTextCaseSensitively() {
        #expect(QueryEditing.apply([.remove(name: "a")], to: "/p?A=1&a%20b=2&a=3") == "/p?A=1&a%20b=2")
        #expect(QueryEditing.apply([.set(name: "a b", value: "9")], to: "/p?a%20b=2") == "/p?a%20b=2&a b=9")
    }

    @Test func parameterWithoutEqualsIsKept() {
        #expect(QueryEditing.apply([.set(name: "a", value: "2")], to: "/p?flag&a=1") == "/p?flag&a=2")
        #expect(QueryEditing.apply([.set(name: "flag", value: "")], to: "/p?flag&a=1") == "/p?flag=&a=1")
        #expect(QueryEditing.apply([.remove(name: "flag")], to: "/p?flag&a=1") == "/p?a=1")
    }

    @Test func noChangeReturnsTheSameString() {
        #expect(QueryEditing.apply([.remove(name: "zz")], to: "/p?a=1&&b=2") == "/p?a=1&&b=2")
        #expect(QueryEditing.apply([.remove(name: "zz")], to: "/p?") == "/p?")
        #expect(QueryEditing.apply([], to: "/p?a=1") == "/p?a=1")
        #expect(QueryEditing.apply([.remove(name: "zz")], to: "/p") == "/p")
    }

    @Test func asteriskTargetIsLeftAlone() {
        #expect(QueryEditing.apply([.set(name: "a", value: "1")], to: "*") == "*")
    }

    @Test func editsApplyInOrder() {
        let edits: [QueryEdit] = [.add(name: "a", value: "1"), .set(name: "a", value: "2"), .add(name: "b", value: "3")]
        #expect(QueryEditing.apply(edits, to: "/p") == "/p?a=2&b=3")
    }

    @Test func validComponentRejectsSpaceHashControlAndNonASCII() {
        #expect(QueryEditing.isValidComponent("a-b_c.d~%20:/?@!$'()*+,;="))
        #expect(QueryEditing.isValidComponent(""))
        for bad in ["a b", "a#b", "a\u{1}b", "a\nb", "é", "a\u{7f}", "日本"] {
            #expect(!QueryEditing.isValidComponent(bad), "\(bad)")
        }
    }

    @Test func namesAndChangesAreByteWise() {
        let nfc = "\u{e9}", nfd = "e\u{301}"
        // Kelvin sign is not "K"; canonically equal names with other bytes do not match.
        #expect(QueryEditing.apply([.remove(name: "K")], to: "/p?\u{212A}=1") == "/p?\u{212A}=1")
        #expect(QueryEditing.apply([.remove(name: nfd)], to: "/p?\(nfc)=1") == "/p?\(nfc)=1")
        // Setting a canonically equal but byte-different value is a real change.
        #expect(QueryEditing.apply([.set(name: "a", value: nfd)], to: "/p?a=\(nfc)") == "/p?a=\(nfd)")
    }

    @Test func separatorsFollowedByCombiningMarksStillSplit() {
        let query = "/p?a=1&\u{301}b=2"
        #expect(QueryEditing.apply([.remove(name: "a")], to: query) == "/p?\u{301}b=2")
        #expect(QueryEditing.apply([.set(name: "a", value: "9")], to: query) == "/p?a=9&\u{301}b=2")
        #expect(QueryEditing.apply([.remove(name: "\u{301}b")], to: query) == "/p?a=1")
    }
}
