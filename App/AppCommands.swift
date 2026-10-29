import AppCore
import AppKit
import Localization
import RulesEngine
import SwiftUI

/// Only the active main scene supplies these actions. Settings and detail windows must not
/// accidentally change a different window's layout or use its selection.
struct MainWindowCommandTarget {
    let flowList: FlowListModel
    let exportHAR: () -> Void
    let copyCurl: () -> Void
    let focusSidebarFilter: () -> Void
}

/// Supplied by the Rules tab of the inspector while it has focus: the Edit menu's "Delete Rule" acts on its list selection.
struct RulesWindowCommandTarget {
    let canDeleteSelection: Bool
    /// Asks for confirmation first, like the list's minus button.
    let deleteSelection: () -> Void
}

private struct RulesWindowCommandKey: FocusedValueKey {
    typealias Value = RulesWindowCommandTarget
}

private struct MainWindowCommandKey: FocusedValueKey {
    typealias Value = MainWindowCommandTarget
}

extension FocusedValues {
    var rulesWindowCommands: RulesWindowCommandTarget? {
        get { self[RulesWindowCommandKey.self] }
        set { self[RulesWindowCommandKey.self] = newValue }
    }

    var mainWindowCommands: MainWindowCommandTarget? {
        get { self[MainWindowCommandKey.self] }
        set { self[MainWindowCommandKey.self] = newValue }
    }
}

struct AppCommands: Commands {
    let appModel: AppModel
    let flowList: FlowListModel
    @FocusedValue(\.mainWindowCommands) private var mainWindow
    @FocusedValue(\.rulesWindowCommands) private var rulesWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button(L10n.format("appCommands.about", AppInfo.name)) { NSApp.orderFrontStandardAboutPanel(nil) }
        }
        // The Settings scene supplies "Settings…" (⌘,) itself; replacing `.appSettings` as well listed it twice.
        CommandGroup(replacing: .appTermination) {
            Button(L10n.format("appCommands.quitNamed", AppInfo.name)) { NSApp.terminate(nil) }
                .shellShortcut(.quit)
        }
        // The group already replaced the system "New Window" (⌘N was unused): New Request takes ⌘N
        // and Export HAR keeps its own shortcut.
        CommandGroup(replacing: .newItem) {
            Button(L10n.string("compose.command.newRequest")) {
                appModel.composeWorkspace.newBlankTab()
                appModel.shell.page = .compose
                MainWindowLocator.bringToFront(openWindow: openWindow)
            }
            .shellShortcut(.newRequest)
            Divider()
            Button(L10n.string("appCommands.exportHAR")) { mainWindow?.exportHAR() }
                .shellShortcut(.exportHAR)
                .disabled(mainWindow?.flowList.visible.isEmpty != false)
        }
        CommandGroup(after: .pasteboard) {
            Button(L10n.string("appCommands.copyCurl")) { mainWindow?.copyCurl() }
                .shellShortcut(.copyCurl)
                .disabled(mainWindow?.flowList.selectedFlow.map { $0.method != "CONNECT" } != true)
            Divider()
            // The flow table's context-menu actions on the selected flow, for the keyboard and the menu bar.
            Button(L10n.string("repeat.entry.menu")) {
                if let flow = mainWindow?.flowList.selectedFlow { appModel.beginRepeat(flow: flow) }
            }
            .shellShortcut(.repeatRequest)
            .disabled(mainWindow == nil || !appModel.canRepeat(flow: mainWindow?.flowList.selectedFlow))
            Button(L10n.string("rules.mock.menu")) {
                if let flow = mainWindow?.flowList.selectedFlow {
                    appModel.saveResponseAsMock(
                        flow: flow,
                        openRules: {
                            appModel.shell.showRules()
                            MainWindowLocator.bringToFront(openWindow: openWindow)
                        },
                        openEditor: { openWindow(id: ProxyWomanApp.ruleEditorWindowID) })
                }
            }
            .shellShortcut(.saveAsMock)
            .disabled(mainWindow == nil || !appModel.canSaveResponseAsMock(flow: mainWindow?.flowList.selectedFlow))
            Divider()
            Button(L10n.string("rules.action.delete")) { rulesWindow?.deleteSelection() }
                .disabled(rulesWindow?.canDeleteSelection != true)
            Divider()
            Button(L10n.string("appCommands.clear")) { mainWindow?.flowList.requestClear() }
                .shellShortcut(.clear)
                .disabled(mainWindow == nil)
        }
        CommandGroup(before: .toolbar) {
            Button(L10n.string("appCommands.showTraffic")) { showPage(.traffic) }
                .shellShortcut(.showTraffic)
            Button(L10n.string("appCommands.showCompose")) { showPage(.compose) }
                .shellShortcut(.showCompose)
            Divider()
            Button(L10n.string("appCommands.filter")) { mainWindow?.focusSidebarFilter() }
                .shellShortcut(.focusFilter)
                .disabled(mainWindow == nil)
            Toggle(
                L10n.string("appCommands.autoSelectLatest"),
                isOn: Binding(
                    get: { mainWindow?.flowList.autoSelectsLatest ?? false },
                    set: { mainWindow?.flowList.autoSelectsLatest = $0 })
            )
            .disabled(mainWindow == nil)
            Button(
                appModel.shell.inspector.sourceBarVisible
                    ? L10n.string("appCommands.hideSidebar") : L10n.string("appCommands.showSidebar")
            ) {
                appModel.shell.setSourceBarVisible(!appModel.shell.inspector.sourceBarVisible)
            }
            .shellShortcut(.toggleSourceBar)
            .disabled(mainWindow == nil)
            Button(
                appModel.shell.inspector.isCollapsed
                    ? L10n.string("inspector.toggle.show") : L10n.string("inspector.toggle.hide")
            ) {
                appModel.shell.toggleCollapsed()
            }
            .shellShortcut(.toggleInspector)
            .disabled(mainWindow == nil)
            Picker(L10n.string("appCommands.detailLayout"), selection: contentLayout) {
                Text(L10n.string("appCommands.verticalLayout")).tag(ContentLayout.vertical)
                Text(L10n.string("appCommands.horizontalLayout")).tag(ContentLayout.horizontal)
            }
            .disabled(mainWindow == nil)
            Divider()
        }
        CommandMenu(L10n.string("appCommands.tools")) {
            Button(
                appModel.isRecording
                    ? L10n.string("appCommands.pauseRecording") : L10n.string("appCommands.startRecording")
            ) {
                appModel.setRecording(!appModel.isRecording)
            }
            .shellShortcut(.record)
            Toggle(L10n.string("appCommands.systemProxy"), isOn: systemProxy)
                .shellShortcut(.systemProxy)
                .disabled(appModel.listeningPort == nil && !appModel.isSystemProxyEnabled)
            Divider()
            Button(L10n.string("rules.command.open")) {
                appModel.shell.showRules()
                MainWindowLocator.bringToFront(openWindow: openWindow)
            }
                .shellShortcut(.showRules)
            // A blank rule in the rule editor window, reachable from the keyboard and the menu bar.
            Button(L10n.string("rules.action.new")) {
                appModel.ruleEditorSession.openNew(inGroup: nil)
                openWindow(id: ProxyWomanApp.ruleEditorWindowID)
            }
            .disabled(!appModel.rulesEditor.canMutate)
            Toggle(
                L10n.string("rules.globalSwitch.toggle"),
                isOn: Binding(get: { appModel.rulesSwitch.isOn }, set: { appModel.rulesSwitch.setOn($0) }))
            Button(L10n.string("breakpoints.command.open")) {
                MainWindowLocator.bringToFront(openWindow: openWindow)
                flowList.selectEarliestPaused(of: appModel.breakpointQueue.pausedFlowIDs)
                appModel.shell.focusRequestDetails()
            }
                .shellShortcut(.showBreakpoints)
            Divider()
            trafficToolsItems
            Divider()
            Button(L10n.string("appCommands.sslListAction")) {
                appModel.prepareHTTPSSettings()
                openSettings()
            }
            Button(L10n.string("appCommands.advancedProxyAction")) {
                appModel.prepareAdvancedProxySettings()
                openSettings()
            }
        }
        CommandMenu(L10n.string("appCommands.certificate")) {
            Button(L10n.string("appCommands.installCertificateAction")) {
                appModel.prepareCertificateSettings()
                openSettings()
            }
            Button(L10n.string("appCommands.installOnPhoneAction")) {
                appModel.prepareAdvancedProxySettings()
                openSettings()
            }
            Button(L10n.string("appCommands.exportCertificateAction"), action: appModel.exportCertificate)
            Button(L10n.string("appCommands.showInFinder"), action: appModel.revealCertificate)
            Divider()
            Button(L10n.string("appCommands.removeTrustAction"), action: appModel.confirmAndRemoveCertificateTrust)
                .disabled(!appModel.isCATrusted)
        }
    }

    /// Disable Caching, the Network Conditions submenu and the list entries. The switches last for
    /// this run only (the model starts them off).
    @ViewBuilder private var trafficToolsItems: some View {
        let tools = appModel.trafficTools
        let conditions = tools.policy.conditions
        Toggle(
            L10n.string("traffic.noCaching.menu"),
            isOn: Binding(get: { tools.policy.noCaching }, set: { tools.setNoCaching($0) })
        )
        .shellShortcut(.noCaching)
        Menu(L10n.string("traffic.conditions.menu")) {
            Toggle(
                L10n.string("traffic.conditions.off"),
                isOn: Binding(get: { !conditions.enabled }, set: { _ in tools.setConditionsEnabled(false) }))
            Divider()
            ForEach(NetworkPreset.allCases, id: \.self) { preset in
                Toggle(
                    TrafficPresentation.title(of: preset),
                    isOn: Binding(
                        get: { conditions.enabled && conditions.global == .preset(preset) },
                        set: { _ in
                            tools.setGlobalCondition(.preset(preset))
                            tools.setConditionsEnabled(true)
                        }))
            }
            Divider()
            Button(L10n.string("traffic.conditions.custom")) {
                trafficControl(.conditions)
            }
        }
        Button(TrafficToolsTab.allow.title) { trafficControl(.allow) }
            .shellShortcut(.allowList)
        Button(TrafficToolsTab.block.title) { trafficControl(.block) }
            .shellShortcut(.blockList)
        Button(L10n.string("traffic.command.conditionsWindow")) {
            trafficControl(.conditions)
        }
        .shellShortcut(.networkConditions)
    }

    private func showPage(_ page: ShellPage) {
        appModel.shell.page = page
        MainWindowLocator.bringToFront(openWindow: openWindow)
    }

    private func trafficControl(_ tab: TrafficToolsTab) {
        appModel.prepareTrafficControl(tab)
        openSettings()
    }

    private var contentLayout: Binding<ContentLayout> {
        Binding(
            get: { appModel.settings.preferences.contentLayout },
            set: { layout in
                guard mainWindow != nil else { return }
                appModel.settings.preferences.contentLayout = layout
            })
    }

    private var systemProxy: Binding<Bool> {
        Binding(
            get: { appModel.isSystemProxyEnabled },
            set: { on in
                if appModel.requestSystemProxy(on) { showSystemProxyConfirmation(openWindow: openWindow) }
            })
    }
}

extension KeyboardShortcut {
    init(_ shortcut: ShellShortcut) {
        var modifiers: EventModifiers = []
        if shortcut.command { modifiers.insert(.command) }
        if shortcut.shift { modifiers.insert(.shift) }
        if shortcut.option { modifiers.insert(.option) }
        if shortcut.control { modifiers.insert(.control) }
        self.init(shortcut.key == "\r" ? .return : KeyEquivalent(shortcut.key), modifiers: modifiers)
    }
}

extension View {
    /// The menu item's shortcut, taken from the one table in `ShellShortcuts`.
    func shellShortcut(_ command: ShellCommand) -> some View {
        keyboardShortcut(ShellShortcuts.shortcut(for: command).map(KeyboardShortcut.init))
    }
}
