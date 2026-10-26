import AppKit
import Foundation
import Localization
import Testing
@testable import AppCore

/// Shortcuts the tool-window tables share: which key press means which command, what the legend
/// says, how a selection toggles, and how the "only enabled" / text filter narrows a list.
@MainActor @Suite(.productionChinese) struct ToolTableCommandTests {
    private func key(_ code: UInt16, _ characters: String, _ modifiers: NSEvent.ModifierFlags, repeating: Bool = false) -> ToolKeyPress {
        ToolKeyPress(keyCode: code, characters: characters, modifiers: modifiers, isRepeat: repeating)
    }

    // MARK: key to command

    private struct Case {
        let code: UInt16
        let characters: String
        let modifiers: NSEvent.ModifierFlags
        let expected: ToolTableCommand
    }

    @Test func eachLegendShortcutResolvesToItsCommand() {
        let cases: [Case] = [
            Case(code: 45, characters: "n", modifiers: .command, expected: .new),
            Case(code: 36, characters: "\r", modifiers: .command, expected: .edit),
            Case(code: 76, characters: "\u{3}", modifiers: .command, expected: .edit),
            Case(code: 51, characters: "\u{7f}", modifiers: .command, expected: .delete),
            Case(code: 2, characters: "d", modifiers: .command, expected: .duplicate),
            Case(code: 49, characters: " ", modifiers: NSEvent.ModifierFlags(), expected: .toggleEnabled),
        ]
        for item in cases {
            #expect(ToolTableShortcuts.command(for: key(item.code, item.characters, item.modifiers)) == item.expected, "\(item.expected)")
        }
    }

    @Test func aLetterIsReadFromTheCharacterSoAnotherKeyboardLayoutStillWorks() {
        // ⌘N on a layout where the N key has another key code.
        #expect(ToolTableShortcuts.command(for: key(99, "n", .command)) == .new)
        #expect(ToolTableShortcuts.command(for: key(99, "N", .command)) == .new)
    }

    @Test func otherModifierCombinationsAreNotOurs() {
        // ⌘⇧N, ⌥⌘N, ⌃⌘N, plain N: the app's own menu shortcuts and typing keep them.
        for modifiers: NSEvent.ModifierFlags in [[.command, .shift], [.command, .option], [.command, .control], []] {
            #expect(ToolTableShortcuts.command(for: key(45, "n", modifiers)) == nil, "\(modifiers)")
        }
        // Space with a modifier (⌘Space is Spotlight) and Return without ⌘ are not ours either.
        #expect(ToolTableShortcuts.command(for: key(49, " ", .command)) == nil)
        #expect(ToolTableShortcuts.command(for: key(36, "\r", [])) == nil)
        #expect(ToolTableShortcuts.command(for: key(51, "\u{7f}", [])) == nil)
    }

    @Test func capsLockAndTheNumericPadFlagDoNotChangeTheMeaning() {
        #expect(ToolTableShortcuts.command(for: key(45, "n", [.command, .capsLock])) == .new)
        #expect(ToolTableShortcuts.command(for: key(76, "\u{3}", [.command, .numericPad])) == .edit)
        #expect(ToolTableShortcuts.command(for: key(49, " ", [.capsLock])) == .toggleEnabled)
    }

    @Test func aHeldKeyDoesNotRepeatACommand() {
        for command in [key(45, "n", .command, repeating: true), key(49, " ", [], repeating: true)] {
            #expect(ToolTableShortcuts.command(for: command) == nil)
        }
    }

    @Test func aHeldKeyIsSwallowedWithoutRunningTheActionAgain() {
        var log: [String] = []
        let actions = ToolTableActions(new: { log.append("new") }, toggleEnabled: { log.append("toggle") })
        #expect(actions.handle(key(49, " ", [])))
        // Auto-repeats are consumed (they must not reach the menu bar or the table) but do nothing.
        #expect(actions.handle(key(49, " ", [], repeating: true)))
        #expect(actions.handle(key(49, " ", [], repeating: true)))
        #expect(actions.handle(key(45, "n", .command, repeating: true)))
        #expect(log == ["toggle"])
        // A repeating key the table has no action for still goes on.
        #expect(!actions.handle(key(51, "\u{7f}", .command, repeating: true)))
        #expect(!actions.handle(key(0, "a", [], repeating: true)))
    }

    // MARK: actions

    @Test func aKeyRunsOnlyTheActionTheTableProvides() {
        var log: [String] = []
        let actions = ToolTableActions(new: { log.append("new") }, delete: { log.append("delete") })
        #expect(actions.handle(key(45, "n", .command)))
        #expect(actions.handle(key(51, "\u{7f}", .command)))
        // A command the table does not offer is not handled, so the key goes on to its normal meaning.
        #expect(!actions.handle(key(2, "d", .command)))
        #expect(!actions.handle(key(49, " ", [])))
        #expect(!actions.handle(key(0, "a", [])))
        #expect(log == ["new", "delete"])
    }

    @Test func aNilActionIsHowAUnavailableCommandIsExpressed() {
        // The caller passes nil for "delete" while nothing is selected.
        let actions = ToolTableActions(new: {}, delete: nil)
        #expect(!actions.handle(key(51, "\u{7f}", .command)))
        #expect(actions.provides(.new) && !actions.provides(.delete))
    }

    // MARK: legend

    @Test func commandsKeepTheCanonicalOrderAndShortcutText() {
        #expect(ToolTableCommand.allCases == [.new, .edit, .delete, .duplicate, .toggleEnabled])
        #expect(ToolTableCommand.new.shortcutText == "⌘N")
        #expect(ToolTableCommand.edit.shortcutText == "⌘↩")
        #expect(ToolTableCommand.delete.shortcutText == "⌘⌫")
        #expect(ToolTableCommand.duplicate.shortcutText == "⌘D")
    }

    @Test func theLegendListsTheOfferedCommandsInTheCanonicalOrder() {
        let all = ToolShortcutLegend.text(for: [.toggleEnabled, .duplicate, .delete, .edit, .new])
        #expect(all == "新建 ⌘N · 编辑 ⌘↩ · 删除 ⌘⌫ · 复制 ⌘D · 启用/停用 空格")
        // A table that cannot edit or duplicate does not advertise it.
        #expect(ToolShortcutLegend.text(for: [.new, .delete, .toggleEnabled]) == "新建 ⌘N · 删除 ⌘⌫ · 启用/停用 空格")
        #expect(ToolShortcutLegend.text(for: []) == "")
    }

    // MARK: toggle

    @Test func aSelectionTurnsOnUnlessEveryRowIsAlreadyOn() {
        #expect(ToolSelectionToggle.targetEnabled(for: []) == nil)
        #expect(ToolSelectionToggle.targetEnabled(for: [true]) == false)
        #expect(ToolSelectionToggle.targetEnabled(for: [false]) == true)
        #expect(ToolSelectionToggle.targetEnabled(for: [true, true]) == false)
        #expect(ToolSelectionToggle.targetEnabled(for: [true, false]) == true)
        #expect(ToolSelectionToggle.targetEnabled(for: [false, false]) == true)
    }

    // MARK: filter

    @Test func anInactiveFilterShowsEverything() {
        let filter = ToolListFilter()
        #expect(!filter.isActive)
        #expect(filter.includes(enabled: false, fields: ["a"]))
        #expect(filter.includes(enabled: true, fields: []))
    }

    @Test func onlyEnabledHidesDisabledRows() {
        let filter = ToolListFilter(onlyEnabled: true)
        #expect(filter.isActive)
        #expect(filter.includes(enabled: true, fields: ["x"]))
        #expect(!filter.includes(enabled: false, fields: ["x"]))
    }

    @Test func theQueryMatchesAnyFieldIgnoringCaseAndWhitespaceAtTheEnds() {
        let filter = ToolListFilter(query: "  API.Example ")
        #expect(filter.isActive)
        #expect(filter.includes(enabled: true, fields: ["Name", "https://api.example.com/v1"]))
        #expect(!filter.includes(enabled: true, fields: ["Name", "other.test"]))
        #expect(ToolListFilter(query: "   ").isActive == false)
    }

    @Test func accentsDoNotHideAMatch() {
        #expect(ToolListFilter(query: "cafe").includes(enabled: true, fields: ["Café"]))
    }

    @Test func bothConditionsMustHold() {
        let filter = ToolListFilter(onlyEnabled: true, query: "a.test")
        #expect(filter.includes(enabled: true, fields: ["a.test"]))
        #expect(!filter.includes(enabled: false, fields: ["a.test"]))
        #expect(!filter.includes(enabled: true, fields: ["b.test"]))
    }

    @Test func filteringKeepsTheOrderOfTheRows() {
        let rows = [(1, true, "a"), (2, false, "ab"), (3, true, "b"), (4, true, "ba")]
        let filter = ToolListFilter(onlyEnabled: true, query: "b")
        let kept = rows.filter { filter.includes(enabled: $0.1, fields: [$0.2]) }.map(\.0)
        #expect(kept == [3, 4])
    }
}
