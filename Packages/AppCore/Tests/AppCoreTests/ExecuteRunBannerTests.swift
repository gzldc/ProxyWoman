import Foundation
import Testing

@testable import AppCore
@testable import Localization

@Suite(.productionChinese) struct ExecuteRunBannerTests {
    private let runID = UUID()

    private func summary(considered: Int = 5, modified: Int = 2, cancelled: Bool = false, id: UUID? = nil) -> ExecuteSummary {
        ExecuteSummary(runID: id ?? runID, considered: considered, modifiedFlows: modified, wasCancelled: cancelled)
    }

    @Test func idleHasNoBanner() {
        #expect(ExecuteRunBanner.of(phase: .idle, canUndo: false, dismissedRunID: nil) == nil)
    }

    @Test func runningShowsProgress() throws {
        let banner = try #require(ExecuteRunBanner.of(phase: .running(done: 3, total: 10), canUndo: false, dismissedRunID: nil))
        #expect(banner.state == .running(done: 3, total: 10))
        #expect(!banner.canShowDetails)
        #expect(banner.text() == L10n.format("execute.runBanner.running", 3, 10))
    }

    @Test func finishedUsesConsideredAndModified() throws {
        let banner = try #require(ExecuteRunBanner.of(phase: .finished(summary()), canUndo: true, dismissedRunID: nil))
        #expect(banner.state == .finished(runID: runID, considered: 5, modified: 2))
        #expect(banner.canShowDetails && banner.canUndo)
        #expect(banner.text() == L10n.format("execute.runBanner.finished", 5, 2))
    }

    @Test func dismissedRunHidesBanner() {
        #expect(ExecuteRunBanner.of(phase: .finished(summary()), canUndo: true, dismissedRunID: runID) == nil)
    }

    @Test func newRunAfterDismissShowsAgain() {
        let other = UUID()
        #expect(ExecuteRunBanner.of(phase: .finished(summary(id: other)), canUndo: false, dismissedRunID: runID) != nil)
    }

    @Test func cancelledRunSaysCancelled() throws {
        let banner = try #require(
            ExecuteRunBanner.of(phase: .finished(summary(cancelled: true)), canUndo: false, dismissedRunID: nil))
        #expect(banner.state == .cancelled(runID: runID, considered: 5, modified: 2))
        #expect(banner.canShowDetails)
        #expect(banner.text() == L10n.format("execute.runBanner.cancelled", 5, 2))
    }

    @Test func finishedTextIsPinnedInChinese() {
        let zh = Localizer(bundle: L10n.bundle, preferredLanguages: ["zh-Hans"])
        let banner = ExecuteRunBanner.of(phase: .finished(summary()), canUndo: false, dismissedRunID: nil)
        #expect(banner?.text(localizer: zh) == "已对 5 条执行 · 改动 2 条")
    }

    @Test func notStartedReasons() {
        #expect(ExecuteNotStartedReason.of(phase: .running(done: 0, total: 1), ruleCount: 1, flowCount: 1) == .running)
        #expect(ExecuteNotStartedReason.of(phase: .idle, ruleCount: 0, flowCount: 3) == .noRules)
        #expect(ExecuteNotStartedReason.of(phase: .idle, ruleCount: 2, flowCount: 0) == .noFlows)
        #expect(ExecuteNotStartedReason.of(phase: .idle, ruleCount: 2, flowCount: 1) == nil)
        #expect(ExecuteNotStartedReason.noFlows.text() == L10n.string("execute.runNow.noFlows"))
    }
}
