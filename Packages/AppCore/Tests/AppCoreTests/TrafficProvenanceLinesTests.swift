import FlowStore
import Foundation
import Localization
import RulesEngine
import Testing
@testable import AppCore

/// The flow detail's one-line marks of what the traffic tools did to a flow.
@Suite(.productionChinese) struct TrafficProvenanceLinesTests {
    @Test func aFlowNoToolTouchedHasNoLines() {
        #expect(TrafficPresentation.provenanceLines(for: TrafficToolsProvenance()).isEmpty)
        // A repeat run is shown by the app column, not repeated here.
        let repeated = TrafficToolsProvenance(repeatRun: RepeatRunTag(runID: UUID(), index: 2, total: 5))
        #expect(TrafficPresentation.provenanceLines(for: repeated).isEmpty)
    }

    @Test func blockedNoCachingAndThrottledAreEachNamed() {
        let blocked = TrafficToolsProvenance(blockedByEntry: UUID())
        #expect(TrafficPresentation.provenanceLines(for: blocked) == [L10n.string("traffic.provenance.blocked")])
        let noCaching = TrafficToolsProvenance(noCaching: true)
        #expect(TrafficPresentation.provenanceLines(for: noCaching) == [L10n.string("traffic.provenance.noCaching")])

        let preset = TrafficToolsProvenance(networkCondition: "preset.edge")
        #expect(TrafficPresentation.provenanceLines(for: preset)
                == [L10n.format("traffic.provenance.throttled", TrafficPresentation.title(of: .edge))])
        let custom = TrafficToolsProvenance(networkCondition: "custom")
        #expect(TrafficPresentation.provenanceLines(for: custom)
                == [L10n.format("traffic.provenance.throttled", L10n.string("traffic.provenance.customProfile"))])
        let offline = TrafficToolsProvenance(networkCondition: "preset.offline")
        #expect(TrafficPresentation.provenanceLines(for: offline)
                == [L10n.format("traffic.provenance.throttled", TrafficPresentation.title(of: .offline))])
    }

    @Test func severalMarksComeInAStableOrderAndAnUnknownTagIsKeptAsIs() {
        let all = TrafficToolsProvenance(blockedByEntry: UUID(), noCaching: true, networkCondition: "preset.lte")
        #expect(TrafficPresentation.provenanceLines(for: all) == [
            L10n.string("traffic.provenance.blocked"), L10n.string("traffic.provenance.noCaching"),
            L10n.format("traffic.provenance.throttled", TrafficPresentation.title(of: .lte)),
        ])
        // A tag from a newer version is shown as recorded rather than hidden or guessed.
        let future = TrafficToolsProvenance(networkCondition: "preset.satellite")
        #expect(TrafficPresentation.provenanceLines(for: future)
                == [L10n.format("traffic.provenance.throttled", "preset.satellite")])
    }
}
