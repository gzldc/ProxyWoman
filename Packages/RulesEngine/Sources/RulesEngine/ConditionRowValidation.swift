import Foundation

extension ConditionRow {
    /// The one decision "is this row on the old path": a legacy field whose row R1 can read, whose value
    /// was meant as a port or status number, or that uses an old-style comparison. `evaluationPath` and
    /// validation both derive from it.
    var usesLegacyChecks: Bool {
        guard field.isLegacyField else { return false }
        if case .unsupported = legacyReading { return op.isLegacyOnly }
        return true
    }

    /// An old-path row the old matcher cannot interpret (an old-style comparison it cannot read, or an
    /// unreadable port / status value). R1 validation refuses it and evaluation never matches it; the
    /// evaluator must do the same instead of sending it to the new comparators.
    var isLegacyNeverMatching: Bool { usesLegacyChecks && legacyMatcher == nil }

    /// The checks of a row on the new path. Errors are reported on the row (`index`).
    func validateNew(limits: RulesLimits, index: Int = 0) throws {
        func fail(_ code: RuleValidationError.Code) -> RuleValidationError {
            RuleValidationError(code: code, field: .conditionRow(index: index))
        }
        let name = (self.name?.isEmpty ?? true) ? nil : self.name
        if field.takesName {
            if let name {
                guard name.utf8.count <= limits.fieldBytes else { throw fail(.fieldTooLong) }
                if let allowed = ConditionField.allowedNames(for: field), !allowed.contains(name) {
                    throw fail(.invalidConditionName)
                }
            } else if !field.nameIsOptional {
                throw fail(.conditionNameRequired)
            }
        } else if name != nil {
            throw fail(.unexpectedConditionName)
        }
        if field == .magicString {
            // The Classic match string takes no comparison: the stored one is ignored. An empty or unparseable
            // string, or a pattern that does not compile, is refused.
            guard value.utf8.count <= limits.fieldBytes else { throw fail(.fieldTooLong) }
            guard let condition = MagicStringCondition.parse(value) else { throw fail(.invalidConditionValue) }
            if let pattern = condition.regexPattern {
                do {
                    _ = try RegexPattern(pattern, mode: .find, caseInsensitive: true)
                } catch PatternError.regexTooComplex {
                    throw fail(.regexTooComplex)
                } catch PatternError.tooLong {
                    throw fail(.fieldTooLong)
                } catch {
                    throw fail(.invalidRegex)
                }
            }
            return
        }
        guard ConditionOperator.allowed(for: field, name: name).contains(op) else { throw fail(.invalidOperator) }
        if [.isEmpty, .isNotEmpty, .exists, .doesNotExist].contains(op) { return }
        guard value.utf8.count <= limits.fieldBytes else { throw fail(.fieldTooLong) }

        if op == .regex {
            do {
                _ = try RegexPattern(value, caseInsensitive: !caseSensitive)
            } catch PatternError.regexTooComplex {
                throw fail(.regexTooComplex)
            } catch PatternError.tooLong {
                throw fail(.fieldTooLong)
            } catch {
                throw fail(.invalidRegex)
            }
            return
        }
        switch field.valueKind(name: name) {
        case .none, .text:
            return
        case .number:
            // The result column also takes plain text comparisons.
            if field == .statusCode, [.contains, .startsWith].contains(op) { return }
            if op == .inRange {
                guard ConditionValues.numberRange(value) != nil else { throw fail(.invalidConditionValue) }
            } else {
                guard ConditionValues.wholeNumber(value) != nil else { throw fail(.invalidConditionValue) }
            }
        case .date:
            let valid =
                op == .inRange
                ? ConditionValues.dayRange(value, timeZone: .current) != nil
                : ConditionValues.day(value, timeZone: .current) != nil
            guard valid else { throw fail(.invalidConditionValue) }
        case .bool:
            guard value == "true" || value == "false" else { throw fail(.invalidConditionValue) }
        case .choice:
            let accepted = field.acceptedChoices(name: name)
            if field == .scheme {
                guard accepted.contains(value.lowercased()) else {
                    throw RuleValidationError(code: .invalidScheme, field: .scheme)
                }
            } else {
                // Case-insensitive, like `knowablePoint`'s reading of `sse`.
                guard accepted.contains(value.lowercased()) else { throw fail(.invalidConditionValue) }
            }
        }
    }
}

extension ConditionRow {
    /// What `Rule.validate` says about this row, or nil when it is fine: the old checks for a row on the old
    /// path, the new ones otherwise. `index` names the row in the error's field.
    public func validationIssue(limits: RulesLimits, index: Int = 0) -> RuleValidationError? {
        do {
            if usesLegacyChecks {
                try validate(limits: limits)
            } else {
                try validateNew(limits: limits, index: index)
            }
            return nil
        } catch let error as RuleValidationError {
            return error
        } catch {
            return RuleValidationError(code: .invalidOperator, field: .conditionRow(index: index))
        }
    }
}
