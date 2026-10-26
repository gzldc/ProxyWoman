import AppKit
import Localization
import SwiftUI

@main
struct ProxyWomanApp: App {
    nonisolated static let mainWindowID = "main"
    static let ruleEditorWindowID = "rule-editor"

    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        // One window over the app-lifetime model: closing and reopening it loses no page, tab or layout.
        Window(AppInfo.name, id: Self.mainWindowID) {
            MainWindow(appModel: delegate.model, flowList: delegate.flowList)
        }
        .commands { AppCommands(appModel: delegate.model, flowList: delegate.flowList) }
        .defaultSize(width: 1440, height: 820)
        // The proxy status in the middle of the toolbar replaces the window title.
        .windowToolbarStyle(.unified(showsTitle: false))
        // The rule editor: one window over the app-lifetime session, so closing it loses no edit; opened only by the user.
        Window(L10n.string("rules.editor2.title.edit"), id: Self.ruleEditorWindowID) {
            RuleEditorWindow(session: delegate.model.ruleEditorSession, store: delegate.model.store, flowList: delegate.flowList)
        }
        .defaultSize(width: 1350, height: 750)
        MenuBarExtra(
            isInserted: Binding(
                get: { delegate.model.settings.preferences.showMenuBarIcon },
                set: { inserted in
                    // SwiftUI may write the current insertion state during scene updates.
                    // Avoid entering Observation's modify accessor for an unchanged value.
                    guard delegate.model.settings.preferences.showMenuBarIcon != inserted else { return }
                    delegate.model.settings.preferences.showMenuBarIcon = inserted
                }
            )
        ) {
            MenuBarContent(model: delegate.model)
        } label: {
            MenuBarIconLabel()
        }
        Settings {
            SettingsWindow(appModel: delegate.model)
        }
        .windowResizability(.contentMinSize)
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    let model: AppModel
    /// Shared by every main window: the store allows a single change subscriber.
    let flowList: FlowListModel

    /// The model and list of this process; tests pass their own.
    init(model: AppModel, flowList: FlowListModel) {
        self.model = model
        self.flowList = flowList
        super.init()
    }

    override convenience init() {
        let runtime: AppRuntime
        switch AppRuntime.startupForThisProcess() {
        case .run(let decided):
            runtime = decided
        case .refuse(let refusal):
            // An unsafe or ambiguous launch never falls back to the real data, proxy or trust.
            FileHandle.standardError.write(Data((refusal.message + "\n").utf8))
            exit(refusal.exitCode)
        }
        let model = AppModel(runtime: runtime)
        self.init(model: model, flowList: FlowListModel(store: model.store, breakpoints: model.breakpointClient))
    }

    /// Before the first window is shown, so it opens in the chosen theme.
    func applicationWillFinishLaunching(_ notification: Notification) {
        model.followThemePreference()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { await model.launch() }
    }

    /// The user may have trusted (or distrusted) the root in Keychain Access meanwhile.
    func applicationDidBecomeActive(_ notification: Notification) {
        model.refreshTrust()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // A restart's own quit goes ahead without the confirmation, and consumes the one-shot mark.
        if model.takeRestartForTermination() { return .terminateNow }
        guard model.settings.preferences.alertOnQuit, model.isSystemProxyEnabled else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = L10n.string("proxyWomanApp.quitRestoresProxy")
        alert.informativeText = L10n.format("app.quit.confirmation", AppInfo.name)
        alert.addButton(withTitle: L10n.string("proxyWomanApp.quit"))
        alert.addButton(withTitle: L10n.string("common.cancel"))
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.shutdown()
    }
}
