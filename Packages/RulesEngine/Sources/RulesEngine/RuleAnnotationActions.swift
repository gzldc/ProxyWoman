import FlowStore
import Foundation

/// Colours a flow in the list. Colours are "#RRGGBB" or "#RRGGBBAA" with an opacity (the leading "#" optional when written).
public struct MarkAction: Codable, Sendable, Equatable, Hashable {
    public var background: String
    public var foreground: String?
    public var text: String?

    public init(background: String, foreground: String? = nil, text: String? = nil) {
        self.background = background
        self.foreground = foreground
        self.text = text
    }

    /// The two colour choices that carry no colour (the editor's "unchanged" and "default"): `""` and `"default"`.
    /// They validate and they never produce a mark by themselves (`flowMark` is nil for them), so a rule that
    /// holds only these changes nothing. The files and behaviour of every colour that is a `#RRGGBB` are as before.
    public static let unchangedColor = ""
    public static let defaultColor = "default"

    public static func isNoColorChoice(_ color: String) -> Bool { color == unchangedColor || color == defaultColor }

    /// What "default" asks for (the reset to the session colour): a background of "default" clears the whole mark
    /// an earlier rule set; an unchanged background with a "default" text colour clears just the text colour. nil when
    /// the action resets nothing.
    public var colorReset: (background: Bool, foreground: Bool)? {
        if background == Self.defaultColor { return (true, true) }
        if background == Self.unchangedColor, foreground == Self.defaultColor { return (false, true) }
        return nil
    }

    /// The mark a rule puts on a flow; nil when a colour is not valid (validation stops that first).
    public func flowMark(ruleID: UUID, ruleName: String) -> FlowMark? {
        FlowMark(
            background: background, foreground: foreground.flatMap { Self.isNoColorChoice($0) ? nil : $0 }, text: text, source: .rule(id: ruleID, name: ruleName))
    }
}

/// Changes a flow's comment.
public struct CommentAction: Codable, Sendable, Equatable, Hashable {
    public enum Mode: String, Codable, Sendable, CaseIterable {
        case set, append, findReplace, clear
        /// Replaces every match of the regular expression `text`; `replacement` is a template (`$1`).
        case regex
        /// Writes `text` only when the flow has no comment yet.
        case addIfMissing
    }

    public var mode: Mode
    /// What to write, or (find and replace, regex) what to look for.
    public var text: String
    /// Find and replace and regex only.
    public var replacement: String
    /// Find and replace and regex only. The original find and replace is case-sensitive, so that is the
    /// default; the file only carries the field when it is off.
    public var caseSensitive: Bool

    public init(mode: Mode = .append, text: String = "", replacement: String = "", caseSensitive: Bool = true) {
        self.mode = mode
        self.text = text
        self.replacement = replacement
        self.caseSensitive = caseSensitive
    }

    private enum CodingKeys: String, CodingKey { case mode, text, replacement, caseSensitive }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = try container.decode(Mode.self, forKey: .mode)
        text = try container.decode(String.self, forKey: .text)
        replacement = try container.decode(String.self, forKey: .replacement)
        caseSensitive = try container.decodeIfPresent(Bool.self, forKey: .caseSensitive) ?? true
    }

    /// The default case flag is not written, so files from before it existed keep their bytes.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mode, forKey: .mode)
        try container.encode(text, forKey: .text)
        try container.encode(replacement, forKey: .replacement)
        if !caseSensitive { try container.encode(caseSensitive, forKey: .caseSensitive) }
    }

    /// The comment after this action. `set` writes `text`; `append` joins to a non-empty comment with
    /// one space; `addIfMissing` writes `text` only to an empty comment; `findReplace` replaces every
    /// literal occurrence (case-sensitive unless `caseSensitive` is off) and leaves a missing comment (or
    /// no occurrence) as it was; `regex` does the same with a regular expression; `clear` removes it.
    /// The result is cut to the comment cap.
    public func applying(to existing: String?) -> String? {
        applying(to: existing, allowance: RegexAllowance(), cache: PatternCache.shared)
    }

    func applying(to existing: String?, allowance: RegexAllowance, cache: PatternCache) -> String? {
        let current = existing.flatMap { $0.isEmpty ? nil : $0 }
        switch mode {
        case .set:
            return Flow.limitedComment(text)
        case .append:
            return Flow.limitedComment(current.map { $0 + " " + text } ?? text)
        case .addIfMissing:
            return Flow.limitedComment(current ?? text)
        case .findReplace:
            guard let current else { return nil }
            guard !text.isEmpty else { return Flow.limitedComment(current) }
            let options: String.CompareOptions = caseSensitive ? [.literal] : [.literal, .caseInsensitive]
            return Flow.limitedComment(current.replacingOccurrences(of: text, with: replacement, options: options))
        case .regex:
            guard let current else { return nil }
            guard !text.isEmpty, let compiled = try? cache.regex(text, mode: .find, caseInsensitive: !caseSensitive)
            else { return Flow.limitedComment(current) }
            switch compiled.replacingMatches(in: current, template: replacement, allowance: allowance) {
            case .replaced(let replaced): return Flow.limitedComment(replaced)
            case .noMatch, .inputTooLong, .timedOut, .disabled: return Flow.limitedComment(current)
            }
        case .clear:
            return nil
        }
    }
}

/// One thing a rule does to a flow's record (never to the traffic), in the order the rules ran.
public enum FlowAnnotation: Sendable, Equatable {
    case mark(FlowMark)
    /// A mark action whose colour is "default": clears the background (the whole mark) and/or the text colour set by earlier
    /// rules. Appended after the rule marks it follows, so a later mark colours again.
    case resetMark(background: Bool, foreground: Bool)
    case comment(CommentAction)
    case hide
}

/// The old editor's view of a rule with one annotation action.
public struct SimpleAnnotationRule: Sendable, Equatable {
    public var matcher: RuleMatcher
    public var kind: ActionKind
    public var mode: ConditionGroup.Mode

    public init(matcher: RuleMatcher, kind: ActionKind, mode: ConditionGroup.Mode) {
        self.matcher = matcher
        self.kind = kind
        self.mode = mode
    }
}

/// What the old editor can show of a rule: one of its two readable shapes.
public enum OldEditorForm: Sendable, Equatable {
    case legacy(SimpleRule)
    case annotation(SimpleAnnotationRule)
}
