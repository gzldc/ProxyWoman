import Foundation
import Testing

@testable import Viewers

@Suite(.productionChinese) struct JSONTreeItemTests {
    private func parse(_ text: String) throws -> JSONNode {
        try JSONParser.parse(Data(text.utf8))
    }

    @Test func rootsAreTheTopLevelMembersInOriginalOrder() throws {
        let roots = JSONTreeItem.roots(for: try parse(#"{"z":1,"a":"s","z":null}"#))
        #expect(roots.map(\.label) == ["z", "a", "z"])
        #expect(Set(roots.map(\.id)).count == 3)
        #expect(roots.map(\.summary) == ["1", "\"s\"", "null"])
        #expect(roots.allSatisfy { $0.children == nil })
    }

    @Test func containersExposeChildrenLazilyWithUniqueIDs() throws {
        let roots = JSONTreeItem.roots(for: try parse(#"[{"k":[1,2]},{"k":[3]}]"#))
        #expect(roots.map(\.label) == ["[0]", "[1]"])
        #expect(roots.map(\.summary) == ["{1}", "{1}"])
        let first = try #require(roots[0].children)
        let second = try #require(roots[1].children)
        #expect(first[0].label == "k")
        #expect(first[0].summary == "[2]")
        let leaves = Array(try #require(first[0].children)) + Array(try #require(second[0].children))
        #expect(leaves.map(\.summary) == ["1", "2", "3"])
        let ids = roots.map(\.id) + first.map(\.id) + second.map(\.id) + leaves.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func emptyContainersAreLeaves() throws {
        let roots = JSONTreeItem.roots(for: try parse(#"{"o":{},"a":[]}"#))
        #expect(roots.map(\.summary) == ["{}", "[]"])
        #expect(roots.allSatisfy { $0.children == nil })
    }

    @Test func emptyRootIsShownAsOneItem() throws {
        let roots = JSONTreeItem.roots(for: try parse("{}"))
        #expect(roots.count == 1)
        #expect(roots[0].label == nil)
        #expect(roots[0].summary == "{}")
    }

    @Test func copyTextIsUnquotedForStringsAndPrettyForContainers() throws {
        let roots = JSONTreeItem.roots(for: try parse(#"{"s":"a\"b","n":1.50,"o":{"x":true}}"#))
        #expect(roots[0].copyText == "a\"b")
        #expect(roots[0].summary == #""a\"b""#)
        #expect(roots[1].copyText == "1.50")
        #expect(roots[2].copyText == "{\n  \"x\": true\n}")
    }

    @Test func longScalarSummaryIsCapped() throws {
        let long = String(repeating: "x", count: 5000)
        let roots = JSONTreeItem.roots(for: try parse(#"{"s":""# + long + #"","n":"# + String(repeating: "9", count: 5000) + "}"))
        #expect(roots[0].summary == "\"" + String(repeating: "x", count: JSONTreeItem.summaryLimit) + "…")
        #expect(roots[1].summary == String(repeating: "9", count: JSONTreeItem.summaryLimit) + "…")
        #expect(roots[0].copyText == long)
    }

    @Test func valueKinds() throws {
        let roots = JSONTreeItem.roots(for: try parse(#"["s",1,true,null,{},[]]"#))
        #expect(roots.map(\.kind) == [.string, .number, .bool, .null, .object, .array])
    }
}
