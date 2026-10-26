import AppCore
import AppKit
import Localization
import MCPKit
import SwiftUI

/// 设置 ▸ MCP：总开关与状态、连接 AI 客户端的配置片段、逐项写入授权、脱敏选项、最近调用。
/// Every change goes through `update`, which stores the new settings and hands them to the controller, so the
/// server follows the switch at once and the tools see the new permissions on their next call.
struct MCPPane: View {
    @Bindable var settings: AppSettings
    var mcp: MCPController
    @State private var client: MCPConfigSnippets.Client = .claudeDesktop
    @State private var extraNamesText = ""
    @State private var copied = false
    @FocusState private var editingNames: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switchSection
            connectSection
            writeSection
            privacySection
            activitySection
        }
        .onAppear { extraNamesText = settings.mcp.redaction.extraNames.joined(separator: ", ") }
        // Leaving the page (another settings tab, closing the window) while the field still has focus must not
        // lose the edit: the focus change that normally saves it may never be delivered.
        .onDisappear { saveExtraNames() }
        .task { await mcp.activity.start() }
    }

    // MARK: Switch and status

    private var switchSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Toggle(L10n.string("mcpPane.enable"), isOn: binding(\.enabled))
                    .accessibilityIdentifier("mcp.enable")
                Text(L10n.string("mcpPane.enableHelp")).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(L10n.string("mcpPane.status.label")).foregroundStyle(.secondary)
                    Text(statusText).foregroundStyle(statusColor).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("mcp.status")
                }
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var statusText: String {
        switch mcp.status {
        case .off: L10n.string("mcpPane.status.off")
        case .listening: L10n.string("mcpPane.status.listening")
        case .unavailableInThisBuild: L10n.string("mcpPane.status.unavailable")
        case .failed(let failure): MCPPresentation.failureText(failure, appName: AppInfo.name)
        }
    }

    private var statusColor: Color {
        switch mcp.status {
        case .off: .secondary
        case .listening: .green
        case .failed, .unavailableInThisBuild: .red
        }
    }

    // MARK: Connect

    private var snippet: String {
        MCPConfigSnippets.snippet(for: client, helperPath: mcp.helperPath, handshakePath: mcp.handshakePath)
    }

    private var connectSection: some View {
        GroupBox(L10n.string("mcpPane.connect.title")) {
            VStack(alignment: .leading, spacing: 8) {
                Picker(L10n.string("mcpPane.connect.clientPicker"), selection: $client) {
                    Text(L10n.string("mcpPane.client.claudeDesktop")).tag(MCPConfigSnippets.Client.claudeDesktop)
                    Text(L10n.string("mcpPane.client.claudeCode")).tag(MCPConfigSnippets.Client.claudeCode)
                    Text(L10n.string("mcpPane.client.cursor")).tag(MCPConfigSnippets.Client.cursor)
                }
                .pickerStyle(.segmented).labelsHidden()
                .accessibilityLabel(L10n.string("mcpPane.connect.clientPicker"))
                Text(clientHint).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(snippet)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                    .accessibilityLabel(L10n.string("mcpPane.connect.snippetLabel"))
                    .accessibilityIdentifier("mcp.snippet")
                HStack {
                    Button(copied ? L10n.string("mcpPane.connect.copied") : L10n.string("mcpPane.connect.copy")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(snippet, forType: .string)
                        copied = true
                    }
                    .accessibilityIdentifier("mcp.copy")
                    Text(L10n.format("mcpPane.connect.requiresRunning", AppInfo.name))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: client) { copied = false }
    }

    private var clientHint: String {
        switch client {
        case .claudeDesktop: L10n.string("mcpPane.connect.hint.claudeDesktop")
        case .claudeCode: L10n.string("mcpPane.connect.hint.claudeCode")
        case .cursor: L10n.string("mcpPane.connect.hint.cursor")
        }
    }

    // MARK: Write permissions

    private var writeSection: some View {
        GroupBox(L10n.string("mcpPane.write.title")) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.string("mcpPane.write.intro")).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle(L10n.string("mcpPane.write.createRule"), isOn: writeBinding(.createRule))
                Toggle(L10n.string("mcpPane.write.updateRule"), isOn: writeBinding(.updateRule))
                Toggle(L10n.string("mcpPane.write.setRuleEnabled"), isOn: writeBinding(.setRuleEnabled))
                Toggle(L10n.string("mcpPane.write.setRecording"), isOn: writeBinding(.setRecording))
                Divider()
                Toggle(L10n.string("mcpPane.write.allowEnabling"), isOn: binding(\.allowEnablingRules))
                Label(L10n.string("mcpPane.write.allowEnablingWarning"), systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Privacy

    private var privacySection: some View {
        GroupBox(L10n.string("mcpPane.privacy.title")) {
            VStack(alignment: .leading, spacing: 8) {
                Toggle(L10n.string("mcpPane.privacy.redact"), isOn: binding(\.redaction.enabled))
                if settings.mcp.redaction.enabled {
                    Text(L10n.string("mcpPane.privacy.redactOnHelp")).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Label(L10n.string("mcpPane.privacy.redactOffWarning"), systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
                HStack {
                    Text(L10n.string("mcpPane.privacy.extraNames")).foregroundStyle(.secondary)
                    TextField(L10n.string("mcpPane.privacy.extraNamesPlaceholder"), text: $extraNamesText)
                        .textFieldStyle(.roundedBorder)
                        .focused($editingNames)
                        .onSubmit(saveExtraNames)
                        .onChange(of: editingNames) { _, editing in if !editing { saveExtraNames() } }
                        .accessibilityLabel(L10n.string("mcpPane.privacy.extraNames"))
                }
                Text(L10n.string("mcpPane.privacy.extraNamesHelp")).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Splits at commas (ASCII or full-width), stores the names the way the redactor reads them
    /// (`normalizedExtraNames`), and shows the stored form back.
    private func saveExtraNames() {
        let normalized = Self.extraNames(from: extraNamesText)
        update { $0.redaction.extraNames = normalized }
        extraNamesText = normalized.joined(separator: ", ")
    }

    /// The names the text field stands for: split at commas (ASCII or full-width), then normalized.
    static func extraNames(from text: String) -> [String] {
        let parts = text.split(whereSeparator: { $0 == "," || $0 == "，" }).map(String.init)
        return MCPRedactionSettings(extraNames: parts).normalizedExtraNames()
    }

    // MARK: Recent calls

    private var activitySection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(L10n.string("mcpPane.activity.title")).font(.headline)
                    Spacer()
                    Button(L10n.string("mcpPane.activity.clear")) { mcp.activity.clear() }
                        .disabled(mcp.activity.entries.isEmpty)
                        .accessibilityIdentifier("mcp.clearActivity")
                }
                if mcp.activity.entries.isEmpty {
                    Text(L10n.string("mcpPane.activity.empty")).font(.caption).foregroundStyle(.secondary)
                } else {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                        GridRow {
                            Text(L10n.string("mcpPane.activity.column.time"))
                            Text(L10n.string("mcpPane.activity.column.client"))
                            Text(L10n.string("mcpPane.activity.column.tool"))
                            Text(L10n.string("mcpPane.activity.column.result"))
                            Text(L10n.string("mcpPane.activity.column.duration"))
                        }
                        .font(.caption).foregroundStyle(.secondary)
                        Divider().gridCellColumns(5)
                        ForEach(mcp.activity.entries) { entry in
                            GridRow {
                                Text(entry.at, style: .time)
                                Text(entry.client ?? L10n.string("mcpPane.activity.unknownClient")).lineLimit(1)
                                Text(entry.tool).lineLimit(1).font(.system(.body, design: .monospaced))
                                Text(MCPPresentation.outcomeText(entry.outcome)).lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(L10n.format("mcpPane.activity.milliseconds", entry.durationMs))
                                    .monospacedDigit().foregroundStyle(.secondary)
                            }
                            .font(.callout)
                        }
                    }
                }
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Settings plumbing

    /// Stores the changed settings and applies them; nothing happens when nothing changed.
    private func update(_ change: (inout MCPSettings) -> Void) {
        var next = settings.mcp
        change(&next)
        guard next != settings.mcp else { return }
        settings.mcp = next
        mcp.apply(next)
    }

    private func binding(_ keyPath: WritableKeyPath<MCPSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { settings.mcp[keyPath: keyPath] },
            set: { value in update { $0[keyPath: keyPath] = value } })
    }

    private func writeBinding(_ tool: MCPWriteTool) -> Binding<Bool> {
        Binding(
            get: { settings.mcp.writeTools.contains(tool) },
            set: { allowed in
                update { settings in
                    if allowed { settings.writeTools.insert(tool) } else { settings.writeTools.remove(tool) }
                }
            })
    }
}
