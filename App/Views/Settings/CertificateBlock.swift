import AppCore
import CertKit
import Darwin
import Localization
import SwiftUI

struct CertificateBlock: View {
    let appModel: AppModel
    /// Local kernel label only: Foundation hostName can block on DNS in a view render.
    private static let localHostname: String = {
        var buffer = [CChar](repeating: 0, count: Int(MAXHOSTNAMELEN) + 1)
        guard gethostname(&buffer, buffer.count) == 0 else { return L10n.string("certificateBlock.localMachine") }
        let name = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return name.isEmpty ? L10n.string("certificateBlock.localMachine") : name
    }()
    @State private var isInstalling = false
    @State private var confirmsRegenerate = false
    @State private var highlighted = false
    private var metadata: CertificateMetadata? { try? CertificateMetadata(pemEncoded: appModel.ca.rootCertificatePEM) }
    private var certificateName: String {
        let host = Self.localHostname
        guard let metadata else { return L10n.format("certificateBlock.fallbackName", AppInfo.name, host) }
        return L10n.format("certificateBlock.name", metadata.commonName, host, metadata.serialNumberPrefix)
    }
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "person.text.rectangle.fill").font(.system(size: 44)).foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 7) {
                Text(certificateName).font(.callout.weight(.medium)).textSelection(.enabled)
                if let metadata {
                    Text(L10n.format("certificateBlock.validFrom", String(describing: date(metadata.validFrom))))
                    Text(L10n.format("certificateBlock.validUntil", String(describing: date(metadata.validUntil))))
                } else {
                    Text(L10n.string("certificateBlock.metadataFailed")).foregroundStyle(.red)
                }
                Label(
                    appModel.isCATrusted
                        ? L10n.string("certificateBlock.trusted") : L10n.string("certificateBlock.untrusted"),
                    systemImage: appModel.isCATrusted ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"
                )
                .foregroundStyle(appModel.isCATrusted ? .green : .orange)
                HStack {
                    Button(L10n.string("certificateBlock.installAndTrust"), action: install).buttonStyle(
                        .borderedProminent
                    )
                    .disabled(isInstalling || appModel.isCATrusted)
                    if isInstalling { ProgressView().controlSize(.small) }
                    Button(L10n.string("certificateBlock.regenerate")) { confirmsRegenerate = true }
                        .disabled(appModel.isCATrusted)
                        .help(appModel.isCATrusted ? L10n.string("certificateBlock.regenerateTrustedHelp") : "")
                    Menu(L10n.string("sslProxyingList.more")) {
                        Button(L10n.string("certificateBlock.installOnMac"), action: install).disabled(
                            isInstalling || appModel.isCATrusted)
                        Button(L10n.string("appCommands.showInFinder"), action: appModel.revealCertificate)
                        Button(L10n.string("certificateBlock.copyPath"), action: appModel.copyCertificatePath)
                        Button(L10n.string("certificateBlock.exportAction"), action: appModel.exportCertificate)
                        Divider()
                        Button(
                            L10n.string("appCommands.removeTrustAction"),
                            action: appModel.confirmAndRemoveCertificateTrust
                        )
                        .disabled(!appModel.isCATrusted)
                    }.fixedSize()
                }
                Text(L10n.string("certificateBlock.installHelp")).foregroundStyle(.secondary)
                if let error = appModel.lastError { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            }.font(.caption).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(highlighted ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8).stroke(
                highlighted ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: highlighted ? 2 : 1)
        )
        .onAppear { appModel.refreshTrust() }
        .task(id: appModel.certificateHighlightID) {
            guard appModel.certificateHighlightID != nil else { return }
            highlighted = true
            do { try await Task.sleep(for: .seconds(4)) } catch { return }
            withAnimation { highlighted = false }
        }
        .alert(L10n.string("certificateBlock.regenerateTitle"), isPresented: $confirmsRegenerate) {
            Button(L10n.string("certificateBlock.regenerateConfirm"), role: .destructive) {
                appModel.regenerateCertificateAndRestart(using: .system) { NSApplication.shared.terminate(nil) }
            }
            Button(L10n.string("certificateBlock.cancel"), role: .cancel) {}
        } message: {
            Text(L10n.format("certificateBlock.regenerateMessage", AppInfo.name))
        }
    }
    private func install() {
        guard !isInstalling else { return }
        isInstalling = true
        Task {
            await appModel.installCertificate()
            isInstalling = false
        }
    }
    private func date(_ value: Date) -> String {
        Formatting.certificateDate(value)
    }
}
