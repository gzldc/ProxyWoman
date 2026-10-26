import FlowStore
import Foundation
import Localization
import RulesEngine

/// The rule actions, in the order the editor offers them. The raw value is a stable identity
/// (never shown, never translated).
public enum RuleKind: String, CaseIterable, Sendable, Hashable, Identifiable {
    case mapLocal, mapLocalDirectory, mapRemote, editHeaders, breakpoint, rewriteBody, rewriteStatus
    case mark, comment, hide

    public var id: String { rawValue }

    public init(_ action: LegacyRuleAction) {
        switch action {
        case .mapLocal: self = .mapLocal
        case .mapLocalDirectory: self = .mapLocalDirectory
        case .mapRemote: self = .mapRemote
        case .editHeaders: self = .editHeaders
        case .breakpoint: self = .breakpoint
        case .rewriteBody: self = .rewriteBody
        case .rewriteStatus: self = .rewriteStatus
        }
    }

    /// The kind of a rule this editor can state (`Rule.oldEditorForm`); nil for any other rule, which the
    /// list shows as having several actions.
    public init?(_ rule: Rule) {
        switch rule.oldEditorForm {
        case .legacy(let simple): self.init(simple.action)
        case .annotation(let annotation): self.init(annotation.kind)
        case nil: return nil
        }
    }

    /// The kind of one action of a rule 2.0.
    init?(_ kind: ActionKind) {
        switch kind {
        case .returnFile: self = .mapLocal
        case .returnDirectory: self = .mapLocalDirectory
        case .mapRemote: self = .mapRemote
        case .editHeaders: self = .editHeaders
        case .breakpoint: self = .breakpoint
        case .rewriteBody: self = .rewriteBody
        case .rewriteStatus: self = .rewriteStatus
        case .mark: self = .mark
        case .comment: self = .comment
        case .hide: self = .hide
        // The old editor has no form for the Rules 2.0 R4 actions (the rule editor window is R5).
        case .modifyURL, .modifyQuery, .editCookies, .delay, .returnHandwritten, .returnPreset, .closeConnection,
            .returnConnectTunnel, .noDecrypt, .magicString: return nil
        }
    }

    public var localizationKey: String {
        switch self {
        case .mapLocal: "rules.kind.mapLocal"
        case .mapLocalDirectory: "rules.kind.mapLocalDirectory"
        case .mapRemote: "rules.kind.mapRemote"
        case .editHeaders: "rules.kind.editHeaders"
        case .breakpoint: "rules.kind.breakpoint"
        case .rewriteBody: "rules.kind.rewriteBody"
        case .rewriteStatus: "rules.kind.rewriteStatus"
        case .mark: "rules.kind.mark"
        case .comment: "rules.kind.comment"
        case .hide: "rules.kind.hide"
        }
    }
    public var title: String { L10n.string(localizationKey) }

    public var systemImage: String {
        switch self {
        case .mapLocal: "doc"
        case .mapLocalDirectory: "folder"
        case .mapRemote: "arrow.triangle.branch"
        case .editHeaders: "list.bullet.rectangle"
        case .breakpoint: "pause.circle"
        case .rewriteBody: "text.magnifyingglass"
        case .rewriteStatus: "number.circle"
        case .mark: "paintpalette"
        case .comment: "text.bubble"
        case .hide: "eye.slash"
        }
    }

    /// What ⌘N creates when the "+" pop-up is not used: another rule like the selected one, else the
    /// first kind the pop-up offers.
    public static func kindForNewDraft(selected: RuleKind?) -> RuleKind { selected ?? .mapLocal }

    /// Map actions choose the route, so they always run on the request.
    public var hasDirection: Bool { self == .editHeaders || self == .breakpoint || self == .rewriteBody }
}

public enum RuleSchemeChoice: String, CaseIterable, Sendable, Hashable {
    case any, http, https
}

public enum RuleTargetScheme: String, CaseIterable, Sendable, Hashable {
    case http, https
}

public enum RulePathMode: String, CaseIterable, Sendable, Hashable {
    case any, exact, prefix
}

public enum RemotePathChoice: String, CaseIterable, Sendable, Hashable {
    case preserve, replace
}

public enum HeaderOperationKind: String, CaseIterable, Sendable, Hashable {
    case set, append, remove
}

/// One row of an ordered header-operation table. `id` only keeps SwiftUI rows and field errors
/// stable; it is never persisted.
public struct HeaderOperationRow: Identifiable, Equatable, Sendable, Hashable {
    public var id: UUID
    public var kind: HeaderOperationKind
    public var name: String
    public var value: String

    public init(id: UUID = UUID(), kind: HeaderOperationKind, name: String, value: String = "") {
        self.id = id
        self.kind = kind
        self.name = name
        self.value = value
    }
}

/// One header field of a Map Local response; duplicates and their order are kept.
public struct HeaderFieldRow: Identifiable, Equatable, Sendable, Hashable {
    public var id: UUID
    public var name: String
    public var value: String

    public init(id: UUID = UUID(), name: String, value: String) {
        self.id = id
        self.name = name
        self.value = value
    }
}

/// The matcher half of the editor, as typed. Empty text means "any".
public struct RuleMatchDraft: Equatable, Sendable {
    public var scheme: RuleSchemeChoice = .any
    /// How `host` and `path` are read. `.literal` keeps today's meaning (host with `*.` support,
    /// `pathMode` plus `path`). `.wildcard` and `.regex` make `host` and `path` one pattern each
    /// (empty = any) and ignore `pathMode`.
    public var syntax: PatternSyntax = .literal {
        // Changing the syntax is the user taking over the text a mixed rule was loaded with.
        didSet {
            guard syntax != oldValue else { return }
            hasMixedSyntax = false
            // Pattern text typed under wildcard or regex must not stop applying silently: the literal
            // form needs a path mode, so text left on "any" becomes an exact path the user can see.
            if syntax == .literal, pathMode == .any, !path.isEmpty { pathMode = .exact }
        }
    }
    /// Set by loading a saved rule whose host and path use contradictory syntaxes; the draft then
    /// refuses to produce a rule until the syntax is chosen again.
    public private(set) var hasMixedSyntax = false
    public var host = ""
    public var port = ""
    /// Kept exactly as typed: methods are case-sensitive tokens (see `RuleDraftWarning.methodCase`).
    public var method = ""
    public var pathMode: RulePathMode = .any
    /// Origin-form path and query, compared byte for byte; never trimmed or decoded.
    public var path = ""
    /// Response rules only; both empty means no status constraint.
    public var statusLower = ""
    public var statusUpper = ""

    public init() {}

    mutating func markMixedSyntax() { hasMixedSyntax = true }

    /// The user's choice in the syntax control, including choosing the syntax already shown: that
    /// confirms the loaded text and clears the mixed-syntax block. Assigning `syntax` directly only
    /// clears it when the value changes.
    public mutating func chooseSyntax(_ choice: PatternSyntax) {
        syntax = choice
        hasMixedSyntax = false
    }
}

extension PatternSyntax {
    /// The caption of the control that chooses the syntax.
    public static let pickerLabelKey = "rules.match.syntax"

    public var titleKey: String {
        switch self {
        case .literal: "rules.match.syntax.literal"
        case .wildcard: "rules.match.syntax.wildcard"
        case .regex: "rules.match.syntax.regex"
        }
    }

    /// One sentence on how to write a pattern; nil for the literal syntax, which has its own help.
    public var hintKey: String? {
        switch self {
        case .literal: nil
        case .wildcard: "rules.match.hint.wildcard"
        case .regex: "rules.match.hint.regex"
        }
    }

    public func title(localizer: Localizer = L10n.localizer) -> String { localizer.string(titleKey) }

    public func hint(localizer: Localizer = L10n.localizer) -> String? { hintKey.map { localizer.string($0) } }
}

public struct MapRemoteDraft: Equatable, Sendable {
    public var targetScheme: RuleTargetScheme = .https
    public var targetHost = ""
    public var targetPort = "443"
    public var pathChoice: RemotePathChoice = .preserve
    public var replacementPath = ""
    /// Keep Authorization, Cookie, Origin and Referer when the origin changes. Off by default.
    public var preserveCredentials = false

    public init() {}

    /// The fixed part of the mapped URL: the origin, plus the path and query when they are replaced.
    /// Nil while the port is not a number.
    public var preview: String? {
        guard let port = Int(targetPort.trimmingCharacters(in: .whitespaces)) else { return nil }
        let scheme = targetScheme.rawValue
        let host = targetHost.trimmingCharacters(in: .whitespaces)
        let isDefaultPort = (scheme == "http" && port == 80) || (scheme == "https" && port == 443)
        let origin = "\(scheme)://\(host)\(isDefaultPort ? "" : ":\(port)")"
        return pathChoice == .replace ? origin + replacementPath : origin
    }
}

/// A Map Local directory rule as typed. The directory is kept as the bookmark the facade made when
/// it was chosen; the path the user picked is never stored (spec F1).
public struct MapLocalDirectoryDraft: Equatable, Sendable {
    public var bookmark: Data?
    /// Shown only; the last path component of the chosen directory.
    public var displayName = ""
    public var servesIndex = true
    public var missing: MissingFilePolicy = .notFound
    public var headers: [HeaderFieldRow] = []

    public init() {}
}

extension MissingFilePolicy {
    /// The segment caption of the missing-file policy.
    public var titleKey: String {
        switch self {
        case .notFound: "rules.mapLocalDirectory.missing.notFound"
        case .network: "rules.mapLocalDirectory.missing.network"
        }
    }
}

/// A body find-and-replace as typed. Find and replacement keep every character, whitespace included.
public struct BodyRewriteDraft: Equatable, Sendable {
    public var find = ""
    public var replacement = ""
    public var syntax: BodyFindSyntax = .text
    public var caseSensitive = true
    public var scope: BodyReplaceScope = .all

    public init() {}
}

/// A status rewrite as typed; the status is a number only after validation.
public struct RewriteStatusDraft: Equatable, Sendable {
    public var status = ""
    public var includeLocalResponses = false

    public init(status: String = "", includeLocalResponses: Bool = false) {
        self.status = status
        self.includeLocalResponses = includeLocalResponses
    }
}

public struct MapLocalDraft: Equatable, Sendable {
    /// The managed copy; the user's original path is never kept.
    public var asset: ManagedAsset?
    public var status = "200"
    public var headers: [HeaderFieldRow] = []

    public init() {}
}

/// The field an editor error belongs to.
public enum RuleDraftField: Hashable, Sendable {
    case name, scheme, host, port, method, path, statusRange
    case mapLocalAsset, mapLocalStatus, mapLocalHeader(UUID)
    case directory
    case targetScheme, targetHost, targetPort, targetPath
    case headerOperation(UUID)
    case bodyFind, bodyReplacement, rewriteStatus
    case markColor, markForeground, markText, commentText, commentFind, commentReplacement
}

/// What is wrong with one field. Messages are whole localized sentences.
public enum RuleDraftIssue: String, CaseIterable, Equatable, Sendable {
    case required, notANumber, fieldTooLong
    case invalidScheme, invalidHostPattern, invalidPort, invalidMethod, invalidPath
    case invalidWildcard, invalidRegex, regexTooComplex, mixedSyntax
    case invalidStatusRange, statusRangeNotAllowed, invalidStatus
    case invalidTargetScheme, invalidTargetHost, invalidTargetPort, invalidTargetPath
    case assetRequired
    case directoryRequired, directoryNeedsPrefix, invalidDirectory
    case headerNameInvalid, headerValueInvalid, headerProtected, headerInvalid
    case emptyFind, findTooLong
    case invalidMarkColor, markTextTooLong, commentRequired, commentFindRequired, commentTooLong
    /// Rules 2.0 R4: the new actions (URL, query and cookie edits, delay, generated responses) and connect-only rules.
    case invalidURLEdit, invalidQueryEdit, invalidCookieEdit, emptyEditFind, invalidDelay
    case invalidHandwrittenResponse, handwrittenResponseTooLarge, presetNeedsLocation, invalidPresetField
    case connectActionCondition, connectActionMixed
    /// Rules 2.0 structure (several actions, a condition this editor cannot show) that a single-action
    /// rule cannot have; only reachable when a rule from the new model reaches this editor.
    case unsupportedStructure
    /// Rules 2.0 R5: the document editor's own issues (condition rows, counts, judgment point).
    case invalidOperator, tooManyConditions, tooManyActions, noActions
    case actionNotAllowedAtResponsePoint, actionNotAllowedAtCompletionPoint
    case conditionNameRequired, unexpectedConditionName, invalidConditionName, invalidConditionValue, finalActionAtLaterPoint
    /// Rules 2.0 R8F2: a magic action string that is not one of the Classic actions.
    case invalidMagicString
    /// Rules 2.0 R8F2 T8: the magic string is the path of a local file; a rule holds managed copies, so the card offers Return File.
    case magicStringLocalFile

    public var localizationKey: String {
        switch self {
        case .required: "rules.issue.required"
        case .notANumber: "rules.issue.notANumber"
        case .fieldTooLong: "rules.issue.fieldTooLong"
        case .invalidScheme: "rules.issue.invalidScheme"
        case .invalidHostPattern: "rules.issue.invalidHostPattern"
        case .invalidPort: "rules.issue.invalidPort"
        case .invalidMethod: "rules.issue.invalidMethod"
        case .invalidPath: "rules.issue.invalidPath"
        case .invalidWildcard: "rules.issue.invalidWildcard"
        case .invalidRegex: "rules.issue.invalidRegex"
        case .regexTooComplex: "rules.issue.regexTooComplex"
        case .mixedSyntax: "rules.issue.mixedSyntax"
        case .invalidStatusRange: "rules.issue.invalidStatusRange"
        case .statusRangeNotAllowed: "rules.issue.statusRangeNotAllowed"
        case .invalidStatus: "rules.issue.invalidStatus"
        case .invalidTargetScheme: "rules.issue.invalidTargetScheme"
        case .invalidTargetHost: "rules.issue.invalidTargetHost"
        case .invalidTargetPort: "rules.issue.invalidTargetPort"
        case .invalidTargetPath: "rules.issue.invalidTargetPath"
        case .assetRequired: "rules.issue.assetRequired"
        case .directoryRequired: "rules.issue.directoryRequired"
        case .directoryNeedsPrefix: "rules.issue.directoryNeedsPrefix"
        case .invalidDirectory: "rules.issue.invalidDirectory"
        case .headerNameInvalid: "rules.issue.headerNameInvalid"
        case .headerValueInvalid: "rules.issue.headerValueInvalid"
        case .headerProtected: "rules.issue.headerProtected"
        case .headerInvalid: "rules.issue.headerInvalid"
        case .emptyFind: "rules.issue.emptyFind"
        case .findTooLong: "rules.issue.findTooLong"
        case .invalidMarkColor: "rules.issue.invalidMarkColor"
        case .markTextTooLong: "rules.issue.markTextTooLong"
        case .commentRequired: "rules.issue.commentRequired"
        case .commentFindRequired: "rules.issue.commentFindRequired"
        case .commentTooLong: "rules.issue.commentTooLong"
        case .invalidURLEdit: "rules.issue.invalidURLEdit"
        case .invalidQueryEdit: "rules.issue.invalidQueryEdit"
        case .invalidCookieEdit: "rules.issue.invalidCookieEdit"
        case .emptyEditFind: "rules.issue.emptyEditFind"
        case .invalidDelay: "rules.issue.invalidDelay"
        case .invalidHandwrittenResponse: "rules.issue.invalidHandwrittenResponse"
        case .handwrittenResponseTooLarge: "rules.issue.handwrittenResponseTooLarge"
        case .presetNeedsLocation: "rules.issue.presetNeedsLocation"
        case .invalidPresetField: "rules.issue.invalidPresetField"
        case .invalidMagicString: "rules.issue.invalidMagicString"
        case .magicStringLocalFile: "rules.issue.magicStringLocalFile"
        case .connectActionCondition: "rules.issue.connectActionCondition"
        case .connectActionMixed: "rules.issue.connectActionMixed"
        case .unsupportedStructure: "rules.issue.unsupportedStructure"
        case .invalidOperator: "rules.issue.invalidOperator"
        case .tooManyConditions: "rules.issue.tooManyConditions"
        case .tooManyActions: "rules.issue.tooManyActions"
        case .noActions: "rules.issue.noActions"
        case .actionNotAllowedAtResponsePoint: "rules.issue.actionNotAllowedAtResponsePoint"
        case .actionNotAllowedAtCompletionPoint: "rules.issue.actionNotAllowedAtCompletionPoint"
        case .conditionNameRequired: "rules.issue.conditionNameRequired"
        case .unexpectedConditionName: "rules.issue.unexpectedConditionName"
        case .invalidConditionName: "rules.issue.invalidConditionName"
        case .invalidConditionValue: "rules.issue.invalidConditionValue"
        case .finalActionAtLaterPoint: "rules.issue.finalActionAtLaterPoint"
        }
    }

    public func message(limits: RulesLimits, localizer: Localizer = L10n.localizer) -> String {
        switch self {
        case .fieldTooLong: localizer.format(localizationKey, arguments: [limits.fieldBytes])
        case .findTooLong: localizer.format(localizationKey, arguments: [BodyRewriteAction.maxFindBytes])
        case .markTextTooLong: localizer.format(localizationKey, arguments: [limits.markTextBytes])
        case .commentTooLong: localizer.format(localizationKey, arguments: [limits.commentBytes])
        case .tooManyConditions: localizer.format(localizationKey, arguments: [limits.ruleConditionRows])
        case .tooManyActions: localizer.format(localizationKey, arguments: [limits.ruleActions])
        default: localizer.string(localizationKey)
        }
    }

    init(_ error: RuleValidationError) {
        switch error.code {
        case .fieldTooLong: self = .fieldTooLong
        case .invalidScheme: self = .invalidScheme
        case .invalidHostPattern: self = .invalidHostPattern
        case .invalidPort: self = .invalidPort
        case .invalidMethod: self = .invalidMethod
        case .invalidPath: self = .invalidPath
        case .invalidWildcard: self = .invalidWildcard
        case .invalidRegex: self = .invalidRegex
        case .regexTooComplex: self = .regexTooComplex
        case .invalidStatusRange: self = .invalidStatusRange
        case .statusRangeNotAllowed: self = .statusRangeNotAllowed
        case .invalidStatus: self = .invalidStatus
        case .invalidDirectory: self = .invalidDirectory
        case .directoryNeedsPrefix: self = .directoryNeedsPrefix
        case .emptyFind: self = .emptyFind
        case .findTooLong: self = .findTooLong
        // A rule is judged at the response only through a status range, which is how the old editor
        // saw a request-side action behind one.
        case .actionNotAllowedAtJudgmentPoint: self = .statusRangeNotAllowed
        case .invalidMarkColor: self = .invalidMarkColor
        case .markTextTooLong: self = .markTextTooLong
        case .emptyComment: self = .commentRequired
        case .emptyCommentFind: self = .commentFindRequired
        case .commentTooLong: self = .commentTooLong
        case .invalidOperator, .tooManyConditions, .tooManyActions, .noActions, .tooManyRules, .groupTooDeep,
            .unknownGroup, .groupCycle, .duplicateID, .conditionNameRequired, .unexpectedConditionName,
            .invalidConditionName, .invalidConditionValue, .actionNotAllowedAtCompletion:
            // Structure errors and errors of rows on the new fields need rules this form cannot build.
            self = .unsupportedStructure
        case .invalidURLEdit: self = .invalidURLEdit
        case .invalidQueryEdit: self = .invalidQueryEdit
        case .invalidCookieEdit: self = .invalidCookieEdit
        case .emptyEditFind: self = .emptyEditFind
        case .invalidDelay: self = .invalidDelay
        case .invalidHandwrittenResponse: self = .invalidHandwrittenResponse
        case .handwrittenResponseTooLarge: self = .handwrittenResponseTooLarge
        case .presetNeedsLocation: self = .presetNeedsLocation
        case .invalidPresetField: self = .invalidPresetField
        case .invalidMagicString: self = .invalidMagicString
        case .connectActionCondition: self = .connectActionCondition
        case .connectActionMixed: self = .connectActionMixed
        case .invalidTarget:
            switch error.field {
            case .targetScheme: self = .invalidTargetScheme
            case .targetPort: self = .invalidTargetPort
            case .targetPath: self = .invalidTargetPath
            default: self = .invalidTargetHost
            }
        case .invalidHeaderEdit:
            switch error.mutation?.code {
            case .invalidHeaderName: self = .headerNameInvalid
            case .invalidHeaderValue: self = .headerValueInvalid
            case .protectedHeader, .nominatedHeader: self = .headerProtected
            default: self = .headerInvalid
            }
        }
    }
}

/// Valid but probably unintended input.
public enum RuleDraftWarning: Equatable, Sendable {
    /// A hide rule without any match field hides all traffic (and the hidden traffic cannot be found again).
    case hidesEverything
    /// Methods are case-sensitive: a lowercase `get` never matches a `GET` request.
    case methodCase(String)

    public var localizationKey: String {
        switch self {
        case .methodCase: "rules.warning.methodCase"
        case .hidesEverything: "rules.warning.hideEverything"
        }
    }

    public func message(localizer: Localizer = L10n.localizer) -> String {
        switch self {
        case .methodCase(let method): localizer.format(localizationKey, arguments: [method])
        case .hidesEverything: localizer.string(localizationKey)
        }
    }
}

public struct RuleDraftValidation: Equatable, Sendable {
    /// The rule to save; nil when any field has an issue.
    public var rule: Rule?
    public var issues: [RuleDraftField: RuleDraftIssue]
}

/// Why this editor shows a rule but cannot change it (`Rule.simple` is nil). The first that applies.
public enum RuleReadOnlyReason: Equatable, Sendable {
    /// The rule has several actions.
    case multipleActions
    /// The user ticked "final" on its action.
    case userFinalFlag
    /// It acts on a range of the matching exchanges only.
    case occurrence
    /// Its conditions have no place in the fixed fields: two rows for one field, or a row the fields cannot say.
    case unsupportedConditions
}

/// One rule as the editor holds it: a matcher half and an action half, both as typed, with every
/// action form kept so switching the kind loses nothing. `id` is the rule's persistent identity.
public struct RuleEditorDraft: Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name = ""
    public var enabled = true
    /// A directory rule serves a literal path prefix, so choosing that kind puts the matcher back on the
    /// literal syntax with a prefix path (the text typed so far stays and is validated as it is) and the
    /// fields back on "all": any other combination would serve what lies outside the prefix.
    public var kind: RuleKind {
        didSet {
            guard kind == .mapLocalDirectory, oldValue != kind else { return }
            match.chooseSyntax(.literal)
            match.pathMode = .prefix
            matchMode = .all
        }
    }
    /// For header and breakpoint rules; Map rules always run on the request.
    public var direction: HTTPMessageDirection = .request
    /// How the filled-in fields combine: all of them, any one of them, or none of them. Without a filled-in
    /// field every mode matches every request.
    public var matchMode: ConditionGroup.Mode = .all
    public var match = RuleMatchDraft()
    public var headerOperations: [HeaderOperationRow] = []
    public var mapRemote = MapRemoteDraft()
    public var mapLocal = MapLocalDraft()
    public var mapLocalDirectory = MapLocalDirectoryDraft()
    public var bodyRewrite = BodyRewriteDraft()
    public var rewriteStatus = RewriteStatusDraft()
    /// The old editor always colours the background; the new card starts unchanged.
    public var mark = MarkDraft(background: MarkPalette.presets[0].lightHex)
    /// The old editor's find and replace has always been case-sensitive.
    public var comment = CommentDraft(caseSensitive: true)
    public var breakpointMode: BreakpointPauseMode = .headers
    /// Set when a saved rule was loaded that this editor cannot state; nil for every rule it can edit.
    public private(set) var readOnlyReason: RuleReadOnlyReason?

    public init(kind: RuleKind, id: UUID = UUID()) {
        self.id = id
        self.kind = kind
        if kind == .mapLocalDirectory { match.pathMode = .prefix }
    }

    /// The editor state of a saved rule. `asset` is the managed asset a Map Local rule references. A rule this
    /// editor cannot state (`readOnlyReason`) keeps only its name and switch; its draft never produces a rule.
    public init(rule: Rule, asset: ManagedAsset?) {
        guard let form = rule.oldEditorForm else {
            self.init(kind: rule.actions.first.flatMap { RuleKind($0.kind) } ?? .breakpoint, id: rule.id)
            name = rule.name
            enabled = rule.enabled
            readOnlyReason = Self.readOnlyReason(of: rule)
            return
        }
        let simple: SimpleRule
        switch form {
        case .annotation(let annotation):
            self.init(kind: RuleKind(annotation.kind) ?? .hide, id: rule.id)
            name = rule.name
            enabled = rule.enabled
            matchMode = annotation.mode
            load(matcher: annotation.matcher)
            load(annotation: annotation.kind)
            return
        case .legacy(let legacy): simple = legacy
        }
        self.init(kind: RuleKind(simple.action), id: rule.id)
        name = rule.name
        enabled = rule.enabled
        matchMode = simple.mode
        load(matcher: simple.matcher)
        switch simple.action {
        case .mapLocal(let local):
            mapLocal.asset = asset ?? ManagedAsset(id: local.assetID, size: 0, displayName: "", importedAt: .distantPast)
            mapLocal.status = String(local.status)
            mapLocal.headers = local.headers.map { HeaderFieldRow(name: $0.name, value: $0.value) }
        case .mapRemote(let remote):
            mapRemote.targetScheme = RuleTargetScheme(rawValue: remote.targetScheme.lowercased()) ?? .https
            mapRemote.targetHost = remote.targetHost
            mapRemote.targetPort = String(remote.targetPort)
            switch remote.path {
            case .preserve: mapRemote.pathChoice = .preserve
            case .replace(let path): mapRemote.pathChoice = .replace; mapRemote.replacementPath = path
            }
            mapRemote.preserveCredentials = remote.preserveCredentials
        case .editHeaders(let direction, let operations):
            self.direction = direction
            headerOperations = operations.map { operation in
                switch operation {
                case .set(let name, let value, _): HeaderOperationRow(kind: .set, name: name, value: value)
                case .append(let name, let value, _): HeaderOperationRow(kind: .append, name: name, value: value)
                case .remove(let name, _): HeaderOperationRow(kind: .remove, name: name)
                // The old editor form is nil for rules with the R5 methods, so these are not reached.
                case .addIfMissing, .appendToValue, .findReplace, .regex:
                    HeaderOperationRow(kind: .set, name: operation.name, value: operation.value ?? "")
                }
            }
        case .breakpoint(let direction, let mode):
            self.direction = direction
            breakpointMode = mode
        case .mapLocalDirectory(let directory):
            mapLocalDirectory.bookmark = directory.bookmark
            mapLocalDirectory.displayName = directory.displayName
            mapLocalDirectory.servesIndex = directory.servesIndex
            mapLocalDirectory.missing = directory.missing
            mapLocalDirectory.headers = directory.headers.map { HeaderFieldRow(name: $0.name, value: $0.value) }
        case .rewriteBody(let direction, let rewrite):
            self.direction = direction
            bodyRewrite.find = rewrite.find
            bodyRewrite.replacement = rewrite.replacement
            bodyRewrite.syntax = rewrite.syntax
            bodyRewrite.caseSensitive = rewrite.caseSensitive
            bodyRewrite.scope = rewrite.scope
        case .rewriteStatus(let rewrite):
            rewriteStatus.status = rewrite.text
            rewriteStatus.includeLocalResponses = rewrite.includeLocalResponses
        }
    }

    /// Fills the fixed fields from a saved matcher.
    private mutating func load(matcher: RuleMatcher) {
        match.scheme = matcher.scheme.flatMap { RuleSchemeChoice(rawValue: $0.lowercased()) } ?? .any
        match.host = matcher.hostPattern ?? ""
        Self.loadSyntax(of: matcher, into: &match)
        match.port = matcher.port.map(String.init) ?? ""
        match.method = matcher.method ?? ""
        if let range = matcher.statusRange {
            match.statusLower = String(range.lowerBound)
            match.statusUpper = String(range.upperBound)
        }
    }

    /// Why the editor cannot state `rule`; nil for a rule it can.
    static func readOnlyReason(of rule: Rule) -> RuleReadOnlyReason? {
        guard rule.oldEditorForm == nil else { return nil }
        if rule.actions.count != 1 { return .multipleActions }
        if rule.actions[0].isFinal { return .userFinalFlag }
        if rule.conditions.occurrence != .any { return .occurrence }
        return .unsupportedConditions
    }

    /// Fills syntax, path mode and path text from a saved matcher (`host` is already set).
    ///
    /// The syntax is the host's when the host is not literal, else the path's. A literal host with
    /// a wildcard or regex path, or two different advanced syntaxes, cannot be shown in one control:
    /// the draft then keeps both texts and is flagged mixed. An advanced host with an exact or prefix
    /// path is shown with the path rewritten as the equivalent pattern, so saving it changes nothing.
    private static func loadSyntax(of matcher: RuleMatcher, into match: inout RuleMatchDraft) {
        let pathSyntax: PatternSyntax
        switch matcher.path {
        case .any:
            match.pathMode = .any
            match.syntax = matcher.hostSyntax
            return
        case .exact(let value), .prefix(let value):
            let isPrefix: Bool
            if case .prefix = matcher.path { isPrefix = true } else { isPrefix = false }
            match.syntax = matcher.hostSyntax
            switch matcher.hostSyntax {
            case .literal:
                match.pathMode = isPrefix ? .prefix : .exact
                match.path = value
            case .wildcard:
                match.path = escapedWildcard(value) + (isPrefix ? "*" : "")
            case .regex:
                match.path = NSRegularExpression.escapedPattern(for: value) + (isPrefix ? ".*" : "")
            }
            return
        case .wildcard(let value):
            pathSyntax = .wildcard
            match.path = value
        case .regex(let value):
            pathSyntax = .regex
            match.path = value
        }
        match.syntax = matcher.hostSyntax == .literal ? pathSyntax : matcher.hostSyntax
        let contradictory = matcher.hostSyntax == .literal ? matcher.hostPattern != nil : matcher.hostSyntax != pathSyntax
        if contradictory { match.markMixedSyntax() }
    }

    private static func escapedWildcard(_ text: String) -> String {
        var result = ""
        for scalar in text.unicodeScalars {
            if scalar == "*" || scalar == "?" || scalar == "\\" { result.unicodeScalars.append("\\") }
            result.unicodeScalars.append(scalar)
        }
        return result
    }

    /// An unsaved draft matching exactly the client's original request (T9a-GPT-R32): scheme, host,
    /// port, method and the whole origin-form path+query as captured, duplicate query items, order,
    /// case and percent spelling included. The downstream boundary is preferred; legacy flows fall
    /// back to their recorded fields. Never the effective (remapped) target.
    public static func fromFlow(_ flow: Flow, kind: RuleKind) -> RuleEditorDraft {
        let target = flow.messages[.downstreamRequest]?.target ?? HTTPMessageTarget(
            scheme: flow.scheme, host: flow.host, port: flow.port, method: flow.method, pathAndQuery: flow.path)
        var draft = RuleEditorDraft(kind: kind)
        draft.name = target.host
        draft.match.scheme = RuleSchemeChoice(rawValue: target.scheme.lowercased()) ?? .any
        draft.match.host = target.host
        draft.match.port = String(target.port)
        draft.match.method = target.method
        draft.match.pathMode = .exact
        draft.match.path = target.pathAndQuery
        if kind == .mapLocalDirectory {
            // A directory serves a prefix: the directory part of the original path, query dropped.
            let pathOnly = target.pathAndQuery.prefix { $0 != "?" }
            draft.match.pathMode = .prefix
            draft.match.path = pathOnly.lastIndex(of: "/").map { String(pathOnly[...$0]) } ?? "/"
        }
        draft.mapRemote.targetScheme = RuleTargetScheme(rawValue: target.scheme.lowercased()) ?? .https
        draft.mapRemote.targetHost = target.host
        draft.mapRemote.targetPort = String(target.port)
        // Rewriting what came back: the body rule works on the response, the status rule starts at the
        // status this flow got.
        if kind == .rewriteBody { draft.direction = .response }
        if kind == .rewriteStatus { draft.rewriteStatus.status = flow.statusCode.map(String.init) ?? "" }
        return draft
    }

    /// Valid input that likely does not do what the user means.
    public var warnings: [RuleDraftWarning] {
        let method = match.method.trimmingCharacters(in: .whitespaces)
        var warnings: [RuleDraftWarning] = method.contains(where: \.isLowercase) ? [.methodCase(method)] : []
        if hidesEverything { warnings.append(.hidesEverything) }
        return warnings
    }

    /// The direction the action runs on.
    public var effectiveDirection: HTTPMessageDirection {
        switch kind {
        case .rewriteStatus: .response
        default: kind.hasDirection ? direction : .request
        }
    }

    /// Parses every field and runs the shared RulesEngine validator per field, so all broken fields
    /// are reported at once. A rule is returned only when nothing is wrong.
    public func validate(order: Int, limits: RulesLimits) -> RuleDraftValidation {
        // A rule the form cannot show would be saved as something else.
        if readOnlyReason != nil { return RuleDraftValidation(rule: nil, issues: [.name: .unsupportedStructure]) }
        var issues: [RuleDraftField: RuleDraftIssue] = [:]
        func check(_ field: RuleDraftField, _ validate: () throws -> Void) {
            do { try validate() } catch let error as RuleValidationError {
                if issues[field] == nil { issues[field] = RuleDraftIssue(error) }
            } catch {
                if issues[field] == nil { issues[field] = .headerInvalid }
            }
        }
        func number(_ text: String, _ field: RuleDraftField, required: Bool) -> Int? {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                if required { issues[field] = .required }
                return nil
            }
            guard let value = Int(trimmed) else {
                issues[field] = .notANumber
                return nil
            }
            return value
        }
        let placeholder = LegacyRuleAction.breakpoint(direction: .request, mode: .headers)
        func probe(_ matcher: RuleMatcher = RuleMatcher(), _ action: LegacyRuleAction = placeholder, name: String = "") -> Rule {
            Rule(id: id, name: name, enabled: enabled, order: order, matcher: matcher, action: action)
        }

        check(.name) { try probe(name: name).validate(limits: limits) }

        // Matcher, field by field.
        var matcher = RuleMatcher()
        matcher.scheme = match.scheme == .any ? nil : match.scheme.rawValue
        check(.scheme) { try RuleMatcher(scheme: matcher.scheme).validate(limits: limits) }
        let host = match.host.trimmingCharacters(in: .whitespaces)
        matcher.hostPattern = host.isEmpty ? nil : host
        // An empty host has nothing to interpret, so it never writes a syntax marker.
        matcher.hostSyntax = host.isEmpty ? .literal : match.syntax
        check(.host) { try RuleMatcher(hostPattern: matcher.hostPattern, hostSyntax: matcher.hostSyntax).validate(limits: limits) }
        matcher.port = number(match.port, .port, required: false)
        check(.port) { try RuleMatcher(port: matcher.port).validate(limits: limits) }
        let method = match.method.trimmingCharacters(in: .whitespaces)
        matcher.method = method.isEmpty ? nil : method
        check(.method) { try RuleMatcher(method: matcher.method).validate(limits: limits) }
        switch match.syntax {
        case .literal:
            switch match.pathMode {
            case .any: matcher.path = .any
            case .exact: matcher.path = .exact(match.path)
            case .prefix: matcher.path = .prefix(match.path)
            }
            if match.pathMode != .any, match.path.isEmpty { issues[.path] = .required }
        case .wildcard: matcher.path = match.path.isEmpty ? .any : .wildcard(match.path)
        case .regex: matcher.path = match.path.isEmpty ? .any : .regex(match.path)
        }
        check(.path) { try RuleMatcher(path: matcher.path).validate(limits: limits) }
        if kind == .mapLocalDirectory {
            // F2: a literal prefix that starts and ends with "/". Any other syntax or mode cannot serve a directory.
            if match.syntax != .literal || match.pathMode != .prefix {
                issues[.path] = .directoryNeedsPrefix
            } else if issues[.path] == nil, !(match.path.hasPrefix("/") && match.path.hasSuffix("/")) {
                issues[.path] = .directoryNeedsPrefix
            }
        }
        let lower = match.statusLower.trimmingCharacters(in: .whitespaces)
        let upper = match.statusUpper.trimmingCharacters(in: .whitespaces)
        if !lower.isEmpty || !upper.isEmpty {
            let low = number(lower, .statusRange, required: true)
            let high = issues[.statusRange] == nil ? number(upper, .statusRange, required: true) : nil
            if let low, let high {
                if low > high {
                    issues[.statusRange] = .invalidStatusRange
                } else {
                    matcher.statusRange = low...high
                    check(.statusRange) { try RuleMatcher(statusRange: low...high).validate(limits: limits) }
                }
            }
        }

        // Action, row by row.
        var action: LegacyRuleAction?
        var annotation: ActionKind?
        switch kind {
        case .mark, .comment, .hide:
            annotation = annotationAction(limits: limits, issues: &issues)
        case .editHeaders:
            let operations = headerOperations.map { row -> HeaderEdit in
                switch row.kind {
                case .set: .set(name: row.name, value: row.value)
                case .append: .append(name: row.name, value: row.value)
                case .remove: .remove(name: row.name)
                }
            }
            for (row, operation) in zip(headerOperations, operations) {
                check(.headerOperation(row.id)) {
                    try probe(RuleMatcher(), .editHeaders(direction: direction, operations: [operation])).validate(limits: limits)
                }
            }
            action = .editHeaders(direction: direction, operations: operations)
        case .mapRemote:
            let targetHost = mapRemote.targetHost.trimmingCharacters(in: .whitespaces)
            let port = number(mapRemote.targetPort, .targetPort, required: true)
            let path: RemotePathPolicy = mapRemote.pathChoice == .preserve ? .preserve : .replace(mapRemote.replacementPath)
            let remote = MapRemoteAction(
                targetScheme: mapRemote.targetScheme.rawValue, targetHost: targetHost, targetPort: port ?? 443, path: path,
                preserveCredentials: mapRemote.preserveCredentials)
            // Each target field on its own, the others replaced by known-good values.
            var probeRemote = MapRemoteAction(targetScheme: "https", targetHost: "a.invalid", targetPort: 443, path: .preserve)
            probeRemote.targetHost = targetHost
            check(.targetHost) { try probe(RuleMatcher(), .mapRemote(probeRemote)).validate(limits: limits) }
            if let port {
                probeRemote = MapRemoteAction(targetScheme: "https", targetHost: "a.invalid", targetPort: port, path: .preserve)
                check(.targetPort) { try probe(RuleMatcher(), .mapRemote(probeRemote)).validate(limits: limits) }
            }
            probeRemote = MapRemoteAction(targetScheme: "https", targetHost: "a.invalid", targetPort: 443, path: path)
            check(.targetPath) { try probe(RuleMatcher(), .mapRemote(probeRemote)).validate(limits: limits) }
            action = .mapRemote(remote)
        case .mapLocal:
            let status = number(mapLocal.status, .mapLocalStatus, required: true)
            let headers = mapLocal.headers.map { HeaderField(name: $0.name, value: $0.value) }
            let placeholderAsset = UUID()
            if let status {
                check(.mapLocalStatus) {
                    try probe(RuleMatcher(), .mapLocal(MapLocalAction(assetID: placeholderAsset, status: status, headers: [])))
                        .validate(limits: limits)
                }
            }
            for (row, field) in zip(mapLocal.headers, headers) {
                check(.mapLocalHeader(row.id)) {
                    try probe(RuleMatcher(), .mapLocal(MapLocalAction(assetID: placeholderAsset, headers: [field]))).validate(limits: limits)
                }
            }
            if mapLocal.asset == nil { issues[.mapLocalAsset] = .assetRequired }
            if let asset = mapLocal.asset {
                action = .mapLocal(MapLocalAction(assetID: asset.id, status: status ?? 200, headers: headers))
            }
        case .mapLocalDirectory:
            let headers = mapLocalDirectory.headers.map { HeaderField(name: $0.name, value: $0.value) }
            // The bookmark and the display name on their own, then each header row.
            let probeBookmark = mapLocalDirectory.bookmark ?? Data([0])
            check(.directory) {
                try probe(
                    RuleMatcher(path: .prefix("/")),
                    .mapLocalDirectory(MapLocalDirectoryAction(bookmark: probeBookmark, displayName: mapLocalDirectory.displayName)))
                    .validate(limits: limits)
            }
            for (row, field) in zip(mapLocalDirectory.headers, headers) {
                check(.mapLocalHeader(row.id)) {
                    try probe(
                        RuleMatcher(path: .prefix("/")),
                        .mapLocalDirectory(MapLocalDirectoryAction(bookmark: probeBookmark, displayName: "", headers: [field])))
                        .validate(limits: limits)
                }
            }
            if let bookmark = mapLocalDirectory.bookmark {
                action = .mapLocalDirectory(MapLocalDirectoryAction(
                    bookmark: bookmark, displayName: mapLocalDirectory.displayName, servesIndex: mapLocalDirectory.servesIndex,
                    missing: mapLocalDirectory.missing, headers: headers))
            } else {
                issues[.directory] = .directoryRequired
            }
        case .breakpoint:
            action = .breakpoint(direction: direction, mode: breakpointMode)
        case .rewriteBody:
            let rewrite = BodyRewriteAction(
                find: bodyRewrite.find, replacement: bodyRewrite.replacement, syntax: bodyRewrite.syntax,
                caseSensitive: bodyRewrite.caseSensitive, scope: bodyRewrite.scope)
            // The find text on its own, then the replacement against a known-good find text.
            var probeRewrite = rewrite
            probeRewrite.replacement = ""
            check(.bodyFind) { try probe(RuleMatcher(), .rewriteBody(direction: direction, probeRewrite)).validate(limits: limits) }
            probeRewrite = BodyRewriteAction(find: "x", replacement: rewrite.replacement)
            check(.bodyReplacement) { try probe(RuleMatcher(), .rewriteBody(direction: direction, probeRewrite)).validate(limits: limits) }
            action = .rewriteBody(direction: direction, rewrite)
        case .rewriteStatus:
            // `404` or `404 Not Found`; anything else goes through the number check for its message.
            let parsed = RewriteStatusAction.parse(rewriteStatus.status, includeLocalResponses: rewriteStatus.includeLocalResponses)
            if let status = parsed?.status ?? number(rewriteStatus.status, .rewriteStatus, required: true) {
                let rewrite = parsed ?? RewriteStatusAction(status: status, includeLocalResponses: rewriteStatus.includeLocalResponses)
                check(.rewriteStatus) { try probe(RuleMatcher(), .rewriteStatus(rewrite)).validate(limits: limits) }
                action = .rewriteStatus(rewrite)
            }
        }
        if matcher.statusRange != nil, !kind.isAnnotation, effectiveDirection == .request, issues[.statusRange] == nil {
            issues[.statusRange] = .statusRangeNotAllowed
        }

        if match.hasMixedSyntax { issues[.path] = .mixedSyntax }

        guard issues.isEmpty else { return RuleDraftValidation(rule: nil, issues: issues) }
        // The rows come out in the fixed order of the fields, whatever order they were filled in.
        var rule: Rule
        if let annotation {
            rule = Rule(id: id, name: name, enabled: enabled, order: order, matcher: matcher, annotation: annotation)
        } else if let action {
            rule = Rule(id: id, name: name, enabled: enabled, order: order, matcher: matcher, action: action)
        } else {
            return RuleDraftValidation(rule: nil, issues: issues)
        }
        rule.conditions.mode = matchMode
        // The whole rule through the shared validator once more: nothing it rejects is ever saved.
        do {
            try rule.validate(limits: limits)
        } catch let error as RuleValidationError {
            return RuleDraftValidation(rule: nil, issues: [Self.field(for: error.field, in: self): RuleDraftIssue(error)])
        } catch {
            return RuleDraftValidation(rule: nil, issues: [.name: .headerInvalid])
        }
        return RuleDraftValidation(rule: rule, issues: [:])
    }

    private static func field(for field: RuleValidationError.Field, in draft: RuleEditorDraft) -> RuleDraftField {
        switch field {
        case .name: .name
        case .scheme: .scheme
        case .hostPattern: .host
        case .port: .port
        case .method: .method
        case .path: .path
        case .statusRange: .statusRange
        case .mapStatus: .mapLocalStatus
        case .mapHeaders:
            (draft.kind == .mapLocalDirectory ? draft.mapLocalDirectory.headers : draft.mapLocal.headers).first
                .map { .mapLocalHeader($0.id) } ?? (draft.kind == .mapLocalDirectory ? .directory : .mapLocalStatus)
        case .targetScheme: .targetScheme
        case .targetHost: .targetHost
        case .targetPort: .targetPort
        case .targetPath: .targetPath
        case .directory: .directory
        case .bodyFind: .bodyFind
        case .bodyReplacement: .bodyReplacement
        case .rewriteStatus: .rewriteStatus
        case .headerEdit(let index):
            draft.headerOperations.indices.contains(index) ? .headerOperation(draft.headerOperations[index].id) : .name
        // A single-action rule has one action, and the only way it fails at its judgment point is a
        // request-side action behind a status range.
        case .action: .statusRange
        case .markColor: .markColor
        case .markForeground: .markForeground
        case .markText: .markText
        case .commentText: draft.comment.mode == .findReplace ? .commentReplacement : .commentText
        case .commentFind: .commentFind
        case .conditions, .group, .conditionRow: .name
        }
    }
}
