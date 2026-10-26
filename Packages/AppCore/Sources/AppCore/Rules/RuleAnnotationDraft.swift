import FlowStore
import Foundation
import RulesEngine

/// The form of a mark action: a background and a text colour, each one of the 28 session colours, "default" (the
/// theme) or "unchanged", and an optional label that only a saved rule can still carry. `background` and `foreground`
/// hold what a rule stores: `#RRGGBB`, `MarkAction.defaultColor`, or nothing for unchanged (`""` / nil).
public struct MarkDraft: Equatable, Sendable {
    public var background: String
    /// nil: the text colour stays as it is.
    public var foreground: String?
    /// An old rule's label; the editor shows the box only when it holds text.
    public var text = ""
    /// The catalogue entry picked in this session, to tell two entries that store the same colour apart.
    public private(set) var backgroundEntry: String?
    public private(set) var foregroundEntry: String?

    public init(background: String = MarkAction.unchangedColor, foreground: String? = nil, text: String = "") {
        self.background = background
        self.foreground = foreground
        self.text = text
    }

    public var backgroundChoice: MarkColorChoice { Self.choice(background, entry: backgroundEntry) }
    public var foregroundChoice: MarkColorChoice { Self.choice(foreground, entry: foregroundEntry) }

    public mutating func setBackground(_ choice: MarkColorChoice) {
        background = MarkColorCatalog.stored(for: choice)
        if case .entry(let id) = choice { backgroundEntry = id } else { backgroundEntry = nil }
    }

    public mutating func setForeground(_ choice: MarkColorChoice) {
        let stored = MarkColorCatalog.stored(for: choice)
        foreground = choice == .unchanged ? nil : stored
        if case .entry(let id) = choice { foregroundEntry = id } else { foregroundEntry = nil }
    }

    private static func choice(_ stored: String?, entry: String?) -> MarkColorChoice {
        if let entry, let found = MarkColorCatalog.entry(id: entry), let stored, let normalized = FlowMark.normalizedHex(stored),
            found.stored == normalized || (normalized.count == 7 && found.rgb == normalized)
        {
            return .entry(entry)
        }
        return MarkColorCatalog.choice(forStored: stored)
    }
}

public enum CommentModeChoice: String, CaseIterable, Sendable {
    case set, append, findReplace, clear, regex, addIfMissing

    var engineMode: CommentAction.Mode {
        switch self {
        case .set: .set
        case .append: .append
        case .findReplace: .findReplace
        case .clear: .clear
        case .regex: .regex
        case .addIfMissing: .addIfMissing
        }
    }

    init(_ mode: CommentAction.Mode) {
        switch mode {
        case .set: self = .set
        case .append: self = .append
        case .findReplace: self = .findReplace
        case .clear: self = .clear
        case .regex: self = .regex
        case .addIfMissing: self = .addIfMissing
        }
    }

    public var localizationKey: String {
        switch self {
        case .set: "rules.comment.mode.set"
        case .append: "rules.comment.mode.append"
        case .findReplace: "rules.comment.mode.findReplace"
        case .clear: "rules.comment.mode.clear"
        case .regex: "rules.comment.mode.regex"
        case .addIfMissing: "rules.comment.mode.addIfMissing"
        }
    }
}

/// The form of a comment action. `text` is what to write, or (find and replace, regular expression) what to look for.
public struct CommentDraft: Equatable, Sendable {
    public var mode: CommentModeChoice = .append
    public var text = ""
    public var replacement = ""
    /// The "Aa" switch of the find box. A new card starts case-insensitive, as the reference does.
    public var caseSensitive: Bool

    public init(mode: CommentModeChoice = .append, text: String = "", replacement: String = "", caseSensitive: Bool = false) {
        self.mode = mode
        self.text = text
        self.replacement = replacement
        self.caseSensitive = caseSensitive
    }
}

extension RuleKind {
    /// Mark, comment and hide: no direction, any status range allowed.
    public var isAnnotation: Bool { self == .mark || self == .comment || self == .hide }
}

extension RuleEditorDraft {
    /// Loads the action half of a saved annotation rule.
    mutating func load(annotation kind: ActionKind) {
        switch kind {
        case .mark(let action):
            mark = MarkDraft(background: action.background, foreground: action.foreground, text: action.text ?? "")
        case .comment(let action):
            comment = CommentDraft(
                mode: CommentModeChoice(action.mode), text: action.text, replacement: action.replacement,
                caseSensitive: action.caseSensitive)
        default:
            break
        }
    }

    /// The action this draft's annotation kind stands for. Each broken field is added to `issues` (the
    /// first problem per field), judged by the shared validator on a probe rule.
    func annotationAction(limits: RulesLimits, issues: inout [RuleDraftField: RuleDraftIssue]) -> ActionKind? {
        func check(_ field: RuleDraftField, _ action: ActionKind) {
            let probe = Rule(id: id, name: "", enabled: enabled, order: 0, matcher: RuleMatcher(), annotation: action)
            do { try probe.validate(limits: limits) } catch let error as RuleValidationError {
                if issues[field] == nil { issues[field] = RuleDraftIssue(error) }
            } catch {
                if issues[.name] == nil { issues[.name] = .unsupportedStructure }
            }
        }
        switch kind {
        case .mark:
            let background = mark.background.trimmingCharacters(in: .whitespaces)
            let foreground = mark.foreground?.trimmingCharacters(in: .whitespaces).nilIfEmpty
            let valid = MarkPalette.presets[0].lightHex
            check(.markColor, .mark(MarkAction(background: background)))
            if let foreground { check(.markForeground, .mark(MarkAction(background: valid, foreground: foreground))) }
            let text = mark.text.nilIfEmpty
            if let text { check(.markText, .mark(MarkAction(background: valid, text: text))) }
            return .mark(MarkAction(
                background: FlowMark.normalizedHex(background) ?? background,
                foreground: foreground.map { FlowMark.normalizedHex($0) ?? $0 }, text: text))
        case .comment:
            let mode = comment.mode.engineMode
            switch comment.mode {
            case .set, .append, .addIfMissing:
                check(.commentText, .comment(CommentAction(mode: mode, text: comment.text)))
            case .findReplace, .regex:
                check(.commentFind, .comment(CommentAction(mode: mode, text: comment.text)))
                check(.commentReplacement, .comment(CommentAction(mode: mode, text: "x", replacement: comment.replacement)))
            case .clear:
                return .comment(CommentAction(mode: mode))
            }
            let looksUp = comment.mode == .findReplace || comment.mode == .regex
            return .comment(CommentAction(
                mode: mode, text: comment.text, replacement: looksUp ? comment.replacement : "",
                caseSensitive: comment.caseSensitive))
        case .hide:
            return .hide
        default:
            return nil
        }
    }

    /// A hide rule that names nothing to match hides all traffic.
    var hidesEverything: Bool {
        guard kind == .hide else { return false }
        func empty(_ text: String) -> Bool { text.trimmingCharacters(in: .whitespaces).isEmpty }
        let pathEmpty = match.syntax == .literal ? match.pathMode == .any : empty(match.path)
        return match.scheme == .any && empty(match.host) && empty(match.port) && empty(match.method) && pathEmpty
            && empty(match.statusLower) && empty(match.statusUpper)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
