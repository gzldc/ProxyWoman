import AppKit

/// Who the shared colour panel currently messages. A claim is a token; a release only clears the panel
/// when its token is still the current one, so an older owner cannot wipe a newer owner's target.
@MainActor final class ColorPanelOwnership {
    static let shared = ColorPanelOwnership { NSColorPanel.shared.setTarget(nil); NSColorPanel.shared.setAction(nil) }

    private var current = 0
    private let clear: () -> Void

    init(clear: @escaping () -> Void) { self.clear = clear }

    /// Makes the caller the owner; returns its token.
    func claim() -> Int {
        current += 1
        return current
    }

    /// Clears the panel if `token` still owns it. Returns whether it did.
    @discardableResult
    func release(_ token: Int) -> Bool {
        guard token == current else { return false }
        current += 1
        clear()
        return true
    }
}
