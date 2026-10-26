import AppCore
import Localization
import SwiftUI

/// The strip under the error / notice banners that reports the latest Execute run: progress with Stop, then the
/// result with Undo, View Details and a close button. It lives in the main window, so the run never needs a window.
struct ExecuteRunBannerView: View {
    let appModel: AppModel
    /// The run whose details are open; the sheet shows only while that run is still the latest result.
    @State private var detailsRunID: UUID?

    var body: some View {
        let runner = appModel.executeRunner
        let banner = ExecuteRunBanner.of(
            phase: runner.phase, canUndo: runner.canUndoLastRun, dismissedRunID: appModel.shell.dismissedExecuteRunID)
        if let banner {
            VStack(spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: icon(banner.state)).foregroundStyle(ShellStyle.color(.accent))
                        Text(banner.text()).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(banner.text())
                    .accessibilityAddTraits(.updatesFrequently)
                    controls(banner, runner: runner)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(ShellStyle.color(.accentSoft))
                Divider()
            }
            .accessibilityElement(children: .contain)
            .sheet(
                isPresented: Binding(
                    get: { detailsRunID != nil && detailsRunID == finishedRunID(runner.phase) },
                    set: { if !$0 { detailsRunID = nil } })
            ) {
                if case .finished(let summary) = runner.phase {
                    ExecuteSummarySheet(summary: summary, rules: appModel.rulesEditor) { detailsRunID = nil }
                }
            }
        }
    }

    @ViewBuilder
    private func controls(_ banner: ExecuteRunBanner, runner: ExecuteRunner) -> some View {
        if case .running = banner.state {
            Button(L10n.string("execute.runBanner.stop")) { runner.cancel() }
                .accessibilityLabel(L10n.string("execute.runBanner.stop"))
        } else {
            if banner.canUndo {
                Button(L10n.string("execute.runBanner.undo")) { runner.undoLastRun() }
                    .accessibilityLabel(L10n.string("execute.runBanner.undo"))
            }
            if banner.canShowDetails {
                Button(L10n.string("execute.runBanner.details")) { detailsRunID = runID(banner.state) }
                    .accessibilityLabel(L10n.string("execute.runBanner.details"))
            }
            Button(L10n.string("execute.runBanner.dismiss"), systemImage: "xmark") {
                if let runID = runID(banner.state) { appModel.shell.dismissedExecuteRunID = runID }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .accessibilityLabel(L10n.string("execute.runBanner.dismiss"))
        }
    }

    private func finishedRunID(_ phase: ExecuteRunner.Phase) -> UUID? {
        if case .finished(let summary) = phase { summary.runID } else { nil }
    }

    /// × hides the strip only; Undo of the last run stays reachable in the rules tab's ⋯ menu.
    private func icon(_ state: ExecuteRunBanner.State) -> String {
        switch state {
        case .running: "play.circle.fill"
        case .finished: "checkmark.circle.fill"
        case .cancelled: "stop.circle.fill"
        }
    }

    private func runID(_ state: ExecuteRunBanner.State) -> UUID? {
        switch state {
        case .running: nil
        case .finished(let id, _, _), .cancelled(let id, _, _): id
        }
    }
}
