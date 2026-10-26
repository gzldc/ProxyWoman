import AppCore
import AppKit
import Observation
import UniformTypeIdentifiers

/// The icons of the apps flows come from. An executable inside an `.app` (helpers included) gets
/// the outermost app's icon, anything else the generic executable icon.
///
/// Lookups never block: an icon not loaded yet is returned as the generic icon while it is read
/// off the main thread, once per app. Views reading `icon(forExecutable:)` are updated through
/// observation when it arrives; AppKit views listen for `didLoadIcon`.
@MainActor @Observable final class AppIconCache {
    static let shared = AppIconCache()
    /// Posted on the main thread after an icon has been loaded.
    static let didLoadIcon = Notification.Name("AppIconCache.didLoadIcon")

    /// Keyed by the outermost `.app` path, so all helpers of an app share one icon.
    private var icons: [String: NSImage] = [:]
    /// Executable path → its outermost `.app` (nil: not inside one); saves re-parsing per row.
    @ObservationIgnored private var bundles: [String: String?] = [:]
    @ObservationIgnored private var loading: Set<String> = []
    @ObservationIgnored let genericIcon = NSWorkspace.shared.icon(for: .unixExecutable)

    private nonisolated static let pointSize = NSSize(width: 32, height: 32)

    func icon(forExecutable path: String?) -> NSImage {
        guard let path, let bundle = bundle(ofExecutable: path) else { return genericIcon }
        if let icon = icons[bundle] { return icon }
        if !loading.contains(bundle) { load(bundle) }
        return genericIcon
    }

    private func bundle(ofExecutable path: String) -> String? {
        if let cached = bundles[path] { return cached }
        let bundle = AppBundlePath.outermostApp(ofExecutable: path)
        bundles[path] = bundle
        return bundle
    }

    private func load(_ bundle: String) {
        loading.insert(bundle)
        Task {
            // `NSImage` is not Sendable: the icon is rendered to a bitmap off the main thread.
            let image = await Task.detached(priority: .utility) { Self.renderIcon(ofFile: bundle) }.value
            loading.remove(bundle)
            icons[bundle] = image.map { NSImage(cgImage: $0, size: Self.pointSize) } ?? genericIcon
            NotificationCenter.default.post(name: Self.didLoadIcon, object: self)
        }
    }

    /// Reads the icon from disk and renders it at twice `pointSize`, for Retina screens.
    private nonisolated static func renderIcon(ofFile path: String) -> CGImage? {
        let icon = NSWorkspace.shared.icon(forFile: path)
        var rect = CGRect(x: 0, y: 0, width: pointSize.width * 2, height: pointSize.height * 2)
        return icon.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
}
