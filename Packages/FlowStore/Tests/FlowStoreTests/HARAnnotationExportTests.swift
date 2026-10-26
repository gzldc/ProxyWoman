import Foundation
import Testing

@testable import FlowStore

@Suite struct HARAnnotationExportTests {
    @Test func flowWithoutAnnotationsExportsTheSameKeysAsBefore() throws {
        let flow = makeFlow(host: "example.com", path: "/plain")
        let entry = try #require(try harEntries(export([flow])).first)
        #expect(entry["comment"] == nil)
        let metadata = try #require(entry["_proxywoman"] as? [String: Any])
        #expect(metadata["mark"] == nil)
        let provenance = try #require(metadata["provenance"] as? [String: Any])
        #expect(provenance["rulesModified"] == nil)
        #expect(Set(entry.keys) == ["startedDateTime", "time", "request", "response", "cache", "timings", "_proxywoman"])
    }

    @Test func commentIsWrittenAsTheEntryComment() throws {
        var flow = makeFlow(host: "example.com", path: "/commented")
        flow.comment = "check the retry"
        let entry = try #require(try harEntries(export([flow])).first)
        #expect(entry["comment"] as? String == "check the retry")
    }

    @Test func manualMarkIsWrittenWithItsSource() throws {
        var flow = makeFlow(host: "example.com", path: "/manual")
        flow.manualMark = mark(background: "#ff3b30", foreground: "#ffffff", text: "slow", source: .manual)
        let entry = try #require(try harEntries(export([flow])).first)
        let metadata = try #require(entry["_proxywoman"] as? [String: Any])
        let mark = try #require(metadata["mark"] as? [String: Any])
        #expect(mark as NSDictionary == [
            "background": "#FF3B30",
            "foreground": "#FFFFFF",
            "source": "manual",
            "text": "slow",
        ] as NSDictionary)
    }

    @Test func ruleMarkIsWrittenWithRuleIDAndName() throws {
        var flow = makeFlow(host: "example.com", path: "/rule")
        let ruleID = UUID()
        flow.ruleMark = mark(background: "#00ff00", source: .rule(id: ruleID, name: "Slow API"))
        let entry = try #require(try harEntries(export([flow])).first)
        let metadata = try #require(entry["_proxywoman"] as? [String: Any])
        let mark = try #require(metadata["mark"] as? [String: Any])
        #expect(mark as NSDictionary == [
            "background": "#00FF00",
            "source": "rule",
            "ruleID": ruleID.uuidString,
            "ruleName": "Slow API",
        ] as NSDictionary)
        #expect(mark["foreground"] == nil)
        #expect(mark["text"] == nil)
    }

    @Test func manualMarkWinsInTheExport() throws {
        var flow = makeFlow(host: "example.com", path: "/both")
        flow.ruleMark = mark(background: "#111111", source: .rule(id: UUID(), name: "r"))
        flow.manualMark = mark(background: "#222222", source: .manual)
        let entry = try #require(try harEntries(export([flow])).first)
        let mark = try #require((entry["_proxywoman"] as? [String: Any])?["mark"] as? [String: Any])
        #expect(mark["source"] as? String == "manual")
        #expect(mark["background"] as? String == "#222222")
    }

    @Test func rulesModifiedIsWrittenOnlyWhenTrue() throws {
        var modified = makeFlow(host: "example.com", path: "/changed")
        modified.provenance = FlowProvenance(rulesModified: true)
        var untouched = makeFlow(id: 2, host: "example.com", path: "/same")
        untouched.provenance = FlowProvenance(rulesModified: false)
        let entries = try harEntries(export([modified, untouched]))
        let changedProvenance = try #require((entries[0]["_proxywoman"] as? [String: Any])?["provenance"] as? [String: Any])
        #expect(changedProvenance["rulesModified"] as? Bool == true)
        let sameProvenance = try #require((entries[1]["_proxywoman"] as? [String: Any])?["provenance"] as? [String: Any])
        #expect(sameProvenance["rulesModified"] == nil)
    }

    @Test func harWritesExecuteMarkSourceAndSummary() throws {
        let baseline = try export([makeFlow(host: "example.com", path: "/e")])
        var flow = makeFlow(host: "example.com", path: "/e")
        let runID = UUID()
        let ruleID = UUID()
        flow.ruleMark = mark(background: "#00ff00", source: .execute(runID: runID, ruleID: ruleID, ruleName: "Tag"))
        let summary = RuleMatchSummary(revision: 3, ruleIDs: [ruleID], total: 1)
        let values = ExecuteFieldValues()
        flow.execute = ExecuteRecord(
            runID: runID, executedAt: Date(timeIntervalSince1970: 1), matches: summary, baseline: values, written: values)
        func parts(_ flow: Flow) throws -> (mark: [String: Any], execute: [String: Any]) {
            let entry = try #require(try harEntries(export([flow])).first)
            let metadata = try #require(entry["_proxywoman"] as? [String: Any])
            let provenance = try #require(metadata["provenance"] as? [String: Any])
            return (
                try #require(metadata["mark"] as? [String: Any]), try #require(provenance["execute"] as? [String: Any]))
        }
        let recordOnly = try parts(flow)
        #expect(recordOnly.mark as NSDictionary == [
            "background": "#00FF00", "source": "execute", "ruleID": ruleID.uuidString, "ruleName": "Tag",
            "runID": runID.uuidString,
        ] as NSDictionary)
        #expect(recordOnly.execute as NSDictionary == [
            "runID": runID.uuidString, "ruleIDs": [ruleID.uuidString], "modified": false,
        ] as NSDictionary)
        flow.executeOverlay = ExecuteOverlay(
            response: HTTPMessageSnapshot(
                boundary: .downstreamResponse, head: .response(status: 200, reason: nil, headers: [])))
        #expect(try parts(flow).execute["modified"] as? Bool == true)
        // Without an Execute record the export is byte-identical to the baseline.
        #expect(try export([makeFlow(host: "example.com", path: "/e")]) == baseline)
        let plain = try #require(try harEntries(baseline).first)
        let provenance = try #require((plain["_proxywoman"] as? [String: Any])?["provenance"] as? [String: Any])
        #expect(provenance["execute"] == nil)
    }

    @Test func hiddenFlowsAreExcludedByDefaultAndIncludedOnRequest() throws {
        let visible = makeFlow(id: 1, host: "example.com", path: "/a")
        var hidden = makeFlow(id: 2, host: "example.com", path: "/b")
        hidden.isHidden = true
        let another = makeFlow(id: 3, host: "example.com", path: "/c")
        let flows = [visible, hidden, another]
        #expect(try harEntries(export(flows)).count == 2)
        #expect(try harEntries(export(flows, includeHidden: true)).count == 3)
    }

    @Test func exportIsTheOriginalRecordNotTheMarkedOne() throws {
        var plain = makeFlow(host: "example.com", path: "/record")
        plain.requestHeaders = [.init(name: "X-Req", value: "1")]
        plain.responseHeaders = [.init(name: "X-Resp", value: "2")]
        var marked = plain
        marked.comment = "note"
        marked.manualMark = mark(background: "#abcdef", text: "tag", source: .manual)
        marked.ruleMark = mark(background: "#123456", source: .rule(id: UUID(), name: "r"))
        marked.provenance = FlowProvenance(rulesModified: true)
        let plainEntry = try #require(try harEntries(export([plain])).first)
        let markedEntry = try #require(try harEntries(export([marked])).first)
        #expect(markedEntry["request"] as? NSDictionary == plainEntry["request"] as? NSDictionary)
        #expect(markedEntry["response"] as? NSDictionary == plainEntry["response"] as? NSDictionary)
    }

    @Test func exportsKeepTheOriginalRecord() throws {
        var plain = makeFlow(host: "example.com", path: "/overlay")
        plain.requestHeaders = [.init(name: "X-Req", value: "1")]
        plain.statusCode = 200
        plain.responseHeaders = [.init(name: "X-Resp", value: "2")]
        var overlaid = plain
        overlaid.executeOverlay = ExecuteOverlay(
            request: HTTPMessageSnapshot(
                boundary: .upstreamRequest,
                head: .request(
                    HTTPMessageTarget(scheme: "https", host: "other.test", port: 443, method: "POST", pathAndQuery: "/x"),
                    headers: [.init(name: "X-Changed", value: "1")])),
            response: HTTPMessageSnapshot(
                boundary: .downstreamResponse,
                head: .response(status: 404, reason: "Nope", headers: [.init(name: "X-Changed", value: "2")])))
        #expect(try export([overlaid]) == export([plain]))
        #expect(CurlExporter.command(for: overlaid) == CurlExporter.command(for: plain))
    }

    private func mark(background: String, foreground: String? = nil, text: String? = nil, source: FlowMark.Source) -> FlowMark {
        // The literal inputs are valid hex colours, so the failable initializer cannot fail here.
        FlowMark(background: background, foreground: foreground, text: text, source: source)!
    }

    private func export(_ flows: [Flow], includeHidden: Bool = false) throws -> Data {
        try HARExporter.export(flows, creatorName: "Test", creatorVersion: "1", includeHidden: includeHidden)
    }

    private func makeFlow(id: Int = 1, host: String, path: String) -> Flow {
        var flow = Flow(id: id, startedAt: Date(timeIntervalSince1970: 1_700_000_000.5),
                        scheme: "https", method: "GET", host: host, port: 443, path: path)
        flow.transport = .init(downstreamRequest: .http1_1, downstreamResponse: .http1_1)
        return flow
    }

    private func harEntries(_ data: Data) throws -> [[String: Any]] {
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require((root["log"] as? [String: Any])?["entries"] as? [[String: Any]])
    }
}
