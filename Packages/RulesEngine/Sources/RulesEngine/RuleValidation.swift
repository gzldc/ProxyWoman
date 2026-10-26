import FlowStore
import Foundation

extension ConditionRow {
    /// The editor field a problem with this row is shown against.
    private var errorField: RuleValidationError.Field {
        switch field {
        case .allSessions: .conditions
        case .scheme: .scheme
        case .host: .hostPattern
        case .port: .port
        case .method: .method
        case .pathAndQuery: .path
        case .statusCode: .statusRange
        default: .conditions
        }
    }

    /// The old matcher's own checks, so a row reports the codes and fields the old editor did. A
    /// combination R1 cannot express is `invalidOperator`; an unreadable port or status value gets
    /// the code of an out-of-range one.
    func validate(limits: RulesLimits) throws {
        switch legacyReading {
        case .matcher(let matcher):
            try matcher.validate(limits: limits)
        case .unsupported:
            throw RuleValidationError(code: .invalidOperator, field: errorField)
        case .unreadableValue:
            throw RuleValidationError(
                code: field == .port ? .invalidPort : .invalidStatusRange, field: errorField)
        }
    }
}

extension RuleAction {
    /// An old rule that carries this action's payload and nothing else, so the old per-action checks
    /// run unchanged. A directory action's prefix travels as the matcher's path, where the old check
    /// reads it.
    fileprivate var payloadProbe: LegacyRule? {
        let action: LegacyRuleAction
        var matcher = RuleMatcher()
        switch kind {
        case .returnFile(let file): action = .mapLocal(file)
        case .returnDirectory(let directory, let prefix):
            action = .mapLocalDirectory(directory)
            matcher.path = .prefix(prefix)
        case .mapRemote(let remote): action = .mapRemote(remote)
        case .editHeaders(let direction, let operations):
            action = .editHeaders(direction: direction, operations: operations)
        case .breakpoint(let direction, let mode): action = .breakpoint(direction: direction, mode: mode)
        case .rewriteBody(let direction, let rewrite): action = .rewriteBody(direction: direction, rewrite)
        case .rewriteStatus(let rewrite): action = .rewriteStatus(rewrite)
        case .mark, .comment, .hide: return nil
        // Checked as the action it expands to (`resolvedForValidation`).
        case .magicString: return nil
        // Validated by the R4 checks, not by an old rule.
        case .modifyURL, .modifyQuery, .editCookies, .delay, .returnHandwritten, .returnPreset, .closeConnection,
            .returnConnectTunnel, .noDecrypt: return nil
        }
        return LegacyRule(id: UUID(), name: "", enabled: true, order: 0, matcher: matcher, action: action)
    }
}

extension ActionKind {
    /// The checks of the mark and comment actions; every other action has none here.
    fileprivate func validateAnnotation(limits: RulesLimits) throws {
        switch self {
        case .mark(let mark):
            guard MarkAction.isNoColorChoice(mark.background) || FlowMark.normalizedHex(mark.background) != nil else {
                throw RuleValidationError(code: .invalidMarkColor, field: .markColor)
            }
            if let foreground = mark.foreground, !MarkAction.isNoColorChoice(foreground),
                FlowMark.normalizedHex(foreground) == nil
            {
                throw RuleValidationError(code: .invalidMarkColor, field: .markForeground)
            }
            if let text = mark.text, text.utf8.count > limits.markTextBytes {
                throw RuleValidationError(code: .markTextTooLong, field: .markText)
            }
        case .comment(let comment):
            switch comment.mode {
            case .set, .append, .addIfMissing:
                guard !comment.text.isEmpty else {
                    throw RuleValidationError(code: .emptyComment, field: .commentText)
                }
            case .findReplace:
                guard !comment.text.isEmpty else {
                    throw RuleValidationError(code: .emptyCommentFind, field: .commentFind)
                }
            case .regex:
                guard !comment.text.isEmpty else {
                    throw RuleValidationError(code: .emptyCommentFind, field: .commentFind)
                }
                do {
                    _ = try RegexPattern(comment.text, mode: .find, caseInsensitive: !comment.caseSensitive)
                } catch PatternError.regexTooComplex {
                    throw RuleValidationError(code: .regexTooComplex, field: .commentFind)
                } catch PatternError.tooLong {
                    throw RuleValidationError(code: .findTooLong, field: .commentFind)
                } catch {
                    throw RuleValidationError(code: .invalidRegex, field: .commentFind)
                }
            case .clear:
                return
            }
            let textField: RuleValidationError.Field = (comment.mode == .findReplace || comment.mode == .regex) ? .commentFind : .commentText
            if comment.text.utf8.count > limits.commentBytes {
                throw RuleValidationError(code: .commentTooLong, field: textField)
            }
            if comment.replacement.utf8.count > limits.commentBytes {
                throw RuleValidationError(code: .commentTooLong, field: .commentText)
            }
        case .returnFile, .returnDirectory, .mapRemote, .editHeaders, .breakpoint, .rewriteBody, .rewriteStatus, .hide,
            .modifyURL, .modifyQuery, .editCookies, .delay, .returnHandwritten, .returnPreset, .closeConnection,
            .returnConnectTunnel, .noDecrypt, .magicString:
            return
        }
    }
}

extension RuleAction {
    /// The action itself, or for a magic string the action it stands for; a string that does not resolve,
    /// or is over the field cap, is refused.
    fileprivate func resolvedForValidation(limits: RulesLimits, index: Int) throws -> RuleAction {
        guard case .magicString(let text) = kind else { return self }
        func fail(_ code: RuleValidationError.Code) -> RuleValidationError {
            RuleValidationError(code: code, field: .action(index: index))
        }
        guard text.utf8.count <= limits.fieldBytes else { throw fail(.fieldTooLong) }
        guard case .success(let resolved) = MagicStringAction.resolve(text) else { throw fail(.invalidMagicString) }
        // `*exit` does nothing; its stand-in comment edit is empty on purpose, so check an inert annotation instead.
        if MagicStringAction.isExit(text) { return RuleAction(.mark(MarkAction(background: "#000000")), isFinal: isFinal) }
        return RuleAction(resolved, isFinal: isFinal)
    }
}

extension Rule {
    /// What a saved rule may contain. The condition rows and the action payloads are checked by the
    /// old matcher and rule checks, so they keep their codes and fields (header edit positions count
    /// within their own action); what is new is the row and action counts, the comparison that suits
    /// a field, and the judgment point: a rule judged at completion only marks, comments and
    /// hides. A rule judged at the response may carry request-side actions (spec R8F2-6): they cannot reach
    /// the origin, so they only change the recorded request (`executionWarnings` says so); Return File, manual and
    /// predefined responses, closing and delay run at the response instead. Execution
    /// validates header content again.
    public func validate(limits: RulesLimits = RulesLimits()) throws {
        try LegacyRule.check(name, limits, .name)
        guard conditions.rows.count <= limits.ruleConditionRows else {
            throw RuleValidationError(code: .tooManyConditions, field: .conditions)
        }
        for (index, row) in conditions.rows.enumerated() {
            if row.usesLegacyChecks {
                try row.validate(limits: limits)
            } else {
                try row.validateNew(limits: limits, index: index)
            }
        }
        guard !actions.isEmpty else {
            throw RuleValidationError(code: .noActions, field: .action(index: 0))
        }
        guard actions.count <= limits.ruleActions else {
            throw RuleValidationError(code: .tooManyActions, field: .action(index: limits.ruleActions))
        }
        for (index, written) in actions.enumerated() {
            // A magic string is checked as the action it expands to.
            let action = try written.resolvedForValidation(limits: limits, index: index)
            try action.payloadProbe?.validate(limits: limits)
            try action.kind.validateAnnotation(limits: limits)
            try action.kind.validateNew(limits: limits, index: index)
        }
        // Once the exchange finished, only the flow's record can change (spec §5.5.3).
        if conditions.judgmentPoint == .completion, let index = actions.firstIndex(where: { !$0.kind.isAnnotation }) {
            throw RuleValidationError(code: .actionNotAllowedAtCompletion, field: .action(index: index))
        }
        try validateConnectOnly()
    }

    /// Compiles every pattern the rule runs (condition rows and body searches) into `cache` and
    /// switches disabled ones back on. Called when the rule is published; patterns that do not
    /// compile are skipped (validation refuses them before they get here).
    public func preparePatterns(in cache: PatternCache = .shared) {
        for row in conditions.rows {
            row.legacyMatcher?.preparePatterns(in: cache)
            if case .current = row.evaluationPath, row.op == .regex, !row.isLegacyNeverMatching,
                row.field != .magicString
            {
                try? cache.prepareRegex(row.value, mode: .find, caseInsensitive: !row.caseSensitive)
            }
            if row.field == .magicString, let pattern = MagicStringCondition.parse(row.value)?.regexPattern {
                try? cache.prepareRegex(pattern, mode: .find, caseInsensitive: true)
            }
        }
        prepareBodyPatterns(in: cache)
    }

    /// Compiles the rule's body searches and switches disabled ones back on.
    func prepareBodyPatterns(in cache: PatternCache) {
        for action in actions {
            if case .rewriteBody(_, let rewrite) = action.kind, rewrite.operation == .findReplace {
                try? cache.prepareBodyPattern(rewrite)
            }
        }
        prepareEditPatterns(in: cache)
    }
}

extension RuleSnapshot {
    /// The shape of the rule list and the group tree: no id used twice, every rule in a group that
    /// exists, every parent present, no cycle, at most `groupDepth` levels, and at most `ruleCount`
    /// rules. The tree walk in `evaluationOrder` silently skips what is not reachable, so this is
    /// where such data is refused. Loading an older, larger file passes `enforcingRuleCount: false`
    /// (the cap only constrains growth).
    public func validateStructure(limits: RulesLimits, enforcingRuleCount: Bool = true) throws {
        func fail(_ code: RuleValidationError.Code) -> RuleValidationError {
            RuleValidationError(code: code, field: .group)
        }
        if enforcingRuleCount, rules.count > limits.ruleCount { throw fail(.tooManyRules) }

        var groupsByID: [UUID: RuleGroup] = [:]
        groupsByID.reserveCapacity(groups.count)
        for group in groups {
            guard groupsByID.updateValue(group, forKey: group.id) == nil else { throw fail(.duplicateID) }
        }
        var ruleIDs = Set<UUID>(minimumCapacity: rules.count)
        for rule in rules {
            guard ruleIDs.insert(rule.id).inserted else { throw fail(.duplicateID) }
            if let groupID = rule.groupID, groupsByID[groupID] == nil { throw fail(.unknownGroup) }
        }

        // Depth of every group, measured once: a walk up stops at the first group already measured.
        var depths: [UUID: Int] = [:]
        for group in groups {
            var unmeasured: [RuleGroup] = []
            var visited = Set<UUID>()
            var depth = 0
            var next: RuleGroup? = group
            while let current = next {
                if let known = depths[current.id] {
                    depth = known
                    break
                }
                guard visited.insert(current.id).inserted else { throw fail(.groupCycle) }
                unmeasured.append(current)
                next = nil
                if let parentID = current.parentID {
                    guard let parent = groupsByID[parentID] else { throw fail(.unknownGroup) }
                    next = parent
                }
            }
            for current in unmeasured.reversed() {
                depth += 1
                depths[current.id] = depth
                if depth > limits.groupDepth { throw fail(.groupTooDeep) }
            }
        }
    }
}
