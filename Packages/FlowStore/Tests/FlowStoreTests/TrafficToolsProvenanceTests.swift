import Foundation
import Testing

@testable import FlowStore

@Suite struct TrafficToolsProvenanceTests {
    @Test func mergingKeepsOlderAndOverridesWithNewer() {
        let id = UUID()
        let older = TrafficToolsProvenance(networkCondition: "custom")
        let newer = TrafficToolsProvenance(blockedByEntry: id, noCaching: true, networkCondition: "preset.edge")
        let merged = older.merging(newer)
        #expect(merged.blockedByEntry == id)
        #expect(merged.noCaching)
        #expect(merged.networkCondition == "preset.edge")
        #expect(merged.repeatRun == nil)

        let kept = TrafficToolsProvenance(networkCondition: "custom").merging(TrafficToolsProvenance())
        #expect(kept.networkCondition == "custom")
        #expect(kept.noCaching == false)
    }

    @Test func emptyDetectsDefaults() {
        #expect(TrafficToolsProvenance().isEmpty)
        #expect(!TrafficToolsProvenance(blockedByEntry: UUID()).isEmpty)
        #expect(!TrafficToolsProvenance(noCaching: true).isEmpty)
        #expect(!TrafficToolsProvenance(networkCondition: "preset.threeG").isEmpty)
        #expect(!TrafficToolsProvenance(repeatRun: RepeatRunTag(runID: UUID(), index: 1, total: 2)).isEmpty)
    }

    @Test func codableRoundTrip() throws {
        let value = TrafficToolsProvenance(
            blockedByEntry: UUID(), noCaching: true, networkCondition: "preset.lte",
            repeatRun: RepeatRunTag(runID: UUID(), index: 3, total: 5))
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(TrafficToolsProvenance.self, from: data)
        #expect(decoded == value)
        #expect(decoded.repeatRun?.index == 3)
        #expect(decoded.repeatRun?.total == 5)
    }

    @Test func provenanceEqualityIncludesTools() {
        #expect(FlowProvenance(tools: .init(noCaching: true)) != .passive)
        #expect(FlowProvenance() == .passive)
    }

    @Test func repeatFlagFollowsRepeatRunTag() {
        var provenance = FlowProvenance.passive
        #expect(!provenance.isRepeat)
        provenance.tools.repeatRun = RepeatRunTag(runID: UUID(), index: 1, total: 1)
        #expect(provenance.isRepeat)
    }
}
