import AppKit
import Foundation
import Localization

/// What a key press does in a tool-window table (the Map Local, Block List, Rules … windows share
/// one keyboard legend). The raw order is the order the legend lists them in.
public enum ToolTableCommand: CaseIterable, Sendable, Hashable {
    case new, edit, delete, duplicate, toggleEnabled

    public var titleKey: String {
        switch self {
        case .new: "toolWindow.command.new"
        case .edit: "toolWindow.command.edit"
        case .delete: "toolWindow.command.delete"
        case .duplicate: "toolWindow.command.duplicate"
        case .toggleEnabled: "toolWindow.command.toggle"
        }
    }

    public var title: String { L10n.string(titleKey) }

    /// The keys as the legend writes them; the space bar has a word, not a symbol.
    public var shortcutText: String {
        switch self {
        case .new: "⌘N"
        case .edit: "⌘↩"
        case .delete: "⌘⌫"
        case .duplicate: "⌘D"
        case .toggleEnabled: L10n.string("toolWindow.key.space")
        }
    }
}

/// A key-down, reduced to what the shortcuts need (the view layer builds it from an `NSEvent`).
public struct ToolKeyPress: Sendable, Equatable {
    public var keyCode: UInt16
    /// `charactersIgnoringModifiers`: the letter on the key in the user's layout.
    public var characters: String
    public var modifiers: NSEvent.ModifierFlags
    public var isRepeat: Bool

    public init(keyCode: UInt16, characters: String, modifiers: NSEvent.ModifierFlags, isRepeat: Bool = false) {
        self.keyCode = keyCode
        self.characters = characters
        self.modifiers = modifiers
        self.isRepeat = isRepeat
    }
}

public enum ToolTableShortcuts {
    private static let returnKeys: Set<UInt16> = [36, 76]  // Return, keypad Enter
    private static let deleteKeys: Set<UInt16> = [51, 117]  // Delete (backspace), forward delete
    private static let spaceKey: UInt16 = 49

    /// ⌘N, ⌘↩, ⌘⌫, ⌘D and the bare space bar; any other combination (⇧, ⌥ or ⌃ added, a held key
    /// repeating) is not ours, so the menu bar and the text system keep it. Caps Lock, the numeric
    /// pad and the function flags are not modifiers the user pressed.
    public static func command(for key: ToolKeyPress) -> ToolTableCommand? {
        guard !key.isRepeat else { return nil }
        let modifiers = key.modifiers.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        if modifiers == .command {
            if returnKeys.contains(key.keyCode) { return .edit }
            if deleteKeys.contains(key.keyCode) { return .delete }
            switch key.characters.lowercased() {
            case "n": return .new
            case "d": return .duplicate
            default: return nil
            }
        }
        if modifiers.isEmpty, key.keyCode == spaceKey { return .toggleEnabled }
        return nil
    }
}

/// What a table does for each command. A command the table cannot do right now (nothing selected,
/// not supported) is nil, and its key is then left alone.
@MainActor public struct ToolTableActions {
    public var new: (@MainActor () -> Void)?
    public var edit: (@MainActor () -> Void)?
    public var delete: (@MainActor () -> Void)?
    public var duplicate: (@MainActor () -> Void)?
    public var toggleEnabled: (@MainActor () -> Void)?

    public init(
        new: (@MainActor () -> Void)? = nil, edit: (@MainActor () -> Void)? = nil, delete: (@MainActor () -> Void)? = nil,
        duplicate: (@MainActor () -> Void)? = nil, toggleEnabled: (@MainActor () -> Void)? = nil
    ) {
        self.new = new
        self.edit = edit
        self.delete = delete
        self.duplicate = duplicate
        self.toggleEnabled = toggleEnabled
    }

    private func action(for command: ToolTableCommand) -> (@MainActor () -> Void)? {
        switch command {
        case .new: new
        case .edit: edit
        case .delete: delete
        case .duplicate: duplicate
        case .toggleEnabled: toggleEnabled
        }
    }

    public func provides(_ command: ToolTableCommand) -> Bool { action(for: command) != nil }

    /// Runs the action the key stands for. False: the key means nothing here and must go on.
    /// A held key's auto-repeats are swallowed without running anything: they must neither fire the
    /// action again (Space would flip the rows back and forth) nor reach the menu bar or the table.
    @discardableResult public func handle(_ key: ToolKeyPress) -> Bool {
        var first = key
        first.isRepeat = false
        guard let command = ToolTableShortcuts.command(for: first), let action = action(for: command) else { return false }
        if !key.isRepeat { action() }
        return true
    }
}

public enum ToolShortcutLegend {
    /// "新建 ⌘N · 编辑 ⌘↩ …" for the commands the table offers, always in the canonical order.
    public static func text(for commands: [ToolTableCommand]) -> String {
        ToolTableCommand.allCases.filter(commands.contains)
            .map { L10n.format("toolWindow.legend.entry", $0.title, $0.shortcutText) }
            .joined(separator: L10n.string("toolWindow.legend.separator"))
    }
}

public enum ToolSelectionToggle {
    /// The space bar on a selection: switch everything on unless it is all on already. Nil: nothing selected.
    public static func targetEnabled(for states: [Bool]) -> Bool? {
        states.isEmpty ? nil : !states.allSatisfy { $0 }
    }
}

/// The bottom bar's "show enabled only" and text filters. Presentation only: nothing is removed
/// from the list, rows are just left out of the table.
public struct ToolListFilter: Equatable, Sendable {
    public var onlyEnabled: Bool
    public var query: String

    public init(onlyEnabled: Bool = false, query: String = "") {
        self.onlyEnabled = onlyEnabled
        self.query = query
    }

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    public var isActive: Bool { onlyEnabled || !trimmedQuery.isEmpty }

    /// `fields` are the texts a row shows; the query matches any of them, ignoring case and accents.
    public func includes(enabled: Bool, fields: [String]) -> Bool {
        if onlyEnabled && !enabled { return false }
        let query = trimmedQuery
        if query.isEmpty { return true }
        return fields.contains { $0.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }
}
