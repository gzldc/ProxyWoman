import AppCore
import AppKit
import Darwin
import Localization
import SwiftUI

struct AdvancedProxySheet: View {
    let appModel: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @State private var showsPlaceholder = false
    @State private var localIP = L10n.string("advancedProxySheet.noIPv4")

    var body: some View {
        @Bindable var settings = appModel.settings
        VStack(alignment: .leading, spacing: 18) {
            Text(L10n.string("advancedProxySheet.advancedProxy")).font(.title2.bold())
            SettingsRow(title: L10n.string("advancedProxySheet.runningStatus")) {
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(
                            appModel.isSystemProxyEnabled
                                ? L10n.string("advancedProxySheet.proxyEnabled")
                                : L10n.string("advancedProxySheet.proxyDisabled"),
                            systemImage: appModel.isSystemProxyEnabled ? "checkmark.circle.fill" : "circle"
                        )
                        .foregroundStyle(appModel.isSystemProxyEnabled ? .green : .secondary)
                        Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                            statusRow(L10n.string("advancedProxySheet.localIP"), localIP)
                            statusRow(
                                L10n.string("advancedProxySheet.proxyPort"),
                                appModel.listeningPort.map(String.init) ?? L10n.string("advancedProxySheet.notRunning"))
                            statusRow(
                                L10n.string("advancedProxySheet.recording"),
                                appModel.isRecording
                                    ? L10n.string("advancedProxySheet.on") : L10n.string("advancedProxySheet.off"))
                            statusRow(L10n.string("httpTransport.capabilityTitle"), HTTPTransportPresentation.capabilityDescription())
                            statusRow(
                                L10n.string("advancedProxySheet.upstreamProxy"), appModel.upstreamProxyDescription)
                        }.font(.callout).textSelection(.enabled)
                    }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                }
                Button(
                    appModel.isSystemProxyEnabled
                        ? L10n.string("advancedProxySheet.disableProxy") : L10n.string("advancedProxySheet.enableProxy")
                ) {
                    if appModel.requestSystemProxy(!appModel.isSystemProxyEnabled) {
                        dismiss()
                        showSystemProxyConfirmation(openWindow: openWindow)
                    }
                }.disabled(appModel.listeningPort == nil && !appModel.isSystemProxyEnabled)
            }
            Divider()
            SettingsRow(title: L10n.string("advancedProxySheet.portLabel")) { ProxyPortEditor(appModel: appModel) }
            SettingsRow(title: "") {
                Toggle(L10n.string("advancedProxySheet.autoPort"), isOn: $settings.preferences.autoSelectAvailablePort)
                Text(L10n.string("advancedProxySheet.autoPortHelp")).font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            SettingsRow(title: L10n.string("advancedProxySheet.advancedLabel")) {
                Toggle(L10n.string("advancedProxySheet.localhostOnly"), isOn: .constant(true)).disabled(true)
                Text(L10n.string("advancedProxySheet.localhostHelp")).font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(L10n.string("advancedProxySheet.resetDefaults")) {
                        settings.preferences.autoSelectAvailablePort = true
                        Task { await appModel.setPort(AppInfo.defaultPort) }
                    }
                    Button(L10n.string("advancedProxySheet.upstreamSettings")) { showsPlaceholder = true }
                }
            }
            HStack {
                Spacer()
                Button(L10n.string("advancedProxySheet.done")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 600)
        .onAppear { localIP = Self.firstLocalIPv4() ?? L10n.string("advancedProxySheet.noIPv4") }
        .alert(L10n.string("advancedProxySheet.availableLater"), isPresented: $showsPlaceholder) {
            Button(L10n.string("advancedProxySheet.ok"), role: .cancel) {}
        } message: {
            Text(L10n.string("advancedProxySheet.upstreamSettingsHelp"))
        }
    }

    private func statusRow(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Read-only interface enumeration, no socket binding or network request.
    private static func firstLocalIPv4() -> String? {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0 else { return nil }
        defer { freeifaddrs(interfaces) }
        var cursor = interfaces
        while let item = cursor {
            let interface = item.pointee
            cursor = interface.ifa_next
            guard let address = interface.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                interface.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
                interface.ifa_flags & UInt32(IFF_UP) != 0
            else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(
                address, socklen_t(address.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST)
                == 0
            {
                return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            }
        }
        return nil
    }
}

/// Confirmation continues to live on MainWindow; settings brings that window forward.
@MainActor func showSystemProxyConfirmation(openWindow: OpenWindowAction) {
    MainWindowLocator.bringToFront(openWindow: openWindow)
}
