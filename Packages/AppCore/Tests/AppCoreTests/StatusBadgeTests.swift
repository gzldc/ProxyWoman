import FlowStore
import Foundation
import Localization
import Testing

@testable import AppCore

@Suite(.productionChinese) struct StatusBadgeTests {
    private func flow(code: Int? = nil, state: FlowState = .completed) -> Flow {
        var f = Flow(id: 1, scheme: "https", method: "GET", host: "example.com", port: 443, path: "/")
        f.statusCode = code
        f.state = state
        return f
    }

    @Test func successForTwoXXAndThreeXX() {
        #expect(StatusBadge.of(flow(code: 200)) == StatusBadge(text: "200", tone: .success))
        #expect(StatusBadge.of(flow(code: 304)) == StatusBadge(text: "304", tone: .success))
    }

    @Test func failureForFourXXAndFiveXX() {
        #expect(StatusBadge.of(flow(code: 404)) == StatusBadge(text: "404", tone: .failure))
        #expect(StatusBadge.of(flow(code: 503)) == StatusBadge(text: "503", tone: .failure))
    }

    @Test func neutralForOneXX() {
        #expect(StatusBadge.of(flow(code: 101)) == StatusBadge(text: "101", tone: .neutral))
    }

    @Test func statusCodeWinsOverState() {
        #expect(StatusBadge.of(flow(code: 200, state: .inProgress)) == StatusBadge(text: "200", tone: .success))
        #expect(StatusBadge.of(flow(code: 502, state: .failed("x"))) == StatusBadge(text: "502", tone: .failure))
    }

    @Test func stateLabelsWithoutStatusCode() {
        #expect(StatusBadge.of(flow(state: .inProgress)) == StatusBadge(text: "进行中", tone: .pending))
        #expect(StatusBadge.of(flow(state: .failed("boom"))) == StatusBadge(text: "失败", tone: .failure))
        #expect(StatusBadge.of(flow(state: .tunnel)) == StatusBadge(text: "隧道", tone: .neutral))
    }

    @Test func completedWithoutStatusCodeIsNeutralDash() {
        #expect(StatusBadge.of(flow()) == StatusBadge(text: "–", tone: .neutral))
    }

    @Test func statusClassTitlesLocalizeOnlyTheWord() {
        let en = Localizer(bundle: L10n.bundle, preferredLanguages: ["en"])
        #expect(StatusClass.allCases.map { $0.title() } == ["1xx", "2xx", "3xx", "4xx", "5xx", "失败"])
        #expect(StatusClass.allCases.map { $0.title(localizer: en) } == ["1xx", "2xx", "3xx", "4xx", "5xx", "Failed"])
    }

    @Test func unknownAppGroupKeyStaysStableAndOnlyItsLabelIsLocalized() {
        let en = Localizer(bundle: L10n.bundle, preferredLanguages: ["en"])
        #expect(FlowGrouping.unknownApp == "未知")
        #expect(SourceBarItem.appDisplayName(FlowGrouping.unknownApp, localizer: en) == "Unknown")
        #expect(SourceBarItem.appDisplayName(FlowGrouping.unknownApp) == "未知")
        #expect(SourceBarItem.appDisplayName("curl", localizer: en) == "curl")
    }
}
