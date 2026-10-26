import AppCore
import AppKit
import FlowStore

/// A table row that paints a mark's colour behind its cells. The selection is a soft token tint
/// (not the saturated system blue); a mark's colour keeps priority over it.
final class MarkedRowView: NSTableRowView {
    static let identifier = NSUserInterfaceItemIdentifier("markedRow")

    var markFill: NSColor? {
        didSet { if markFill != oldValue { needsDisplay = true } }
    }

    /// Fill and tooltip from the flow's mark and comment. A view-based table never asks a cell
    /// delegate for tooltips, so the row view carries it.
    /// A paused flow gets the pending tint unless a mark colours the row (the mark keeps priority).
    func apply(_ flow: Flow?, isPaused: Bool = false) {
        markFill = flow?.displayMark.map(MarkPalette.rowBackground) ?? (isPaused ? ShellStyle.nsColor(.paused) : nil)
        toolTip = flow.flatMap { FlowAnnotationPresentation.tooltip(for: $0) }
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        // A marked row keeps its mark colour; the selection then only shows as a thin outline.
        if markFill != nil {
            ShellStyle.nsColor(.accent).withAlphaComponent(0.6).setStroke()
            let path = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
            path.lineWidth = 1
            path.stroke()
        } else {
            ShellStyle.nsColor(.accentSoft).setFill()
            dirtyRect.intersection(bounds).fill(using: .sourceOver)
        }
    }

    /// Selected rows keep the normal (dark) text colour on the soft tint.
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard let markFill else { return }
        markFill.setFill()
        dirtyRect.intersection(bounds).fill(using: .sourceOver)
    }
}
