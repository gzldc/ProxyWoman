import AppCore
import AppKit
import SwiftUI

extension ToolKeyPress {
    init(_ event: NSEvent) {
        self.init(
            keyCode: event.keyCode, characters: event.charactersIgnoringModifiers ?? "", modifiers: event.modifierFlags,
            isRepeat: event.isARepeat)
    }
}

/// Decides whether a key belongs to a tool window's table. Only a table that is the window's first
/// responder owns keys: while a text field is being edited the first responder is the field editor,
/// which is not a table, so typing, ⌘⌫ (delete to line start) and Space stay with the text.
@MainActor enum ToolTableFocus {
    /// True when `responder` is a table view whose scroll view is the one `anchor` sits behind (the
    /// anchor is the table's background, so it covers the same area). Another table in the same window,
    /// such as one inside an editor form, does not count.
    static func isTableFocused(_ responder: NSResponder?, anchor: NSView) -> Bool {
        guard let table = responder as? NSTableView, table.window != nil, anchor.window === table.window else { return false }
        let container = table.enclosingScrollView ?? table
        let area = container.convert(container.bounds, to: nil)
        let center = anchor.convert(NSPoint(x: anchor.bounds.midX, y: anchor.bounds.midY), to: nil)
        return area.insetBy(dx: -1, dy: -1).contains(center)
    }
}

/// A zero-effort background for a tool window's table that routes ⌘N, ⌘↩, ⌘⌫, ⌘D and Space to the
/// table's actions while the table has keyboard focus. A key the table does not handle goes on
/// untouched to the text system and the menu bar.
struct ToolTableKeyMonitor: NSViewRepresentable {
    let actions: ToolTableActions

    func makeNSView(context: Context) -> ToolTableKeyMonitorView {
        let view = ToolTableKeyMonitorView()
        view.actions = actions
        return view
    }

    func updateNSView(_ view: ToolTableKeyMonitorView, context: Context) {
        view.actions = actions
    }

    static func dismantleNSView(_ view: ToolTableKeyMonitorView, coordinator: ()) {
        view.removeMonitor()
    }
}

final class ToolTableKeyMonitorView: NSView {
    var actions = ToolTableActions()
    private var monitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeMonitor()
        guard window != nil else { return }
        // A local monitor sees the key before the menu bar does, so ⌘N in a focused table is "new entry"
        // here and "New Request" everywhere else.
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.consumes(event) ?? false }
            return consumed ? nil : event
        }
    }

    func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// True when a table action consumed the event; false: pass it on.
    func consumes(_ event: NSEvent) -> Bool {
        route(ToolKeyPress(event), from: event.window)
    }

    /// True when the key was this window's table's and its action ran.
    func route(_ press: ToolKeyPress, from eventWindow: NSWindow?) -> Bool {
        guard let window, eventWindow === window, ToolTableFocus.isTableFocused(window.firstResponder, anchor: self) else {
            return false
        }
        return actions.handle(press)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }
}
