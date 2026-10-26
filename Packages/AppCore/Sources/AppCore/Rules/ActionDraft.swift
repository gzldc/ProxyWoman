import FlowStore
import Foundation
import RulesEngine

/// The input an action form error belongs to.
public enum ActionField: Hashable, Sendable {
    case urlFind, urlReplacement, queryRow(UUID), cookieRow(UUID), headerRow(UUID), bodyFind, bodyReplacement
    case targetScheme, targetHost, targetPort, targetPath, status, delay
    case magicString, handwritten, presetLocation, presetChallenge, presetBody, directory, file, directoryPrefix, markColor, markForeground, markText, commentText, commentFind, commentReplacement
    /// The card as a whole: its type is ruled out by the judgment point or by the other cards.
    case type
    /// The "make this action final" tick.
    case final
}

/// Valid but probably unintended input.
public enum ActionWarning: Equatable, Sendable { case contentLengthCorrected, hideCutsLowerRules, markTextColorNeedsBackground }

/// What one action form produces: the action when every field is fine, else the issue of each field that is not.
public struct ActionBuildResult: Equatable, Sendable {
    public var action: RuleAction?
    public var issues: [ActionField: RuleDraftIssue]
    public var warnings: [ActionWarning]

    public init(action: RuleAction? = nil, issues: [ActionField: RuleDraftIssue] = [:], warnings: [ActionWarning] = []) {
        self.action = action
        self.issues = issues
        self.warnings = warnings
    }

}

/// How one header edit changes the field. The six of the reference come first, in its order; `append` (add a second
/// field of the same name) is an old-style method a saved rule can still hold.
public enum HeaderMethod: String, CaseIterable, Sendable {
    case set, findReplace, regex, addIfMissing, appendToValue, remove, append

    public var titleKey: String {
        switch self {
        case .set: "rules.headerMethod.set"
        case .addIfMissing: "rules.headerMethod.addIfMissing"
        case .append: "rules.headerMethod.append"
        case .appendToValue: "rules.headerMethod.appendToValue"
        case .findReplace: "rules.headerMethod.findReplace"
        case .regex: "rules.headerMethod.regex"
        case .remove: "rules.headerMethod.remove"
        }
    }

    public var isLegacy: Bool { self == .append }
}

public enum QueryMethod: String, CaseIterable, Sendable {
    case set, findReplace, regex, addIfMissing, appendToValue, remove, add

    public var titleKey: String {
        switch self {
        case .set: "rules.queryMethod.set"
        case .add: "rules.queryMethod.add"
        case .remove: "rules.queryMethod.remove"
        case .findReplace: "rules.queryMethod.findReplace"
        case .regex: "rules.queryMethod.regex"
        case .addIfMissing: "rules.queryMethod.addIfMissing"
        case .appendToValue: "rules.queryMethod.appendToValue"
        }
    }

    /// `add` (a second parameter of the same name) is the old-style method.
    public var isLegacy: Bool { self == .add }
}

public enum CookieMethod: String, CaseIterable, Sendable {
    case set, findReplace, regex, addIfMissing, appendToValue, remove

    public var titleKey: String {
        switch self {
        case .set: "rules.cookieMethod.set"
        case .addIfMissing: "rules.cookieMethod.addIfMissing"
        case .remove: "rules.cookieMethod.remove"
        case .findReplace: "rules.cookieMethod.findReplace"
        case .regex: "rules.cookieMethod.regex"
        case .appendToValue: "rules.cookieMethod.appendToValue"
        }
    }

    public var isLegacy: Bool { false }
}

extension URLEditAction.Mode {
    public var titleKey: String {
        switch self {
        case .set: "rules.urlMode.set"
        case .findReplace: "rules.urlMode.findReplace"
        case .regex: "rules.urlMode.regex"
        case .append: "rules.urlMode.append"
        }
    }
}

/// One row of a header edit table. `value` is the value to write, the text to append, or what to find;
/// `replacement` is only read by the two look-up methods.
public struct HeaderEditRow: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var method: HeaderMethod
    public var name: String
    public var value: String
    public var replacement: String
    public var caseSensitive: Bool
    /// The key's "Aa" as the file stores it: nil is the original behaviour (see `nameCaseOn`), true is exact case,
    /// false ignores case. A card opened from a saved rule keeps nil until the user flips the switch.
    public var nameCaseSensitive: Bool?

    public init(
        id: UUID = UUID(), method: HeaderMethod = .set, name: String = "", value: String = "", replacement: String = "",
        caseSensitive: Bool = false, nameCaseSensitive: Bool? = nil
    ) {
        self.id = id
        self.method = method
        self.name = name
        self.value = value
        self.replacement = replacement
        self.caseSensitive = caseSensitive
        self.nameCaseSensitive = nameCaseSensitive
    }

    /// Nothing typed, the first method, no choice made for the key: a row nobody has touched.
    var isPristine: Bool {
        method == .set && name.isEmpty && value.isEmpty && replacement.isEmpty && !caseSensitive && nameCaseSensitive == nil
    }

    /// What the "Aa" switch shows: names match in exact case. Without a stored choice that is the original behaviour
    /// (header names ignore case).
    public var nameCaseOn: Bool {
        get { nameCaseSensitive == true }
        set { nameCaseSensitive = newValue }
    }
}

/// One row of a query edit table; `value` is the value to write or what to find. An empty name on a find and
/// replace means every parameter.
public struct QueryEditRow: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var method: QueryMethod
    public var name: String
    public var value: String
    public var replacement: String
    public var caseSensitive: Bool
    /// The key's "Aa" as the file stores it: nil is the original behaviour (see `nameCaseOn`), true is exact case,
    /// false ignores case. A card opened from a saved rule keeps nil until the user flips the switch.
    public var nameCaseSensitive: Bool?

    public init(
        id: UUID = UUID(), method: QueryMethod = .set, name: String = "", value: String = "", replacement: String = "",
        caseSensitive: Bool = false, nameCaseSensitive: Bool? = nil
    ) {
        self.id = id
        self.method = method
        self.name = name
        self.value = value
        self.replacement = replacement
        self.caseSensitive = caseSensitive
        self.nameCaseSensitive = nameCaseSensitive
    }

    /// Nothing typed, the first method, no choice made for the key: a row nobody has touched.
    var isPristine: Bool {
        method == .set && name.isEmpty && value.isEmpty && replacement.isEmpty && !caseSensitive && nameCaseSensitive == nil
    }

    /// What the "Aa" switch shows: names match in exact case. Without a stored choice that is the original behaviour
    /// (names match in exact case).
    public var nameCaseOn: Bool {
        get { nameCaseSensitive != false }
        set { nameCaseSensitive = newValue }
    }
}

/// One row of a cookie edit table; `value` is the value to write or what to find. An empty name on a look-up
/// means every cookie.
public struct CookieEditRow: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var method: CookieMethod
    public var name: String
    public var value: String
    public var replacement: String
    public var caseSensitive: Bool
    /// The key's "Aa" as the file stores it: nil is the original behaviour (see `nameCaseOn`), true is exact case,
    /// false ignores case. A card opened from a saved rule keeps nil until the user flips the switch.
    public var nameCaseSensitive: Bool?

    public init(
        id: UUID = UUID(), method: CookieMethod = .set, name: String = "", value: String = "", replacement: String = "",
        caseSensitive: Bool = false, nameCaseSensitive: Bool? = nil
    ) {
        self.id = id
        self.method = method
        self.name = name
        self.value = value
        self.replacement = replacement
        self.caseSensitive = caseSensitive
        self.nameCaseSensitive = nameCaseSensitive
    }

    /// Nothing typed, the first method, no choice made for the key: a row nobody has touched.
    var isPristine: Bool {
        method == .set && name.isEmpty && value.isEmpty && replacement.isEmpty && !caseSensitive && nameCaseSensitive == nil
    }

    /// What the "Aa" switch shows: names match in exact case. Without a stored choice that is the original behaviour
    /// (names match in exact case).
    public var nameCaseOn: Bool {
        get { nameCaseSensitive != false }
        set { nameCaseSensitive = newValue }
    }
}

public struct URLEditDraft: Equatable, Sendable {
    public var mode: URLEditAction.Mode
    public var find: String
    public var replacement: String
    public var caseSensitive: Bool
    public var preserveCredentials: Bool

    public init(
        mode: URLEditAction.Mode = .set, find: String = "", replacement: String = "", caseSensitive: Bool = false,
        preserveCredentials: Bool = false
    ) {
        self.mode = mode
        self.find = find
        self.replacement = replacement
        self.caseSensitive = caseSensitive
        self.preserveCredentials = preserveCredentials
    }
}

/// The four ways of the reference's body edit: set the whole text, find and replace, regular expression, remove.
public enum BodyMode: String, CaseIterable, Sendable {
    case setValue, findReplace, regex, remove

    public var titleKey: String {
        switch self {
        case .setValue: "rules.bodyOperation.setValue"
        case .findReplace: "rules.bodyOperation.findReplace"
        case .regex: "rules.rewriteBody.syntax.regex"
        case .remove: "rules.bodyOperation.clear"
        }
    }
}

public struct BodyEditDraft: Equatable, Sendable {
    public var operation: BodyRewriteOperation
    public var syntax: BodyFindSyntax
    public var find: String
    public var replacement: String
    public var caseSensitive: Bool
    public var scope: BodyReplaceScope
    /// The highlighting language of the big editor (`BodyEditorLanguage` ids), nil: plain text. Never changes traffic.
    public var editorLanguage: String?

    public init(
        operation: BodyRewriteOperation = .findReplace, syntax: BodyFindSyntax = .text, find: String = "",
        replacement: String = "", caseSensitive: Bool = true, scope: BodyReplaceScope = .all, editorLanguage: String? = nil
    ) {
        self.operation = operation
        self.syntax = syntax
        self.find = find
        self.replacement = replacement
        self.caseSensitive = caseSensitive
        self.scope = scope
        self.editorLanguage = editorLanguage
    }

    /// Where the operation and the syntax meet: a regular expression is a find and replace in `regex` syntax.
    public var mode: BodyMode {
        get {
            switch operation {
            case .setValue: .setValue
            case .clear: .remove
            case .findReplace: syntax == .regex ? .regex : .findReplace
            }
        }
        set {
            switch newValue {
            case .setValue: operation = .setValue
            case .remove: operation = .clear
            case .findReplace:
                operation = .findReplace
                syntax = .text
            case .regex:
                operation = .findReplace
                syntax = .regex
            }
        }
    }
}

/// One action card as the editor holds it: every form's texts stay in the draft, so changing the type back and
/// forth loses nothing; `build` reads only the form of the current type.
///
/// A header, cookie or query card holds one edit (the reference's one operation per card). A stored action with
/// several edits is split into consecutive cards by `cards(for:)`; the cards remember where they came from, so a rule
/// nobody edited is saved as the action it was (R8F2-9).
public struct ActionDraft: Identifiable, Equatable, Sendable {
    /// What a card was opened from: the stored action and what the form built from it, so the form can hand the
    /// stored action back whenever it still builds the same thing (kinds the form cannot show exactly survive).
    struct Baseline: Equatable, Sendable {
        var original: RuleAction
        var built: RuleAction?
    }

    /// The card is one share of a stored multi-edit action.
    struct SplitOrigin: Equatable, Sendable {
        var group: UUID
        var index: Int
        var count: Int
        var original: RuleAction
    }

    public var id: UUID
    public private(set) var type: ActionType
    public var isFinal: Bool
    public var url = URLEditDraft()
    public var queryRows: [QueryEditRow] = [QueryEditRow()]
    public var cookieRows: [CookieEditRow] = [CookieEditRow()]
    public var headerRows: [HeaderEditRow] = [HeaderEditRow()]
    public var body = BodyEditDraft()
    public var remote = MapRemoteDraft()
    public var status = RewriteStatusDraft()
    public var breakpointMode: BreakpointPauseMode = .headers
    public var delayText = ""
    public var file = MapLocalDraft()
    public var directory = MapLocalDirectoryDraft()
    public var directoryPrefix = "/"
    public var handwrittenText = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n"
    public var preset = PresetResponse.Preset.notFound404
    /// The redirect presets' `Location`; a new card starts at the reference's default address (R8F2-7).
    public var presetLocation = MagicStringAction.defaultRedirectLocation
    public var presetChallenge = ""
    public var presetBody = ""
    /// A new card marks nothing: both colours unchanged.
    public var mark = MarkDraft()
    public var comment = CommentDraft()
    public var magicText = ""
    /// A stored action no form can show (a defence: every kind has a form today). It is kept as it is, read-only,
    /// until the user picks another type.
    public private(set) var opaque: RuleAction?
    private(set) var baseline: Baseline?
    private(set) var split: SplitOrigin?

    public var isOpaque: Bool { opaque != nil }

    /// Where the card can run. A magic string card takes it from what its text resolves to.
    public var traits: ActionType.Traits { type.traits(of: type == .magicString ? .magicString(magicText) : nil) }

    public init(type: ActionType, id: UUID = UUID()) {
        self.id = id
        self.type = type
        self.isFinal = false
    }

    /// The editable form of a stored action (the other direction's forms keep their defaults). An action with several
    /// edits keeps all of them as rows; `cards(for:)` is what splits them.
    public init(action: RuleAction) {
        self.init(action: action, typeOf: { ActionType($0) })
    }

    /// `typeOf` names the type of a kind; a kind it cannot name is kept untouched as `opaque`.
    init(action: RuleAction, typeOf: (ActionKind) -> ActionType?) {
        guard let type = typeOf(action.kind) else {
            self.init(type: .modifyURL)
            isFinal = action.isFinal
            opaque = action
            return
        }
        self.init(type: type)
        isFinal = action.isFinal
        load(action.kind)
        baseline = Baseline(original: action, built: buildForm(limits: RulesLimits()).action)
    }

    private mutating func load(_ kind: ActionKind) {
        switch kind {
        case .modifyURL(let edit):
            url = URLEditDraft(
                mode: edit.mode, find: edit.find, replacement: edit.replacement, caseSensitive: edit.caseSensitive,
                preserveCredentials: edit.preserveCredentials)
        case .modifyQuery(let edit):
            queryRows = edit.operations.isEmpty ? [QueryEditRow()] : edit.operations.map(QueryEditRow.init)
        case .editCookies(_, let operations):
            cookieRows = operations.isEmpty ? [CookieEditRow()] : operations.map(CookieEditRow.init)
        case .editHeaders(_, let operations):
            headerRows = operations.isEmpty ? [HeaderEditRow()] : operations.map(HeaderEditRow.init)
        case .rewriteBody(_, let rewrite):
            body = BodyEditDraft(
                operation: rewrite.operation, syntax: rewrite.syntax, find: rewrite.find, replacement: rewrite.replacement,
                caseSensitive: rewrite.caseSensitive, scope: rewrite.scope, editorLanguage: rewrite.editorLanguage)
        case .mapRemote(let target):
            remote.targetScheme = RuleTargetScheme(rawValue: target.targetScheme.lowercased()) ?? .https
            remote.targetHost = target.targetHost
            remote.targetPort = String(target.targetPort)
            switch target.path {
            case .preserve: remote.pathChoice = .preserve
            case .replace(let path):
                remote.pathChoice = .replace
                remote.replacementPath = path
            }
            remote.preserveCredentials = target.preserveCredentials
        case .breakpoint(_, let mode):
            breakpointMode = mode
        case .delay(let milliseconds):
            delayText = String(milliseconds)
        case .rewriteStatus(let rewrite):
            status = RewriteStatusDraft(status: rewrite.text, includeLocalResponses: rewrite.includeLocalResponses)
        case .returnFile(let local):
            file.asset = ManagedAsset(id: local.assetID, size: 0, displayName: "", importedAt: .distantPast)
            file.status = String(local.status)
            file.headers = local.headers.map { HeaderFieldRow(name: $0.name, value: $0.value) }
        case .returnDirectory(let served, let prefix):
            directory.bookmark = served.bookmark
            directory.displayName = served.displayName
            directory.servesIndex = served.servesIndex
            directory.missing = served.missing
            directory.headers = served.headers.map { HeaderFieldRow(name: $0.name, value: $0.value) }
            directoryPrefix = prefix
        case .returnHandwritten(let response):
            handwrittenText = response.text
        case .returnPreset(let stored):
            preset = stored.preset
            presetLocation = stored.location ?? MagicStringAction.defaultRedirectLocation
            presetChallenge = stored.challenge ?? ""
            presetBody = stored.body ?? ""
        case .mark(let stored):
            mark = MarkDraft(background: stored.background, foreground: stored.foreground, text: stored.text ?? "")
        case .comment(let stored):
            comment = CommentDraft(
                mode: CommentModeChoice(stored.mode), text: stored.text, replacement: stored.replacement,
                caseSensitive: stored.caseSensitive)
        case .magicString(let text):
            magicText = text
        case .closeConnection, .returnConnectTunnel, .noDecrypt, .hide:
            break  // the type says it all
        }
    }

    /// The cards a stored action opens as: one, except a header, cookie or query action with several edits, which
    /// becomes one card per edit in the same order (they ran in that order anyway). The "stop" tick stays on the last.
    public static func cards(for action: RuleAction) -> [ActionDraft] {
        func cards<Edit>(
            _ edits: [Edit], _ make: (Edit) -> ActionKind
        ) -> [ActionDraft] {
            let group = UUID()
            return edits.enumerated().map { index, edit in
                var card = ActionDraft(action: RuleAction(make(edit), isFinal: index == edits.count - 1 ? action.isFinal : false))
                card.split = SplitOrigin(group: group, index: index, count: edits.count, original: action)
                return card
            }
        }
        switch action.kind {
        case .editHeaders(let direction, let operations) where operations.count > 1:
            return cards(operations) { .editHeaders(direction: direction, operations: [$0]) }
        case .editCookies(let direction, let operations) where operations.count > 1:
            return cards(operations) { .editCookies(direction: direction, operations: [$0]) }
        case .modifyQuery(let edit) where edit.operations.count > 1:
            return cards(edit.operations) { .modifyQuery(QueryEditAction(operations: [$0])) }
        default:
            return [ActionDraft(action: action)]
        }
    }

    /// Whether the form still builds what it built when the card was opened (the type and every text are as they were;
    /// the stop tick is separate, it is the user's to change either way).
    func isUnchanged(since result: ActionBuildResult) -> Bool {
        guard let baseline, let built = baseline.built, let now = result.action, result.issues.isEmpty else { return false }
        return now.kind == built.kind
    }

    /// Whether the form still reads what it read when the card was opened. This compares the form with its own earlier
    /// reading, not with the stored action `build` hands back, so an edit the form cannot show exactly (a name stored
    /// as an empty text) still counts as untouched.
    func isUntouched(limits: RulesLimits) -> Bool { isUnchanged(since: buildForm(limits: limits)) }

    /// The managed files the action this card builds points at.
    public func referencedAssetIDs() -> Set<UUID> {
        if let opaque {
            if case .returnFile(let local) = opaque.kind { return [local.assetID] }
            return []
        }
        guard type == .returnFile, let asset = file.asset else { return [] }
        return [asset.id]
    }

    /// Switches the card to another type. The final tick and every form's content stay, so changing between
    /// the two directions of one family only changes the direction.
    public mutating func setType(_ newType: ActionType) {
        type = newType
        opaque = nil
        defaultKeyCaseOff()
    }

    /// A card that is new (or has just become a header, cookie or query card with an empty table) starts with the key's
    /// "Aa" off: names ignore case, as in the reference. A table that holds anything keeps what it has.
    mutating func defaultKeyCaseOff() {
        // A card opened from a saved rule keeps what the rule says.
        guard baseline == nil else { return }
        switch type {
        case .editRequestHeaders, .editResponseHeaders:
            if headerRows.count == 1, headerRows[0].isPristine { headerRows[0].nameCaseSensitive = false }
        case .modifyQuery:
            if queryRows.count == 1, queryRows[0].isPristine { queryRows[0].nameCaseSensitive = false }
        case .editRequestCookies, .editResponseCookies:
            if cookieRows.count == 1, cookieRows[0].isPristine { cookieRows[0].nameCaseSensitive = false }
        default:
            break
        }
    }

    /// The key's "Aa" of a header, cookie or query card as the switch shows it (nil: the type has no key).
    public var keyCaseOn: Bool? {
        switch type {
        case .editRequestHeaders, .editResponseHeaders: (headerRows.first ?? HeaderEditRow()).nameCaseOn
        case .modifyQuery: (queryRows.first ?? QueryEditRow()).nameCaseOn
        case .editRequestCookies, .editResponseCookies: (cookieRows.first ?? CookieEditRow()).nameCaseOn
        default: nil
        }
    }

    /// Flips the key's "Aa" of the card (every edit it holds; a card holds one).
    public mutating func setKeyCase(_ on: Bool) {
        switch type {
        case .editRequestHeaders, .editResponseHeaders: for index in headerRows.indices { headerRows[index].nameCaseOn = on }
        case .modifyQuery: for index in queryRows.indices { queryRows[index].nameCaseOn = on }
        case .editRequestCookies, .editResponseCookies: for index in cookieRows.indices { cookieRows[index].nameCaseOn = on }
        default: break
        }
    }

    /// A copy that is a new card of its own: nothing ties it to a stored action any more.
    func detachedCopy() -> ActionDraft {
        var copy = self
        copy.id = UUID()
        copy.split = nil
        return copy
    }
}

extension HeaderEditRow {
    init(_ edit: HeaderEdit) {
        let flag = edit.nameCaseSensitive
        switch edit {
        case .set(let name, let value, _): self.init(method: .set, name: name, value: value, nameCaseSensitive: flag)
        case .addIfMissing(let name, let value, _):
            self.init(method: .addIfMissing, name: name, value: value, nameCaseSensitive: flag)
        case .append(let name, let value, _): self.init(method: .append, name: name, value: value, nameCaseSensitive: flag)
        case .appendToValue(let name, let text, _):
            self.init(method: .appendToValue, name: name, value: text, nameCaseSensitive: flag)
        case .findReplace(let name, let find, let replacement, let caseSensitive, _):
            self.init(
                method: .findReplace, name: name, value: find, replacement: replacement, caseSensitive: caseSensitive,
                nameCaseSensitive: flag)
        case .regex(let name, let pattern, let replacement, let caseSensitive, _):
            self.init(
                method: .regex, name: name, value: pattern, replacement: replacement, caseSensitive: caseSensitive,
                nameCaseSensitive: flag)
        case .remove(let name, _): self.init(method: .remove, name: name, nameCaseSensitive: flag)
        }
    }
}

extension QueryEditRow {
    init(_ edit: QueryEdit) {
        let flag = edit.nameCaseSensitive
        switch edit {
        case .set(let name, let value, _): self.init(method: .set, name: name, value: value, nameCaseSensitive: flag)
        case .add(let name, let value, _): self.init(method: .add, name: name, value: value, nameCaseSensitive: flag)
        case .remove(let name, _): self.init(method: .remove, name: name, nameCaseSensitive: flag)
        case .findReplace(let name, let find, let replacement, let caseSensitive, _):
            self.init(
                method: .findReplace, name: name ?? "", value: find, replacement: replacement, caseSensitive: caseSensitive,
                nameCaseSensitive: flag)
        case .regex(let name, let pattern, let replacement, let caseSensitive, _):
            self.init(
                method: .regex, name: name ?? "", value: pattern, replacement: replacement, caseSensitive: caseSensitive,
                nameCaseSensitive: flag)
        case .addIfMissing(let name, let value, _):
            self.init(method: .addIfMissing, name: name, value: value, nameCaseSensitive: flag)
        case .appendToValue(let name, let text, _):
            self.init(method: .appendToValue, name: name, value: text, nameCaseSensitive: flag)
        }
    }
}

extension CookieEditRow {
    init(_ edit: CookieEdit) {
        let flag = edit.nameCaseSensitive
        switch edit {
        case .set(let name, let value, _): self.init(method: .set, name: name, value: value, nameCaseSensitive: flag)
        case .addIfMissing(let name, let value, _):
            self.init(method: .addIfMissing, name: name, value: value, nameCaseSensitive: flag)
        case .remove(let name, _): self.init(method: .remove, name: name, nameCaseSensitive: flag)
        case .findReplace(let name, let find, let replacement, let caseSensitive, _):
            self.init(
                method: .findReplace, name: name ?? "", value: find, replacement: replacement, caseSensitive: caseSensitive,
                nameCaseSensitive: flag)
        case .regex(let name, let pattern, let replacement, let caseSensitive, _):
            self.init(
                method: .regex, name: name ?? "", value: pattern, replacement: replacement, caseSensitive: caseSensitive,
                nameCaseSensitive: flag)
        case .appendToValue(let name, let text, _):
            self.init(method: .appendToValue, name: name, value: text, nameCaseSensitive: flag)
        }
    }
}

extension PresetResponse.Preset {
    public var titleKey: String {
        switch self {
        case .emptyHTML200: "rules.preset.emptyHTML200"
        case .gif200: "rules.preset.gif200"
        case .noContent204: "rules.preset.noContent204"
        case .movedPermanently301: "rules.preset.movedPermanently301"
        case .found302: "rules.preset.found302"
        case .seeOther303: "rules.preset.seeOther303"
        case .notModified304: "rules.preset.notModified304"
        case .temporaryRedirect307: "rules.preset.temporaryRedirect307"
        case .permanentRedirect308: "rules.preset.permanentRedirect308"
        case .badRequest400: "rules.preset.badRequest400"
        case .unauthorized401: "rules.preset.unauthorized401"
        case .forbidden403: "rules.preset.forbidden403"
        case .notFound404: "rules.preset.notFound404"
        case .proxyAuthRequired407: "rules.preset.proxyAuthRequired407"
        case .tooManyRequests429: "rules.preset.tooManyRequests429"
        case .internalError500: "rules.preset.internalError500"
        case .serviceUnavailable503: "rules.preset.serviceUnavailable503"
        case .transparentPixel200: "rules.preset.transparentPixel200"
        case .digestAuth401: "rules.preset.digestAuth401"
        case .unreachable502: "rules.preset.unreachable502"
        }
    }
}

extension ActionKind {
    /// This action with the edits of `other` after its own, when both are the same kind of header, cookie or query action
    /// (same direction); nil otherwise.
    func appendingEdits(of other: ActionKind) -> ActionKind? {
        switch (self, other) {
        case (.editHeaders(let direction, let mine), .editHeaders(let otherDirection, let theirs)) where direction == otherDirection:
            return .editHeaders(direction: direction, operations: mine + theirs)
        case (.editCookies(let direction, let mine), .editCookies(let otherDirection, let theirs)) where direction == otherDirection:
            return .editCookies(direction: direction, operations: mine + theirs)
        case (.modifyQuery(let mine), .modifyQuery(let theirs)):
            return .modifyQuery(QueryEditAction(operations: mine.operations + theirs.operations))
        default:
            return nil
        }
    }
}
