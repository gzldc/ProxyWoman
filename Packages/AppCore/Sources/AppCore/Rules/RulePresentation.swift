import FlowStore
import Foundation
import Localization
import RulesEngine

/// One line of the detail pane's rule results.
public struct RuleResultLine: Equatable, Sendable {
    public enum Tone: Sendable { case applied, attention }
    public var text: String
    public var tone: Tone

    public init(text: String, tone: Tone) {
        self.text = text
        self.tone = tone
    }
}

/// The card number (0-based) an outcome of `rule`'s stored action `stored` is shown against, by the outcome's code; nil keeps
/// the stored number (a rule that no longer exists, or an action the rule does not have).
public typealias OutcomeCardIndex = (UUID, Int, RuleOutcomeCode) -> Int?

/// Text shown for rules in the list. Captured values (host, path, method) are shown verbatim.
public enum RulePresentation {
    /// `GET https://*.a.test:8443/api?*`: method, scheme, host, port and path+query (`*` = any,
    /// a trailing `*` = prefix), plus the status range of response rules.
    public static func matchSummary(_ matcher: RuleMatcher, localizer: Localizer = L10n.localizer) -> String {
        if matcher == RuleMatcher() { return localizer.string("rules.summary.anyRequest") }
        let path: String
        switch matcher.path {
        case .any: path = "/*"
        case .exact(let value): path = value
        case .prefix(let value): path = value + "*"
        case .wildcard(let value), .regex(let value): path = value
        }
        let base = (matcher.method.map { $0 + " " } ?? "") + (matcher.scheme ?? "*") + "://" + (matcher.hostPattern ?? "*")
            + (matcher.port.map { ":\($0)" } ?? "") + path
        var summary = base
        if let range = matcher.statusRange {
            summary = localizer.format("rules.summary.withStatus", arguments: [base, range.lowerBound, range.upperBound])
        }
        guard let label = syntaxLabel(matcher, localizer: localizer) else { return summary }
        return localizer.format("rules.summary.withSyntax", arguments: [summary, label])
    }

    /// The Match column of a rule. A rule the old editor can state shows its fixed fields as `matchSummary`
    /// does, followed by how they combine when that is not "all". Any other rule only counts its conditions.
    public static func matchSummary(of rule: Rule, localizer: Localizer = L10n.localizer) -> String {
        let fields: (matcher: RuleMatcher, mode: ConditionGroup.Mode)
        switch rule.oldEditorForm {
        case .legacy(let simple): fields = (simple.matcher, simple.mode)
        case .annotation(let annotation): fields = (annotation.matcher, annotation.mode)
        case nil:
            // A row on a field added in Rules 2.0 has words of its own; rules of the old fields only count theirs.
            let usesNewFields = rule.conditions.rows.contains { if case .current = $0.evaluationPath { true } else { false } }
            guard usesNewFields else {
                return localizer.format("rules.summary.conditionsCount", arguments: [rule.conditions.rows.count])
            }
            return ConditionPresentation.summary(rule.conditions, localizer: localizer)
        }
        let summary = matchSummary(fields.matcher, localizer: localizer)
        // Without a field every mode matches every request, so there is no combination to tell.
        guard fields.matcher != RuleMatcher() else { return summary }
        switch fields.mode {
        case .all: return summary
        case .any: return localizer.format("rules.summary.modeAny", arguments: [summary])
        case .none: return localizer.format("rules.summary.modeNone", arguments: [summary])
        }
    }

    /// The Type column: what the action is called, or "multiple actions" for a rule the old editor cannot state.
    public static func kindTitle(of rule: Rule, localizer: Localizer = L10n.localizer) -> String {
        localizer.string(RuleKind(rule)?.localizationKey ?? "rules.kind.multiple")
    }

    /// The list line of a rule: its match summary, and for a directory rule where the prefix leads to.
    public static func summary(of rule: Rule, localizer: Localizer = L10n.localizer) -> String {
        let match = matchSummary(of: rule, localizer: localizer)
        switch rule.simple?.action {
        case .mapLocalDirectory(let directory):
            return localizer.format("rules.summary.directory", arguments: [match, directory.displayName])
        case .rewriteBody(let direction, let rewrite):
            // Each side has its own sentence so a language phrases the whole line, not a word dropped into it.
            let key = direction == .request ? "rules.summary.rewriteBody.request" : "rules.summary.rewriteBody.response"
            return localizer.format(key, arguments: [match, shortened(rewrite.find), shortened(rewrite.replacement)])
        case .rewriteStatus(let rewrite):
            return localizer.format("rules.summary.rewriteStatus", arguments: [match, rewrite.status])
        case .mapLocal, .mapRemote, .editHeaders, .breakpoint, .none:
            return match
        }
    }

    /// The Action column: what the rule does, without the match (which has its own column). Captured
    /// and typed values (file, host, find text) are shown verbatim. `assetName` is the saved file's
    /// display name; nil when the model no longer knows the file.
    public static func actionSummary(
        of rule: Rule, assetName: (UUID) -> String?, localizer: Localizer = L10n.localizer
    ) -> String {
        // Only a count: what each of several actions does is for the new editor.
        if rule.actions.count == 1, let only = rule.actions.first, let text = r4ActionSummary(only.kind, localizer: localizer) {
            return text
        }
        if let annotation = rule.simpleAnnotation { return annotationSummary(annotation.kind, localizer: localizer) }
        guard let action = rule.simple?.action else {
            return localizer.format("rules.summary.multiAction", arguments: [rule.actions.count])
        }
        switch action {
        case .mapLocal(let action):
            let name = assetName(action.assetID) ?? localizer.string("rules.actionSummary.assetUnknown")
            return localizer.format("rules.actionSummary.mapLocal", arguments: [name, action.status])
        case .mapLocalDirectory(let action):
            return localizer.format("rules.actionSummary.mapLocalDirectory", arguments: [action.displayName])
        case .mapRemote(let action):
            var target = "\(action.targetScheme)://\(action.targetHost):\(action.targetPort)"
            if case .replace(let path) = action.path { target += path }
            return localizer.format("rules.actionSummary.mapRemote", arguments: [target])
        case .editHeaders(let direction, let operations):
            return localizer.format(editHeadersKey(direction), arguments: [operations.count])
        case .breakpoint(let direction, let mode):
            let key =
                switch (mode == .fullBody, direction) {
                case (true, .request): "rules.actionSummary.breakpointFullBody.request"
                case (true, .response): "rules.actionSummary.breakpointFullBody.response"
                case (false, .request): "rules.actionSummary.breakpoint.request"
                case (false, .response): "rules.actionSummary.breakpoint.response"
                }
            return localizer.string(key)
        case .rewriteBody(let direction, let rewrite):
            let key = direction == .request ? "rules.actionSummary.rewriteBody.request" : "rules.actionSummary.rewriteBody.response"
            return localizer.format(key, arguments: [shortened(rewrite.find), shortened(rewrite.replacement)])
        case .rewriteStatus(let rewrite):
            return localizer.format("rules.actionSummary.rewriteStatus", arguments: [rewrite.status])
        }
    }

    /// What one new action (Rules 2.0 R4) does, in a sentence. Nil for the older actions, which the rule
    /// summary states from the whole rule.
    public static func actionSummary(of kind: ActionKind, localizer: Localizer = L10n.localizer) -> String? {
        r4ActionSummary(kind, localizer: localizer)
    }

    private static func r4ActionSummary(_ kind: ActionKind, localizer: Localizer) -> String? {
        switch kind {
        case .modifyURL(let edit):
            switch edit.mode {
            case .set: return localizer.format("rules.actionSummary.modifyURL.set", arguments: [shortened(edit.replacement)])
            case .findReplace:
                return localizer.format(
                    "rules.actionSummary.modifyURL.findReplace",
                    arguments: [shortened(edit.find), shortened(edit.replacement)])
            case .regex: return localizer.format("rules.actionSummary.modifyURL.regex", arguments: [shortened(edit.find)])
            case .append: return localizer.format("rules.actionSummary.modifyURL.append", arguments: [shortened(edit.replacement)])
            }
        case .modifyQuery(let edit):
            return localizer.format("rules.actionSummary.modifyQuery", arguments: [edit.operations.count])
        case .editCookies(let direction, let operations):
            let key = direction == .request ? "rules.actionSummary.editCookies.request" : "rules.actionSummary.editCookies.response"
            return localizer.format(key, arguments: [operations.count])
        case .delay(let milliseconds):
            return localizer.format("rules.actionSummary.delay", arguments: [milliseconds])
        case .returnHandwritten(let response):
            return localizer.format("rules.actionSummary.returnHandwritten", arguments: [handwrittenStatus(response.text)])
        case .returnPreset(let response):
            return localizer.format("rules.actionSummary.returnPreset", arguments: [presetName(response.preset, localizer: localizer)])
        case .closeConnection(let mode):
            let key = mode == .graceful ? "rules.actionSummary.closeConnection.graceful" : "rules.actionSummary.closeConnection.reset"
            return localizer.string(key)
        case .returnConnectTunnel: return localizer.string("rules.actionSummary.returnConnectTunnel")
        case .magicString(let text): return localizer.format("rules.actionSummary.magicString", arguments: [shortened(text)])
        case .noDecrypt: return localizer.string("rules.actionSummary.noDecrypt")
        case .editHeaders(let direction, let operations):
            // Rules with only the old methods keep the old summary below; the same sentence names the new ones.
            let hasNewMethod = operations.contains { operation in
                switch operation {
                case .set, .append, .remove: false
                case .addIfMissing, .appendToValue, .findReplace, .regex: true
                }
            }
            guard hasNewMethod else { return nil }
            return localizer.format(editHeadersKey(direction), arguments: [operations.count])
        case .rewriteBody(_, let rewrite):
            switch rewrite.operation {
            case .findReplace: return nil
            case .setValue:
                return localizer.format("rules.actionSummary.rewriteBody.setValue", arguments: [shortened(rewrite.replacement)])
            case .clear: return localizer.string("rules.actionSummary.rewriteBody.clear")
            }
        case .returnFile, .returnDirectory, .mapRemote, .breakpoint, .rewriteStatus, .mark, .comment, .hide:
            return nil
        }
    }

    private static func editHeadersKey(_ direction: HTTPMessageDirection) -> String {
        direction == .request ? "rules.actionSummary.editHeaders.request" : "rules.actionSummary.editHeaders.response"
    }

    /// The status code on the first line of a handwritten response (`HTTP/1.1 404 Not Found`); 0 when it has none.
    private static func handwrittenStatus(_ text: String) -> Int {
        let firstLine = text.prefix { $0 != "\r" && $0 != "\n" }
        let fields = firstLine.split(separator: " ", omittingEmptySubsequences: true)
        return fields.count >= 2 ? Int(fields[1]) ?? 0 : 0
    }

    private static func presetName(_ preset: PresetResponse.Preset, localizer: Localizer) -> String {
        switch preset {
        case .emptyHTML200: localizer.string("rules.preset.emptyHTML200")
        case .gif200: localizer.string("rules.preset.gif200")
        case .noContent204: localizer.string("rules.preset.noContent204")
        case .movedPermanently301: localizer.string("rules.preset.movedPermanently301")
        case .found302: localizer.string("rules.preset.found302")
        case .seeOther303: localizer.string("rules.preset.seeOther303")
        case .notModified304: localizer.string("rules.preset.notModified304")
        case .temporaryRedirect307: localizer.string("rules.preset.temporaryRedirect307")
        case .permanentRedirect308: localizer.string("rules.preset.permanentRedirect308")
        case .badRequest400: localizer.string("rules.preset.badRequest400")
        case .unauthorized401: localizer.string("rules.preset.unauthorized401")
        case .forbidden403: localizer.string("rules.preset.forbidden403")
        case .notFound404: localizer.string("rules.preset.notFound404")
        case .proxyAuthRequired407: localizer.string("rules.preset.proxyAuthRequired407")
        case .tooManyRequests429: localizer.string("rules.preset.tooManyRequests429")
        case .internalError500: localizer.string("rules.preset.internalError500")
        case .serviceUnavailable503: localizer.string("rules.preset.serviceUnavailable503")
        case .transparentPixel200: localizer.string("rules.preset.transparentPixel200")
        case .digestAuth401: localizer.string("rules.preset.digestAuth401")
        case .unreachable502: localizer.string("rules.preset.unreachable502")
        }
    }

    private static func annotationSummary(_ kind: ActionKind, localizer: Localizer) -> String {
        switch kind {
        case .mark(let mark):
            let color = FlowAnnotationPresentation.colourName(forHex: mark.background, localizer: localizer)
            guard let text = mark.text else { return localizer.format("rules.actionSummary.mark", arguments: [color]) }
            return localizer.format("rules.actionSummary.markText", arguments: [color, shortened(text)])
        case .comment(let comment):
            switch comment.mode {
            case .set: return localizer.format("rules.actionSummary.comment.set", arguments: [shortened(comment.text)])
            case .append: return localizer.format("rules.actionSummary.comment.append", arguments: [shortened(comment.text)])
            case .findReplace:
                return localizer.format(
                    "rules.actionSummary.comment.findReplace", arguments: [shortened(comment.text), shortened(comment.replacement)])
            case .clear: return localizer.string("rules.actionSummary.comment.clear")
            case .addIfMissing: return localizer.format("rules.actionSummary.comment.set", arguments: [shortened(comment.text)])
            case .regex:
                return localizer.format(
                    "rules.actionSummary.comment.findReplace", arguments: [shortened(comment.text), shortened(comment.replacement)])
            }
        default:
            return localizer.string("rules.actionSummary.hide")
        }
    }

    /// The Match and Action cells of the unsaved draft's row. Both come from one validation result (the
    /// caller validates once); an invalid draft shows empty cells, its issues are in the form.
    public static func draftRowSummary(
        _ validation: RuleDraftValidation, assetName: (UUID) -> String?, localizer: Localizer = L10n.localizer
    ) -> (matching: String, action: String) {
        guard let rule = validation.rule else { return ("", "") }
        return (matchSummary(of: rule, localizer: localizer), actionSummary(of: rule, assetName: assetName, localizer: localizer))
    }

    /// The texts a rule row shows, for the table's filter field.
    public static func searchFields(
        of rule: Rule, assetName: (UUID) -> String?, localizer: Localizer = L10n.localizer
    ) -> [String] {
        [
            displayName(rule.name, localizer: localizer), kindTitle(of: rule, localizer: localizer),
            matchSummary(of: rule, localizer: localizer), actionSummary(of: rule, assetName: assetName, localizer: localizer),
        ]
    }

    /// Find and replacement texts are shown whole up to this many characters.
    private static let summaryTextLimit = 40

    private static func shortened(_ text: String) -> String {
        text.count > summaryTextLimit ? String(text.prefix(summaryTextLimit)) + "…" : text
    }

    /// The host's syntax when it is not literal, else the path's; nil for a literal matcher.
    private static func syntaxLabel(_ matcher: RuleMatcher, localizer: Localizer) -> String? {
        let syntax: PatternSyntax
        switch (matcher.hostSyntax, matcher.path) {
        case (.literal, .wildcard): syntax = .wildcard
        case (.literal, .regex): syntax = .regex
        case (.literal, _): return nil
        case (let host, _): syntax = host
        }
        switch syntax {
        case .literal: return nil
        case .wildcard: return localizer.string("rules.summary.syntaxWildcard")
        case .regex: return localizer.string("rules.summary.syntaxRegex")
        }
    }

    /// A user-visible name; unnamed rules get a localized placeholder (never saved).
    public static func displayName(_ name: String, localizer: Localizer = L10n.localizer) -> String {
        name.trimmingCharacters(in: .whitespaces).isEmpty ? localizer.string("rules.list.unnamed") : name
    }

    /// One line per rule whose regular expression timed out or is switched off on this flow
    /// (once per rule and kind, even when both the request and the response were evaluated).
    /// `ruleName` is nil for a rule that no longer exists.
    public static func patternProblemLines(
        _ matches: RuleMatchSummary?, ruleName: (UUID) -> String?, localizer: Localizer = L10n.localizer
    ) -> [String] {
        outcomeLines(matches, ruleName: ruleName, localizer: localizer, codes: [.patternTimedOut, .patternDisabled])
    }

    /// One sentence per rule and outcome the user may wonder about: a regular expression that timed out
    /// or is switched off, a body rewrite that found nothing or was skipped, a status rewrite skipped on a
    /// local response, a final action that cut off what came after it, a hit outside the rule's occurrence
    /// range. Once per rule, kind and action, in the order they happened. `ruleName` is nil for a rule that
    /// no longer exists.
    /// `cardIndex` maps a rule and the stored action index of an outcome to the 0-based number to show; the default shows
    /// the stored index. A rule open in the editor passes its document's `cardIndex(forStoredAction:)` so "action N"
    /// names the card the person sees.
    public static func outcomeLines(
        _ matches: RuleMatchSummary?, ruleName: (UUID) -> String?, localizer: Localizer = L10n.localizer,
        cardIndex: OutcomeCardIndex? = nil
    ) -> [String] {
        outcomeLines(matches, ruleName: ruleName, localizer: localizer, codes: Set(outcomeKeys.keys), cardIndex: cardIndex)
    }

    /// One line per outcome of this flow, in the order they happened and once each: the rules that were
    /// applied, then everything `outcomeLines` explains plus a rejected edit and an action that does not
    /// fit a protocol upgrade. Codes without a sentence (such as breakpoint framing notes) are left out.
    /// `ruleName` is nil for a rule that no longer exists.
    public static func resultLines(
        _ matches: RuleMatchSummary?, ruleName: (UUID) -> String?, localizer: Localizer = L10n.localizer,
        cardIndex: OutcomeCardIndex? = nil
    ) -> [RuleResultLine] {
        var seen: Set<RuleOutcome> = []
        var lines: [RuleResultLine] = []
        for outcome in matches?.outcomes ?? [] where seen.insert(outcome).inserted {
            let name = ruleName(outcome.ruleID).map { displayName($0, localizer: localizer) }
                ?? localizer.string("ruleOutcome.unknownRule")
            if outcome.code == .applied {
                let line = outcome.actionIndex.map {
                    localizer.format("ruleOutcome.appliedAction", arguments: [name, shownIndex(outcome.ruleID, $0, outcome.code, cardIndex) + 1])
                } ?? localizer.format("ruleOutcome.applied", arguments: [name])
                lines.append(RuleResultLine(text: line, tone: .applied))
            } else if let key = outcomeKeys[outcome.code] {
                let arguments: [any CVarArg] = actionOutcomes.contains(outcome.code) ? [name, shownIndex(outcome.ruleID, outcome.actionIndex ?? 0, outcome.code, cardIndex) + 1] : [name]
                lines.append(RuleResultLine(text: localizer.format(key, arguments: arguments), tone: .attention))
            } else if let key = resultOnlyKeys[outcome.code] {
                lines.append(RuleResultLine(text: localizer.format(key, arguments: [name]), tone: .attention))
            }
        }
        return lines
    }

    private static let resultOnlyKeys: [RuleOutcomeCode: String] = [
        .rejected: "ruleOutcome.rejected",
        .unsupportedUpgradeAction: "ruleOutcome.unsupportedUpgradeAction",
    ]

    private static let outcomeKeys: [RuleOutcomeCode: String] = [
        .patternTimedOut: "ruleOutcome.patternTimedOut",
        .patternDisabled: "ruleOutcome.patternDisabled",
        .bodyNoMatch: "ruleOutcome.bodyNoMatch",
        .bodySkippedTooLarge: "ruleOutcome.bodySkippedTooLarge",
        .bodySkippedNotText: "ruleOutcome.bodySkippedNotText",
        .bodySkippedUndecodable: "ruleOutcome.bodySkippedUndecodable",
        .bodySkippedBreakpoint: "ruleOutcome.bodySkippedBreakpoint",
        .bodySkippedLocalRoute: "ruleOutcome.bodySkippedLocalRoute",
        .bodySkippedNoBody: "ruleOutcome.bodySkippedNoBody",
        .bodySkippedUnavailable: "ruleOutcome.bodySkippedUnavailable",
        .bodySkippedBusy: "ruleOutcome.bodySkippedBusy",
        .bodySkippedAborted: "ruleOutcome.bodySkippedAborted",
        .unknownSize: "ruleOutcome.unknownSize",
        .appUnknown: "ruleOutcome.appUnknown",
        .bodyTooLarge: "ruleOutcome.bodyTooLarge",
        .bodySkippedOnDisk: "ruleOutcome.bodySkippedOnDisk",
        .bodySkippedStreaming: "ruleOutcome.bodySkippedStreaming",
        .statusSkippedLocal: "ruleOutcome.statusSkippedLocal",
        .finalStop: "ruleOutcome.finalStop",
        .skippedAfterFinal: "ruleOutcome.skippedAfterFinal",
        .occurrenceSkipped: "ruleOutcome.occurrenceSkipped",
        .skippedByTool: "ruleOutcome.skippedByTool",
        .delayCapped: "ruleOutcome.delayCapped",
        .editNoMatch: "ruleOutcome.editNoMatch",
        .notApplicableOffline: "ruleOutcome.notApplicableOffline",
        .requestActionVisibleOnly: "ruleOutcome.requestActionVisibleOnly",
        .requestActionSkippedAtResponse: "ruleOutcome.requestActionSkippedAtResponse",
        .responseAlreadyLocal: "ruleOutcome.responseAlreadyLocal",
    ]

    /// The outcomes whose sentence names an action of the rule (1-based) after the rule's name.
    private static let actionOutcomes: Set<RuleOutcomeCode> = [
        .finalStop, .skippedAfterFinal, .requestActionVisibleOnly, .requestActionSkippedAtResponse, .responseAlreadyLocal,
    ]

    private static func outcomeLines(
        _ matches: RuleMatchSummary?, ruleName: (UUID) -> String?, localizer: Localizer, codes: Set<RuleOutcomeCode>,
        cardIndex: OutcomeCardIndex? = nil
    ) -> [String] {
        var seen: Set<RuleOutcome> = []
        var lines: [String] = []
        for outcome in matches?.outcomes ?? [] where seen.insert(outcome).inserted {
            guard codes.contains(outcome.code), let key = outcomeKeys[outcome.code] else { continue }
            let name = ruleName(outcome.ruleID).map { displayName($0, localizer: localizer) }
                ?? localizer.string("ruleOutcome.unknownRule")
            if actionOutcomes.contains(outcome.code) {
                // The engine always names the action of these; a record without one reads as the first.
                lines.append(localizer.format(key, arguments: [name, shownIndex(outcome.ruleID, outcome.actionIndex ?? 0, outcome.code, cardIndex) + 1]))
            } else {
                lines.append(localizer.format(key, arguments: [name]))
            }
        }
        return lines
    }

    private static func shownIndex(_ rule: UUID, _ stored: Int, _ code: RuleOutcomeCode, _ cardIndex: OutcomeCardIndex?) -> Int {
        cardIndex?(rule, stored, code) ?? stored
    }
}
