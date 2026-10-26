import Foundation
import Testing

@testable import MCPWire

@Suite struct JSONValueTests {
    @Test func roundTripsNestedValues() throws {
        let value: JSONValue = .object([
            "null": .null,
            "yes": .bool(true),
            "int": .int(-42),
            "big": .int(Int.max),
            "double": .double(1.5),
            "text": .string("héllo \u{1F600} \"quoted\" \\ /"),
            "list": .array([.int(1), .string("two"), .array([]), .object([:])]),
            "nested": .object(["a": .object(["b": .array([.null, .bool(false)])])]),
        ])
        let data = try value.encoded()
        #expect(try JSONValue.parse(data) == value)
    }

    @Test func encodedIsSingleLineWithSortedKeys() throws {
        let value: JSONValue = .object([
            "b": .string("line1\nline2\r\ttab"),
            "a": .int(1),
            "c": .array([.string("x\ny")]),
        ])
        let data = try value.encoded()
        #expect(!data.contains(0x0A))
        #expect(!data.contains(0x0D))
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text == #"{"a":1,"b":"line1\nline2\r\ttab","c":["x\ny"]}"#)
        // The escaped newline still decodes back to the original string.
        #expect(try JSONValue.parse(data)["b"]?.stringValue == "line1\nline2\r\ttab")
    }

    @Test func parseRejectsTrailingGarbage() {
        #expect(throws: (any Error).self) { try JSONValue.parse(Data(#"{"a":1} x"#.utf8)) }
        #expect(throws: (any Error).self) { try JSONValue.parse(Data(#"{"a":1}{"b":2}"#.utf8)) }
        #expect(throws: (any Error).self) { try JSONValue.parse(Data("".utf8)) }
        #expect(throws: (any Error).self) { try JSONValue.parse(Data(#"{"a":"#.utf8)) }
    }

    @Test func accessorsReturnOnlyMatchingCases() {
        let value: JSONValue = .object([
            "s": .string("x"), "i": .int(3), "b": .bool(true),
            "a": .array([.null]), "o": .object(["k": .int(1)]),
        ])
        #expect(value["s"]?.stringValue == "x")
        #expect(value["i"]?.intValue == 3)
        #expect(value["b"]?.boolValue == true)
        #expect(value["a"]?.arrayValue == [.null])
        #expect(value["o"]?.objectValue == ["k": .int(1)])
        #expect(value["s"]?.intValue == nil)
        #expect(value["i"]?.stringValue == nil)
        #expect(value["missing"] == nil)
        #expect(JSONValue.array([])["s"] == nil)
        #expect(JSONValue.string("x")["s"] == nil)
    }

    @Test func nonFiniteDoubleFailsToEncode() {
        #expect(throws: (any Error).self) { try JSONValue.double(.nan).encoded() }
        #expect(throws: (any Error).self) { try JSONValue.double(.infinity).encoded() }
    }

    @Test func integersAndDoublesStayDistinct() throws {
        #expect(try JSONValue.parse(Data("7".utf8)) == .int(7))
        #expect(try JSONValue.parse(Data("7.25".utf8)) == .double(7.25))
        #expect(try JSONValue.parse(Data("true".utf8)) == .bool(true))
        #expect(try JSONValue.parse(Data("null".utf8)) == .null)
    }
}
