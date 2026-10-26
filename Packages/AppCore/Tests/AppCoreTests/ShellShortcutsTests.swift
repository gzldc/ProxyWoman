import Testing

@testable import AppCore

@Suite(.productionChinese) struct ShellShortcutsTests {
    private func sc(_ key: Character, _ mods: String = "c") -> ShellShortcut {
        ShellShortcut(
            key: key, command: mods.contains("c"), shift: mods.contains("s"), option: mods.contains("o"),
            control: mods.contains("k"))
    }

    @Test func noTwoCommandsShareAShortcut() {
        let all = ShellCommand.allCases.compactMap(ShellShortcuts.shortcut(for:))
        #expect(all.count == Set(all).count)
    }

    @Test func pagesUseCommandDigits() {
        #expect(ShellShortcuts.shortcut(for: .showTraffic) == sc("1"))
        #expect(ShellShortcuts.shortcut(for: .showCompose) == sc("2"))
    }

    @Test func existingShortcutsAreKept() {
        let expected: [(ShellCommand, ShellShortcut)] = [
            (.record, sc("r")), (.clear, sc("k")), (.newRequest, sc("n")), (.showRules, sc("r", "co")),
            (.showBreakpoints, sc("b", "co")), (.networkConditions, sc("j", "cs")), (.allowList, sc("]", "co")),
            (.blockList, sc("[", "co")), (.focusFilter, sc("f", "co")), (.toggleSourceBar, sc("s", "ck")),
            (.systemProxy, sc("o", "co")), (.noCaching, sc("n", "co")), (.exportHAR, sc("e", "cs")),
            (.copyCurl, sc("c", "cs")), (.repeatRequest, sc("r", "cs")), (.saveAsMock, sc("m", "cs")),
            (.settings, sc(",")), (.quit, sc("q")),
        ]
        for (command, shortcut) in expected {
            #expect(ShellShortcuts.shortcut(for: command) == shortcut, "\(command)")
        }
    }

    @Test func inspectorToggleIsOptionCommandI() {
        #expect(ShellShortcuts.shortcut(for: .toggleInspector) == sc("i", "co"))
    }

    @Test func noneCollidesWithEditorShortcuts() {
        for command in ShellCommand.allCases {
            guard let shortcut = ShellShortcuts.shortcut(for: command) else { continue }
            #expect(!ShellShortcuts.reservedInEditors.contains(shortcut), "\(command)")
        }
    }
}
