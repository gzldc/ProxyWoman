import AppKit
import SwiftUI
import Testing

@testable import Viewers

@MainActor @Suite(.productionChinese) struct RawTextLayoutTests {
    private let body = "{\"wrapCheck\": \"" + String(repeating: "wrap-marker 中文 50% ", count: 40) + "\"}"

    @Test func wrappedTextUsesViewportAfterTurningWrapOn() throws {
        let host = NSHostingView(rootView: RawTextView(text: body, style: style(wrap: false)))
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame = NSRect(x: 0, y: 0, width: 414, height: 300)
        host.layoutSubtreeIfNeeded()
        let scroll = try #require(descendant(NSScrollView.self, in: host))
        let text = try #require(scroll.documentView as? NSTextView)
        let initial = try layout(text)
        #expect(initial.count == 1)
        #expect(initial.bounds.width > scroll.contentSize.width)
        #expect(scroll.hasHorizontalScroller)
        let selection = NSRange(location: 5, length: 12)
        text.setSelectedRange(selection)

        host.rootView = RawTextView(text: body, style: style(wrap: true))
        host.layoutSubtreeIfNeeded()
        #expect(scroll.documentView === text)
        #expect(text.textContainer?.widthTracksTextView == true)
        let wrapped = try layout(text)
        #expect(wrapped.count > 1)
        #expect(wrapped.bounds.width <= scroll.contentSize.width)
        #expect(!scroll.hasHorizontalScroller)
        #expect(text.selectedRange() == selection)

        host.frame.size.width = 280
        host.layoutSubtreeIfNeeded()
        let narrow = try layout(text)
        #expect(narrow.count > wrapped.count)
        #expect(narrow.bounds.width <= scroll.contentSize.width)
        host.frame.size.width = 600
        host.layoutSubtreeIfNeeded()
        let wide = try layout(text)
        #expect(wide.count < narrow.count)
        #expect(wide.bounds.width <= scroll.contentSize.width)

        host.rootView = RawTextView(text: body, style: style(wrap: false))
        host.layoutSubtreeIfNeeded()
        #expect(try layout(text).count == 1)
        #expect(scroll.hasHorizontalScroller)
        host.rootView = RawTextView(text: body, style: style(wrap: true))
        host.layoutSubtreeIfNeeded()
        let rewrapped = try layout(text)
        #expect(rewrapped.count > 1)
        #expect(rewrapped.bounds.width <= scroll.contentSize.width)
        #expect(text.string == body)
        #expect(text.selectedRange() == selection)
        #expect(!text.isEditable && text.isSelectable && text.usesFindBar)
        #expect(text.isIncrementalSearchingEnabled)
        #expect(text.font == NSFont.monospacedSystemFont(ofSize: 18, weight: .regular))
        #expect(text.layoutManager?.showsInvisibleCharacters == true)
    }

    @Test func initiallyWrappedTextUsesViewport() throws {
        let host = NSHostingView(rootView: RawTextView(text: body, style: style(wrap: true)))
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame = NSRect(x: 0, y: 0, width: 414, height: 300)
        host.layoutSubtreeIfNeeded()
        let scroll = try #require(descendant(NSScrollView.self, in: host))
        let text = try #require(scroll.documentView as? NSTextView)
        let wrapped = try layout(text)
        #expect(wrapped.count > 1)
        #expect(wrapped.bounds.width <= scroll.contentSize.width)
        #expect(text.frame.width == scroll.contentSize.width)
    }

    private func style(wrap: Bool) -> ViewerStyle {
        ViewerStyle(fontSize: 18, monospaced: true, wrapsLines: wrap, showsInvisibles: true)
    }

    private func descendant<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        return view.subviews.lazy.compactMap { descendant(type, in: $0) }.first
    }

    private func layout(_ text: NSTextView) throws -> (count: Int, bounds: NSRect) {
        let manager = try #require(text.layoutManager)
        let container = try #require(text.textContainer)
        manager.ensureLayout(for: container)
        var count = 0
        manager.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: manager.numberOfGlyphs)) {
            _, _, _, _, _ in count += 1
        }
        return (count, manager.usedRect(for: container))
    }
}
