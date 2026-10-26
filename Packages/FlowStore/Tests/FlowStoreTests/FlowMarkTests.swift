import Foundation
import Testing

@testable import FlowStore

private func makeFlow(_ id: Int = 1) -> Flow {
    Flow(id: id, scheme: "https", method: "GET", host: "h", port: 443, path: "/")
}

@Suite struct FlowMarkTests {
    @Test func normalizedHexAcceptsSixDigitsWithOrWithoutHash() {
        #expect(FlowMark.normalizedHex("#ff3b30") == "#FF3B30")
        #expect(FlowMark.normalizedHex("FF3B30") == "#FF3B30")
        #expect(FlowMark.normalizedHex("#fff") == nil)
        #expect(FlowMark.normalizedHex("#GG0000") == nil)
        #expect(FlowMark.normalizedHex("") == nil)
        #expect(FlowMark.normalizedHex("#FF3B30 ") == nil)
    }

    @Test func normalizedHexAcceptsEightDigitsWithOpacity() throws {
        #expect(FlowMark.normalizedHex("#ffec1a4d") == "#FFEC1A4D")
        #expect(FlowMark.normalizedHex("FFEC1A4D") == "#FFEC1A4D")
        #expect(FlowMark.normalizedHex("#FFEC1A4") == nil)
        #expect(FlowMark.normalizedHex("#FFEC1A4DAA") == nil)
        #expect(FlowMark.normalizedHex("#FFEC1AZZ") == nil)
        let mark = try #require(FlowMark(background: "#ffec1a4d", foreground: "#00000080", source: .manual))
        #expect(mark.background == "#FFEC1A4D" && mark.foreground == "#00000080")
    }

    @Test func resetClearsTheBackgroundOrTheTextColour() throws {
        let mark = try #require(FlowMark(background: "#FF0000", foreground: "#FFFFFF", text: "t", source: .manual))
        #expect(FlowMark.reset(mark, background: true, foreground: false) == nil)
        #expect(FlowMark.reset(mark, background: true, foreground: true) == nil)
        let plain = try #require(FlowMark.reset(mark, background: false, foreground: true))
        #expect(plain.background == "#FF0000" && plain.foreground == nil && plain.text == "t")
        #expect(FlowMark.reset(mark, background: false, foreground: false) == mark)
        #expect(FlowMark.reset(nil, background: true, foreground: true) == nil)
    }

    @Test func initRejectsABadColourAndCutsLongText() throws {
        #expect(FlowMark(background: "red", source: .manual) == nil)
        #expect(FlowMark(background: "#FF0000", foreground: "x", source: .manual) == nil)
        let wide = try #require(
            FlowMark(background: "#ff0000", text: String(repeating: "é", count: 200), source: .manual))
        #expect(wide.text?.utf8.count == 256)
        #expect(wide.text?.count == 128)
        let ascii = try #require(
            FlowMark(background: "#ff0000", text: String(repeating: "a", count: 300), source: .manual))
        #expect(ascii.text?.utf8.count == 256)
        #expect(ascii.background == "#FF0000")
    }

    @Test func emptyTextBecomesNil() throws {
        let mark = try #require(FlowMark(background: "#00FF00", text: "", source: .manual))
        #expect(mark.text == nil)
    }

    @Test func flowDefaultsAreEmpty() {
        let flow = makeFlow()
        #expect(flow.ruleMark == nil)
        #expect(flow.manualMark == nil)
        #expect(flow.comment == nil)
        #expect(flow.isHidden == false)
        #expect(flow.displayMark == nil)
    }

    @Test func manualMarkWinsOverRuleMark() throws {
        var flow = makeFlow()
        let rule = try #require(FlowMark(background: "#111111", source: .rule(id: UUID(), name: "r")))
        let manual = try #require(FlowMark(background: "#222222", source: .manual))
        flow.ruleMark = rule
        #expect(flow.displayMark == rule)
        flow.manualMark = manual
        #expect(flow.displayMark == manual)
        flow.manualMark = nil
        #expect(flow.displayMark == rule)
    }

    @Test func executeSourceMarkRoundTripsThroughDisplayMark() throws {
        var flow = makeFlow()
        let executeMark = try #require(
            FlowMark(background: "#333333", source: .execute(runID: UUID(), ruleID: UUID(), ruleName: "r")))
        let manual = try #require(FlowMark(background: "#222222", source: .manual))
        flow.ruleMark = executeMark
        #expect(flow.displayMark == executeMark)
        flow.manualMark = manual
        #expect(flow.displayMark == manual)
        flow.manualMark = nil
        #expect(flow.displayMark == executeMark)
    }

    @Test func limitedCommentCutsAtACharacterBoundary() {
        #expect(Flow.limitedComment(String(repeating: "a", count: 5000))?.utf8.count == 4096)
        let wide = Flow.limitedComment(String(repeating: "é", count: 3000))
        #expect((wide?.utf8.count ?? .max) <= 4096)
        #expect(wide?.count == 2048)
        #expect(Flow.limitedComment("") == nil)
        #expect(Flow.limitedComment("  \n") == nil)
        #expect(Flow.limitedComment(nil) == nil)
        #expect(Flow.limitedComment("  hi ") == "  hi ")
    }
}
