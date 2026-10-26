import AppCore
import AppKit
import Localization
import SwiftUI

struct GeneralPane: View {
    let appModel: AppModel
    @State private var languageChoice = LanguagePreference.standard.choice
    @State private var showsLanguageRestart = false

    private func name(of choice: LanguageChoice) -> String {
        choice.nativeName ?? L10n.string("generalPane.languageChoice.system")
    }

    var body: some View {
        @Bindable var settings = appModel.settings
        VStack(alignment: .leading, spacing: 16) {
            SettingsRow(title: L10n.string("generalPane.contentLayoutLabel")) {
                Picker(L10n.string("generalPane.contentLayout"), selection: $settings.preferences.contentLayout) {
                    Text(L10n.string("generalPane.vertical")).tag(ContentLayout.vertical)
                    Text(L10n.string("generalPane.horizontal")).tag(ContentLayout.horizontal)
                }.pickerStyle(.radioGroup).labelsHidden()
                Text(L10n.string("generalPane.contentLayoutHelp")).font(.caption).foregroundStyle(.secondary)
            }
            SettingsRow(title: L10n.string("generalPane.menuBarLabel")) {
                Toggle(
                    L10n.format("generalPane.menuBarIcon", AppInfo.name), isOn: $settings.preferences.showMenuBarIcon)
            }
            SettingsRow(title: L10n.string("generalPane.truncationLabel")) {
                Picker(L10n.string("generalPane.truncation"), selection: $settings.preferences.truncation) {
                    Text(L10n.string("generalPane.head")).tag(TruncationStyle.head)
                    Text(L10n.string("generalPane.middle")).tag(TruncationStyle.middle)
                    Text(L10n.string("generalPane.tail")).tag(TruncationStyle.tail)
                }.labelsHidden().frame(width: 120)
            }
            Divider()
            SettingsRow(title: L10n.string("advancedProxySheet.portLabel")) { ProxyPortEditor(appModel: appModel) }
            SettingsRow(title: "") {
                VStack(alignment: .leading, spacing: 9) {
                    Toggle(
                        L10n.string("generalPane.autoSystemProxy"),
                        isOn: $settings.preferences.autoOverrideSystemProxyAtLaunch)
                    Text(L10n.format("generalPane.autoSystemProxyHelp", AppInfo.name)).font(.caption)
                        .foregroundStyle(
                            .secondary)
                    Toggle(
                        L10n.string("generalPane.autoRecording"), isOn: $settings.preferences.autoStartRecordingAtLaunch
                    )
                    Text(L10n.string("generalPane.autoRecordingHelp")).font(.caption).foregroundStyle(.secondary)
                    Label(L10n.string("httpTransport.capabilityTitle"), systemImage: "network")
                    Text(HTTPTransportPresentation.capabilityDescription())
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(L10n.string("appCommands.advancedProxyAction")) {
                        appModel.showsAdvancedProxySettings = true
                    }
                }
            }
            Divider()
            SettingsRow(title: L10n.string("generalPane.behaviorLabel")) {
                Toggle(L10n.string("generalPane.alertOnQuit"), isOn: $settings.preferences.alertOnQuit)
            }
            SettingsRow(title: L10n.string("generalPane.languageLabel")) {
                Picker(L10n.string("generalPane.language"), selection: $languageChoice) {
                    ForEach(LanguageChoice.allCases, id: \.self) { Text(name(of: $0)).tag($0) }
                }
                .labelsHidden().fixedSize()
                .onChange(of: languageChoice) { _, choice in
                    LanguagePreference.standard.choice = choice
                    // Saved either way; the restart is offered only when the language in effect would change.
                    showsLanguageRestart = choice.changesLanguage(
                        from: L10n.localizer.languageCode, systemLanguages: LanguagePreference.systemLanguages,
                        bundle: L10n.bundle)
                }
            }
            Divider()
            CertificateBlock(appModel: appModel).id("certificate")
        }
        .alert(L10n.string("generalPane.languageRestart.title"), isPresented: $showsLanguageRestart) {
            Button(L10n.string("generalPane.languageRestart.restartNow")) {
                appModel.restart(using: .system) { NSApplication.shared.terminate(nil) }
            }
            Button(L10n.string("generalPane.languageRestart.later"), role: .cancel) {}
        } message: {
            Text(L10n.format("generalPane.languageRestart.message", AppInfo.name))
        }
    }
}

struct ProxyPortEditor: View {
    let appModel: AppModel
    @State private var text = ""
    @State private var isApplying = false
    private var port: Int? { Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) }
    private var valid: Bool { port.map { (1...65535).contains($0) } ?? false }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                TextField(L10n.string("generalPane.port"), text: $text).frame(width: 80).onSubmit(apply)
                Button(L10n.string("common.apply"), action: apply).disabled(!valid || isApplying)
                if isApplying { ProgressView().controlSize(.small) }
            }
            if !text.isEmpty && !valid {
                Text(L10n.string("appModel.invalidPort")).font(.caption).foregroundStyle(.red)
            }
            Text(
                appModel.listeningPort.map {
                    L10n.format("generalPane.currentListener", appModel.listenHost, String($0))
                } ?? L10n.string("mainToolbar.proxyStopped")
            )
            .font(.caption).foregroundStyle(.secondary)
            if let error = appModel.portError { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .onAppear { text = String(appModel.settings.port) }
        .onChange(of: appModel.settings.port) { text = String(appModel.settings.port) }
    }
    private func apply() {
        guard valid, !isApplying, let port else { return }
        isApplying = true
        Task {
            await appModel.setPort(port)
            isApplying = false
        }
    }
}
