import AppCore
import FlowStore
import Localization
import SwiftUI

/// The bar below the main area, 11 pt grey text: the traffic tool badges on the left, the number of items and the
/// selection in the middle, memory, the up / down rates and the system proxy switch on the right.
struct StatusBar: View {
    let appModel: AppModel
    @Bindable var flowList: FlowListModel

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                TrafficBadges(appModel: appModel)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 10) {
                Text(L10n.format("statusBar.count", flowList.visible.count))
                if selectedCount > 0 {
                    Text(L10n.format("statusBar.selected", selectedCount))
                }
            }
            .monospacedDigit()
            .fixedSize()

            HStack(spacing: 10) {
                if appModel.settings.preferences.showResourceUsage {
                    ResourceUsageView(appModel: appModel)
                }
                SystemProxySwitch(appModel: appModel)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(.system(size: 11))
        .foregroundStyle(ShellStyle.color(.textSecondary))
        .lineLimit(1)
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(ShellStyle.color(.toolbar))
        .overlay(alignment: .top) {
            Rectangle().fill(ShellStyle.color(.separator)).frame(height: 1)
        }
    }

    /// The selected flow counts only while the list shows it.
    private var selectedCount: Int {
        guard let id = flowList.selectedID, flowList.visible.index(ofID: id) != nil else { return 0 }
        return 1
    }
}

/// The system proxy state and its switch in the bottom-right corner; clicking the text toggles it as well.
private struct SystemProxySwitch: View {
    let appModel: AppModel

    var body: some View {
        let isOn = appModel.isSystemProxyEnabled
        // Turning it off must stay possible even if the listener failed to start.
        let isDisabled = appModel.listeningPort == nil && !isOn
        HStack(spacing: 6) {
            Button {
                appModel.requestSystemProxy(!isOn)
            } label: {
                HStack(spacing: 6) {
                    Circle()
                        .fill(isOn ? ShellStyle.color(.success) : ShellStyle.color(.textSecondary))
                        .frame(width: 6, height: 6)
                    Text(isOn ? L10n.string("statusBar.proxyTakenOver") : L10n.string("statusBar.proxyNotTakenOver"))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHidden(true)
            Toggle(
                L10n.string("trafficToolbar.systemProxy"),
                isOn: Binding(get: { isOn }, set: { appModel.requestSystemProxy($0) })
            )
            .toggleStyle(CapsuleSwitchStyle())
            .labelsHidden()
            .accessibilityLabel(L10n.string("trafficToolbar.systemProxy"))
        }
        .disabled(isDisabled)
        .fixedSize()
        .help(isOn ? L10n.string("statusBar.restoreProxyHelp") : L10n.string("statusBar.enableProxyHelp"))
    }
}

/// "· 168 MB ↑ 0 KB/s ↓ 0 KB/s"; samples only while shown.
private struct ResourceUsageView: View {
    let appModel: AppModel
    @State private var monitor = ResourceMonitor()

    var body: some View {
        Text(
            "· \(Formatting.size(monitor.residentBytes)) ↑ \(Formatting.rate(monitor.rate.up)) ↓ \(Formatting.rate(monitor.rate.down))"
        )
        .monospacedDigit()
        .fixedSize()
        .help(L10n.string("statusBar.resourceUsageHelp"))
        .task { await monitor.run { appModel.trafficTotals() } }
    }
}

/// A small marker for each active traffic tool, left of the proxy button; a click opens the
/// tool's tab (No Caching has none and is only a marker).
private struct TrafficBadges: View {
    let appModel: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        ForEach(appModel.trafficTools.badges) { badge in
            let label = Text(badge.title)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .foregroundStyle(Palette.pendingColor)
                .background(Capsule().fill(Palette.pendingColor.opacity(0.15)))
            if let tab = badge.tab {
                Button {
                    appModel.prepareTrafficControl(tab)
                    openSettings()
                } label: {
                    label
                }
                .buttonStyle(.plain)
                .help(badge.help + "\n" + L10n.string("traffic.status.openHint"))
            } else {
                label.help(badge.help)
            }
        }
    }
}
