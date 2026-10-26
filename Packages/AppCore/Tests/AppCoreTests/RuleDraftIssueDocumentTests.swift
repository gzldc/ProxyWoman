import Localization
import RulesEngine
import Testing

@testable import AppCore

/// Every code of the engine, listed through a `switch` so a new code fails to compile here until it is placed.
private let allCodes: [RuleValidationError.Code] = {
    let seed: [RuleValidationError.Code] = [
        .fieldTooLong, .invalidScheme, .invalidHostPattern, .invalidPort, .invalidMethod, .invalidPath,
        .invalidStatusRange, .statusRangeNotAllowed, .invalidStatus, .invalidTarget, .invalidHeaderEdit,
        .invalidWildcard, .invalidRegex, .regexTooComplex, .invalidDirectory, .directoryNeedsPrefix, .emptyFind,
        .findTooLong, .invalidOperator, .tooManyConditions, .tooManyActions, .noActions,
        .actionNotAllowedAtJudgmentPoint, .tooManyRules, .groupTooDeep, .unknownGroup, .groupCycle, .duplicateID,
        .invalidMarkColor, .markTextTooLong, .emptyComment, .emptyCommentFind, .commentTooLong,
        .conditionNameRequired, .unexpectedConditionName, .invalidConditionName, .invalidConditionValue,
        .actionNotAllowedAtCompletion, .invalidURLEdit, .invalidQueryEdit, .invalidCookieEdit, .emptyEditFind,
        .invalidDelay, .invalidHandwrittenResponse, .handwrittenResponseTooLarge, .presetNeedsLocation,
        .invalidPresetField, .connectActionCondition, .connectActionMixed, .invalidMagicString,
    ]
    for code in seed {
        switch code {  // exhaustive on purpose
        case .fieldTooLong, .invalidScheme, .invalidHostPattern, .invalidPort, .invalidMethod, .invalidPath,
            .invalidStatusRange, .statusRangeNotAllowed, .invalidStatus, .invalidTarget, .invalidHeaderEdit,
            .invalidWildcard, .invalidRegex, .regexTooComplex, .invalidDirectory, .directoryNeedsPrefix, .emptyFind,
            .findTooLong, .invalidOperator, .tooManyConditions, .tooManyActions, .noActions,
            .actionNotAllowedAtJudgmentPoint, .tooManyRules, .groupTooDeep, .unknownGroup, .groupCycle, .duplicateID,
            .invalidMarkColor, .markTextTooLong, .emptyComment, .emptyCommentFind, .commentTooLong,
            .conditionNameRequired, .unexpectedConditionName, .invalidConditionName, .invalidConditionValue,
            .actionNotAllowedAtCompletion, .invalidURLEdit, .invalidQueryEdit, .invalidCookieEdit, .emptyEditFind,
            .invalidDelay, .invalidHandwrittenResponse, .handwrittenResponseTooLarge, .presetNeedsLocation,
            .invalidPresetField, .connectActionCondition, .connectActionMixed, .invalidMagicString:
            break
        }
    }
    return seed
}()

@Suite(.productionChinese) struct RuleDraftIssueDocumentTests {
    @Test func everyEngineCodeMapsToANonStructureIssueForDocuments() {
        let structural: Set<RuleValidationError.Code> = [.unknownGroup, .groupCycle, .duplicateID, .tooManyRules, .groupTooDeep]
        for code in allCodes {
            let issue = RuleDraftIssue(documentError: RuleValidationError(code: code, field: .conditions))
            if structural.contains(code) {
                #expect(issue == .unsupportedStructure, "\(code)")
            } else {
                #expect(issue != .unsupportedStructure, "\(code)")
            }
        }
        func map(_ code: RuleValidationError.Code) -> RuleDraftIssue {
            RuleDraftIssue(documentError: RuleValidationError(code: code, field: .conditions))
        }
        #expect(map(.invalidOperator) == .invalidOperator)
        #expect(map(.tooManyConditions) == .tooManyConditions)
        #expect(map(.tooManyActions) == .tooManyActions)
        #expect(map(.noActions) == .noActions)
        #expect(map(.actionNotAllowedAtJudgmentPoint) == .actionNotAllowedAtResponsePoint)
        #expect(map(.actionNotAllowedAtCompletion) == .actionNotAllowedAtCompletionPoint)
        #expect(map(.conditionNameRequired) == .conditionNameRequired)
        #expect(map(.unexpectedConditionName) == .unexpectedConditionName)
        #expect(map(.invalidConditionName) == .invalidConditionName)
        #expect(map(.invalidConditionValue) == .invalidConditionValue)
        #expect(map(.invalidRegex) == .invalidRegex)
    }

    @Test func oldInitStillMapsJudgmentPointToStatusRange() {
        #expect(RuleDraftIssue(RuleValidationError(code: .actionNotAllowedAtJudgmentPoint, field: .action(index: 0))) == .statusRangeNotAllowed)
        #expect(RuleDraftIssue(RuleValidationError(code: .invalidOperator, field: .conditions)) == .unsupportedStructure)
        #expect(RuleDraftIssue(RuleValidationError(code: .noActions, field: .conditions)) == .unsupportedStructure)
    }

    @Test func everyIssueHasALocalizedMessage() {
        let zh = Localizer(bundle: L10n.bundle, preferredLanguages: ["zh-Hans"])
        let limits = RulesLimits()
        for issue in RuleDraftIssue.allCases {
            let message = issue.message(limits: limits, localizer: zh)
            #expect(!message.isEmpty && message != issue.localizationKey && !message.contains("%"), "\(issue)")
        }
        #expect(RuleDraftIssue.tooManyConditions.message(limits: limits, localizer: zh).contains("32"))
        #expect(RuleDraftIssue.tooManyActions.message(limits: limits, localizer: zh).contains("16"))
    }

    @Test func newIssuesUseCaseNamesAsRawValues() {
        let names = [
            "invalidOperator", "tooManyConditions", "tooManyActions", "noActions", "actionNotAllowedAtResponsePoint",
            "actionNotAllowedAtCompletionPoint", "conditionNameRequired", "unexpectedConditionName",
            "invalidConditionName", "invalidConditionValue",
        ]
        for name in names { #expect(RuleDraftIssue(rawValue: name)?.rawValue == name) }
    }
}
