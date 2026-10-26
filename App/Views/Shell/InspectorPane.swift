import AppCore
import FlowStore
import Localization
import SwiftUI

/// The right-hand tab area: overview, request details and the rules list. The selected tab lives on the shell model.
struct InspectorPane: View {
    let appModel: AppModel
    let flowList: FlowListModel

    @Environment(\.openWindow) private var openWindow

    private var shell: MainShellModel { appModel.shell }

    private static let tabs: [InspectorTab] = [.overview, .requestDetails, .rules]

    var body: some View {
        VStack(spacing: 0) {
            ShellTabStrip(
                tabs: Self.tabs,
                selection: Binding(
                    get: { Self.displayed(shell.inspector.tab) },
                    set: { shell.selectTab($0) }),
                title: { L10n.string($0.titleKey) },
                icon: { $0.icon },
                accessory: { tab in tab == .rules ? AnyView(rulesSwitch) : nil },
                iconOnlyWhenUnselected: true)
            content
        }
        .background(ShellStyle.color(.content))
    }

    /// The global rules switch beside the rules tab's title: off pauses every rule.
    private var rulesSwitch: some View {
        let rules = appModel.rulesSwitch
        return Toggle(
            L10n.string("rules.tab.switch"),
            isOn: Binding(get: { rules.isOn }, set: { rules.setOn($0) })
        )
        .toggleStyle(CapsuleSwitchStyle())
        .labelsHidden()
        .help(L10n.string("rules.tab.switch"))
        .accessibilityLabel(L10n.string("rules.tab.switch"))
    }

    static func displayed(_ tab: InspectorTab) -> InspectorTab {
        tabs.contains(tab) ? tab : .overview
    }

    @ViewBuilder private var content: some View {
        switch Self.displayed(shell.inspector.tab) {
        case .rules:
            RulesTab(appModel: appModel, flowList: flowList, openEditor: { openWindow(id: ProxyWomanApp.ruleEditorWindowID) })
        case .overview:
            if let flow = flowList.selectedFlow {
                InspectorOverviewTab(
                    flow: flow, ruleName: { id in appModel.rulesEditor.rules.first { $0.id == id }?.name },
                    cardIndex: { appModel.rulesEditor.outcomeCardIndex(rule: $0, stored: $1, code: $2) },
                    use24Hour: appModel.settings.preferences.use24HourTime)
            } else {
                emptyState
            }
        case .requestDetails:
            if let flow = flowList.selectedFlow {
                requestDetails(of: flow)
            } else {
                emptyState
            }
        }
    }

    /// A paused ticket is edited here; a ticket that ended on its own leaves a note above the read-only details.
    @ViewBuilder private func requestDetails(of flow: Flow) -> some View {
        let queue = appModel.breakpointQueue
        if let ticket = queue.ticket(forFlow: flow.id), let editor = queue.editor(for: ticket.id) {
            BreakpointInspector(queue: queue, editor: editor, flowList: flowList, rules: appModel.rulesEditor)
                .id(editor.id)
        } else if let ended = queue.ended(forFlow: flow.id) {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Palette.pendingColor)
                    Text(L10n.string(ended == .timedOut ? "breakpoints.inspector.ended.timedOut" : "breakpoints.inspector.ended.aborted"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button { queue.acknowledgeEnded(forFlow: flow.id) } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                        .help(L10n.string("common.close"))
                        .accessibilityLabel(L10n.string("common.close"))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Palette.pendingColor.opacity(0.12))
                Divider()
                FlowDetailView(flow: flow, appModel: appModel)
            }
        } else {
            FlowDetailView(flow: flow, appModel: appModel)
        }
    }

    private var emptyState: some View {
        Text(L10n.string("inspector.empty"))
            .foregroundStyle(ShellStyle.color(.textSecondary))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
