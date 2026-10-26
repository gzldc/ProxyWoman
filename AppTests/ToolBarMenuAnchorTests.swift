import AppKit
import SwiftUI
import Testing
@testable import ProxyWoman

/// A "+" button's menu opens at the button's own bottom-left corner, not at the last mouse location.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)), .productionChinese) struct ToolBarMenuAnchorTests {
    @Test func theMenuOpensAtTheButtonsBottomLeftWhicheverWayTheViewIsFlipped() {
        let bounds = NSRect(x: 0, y: 0, width: 24, height: 24)
        #expect(ToolBarMenuAnchor.popUpLocation(in: bounds, isFlipped: true) == NSPoint(x: 0, y: 24))
        #expect(ToolBarMenuAnchor.popUpLocation(in: bounds, isFlipped: false) == NSPoint(x: 0, y: 0))
        // A view whose bounds do not start at the origin.
        let shifted = NSRect(x: 5, y: 7, width: 24, height: 20)
        #expect(ToolBarMenuAnchor.popUpLocation(in: shifted, isFlipped: true) == NSPoint(x: 5, y: 27))
        #expect(ToolBarMenuAnchor.popUpLocation(in: shifted, isFlipped: false) == NSPoint(x: 5, y: 7))
    }

    @Test func theAnchorBehindAButtonHasTheButtonsFrame() throws {
        struct Harness: View {
            let box: ToolBarAnchorBox
            var body: some View {
                HStack {
                    Spacer()
                    Button {} label: { ToolBarSymbol.image("plus") }
                        .background(ToolBarAnchorView(box: box))
                }
                .frame(width: 200, height: 60)
            }
        }
        let box = ToolBarAnchorBox()
        let host = NSHostingView(rootView: Harness(box: box))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 60), styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let anchor = try #require(box.view)
        #expect(anchor.window === window)
        let frame = anchor.convert(anchor.bounds, to: host)
        #expect(frame.width >= ToolBarSymbol.target && frame.height >= ToolBarSymbol.target)
        // The button is at the right edge, so the anchor is too: its corner is not the window's origin.
        #expect(frame.maxX > 150)
        let corner = ToolBarMenuAnchor.popUpLocation(in: anchor.bounds, isFlipped: anchor.isFlipped)
        #expect(anchor.bounds.insetBy(dx: -0.5, dy: -0.5).contains(corner))
    }
}
