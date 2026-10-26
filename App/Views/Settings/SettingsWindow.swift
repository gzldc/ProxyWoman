import AppCore
import Localization
import SwiftUI

struct SettingsWindow: View {
    /// 180 pt for Chinese; wider when the longest page title needs it.
    private static let sidebarWidth = SettingsMetrics.sidebarWidth()

    @Bindable var appModel: AppModel
    @State private var search = ""
    @State private var history: [SettingsPage] = [.general]
    @State private var historyIndex = 0
    @State private var isTraversing = false

    private func matches(_ page: SettingsPage) -> Bool {
        page.matches(search)
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                TextField(L10n.string("settingsWindow.searchSettings"), text: $search)
                    .textFieldStyle(.roundedBorder)
                    .padding([.horizontal, .top], 12)
                    .accessibilityLabel(L10n.string("settingsWindow.searchSettingsHelp"))
                List(selection: $appModel.settingsPage) {
                    Section(L10n.string("sidebarView.apps")) { pageRows([.general, .appearance, .privacy, .trafficControl, .https]) }
                    Section(L10n.string("settingsWindow.integration")) { pageRows([.tools, .mcp]) }
                    Section(L10n.string("settingsWindow.advanced")) { pageRows([.advanced]) }
                }
                .listStyle(.sidebar)
            }
            .frame(width: Self.sidebarWidth)
            .background(.regularMaterial)
            Divider()
            content
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    navigate(-1)
                } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(historyIndex == 0).help(L10n.string("settingsWindow.back"))
                .accessibilityLabel(L10n.string("settingsWindow.back"))
                .accessibilityIdentifier("settings.back")
                Button {
                    navigate(1)
                } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(historyIndex + 1 >= history.count).help(L10n.string("settingsWindow.forward"))
                .accessibilityLabel(L10n.string("settingsWindow.forward"))
                .accessibilityIdentifier("settings.forward")
            }
            ToolbarItem(placement: .principal) { Text(appModel.settingsPage.title).font(.headline) }
        }
        .frame(minWidth: 830, idealWidth: 980, minHeight: 660, idealHeight: 760)
        .onAppear {
            if history[historyIndex] != appModel.settingsPage {
                history = [appModel.settingsPage]
                historyIndex = 0
            }
        }
        .onChange(of: appModel.settingsPage) { _, page in
            if isTraversing {
                isTraversing = false
                return
            }
            guard history[historyIndex] != page else { return }
            history = Array(history.prefix(historyIndex + 1)) + [page]
            historyIndex = history.count - 1
        }
        .sheet(isPresented: $appModel.showsAdvancedProxySettings) {
            AdvancedProxySheet(appModel: appModel)
        }
    }

    /// Table pages fill the pane; only the form pages scroll (a table inside a padded ScrollView collapses).
    @ViewBuilder private var content: some View {
        switch appModel.settingsPage {
        case .trafficControl:
            TrafficControlPane(
                model: appModel.trafficTools, navigation: appModel.trafficToolsNavigation, health: appModel.patternHealth)
        case .https:
            HTTPSPane(appModel: appModel)
        default:
            ScrollViewReader { reader in
                ScrollView {
                    pane.padding(24).frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: appModel.certificateHighlightID) {
                    search = ""
                    withAnimation { reader.scrollTo("certificate", anchor: .center) }
                }
                .onAppear {
                    if appModel.certificateHighlightID != nil { reader.scrollTo("certificate", anchor: .center) }
                }
            }
        }
    }

    @ViewBuilder private var pane: some View {
        switch appModel.settingsPage {
        case .general: GeneralPane(appModel: appModel)
        case .appearance: AppearancePane(settings: appModel.settings)
        case .privacy: PrivacyPane()
        case .trafficControl, .https: EmptyView()
        case .tools: ToolsPane(settings: appModel.settings)
        case .mcp: MCPPane(settings: appModel.settings, mcp: appModel.mcp)
        case .advanced: AdvancedPane(appModel: appModel)
        }
    }

    private func pageRows(_ pages: [SettingsPage]) -> some View {
        ForEach(pages.filter(matches)) { page in
            Label(page.title, systemImage: page.icon).tag(page)
        }
    }

    private func navigate(_ delta: Int) {
        let next = historyIndex + delta
        guard history.indices.contains(next) else { return }
        isTraversing = true
        historyIndex = next
        appModel.settingsPage = history[next]
    }
}

/// 95 pt for Chinese; as wide as the longest title of any pane in the current language, so every pane's titles line up
/// and none wraps.
private let settingsTitleWidth = SettingsMetrics.titleColumnWidth()

/// Shared compact, aligned form layout for the settings panes.
struct SettingsRow<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Text(title.isEmpty ? " " : title).foregroundStyle(.secondary)
                .frame(width: settingsTitleWidth, alignment: .trailing).padding(.top, 3)
            VStack(alignment: .leading, spacing: 6) { content }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
