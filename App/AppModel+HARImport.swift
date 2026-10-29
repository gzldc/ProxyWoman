import AppKit
import FlowStore
import Localization
import UniformTypeIdentifiers

extension AppModel {
    /// Opens a HAR file (a saved ProxyWoman session or a capture from another tool) and adds its
    /// requests to the list as finished sessions.
    func importHAR() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "har") ?? .json, .json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        dismissNotice()
        let store = store
        Task {
            do {
                let count = try await Task.detached(priority: .userInitiated) {
                    let entries = try HARImporter.parse(try Data(contentsOf: url))
                    return HARImporter.add(entries, to: store)
                }.value
                showNotice(L10n.format("harImport.done", count, url.lastPathComponent))
            } catch {
                showError(L10n.format("harImport.failed", url.lastPathComponent, error.localizedDescription))
            }
        }
    }
}
