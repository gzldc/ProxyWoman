import Foundation

/// Validation of the Rules 2.0 R4 actions. Errors are reported on the action's position.
extension ActionKind {
    func validateNew(limits: RulesLimits, index: Int) throws {
        func fail(_ code: RuleValidationError.Code) -> RuleValidationError {
            RuleValidationError(code: code, field: .action(index: index))
        }
        switch self {
        case .modifyURL(let edit): try Self.validate(edit, limits: limits, fail: fail)
        case .modifyQuery(let edit): try Self.validate(edit.operations, limits: limits, fail: fail)
        case .editCookies(_, let operations): try Self.validate(operations, limits: limits, fail: fail)
        case .delay(let milliseconds):
            guard (0...limits.delayMillisecondsMax).contains(milliseconds) else { throw fail(.invalidDelay) }
        case .returnHandwritten(let response):
            switch response.parse(limits: limits) {
            case .success: return
            case .failure(.tooLarge): throw fail(.handwrittenResponseTooLarge)
            case .failure: throw fail(.invalidHandwrittenResponse)
            }
        case .returnPreset(let preset):
            if (preset.body?.utf8.count ?? 0) > limits.handwrittenResponseBytes {
                throw fail(.handwrittenResponseTooLarge)
            }
            if (preset.location?.utf8.count ?? 0) > limits.fieldBytes
                || (preset.challenge?.utf8.count ?? 0) > limits.fieldBytes
            {
                throw fail(.invalidPresetField)
            }
            switch preset.build() {
            case .success: return
            case .failure(.locationRequired): throw fail(.presetNeedsLocation)
            case .failure: throw fail(.invalidPresetField)
            }
        case .editHeaders(_, let operations): try Self.validate(operations, limits: limits, fail: fail)
        case .returnFile, .returnDirectory, .mapRemote, .breakpoint, .rewriteBody, .rewriteStatus,
            .mark, .comment, .hide, .closeConnection, .returnConnectTunnel, .noDecrypt, .magicString:
            return
        }
    }

    private static let operationLimit = 64

    private static func checkFind(
        _ find: String, limits: RulesLimits, fail: (RuleValidationError.Code) -> RuleValidationError
    ) throws {
        guard !find.isEmpty else { throw fail(.emptyEditFind) }
        guard find.utf8.count <= limits.fieldBytes else { throw fail(.findTooLong) }
    }

    private static func checkLength(
        _ texts: String..., limits: RulesLimits, fail: (RuleValidationError.Code) -> RuleValidationError
    ) throws {
        if texts.contains(where: { $0.utf8.count > limits.fieldBytes }) { throw fail(.fieldTooLong) }
    }

    /// A regular expression that the `.find` mode compiles, with the codes the condition rows use.
    private static func checkRegex(
        _ pattern: String, caseSensitive: Bool, fail: (RuleValidationError.Code) -> RuleValidationError
    ) throws {
        do {
            _ = try RegexPattern(pattern, mode: .find, caseInsensitive: !caseSensitive)
        } catch PatternError.regexTooComplex {
            throw fail(.regexTooComplex)
        } catch PatternError.tooLong {
            throw fail(.findTooLong)
        } catch {
            throw fail(.invalidRegex)
        }
    }

    private static func validate(
        _ edit: URLEditAction, limits: RulesLimits, fail: (RuleValidationError.Code) -> RuleValidationError
    ) throws {
        switch edit.mode {
        case .append:
            try checkLength(edit.replacement, limits: limits, fail: fail)
        case .set:
            guard edit.replacement.utf8.count <= limits.fieldBytes else { throw fail(.fieldTooLong) }
            guard URLEditing.parse(edit.replacement, method: "GET") != nil else { throw fail(.invalidURLEdit) }
        case .findReplace:
            try checkFind(edit.find, limits: limits, fail: fail)
            try checkLength(edit.replacement, limits: limits, fail: fail)
        case .regex:
            try checkFind(edit.find, limits: limits, fail: fail)
            try checkLength(edit.replacement, limits: limits, fail: fail)
            try checkRegex(edit.find, caseSensitive: edit.caseSensitive, fail: fail)
        }
    }

    private static func validate(
        _ operations: [QueryEdit], limits: RulesLimits, fail: (RuleValidationError.Code) -> RuleValidationError
    ) throws {
        guard !operations.isEmpty, operations.count <= operationLimit else { throw fail(.invalidQueryEdit) }
        // A name is split from its value at `=` and parameters at `&`; a value may hold `=` but not `&`.
        func nameOK(_ name: String) -> Bool {
            !name.isEmpty && QueryEditing.isValidComponent(name) && !name.utf8.contains { $0 == 38 || $0 == 61 }
        }
        func valueOK(_ value: String) -> Bool {
            QueryEditing.isValidComponent(value) && !value.utf8.contains(38)
        }
        for operation in operations {
            switch operation {
            case .add(let name, let value, _), .addIfMissing(let name, let value, _):
                try checkLength(name, value, limits: limits, fail: fail)
                guard nameOK(name), valueOK(value) else { throw fail(.invalidQueryEdit) }
            case .set(let name, let value, _):
                // An empty name is "all keys".
                try checkLength(name, value, limits: limits, fail: fail)
                guard name.isEmpty || nameOK(name), valueOK(value) else { throw fail(.invalidQueryEdit) }
            case .remove(let name, _):
                try checkLength(name, limits: limits, fail: fail)
                guard name.isEmpty || nameOK(name) else { throw fail(.invalidQueryEdit) }
            case .appendToValue(let name, let text, _):
                try checkLength(name, text, limits: limits, fail: fail)
                guard name.isEmpty || nameOK(name), valueOK(text) else { throw fail(.invalidQueryEdit) }
            case .findReplace(let name, let find, let replacement, _, _):
                try checkFind(find, limits: limits, fail: fail)
                try checkLength(name ?? "", replacement, limits: limits, fail: fail)
                if let name, !name.isEmpty, !nameOK(name) { throw fail(.invalidQueryEdit) }
                guard valueOK(replacement) else { throw fail(.invalidQueryEdit) }
            case .regex(let name, let pattern, let replacement, let caseSensitive, _):
                try checkFind(pattern, limits: limits, fail: fail)
                try checkLength(name ?? "", replacement, limits: limits, fail: fail)
                try checkRegex(pattern, caseSensitive: caseSensitive, fail: fail)
                if let name, !name.isEmpty, !nameOK(name) { throw fail(.invalidQueryEdit) }
                // A template may hold `$1` and the like; the text it produces is not known here.
                guard valueOK(replacement) else { throw fail(.invalidQueryEdit) }
            }
        }
    }

    /// The names and values of header edits are checked by the shared header validator; what is new is
    /// the find text and the regular expression of the look-up methods.
    private static func validate(
        _ operations: [HeaderEdit], limits: RulesLimits, fail: (RuleValidationError.Code) -> RuleValidationError
    ) throws {
        for operation in operations {
            switch operation {
            case .findReplace(_, let find, let replacement, _, _):
                try checkFind(find, limits: limits, fail: fail)
                try checkLength(replacement, limits: limits, fail: fail)
            case .regex(_, let pattern, let replacement, let caseSensitive, _):
                try checkFind(pattern, limits: limits, fail: fail)
                try checkLength(replacement, limits: limits, fail: fail)
                try checkRegex(pattern, caseSensitive: caseSensitive, fail: fail)
            case .set, .append, .remove, .addIfMissing, .appendToValue:
                continue
            }
        }
    }

    private static func validate(
        _ operations: [CookieEdit], limits: RulesLimits, fail: (RuleValidationError.Code) -> RuleValidationError
    ) throws {
        guard !operations.isEmpty, operations.count <= operationLimit else { throw fail(.invalidCookieEdit) }
        // Attributes are not written here, so `;` has no place in a value; the name is a cookie-name token.
        func nameOK(_ name: String) -> Bool {
            !name.isEmpty
                && name.utf8.allSatisfy { $0 > 32 && $0 != 127 && $0 != 61 && $0 != 59 && $0 != 44 }
        }
        func valueOK(_ value: String) -> Bool {
            HTTPMutationValidator.isValidValue(value) && !value.utf8.contains(59)
        }
        for operation in operations {
            switch operation {
            case .addIfMissing(let name, let value, _):
                try checkLength(name, value, limits: limits, fail: fail)
                guard nameOK(name), valueOK(value) else { throw fail(.invalidCookieEdit) }
            case .set(let name, let value, _):
                // An empty name is "all keys".
                try checkLength(name, value, limits: limits, fail: fail)
                guard name.isEmpty || nameOK(name), valueOK(value) else { throw fail(.invalidCookieEdit) }
            case .remove(let name, _):
                try checkLength(name, limits: limits, fail: fail)
                guard name.isEmpty || nameOK(name) else { throw fail(.invalidCookieEdit) }
            case .appendToValue(let name, let text, _):
                try checkLength(name, text, limits: limits, fail: fail)
                guard name.isEmpty || nameOK(name), valueOK(text) else { throw fail(.invalidCookieEdit) }
            case .findReplace(let name, let find, let replacement, _, _):
                try checkFind(find, limits: limits, fail: fail)
                try checkLength(name ?? "", replacement, limits: limits, fail: fail)
                if let name, !name.isEmpty, !nameOK(name) { throw fail(.invalidCookieEdit) }
                guard valueOK(replacement) else { throw fail(.invalidCookieEdit) }
            case .regex(let name, let pattern, let replacement, let caseSensitive, _):
                try checkFind(pattern, limits: limits, fail: fail)
                try checkLength(name ?? "", replacement, limits: limits, fail: fail)
                try checkRegex(pattern, caseSensitive: caseSensitive, fail: fail)
                if let name, !name.isEmpty, !nameOK(name) { throw fail(.invalidCookieEdit) }
                guard valueOK(replacement) else { throw fail(.invalidCookieEdit) }
            }
        }
    }
}

extension Rule {
    /// A rule with a connect-only action (no decrypt, CONNECT tunnel) runs at the CONNECT line, where
    /// only facts known then are available and only the actions that can run there make sense.
    func validateConnectOnly() throws {
        guard actions.contains(where: { $0.kind.isConnectOnly }) else { return }
        let whitelist: Set<ConditionField> = [.allSessions, .url, .scheme, .host, .port, .clientIP, .clientApp]
        guard conditions.judgmentPoint == .connect, conditions.rows.allSatisfy({ whitelist.contains($0.field) }) else {
            throw RuleValidationError(code: .connectActionCondition, field: .conditions)
        }
        if let index = actions.firstIndex(where: { !$0.kind.canRunAtConnect }) {
            throw RuleValidationError(code: .connectActionMixed, field: .action(index: index))
        }
    }

    /// Compiles the regular expressions of the URL, header and cookie edits; one that does not compile is
    /// skipped (validation refuses it before it gets here).
    func prepareEditPatterns(in cache: PatternCache) {
        for regex in editRegexes {
            try? cache.prepareRegex(regex.pattern, mode: .find, caseInsensitive: regex.caseInsensitive)
        }
    }

    /// Every regular expression the URL, header and cookie edits compile, with its case flag. The one
    /// place that lists them: `prepareEditPatterns` compiles these and the provider compares them.
    var editRegexes: [EditRegex] {
        var result: [EditRegex] = []
        for action in actions {
            switch action.kind {
            case .modifyURL(let edit) where edit.mode == .regex:
                result.append(EditRegex(pattern: edit.find, caseInsensitive: !edit.caseSensitive))
            case .modifyQuery(let edit):
                for case .regex(_, let pattern, _, let caseSensitive, _) in edit.operations {
                    result.append(EditRegex(pattern: pattern, caseInsensitive: !caseSensitive))
                }
            case .editCookies(_, let operations):
                for case .regex(_, let pattern, _, let caseSensitive, _) in operations {
                    result.append(EditRegex(pattern: pattern, caseInsensitive: !caseSensitive))
                }
            case .editHeaders(_, let operations):
                for case .regex(_, let pattern, _, let caseSensitive, _) in operations {
                    result.append(EditRegex(pattern: pattern, caseInsensitive: !caseSensitive))
                }
            default:
                continue
            }
        }
        return result
    }
}

struct EditRegex: Hashable {
    var pattern: String
    var caseInsensitive: Bool
}
