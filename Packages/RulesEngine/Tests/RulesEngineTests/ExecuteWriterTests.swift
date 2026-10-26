import FlowStore
import Foundation
import Testing

@testable import RulesEngine

private let ruleID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
private let otherRuleID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A2")!
private let runA = UUID(uuidString: "00000000-0000-0000-0000-00000000B001")!
private let runB = UUID(uuidString: "00000000-0000-0000-0000-00000000B002")!
private let date = Date(timeIntervalSince1970: 1_700_000_000)

private func makeFlow(_ id: Int = 1) -> Flow {
    Flow(id: id, startedAt: date, scheme: "https", method: "GET", host: "example.com", port: 443, path: "/\(id)")
}

private func ruleMark(_ background: String = "#FF0000", name: String = "R", id: UUID = ruleID) -> FlowMark {
    FlowMark(background: background, text: "t", source: .rule(id: id, name: name))!
}

private func summary(_ ids: [UUID] = [ruleID]) -> RuleMatchSummary {
    RuleMatchSummary(
        revision: 3, ruleIDs: ids, total: ids.count,
        outcomes: ids.map { RuleOutcome(ruleID: $0, code: .applied, actionIndex: 0) })
}

private func result(
    _ id: Int = 1, annotations: [FlowAnnotation], matches: RuleMatchSummary? = nil, overlay: ExecuteOverlay? = nil
) -> ExecuteFlowResult {
    ExecuteFlowResult(flowID: id, matches: matches ?? summary(), annotations: annotations, overlay: overlay)
}

private func overlayRequest() -> ExecuteOverlay {
    ExecuteOverlay(
        request: HTTPMessageSnapshot(
            boundary: .upstreamRequest,
            head: .request(
                HTTPMessageTarget(scheme: "https", host: "example.com", port: 443, method: "GET", pathAndQuery: "/x"),
                headers: []),
            bodyState: .complete, transferState: .finished))
}

private let appendX = FlowAnnotation.comment(CommentAction(mode: .append, text: "x"))

@Suite struct ExecuteWriterTests {
    @Test func applyWritesMarkCommentHideAndOverlay() {
        var flow = makeFlow()
        flow.comment = "base"
        let overlay = overlayRequest()
        ExecuteWriter.apply(
            result(annotations: [.mark(ruleMark()), appendX, .hide], overlay: overlay), runID: runA, at: date, to: &flow)
        #expect(flow.ruleMark?.background == "#FF0000")
        #expect(flow.comment == "base x")
        #expect(flow.isHidden)
        #expect(flow.executeOverlay == overlay)
        let record = flow.execute
        #expect(record?.runID == runA)
        #expect(record?.executedAt == date)
        #expect(record?.baseline == ExecuteFieldValues(ruleMark: nil, comment: "base", isHidden: false))
        #expect(record?.written == ExecuteFieldValues(ruleMark: flow.ruleMark, comment: "base x", isHidden: true))
    }

    @Test func markSourceIsExecuteWithTheRunID() {
        var flow = makeFlow()
        ExecuteWriter.apply(result(annotations: [.mark(ruleMark(name: "Paint"))]), runID: runA, to: &flow)
        #expect(flow.ruleMark?.source == .execute(runID: runA, ruleID: ruleID, ruleName: "Paint"))
        #expect(flow.displayMark?.source == .execute(runID: runA, ruleID: ruleID, ruleName: "Paint"))
    }

    @Test func secondRunStartsFromTheBaselineNotFromTheFirstResult() {
        var flow = makeFlow()
        flow.comment = "base"
        let first = result(annotations: [.mark(ruleMark("#111111")), appendX])
        ExecuteWriter.apply(first, runID: runA, to: &flow)
        ExecuteWriter.apply(first, runID: runB, to: &flow)
        #expect(flow.comment == "base x")
        #expect(flow.ruleMark?.background == "#111111")
        #expect(flow.execute?.runID == runB)
        #expect(flow.execute?.baseline.comment == "base")
        #expect(flow.execute?.baseline.ruleMark == nil)
    }

    @Test func userEditedCommentSurvivesRerunAndUndo() {
        var flow = makeFlow()
        flow.comment = "base"
        let run = result(annotations: [appendX])
        ExecuteWriter.apply(run, runID: runA, to: &flow)
        flow.comment = "mine"
        ExecuteWriter.apply(run, runID: runB, to: &flow)
        #expect(flow.execute?.baseline.comment == "mine")
        #expect(flow.comment == "mine x")
        #expect(ExecuteWriter.undo(&flow))
        #expect(flow.comment == "mine")
        #expect(flow.execute == nil)
    }

    @Test func undoRestoresOnlyFieldsStillAtWrittenValues() {
        var flow = makeFlow()
        flow.comment = "base"
        ExecuteWriter.apply(result(annotations: [.mark(ruleMark()), appendX]), runID: runA, to: &flow)
        flow.comment = "user"
        #expect(ExecuteWriter.undo(&flow))
        #expect(flow.ruleMark == nil)
        #expect(flow.comment == "user")
        #expect(flow.executeOverlay == nil)
        #expect(flow.execute == nil)
    }

    @Test func undoWithOtherRunIDIsANoOp() {
        var flow = makeFlow()
        ExecuteWriter.apply(result(annotations: [.mark(ruleMark()), .hide], overlay: overlayRequest()), runID: runA, to: &flow)
        let before = flow
        #expect(!ExecuteWriter.undo(&flow, onlyRun: runB))
        #expect(flow == before)
        #expect(ExecuteWriter.undo(&flow, onlyRun: runA))
        #expect(flow.ruleMark == nil && !flow.isHidden && flow.executeOverlay == nil)
    }

    @Test func undoWithoutRecordIsFalse() {
        var flow = makeFlow()
        #expect(!ExecuteWriter.undo(&flow))
        #expect(flow == makeFlow())
    }

    @Test func rerunWithNoMatchRestoresBaselineAndClearsRecord() {
        var flow = makeFlow()
        flow.comment = "base"
        ExecuteWriter.apply(
            result(annotations: [.mark(ruleMark()), appendX, .hide], overlay: overlayRequest()), runID: runA, to: &flow)
        ExecuteWriter.apply(ExecuteFlowResult(flowID: 1), runID: runB, to: &flow)
        #expect(flow.ruleMark == nil)
        #expect(flow.comment == "base")
        #expect(!flow.isHidden)
        #expect(flow.executeOverlay == nil)
        #expect(flow.execute == nil)
    }

    @Test func emptyResultWithoutRecordIsANoOp() {
        var flow = makeFlow()
        flow.comment = "c"
        let before = flow
        ExecuteWriter.apply(ExecuteFlowResult(flowID: 1), runID: runA, to: &flow)
        #expect(flow == before)
    }

    @Test func skippedResultsTouchNothing() {
        for skip in [ExecuteFlowResult.Skip.inProgress, .hidden] {
            var flow = makeFlow()
            ExecuteWriter.apply(result(annotations: [.mark(ruleMark()), .hide]), runID: runA, to: &flow)
            let before = flow
            var skipped = result(annotations: [.hide, appendX])
            skipped.skipped = skip
            ExecuteWriter.apply(skipped, runID: runB, to: &flow)
            #expect(flow == before)
            var fresh = makeFlow()
            ExecuteWriter.apply(skipped, runID: runB, to: &fresh)
            #expect(fresh == makeFlow())
        }
    }

    @Test func hideThenUndoRestoresVisibilityAndKeepsTheCountsStraight() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = FlowStore(bodyDirectory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ids = (0..<3).map { _ in store.begin { makeFlow($0) } }
        #expect(store.visibleFlowCount == 3)
        store.update(ids[1]) { ExecuteWriter.apply(result(ids[1], annotations: [.hide]), runID: runA, to: &$0) }
        #expect(store.visibleFlowCount == 2)
        #expect(store.visibleFlows().map(\.id) == [ids[0], ids[2]])
        #expect(store.flow(ids[1])?.isHidden == true)
        #expect(store.visibleFlowCount == store.visibleFlows().count)
        store.update(ids[1]) { _ = ExecuteWriter.undo(&$0, onlyRun: runA) }
        #expect(store.visibleFlowCount == 3)
        #expect(store.visibleFlows().map(\.id) == ids)
        #expect(store.flow(ids[1])?.isHidden == false)
    }

    @Test func manualMarkIsNeverTouched() {
        var flow = makeFlow()
        let manual = FlowMark(background: "#00FF00", source: .manual)!
        flow.manualMark = manual
        ExecuteWriter.apply(result(annotations: [.mark(ruleMark())]), runID: runA, to: &flow)
        #expect(flow.manualMark == manual)
        #expect(flow.displayMark == manual)
        _ = ExecuteWriter.undo(&flow)
        #expect(flow.manualMark == manual)
    }

    @Test func liveRuleMarkIsTheBaselineAndComesBackOnUndo() {
        var flow = makeFlow()
        let live = ruleMark("#0000FF", name: "Live", id: otherRuleID)
        flow.ruleMark = live
        #expect(ExecuteWriter.baseline(of: flow).ruleMark == live)
        ExecuteWriter.apply(result(annotations: [.mark(ruleMark())]), runID: runA, to: &flow)
        #expect(flow.ruleMark?.background == "#FF0000")
        #expect(ExecuteWriter.undo(&flow))
        #expect(flow.ruleMark == live)
        // A run that sets no mark keeps the live one.
        ExecuteWriter.apply(result(annotations: [appendX]), runID: runB, to: &flow)
        #expect(flow.ruleMark == live)
        #expect(flow.comment == "x")
    }

    @Test func provenanceAndRulesModifiedAreNeverTouched() {
        var flow = makeFlow()
        flow.provenance = .unknown
        flow.provenance.rulesModified = true
        flow.provenance.ruleMatches = summary([otherRuleID])
        let provenance = flow.provenance
        ExecuteWriter.apply(result(annotations: [.hide, appendX], overlay: overlayRequest()), runID: runA, to: &flow)
        #expect(flow.provenance == provenance)
        _ = ExecuteWriter.undo(&flow)
        #expect(flow.provenance == provenance)
    }

    @Test func recordMatchesAreStoredAsGiven() {
        var flow = makeFlow()
        let matches = summary([ruleID, otherRuleID])
        ExecuteWriter.apply(result(annotations: [.hide], matches: matches), runID: runA, to: &flow)
        #expect(flow.execute?.matches == matches)
    }
}
