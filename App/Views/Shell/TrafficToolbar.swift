import AppCore
import FlowStore
import Localization
import SwiftUI

/// The one tab of the traffic page ("全部流量"); the strip above the toolbar.
private enum TrafficTab: String, Identifiable {
    case all
    var id: Self { self }
}

/// The strip with the single "全部流量" tab, then the toolbar: record / pause, filter popover, system proxy switch,
/// URL search, clear and the "更多" menu.
struct TrafficTabAndToolbar: View {
    let appModel: AppModel
    @Bindable var flowList: FlowListModel
    let exportHAR: () -> Void
    var searchFocus: FocusState<Bool>.Binding

    var body: some View {
        VStack(spacing: 0) {
            ShellTabStrip(
                tabs: [TrafficTab.all], selection: .constant(.all),
                title: { _ in L10n.string("trafficTab.all") }, icon: { _ in nil },
                trailing: AnyView(inspectorToggle))
            TrafficToolbar(appModel: appModel, flowList: flowList, exportHAR: exportHAR, searchFocus: searchFocus)
        }
    }

    /// Shows or hides the right panel; the same button at the strip's trailing end in both states.
    private var inspectorToggle: some View {
        let label = L10n.string(InspectorTabStripPolicy.toggleLabelKey(isCollapsed: appModel.shell.inspector.isCollapsed))
        return Button { appModel.shell.toggleCollapsed() } label: { Image(systemName: "sidebar.right") }
            .buttonStyle(IconSquareButtonStyle())
            .help(label)
            .accessibilityLabel(label)
    }
}

struct TrafficToolbar: View {
    let appModel: AppModel
    @Bindable var flowList: FlowListModel
    let exportHAR: () -> Void
    var searchFocus: FocusState<Bool>.Binding

    @State private var isFilterOpen = false

    var body: some View {
        HStack(spacing: 8) {
            recordButton
            filterButton
            if let title = QuickFilter.ruleMatchesTitle(flowList.filter) {
                RuleMatchesChip(title: title) { flowList.clearRuleMatches() }
            }
            Spacer(minLength: 8)
            systemProxySwitch
            searchField
            clearMenu
            moreMenu
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background(ShellStyle.color(.toolbar))
        .background {
            // ⌘F moves the keyboard into the toolbar's search field.
            Button("") { searchFocus.wrappedValue = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .accessibilityHidden(true)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(ShellStyle.color(.separator)).frame(height: 1)
        }
    }

    // MARK: Pieces

    private var recordButton: some View {
        let isRecording = appModel.isRecording
        let label = isRecording ? L10n.string("appCommands.pauseRecording") : L10n.string("mainToolbar.resumeRecording")
        return Button {
            appModel.setRecording(!isRecording)
        } label: {
            Image(systemName: isRecording ? "pause.fill" : "record.circle")
                .foregroundStyle(isRecording ? ShellStyle.color(.textPrimary) : ShellStyle.color(.failure))
        }
        .buttonStyle(IconSquareButtonStyle())
        .accessibilityLabel(label)
        .help(isRecording ? L10n.string("mainToolbar.pauseHelp") : label)
    }

    private var filterButton: some View {
        Button {
            isFilterOpen.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "line.3.horizontal.decrease")
                Text(L10n.string("trafficToolbar.filter"))
                if activeFilterCount > 0 {
                    Text("\(activeFilterCount)")
                        .monospacedDigit()
                        .foregroundStyle(Color.accentColor)
                }
                Image(systemName: "chevron.down").imageScale(.small)
            }
            .foregroundStyle(activeFilterCount > 0 ? Color.accentColor : ShellStyle.color(.textPrimary))
        }
        .buttonStyle(OutlineButtonStyle())
        .accessibilityLabel(L10n.string("trafficToolbar.filter"))
        .accessibilityValue(activeFilterCount > 0 ? "\(activeFilterCount)" : "")
        .popover(isPresented: $isFilterOpen, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                QuickFilterChips(flowList: flowList)
                Divider()
                Toggle(L10n.string("trafficToolbar.filter.showHidden"), isOn: $flowList.filter.includeHidden)
            }
            .padding(12)
            .frame(width: 380)
        }
    }

    /// How many of the popover's filters are on (the search text has its own field).
    private var activeFilterCount: Int {
        let f = flowList.filter
        let flags = [
            !f.methods.isEmpty, !f.statusClasses.isEmpty, !f.contentKinds.isEmpty, !f.protocols.isEmpty,
            f.hasMark, f.rulesModified, !f.commentContains.trimmingCharacters(in: .whitespaces).isEmpty,
            f.includeHidden, f.ids != nil,
        ]
        return flags.filter { $0 }.count
    }

    private var systemProxySwitch: some View {
        let isOn = appModel.isSystemProxyEnabled
        return HStack(spacing: 6) {
            Toggle(
                L10n.string("trafficToolbar.systemProxy"),
                isOn: Binding(get: { isOn }, set: { appModel.requestSystemProxy($0) })
            )
            .toggleStyle(CapsuleSwitchStyle())
            .labelsHidden()
            .accessibilityLabel(L10n.string("trafficToolbar.systemProxy"))
            // Turning it off must stay possible even if the listener failed to start.
            .disabled(appModel.listeningPort == nil && !isOn)
            .help(isOn ? L10n.string("statusBar.restoreProxyHelp") : L10n.string("statusBar.enableProxyHelp"))
            Text(L10n.string("trafficToolbar.systemProxy"))
                .font(.system(size: 12))
                .foregroundStyle(ShellStyle.color(.textSecondary))
                .lineLimit(1)
                .fixedSize()
        }
    }

    private var searchField: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .imageScale(.small)
                .foregroundStyle(ShellStyle.color(.textSecondary))
                .accessibilityHidden(true)
            TextField(
                L10n.string("trafficToolbar.search"), text: $flowList.filter.text,
                prompt: Text(L10n.string("trafficToolbar.search"))
            )
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .focused(searchFocus)
            .accessibilityLabel(L10n.string("trafficToolbar.search"))
        }
        .padding(.horizontal, 6)
        .frame(width: 200, height: ShellStyle.iconButtonSide)
        .background(RoundedRectangle(cornerRadius: ShellStyle.cornerRadius).fill(ShellStyle.color(.content)))
        .overlay(
            RoundedRectangle(cornerRadius: ShellStyle.cornerRadius)
                .strokeBorder(ShellStyle.color(.separator), lineWidth: 1))
    }

    private var clearMenu: some View {
        Menu {
            Button(L10n.string("trafficToolbar.clearAll")) { flowList.requestClear() }
        } label: {
            Image(systemName: "trash")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(L10n.string("trafficToolbar.clear"))
        .help(L10n.string("mainToolbar.clearHelp"))
    }

    private var moreMenu: some View {
        Menu {
            Toggle(L10n.string("appCommands.autoSelectLatest"), isOn: $flowList.autoSelectsLatest)
            Button(L10n.string("appCommands.exportHAR"), action: exportHAR)
            Divider()
            Picker(L10n.string("appCommands.detailLayout"), selection: contentLayout) {
                Text(L10n.string("appCommands.verticalLayout")).tag(ContentLayout.vertical)
                Text(L10n.string("appCommands.horizontalLayout")).tag(ContentLayout.horizontal)
            }
            .pickerStyle(.inline)
            Toggle(
                L10n.string("trafficToolbar.showComments"),
                isOn: Binding(
                    get: { appModel.settings.preferences.showCommentColumn },
                    set: { appModel.settings.preferences.showCommentColumn = $0 }))
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(L10n.string("trafficToolbar.more"))
        .help(L10n.string("trafficToolbar.more"))
    }

    private var contentLayout: Binding<ContentLayout> {
        Binding(
            get: { appModel.settings.preferences.contentLayout },
            set: { appModel.settings.preferences.contentLayout = $0 })
    }
}
