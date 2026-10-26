import AppKit
import Localization
import UniformTypeIdentifiers

extension AppModel {
    func revealCertificate() {
        NSWorkspace.shared.activateFileViewerSelecting([caStore.certificateURL])
    }

    /// Raw path, suitable for pasting into a save dialog or quoting in a terminal.
    func copyCertificatePath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(caStore.certificateURL.path, forType: .string)
    }

    func exportCertificate() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "pem") ?? .data]
        panel.nameFieldStringValue = "root-ca.pem"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try ca.rootCertificatePEM.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            showError(L10n.format("certificateActions.exportCertificateFailed", error.localizedDescription))
        }
    }

    /// Shared entry point for settings and menu commands; confirmation always precedes trust removal.
    func confirmAndRemoveCertificateTrust() {
        let alert = NSAlert()
        alert.messageText = L10n.string("certificateActions.removeTrustQuestion")
        alert.informativeText = L10n.string("certificateActions.removeTrustExplanation")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.string("common.cancel"))
        alert.addButton(withTitle: L10n.string("certificateActions.removeTrust"))
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        Task { await removeCertificateTrust() }
    }
}
