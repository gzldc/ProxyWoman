import AppCore
import FlowStore
import Localization
import SwiftUI

/// "实时流量": 全部流量, 已固定, 应用 (each app expands to its hosts), 域名, 已标记, 已隐藏 and 未解密 (expands to
/// hosts). Selecting a row applies `SourceBarItem.apply(to:)` to the list filter; the field at the bottom filters
/// the rows only.
struct SourceBarView: View {
    let appModel: AppModel
    let flowList: FlowListModel
    var searchFocus: FocusState<Bool>.Binding

    /// The row the user clicked. Several rows share a filter (every pinned / app / host group row addresses
    /// everything), so the highlight tracks the row itself and falls back to `SourceBarItem.item(for:)` only when
    /// the filter was changed elsewhere.
    @State private var selection: SourceBarItem?
    @State private var expanded: Set<SourceBarItem> = [.pinned]
    @State private var searchText = ""
    @FocusState private var isSourceBarFocused: Bool

    private var tally: SourceBarTally { flowList.sourceTally }

    var body: some View {
        ScrollViewReader { proxy in
            // SwiftUI's outline-backed List recursively estimates row heights during its
            // initial diff on macOS. These disclosures have no AppKit table row-height cache.
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    Text(L10n.string("sourceBar.title"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(ShellStyle.color(.textSecondary))
                        .padding(.top, 10)
                        .padding(.bottom, 4)
                        .padding(.horizontal, 6)
                        .accessibilityAddTraits(.isHeader)
                    selectableRow(.all, title: L10n.string("sourceBar.all"), count: tally.allCount) {
                        Label(L10n.string("sourceBar.all"), systemImage: "tray.full")
                    }
                    DisclosureGroup(isExpanded: isExpanded(.pinned)) {
                        if expanded.contains(.pinned) {
                            LazyVStack(alignment: .leading, spacing: 2) { pinnedRows }
                        }
                    } label: {
                        selectableRow(.pinned, title: L10n.string("sidebarView.pinned")) {
                            Label(L10n.string("sidebarView.pinned"), systemImage: "pin")
                        }
                    }
                    .accessibilityLabel(L10n.string("sidebarView.pinned"))
                    DisclosureGroup(isExpanded: isExpanded(.apps)) {
                        if expanded.contains(.apps) {
                            LazyVStack(alignment: .leading, spacing: 2) {
                                ForEach(matching(flowList.appGroups), id: \.name) { group in
                                    appRow(group)
                                }
                            }
                        }
                    } label: {
                        selectableRow(.apps, title: L10n.string("sidebarView.apps"), count: flowList.appGroups.count) {
                            Label(L10n.string("sidebarView.apps"), systemImage: "square.grid.2x2")
                        }
                    }
                    .accessibilityLabel(L10n.string("sidebarView.apps"))
                    DisclosureGroup(isExpanded: isExpanded(.hosts)) {
                        if expanded.contains(.hosts) {
                            LazyVStack(alignment: .leading, spacing: 2) {
                                ForEach(matching(flowList.hostGroups), id: \.name) { group in
                                    hostRow(group.name, count: group.count, item: .host(group.name))
                                }
                            }
                        }
                    } label: {
                        selectableRow(.hosts, title: L10n.string("sidebarView.domains"), count: flowList.hostGroups.count) {
                            Label(L10n.string("sidebarView.domains"), systemImage: "globe")
                        }
                    }
                    .accessibilityLabel(L10n.string("sidebarView.domains"))
                    selectableRow(.marked, title: L10n.string("sourceBar.marked"), count: tally.markedCount) {
                        Label(L10n.string("sourceBar.marked"), systemImage: "flag")
                    }
                    selectableRow(.hidden, title: L10n.string("sourceBar.hidden"), count: tally.hiddenCount) {
                        Label(L10n.string("sourceBar.hidden"), systemImage: "eye.slash")
                    }
                    DisclosureGroup(isExpanded: isExpanded(.undecrypted)) {
                        if expanded.contains(.undecrypted) {
                            LazyVStack(alignment: .leading, spacing: 2) {
                                ForEach(matching(tally.undecryptedHosts), id: \.name) { group in
                                    hostRow(group.name, count: group.count, item: .undecryptedHost(group.name))
                                }
                            }
                        }
                    } label: {
                        selectableRow(.undecrypted, title: L10n.string("sourceBar.undecrypted"), count: tally.undecryptedCount) {
                            Label(L10n.string("sourceBar.undecrypted"), systemImage: "lock.open")
                        }
                    }
                    .accessibilityLabel(L10n.string("sourceBar.undecrypted"))
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 10)
            }
            .focusable()
            .focusEffectDisabled()
            .focused($isSourceBarFocused)
            .onMoveCommand { direction in
                switch direction {
                case .up: navigate(.up)
                case .down: navigate(.down)
                case .left: navigate(.left)
                case .right: navigate(.right)
                @unknown default: break
                }
            }
            .onKeyPress(.return) { navigate(.activate); return .handled }
            .onKeyPress(.space) { navigate(.activate); return .handled }
            .onChange(of: selectedItem) { _, item in proxy.scrollTo(item) }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                TextField(
                    L10n.string("appCommands.filter"), text: $searchText,
                    prompt: Text(L10n.string("sidebarView.filterShortcut"))
                )
                .focused(searchFocus)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
            }
        }
    }

    // MARK: Rows

    @ViewBuilder private var pinnedRows: some View {
        let preferences = appModel.settings.preferences
        ForEach(preferences.pinnedApps.filter(matches), id: \.self) { name in
            let count = flowList.appGroups.first { $0.name == name }?.count ?? 0
            selectableRow(.pinnedApp(name), title: SourceBarItem.appDisplayName(name), count: count, isEnabled: count > 0) {
                AppLabel(name: SourceBarItem.appDisplayName(name), path: flowList.executablePath(ofApp: name))
            }
            .contextMenu { pinButton(app: name) }
        }
        ForEach(preferences.pinnedHosts.filter(matches), id: \.self) { host in
            let count = flowList.hostGroups.first { $0.name == host }?.count ?? 0
            hostRow(host, count: count, item: .pinnedHost(host), isEnabled: count > 0)
        }
    }

    private func appRow(_ group: GroupCount) -> some View {
        let item = SourceBarItem.app(group.name)
        return DisclosureGroup(isExpanded: isExpanded(item)) {
            // Built only while expanded.
            if expanded.contains(item) {
                AppHostRows(flowList: flowList, app: group.name) { host, count in
                    hostRow(host, count: count, item: .appHost(app: group.name, host: host))
                }
            }
        } label: {
            selectableRow(item, title: SourceBarItem.appDisplayName(group.name), count: group.count) {
                AppLabel(name: SourceBarItem.appDisplayName(group.name), path: flowList.executablePath(ofApp: group.name))
            }
            .contextMenu { pinButton(app: group.name) }
        }
        .accessibilityLabel(SourceBarItem.appDisplayName(group.name))
    }

    private func hostRow(_ host: String, count: Int, item: SourceBarItem, isEnabled: Bool = true) -> some View {
        selectableRow(item, title: host, count: count, isEnabled: isEnabled) {
            Label(host, systemImage: "globe")
        }
        .contextMenu {
            pinButton(host: host)
            decryptionToggle(for: host)
        }
    }

    private func selectableRow<Content: View>(
        _ item: SourceBarItem, title: String, count: Int? = nil, isEnabled: Bool = true,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let isSelected = selectedItem == item
        return Button {
            selectedItemBinding.wrappedValue = item
            isSourceBarFocused = true
        } label: {
            HStack {
                content().lineLimit(1)
                Spacer(minLength: 4)
                if let count {
                    Text(count, format: .number)
                        .monospacedDigit()
                        .foregroundStyle(ShellStyle.color(.textSecondary))
                }
            }
            .font(.system(size: 12, weight: isSelected ? .medium : .regular))
            .foregroundStyle(ShellStyle.color(.textPrimary))
            .padding(.horizontal, 6)
            .frame(minHeight: ShellStyle.rowHeight)
            .contentShape(Rectangle())
            .background(
                isSelected ? ShellStyle.color(.selection) : Color.clear,
                in: RoundedRectangle(cornerRadius: ShellStyle.cornerRadius))
        }
        .buttonStyle(.plain)
        .focusable(false)
        .disabled(!isEnabled)
        // The row cuts a long name (an app, a host, a longer English title); hovering shows it whole.
        .help(title)
        .accessibilityLabel(count.map { L10n.format("sourceBar.count.accessibility", title, $0) } ?? title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .id(item)
    }

    /// Built only for a key event, using exactly the same expansion/filter state as the rows.
    private func navigationRows() -> [SidebarNavigationRow<SourceBarItem>] {
        var rows: [SidebarNavigationRow<SourceBarItem>] = []
        func group(_ item: SourceBarItem, parent: SourceBarItem? = nil) {
            rows.append(.init(id: item, parent: parent, canExpand: true, isExpanded: expanded.contains(item)))
        }
        rows.append(.init(id: .all))
        group(.pinned)
        if expanded.contains(.pinned) {
            for name in appModel.settings.preferences.pinnedApps.filter(matches) {
                let count = flowList.appGroups.first { $0.name == name }?.count ?? 0
                rows.append(.init(id: .pinnedApp(name), parent: .pinned, isEnabled: count > 0))
            }
            for host in appModel.settings.preferences.pinnedHosts.filter(matches) {
                let count = flowList.hostGroups.first { $0.name == host }?.count ?? 0
                rows.append(.init(id: .pinnedHost(host), parent: .pinned, isEnabled: count > 0))
            }
        }
        group(.apps)
        if expanded.contains(.apps) {
            for app in matching(flowList.appGroups) {
                let item = SourceBarItem.app(app.name)
                group(item, parent: .apps)
                if expanded.contains(item) {
                    for host in flowList.hostGroups(ofApp: app.name) {
                        rows.append(.init(id: .appHost(app: app.name, host: host.name), parent: item))
                    }
                }
            }
        }
        group(.hosts)
        if expanded.contains(.hosts) {
            for host in matching(flowList.hostGroups) { rows.append(.init(id: .host(host.name), parent: .hosts)) }
        }
        rows.append(.init(id: .marked))
        rows.append(.init(id: .hidden))
        group(.undecrypted)
        if expanded.contains(.undecrypted) {
            for host in matching(tally.undecryptedHosts) {
                rows.append(.init(id: .undecryptedHost(host.name), parent: .undecrypted))
            }
        }
        return rows
    }

    private func navigate(_ direction: SidebarNavigation.Direction) {
        guard let action = SidebarNavigation.action(direction, selected: selectedItem, rows: navigationRows())
        else { return }
        switch action {
        case .select(let item): selectedItemBinding.wrappedValue = item
        case .expand(let item, let isOn): isExpanded(item).wrappedValue = isOn
        }
    }

    // MARK: Context menu

    private func pinButton(app name: String) -> some View {
        let isPinned = appModel.settings.preferences.isPinned(app: name)
        return Button(isPinned ? L10n.string("sidebarView.unpin") : L10n.string("sidebarView.pin")) {
            appModel.settings.preferences.setPinned(!isPinned, app: name)
        }
    }

    private func pinButton(host: String) -> some View {
        let isPinned = appModel.settings.preferences.isPinned(host: host)
        return Button(isPinned ? L10n.string("sidebarView.unpin") : L10n.string("sidebarView.pin")) {
            appModel.settings.preferences.setPinned(!isPinned, host: host)
        }
    }

    private func decryptionToggle(for host: String) -> some View {
        let excluded = appModel.settings.decryption.hasActiveExactExclusion(for: host)
        return Button(
            excluded
                ? L10n.string("sidebarView.enableHostDecryption") : L10n.string("sidebarView.disableHostDecryption")
        ) {
            appModel.setDecryption(excluded: !excluded, for: host)
        }
    }

    // MARK: State

    /// The clicked row while the list filter is still the one it set; otherwise the row the filter implies
    /// (the filter was changed elsewhere, e.g. by "查看" or because a group vanished).
    private var selectedItem: SourceBarItem {
        let filter = flowList.filter
        if let selection, selection.scope == filter.scope, selection.source == filter.source { return selection }
        return SourceBarItem.item(for: filter)
    }

    private var selectedItemBinding: Binding<SourceBarItem> {
        Binding(
            get: { selectedItem },
            set: { item in
                selection = item
                var filter = flowList.filter
                item.apply(to: &filter)
                flowList.filter = filter
            })
    }

    private func isExpanded(_ item: SourceBarItem) -> Binding<Bool> {
        Binding(
            get: { expanded.contains(item) },
            set: { isOn in
                if isOn {
                    expanded.insert(item)
                } else {
                    expanded.remove(item)
                }
            })
    }

    private func matches(_ name: String) -> Bool {
        let needle = searchText.trimmingCharacters(in: .whitespaces)
        return needle.isEmpty || name.localizedCaseInsensitiveContains(needle)
            || SourceBarItem.appDisplayName(name).localizedCaseInsensitiveContains(needle)
    }

    private func matching(_ groups: [GroupCount]) -> [GroupCount] {
        groups.filter { matches($0.name) }
    }
}

/// The hosts under an expanded app. A separate view so that only it follows every batch.
private struct AppHostRows<Row: View>: View {
    let flowList: FlowListModel
    let app: String
    @ViewBuilder let row: (String, Int) -> Row

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 2) {
            ForEach(flowList.hostGroups(ofApp: app), id: \.name) { group in
                row(group.name, group.count)
            }
        }
    }
}

private struct AppLabel: View {
    let name: String
    let path: String?

    var body: some View {
        Label {
            Text(name)
        } icon: {
            Image(nsImage: AppIconCache.shared.icon(forExecutable: path))
                .resizable()
                .frame(width: 16, height: 16)
        }
    }
}
