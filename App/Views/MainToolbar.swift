import AppCore
import Localization
import SwiftUI

/// The proxy status in the middle of the title bar; the traffic toolbar owns recording, filter, search and clear.
/// The rules button and the breakpoint badge stay on the right; the global rules switch lives in the rules tab header.
struct MainToolbar: ToolbarContent {
    let appModel: AppModel
    let flowList: FlowListModel

    var body: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            ProxyStatusView(appModel: appModel)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button(L10n.string("rules.toolbar.title"), systemImage: "list.bullet.rectangle.portrait") {
                appModel.shell.showRules()
            }
            .help(L10n.string("rules.toolbar.help"))
            BreakpointToolbarButton(queue: appModel.breakpointQueue) {
                // Select the oldest paused request and show it in the request details.
                if let first = appModel.breakpointQueue.pausedFlowIDs.first { flowList.selectedID = first }
                appModel.shell.focusRequestDetails()
            }
        }
    }
}

/// "断点" with the number of paused tickets from the coordinator (not the flow list). Clicking it
/// selects the oldest paused request and opens the request details; nothing opens it by itself.
private struct BreakpointToolbarButton: View {
    let queue: BreakpointQueueModel
    let open: () -> Void

    var body: some View {
        let count = queue.pendingCount
        Button(action: open) {
            HStack(spacing: 4) {
                Image(systemName: count > 0 ? "pause.circle.fill" : "pause.circle")
                if count > 0 {
                    Text(verbatim: "\(count)")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .padding(.horizontal, 5)
                        .foregroundStyle(Palette.textColor(for: .pending))
                        .background(Capsule().fill(Palette.badgeFillColor(for: .pending)))
                }
            }
        }
        .accessibilityLabel(count > 0 ? L10n.format("breakpoints.toolbar.pending", count) : L10n.string("breakpoints.toolbar.title"))
        .help(count > 0 ? L10n.format("breakpoints.toolbar.pending", count) : L10n.string("breakpoints.toolbar.help"))
    }
}

/// "● ProxyWoman · 正在监听 127.0.0.1:9090"; grey while paused or still starting, a red dot and
/// the reason while nothing listens.
private struct ProxyStatusView: View {
    let appModel: AppModel

    var body: some View {
        let port = appModel.listeningPort
        let isPaused = port != nil && !appModel.isRecording
        HStack(spacing: 6) {
            Circle()
                .fill(dotColor(port: port, isPaused: isPaused))
                .frame(width: 8, height: 8)
            if let port {
                if isPaused {
                    Text(AppInfo.name).fontWeight(.semibold)
                    Text("·").foregroundStyle(.tertiary)
                    Text(L10n.string("mainToolbar.recordingPaused"))
                } else {
                    let listening = L10n.format("mainToolbar.listening", AppInfo.name, "\(appModel.listenHost):\(port)")
                    Text(listening).help(listening)
                }
            } else if appModel.isStarting {
                Text(AppInfo.name).fontWeight(.semibold)
                Text("·").foregroundStyle(.tertiary)
                Text(L10n.string("mainToolbar.starting"))
                    .foregroundStyle(.secondary)
            } else {
                Text(AppInfo.name).fontWeight(.semibold)
                Text("·").foregroundStyle(.tertiary)
                let reason = appModel.portError ?? L10n.string("mainToolbar.proxyStopped")
                Text(reason)
                    .truncationMode(.tail)
                    .help(reason)
            }
        }
        .font(.callout)
        .lineLimit(1)
        .foregroundStyle(isPaused ? .secondary : .primary)
        .padding(.horizontal, 12)
        .frame(minWidth: 240, maxWidth: 420)
    }

    private func dotColor(port: Int?, isPaused: Bool) -> Color {
        if port == nil { return appModel.isStarting ? Palette.neutralColor : Palette.failureColor }
        return isPaused ? Palette.neutralColor : Palette.successColor
    }
}
