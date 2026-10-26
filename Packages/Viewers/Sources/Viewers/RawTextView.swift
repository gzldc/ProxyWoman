import AppKit
import Localization
import SwiftUI

/// Read-only, selectable monospaced text in an `NSTextView`, which copes with megabytes of text.
public struct RawTextView: View {
    private let text: String
    private let isTruncated: Bool
    private let style: ViewerStyle

    public init(text: String, isTruncated: Bool = false, wrapsLines: Bool? = nil, style: ViewerStyle = .init()) {
        self.text = text
        self.isTruncated = isTruncated
        var style = style
        if let wrapsLines { style.wrapsLines = wrapsLines }
        self.style = style
    }

    public var body: some View {
        VStack(spacing: 0) {
            if isTruncated {
                Text(L10n.string("rawTextView.textTruncated"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                Divider()
            }
            MonospacedTextView(text: text, style: style)
        }
    }
}

private struct MonospacedTextView: NSViewRepresentable {
    let text: String
    let style: ViewerStyle

    final class Coordinator {
        /// The text last handed to the view. Comparing against it is cheap (same storage),
        /// unlike reading `NSTextView.string` back, which bridges megabytes.
        var text: String?
        var style: ViewerStyle?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        // Explicitly use NSLayoutManager, whose invisible-character rendering is required here.
        let textView = NSTextView(usingTextLayoutManager: false)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        scrollView.documentView = textView
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.textColor = .textColor
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 4, height: 4)
        applyStyle(to: textView, in: scrollView)
        textView.string = text
        context.coordinator.text = text
        context.coordinator.style = style
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if context.coordinator.style != style {
            applyStyle(to: textView, in: scrollView)
            context.coordinator.style = style
        }
        if context.coordinator.text != text {
            textView.string = text
            context.coordinator.text = text
            textView.scroll(.zero)
        }
    }

    private func applyStyle(to text: NSTextView, in scroll: NSScrollView) {
        text.font = style.nsFont
        text.layoutManager?.showsInvisibleCharacters = style.showsInvisibles
        scroll.hasHorizontalScroller = !style.wrapsLines
        text.isHorizontallyResizable = !style.wrapsLines
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.textContainer?.widthTracksTextView = style.wrapsLines
        text.textContainer?.containerSize = NSSize(
            width: style.wrapsLines ? max(scroll.contentSize.width, 1) : .greatestFiniteMagnitude,
            height: .greatestFiniteMagnitude)
        if style.wrapsLines, scroll.contentSize.width > 0 {
            // Unwrapped layout can grow the document far beyond the viewport. Width tracking
            // follows that document, so restore its width before relying on autoresizing.
            text.setFrameSize(NSSize(width: scroll.contentSize.width, height: text.frame.height))
        }
    }
}
