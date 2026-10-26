import AppCore
import AppKit
import SwiftUI
import Testing
@testable import ProxyWoman

/// Which key presses a tool window's table may take: only while that table is the first responder,
/// never while a text field is being edited.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)), .productionChinese) struct ToolTableFocusTests {
    @MainActor private final class Scene {
        let window: NSWindow
        let table = NSTableView()
        let otherTable = NSTableView()
        let field = NSTextField(string: "abc")
        let anchor = ToolTableKeyMonitorView()
        var log: [String] = []

        init() {
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
            let content = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
            window.contentView = content
            let tableScroll = NSScrollView(frame: NSRect(x: 0, y: 40, width: 280, height: 250))
            let otherScroll = NSScrollView(frame: NSRect(x: 300, y: 40, width: 280, height: 250))
            for (scroll, table) in [(tableScroll, table), (otherScroll, otherTable)] {
                let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c"))
                table.addTableColumn(column)
                scroll.documentView = table
                content.addSubview(scroll)
            }
            field.frame = NSRect(x: 10, y: 5, width: 200, height: 24)
            content.addSubview(field)
            // The key monitor sits behind the first table, like the background of a SwiftUI Table.
            anchor.frame = tableScroll.frame
            content.addSubview(anchor, positioned: .below, relativeTo: tableScroll)
            anchor.actions = ToolTableActions(
                new: { [unowned self] in log.append("new") }, edit: { [unowned self] in log.append("edit") },
                delete: { [unowned self] in log.append("delete") }, duplicate: { [unowned self] in log.append("duplicate") },
                toggleEnabled: { [unowned self] in log.append("toggle") })
        }

        /// A key-down as the key window would deliver it (an unshown window has no window server number, so
        /// the routing is given the window the event belongs to).
        func press(_ code: UInt16, _ characters: String, _ modifiers: NSEvent.ModifierFlags) -> ToolKeyPress {
            let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0,
                context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
            return ToolKeyPress(event)
        }

        func route(_ press: ToolKeyPress) -> Bool { anchor.route(press, from: window) }
    }

    @Test func theTableUnderTheMonitorOwnsKeysOnlyWhileItIsTheFirstResponder() {
        let scene = Scene()
        #expect(scene.window.makeFirstResponder(scene.table))
        #expect(ToolTableFocus.isTableFocused(scene.window.firstResponder, anchor: scene.anchor))
        // Another table in the same window (an editor form, say) does not.
        #expect(scene.window.makeFirstResponder(scene.otherTable))
        #expect(!ToolTableFocus.isTableFocused(scene.window.firstResponder, anchor: scene.anchor))
        #expect(!ToolTableFocus.isTableFocused(nil, anchor: scene.anchor))
    }

    @Test func aTextFieldBeingEditedIsNeverATable() {
        let scene = Scene()
        #expect(scene.window.makeFirstResponder(scene.field))
        #expect(scene.window.firstResponder is NSText, "the field editor")
        #expect(!ToolTableFocus.isTableFocused(scene.window.firstResponder, anchor: scene.anchor))
    }

    @Test func aKeyEventBecomesTheSamePressTheShortcutsExpect() {
        let scene = Scene()
        let press = scene.press(45, "n", [.command, .capsLock])
        #expect(press.keyCode == 45 && press.characters.lowercased() == "n" && !press.isRepeat)
        #expect(press.modifiers.contains(.command))
        #expect(ToolTableShortcuts.command(for: press) == .new)
    }

    @Test func aFocusedTableConsumesItsShortcuts() {
        let scene = Scene()
        _ = scene.window.makeFirstResponder(scene.table)
        let consumed = [
            scene.press(45, "n", .command), scene.press(36, "\r", .command), scene.press(51, "\u{7f}", .command),
            scene.press(2, "d", .command), scene.press(49, " ", []),
        ].map { scene.route($0) }
        #expect(consumed == [true, true, true, true, true])
        #expect(scene.log == ["new", "edit", "delete", "duplicate", "toggle"])
    }

    @Test func aTextFieldKeepsEveryKey() {
        let scene = Scene()
        _ = scene.window.makeFirstResponder(scene.field)
        for press in [scene.press(45, "n", .command), scene.press(51, "\u{7f}", .command), scene.press(49, " ", [])] {
            #expect(!scene.route(press))
        }
        #expect(scene.log.isEmpty)
    }

    @Test func aKeyForAnotherTableOrWindowIsLeftAlone() {
        let scene = Scene()
        _ = scene.window.makeFirstResponder(scene.otherTable)
        #expect(!scene.route(scene.press(45, "n", .command)))
        // An event addressed to a different window is not this window's.
        _ = scene.window.makeFirstResponder(scene.table)
        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10), styleMask: [.titled], backing: .buffered, defer: true)
        #expect(!scene.anchor.route(scene.press(45, "n", .command), from: other))
        #expect(!scene.anchor.route(scene.press(45, "n", .command), from: nil))
        #expect(scene.log.isEmpty)
    }

    @Test func aKeyTheTableDoesNotOfferGoesOn() {
        let scene = Scene()
        _ = scene.window.makeFirstResponder(scene.table)
        scene.anchor.actions = ToolTableActions(new: { scene.log.append("new") })
        #expect(!scene.route(scene.press(51, "\u{7f}", .command)))
        #expect(!scene.route(scene.press(0, "a", [])))
        #expect(scene.route(scene.press(45, "n", .command)))
        #expect(scene.log == ["new"])
    }
}
