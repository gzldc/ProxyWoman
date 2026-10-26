import AppKit
import SwiftUI

/// Finds the single main window. SwiftUI names its `NSWindow` identifier `main` or `main-<something>` depending
/// on the scene type and the macOS version, so both forms are accepted.
@MainActor enum MainWindowLocator {
    nonisolated static func isMainWindowIdentifier(_ raw: String?) -> Bool {
        guard let raw else { return false }
        return raw == ProxyWomanApp.mainWindowID || raw.hasPrefix("\(ProxyWomanApp.mainWindowID)-")
    }

    static func window() -> NSWindow? {
        NSApp.windows.first { isMainWindowIdentifier($0.identifier?.rawValue) }
    }

    /// Whether a found window can simply be raised: on screen or in the Dock. A hidden (closed but
    /// retained) window is not reused; the scene is asked to open instead.
    nonisolated static func isReusable(isVisible: Bool, isMiniaturized: Bool) -> Bool {
        isVisible || isMiniaturized
    }

    /// Raises the main window, opening it first when it was closed.
    static func bringToFront(openWindow: OpenWindowAction) {
        if let window = window(), isReusable(isVisible: window.isVisible, isMiniaturized: window.isMiniaturized) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: ProxyWomanApp.mainWindowID)
        }
        NSApp.activate()
    }
}
