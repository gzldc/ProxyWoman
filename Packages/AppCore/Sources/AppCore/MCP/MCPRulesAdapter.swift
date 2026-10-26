import FlowStore
import Foundation
import MCPKit
import MCPWire
import RulesEngine

/// The MCP tools' window onto the rules: a thin translation between the AI-facing rule description
/// (`MCPRuleSpec`) and the editor's own types (spec D11, D12).
///
/// Nothing is validated here. The spec becomes a `RuleEditorDraft`, and the editor's `commitExternal` runs the
/// Rules window's own `RuleEditorDraft.validate` before anything is saved; its issues come back as machine codes
/// (`MCPRuleIssue`) with the draft field written as the tool's own member path. The only checks made here are the
/// ones the draft's types force: a word that names no case of the editor's enums (for example a direction of
/// "sideways") is reported as `invalid_value` instead of being replaced by a default.
///
/// Several actions (`actions`): every element becomes a draft of its own, sharing the one match, validated like a
/// single-action rule, and contributes its action; the actions are joined into one rule, checked once more as a
/// whole and saved through `commitExternal(rule:)`. An element never carries a final flag. A rule with several
/// actions, or with conditions the fixed fields cannot state, is listed as `multiple` and can only be renamed,
/// enabled or disabled from here: its match and actions are never patched, so nothing it holds can be dropped.
///
/// Paths (decision): under the default literal syntax a given `match.path` is an exact match, which is what the
/// Rules window gives a path typed into a literal matcher; a prefix is written as a wildcard (`/api/*`). When a
/// rule the user made with a literal prefix path is patched, a new `path` keeps that prefix mode.
@MainActor public final class MCPRulesAdapter: MCPRulesAccess {
    private let editor: RulesEditorModel
    private let globalSwitchOn: @MainActor () -> Bool

    public init(editor: RulesEditorModel, globalSwitchOn: @escaping @MainActor () -> Bool) {
        self.editor = editor
        self.globalSwitchOn = globalSwitchOn
    }

    // MARK: MCPRulesAccess

    public func list(includeDisabled: Bool) async -> MCPRuleListing {
        await editor.loadIfNeeded()
        let rules = editor.rules.enumerated().filter { includeDisabled || $0.element.enabled }.map {
            Self.summary(of: $0.element, order: $0.offset)
        }
        return MCPRuleListing(revision: editor.revision, globalSwitchOn: globalSwitchOn(), rules: rules)
    }

    public func create(_ spec: MCPRuleSpec, enable: Bool) async -> MCPRuleWriteOutcome {
        await editor.loadIfNeeded()
        if spec.conditions != nil, spec.match != nil { return .invalid([MCPRuleIssue(field: "conditions", issue: "conflicts_with_match")]) }
        if let elements = spec.actions ?? Self.newTypeAction(spec.action) {
            guard spec.actions == nil || spec.action == nil else {
                return .invalid([MCPRuleIssue(field: "actions", issue: "conflicts_with_action")])
            }
            var base = RuleEditorDraft(kind: .mapRemote)
            base.name = spec.name ?? ""
            base.enabled = enable
            var issues = Issues()
            Self.apply(match: spec.match ?? [:], to: &base, issues: &issues)
            let group = spec.conditions.flatMap {
                Self.group(of: $0, occurrence: .any, defaultMode: .all, limits: editor.limits, issues: &issues)
            }
            return await commit(
                elements, base: base, isNew: true, allowEnabledRule: false, parseIssues: issues, conditions: group,
                single: spec.actions == nil)
        }
        guard let actionMembers = spec.action, let kind = Self.kind(of: actionMembers) else {
            return .invalid([MCPRuleIssue(field: "action.type", issue: "unsupported_type")])
        }
        var draft = RuleEditorDraft(kind: kind)
        draft.name = spec.name ?? ""
        draft.enabled = enable
        var issues = Issues()
        Self.apply(match: spec.match ?? [:], to: &draft, issues: &issues)
        Self.apply(action: actionMembers, to: &draft, isNew: true, issues: &issues)
        if let conditions = spec.conditions {
            return await commit(
                draft, conditions: conditions, occurrence: .any, defaultMode: .all, isNew: true, allowEnabledRule: false,
                parseIssues: issues)
        }
        return await commit(draft, isNew: true, allowEnabledRule: false, parseIssues: issues)
    }

    public func update(id: UUID, _ spec: MCPRuleSpec, enable: Bool?, allowEnabledRule: Bool) async -> MCPRuleWriteOutcome {
        await editor.loadIfNeeded()
        guard let rule = editor.rules.first(where: { $0.id == id }) else { return .notFound }
        if spec.action != nil, spec.actions != nil {
            return .invalid([MCPRuleIssue(field: "actions", issue: "conflicts_with_action")])
        }
        if spec.conditions != nil, spec.match != nil { return .invalid([MCPRuleIssue(field: "conditions", issue: "conflicts_with_match")]) }
        // A rule the Rules window cannot edit (several actions, new conditions) keeps all it holds: only its name
        // and switch change from here.
        guard let existing = RuleKind(rule) else {
            return await updateWhole(rule, spec, enable: enable, allowEnabledRule: allowEnabledRule)
        }
        // Rules that need a file or a directory cannot be edited here (the asset or bookmark would have to be
        // rebuilt), and a breakpoint rule never turns into another type or gets a list of actions; the rest of such
        // a rule stays editable only in the Rules window. A breakpoint rule can still be renamed or re-matched.
        if existing == .mapLocal || existing == .mapLocalDirectory
            || (existing == .breakpoint && (spec.action != nil || spec.actions != nil))
        {
            return .invalid([MCPRuleIssue(field: "action", issue: "unsupported_type")])
        }
        // A hide rule is owned by the user: MCP may rename or switch it, never re-match or re-action it.
        if existing == .hide, spec.match != nil || spec.conditions != nil || spec.action != nil || spec.actions != nil {
            let field = spec.match != nil ? "match" : spec.conditions != nil ? "conditions" : "action"
            return .invalid([MCPRuleIssue(field: field, issue: "unsupported_type")])
        }
        var draft = RuleEditorDraft(rule: rule, asset: nil)
        var issues = Issues()
        if let name = spec.name { draft.name = name }
        if let match = spec.match { Self.apply(match: match, to: &draft, issues: &issues) }
        if let elements = spec.actions ?? Self.newTypeAction(spec.action) {
            // The list replaces the actions; the match (patched above), the mode and the name are the draft's.
            if let enable { draft.enabled = enable }
            let group = spec.conditions.flatMap {
                Self.group(
                    of: $0, occurrence: rule.conditions.occurrence, defaultMode: rule.conditions.mode, limits: editor.limits,
                    issues: &issues)
            }
            return await commit(
                elements, base: draft, isNew: false, allowEnabledRule: allowEnabledRule, parseIssues: issues, conditions: group,
                single: spec.actions == nil)
        }
        if let members = spec.action {
            if let kind = Self.kind(of: members) {
                draft.kind = kind
                // A different type starts from that type's own defaults, like a new rule.
                Self.apply(action: members, to: &draft, isNew: kind != existing, issues: &issues)
            } else {
                issues.add("action.type", "unsupported_type")
            }
        }
        if let enable { draft.enabled = enable }
        if let conditions = spec.conditions {
            return await commit(
                draft, conditions: conditions, occurrence: rule.conditions.occurrence, defaultMode: rule.conditions.mode,
                isNew: false, allowEnabledRule: allowEnabledRule, parseIssues: issues)
        }
        return await commit(draft, isNew: false, allowEnabledRule: allowEnabledRule, parseIssues: issues)
    }

    public func setEnabled(id: UUID, _ enabled: Bool) async -> MCPRuleWriteOutcome {
        await editor.loadIfNeeded()
        return Self.map(await editor.setEnabledExternal(id: id, enabled: enabled), draft: nil)
    }

    // MARK: writing

    private func commit(
        _ draft: RuleEditorDraft, isNew: Bool, allowEnabledRule: Bool, parseIssues: Issues
    ) async -> MCPRuleWriteOutcome {
        guard parseIssues.isEmpty else {
            // The words that did not parse, together with everything the editor's validation finds in the rest.
            let found = draft.validate(order: 0, limits: editor.limits).issues
            return .invalid(Self.sorted(parseIssues.items + Self.issues(found, in: draft)))
        }
        return Self.map(await editor.commitExternal(draft: draft, isNew: isNew, allowEnabledRule: allowEnabledRule), draft: draft)
    }

    /// A single-action draft under condition rows: the draft gives the name, switch and action, the rows replace its
    /// match. Everything is checked here, with the problems named in the tool's own member paths, before the rule
    /// goes to the editor.
    private func commit(
        _ draft: RuleEditorDraft, conditions: MCPConditionsSpec, occurrence: Occurrence, defaultMode: ConditionGroup.Mode,
        isNew: Bool, allowEnabledRule: Bool, parseIssues: Issues
    ) async -> MCPRuleWriteOutcome {
        var issues = parseIssues
        let group = Self.group(
            of: conditions, occurrence: occurrence, defaultMode: defaultMode, limits: editor.limits, issues: &issues)
        let validation = draft.validate(order: 0, limits: editor.limits)
        issues.items += Self.issues(validation.issues, in: draft)
        guard issues.isEmpty, var rule = validation.rule, let group else { return .invalid(Self.sorted(issues.items)) }
        rule.conditions = group
        do {
            try rule.validate(limits: editor.limits)
        } catch let error as RuleValidationError {
            return .invalid(Self.issues(of: error, singleAction: true))
        } catch {
            return .invalid([MCPRuleIssue(field: "action", issue: "unknown")])
        }
        return Self.map(await editor.commitExternal(rule: rule, isNew: isNew, allowEnabledRule: allowEnabledRule), draft: nil)
    }

    /// The rows as a condition group, or nil with the problems added to `issues` (each at its row and member). A
    /// field or comparison that is not one of the app's, and an old-style comparison, are `invalid_value`; the rest
    /// is the engine's own row validation, run on each row alone so that every bad row is reported.
    private static func group(
        of spec: MCPConditionsSpec, occurrence: Occurrence, defaultMode: ConditionGroup.Mode, limits: RulesLimits,
        issues: inout Issues
    ) -> ConditionGroup? {
        let before = issues.items.count
        var mode = defaultMode
        if let word = spec.mode {
            if let parsed = ConditionGroup.Mode(rawValue: word) {
                mode = parsed
            } else {
                issues.add("conditions.mode", "invalid_value")
            }
        }
        guard spec.rows.count <= limits.ruleConditionRows else {
            issues.add("conditions.rows", "tooManyConditions")
            return nil
        }
        var rows: [ConditionRow] = []
        for (index, row) in spec.rows.enumerated() {
            let path = "conditions.rows[\(index)]"
            let field = ConditionField(rawValue: row.field)
            let op = ConditionOperator(rawValue: row.op).flatMap { $0.isLegacyOnly ? nil : $0 }
            if field == nil { issues.add("\(path).field", "invalid_value") }
            if op == nil { issues.add("\(path).op", "invalid_value") }
            guard let field, let op else { continue }
            let built = ConditionRow(
                field: field, name: (row.name?.isEmpty ?? true) ? nil : row.name, op: op, value: row.value,
                caseSensitive: row.caseSensitive)
            rows.append(built)
            // The row alone, under an action that fits every judgment point.
            let probe = Rule(
                id: UUID(), name: "probe", enabled: false, order: 0, conditions: ConditionGroup(rows: [built]),
                actions: [RuleAction(.mark(MarkAction(background: "#FF0000")))])
            do {
                try probe.validate(limits: limits)
            } catch let error as RuleValidationError {
                issues.add("\(path).\(member(of: error.code))", error.code.rawValue)
            } catch {
                issues.add("\(path).value", "unknown")
            }
        }
        guard issues.items.count == before else { return nil }
        return ConditionGroup(mode: mode, occurrence: occurrence, rows: rows)
    }

    /// Which member of a row a validation problem is about.
    private static func member(of code: RuleValidationError.Code) -> String {
        switch code {
        case .conditionNameRequired, .unexpectedConditionName, .invalidConditionName: "name"
        case .invalidOperator: "op"
        default: "value"
        }
    }

    /// The rule `elements` make under `base` (its name, switch, combination and match), saved as a new rule or in
    /// place of the one with `base.id`.
    private func commit(
        _ elements: [[String: JSONValue]], base: RuleEditorDraft, isNew: Bool, allowEnabledRule: Bool, parseIssues: Issues,
        conditions: ConditionGroup? = nil, single: Bool = false
    ) async -> MCPRuleWriteOutcome {
        switch compose(elements, base: base, parseIssues: parseIssues, conditions: conditions, single: single) {
        case .issues(let issues): return .invalid(issues)
        case .rule(let rule):
            return Self.map(
                await editor.commitExternal(rule: rule, isNew: isNew, allowEnabledRule: allowEnabledRule), draft: nil)
        }
    }

    private enum Composed {
        case rule(Rule)
        case issues([MCPRuleIssue])
    }

    /// One draft per element, all with `base`'s match, each validated like a single-action rule and giving its
    /// action; the rule they make is checked as a whole. The shared match and name are reported once, an element's
    /// own problems under `actions[i]`.
    private func compose(
        _ elements: [[String: JSONValue]], base: RuleEditorDraft, parseIssues: Issues, conditions override: ConditionGroup? = nil,
        single: Bool = false
    ) -> Composed {
        let limits = editor.limits
        guard !elements.isEmpty else { return .issues([MCPRuleIssue(field: "actions", issue: "no_actions")]) }
        guard elements.count <= limits.ruleActions else {
            return .issues([MCPRuleIssue(field: "actions", issue: "too_many_actions")])
        }
        var issues = parseIssues.items
        var actions: [RuleAction] = []
        var conditions: ConditionGroup?
        for (index, element) in elements.enumerated() {
            let prefix = single ? "action" : "actions[\(index)]"
            if let type = Self.newType(of: element) {
                // The edit is built from the wire form. The editor has no kind for it, so a throwaway mark draft (whose
                // defaults always validate) carries the shared name, switch and match through the draft's own checks;
                // only its conditions are used, never its mark action.
                var draft = RuleEditorDraft(kind: .mark, id: base.id)
                draft.name = base.name
                draft.enabled = base.enabled
                draft.matchMode = base.matchMode
                draft.match = base.match
                var own = Issues()
                let built = Self.newAction(type, element, prefix: prefix, issues: &own)
                issues += own.items
                let validation = draft.validate(order: 0, limits: limits)
                issues += Self.issues(validation.issues, in: draft, actionPrefix: prefix)
                if let rule = validation.rule, let built {
                    actions.append(RuleAction(built))
                    conditions = conditions ?? rule.conditions
                }
                continue
            }
            guard let kind = Self.kind(of: element) else {
                issues.append(MCPRuleIssue(field: "\(prefix).type", issue: "unsupported_type"))
                continue
            }
            var draft = RuleEditorDraft(kind: kind, id: base.id)
            draft.name = base.name
            draft.enabled = base.enabled
            draft.matchMode = base.matchMode
            draft.match = base.match
            var own = Issues()
            Self.apply(action: element, to: &draft, isNew: true, issues: &own, prefix: prefix)
            issues += own.items
            let validation = draft.validate(order: 0, limits: limits)
            issues += Self.issues(validation.issues, in: draft, actionPrefix: prefix)
            if let rule = validation.rule, let action = rule.actions.first {
                actions.append(action)
                conditions = conditions ?? rule.conditions
            }
        }
        guard issues.isEmpty, let conditions = override ?? conditions else { return .issues(Self.sorted(issues)) }
        let rule = Rule(
            id: base.id, name: base.name, enabled: base.enabled, order: 0, conditions: conditions, actions: actions)
        do {
            try rule.validate(limits: limits)
        } catch let error as RuleValidationError {
            return .issues(Self.issues(of: error, singleAction: single))
        } catch {
            return .issues([MCPRuleIssue(field: single ? "action" : "actions", issue: "unknown")])
        }
        return .rule(rule)
    }

    /// A rename, a switch and new conditions for a rule the Rules window cannot state; its actions are written back
    /// as they are, and its occurrence range stays.
    private func updateWhole(_ rule: Rule, _ spec: MCPRuleSpec, enable: Bool?, allowEnabledRule: Bool) async -> MCPRuleWriteOutcome {
        var refused = Issues()
        // Actions MCP cannot create are the user's to edit in the Rules window: only the name and the switch change.
        if rule.actions.contains(where: { Self.isReadOnlyThroughMCP($0.kind) }) {
            if spec.match != nil { refused.add("match", Self.nonCreatableIssue) }
            if spec.conditions != nil { refused.add("conditions", Self.nonCreatableIssue) }
            if spec.action != nil { refused.add("action", Self.nonCreatableIssue) }
            if spec.actions != nil { refused.add("actions", Self.nonCreatableIssue) }
            if !refused.isEmpty { return .invalid(Self.sorted(refused.items)) }
        }
        if spec.match != nil { refused.add("match", "unsupported_type") }
        // A hide rule is owned by the user: its conditions are not MCP's to change either.
        if spec.conditions != nil, rule.actions.contains(where: { $0.kind == .hide }) {
            refused.add("conditions", "unsupported_type")
        }
        // Conditions alone are fine; next to a match or actions they would be a second, conflicting description.
        if spec.conditions != nil, spec.action != nil || spec.actions != nil { refused.add("conditions", "unsupported_type") }
        if spec.action != nil { refused.add("action", "unsupported_type") }
        if spec.actions != nil { refused.add("actions", "unsupported_type") }
        guard refused.isEmpty else { return .invalid(Self.sorted(refused.items)) }
        var changed = rule
        if let name = spec.name { changed.name = name }
        if let enable { changed.enabled = enable }
        if let patch = spec.conditions {
            var issues = Issues()
            guard
                let group = Self.group(
                    of: patch, occurrence: rule.conditions.occurrence, defaultMode: rule.conditions.mode, limits: editor.limits,
                    issues: &issues)
            else { return .invalid(Self.sorted(issues.items)) }
            changed.conditions = group
            do {
                try changed.validate(limits: editor.limits)
            } catch let error as RuleValidationError {
                return .invalid(Self.sorted(Self.issues(of: error)))
            } catch {
                return .invalid([MCPRuleIssue(field: "conditions", issue: "unknown")])
            }
        }
        return Self.map(await editor.commitExternal(rule: changed, isNew: false, allowEnabledRule: allowEnabledRule), draft: nil)
    }

    private static func map(_ outcome: ExternalRuleOutcome, draft: RuleEditorDraft?) -> MCPRuleWriteOutcome {
        switch outcome {
        case .saved(let id, let enabled, let revision): .saved(id: id, enabled: enabled, revision: revision)
        case .invalid(let found): .invalid(sorted(issues(found, in: draft)))
        case .notFound: .notFound
        case .busy: .busy
        case .beingEdited: .beingEdited
        case .ruleIsEnabled: .ruleIsEnabled
        case .conflict: .conflict
        case .breakpointsUnavailable: .invalid([MCPRuleIssue(field: "enabled", issue: "breakpoint_unavailable")])
        }
    }

    // MARK: issues

    private struct Issues {
        var items: [MCPRuleIssue] = []
        var isEmpty: Bool { items.isEmpty }
        mutating func add(_ field: String, _ issue: String) { items.append(MCPRuleIssue(field: field, issue: issue)) }
    }

    private static func sorted(_ issues: [MCPRuleIssue]) -> [MCPRuleIssue] {
        var seen: Set<String> = []
        return issues.sorted { ($0.field, $0.issue) < ($1.field, $1.issue) }.filter { seen.insert("\($0.field)\u{0}\($0.issue)").inserted }
    }

    /// The editor's issues as the tool's member paths and the issue's raw value (never a localized message). A
    /// problem of the action is named `action.…`, or `actionPrefix.…` for an element of `actions`.
    private static func issues(
        _ found: [RuleDraftField: RuleDraftIssue], in draft: RuleEditorDraft?, actionPrefix: String = "action"
    ) -> [MCPRuleIssue] {
        found.map { entry in
            let name = fieldName(entry.key, in: draft)
            let field = name.hasPrefix("action.") ? actionPrefix + name.dropFirst("action".count) : name
            return MCPRuleIssue(field: field, issue: entry.value.rawValue)
        }
    }

    /// A problem of the finished rule that no element's draft found, in the tool's member names.
    private static func issues(of error: RuleValidationError, singleAction: Bool = false) -> [MCPRuleIssue] {
        let field: String =
            switch error.field {
            case .name: "name"
            case .scheme, .hostPattern, .port, .method, .path, .statusRange, .conditions: "match"
            case .conditionRow(let index): "conditions.rows[\(index)].\(member(of: error.code))"
            case .action(let index):
                (singleAction ? "action" : "actions[\(index)]")
                    + ([.invalidQueryEdit, .invalidCookieEdit].contains(error.code) ? ".operations" : "")
            default: "actions"
            }
        // The conditions' own codes keep their names; the rest read as the Rules window's issues do.
        switch error.code {
        case .actionNotAllowedAtCompletion, .conditionNameRequired, .unexpectedConditionName, .invalidConditionName,
            .invalidConditionValue, .invalidOperator, .tooManyConditions:
            return [MCPRuleIssue(field: field, issue: error.code.rawValue)]
        default:
            return [MCPRuleIssue(field: field, issue: RuleDraftIssue(error).rawValue)]
        }
    }

    private static func fieldName(_ field: RuleDraftField, in draft: RuleEditorDraft?) -> String {
        switch field {
        case .name: "name"
        case .scheme: "match.scheme"
        case .host: "match.host"
        case .port: "match.port"
        case .method: "match.method"
        case .path: "match.path"
        case .statusRange: "match.status_range"
        case .mapLocalAsset: "action.asset"
        case .mapLocalStatus: "action.status"
        case .mapLocalHeader: "action.headers"
        case .directory: "action.directory"
        case .targetScheme: "action.target_scheme"
        case .targetHost: "action.target_host"
        case .targetPort: "action.target_port"
        case .targetPath: "action.path"
        case .headerOperation(let rowID):
            "action.operations[\(draft?.headerOperations.firstIndex { $0.id == rowID } ?? 0)]"
        case .bodyFind: "action.find"
        case .bodyReplacement: "action.replace"
        case .rewriteStatus: "action.status"
        case .markColor: "action.color"
        case .markForeground: "action.text_color"
        case .markText, .commentText, .commentFind: "action.text"
        case .commentReplacement: "action.replace"
        }
    }

    // MARK: spec to draft

    private static let wireTypes: [(String, RuleKind)] = [
        ("map_remote", .mapRemote), ("edit_headers", .editHeaders), ("rewrite_body", .rewriteBody),
        ("rewrite_status", .rewriteStatus), ("mark", .mark), ("comment", .comment),
    ]

    /// The kind a spec's `action.type` names; only the types MCP may write (hide is not one of them).
    static let nonCreatableIssue = "contains_non_creatable_action"

    /// The R4 actions MCP can create. They have no editor kind: they are built from the wire form here and checked by
    /// the rule validation like any action.
    private enum NewType: String {
        case modifyURL = "modify_url", modifyQuery = "modify_query", editCookies = "edit_cookies"
    }

    private static func newType(of action: [String: JSONValue]) -> NewType? {
        action["type"]?.stringValue.flatMap(NewType.init(rawValue:))
    }

    /// `[action]` when the single action is one of the new types, so it takes the path of `actions`.
    private static func newTypeAction(_ action: [String: JSONValue]?) -> [[String: JSONValue]]? {
        guard let action, newType(of: action) != nil else { return nil }
        return [action]
    }

    /// Actions the Rules window runs that MCP lists but never creates, patches or replaces.
    private static func isReadOnlyThroughMCP(_ kind: ActionKind) -> Bool {
        switch kind {
        case .delay, .returnHandwritten, .returnPreset, .closeConnection, .returnConnectTunnel, .noDecrypt, .magicString: true
        case .returnFile, .returnDirectory, .mapRemote, .editHeaders, .breakpoint, .rewriteBody, .rewriteStatus, .mark,
            .comment, .hide, .modifyURL, .modifyQuery, .editCookies: false
        }
    }

    private static func newAction(_ type: NewType, _ action: [String: JSONValue], prefix: String, issues: inout Issues) -> ActionKind? {
        let before = issues.items.count
        func text(_ item: [String: JSONValue], _ key: String) -> String? { item[key]?.stringValue }
        /// A flag that is given must be a boolean (the tool checks it too); anything else is `invalid_value`.
        func flag(_ item: [String: JSONValue], _ key: String, _ path: String) -> Bool {
            guard let value = item[key] else { return false }
            guard let flag = value.boolValue else {
                issues.add(path, "invalid_value")
                return false
            }
            return flag
        }
        switch type {
        case .modifyURL:
            var edit = URLEditAction(mode: .set)
            if let word = text(action, "mode") {
                switch word {
                case "set": edit.mode = .set
                case "find_replace": edit.mode = .findReplace
                case "regex": edit.mode = .regex
                case "append": edit.mode = .append
                default: issues.add("\(prefix).mode", "invalid_value")
                }
            }
            edit.find = text(action, "find") ?? ""
            edit.replacement = text(action, "replacement") ?? ""
            edit.caseSensitive = flag(action, "case_sensitive", "\(prefix).case_sensitive")
            edit.preserveCredentials = flag(action, "preserve_credentials", "\(prefix).preserve_credentials")
            return issues.items.count == before ? .modifyURL(edit) : nil
        case .modifyQuery:
            var edits: [QueryEdit] = []
            for (index, item) in (action["operations"]?.arrayValue ?? []).enumerated() {
                let members = item.objectValue ?? [:]
                let name = text(members, "name") ?? ""
                let optionalName = name.isEmpty ? nil : name
                switch text(members, "op") {
                case "set": edits.append(.set(name: name, value: text(members, "value") ?? ""))
                case "add": edits.append(.add(name: name, value: text(members, "value") ?? ""))
                case "remove": edits.append(.remove(name: name))
                case "add_if_missing": edits.append(.addIfMissing(name: name, value: text(members, "value") ?? ""))
                case "append_to_value":
                    edits.append(.appendToValue(name: name, text: text(members, "text") ?? text(members, "value") ?? ""))
                case "replace":
                    edits.append(
                        .findReplace(
                            name: optionalName, find: text(members, "find") ?? "", replacement: text(members, "replacement") ?? "",
                            caseSensitive: flag(members, "case_sensitive", "\(prefix).operations[\(index)].case_sensitive")))
                case "regex":
                    edits.append(
                        .regex(
                            name: optionalName, pattern: text(members, "pattern") ?? "", replacement: text(members, "replacement") ?? "",
                            caseSensitive: flag(members, "case_sensitive", "\(prefix).operations[\(index)].case_sensitive")))
                default: issues.add("\(prefix).operations[\(index)].op", "invalid_value")
                }
            }
            return issues.items.count == before ? .modifyQuery(QueryEditAction(operations: edits)) : nil
        case .editCookies:
            var direction = HTTPMessageDirection.request
            if let word = text(action, "direction") {
                if let parsed = HTTPMessageDirection(rawValue: word) {
                    direction = parsed
                } else {
                    issues.add("\(prefix).direction", "invalid_value")
                }
            }
            var edits: [CookieEdit] = []
            for (index, item) in (action["operations"]?.arrayValue ?? []).enumerated() {
                let members = item.objectValue ?? [:]
                let name = text(members, "name") ?? ""
                let optionalName = name.isEmpty ? nil : name
                let value = text(members, "value") ?? ""
                let replacement = text(members, "replacement") ?? ""
                let caseSensitive = flag(members, "case_sensitive", "\(prefix).operations[\(index)].case_sensitive")
                switch text(members, "op") {
                case "set": edits.append(.set(name: name, value: value))
                case "add_if_missing": edits.append(.addIfMissing(name: name, value: value))
                case "remove": edits.append(.remove(name: name))
                case "append_to_value":
                    edits.append(.appendToValue(name: name, text: text(members, "text") ?? text(members, "value") ?? ""))
                case "replace":
                    edits.append(
                        .findReplace(
                            name: optionalName, find: text(members, "find") ?? "", replacement: replacement,
                            caseSensitive: caseSensitive))
                case "regex":
                    edits.append(
                        .regex(
                            name: optionalName, pattern: text(members, "pattern") ?? "", replacement: replacement,
                            caseSensitive: caseSensitive))
                default: issues.add("\(prefix).operations[\(index)].op", "invalid_value")
                }
            }
            return issues.items.count == before ? .editCookies(direction: direction, operations: edits) : nil
        }
    }

    private static func kind(of action: [String: JSONValue]) -> RuleKind? {
        guard let type = action["type"]?.stringValue else { return nil }
        return wireTypes.first { $0.0 == type }?.1
    }

    /// What `list` calls an action: the wire name of its type, the message it runs on (nil for the mapping
    /// actions, which choose the route), and whether it stops lower-priority rules. An action of Rules 2.0 R4 also
    /// has a one-line summary and, when MCP can create it, its fields in the shape `create_rule` takes; the ones MCP
    /// can only list say so and show nothing of what they hold (no response text, location or challenge).
    static func summary(of action: RuleAction) -> MCPRuleActionSummary {
        let type: String
        let direction: String?
        var line: String?
        var fields: JSONValue?
        switch action.kind {
        case .returnFile: (type, direction) = ("map_local", nil)
        case .returnDirectory: (type, direction) = ("map_local_directory", nil)
        case .mapRemote: (type, direction) = ("map_remote", nil)
        case .editHeaders(let side, _): (type, direction) = ("edit_headers", side.rawValue)
        case .breakpoint(let side, _): (type, direction) = ("breakpoint", side.rawValue)
        case .rewriteBody(let side, _): (type, direction) = ("rewrite_body", side.rawValue)
        case .rewriteStatus: (type, direction) = ("rewrite_status", HTTPMessageDirection.response.rawValue)
        case .mark: (type, direction) = ("mark", nil)
        case .comment: (type, direction) = ("comment", nil)
        case .hide: (type, direction) = ("hide", nil)
        case .modifyURL(let edit):
            (type, direction) = ("modify_url", HTTPMessageDirection.request.rawValue)
            let mode = urlModeWords[edit.mode] ?? "set"
            line = "modify_url \(mode)" + (edit.mode == .set ? " -> \(edit.replacement)" : "")
            fields = .object([
                "mode": .string(mode), "find": .string(edit.find), "replacement": .string(edit.replacement),
                "case_sensitive": .bool(edit.caseSensitive), "preserve_credentials": .bool(edit.preserveCredentials),
            ])
        case .modifyQuery(let edit):
            (type, direction) = ("modify_query", HTTPMessageDirection.request.rawValue)
            line = "modify_query (\(edit.operations.count) \(edit.operations.count == 1 ? "operation" : "operations"))"
            fields = .object(["operations": .array(edit.operations.map(queryOperationValue))])
        case .editCookies(let side, let operations):
            (type, direction) = ("edit_cookies", side.rawValue)
            line = "edit_cookies on \(side.rawValue) (\(operations.count) \(operations.count == 1 ? "operation" : "operations"))"
            fields = .object(["operations": .array(operations.map(cookieOperationValue))])
        case .delay(let milliseconds):
            (type, direction) = ("delay", HTTPMessageDirection.request.rawValue)
            line = "delay \(milliseconds) ms (only editable in ProxyWoman)"
        case .returnHandwritten:
            (type, direction) = ("return_handwritten", HTTPMessageDirection.request.rawValue)
            line = "return_handwritten (only editable in ProxyWoman)"
        case .returnPreset(let response):
            (type, direction) = ("return_preset", HTTPMessageDirection.request.rawValue)
            line = "return_preset \(response.preset.rawValue) (only editable in ProxyWoman)"
        case .closeConnection(let mode):
            (type, direction) = ("close_connection", HTTPMessageDirection.request.rawValue)
            line = "close_connection \(mode.rawValue) (only editable in ProxyWoman)"
        case .returnConnectTunnel:
            (type, direction) = ("return_connect_tunnel", HTTPMessageDirection.request.rawValue)
            line = "return_connect_tunnel (only editable in ProxyWoman)"
        case .noDecrypt:
            (type, direction) = ("no_decrypt", HTTPMessageDirection.request.rawValue)
            line = "no_decrypt (only editable in ProxyWoman)"
        case .magicString(let text):
            (type, direction) = ("magic_string", action.kind.direction?.rawValue)
            line = "magic_string \(text) (only editable in ProxyWoman)"
            fields = .object(["text": .string(text)])
        }
        return MCPRuleActionSummary(type: type, direction: direction, isFinal: action.isFinalEffective, summary: line, fields: fields)
    }

    private static let urlModeWords: [URLEditAction.Mode: String] = [.set: "set", .findReplace: "find_replace", .regex: "regex", .append: "append"]

    private static func queryOperationValue(_ edit: QueryEdit) -> JSONValue {
        switch edit {
        case .set(let name, let value, _): .object(["op": .string("set"), "name": .string(name), "value": .string(value)])
        case .add(let name, let value, _): .object(["op": .string("add"), "name": .string(name), "value": .string(value)])
        case .remove(let name, _): .object(["op": .string("remove"), "name": .string(name)])
        case .findReplace(let name, let find, let replacement, let caseSensitive, _):
            .object(replaceMembers(op: "replace", name: name, find: find, replacement: replacement, caseSensitive: caseSensitive))
        case .regex(let name, let pattern, let replacement, let caseSensitive, _):
            .object(
                replaceMembers(op: "regex", name: name, find: nil, replacement: replacement, caseSensitive: caseSensitive)
                    .merging(["pattern": .string(pattern)]) { $1 })
        case .addIfMissing(let name, let value, _):
            .object(["op": .string("add_if_missing"), "name": .string(name), "value": .string(value)])
        case .appendToValue(let name, let text, _):
            .object(["op": .string("append_to_value"), "name": .string(name), "text": .string(text)])
        }
    }

    private static func cookieOperationValue(_ edit: CookieEdit) -> JSONValue {
        switch edit {
        case .set(let name, let value, _): .object(["op": .string("set"), "name": .string(name), "value": .string(value)])
        case .addIfMissing(let name, let value, _):
            .object(["op": .string("add_if_missing"), "name": .string(name), "value": .string(value)])
        case .remove(let name, _): .object(["op": .string("remove"), "name": .string(name)])
        case .findReplace(let name, let find, let replacement, let caseSensitive, _):
            .object(replaceMembers(op: "replace", name: name, find: find, replacement: replacement, caseSensitive: caseSensitive))
        case .regex(let name, let pattern, let replacement, let caseSensitive, _):
            .object(
                replaceMembers(op: "regex", name: name, find: nil, replacement: replacement, caseSensitive: caseSensitive)
                    .merging(["pattern": .string(pattern)]) { $1 })
        case .appendToValue(let name, let text, _):
            .object(["op": .string("append_to_value"), "name": .string(name), "text": .string(text)])
        }
    }

    private static func replaceMembers(
        op: String, name: String?, find: String?, replacement: String, caseSensitive: Bool
    ) -> [String: JSONValue] {
        var members: [String: JSONValue] = [
            "op": .string(op), "replacement": .string(replacement), "case_sensitive": .bool(caseSensitive),
        ]
        if let name { members["name"] = .string(name) }
        if let find { members["find"] = .string(find) }
        return members
    }

    private static func apply(match: [String: JSONValue], to draft: inout RuleEditorDraft, issues: inout Issues) {
        func text(_ key: String) -> String? { match[key]?.stringValue }
        func number(_ key: String) -> String? { match[key]?.intValue.map(String.init) }

        if let value = text("scheme") {
            if let scheme = RuleSchemeChoice(rawValue: value.lowercased()) {
                draft.match.scheme = scheme
            } else {
                issues.add("match.scheme", "invalid_value")
            }
        }
        if let value = text("host") { draft.match.host = value }
        if let value = number("port") { draft.match.port = value }
        if let value = text("method") { draft.match.method = value }
        // The syntax first: it decides how host and path are read, and choosing it confirms the loaded text.
        if let value = text("syntax") {
            if let syntax = PatternSyntax(rawValue: value) {
                draft.match.chooseSyntax(syntax)
            } else {
                issues.add("match.syntax", "invalid_value")
            }
        }
        if let value = text("path") {
            draft.match.path = value
            if draft.match.syntax == .literal {
                switch (value.isEmpty, draft.match.pathMode) {
                case (true, _): draft.match.pathMode = .any
                case (false, .any): draft.match.pathMode = .exact
                case (false, .exact), (false, .prefix): break
                }
            }
        }
        if let value = number("status_min") { draft.match.statusLower = value }
        if let value = number("status_max") { draft.match.statusUpper = value }
        if let value = text("mode") {
            if let mode = ConditionGroup.Mode(rawValue: value) {
                draft.matchMode = mode
            } else {
                issues.add("match.mode", "invalid_value")
            }
        }
    }

    private static let commentModes: [String: CommentModeChoice] = [
        "set": .set, "append": .append, "find_replace": .findReplace, "clear": .clear, "regex": .regex,
        "add_if_missing": .addIfMissing,
    ]

    /// `prefix` names the action in the issues: `action`, or `actions[i]` for an element of `actions`.
    private static func apply(
        action: [String: JSONValue], to draft: inout RuleEditorDraft, isNew: Bool, issues: inout Issues, prefix: String = "action"
    ) {
        func text(_ key: String) -> String? { action[key]?.stringValue }
        func number(_ key: String) -> String? { action[key]?.intValue.map(String.init) }
        func flag(_ key: String) -> Bool? { action[key]?.boolValue }

        func direction() {
            guard let value = text("direction") else { return }
            if let parsed = HTTPMessageDirection(rawValue: value) {
                draft.direction = parsed
            } else {
                issues.add("\(prefix).direction", "invalid_value")
            }
        }

        switch draft.kind {
        case .mapRemote:
            if let value = text("target_scheme") {
                if let scheme = RuleTargetScheme(rawValue: value.lowercased()) {
                    draft.mapRemote.targetScheme = scheme
                } else {
                    issues.add("\(prefix).target_scheme", "invalid_value")
                }
            }
            if let value = text("target_host") { draft.mapRemote.targetHost = value }
            if let value = number("target_port") {
                draft.mapRemote.targetPort = value
            } else if isNew {
                // No port given: the scheme's own port, not a leftover default.
                draft.mapRemote.targetPort = draft.mapRemote.targetScheme == .http ? "80" : "443"
            }
            if let value = text("path") {
                draft.mapRemote.pathChoice = value.isEmpty ? .preserve : .replace
                draft.mapRemote.replacementPath = value
            }
            if let value = flag("preserve_credentials") { draft.mapRemote.preserveCredentials = value }
        case .editHeaders:
            direction()
            if let operations = action["operations"]?.arrayValue {
                draft.headerOperations = operations.compactMap { operation in
                    guard let op = operation["op"]?.stringValue, let name = operation["name"]?.stringValue else { return nil }
                    let value = operation["value"]?.stringValue ?? ""
                    switch op {
                    case "set": return HeaderOperationRow(kind: .set, name: name, value: value)
                    case "add": return HeaderOperationRow(kind: .append, name: name, value: value)
                    case "remove": return HeaderOperationRow(kind: .remove, name: name)
                    default: return nil
                    }
                }
            }
        case .rewriteBody:
            direction()
            if let value = text("find") { draft.bodyRewrite.find = value }
            if let value = text("replace") { draft.bodyRewrite.replacement = value }
            if let value = text("syntax") {
                switch value {
                case "literal", "text": draft.bodyRewrite.syntax = .text
                case "regex": draft.bodyRewrite.syntax = .regex
                default: issues.add("\(prefix).syntax", "invalid_value")
                }
            }
            if let value = flag("case_sensitive") { draft.bodyRewrite.caseSensitive = value }
            if let value = text("scope") {
                if let scope = BodyReplaceScope(rawValue: value) {
                    draft.bodyRewrite.scope = scope
                } else {
                    issues.add("\(prefix).scope", "invalid_value")
                }
            }
        case .rewriteStatus:
            if let value = number("status") {
                // `reason` is the phrase after the code (HTTP/1.1 only); the status field holds both.
                let phrase = text("reason").map { $0.isEmpty ? "" : " " + $0 } ?? ""
                draft.rewriteStatus.status = value + phrase
            }
            if let value = flag("include_local_responses") { draft.rewriteStatus.includeLocalResponses = value }
        case .mark:
            if let value = text("color") { draft.mark.background = MarkPalette.presets.first { $0.name.rawValue == value.lowercased() }?.lightHex ?? value }
            if let value = text("text") { draft.mark.text = value }
            if let value = text("text_color") { draft.mark.foreground = value.isEmpty ? nil : value }
        case .comment:
            if let value = text("mode") {
                if let mode = commentModes[value] {
                    draft.comment.mode = mode
                } else {
                    issues.add("\(prefix).mode", "invalid_value")
                }
            }
            if let value = text("text") { draft.comment.text = value }
            if let value = text("replace") { draft.comment.replacement = value }
            if let value = flag("case_sensitive") { draft.comment.caseSensitive = value }
        case .mapLocal, .mapLocalDirectory, .breakpoint, .hide:
            break
        }
    }

    // MARK: listing

    /// Every rule says how its conditions combine (`mode`), what each action is (`actions`) and where it sits
    /// (`groupID`). A rule with one action the Rules window can state keeps the keys it always had; any other rule
    /// is `multiple`, has no `match` or `direction`, and its summary says what it holds and what it matches.
    private static func summary(of rule: Rule, order: Int) -> MCPRuleSummary {
        let actions = rule.actions.map { summary(of: $0) }
        let mode = rule.conditions.mode.rawValue
        if case .annotation(let annotation) = rule.oldEditorForm, let only = actions.first {
            return MCPRuleSummary(
                id: rule.id, name: rule.name, enabled: rule.enabled, order: order, type: only.type, direction: nil,
                match: matchValue(of: rule), summary: annotationLine(of: annotation, type: only.type),
                mode: mode, actions: actions, groupID: rule.groupID)
        }
        guard case .legacy(let simple) = rule.oldEditorForm, let only = actions.first else {
            return MCPRuleSummary(
                id: rule.id, name: rule.name, enabled: rule.enabled, order: order, type: "multiple", direction: nil,
                match: .null, summary: wholeRuleLine(of: rule, actions: actions), mode: mode, actions: actions,
                groupID: rule.groupID, conditions: conditionsValue(of: rule))
        }
        return MCPRuleSummary(
            id: rule.id, name: rule.name, enabled: rule.enabled, order: order, type: only.type, direction: only.direction,
            match: matchValue(of: rule), summary: summaryLine(of: simple, type: only.type, direction: only.direction),
            mode: mode, actions: actions, groupID: rule.groupID)
    }

    /// The condition rows in the shape `create_rule` takes, for a rule that uses a field the fixed `match` cannot
    /// state; nil for every other rule (its listing has no `conditions` key).
    private static func conditionsValue(of rule: Rule) -> JSONValue? {
        guard rule.conditions.rows.contains(where: { if case .current = $0.evaluationPath { true } else { false } }) else {
            return nil
        }
        let rows = rule.conditions.rows.map { row -> JSONValue in
            var members: [String: JSONValue] = [
                "field": .string(row.field.rawValue), "op": .string(row.op.rawValue), "value": .string(row.value),
                "case_sensitive": .bool(row.caseSensitive),
            ]
            if let name = row.name, !name.isEmpty { members["name"] = .string(name) }
            return .object(members)
        }
        return .object(["mode": .string(rule.conditions.mode.rawValue), "rows": .array(rows)])
    }

    /// The matcher in the tool's own member names, read through the editor's draft so it shows what the Rules
    /// window shows. A literal path also says whether it is an exact or a prefix match (`path_mode`), which the
    /// tools cannot set but keep when the path is patched. A rule whose fields combine any / none says so in
    /// `mode`, as `create_rule` takes it (all is the default and stays unsaid), so the fields are never read as
    /// "every one must match" on their own.
    private static func matchValue(of rule: Rule) -> JSONValue {
        let match = RuleEditorDraft(rule: rule, asset: nil).match
        var members: [String: JSONValue] = [:]
        if match.scheme != .any { members["scheme"] = .string(match.scheme.rawValue) }
        if !match.host.isEmpty { members["host"] = .string(match.host) }
        if let port = Int(match.port) { members["port"] = .int(port) }
        if !match.method.isEmpty { members["method"] = .string(match.method) }
        if !match.path.isEmpty {
            members["path"] = .string(match.path)
            if match.syntax == .literal { members["path_mode"] = .string(match.pathMode.rawValue) }
        }
        if !match.host.isEmpty || !match.path.isEmpty { members["syntax"] = .string(match.syntax.rawValue) }
        if let lower = Int(match.statusLower) { members["status_min"] = .int(lower) }
        if let upper = Int(match.statusUpper) { members["status_max"] = .int(upper) }
        if rule.conditions.mode != .all { members["mode"] = .string(rule.conditions.mode.rawValue) }
        return .object(members)
    }

    /// One English line for the AI client (the Rules window's own summary is localized for the user). Rules
    /// that use a file or a directory show only their type and status; no body text, header values, file name,
    /// bookmark or asset id of any rule is written here.
    private static func summaryLine(of rule: SimpleRule, type: String, direction: String?) -> String {
        var line = type
        if let direction { line += " on \(direction)" }
        // These two lines do not show the match, so a rule that combines its fields any / none says so here.
        let modeNote = rule.mode != .all && rule.matcher != RuleMatcher() ? ", match mode \(rule.mode.rawValue)" : ""
        switch rule.action {
        case .mapLocal(let local): return "\(line), status \(local.status)" + modeNote
        case .mapLocalDirectory: return line + modeNote
        default: break
        }
        line += ": " + conditionLine(rule.matcher, mode: rule.mode)
        switch rule.action {
        case .mapRemote(let remote):
            let defaultPort = (remote.targetScheme == "http" && remote.targetPort == 80)
                || (remote.targetScheme == "https" && remote.targetPort == 443)
            line += " -> \(remote.targetScheme)://\(remote.targetHost)" + (defaultPort ? "" : ":\(remote.targetPort)")
        case .rewriteStatus(let rewrite):
            line += " -> status \(rewrite.status)"
        case .editHeaders(_, let operations):
            line += " (\(operations.count) header \(operations.count == 1 ? "change" : "changes"))"
        default: break
        }
        return line
    }

    /// Mark, comment and hide: the type, what it matches and (for a mark) its colour. Labels and comment
    /// text are not repeated here.
    private static func annotationLine(of rule: SimpleAnnotationRule, type: String) -> String {
        var line = type + ": " + conditionLine(rule.matcher, mode: rule.mode)
        switch rule.kind {
        case .mark(let mark): line += " -> \(mark.background)"
        case .comment(let comment): line += " -> " + (commentModes.first { $0.value.engineMode == comment.mode }?.key ?? "")
        default: break
        }
        return line
    }

    /// The summary of a rule listed as `multiple`: its actions in order (and which of them are final), what it
    /// matches as far as the fixed fields can say it, and its occurrence range.
    private static func wholeRuleLine(of rule: Rule, actions: [MCPRuleActionSummary]) -> String {
        let steps = actions.map { action in
            action.type + (action.direction.map { " on \($0)" } ?? "") + (action.isFinal ? " (final)" : "")
        }
        var line = "\(actions.count) \(actions.count == 1 ? "action" : "actions"): " + steps.joined(separator: ", ")
        if let matcher = fixedFieldMatcher(of: rule) {
            line += "; match: " + conditionLine(matcher, mode: rule.conditions.mode)
        } else {
            let rows = rule.conditions.rows.count
            line += "; match: \(rows) condition \(rows == 1 ? "row" : "rows"), mode \(rule.conditions.mode.rawValue)"
        }
        if case .times(let range) = rule.conditions.occurrence {
            line += "; occurrence \(range.lowerBound)-\(range.upperBound)"
        }
        return line
    }

    /// The conditions as the six fixed fields, when they fit them. `Rule.simple` is the one place that knows
    /// what fits, so it is asked about the same conditions on a rule with one plain action.
    private static func fixedFieldMatcher(of rule: Rule) -> RuleMatcher? {
        var probe = rule
        probe.conditions.occurrence = .any
        probe.actions = [RuleAction(.rewriteStatus(RewriteStatusAction(status: 200)))]
        return probe.simple?.matcher
    }

    /// What the fixed fields match, and how: as one request pattern when every field must match, otherwise as
    /// the list of fields with the word that says which of them decide. Without a field every request matches.
    private static func conditionLine(_ matcher: RuleMatcher, mode: ConditionGroup.Mode) -> String {
        if matcher == RuleMatcher() { return "any request" }
        switch mode {
        case .all: return matchLine(matcher)
        case .any: return "any of [\(fieldList(matcher))]"
        case .none: return "none of [\(fieldList(matcher))]"
        }
    }

    private static func fieldList(_ matcher: RuleMatcher) -> String {
        var fields: [String] = []
        if let scheme = matcher.scheme { fields.append("scheme \(scheme)") }
        if let host = matcher.hostPattern {
            let syntax = matcher.hostSyntax == .literal ? "" : " (\(matcher.hostSyntax.rawValue))"
            fields.append("host \(host)\(syntax)")
        }
        if let port = matcher.port { fields.append("port \(port)") }
        if let method = matcher.method { fields.append("method \(method)") }
        switch matcher.path {
        case .any: break
        case .exact(let value): fields.append("path \(value)")
        case .prefix(let value): fields.append("path \(value)*")
        case .wildcard(let value): fields.append("path \(value) (wildcard)")
        case .regex(let value): fields.append("path \(value) (regex)")
        }
        if let range = matcher.statusRange { fields.append("status \(range.lowerBound)-\(range.upperBound)") }
        return fields.joined(separator: ", ")
    }

    private static func matchLine(_ matcher: RuleMatcher) -> String {
        if matcher == RuleMatcher() { return "any request" }
        let path: String =
            switch matcher.path {
            case .any: "/*"
            case .exact(let value): value
            case .prefix(let value): value + "*"
            case .wildcard(let value), .regex(let value): value
            }
        var line = (matcher.method.map { $0 + " " } ?? "") + (matcher.scheme ?? "*") + "://" + (matcher.hostPattern ?? "*")
            + (matcher.port.map { ":\($0)" } ?? "") + path
        if let range = matcher.statusRange { line += " [status \(range.lowerBound)-\(range.upperBound)]" }
        switch (matcher.hostSyntax, matcher.path) {
        case (.wildcard, _), (.literal, .wildcard): line += " (wildcard)"
        case (.regex, _), (.literal, .regex): line += " (regex)"
        default: break
        }
        return line
    }
}
