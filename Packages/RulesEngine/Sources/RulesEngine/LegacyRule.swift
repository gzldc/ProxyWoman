import Foundation
import FlowStore

public enum BreakpointPauseMode: String, Sendable, Equatable, Hashable, Codable {
    /// Pause at the head; the body stays streaming and untouched.
    case headers
    /// Also collect the whole body before it can be edited.
    case fullBody
}

public enum RemotePathPolicy: Sendable, Equatable, Hashable, Codable {
    /// Keep the original path and query.
    case preserve
    /// Replace the whole origin-form path and query.
    case replace(String)
}

public struct MapRemoteAction: Sendable, Equatable, Hashable, Codable {
    public var targetScheme: String
    public var targetHost: String
    public var targetPort: Int
    public var path: RemotePathPolicy
    /// Keep Authorization, Cookie, Origin and Referer when the origin changes.
    public var preserveCredentials: Bool

    public init(
        targetScheme: String, targetHost: String, targetPort: Int, path: RemotePathPolicy,
        preserveCredentials: Bool = false
    ) {
        self.targetScheme = targetScheme
        self.targetHost = targetHost
        self.targetPort = targetPort
        self.path = path
        self.preserveCredentials = preserveCredentials
    }
}

extension MapRemoteAction {
    /// The request target this action sends `original` to: lowercase scheme and host (an IPv6 literal
    /// without its brackets), the target port, and the original or the replacement origin-form path
    /// and query. The method is kept. Validation of the result is the executor's.
    public func target(applyingTo original: HTTPMessageTarget) -> HTTPMessageTarget {
        let pathAndQuery: String
        switch path {
        case .preserve: pathAndQuery = original.pathAndQuery
        case .replace(let replacement): pathAndQuery = replacement
        }
        return HTTPMessageTarget(
            scheme: targetScheme.lowercased(), host: normalizedHost, port: targetPort, method: original.method,
            pathAndQuery: pathAndQuery)
    }

    /// Whether both actions send to one origin (scheme, host and port as `target(applyingTo:)` writes them).
    func hasSameOrigin(as other: MapRemoteAction) -> Bool {
        targetScheme.lowercased() == other.targetScheme.lowercased() && normalizedHost == other.normalizedHost
            && targetPort == other.targetPort
    }

    private var normalizedHost: String {
        var host = Substring(targetHost)
        if host.hasPrefix("["), host.hasSuffix("]") { host = host.dropFirst().dropLast() }
        return host.lowercased()
    }
}

public struct MapLocalAction: Sendable, Equatable, Hashable, Codable {
    /// A managed, immutable copy; never a user path.
    public var assetID: UUID
    public var status: Int
    public var headers: [HeaderField]

    public init(assetID: UUID, status: Int = 200, headers: [HeaderField]) {
        self.assetID = assetID
        self.status = status
        self.headers = headers
    }
}

public enum MissingFilePolicy: String, Sendable, Equatable, Hashable, Codable {
    /// Answer with a local 404.
    case notFound
    /// Let the request go to the network unchanged.
    case network
}

/// Serves a user directory live. The rule holds a bookmark, never a path.
public struct MapLocalDirectoryAction: Sendable, Equatable, Hashable, Codable {
    /// Largest accepted bookmark.
    public static let maxBookmarkBytes = 65_536

    /// The directory's bookmark data (at most `maxBookmarkBytes`), not a path.
    public var bookmark: Data
    /// Shown only; never used to locate anything.
    public var displayName: String
    public var servesIndex: Bool
    public var missing: MissingFilePolicy
    /// Extra response headers.
    public var headers: [HeaderField]

    public init(
        bookmark: Data, displayName: String, servesIndex: Bool = true, missing: MissingFilePolicy = .notFound,
        headers: [HeaderField] = []
    ) {
        self.bookmark = bookmark
        self.displayName = displayName
        self.servesIndex = servesIndex
        self.missing = missing
        self.headers = headers
    }
}

/// The action of the pre-2.0 rule model (`LegacyRule`): one per rule. It remains the form old files are decoded
/// in, the form the single-action compatibility constructor and the old editor's `SimpleRule` use, and what the
/// frozen oracle evaluator reads.
public enum LegacyRuleAction: Sendable, Equatable, Hashable, Codable {
    case mapLocal(MapLocalAction)
    case mapLocalDirectory(MapLocalDirectoryAction)
    case mapRemote(MapRemoteAction)
    case editHeaders(direction: HTTPMessageDirection, operations: [HeaderEdit])
    case breakpoint(direction: HTTPMessageDirection, mode: BreakpointPauseMode)
    case rewriteBody(direction: HTTPMessageDirection, BodyRewriteAction)
    case rewriteStatus(RewriteStatusAction)

    /// Which message the action runs on. Map actions choose the route, so they run on requests;
    /// a status rewrite only exists on responses.
    public var direction: HTTPMessageDirection {
        switch self {
        case .mapLocal, .mapLocalDirectory, .mapRemote: .request
        case .rewriteStatus: .response
        case .editHeaders(let direction, _), .breakpoint(let direction, _), .rewriteBody(let direction, _): direction
        }
    }
}

/// A rule of the pre-2.0 model: one matcher, one action. Schema 1…3 files stored this form; it is only used to
/// decode and migrate them (`Rule(migrating:)`), for the upgrade analysis (`MigrationAnalyzer`) and by the oracle.
public struct LegacyRule: Sendable, Equatable, Hashable, Codable, Identifiable {
    public var id: UUID
    public var name: String
    public var enabled: Bool
    /// Evaluation order; equal values keep their position in the stored array.
    public var order: Int
    public var matcher: RuleMatcher
    public var action: LegacyRuleAction

    public init(id: UUID, name: String, enabled: Bool, order: Int, matcher: RuleMatcher, action: LegacyRuleAction) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.order = order
        self.matcher = matcher
        self.action = action
    }
}

/// The rule list of a schema 1…3 `rules.json`. Nothing publishes or writes this form any more: stored files
/// are decoded and migrated by `RuleStorage`, and the frozen oracle evaluator in the tests still reads it.
public struct LegacyRuleSnapshot: Sendable, Equatable, Codable {
    public var schemaVersion: Int
    public var revision: UInt64
    public var rules: [LegacyRule]

    public init(schemaVersion: Int = 1, revision: UInt64, rules: [LegacyRule]) {
        self.schemaVersion = schemaVersion
        self.revision = revision
        self.rules = rules
    }

    /// Enabled rules in evaluation order (stable for equal `order`). The frozen oracle evaluator reads it.
    var orderedEnabledRules: [LegacyRule] {
        rules.enumerated()
            .filter { $0.element.enabled }
            .sorted { ($0.element.order, $0.offset) < ($1.element.order, $1.offset) }
            .map(\.element)
    }
}

/// A typed rule-configuration failure. `field` identifies what the editor should highlight.
public struct RuleValidationError: Error, Equatable, Sendable {
    public enum Code: String, Sendable, Equatable {
        case fieldTooLong, invalidScheme, invalidHostPattern, invalidPort, invalidMethod, invalidPath
        case invalidStatusRange, statusRangeNotAllowed, invalidStatus, invalidTarget, invalidHeaderEdit
        case invalidWildcard, invalidRegex, regexTooComplex
        case invalidDirectory, directoryNeedsPrefix
        case emptyFind, findTooLong
        /// Rules 2.0: a condition row whose field, comparison and case option do not go together.
        case invalidOperator
        case tooManyConditions, tooManyActions, noActions
        /// A request-side action in a rule that is only judged once the response is known.
        case actionNotAllowedAtJudgmentPoint
        case tooManyRules, groupTooDeep, unknownGroup, groupCycle
        /// Two rules, or two groups, with the same id.
        case duplicateID
        /// Rule marks and comments.
        case invalidMarkColor, markTextTooLong, emptyComment, emptyCommentFind, commentTooLong
        /// Rules 2.0 R3: condition rows on the new fields.
        case conditionNameRequired, unexpectedConditionName, invalidConditionName, invalidConditionValue
        /// A rule judged after the exchange finished carries an action that needs an earlier point.
        case actionNotAllowedAtCompletion
        /// Rules 2.0 R4: the new actions (URL, query and cookie edits, delay, generated responses).
        case invalidURLEdit, invalidQueryEdit, invalidCookieEdit, emptyEditFind, invalidDelay
        case invalidHandwrittenResponse, handwrittenResponseTooLarge, presetNeedsLocation, invalidPresetField, invalidMagicString
        /// A connect-only action (no decrypt, CONNECT tunnel) in a rule that is not judged at the CONNECT line
        /// or that carries actions which cannot run there.
        case connectActionCondition, connectActionMixed
    }

    public enum Field: Sendable, Equatable {
        case name, scheme, hostPattern, port, method, path, statusRange
        case mapStatus, mapHeaders, directory, targetScheme, targetHost, targetPort, targetPath
        case bodyFind, bodyReplacement, rewriteStatus
        case headerEdit(index: Int)
        /// The action at this position in a rule's list (the first one over the limit, or the first
        /// that cannot run at the rule's judgment point).
        case action(index: Int)
        /// The condition rows as a whole.
        case conditions
        /// The group tree and the rule list it holds.
        case group
        case markColor, markForeground, markText, commentText, commentFind
        /// The condition row at this position (rows on the new fields report here).
        case conditionRow(index: Int)
    }

    public var code: Code
    public var field: Field
    /// The shared edit validator's verdict when `code == .invalidHeaderEdit`.
    public var mutation: HTTPMutationError?

    public init(code: Code, field: Field, mutation: HTTPMutationError? = nil) {
        self.code = code
        self.field = field
        self.mutation = mutation
    }
}

extension LegacyRule {
    /// Validates what a saved rule may contain. Execution validates header content again.
    public func validate(limits: RulesLimits = RulesLimits()) throws {
        try Self.check(name, limits, .name)
        try matcher.validate(limits: limits)
        switch action {
        case .mapLocal(let local):
            guard (200...599).contains(local.status) else {
                throw RuleValidationError(code: .invalidStatus, field: .mapStatus)
            }
            try Self.validateResponseHeaders(local.headers, limits)
        case .mapLocalDirectory(let directory):
            guard !directory.bookmark.isEmpty, directory.bookmark.count <= MapLocalDirectoryAction.maxBookmarkBytes else {
                throw RuleValidationError(code: .invalidDirectory, field: .directory)
            }
            try Self.check(directory.displayName, limits, .directory)
            try Self.validateResponseHeaders(directory.headers, limits)
            guard case .prefix(let prefix) = matcher.path, prefix.hasPrefix("/"), prefix.hasSuffix("/") else {
                throw RuleValidationError(code: .directoryNeedsPrefix, field: .path)
            }
        case .mapRemote(let remote):
            try Self.validate(remote, limits: limits)
        case .editHeaders(_, let operations):
            for (index, operation) in operations.enumerated() {
                try Self.check(operation.name, limits, .headerEdit(index: index))
                if let value = operation.value { try Self.check(value, limits, .headerEdit(index: index)) }
                do {
                    try HTTPMutationValidator.validateEdits([operation], originalHeaders: [])
                } catch let error as HTTPMutationError {
                    throw RuleValidationError(code: .invalidHeaderEdit, field: .headerEdit(index: index), mutation: error)
                }
            }
        case .breakpoint:
            break
        case .rewriteBody(_, let rewrite):
            try Self.validate(rewrite, limits: limits)
        case .rewriteStatus(let rewrite):
            guard (200...599).contains(rewrite.status) else {
                throw RuleValidationError(code: .invalidStatus, field: .rewriteStatus)
            }
            if let reason = rewrite.reason,
                reason.count + 4 > RewriteStatusAction.maxTextCharacters || !HTTPMutationValidator.isValidValue(reason)
            {
                throw RuleValidationError(code: .invalidStatus, field: .rewriteStatus)
            }
        }
        if matcher.statusRange != nil, action.direction == .request {
            throw RuleValidationError(code: .statusRangeNotAllowed, field: .statusRange)
        }
    }

    /// Compiles the find text once to check it, outside the shared cache (validation has no side
    /// effects; `preparePatterns` fills the cache when the rule is published).
    private static func validate(_ rewrite: BodyRewriteAction, limits: RulesLimits) throws {
        // Setting or clearing the body looks nothing up: no find text is needed or checked.
        guard rewrite.operation == .findReplace else {
            if rewrite.operation == .setValue { try check(rewrite.replacement, limits, .bodyReplacement) }
            return
        }
        guard !rewrite.find.isEmpty else { throw RuleValidationError(code: .emptyFind, field: .bodyFind) }
        guard rewrite.find.utf8.count <= BodyRewriteAction.maxFindBytes else {
            throw RuleValidationError(code: .findTooLong, field: .bodyFind)
        }
        try check(rewrite.replacement, limits, .bodyReplacement)
        do {
            _ = try BodySearchPattern(
                find: rewrite.find, syntax: rewrite.syntax, caseSensitive: rewrite.caseSensitive,
                budget: .standard, breaker: RegexBreaker())
        } catch PatternError.regexTooComplex {
            throw RuleValidationError(code: .regexTooComplex, field: .bodyFind)
        } catch PatternError.tooLong {
            throw RuleValidationError(code: .findTooLong, field: .bodyFind)
        } catch PatternError.empty {
            throw RuleValidationError(code: .emptyFind, field: .bodyFind)
        } catch {
            throw RuleValidationError(code: .invalidRegex, field: .bodyFind)
        }
    }

    private static func validateResponseHeaders(_ headers: [HeaderField], _ limits: RulesLimits) throws {
        for field in headers {
            try check(field.name, limits, .mapHeaders)
            try check(field.value, limits, .mapHeaders)
        }
        do {
            try HTTPMutationValidator.validateEdits(
                headers.map { .append(name: $0.name, value: $0.value) }, originalHeaders: [])
        } catch let error as HTTPMutationError {
            throw RuleValidationError(code: .invalidHeaderEdit, field: .mapHeaders, mutation: error)
        }
    }

    private static func validate(_ remote: MapRemoteAction, limits: RulesLimits) throws {
        guard ["http", "https"].contains(remote.targetScheme.lowercased()) else {
            throw RuleValidationError(code: .invalidTarget, field: .targetScheme)
        }
        try check(remote.targetHost, limits, .targetHost)
        guard HTTPMutationValidator.hostError(remote.targetHost) == nil else {
            throw RuleValidationError(code: .invalidTarget, field: .targetHost)
        }
        guard (1...65_535).contains(remote.targetPort) else {
            throw RuleValidationError(code: .invalidTarget, field: .targetPort)
        }
        if case .replace(let path) = remote.path {
            try check(path, limits, .targetPath)
            guard path.hasPrefix("/"), HTTPMutationValidator.pathError(path, method: "GET") == nil else {
                throw RuleValidationError(code: .invalidTarget, field: .targetPath)
            }
        }
    }

    static func check(_ text: String, _ limits: RulesLimits, _ field: RuleValidationError.Field) throws {
        guard text.utf8.count <= limits.fieldBytes else {
            throw RuleValidationError(code: .fieldTooLong, field: field)
        }
    }
}
