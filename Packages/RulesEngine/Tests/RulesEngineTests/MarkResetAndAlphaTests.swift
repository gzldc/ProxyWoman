import FlowStore
import Foundation
import Testing

@testable import RulesEngine

private let ruleID = UUID(uuidString: "00000000-0000-0000-0000-0000000000C1")!
private let runID = UUID(uuidString: "00000000-0000-0000-0000-00000000D001")!

private func makeFlow() -> Flow {
    Flow(id: 1, scheme: "https", method: "GET", host: "a.test", port: 443, path: "/")
}

private func target() -> HTTPMessageTarget {
    HTTPMessageTarget(scheme: "https", host: "a.test", port: 443, method: "GET", pathAndQuery: "/")
}

private func rule(_ name: String, _ mark: MarkAction, isFinal: Bool = false) -> Rule {
    Rule(
        id: UUID(), name: name, enabled: true, groupID: nil, order: 0, conditions: ConditionGroup(mode: .all, rows: []),
        actions: [RuleAction(.mark(mark), isFinal: isFinal)])
}

private func annotations(_ rules: Rule...) throws -> [FlowAnnotation] {
    let snapshot = RuleSnapshot(revision: 1, rules: rules)
    let cache = PatternCache(budget: RegexBudget(clock: { .zero }))
    return try RuleEvaluator.request(.request(target(), headers: []), snapshot: snapshot, hits: nil, cache: cache).annotations
}

private func connectAnnotations(_ rules: Rule...) -> [FlowAnnotation] {
    let cache = PatternCache(budget: RegexBudget(clock: { .zero }))
    return RuleEvaluator.connect(
        target: target(), snapshot: RuleSnapshot(revision: 1, rules: rules), tool: .decrypt, hits: nil, facts: ExchangeFacts(),
        allowance: RegexAllowance(), cache: cache
    ).annotations
}

/// What the recorder and Execute do with the annotations, in order.
private func applied(_ annotations: [FlowAnnotation]) -> FlowMark? {
    var mark: FlowMark?
    for annotation in annotations {
        switch annotation {
        case .mark(let new): mark = new
        case .resetMark(let background, let foreground): mark = FlowMark.reset(mark, background: background, foreground: foreground)
        case .comment, .hide: break
        }
    }
    return mark
}

@Suite("MarkResetAndAlpha")
struct MarkResetAndAlphaTests {
    // MARK: default clears

    @Test func defaultBackgroundClearsTheMarkAnEarlierRuleSet() throws {
        let first = rule("a", MarkAction(background: "#FF3B30", foreground: "#FFFFFF", text: "x"))
        let reset = rule("b", MarkAction(background: MarkAction.defaultColor))
        let list = try annotations(first, reset)
        #expect(list.count == 2)
        #expect(list.last == .resetMark(background: true, foreground: true))
        #expect(applied(list) == nil)
        // A later colour paints again.
        let again = rule("c", MarkAction(background: "#007AFF"))
        #expect(applied(try annotations(first, reset, again))?.background == "#007AFF")
        // And the Connect point gives the same annotations.
        #expect(connectAnnotations(first, reset).last == .resetMark(background: true, foreground: true))
    }

    @Test func defaultTextColourClearsOnlyTheTextColour() throws {
        let first = rule("a", MarkAction(background: "#FF3B30", foreground: "#FFFFFF", text: "x"))
        let reset = rule("b", MarkAction(background: MarkAction.unchangedColor, foreground: MarkAction.defaultColor))
        let list = try annotations(first, reset)
        #expect(list.last == .resetMark(background: false, foreground: true))
        let mark = try #require(applied(list))
        #expect(mark.background == "#FF3B30")
        #expect(mark.foreground == nil)
        #expect(mark.text == "x")
    }

    @Test func unchangedStillMeansUnchangedAndOldMarksAreAsBefore() throws {
        let first = rule("a", MarkAction(background: "#FF3B30"))
        let unchanged = rule("b", MarkAction(background: MarkAction.unchangedColor))
        let list = try annotations(first, unchanged)
        #expect(list.count == 1)
        #expect(applied(list)?.background == "#FF3B30")
        // A real background with a "default" text colour is the plain mark it always was.
        let plain = rule("c", MarkAction(background: "#FF3B30", foreground: MarkAction.defaultColor))
        let one = try annotations(plain)
        #expect(one.count == 1)
        #expect(MarkAction(background: "#FF3B30", foreground: MarkAction.defaultColor).colorReset == nil)
        #expect(MarkAction(background: "", foreground: "#FFFFFF").colorReset == nil)
    }

    @Test func resettingNothingStaysNothing() {
        #expect(FlowMark.reset(nil, background: true, foreground: true) == nil)
        #expect(FlowMark.reset(nil, background: false, foreground: true) == nil)
    }

    @Test func executeWriterAppliesTheReset() {
        var flow = makeFlow()
        let red = FlowMark(background: "#FF0000", foreground: "#FFFFFF", source: .rule(id: ruleID, name: "R"))!
        let result = ExecuteFlowResult(
            flowID: 1, matches: RuleMatchSummary(revision: 1, ruleIDs: [ruleID], total: 1),
            annotations: [.mark(red), .resetMark(background: false, foreground: true)], overlay: nil)
        ExecuteWriter.apply(result, runID: runID, at: Date(timeIntervalSince1970: 1), to: &flow)
        #expect(flow.ruleMark?.background == "#FF0000")
        #expect(flow.ruleMark?.foreground == nil)
        var cleared = makeFlow()
        let second = ExecuteFlowResult(
            flowID: 1, matches: RuleMatchSummary(revision: 1, ruleIDs: [ruleID], total: 1),
            annotations: [.mark(red), .resetMark(background: true, foreground: true)], overlay: nil)
        ExecuteWriter.apply(second, runID: runID, at: Date(timeIntervalSince1970: 1), to: &cleared)
        #expect(cleared.ruleMark == nil)
    }

    // MARK: eight-digit colours

    @Test func eightDigitColoursAreValidAndNormalised() throws {
        #expect(FlowMark.normalizedHex("#ffec1a4d") == "#FFEC1A4D")
        #expect(FlowMark.normalizedHex("ffec1a4d") == "#FFEC1A4D")
        #expect(FlowMark.normalizedHex("#FFEC1A") == "#FFEC1A")
        #expect(FlowMark.normalizedHex("#FFEC1A4") == nil)
        #expect(FlowMark.normalizedHex("#FFEC1A4DFF") == nil)
        #expect(FlowMark.normalizedHex("#GGEC1A4D") == nil)
        let mark = try #require(FlowMark(background: "#ffec1a4d", foreground: "#00000080", source: .manual))
        #expect(mark.background == "#FFEC1A4D")
        #expect(mark.foreground == "#00000080")
        // The 6-digit form is untouched.
        #expect(FlowMark(background: "#ff3b30", source: .manual)?.background == "#FF3B30")
    }

    @Test func engineAcceptsAndEmitsEightDigitMarks() throws {
        let rule = rule("t", MarkAction(background: "#ffec1a4d"))
        let list = try annotations(rule)
        guard case .mark(let mark)? = list.first else { Issue.record("no mark"); return }
        #expect(mark.background == "#FFEC1A4D")
        // Validation passes the new form and still fails a bad one.
        let valid = Rule(
            name: "v", conditions: ConditionGroup(mode: .all, rows: []),
            actions: [RuleAction(.mark(MarkAction(background: "#FFEC1A4D", foreground: "#00000080")))])
        #expect(throws: Never.self) { try valid.validate() }
        let bad = Rule(
            name: "v", conditions: ConditionGroup(mode: .all, rows: []),
            actions: [RuleAction(.mark(MarkAction(background: "#FFEC1A4")))])
        #expect(throws: RuleValidationError.self) { try bad.validate() }
    }

    @Test func savedSixDigitRulesRoundTripUnchanged() throws {
        let action = MarkAction(background: "#FFEC1A", foreground: "#000000", text: "t")
        let data = try JSONEncoder().encode(action)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"#FFEC1A\""))
        #expect(try JSONDecoder().decode(MarkAction.self, from: data) == action)
    }
}
