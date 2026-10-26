import AppCore
import AppKit
import Localization
import SwiftUI
import Testing
@testable import ProxyWoman

/// The bar under every tool-window table (Allow, Block, Network Conditions, Rules): each control is a
/// real AppKit control with a usable hit target and a label, and the minus follows the selection.
/// Read from an in-process hosting view that is never shown.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)), .productionChinese) struct ToolWindowBottomBarTests {
    private static func buttons(in view: NSView) -> [NSButton] {
        ((view as? NSButton).map { [$0] } ?? []) + view.subviews.flatMap { buttons(in: $0) }
    }

    /// Left to right.
    private static func sorted(_ buttons: [NSButton], in host: NSView) -> [NSButton] {
        buttons.sorted { $0.convert($0.bounds, to: host).minX < $1.convert($1.bounds, to: host).minX }
    }

    private static func host<Bar: View>(_ bar: Bar) -> NSHostingView<some View> {
        let host = NSHostingView(rootView: bar.frame(width: 640, height: 80))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 80), styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        return host
    }

    private struct Harness: View {
        let canRemove: Bool
        @State var filter = ToolListFilter()

        var body: some View {
            ToolWindowBottomBar(
                removeLabel: "Remove", canRemove: canRemove, remove: {}, helpParagraphs: ["What it does", "In which order"],
                filter: $filter,
                add: { ToolBarAddButton(label: "Add", action: {}) },
                more: { Button("Clear") {} })
        }
    }

    /// The three symbol buttons, left to right: add, remove, help. (Their labels are accessibility labels
    /// set by `ToolBarAddButton` and the bar from the strings the owner passes; the hosting view exposes
    /// them only to a running accessibility client, so this checks what AppKit shows: real buttons, size,
    /// order and enabled state.)
    private static func symbolButtons(in host: NSView) -> [NSButton] {
        sorted(buttons(in: host).filter { !($0 is NSPopUpButton) && $0.frame.width <= 40 && $0.frame.height >= 20 }, in: host)
    }

    @Test(arguments: [false, true]) func addRemoveAndHelpAreSquareButtonsAndRemoveFollowsTheSelection(canRemove: Bool) {
        let host = Self.host(Harness(canRemove: canRemove))
        let symbols = Self.symbolButtons(in: host)
        #expect(symbols.count == 3, "\(symbols.map(\.frame))")
        for button in symbols {
            #expect(button.frame.width >= 20 && button.frame.height >= 20, "\(button.frame)")
        }
        #expect(symbols.map(\.isEnabled) == [true, canRemove, true])
    }

    @Test func theMiddleOfEachSquareButtonResolvesToThatButton() {
        let host = Self.host(Harness(canRemove: true))
        for button in Self.symbolButtons(in: host) {
            let center = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: host)
            let hit = host.hitTest(host.convert(center, to: host.superview))
            #expect(hit === button || hit?.isDescendant(of: button) == true, "\(String(describing: hit))")
        }
    }

    @Test func theRightHandControlsAreAnEnabledOnlyCheckboxAFilterToggleAndAMoreMenu() throws {
        let host = Self.host(Harness(canRemove: true))
        let all = Self.sorted(Self.buttons(in: host), in: host)
        let more = try #require(all.compactMap { $0 as? NSPopUpButton }.first)
        #expect(more.title == L10n.string("toolWindow.bar.more"))
        #expect(more.isEnabled)
        // Left of the menu: the filter toggle and the checkbox, both to the right of the three symbols.
        let others = all.filter { !($0 is NSPopUpButton) && !Self.symbolButtons(in: host).contains($0) }
        #expect(others.count == 2, "\(others.map(\.frame))")
        #expect(others.allSatisfy { $0.isEnabled })
        let symbolsRight = Self.symbolButtons(in: host).map { $0.convert($0.bounds, to: host).maxX }.max() ?? 0
        #expect(others.allSatisfy { $0.convert($0.bounds, to: host).minX > symbolsRight })
    }

    @Test func aPlusMenuAsTheAddControlIsASquareButtonLikeTheOthers() {
        struct MenuHarness: View {
            @State var filter = ToolListFilter()
            var body: some View {
                ToolWindowBottomBar(
                    removeLabel: "Remove", canRemove: false, remove: {}, helpParagraphs: ["x"], filter: $filter,
                    add: { ToolBarPlusMenu(label: "New", items: [ToolBarMenuItem(title: "Map Local", action: {})]) },
                    more: { EmptyView() })
            }
        }
        let host = Self.host(MenuHarness())
        let symbols = Self.symbolButtons(in: host)
        #expect(symbols.count == 3, "\(symbols.map(\.frame))")
        #expect(symbols.allSatisfy { $0.frame.width >= 20 && $0.frame.height >= 20 })
        #expect(symbols.map(\.isEnabled) == [true, false, true])
    }

    @Test func thePlusMenuListsEachItemAndRunsItsAction() throws {
        var ran: [String] = []
        let menu = ToolBarMenu.make([
            ToolBarMenuItem(title: "Map Local", systemImage: "doc") { ran.append("local") },
            ToolBarMenuItem(title: "Breakpoint", systemImage: nil) { ran.append("breakpoint") },
        ])
        #expect(menu.items.map(\.title) == ["Map Local", "Breakpoint"])
        #expect(menu.items.map { $0.image != nil } == [true, false])
        #expect(menu.items.allSatisfy { $0.isEnabled })
        menu.performActionForItem(at: 1)
        menu.performActionForItem(at: 0)
        #expect(ran == ["breakpoint", "local"])
    }

    @Test func aBarWithoutMoreOmitsTheMenu() {
        struct Bare: View {
            @State var filter = ToolListFilter()
            var body: some View {
                ToolWindowBottomBar(
                    removeLabel: "Remove", canRemove: false, remove: {}, helpParagraphs: ["x"], filter: $filter,
                    showsMore: false, add: { ToolBarAddButton(label: "Add", action: {}) }, more: { EmptyView() })
            }
        }
        let host = Self.host(Bare())
        #expect(Self.buttons(in: host).allSatisfy { !($0 is NSPopUpButton) })
    }
}
