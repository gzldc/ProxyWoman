/// Menu commands of the single main window that carry a keyboard shortcut (or, for `nil` entries, none).
public enum ShellCommand: CaseIterable, Sendable {
    case showTraffic, showCompose, newRequest, showRules, showBreakpoints, toggleInspector, toggleSourceBar,
        focusFilter, record, clear, importHAR, exportHAR, copyCurl, repeatRequest, saveAsMock, systemProxy, noCaching,
        allowList, blockList, networkConditions, settings, quit
}

public struct ShellShortcut: Equatable, Hashable, Sendable {
    public var key: Character
    public var command: Bool
    public var shift: Bool
    public var option: Bool
    public var control: Bool

    public init(key: Character, command: Bool = true, shift: Bool = false, option: Bool = false, control: Bool = false) {
        self.key = key
        self.command = command
        self.shift = shift
        self.option = option
        self.control = control
    }
}

/// The single source of truth for the menu shortcuts, so two commands can never share one and none can
/// shadow a shortcut used inside the editors.
public enum ShellShortcuts {
    public static func shortcut(for command: ShellCommand) -> ShellShortcut? {
        switch command {
        case .showTraffic: ShellShortcut(key: "1")
        case .showCompose: ShellShortcut(key: "2")
        case .newRequest: ShellShortcut(key: "n")
        case .showRules: ShellShortcut(key: "r", option: true)
        case .showBreakpoints: ShellShortcut(key: "b", option: true)
        case .toggleInspector: ShellShortcut(key: "i", option: true)
        case .toggleSourceBar: ShellShortcut(key: "s", control: true)
        case .focusFilter: ShellShortcut(key: "f", option: true)
        case .record: ShellShortcut(key: "r")
        case .clear: ShellShortcut(key: "k")
        case .importHAR: ShellShortcut(key: "o")
        case .exportHAR: ShellShortcut(key: "e", shift: true)
        case .copyCurl: ShellShortcut(key: "c", shift: true)
        case .repeatRequest: ShellShortcut(key: "r", shift: true)
        case .saveAsMock: ShellShortcut(key: "m", shift: true)
        case .systemProxy: ShellShortcut(key: "o", option: true)
        case .noCaching: ShellShortcut(key: "n", option: true)
        case .allowList: ShellShortcut(key: "]", option: true)
        case .blockList: ShellShortcut(key: "[", option: true)
        case .networkConditions: ShellShortcut(key: "j", shift: true)
        case .settings: ShellShortcut(key: ",")
        case .quit: ShellShortcut(key: "q")
        }
    }

    /// Used inside the rule editor, action cards, Compose and the breakpoint editor: ⌘S, ⇧⌘N, ⇧⌘A, ⌘↩.
    public static let reservedInEditors: [ShellShortcut] = [
        ShellShortcut(key: "s"),
        ShellShortcut(key: "n", shift: true),
        ShellShortcut(key: "a", shift: true),
        ShellShortcut(key: "\r"),
    ]
}
