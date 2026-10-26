import AppCore
import AppKit
import FlowStore
import Localization
import SwiftUI
import SystemProxy

struct AdvancedPane: View {
    let appModel: AppModel
    @State private var copied = false
    private var command: String {
        TerminalProxyCommand.exportLine(
            host: appModel.listenHost, port: appModel.listeningPort ?? appModel.settings.port)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            GroupBox(L10n.string("appCommands.systemProxy")) {
                VStack(alignment: .leading, spacing: 12) {
                    SettingsRow(title: L10n.string("advancedPane.setupLabel")) {
                        Text(L10n.string("advancedPane.setupHelp"))
                        Text(
                            appModel.isSystemProxyEnabled
                                ? L10n.format("advancedPane.proxyOwned", AppInfo.name)
                                : L10n.string("advancedPane.proxyUnowned"))
                        Text(L10n.format("advancedPane.originalProxy", appModel.upstreamProxyDescription)).font(
                            .caption
                        ).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Toggle(L10n.string("advancedPane.restoreProxy"), isOn: .constant(true)).disabled(true)
                    Text(L10n.string("advancedPane.restoreProxyExplanation")).font(.caption).foregroundStyle(.secondary)
                }.padding(12)
            }
            Divider()
            SettingsRow(title: L10n.string("advancedPane.recordingLabel")) {
                Toggle(L10n.string("advancedPane.deleteOldFlows"), isOn: .constant(true)).disabled(true)
                Text(
                    Formatting.deletionLimits(
                        maxFlows: FlowStore.defaultMaxFlows, maxSpilledBytes: FlowStore.defaultMaxSpilledBytes)
                )
                .font(.caption).foregroundStyle(.secondary)
                Text(L10n.string("advancedPane.deletionLimitsHelp")).font(.caption).foregroundStyle(.secondary)
                Button(L10n.string("advancedPane.editAction")) {}.disabled(true)
            }
            SettingsRow(title: L10n.string("advancedPane.terminalLabel")) {
                Button(copied ? L10n.string("advancedPane.copied") : L10n.string("advancedPane.copyTerminalProxy")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                    copied = true
                }
                Text(command).font(.caption.monospaced()).textSelection(.enabled).fixedSize(
                    horizontal: false, vertical: true)
                Text(L10n.string("advancedPane.terminalProxyHelp")).font(.caption).foregroundStyle(.secondary)
            }
        }.onChange(of: command) { copied = false }
    }
}
