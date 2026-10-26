import AppKit
import Localization
import SwiftUI

struct MenuBarContent: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Text(AppInfo.name)
        if let port = model.listeningPort {
            Text(L10n.format("menuBarContent.listeningPort", String(port)))
        } else {
            Text(L10n.string("mainToolbar.proxyStopped"))
        }
        Divider()
        Button(
            model.isRecording ? L10n.string("appCommands.pauseRecording") : L10n.string("appCommands.startRecording")
        ) {
            model.setRecording(!model.isRecording)
        }
        Toggle(
            L10n.string("appCommands.systemProxy"),
            isOn: Binding(
                get: { model.isSystemProxyEnabled },
                set: { on in
                    if model.requestSystemProxy(on) { showSystemProxyConfirmation(openWindow: openWindow) }
                })
        )
        // Turning it off must stay possible even if the listener failed to start.
        .disabled(model.listeningPort == nil && !model.isSystemProxyEnabled)
        Divider()
        Button(L10n.string("menuBarContent.openMainWindow")) { MainWindowLocator.bringToFront(openWindow: openWindow) }
        Button(L10n.string("appCommands.settings")) {
            openSettings()
            NSApp.activate()
        }
        Divider()
        Button(L10n.format("appCommands.quitNamed", AppInfo.name)) { NSApp.terminate(nil) }
    }
}
