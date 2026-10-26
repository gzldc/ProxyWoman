import FlowStore
import Foundation
import Localization
import Testing

@testable import AppCore

@Suite(.productionChinese) struct FlowOverviewPresentationTests {
    private func flow(scheme: String = "https", method: String = "GET") -> Flow {
        Flow(id: 1, scheme: scheme, method: method, host: "a.com", port: 443, path: "/x?y=1")
    }

    private func sections(_ flow: Flow, names: @escaping (UUID) -> String? = { _ in nil })
        -> [OverviewSection]
    {
        FlowOverviewPresentation.sections(for: flow, ruleName: names)
    }

    private func row(_ sections: [OverviewSection], _ kind: OverviewSection.Kind, _ titleKey: String) -> OverviewRow? {
        sections.first { $0.kind == kind }?.rows.first { $0.title == L10n.string(titleKey) }
    }

    @Test func inProgressFlowShowsInProgressStatus() {
        var f = flow()
        f.state = .inProgress
        let status = row(sections(f), .summary, "overview.status")
        #expect(status?.value == L10n.string("overview.status.inProgress"))
    }

    @Test func completedFlowShowsStatusCode() {
        var f = flow()
        f.state = .completed
        f.statusCode = 404
        #expect(row(sections(f), .summary, "overview.status")?.value == "404")
    }

    @Test func failedFlowShowsReasonWithFailureTone() {
        var f = flow()
        f.state = .failed("connection refused")
        let status = row(sections(f), .summary, "overview.status")
        #expect(status?.value == "connection refused")
        #expect(status?.tone == .failure)
    }

    @Test func connectRowSaysNotDecrypted() {
        var f = flow(scheme: "https", method: "CONNECT")
        f.state = .tunnel
        #expect(row(sections(f), .connection, "overview.tls")?.value == L10n.string("overview.tls.tunnel"))
    }

    @Test func httpsRequestSaysDecrypted() {
        #expect(row(sections(flow()), .connection, "overview.tls")?.value == L10n.string("overview.tls.decrypted"))
    }

    @Test func plainHTTPShowsDash() {
        #expect(row(sections(flow(scheme: "http")), .connection, "overview.tls")?.value == L10n.string("overview.none"))
    }

    @Test func missingIPsShowDash() {
        let none = L10n.string("overview.none")
        let s = sections(flow())
        #expect(row(s, .connection, "overview.clientIP")?.value == none)
        #expect(row(s, .connection, "overview.remoteIP")?.value == none)
    }

    @Test func presentIPsAreShown() {
        var f = flow()
        f.clientIP = "10.0.0.2"
        f.remoteIP = "93.184.216.34"
        let s = sections(f)
        #expect(row(s, .connection, "overview.clientIP")?.value == "10.0.0.2")
        #expect(row(s, .connection, "overview.remoteIP")?.value == "93.184.216.34")
    }

    @Test func rulesSectionOnlyWhenMatched() {
        #expect(!sections(flow()).map(\.kind).contains(.rules))
        var f = flow()
        f.provenance.ruleMatches = RuleMatchSummary(revision: 1, ruleIDs: [UUID()], total: 1)
        #expect(sections(f).map(\.kind).contains(.rules))
    }

    @Test func rulesSectionUsesResultLines() {
        let id = UUID()
        var f = flow()
        f.provenance.ruleMatches = RuleMatchSummary(
            revision: 1, ruleIDs: [id], total: 1, outcomes: [RuleOutcome(ruleID: id, code: .applied)])
        let expected = RulePresentation.resultLines(f.provenance.ruleMatches, ruleName: { _ in "R" }).map(\.text)
        let rows = sections(f, names: { _ in "R" }).first { $0.kind == .rules }?.rows ?? []
        #expect(!expected.isEmpty)
        #expect(rows.map(\.value) == expected)
    }

    @Test func timingRowsShowStartedCompletedDuration() {
        var f = flow()
        f.startedAt = Date(timeIntervalSince1970: 1_791_000_000)
        f.completedAt = f.startedAt.addingTimeInterval(1.5)
        let s = sections(f)
        #expect(row(s, .timing, "overview.started")?.value == Formatting.time(f.startedAt, use24Hour: true, full: true))
        #expect(row(s, .timing, "overview.completed")?.value == Formatting.time(f.completedAt!, use24Hour: true, full: true))
        #expect(row(s, .timing, "overview.duration")?.value == Formatting.duration(1.5))
    }

    @Test func timingRowsShowDashUntilCompleted() {
        var f = flow()
        f.completedAt = nil
        let none = L10n.string("overview.none")
        let s = sections(f)
        #expect(row(s, .timing, "overview.completed")?.value == none)
        #expect(row(s, .timing, "overview.duration")?.value == none)
        #expect(row(s, .timing, "overview.started")?.value != none)
    }

    @Test func timingFollowsTheTwelveHourPreference() {
        var f = flow()
        f.startedAt = Date(timeIntervalSince1970: 1_791_000_000)
        let s = FlowOverviewPresentation.sections(for: f, ruleName: { _ in nil }, use24Hour: false)
        #expect(row(s, .timing, "overview.started")?.value == Formatting.time(f.startedAt, use24Hour: false, full: true))
    }

    @Test func missingAppShowsDash() {
        #expect(row(sections(flow()), .summary, "overview.app")?.value == L10n.string("overview.none"))
    }

    @Test func sizesUseFormatting() {
        var f = flow()
        f.bytesSent = 1536
        f.bytesReceived = 0
        let s = sections(f)
        #expect(row(s, .sizes, "overview.sent")?.value == Formatting.size(1536))
        #expect(row(s, .sizes, "overview.received")?.value == Formatting.size(0))
    }
}
