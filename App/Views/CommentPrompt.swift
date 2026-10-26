import AppKit
import Localization

/// The modal prompt for a flow's comment: a text field prefilled with the current comment.
enum CommentPrompt {
    enum Result: Equatable {
        case save(String)
        case clear
        case cancel
    }

    /// Buttons: Save, Cancel and, when there is a comment, Clear Comment.
    @MainActor static func run(current: String?) -> Result {
        let alert = NSAlert()
        alert.messageText = L10n.string("comment.prompt.title")
        alert.informativeText = L10n.string("comment.prompt.message")
        alert.addButton(withTitle: L10n.string("comment.prompt.save"))
        alert.addButton(withTitle: L10n.string("common.cancel"))
        let hasComment = current != nil
        if hasComment { alert.addButton(withTitle: L10n.string("comment.prompt.clear")) }
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = current ?? ""
        field.setAccessibilityLabel(L10n.string("comment.prompt.title"))
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .save(field.stringValue)
        case .alertThirdButtonReturn where hasComment: return .clear
        default: return .cancel
        }
    }
}
