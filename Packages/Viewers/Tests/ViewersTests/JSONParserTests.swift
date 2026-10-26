import Foundation
import Testing

@testable import Viewers

@Suite(.productionChinese) struct JSONParserTests {
    private func parse(_ s: String) throws(JSONParseError) -> JSONNode {
        try JSONParser.parse(Data(s.utf8))
    }

    @Test func preservesKeyOrder() throws {
        let n = try parse(#"{"b":1,"a":2,"c":{"z":true,"y":null}}"#)
        guard case .object(let kv) = n else {
            Issue.record("expected object")
            return
        }
        #expect(kv.map(\.key) == ["b", "a", "c"])
        guard case .object(let inner) = kv[2].value else {
            Issue.record("expected nested object")
            return
        }
        #expect(inner.map(\.key) == ["z", "y"])
        #expect(inner[0].value == .bool(true))
        #expect(inner[1].value == .null)
    }

    @Test func duplicateKeysAreKept() throws {
        let n = try parse(#"{"a":1,"a":2}"#)
        guard case .object(let kv) = n else {
            Issue.record("expected object")
            return
        }
        #expect(kv.map(\.key) == ["a", "a"])
        #expect(kv.map(\.value) == [.number("1"), .number("2")])
    }

    @Test func equatableComparesKeyOrder() throws {
        #expect(try parse(#"{"a":1,"b":2}"#) == parse(#"{"a":1,"b":2}"#))
        #expect(try parse(#"{"a":1,"b":2}"#) != parse(#"{"b":2,"a":1}"#))
    }

    @Test func numbersKeepRawText() throws {
        let n = try parse("[1.0e10,-0,12345678901234567890]")
        #expect(
            n == .array([.number("1.0e10"), .number("-0"), .number("12345678901234567890")]))
    }

    @Test func invalidNumbersThrow() {
        for bad in ["01", "-", "1.", ".5", "1e", "1e+", "+1", "--1", "0x10", "[1.]", "NaN"] {
            #expect(throws: JSONParseError.self, "\(bad)") { try parse(bad) }
        }
    }

    @Test func scalarsAndWhitespace() throws {
        #expect(try parse(" \t\r\n true \n") == .bool(true))
        #expect(try parse("false") == .bool(false))
        #expect(try parse("null") == .null)
        #expect(try parse(#""hi""#) == .string("hi"))
        #expect(try parse("0") == .number("0"))
        #expect(try parse("[ ]") == .array([]))
        #expect(try parse("{ }") == .object([]))
    }

    @Test func leadingBOMIsAccepted() throws {
        var d = Data([0xEF, 0xBB, 0xBF])
        d.append(Data("[1]".utf8))
        #expect(try JSONParser.parse(d) == .array([.number("1")]))
    }

    @Test func unicodeEscapesAndSurrogates() throws {
        #expect(try parse(#""é😀\n""#) == .string("é😀\n"))
        #expect(try parse(#""\"\\\/\b\f\r\t""#) == .string("\"\\/\u{08}\u{0C}\r\t"))
        #expect(try parse(#""日本語 😀""#) == .string("日本語 😀"))
    }

    @Test func unpairedSurrogatesThrow() {
        for bad in [#""\ud83d""#, #""\ude00""#, #""\ud83dx""#, #""\ud83dA""#, #""\ud83d\ud83d""#] {
            #expect(throws: JSONParseError.self, "\(bad)") { try parse(bad) }
        }
    }

    @Test func badStringsThrow() {
        for bad in [#""abc"#, #""\x""#, #""\u12""#, #""\u12G4""#, "\"a\nb\"", "\"a\u{01}b\"", #""\"#] {
            #expect(throws: JSONParseError.self, "\(bad)") { try parse(bad) }
        }
    }

    @Test func invalidUTF8Throws() {
        #expect(throws: JSONParseError.self) { try JSONParser.parse(Data([0x22, 0xFF, 0x22])) }
    }

    @Test func invalidInputThrowsWithOffset() {
        do {
            _ = try parse("{\"a\":}")
            Issue.record("expected throw")
        } catch {
            #expect(error.offset == 5)
            #expect(!error.message.isEmpty)
        }
    }

    @Test func emptyInputThrows() {
        #expect(throws: JSONParseError.self) { try JSONParser.parse(Data()) }
        #expect(throws: JSONParseError.self) { try parse("   ") }
    }

    @Test func structuralErrorsThrow() {
        for bad in ["{", "[", "[1,]", "[1 2]", "{\"a\" 1}", "{\"a\":1,}", "{a:1}", "{1:2}", "[}", "tru", "nul"] {
            #expect(throws: JSONParseError.self, "\(bad)") { try parse(bad) }
        }
    }

    @Test func trailingGarbageThrows() {
        do {
            _ = try parse("{} x")
            Issue.record("expected throw")
        } catch {
            #expect(error.offset == 3)
        }
    }

    @Test func prettyPrint() throws {
        #expect(
            try parse(#"{"b":[1,{"x":"s"}],"a":{}}"#).prettyPrinted()
                == "{\n  \"b\": [\n    1,\n    {\n      \"x\": \"s\"\n    }\n  ],\n  \"a\": {}\n}")
    }

    @Test func prettyPrintEmptyAndScalars() throws {
        #expect(try parse("{}").prettyPrinted() == "{}")
        #expect(try parse("[]").prettyPrinted() == "[]")
        #expect(try parse("[[],{}]").prettyPrinted() == "[\n  [],\n  {}\n]")
        #expect(try parse("null").prettyPrinted() == "null")
        #expect(try parse("-0").prettyPrinted() == "-0")
        #expect(try parse("true").prettyPrinted() == "true")
        #expect(try parse("[1]").prettyPrinted(indent: 4) == "[\n    1\n]")
    }

    @Test func prettyPrintEscapesMinimally() throws {
        let n = try parse(#"{"k\"":"a\"b\\c\/d\n\r\t\b\f\u0001é😀"}"#)
        #expect(
            n.prettyPrinted()
                == "{\n  \"k\\\"\": \"a\\\"b\\\\c/d\\n\\r\\t\\b\\f\\u0001é😀\"\n}")
    }

    @Test func prettyPrintRoundTrips() throws {
        let src = #"{"b":[1,2.5e3,"x\u0000y",null,{"q":[]}],"a":{"é":false}}"#
        let n = try parse(src)
        #expect(try parse(n.prettyPrinted()) == n)
    }

    @Test func deepNestingDoesNotCrash() {
        for opener in ["[", #"{"a":"#] {
            let s = String(repeating: opener, count: 10_000)
            do {
                _ = try parse(s)
                Issue.record("expected throw")
            } catch {
                #expect(error.message.contains("nesting depth"))
            }
        }
    }

    @Test func nestingAtLimitSucceedsAndBeyondFails() throws {
        func nested(_ n: Int) -> String {
            String(repeating: "[", count: n) + String(repeating: "]", count: n)
        }
        _ = try parse(nested(512))
        #expect(throws: JSONParseError.self) { try parse(nested(513)) }
    }

    /// Runs `body` on a thread with a 512 KB stack (the size of Swift Testing / Swift concurrency workers).
    private func onSmallStack(_ body: @escaping @Sendable () -> Void) {
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            body()
            done.signal()
        }
        thread.stackSize = 512 * 1024
        thread.start()
        done.wait()
    }

    @Test func deepValuesSurviveEqualityPrintingAndDeallocOnSmallStack() {
        @Sendable func deep(_ kind: Int) -> String {
            var open = "", close = ""
            for i in 0..<512 {
                let isObject = kind == 1 || (kind == 2 && i % 2 == 0)
                open += isObject ? #"{"a":"# : "["
                close += isObject ? "}" : "]"
            }
            return open + "null" + String(close.reversed())
        }
        let ok = ResultBox()
        onSmallStack {
            do {
                for kind in 0...2 {
                    let a = try JSONParser.parse(Data(deep(kind).utf8))
                    let b = try JSONParser.parse(Data(deep(kind).utf8))
                    guard a == b, a.prettyPrinted().utf8.count > 512 else { return }
                }
                ok.value = true
            } catch {}
        }
        #expect(ok.value)
    }

    @Test func largeFlatContainersParseInLinearTime() throws {
        let n = 100_000
        let array = "[" + (0..<n).map(String.init).joined(separator: ",") + "]"
        let object = "{" + (0..<n).map { "\"k\($0)\":\($0)" }.joined(separator: ",") + "}"
        for src in [array, object] {
            let start = ContinuousClock.now
            let node = try parse(src)
            let elapsed = ContinuousClock.now - start
            #expect(elapsed < .seconds(2), "took \(elapsed)")
            switch node {
            case .array(let items): #expect(items.count == n)
            case .object(let members): #expect(members.count == n)
            default: Issue.record("unexpected node")
            }
        }
    }
}

private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool {
        get { lock.withLock { flag } }
        set { lock.withLock { flag = newValue } }
    }
}
