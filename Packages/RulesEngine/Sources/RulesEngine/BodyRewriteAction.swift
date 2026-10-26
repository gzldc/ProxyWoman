import Foundation

public enum BodyFindSyntax: String, Sendable, Equatable, Hashable, Codable, CaseIterable { case text, regex }

public enum BodyReplaceScope: String, Sendable, Equatable, Hashable, Codable, CaseIterable { case all, first }

/// What a body rewrite does: look up and replace (the original), put a whole new text in place of the
/// body, or empty it. `setValue` and `clear` ignore `find`, `syntax`, `caseSensitive` and `scope`.
public enum BodyRewriteOperation: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
    case findReplace, setValue, clear
}

/// One find-and-replace over a message body. In `.text` syntax both fields are literal; in
/// `.regex` syntax `find` is an ICU regular expression and `replacement` an ICU template
/// (`$1`, `\$`).
public struct BodyRewriteAction: Sendable, Equatable, Hashable, Codable {
    public static let maxFindBytes = 1024

    public var find: String
    public var replacement: String
    public var syntax: BodyFindSyntax
    public var caseSensitive: Bool
    public var scope: BodyReplaceScope
    /// `.setValue` replaces the whole text body with `replacement`, `.clear` empties it.
    public var operation: BodyRewriteOperation
    /// The highlighting language the editor shows the text in (`plaintext`, `json`, `css`, `xml`, `html`,
    /// `javascript`, `typescript`). An editor preference only: it never changes the traffic and is not
    /// written to a file when nil.
    public var editorLanguage: String?

    public init(
        find: String, replacement: String, syntax: BodyFindSyntax = .text, caseSensitive: Bool = true,
        scope: BodyReplaceScope = .all, operation: BodyRewriteOperation = .findReplace,
        editorLanguage: String? = nil
    ) {
        self.editorLanguage = editorLanguage
        self.operation = operation
        self.find = find
        self.replacement = replacement
        self.syntax = syntax
        self.caseSensitive = caseSensitive
        self.scope = scope
    }

    private enum CodingKeys: String, CodingKey { case find, replacement, syntax, caseSensitive, scope, operation, editorLanguage }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        find = try container.decode(String.self, forKey: .find)
        replacement = try container.decode(String.self, forKey: .replacement)
        syntax = try container.decode(BodyFindSyntax.self, forKey: .syntax)
        caseSensitive = try container.decode(Bool.self, forKey: .caseSensitive)
        scope = try container.decode(BodyReplaceScope.self, forKey: .scope)
        operation = try container.decodeIfPresent(BodyRewriteOperation.self, forKey: .operation) ?? .findReplace
        editorLanguage = try container.decodeIfPresent(String.self, forKey: .editorLanguage)
    }

    /// The default operation and an unset language are not written, so files from before it existed keep their bytes.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(find, forKey: .find)
        try container.encode(replacement, forKey: .replacement)
        try container.encode(syntax, forKey: .syntax)
        try container.encode(caseSensitive, forKey: .caseSensitive)
        try container.encode(scope, forKey: .scope)
        if operation != .findReplace { try container.encode(operation, forKey: .operation) }
        try container.encodeIfPresent(editorLanguage, forKey: .editorLanguage)
    }

    /// The text this step puts in place of the whole body, nil for a find-and-replace.
    var wholeText: String? {
        switch operation {
        case .findReplace: nil
        case .setValue: replacement
        case .clear: ""
        }
    }
}

/// An action together with the rule that owns it; steps are applied in order to one buffer.
public struct BodyRewriteStep: Sendable, Equatable {
    public var ruleID: UUID
    /// The action's position in its rule, carried to the step's outcomes (`RuleOutcome.actionIndex`);
    /// nil for a rule with a single action.
    public var actionIndex: Int?
    public var action: BodyRewriteAction

    public init(ruleID: UUID, actionIndex: Int? = nil, action: BodyRewriteAction) {
        self.ruleID = ruleID
        self.actionIndex = actionIndex
        self.action = action
    }
}
