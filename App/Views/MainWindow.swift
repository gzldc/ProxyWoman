import AppCore
import AppKit
import FlowStore
import Localization
import SwiftUI
import UniformTypeIdentifiers
import Viewers

struct MainWindow: View {
    let appModel: AppModel
    @Bindable var flowList: FlowListModel

    @Environment(\.openSettings) private var openSettings

    @FocusState private var isSidebarFilterFocused: Bool
    @FocusState private var isToolbarSearchFocused: Bool

    var body: some View {
        let shell = appModel.shell
        HStack(spacing: 0) {
            IconRail(shell: shell, openSettings: { openSettings() })
            // The Compose page replaces the traffic page; nothing it holds lives in these views.
            if shell.page == .compose {
                ComposePage(appModel: appModel, flowList: flowList)
            } else {
                if shell.inspector.sourceBarVisible {
                    SourceBarView(appModel: appModel, flowList: flowList, searchFocus: $isSidebarFilterFocused)
                        .frame(width: ShellStyle.sourceBarWidth)
                        .background(ShellStyle.color(.sidebar))
                    Divider()
                }
                trafficPage
            }
        }
        .frame(minWidth: 1040, minHeight: 520)
        // On the root so the proxy status and breakpoint badge show on every page.
        .toolbar {
            MainToolbar(appModel: appModel, flowList: flowList)
        }
        // Paused requests are pinned on top; the queue follows the list's selection (the selection never moves by itself).
        .onChange(of: appModel.breakpointQueue.pausedFlowIDs, initial: true) {
            flowList.pausedFlowIDs = appModel.breakpointQueue.pausedFlowIDs
            appModel.breakpointQueue.selectFlow(flowList.selectedID)
        }
        .onChange(of: flowList.selectedID) {
            appModel.breakpointQueue.selectFlow(flowList.selectedID)
        }
        .focusedSceneValue(
            \.mainWindowCommands,
            MainWindowCommandTarget(
                flowList: flowList, exportHAR: exportHAR, copyCurl: copyCurl, focusSidebarFilter: focusSidebarFilter)
        )
        // Clear with paused breakpoints of recorded flows: say how many will be ended, then end them.
        .alert(
            L10n.string("breakpoints.clear.title"),
            isPresented: Binding(get: { flowList.clearConfirmation.pausedTicketCount != nil }, set: { _ in })
        ) {
            Button(L10n.string("breakpoints.clear.confirm"), role: .destructive) {
                Task { await flowList.clearConfirmation.confirm() }
            }
            Button(L10n.string("common.cancel"), role: .cancel) { flowList.clearConfirmation.dismiss() }
        } message: {
            Text(L10n.format("breakpoints.clear.message", flowList.clearConfirmation.pausedTicketCount ?? 0))
        }
        .alert(L10n.string("mainWindow.systemProxyQuestion"), isPresented: Bindable(appModel).isConfirmingSystemProxy) {
            Button(L10n.string("mainWindow.installCertificate")) {
                appModel.confirmSystemProxy(.installCertificate)
                openSettings()
            }
            Button(L10n.string("mainWindow.enableAnyway")) { appModel.confirmSystemProxy(.enableAnyway) }
            Button(L10n.string("common.cancel"), role: .cancel) { appModel.confirmSystemProxy(.cancel) }
        } message: {
            Text(L10n.string("mainWindow.trustWarning"))
        }
        // Closing the sheet in any way ends a run that is still going (the sheet cancels it).
        .sheet(item: Bindable(appModel).pendingRepeat) { RepeatSheet(model: $0.model) }
    }

    /// Banners, the tab strip and toolbar, the list with the inspector beside or below it, and the status bar.
    private var trafficPage: some View {
        VStack(spacing: 0) {
            if let message = appModel.lastError {
                ErrorBanner(message: message) { appModel.dismissError() }
                Divider()
            }
            if let notice = appModel.lastNotice {
                NoticeBanner(message: notice) { appModel.dismissNotice() }
                Divider()
            }
            if !appModel.isCATrusted {
                UntrustedCABanner {
                    appModel.prepareCertificateSettings()
                    openSettings()
                }
                Divider()
            }
            if appModel.showsRulesUpgradeBanner {
                RulesUpgradeBanner(
                    open: { appModel.shell.showRules() },
                    dismiss: { appModel.dismissRulesUpgradeBanner() })
                Divider()
            }
            ExecuteRunBannerView(appModel: appModel)
            TrafficTabAndToolbar(
                appModel: appModel, flowList: flowList, exportHAR: exportHAR, searchFocus: $isToolbarSearchFocused)
            listAndInspector
            StatusBar(appModel: appModel, flowList: flowList)
        }
        // Room for every quick filter chip and the status bar without clipping.
        .frame(minWidth: 820)
    }

    /// The list above (vertical) or beside (horizontal) the inspector, per `contentLayout`.
    private var listAndInspector: some View {
        InspectorSplit(shell: appModel.shell, layout: appModel.settings.preferences.contentLayout) {
            FlowTableView(
                model: flowList, appModel: appModel, revision: flowList.revision,
                style: FlowTableStyle(appModel.settings.preferences), selectedID: $flowList.selectedID,
                onDoubleClick: { _ in appModel.shell.focusRequestDetails() })
        } trailing: {
            InspectorPane(appModel: appModel, flowList: flowList)
        }
    }

    private func focusSidebarFilter() {
        appModel.shell.setSourceBarVisible(true)
        // Let the source bar appear before assigning the field's focus.
        Task { @MainActor in
            await Task.yield()
            isSidebarFilterFocused = true
        }
    }

    private func copyCurl() {
        guard let flow = flowList.selectedFlow, flow.method != "CONNECT" else { return }
        let preferences = appModel.settings.preferences
        let port = appModel.listeningPort ?? appModel.settings.port
        let options = CurlOptions(
            proxy: preferences.copyAddsProxy ? "http://\(appModel.listenHost):\(port)" : nil,
            preserveOriginalHeaders: preferences.copyPreservesOriginalHeaders)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(CurlExporter.command(for: flow, options: options), forType: .string)
    }

    /// Exports what the list currently shows (the filtered flows).
    private func exportHAR() {
        appModel.dismissNotice()
        let flows = flowList.visible
        let store = appModel.store
        let hiddenCount = flowList.filter.includeHidden ? 0 : flowList.hiddenCount
        guard !flows.isEmpty else { return }

        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "har") ?? .json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "\(AppInfo.name)-\(stamp.string(from: .now)).har"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        Task {
            do {
                // Bodies may have to be read from disk.
                try await Task.detached(priority: .userInitiated) {
                    let data = try HARExporter.export(
                        flows, creatorName: AppInfo.name, creatorVersion: AppInfo.version,
                        webSocketSummaryForFlow: { (flow: Flow) in
                            store.webSocketToken(flowID: flow.id).flatMap { store.webSocketHARSummary(token: $0) }
                        }
                    ) { body, encoding in
                        let decoded = BodyDecoder.decode(body, contentEncoding: encoding)
                        return decoded.error == nil && decoded.encoding != nil ? decoded.data : nil
                    }
                    try data.write(to: url, options: .atomic)
                }.value
                if hiddenCount > 0 {
                    appModel.showNotice(L10n.format("mainWindow.exportExcludedHidden", hiddenCount))
                }
            } catch {
                appModel.showError(L10n.format("mainWindow.exportHARFailed", error.localizedDescription))
            }
        }
    }
}

private struct ErrorBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(message)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(L10n.string("common.close"), systemImage: "xmark", action: dismiss)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.yellow.opacity(0.15))
    }
}

private struct NoticeBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(.blue)
            Text(message)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(L10n.string("common.close"), systemImage: "xmark", action: dismiss)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.blue.opacity(0.12))
    }
}

private struct UntrustedCABanner: View {
    let install: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "lock.trianglebadge.exclamationmark")
                .foregroundStyle(.orange)
            Text(L10n.format("mainWindow.certificateRequired", AppInfo.name))
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(L10n.string("mainWindow.installCertificate"), action: install)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.orange.opacity(0.12))
    }
}

/// One line under the toolbar while the rules upgrade notice is unread: it points to the Rules tab, where
/// the notice itself is. Closing it keeps it closed; reading the notice makes it go by itself.
private struct RulesUpgradeBanner: View {
    let open: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundStyle(Color.accentColor)
            Text(L10n.string("rules.upgrade.banner"))
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(L10n.string("rules.upgrade.banner.open"), action: open)
            Button(L10n.string("rules.upgrade.banner.dismiss"), systemImage: "xmark", action: dismiss)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.12))
    }
}
