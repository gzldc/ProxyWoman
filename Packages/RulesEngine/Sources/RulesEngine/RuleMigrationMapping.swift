import Foundation

// How a rule of the old model (one matcher, one action) becomes a rule of the 2.0 model, and how the
// old editor reads such a rule back. Spec 5.6.2.

extension RuleMatcher {
    /// The matcher as condition rows, in the fixed order scheme, host, port, method, path, status;
    /// only the fields the matcher has. Host and path keep the old comparison, so a row evaluates
    /// exactly as the matcher did (`ConditionRow.legacyMatcher` reads the row back).
    fileprivate var migratedRows: [ConditionRow] {
        var rows: [ConditionRow] = []
        if let scheme {
            rows.append(ConditionRow(field: .scheme, op: .equals, value: scheme, caseSensitive: false))
        }
        if let hostPattern {
            let op: ConditionOperator =
                switch hostSyntax {
                case .literal: .hostPattern
                case .wildcard: .wildcard
                case .regex: .regexWhole
                }
            rows.append(ConditionRow(field: .host, op: op, value: hostPattern, caseSensitive: false))
        }
        if let port {
            rows.append(ConditionRow(field: .port, op: .equals, value: String(port), caseSensitive: false))
        }
        if let method {
            rows.append(ConditionRow(field: .method, op: .equals, value: method, caseSensitive: true))
        }
        switch path {
        case .any: break
        case .exact(let value):
            rows.append(ConditionRow(field: .pathAndQuery, op: .equals, value: value, caseSensitive: true))
        case .prefix(let value):
            rows.append(ConditionRow(field: .pathAndQuery, op: .startsWith, value: value, caseSensitive: true))
        case .wildcard(let value):
            rows.append(ConditionRow(field: .pathAndQuery, op: .wildcard, value: value, caseSensitive: true))
        case .regex(let value):
            rows.append(ConditionRow(field: .pathAndQuery, op: .regexWhole, value: value, caseSensitive: true))
        }
        if let statusRange {
            rows.append(
                ConditionRow(
                    field: .statusCode, op: .inRange, value: "\(statusRange.lowerBound)-\(statusRange.upperBound)",
                    caseSensitive: false))
        }
        return rows
    }
}

extension ActionKind {
    /// The 2.0 action for an old one. A directory action takes its served prefix from the old
    /// matcher's path, the only place the old model kept it. A path that is not a prefix (such a rule
    /// never passed validation) leaves the prefix empty, which validation refuses the same way.
    fileprivate init(migrating action: LegacyRuleAction, matcher: RuleMatcher) {
        switch action {
        case .mapLocal(let file):
            self = .returnFile(file)
        case .mapLocalDirectory(let directory):
            if case .prefix(let prefix) = matcher.path {
                self = .returnDirectory(directory, pathPrefix: prefix)
            } else {
                self = .returnDirectory(directory, pathPrefix: "")
            }
        case .mapRemote(let remote):
            self = .mapRemote(remote)
        case .editHeaders(let direction, let operations):
            self = .editHeaders(direction: direction, operations: operations)
        case .breakpoint(let direction, let mode):
            self = .breakpoint(direction: direction, mode: mode)
        case .rewriteBody(let direction, let rewrite):
            self = .rewriteBody(direction: direction, rewrite)
        case .rewriteStatus(let rewrite):
            self = .rewriteStatus(rewrite)
        }
    }

    /// The old action this one came from (the prefix of a directory action lives in the matcher there).
    fileprivate var legacyAction: LegacyRuleAction? {
        switch self {
        case .returnFile(let file): .mapLocal(file)
        case .returnDirectory(let directory, _): .mapLocalDirectory(directory)
        case .mapRemote(let remote): .mapRemote(remote)
        case .editHeaders(let direction, let operations):
            // The old editor knows only the three old methods.
            operations.allSatisfy(\.isLegacyMethod) ? .editHeaders(direction: direction, operations: operations) : nil
        case .breakpoint(let direction, let mode): .breakpoint(direction: direction, mode: mode)
        case .rewriteBody(let direction, let rewrite):
            rewrite.operation == .findReplace ? .rewriteBody(direction: direction, rewrite) : nil
        case .rewriteStatus(let rewrite): .rewriteStatus(rewrite)
        case .mark, .comment, .hide, .modifyURL, .modifyQuery, .editCookies, .delay, .returnHandwritten,
            .returnPreset, .closeConnection, .returnConnectTunnel, .noDecrypt, .magicString: nil
        }
    }
}

extension ConditionGroup {
    /// The rows merged into one old matcher, or nil when they do not fit one: at most one row per
    /// fixed field, every row readable as an old single-field matcher, no all-sessions row (it is not a
    /// fixed field, and dropping it would change what an any / none group matches). Row order and the
    /// case flag of port and status rows (which has no meaning) are not kept.
    fileprivate var fixedFieldMatcher: RuleMatcher? {
        var merged = RuleMatcher()
        var seen = Set<ConditionField>()
        for row in rows {
            guard seen.insert(row.field).inserted, let single = row.legacyMatcher else { return nil }
            switch row.field {
            case .allSessions: return nil
            case .scheme: merged.scheme = single.scheme
            case .host:
                merged.hostPattern = single.hostPattern
                merged.hostSyntax = single.hostSyntax
            case .port: merged.port = single.port
            case .method: merged.method = single.method
            case .pathAndQuery: merged.path = single.path
            case .statusCode: merged.statusRange = single.statusRange
            default: return nil
            }
        }
        return merged
    }
}

/// What the old editor can show and change: the six fixed fields as one old matcher, one old action,
/// and how the rows combine.
public struct SimpleRule: Sendable, Equatable {
    /// The editor's set of fixed fields. When `mode` is `any` or `none` it is not an AND that can be
    /// evaluated: evaluation always goes through the rule's conditions.
    public var matcher: RuleMatcher
    public var action: LegacyRuleAction
    public var mode: ConditionGroup.Mode

    public init(matcher: RuleMatcher, action: LegacyRuleAction, mode: ConditionGroup.Mode) {
        self.matcher = matcher
        self.action = action
        self.mode = mode
    }
}

extension Rule {
    /// Spec 5.6.2: one old rule becomes one rule with a single action, rows combined by `all`. Id, name,
    /// enabled flag and order stay as they were; the rule sits at the root and has no note.
    public init(migrating legacy: LegacyRule) {
        self.init(
            id: legacy.id, name: legacy.name, enabled: legacy.enabled, groupID: nil, order: legacy.order,
            conditions: ConditionGroup(mode: .all, occurrence: .any, rows: legacy.matcher.migratedRows),
            actions: [
                RuleAction(ActionKind(migrating: legacy.action, matcher: legacy.matcher), isFinal: false)
            ],
            note: nil)
    }

    /// For the old editor, MCP and test fixtures: the same as migrating an old rule with these values.
    public init(id: UUID, name: String, enabled: Bool, order: Int, matcher: RuleMatcher, action: LegacyRuleAction) {
        self.init(migrating: LegacyRule(id: id, name: name, enabled: enabled, order: order, matcher: matcher, action: action))
    }

    /// The rule as the old editor shows it, or nil when it cannot say what the rule does: several
    /// actions, an action the user ticked as final, an occurrence range, two rows for one fixed field,
    /// a row with no old matcher, or a directory whose prefix is not the path row.
    public var simple: SimpleRule? {
        guard actions.count == 1, let only = actions.first, !only.isFinal, conditions.occurrence == .any,
            let matcher = conditions.fixedFieldMatcher
        else { return nil }
        if case .returnDirectory(_, let pathPrefix) = only.kind, matcher.path != .prefix(pathPrefix) { return nil }
        guard let action = only.kind.legacyAction else { return nil }
        return SimpleRule(matcher: matcher, action: action, mode: conditions.mode)
    }

    /// The old matcher init for a rule that only marks, comments or hides: the rows are the ones
    /// migration builds.
    public init(id: UUID, name: String, enabled: Bool, order: Int, matcher: RuleMatcher, annotation: ActionKind) {
        precondition(annotation.isAnnotation, "annotation must be a mark, comment or hide action")
        self.init(
            id: id, name: name, enabled: enabled, groupID: nil, order: order,
            conditions: ConditionGroup(mode: .all, occurrence: .any, rows: matcher.migratedRows),
            actions: [RuleAction(annotation, isFinal: false)], note: nil)
    }

    /// One mark, comment or hide action, not ticked final, no occurrence range and at most one row
    /// per fixed field; nil for any other rule.
    public var simpleAnnotation: SimpleAnnotationRule? {
        guard actions.count == 1, let only = actions.first, only.kind.isAnnotation, !only.isFinal,
            conditions.occurrence == .any, let matcher = conditions.fixedFieldMatcher
        else { return nil }
        return SimpleAnnotationRule(matcher: matcher, kind: only.kind, mode: conditions.mode)
    }

    /// What the old editor shows this rule as, or nil when it cannot.
    public var oldEditorForm: OldEditorForm? {
        simple.map(OldEditorForm.legacy) ?? simpleAnnotation.map(OldEditorForm.annotation)
    }
}
