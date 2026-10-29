import AppCore
import AppKit
import CoreImage
import ProxyCore
import Darwin
import Localization
import SwiftUI

struct AdvancedProxySheet: View {
    let appModel: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @State private var showsUpstream = false
    @State private var localIP = L10n.string("advancedProxySheet.noIPv4")

    var body: some View {
        @Bindable var settings = appModel.settings
        // The phone setup box makes the content taller than the Settings window, so it scrolls
        // while Done stays visible.
        VStack(spacing: 0) {
            ScrollView {
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
                                VStack(alignment: .leading, spacing: 8) {
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
                        Toggle(
                            L10n.string("advancedProxySheet.lanDevices"),
                            isOn: Binding(
                                get: { settings.preferences.allowLANDevices },
                                set: { on in Task { await appModel.setAllowsLANDevices(on) } })
                        )
                        .disabled(appModel.isolatedRoot != nil)
                        Text(
                            settings.preferences.allowLANDevices
                                ? L10n.string("advancedProxySheet.lanHelp") : L10n.string("advancedProxySheet.localOnlyHelp")
                        ).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        if settings.preferences.allowLANDevices {
                            DeviceSetupBox(address: Self.firstLocalIPv4(), port: appModel.listeningPort ?? settings.port)
                        }
                        HStack {
                            Button(L10n.string("advancedProxySheet.resetDefaults")) {
                                settings.preferences.autoSelectAvailablePort = true
                                Task {
                                    await appModel.setAllowsLANDevices(false)
                                    await appModel.setPort(AppInfo.defaultPort)
                                }
                            }
                            Button(L10n.string("advancedProxySheet.upstreamSettings")) { showsUpstream = true }
                        }
                    }
                }
                .padding(24)
                .fixedSize(horizontal: false, vertical: true) // wrapped text must not overlap the next row
            }
            .frame(maxHeight: 560)
            Divider()
            HStack {
                Spacer()
                Button(L10n.string("advancedProxySheet.done")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24).padding(.vertical, 14)
        }
        .frame(width: 600)
        .onAppear { localIP = Self.firstLocalIPv4() ?? L10n.string("advancedProxySheet.noIPv4") }
        .sheet(isPresented: $showsUpstream) { UpstreamProxySheet(appModel: appModel) }
    }

    private func statusRow(_ title: String, _ value: String) -> some View {
        // Plain rows: a Grid inside the scroll view measured wrapped values too short and overlapped the next row.
        HStack(alignment: .firstTextBaseline, spacing: 20) {
            Text(title).foregroundStyle(.secondary).frame(width: 150, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Text(value).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Read-only interface enumeration, no socket binding or network request.
    static func firstLocalIPv4() -> String? {
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

/// How to point a phone at this Mac: proxy address, the certificate download link and its QR code.
private struct DeviceSetupBox: View {
    let address: String?
    let port: Int

    var body: some View {
        GroupBox {
            if let address {
                let link = "http://\(address):\(port)\(CertificateDownload.path)"
                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L10n.string("advancedProxySheet.deviceSetupTitle")).font(.headline)
                        Text(L10n.format("advancedProxySheet.deviceStep1", address, String(port)))
                        HStack(alignment: .firstTextBaseline) {
                            Text(L10n.format("advancedProxySheet.deviceStep2", link))
                            Button(L10n.string("advancedProxySheet.copyAddress")) {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(link, forType: .string)
                            }.controlSize(.small)
                        }
                        Text(L10n.string("advancedProxySheet.deviceStep3")).foregroundStyle(.secondary)
                    }
                    .font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    if let image = QRCode.image(for: link) {
                        Image(nsImage: image).interpolation(.none).resizable().frame(width: 120, height: 120)
                            .accessibilityLabel(link)
                    }
                }.padding(6)
            } else {
                Text(L10n.string("advancedProxySheet.deviceNoNetwork")).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// A QR code image for a short text, drawn with Core Image.
enum QRCode {
    static func image(for text: String) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}

/// Upstream proxy choice: follow the original system proxy, a manual HTTP proxy, or direct.
struct UpstreamProxySheet: View {
    let appModel: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var mode: UpstreamMode = .automatic
    @State private var host = ""
    @State private var portText = ""
    @State private var bypassText = ""

    private var manual: ManualUpstream {
        ManualUpstream(
            host: host.trimmingCharacters(in: .whitespaces),
            port: Int(portText.trimmingCharacters(in: .whitespaces)) ?? 0,
            bypass: bypassText.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty })
    }

    private var canApply: Bool { mode != .manual || manual.isUsable }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.string("upstream.title")).font(.title2.bold())
            Text(L10n.string("upstream.intro")).foregroundStyle(.secondary)
            Picker("", selection: $mode) {
                Text(L10n.string("upstream.mode.automatic")).tag(UpstreamMode.automatic)
                Text(L10n.string("upstream.mode.manual")).tag(UpstreamMode.manual)
                Text(L10n.string("upstream.mode.direct")).tag(UpstreamMode.direct)
            }
            .pickerStyle(.radioGroup).labelsHidden()
            if mode == .automatic {
                Text(L10n.string("upstream.mode.automaticHelp")).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if mode == .manual {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                    GridRow {
                        Text(L10n.string("upstream.host"))
                        TextField("127.0.0.1", text: $host).textFieldStyle(.roundedBorder).frame(width: 260)
                    }
                    GridRow {
                        Text(L10n.string("upstream.port"))
                        TextField("7890", text: $portText).textFieldStyle(.roundedBorder).frame(width: 90)
                    }
                    GridRow(alignment: .top) {
                        Text(L10n.string("upstream.bypass"))
                        VStack(alignment: .leading, spacing: 4) {
                            TextEditor(text: $bypassText).font(.system(.callout, design: .monospaced))
                                .frame(width: 260, height: 70)
                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
                            Text(L10n.string("upstream.bypassHelp")).font(.caption).foregroundStyle(.secondary)
                                .frame(width: 260, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            Text(L10n.string("upstream.limitations")).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(L10n.format("upstream.current", appModel.upstreamProxyDescription)).font(.caption)
                .textSelection(.enabled)
            HStack {
                Spacer()
                Button(L10n.string("certificateBlock.cancel"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L10n.string("upstream.apply")) {
                    appModel.settings.preferences.upstreamMode = mode
                    if mode == .manual { appModel.settings.preferences.manualUpstream = manual }
                    appModel.applyUpstreamPreferences()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction).disabled(!canApply)
            }
        }
        .padding(24).frame(width: 520)
        .onAppear {
            let preferences = appModel.settings.preferences
            mode = preferences.upstreamMode
            host = preferences.manualUpstream.host
            portText = String(preferences.manualUpstream.port)
            bypassText = preferences.manualUpstream.bypass.joined(separator: "\n")
        }
    }
}

/// Confirmation continues to live on MainWindow; settings brings that window forward.
@MainActor func showSystemProxyConfirmation(openWindow: OpenWindowAction) {
    MainWindowLocator.bringToFront(openWindow: openWindow)
}
