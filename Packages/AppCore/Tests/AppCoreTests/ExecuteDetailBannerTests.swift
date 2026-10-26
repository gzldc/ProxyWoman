import FlowStore
import Foundation
import Testing

@testable import AppCore

private func flow(overlay: ExecuteOverlay?, record: Bool) -> Flow {
    var flow = Flow(id: 1, scheme: "https", method: "GET", host: "a.test", port: 443, path: "/")
    flow.executeOverlay = overlay
    if record {
        flow.execute = ExecuteRecord(
            runID: UUID(), executedAt: Date(timeIntervalSince1970: 1),
            matches: RuleMatchSummary(revision: 1, ruleIDs: [], total: 0),
            baseline: ExecuteFieldValues(), written: ExecuteFieldValues(comment: "x"))
    }
    return flow
}

@Suite(.productionChinese) struct ExecuteDetailBannerTests {
    @Test func bannerKindsFollowTheRecord() {
        let response = HTTPMessageSnapshot(boundary: .downstreamResponse, head: .response(status: 200, reason: nil, headers: []))
        #expect(ExecuteDetailBanner.of(flow(overlay: ExecuteOverlay(response: response), record: true))
            == ExecuteDetailBanner(kind: .modified, canCompare: true))
        #expect(ExecuteDetailBanner.of(flow(overlay: nil, record: true))
            == ExecuteDetailBanner(kind: .recordOnly, canCompare: false))
        #expect(ExecuteDetailBanner.of(flow(overlay: ExecuteOverlay(), record: true))?.kind == .recordOnly)
        #expect(ExecuteDetailBanner.of(flow(overlay: nil, record: false)) == nil)
    }
}
