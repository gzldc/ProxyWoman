import FlowStore
import RulesEngine

/// The kinds of action the editor offers, one per entry of the action menu. The two ways of closing a connection are two
/// types, although a rule stores them as one kind with a mode.
public enum ActionType: String, CaseIterable, Sendable, Identifiable, Hashable {
    case modifyURL, modifyQuery, editRequestHeaders, editRequestCookies, rewriteRequestBody, mapRemote, requestBreakpoint, delay
    case rewriteStatus, editResponseHeaders, editResponseCookies, rewriteResponseBody, responseBreakpoint
    case returnFile, returnDirectory, returnHandwritten, returnPreset
    case closeConnectionGraceful, closeConnectionReset, returnConnectTunnel, noDecrypt
    case hide, mark, comment
    /// Rules 2.0 R8F2: a Classic auto-responder action string (`*drop`, `*delay:100`, ...).
    case magicString

    public var id: String { rawValue }

    /// Which message the action works on; the menu colours its dot by it.
    public enum Side: Sendable { case request, response, both, none }

    public var side: Side {
        switch self {
        case .modifyURL, .modifyQuery, .editRequestHeaders, .editRequestCookies, .rewriteRequestBody, .mapRemote,
            .requestBreakpoint, .returnDirectory, .returnConnectTunnel, .noDecrypt: .request
        case .rewriteStatus, .editResponseHeaders, .editResponseCookies, .rewriteResponseBody, .responseBreakpoint: .response
        case .hide, .mark, .comment: .none
        // Work at either point: a rule judged at the response answers, closes or delays there (spec 12.7).
        case .magicString, .delay, .returnFile, .returnHandwritten, .returnPreset, .closeConnectionGraceful,
            .closeConnectionReset: .both
        }
    }

    public var titleKey: String {
        switch self {
        case .modifyURL: "rules.actionType.modifyURL"
        case .modifyQuery: "rules.actionType.modifyQuery"
        case .editRequestHeaders: "rules.actionType.editRequestHeaders"
        case .editRequestCookies: "rules.actionType.editRequestCookies"
        case .rewriteRequestBody: "rules.actionType.rewriteRequestBody"
        case .mapRemote: "rules.actionType.mapRemote"
        case .requestBreakpoint: "rules.actionType.requestBreakpoint"
        case .delay: "rules.actionType.delay"
        case .rewriteStatus: "rules.actionType.rewriteStatus"
        case .editResponseHeaders: "rules.actionType.editResponseHeaders"
        case .editResponseCookies: "rules.actionType.editResponseCookies"
        case .rewriteResponseBody: "rules.actionType.rewriteResponseBody"
        case .responseBreakpoint: "rules.actionType.responseBreakpoint"
        case .returnFile: "rules.actionType.returnFile"
        case .returnDirectory: "rules.actionType.returnDirectory"
        case .returnHandwritten: "rules.actionType.returnHandwritten"
        case .returnPreset: "rules.actionType.returnPreset"
        case .closeConnectionGraceful: "rules.actionType.closeConnectionGraceful"
        case .closeConnectionReset: "rules.actionType.closeConnectionReset"
        case .returnConnectTunnel: "rules.actionType.returnConnectTunnel"
        case .noDecrypt: "rules.actionType.noDecrypt"
        case .hide: "rules.actionType.hide"
        case .mark: "rules.actionType.mark"
        case .comment: "rules.actionType.comment"
        case .magicString: "rules.actionType.magicString"
        }
    }

    public var hintKey: String {
        switch self {
        case .modifyURL: "rules.actionType.modifyURL.hint"
        case .modifyQuery: "rules.actionType.modifyQuery.hint"
        case .editRequestHeaders: "rules.actionType.editRequestHeaders.hint"
        case .editRequestCookies: "rules.actionType.editRequestCookies.hint"
        case .rewriteRequestBody: "rules.actionType.rewriteRequestBody.hint"
        case .mapRemote: "rules.actionType.mapRemote.hint"
        case .requestBreakpoint: "rules.actionType.requestBreakpoint.hint"
        case .delay: "rules.actionType.delay.hint"
        case .rewriteStatus: "rules.actionType.rewriteStatus.hint"
        case .editResponseHeaders: "rules.actionType.editResponseHeaders.hint"
        case .editResponseCookies: "rules.actionType.editResponseCookies.hint"
        case .rewriteResponseBody: "rules.actionType.rewriteResponseBody.hint"
        case .responseBreakpoint: "rules.actionType.responseBreakpoint.hint"
        case .returnFile: "rules.actionType.returnFile.hint"
        case .returnDirectory: "rules.actionType.returnDirectory.hint"
        case .returnHandwritten: "rules.actionType.returnHandwritten.hint"
        case .returnPreset: "rules.actionType.returnPreset.hint"
        case .closeConnectionGraceful: "rules.actionType.closeConnectionGraceful.hint"
        case .closeConnectionReset: "rules.actionType.closeConnectionReset.hint"
        case .returnConnectTunnel: "rules.actionType.returnConnectTunnel.hint"
        case .noDecrypt: "rules.actionType.noDecrypt.hint"
        case .hide: "rules.actionType.hide.hint"
        case .mark: "rules.actionType.mark.hint"
        case .comment: "rules.actionType.comment.hint"
        case .magicString: "rules.actionType.magicString.hint"
        }
    }

    /// Same answer as `ActionKind.isIntrinsicallyFinal`.
    public var isIntrinsicallyFinal: Bool {
        switch self {
        case .returnFile, .returnDirectory, .hide, .returnHandwritten, .returnPreset, .closeConnectionGraceful,
            .closeConnectionReset, .returnConnectTunnel, .noDecrypt: true
        case .modifyURL, .modifyQuery, .editRequestHeaders, .editRequestCookies, .rewriteRequestBody, .mapRemote,
            .requestBreakpoint, .delay, .rewriteStatus, .editResponseHeaders, .editResponseCookies, .rewriteResponseBody,
            .responseBreakpoint, .mark, .comment, .magicString: false
        }
    }

    public var isConnectOnly: Bool {
        switch self {
        case .noDecrypt, .returnConnectTunnel: true
        case .modifyURL, .modifyQuery, .editRequestHeaders, .editRequestCookies, .rewriteRequestBody, .mapRemote,
            .requestBreakpoint, .delay, .rewriteStatus, .editResponseHeaders, .editResponseCookies, .rewriteResponseBody,
            .responseBreakpoint, .returnFile, .returnDirectory, .returnHandwritten, .returnPreset, .closeConnectionGraceful,
            .closeConnectionReset, .hide, .mark, .comment, .magicString: false
        }
    }

    public var canRunAtConnect: Bool {
        switch self {
        case .closeConnectionGraceful, .closeConnectionReset, .mark, .comment, .hide, .noDecrypt, .returnConnectTunnel: true
        case .modifyURL, .modifyQuery, .editRequestHeaders, .editRequestCookies, .rewriteRequestBody, .mapRemote,
            .requestBreakpoint, .delay, .rewriteStatus, .editResponseHeaders, .editResponseCookies, .rewriteResponseBody,
            .responseBreakpoint, .returnFile, .returnDirectory, .returnHandwritten, .returnPreset, .magicString: false
        }
    }

    /// Marks, comments and hiding change the record, not the traffic.
    public var isAnnotation: Bool {
        switch self {
        case .hide, .mark, .comment: true
        case .modifyURL, .modifyQuery, .editRequestHeaders, .editRequestCookies, .rewriteRequestBody, .mapRemote,
            .requestBreakpoint, .delay, .rewriteStatus, .editResponseHeaders, .editResponseCookies, .rewriteResponseBody,
            .responseBreakpoint, .returnFile, .returnDirectory, .returnHandwritten, .returnPreset, .closeConnectionGraceful,
            .closeConnectionReset, .returnConnectTunnel, .noDecrypt, .magicString: false
        }
    }

    /// The type a stored action belongs to.
    public init?(_ kind: ActionKind) {
        switch kind {
        case .modifyURL: self = .modifyURL
        case .modifyQuery: self = .modifyQuery
        case .editHeaders(let direction, _): self = direction == .request ? .editRequestHeaders : .editResponseHeaders
        case .editCookies(let direction, _): self = direction == .request ? .editRequestCookies : .editResponseCookies
        case .rewriteBody(let direction, _): self = direction == .request ? .rewriteRequestBody : .rewriteResponseBody
        case .mapRemote: self = .mapRemote
        case .breakpoint(let direction, _): self = direction == .request ? .requestBreakpoint : .responseBreakpoint
        case .delay: self = .delay
        case .rewriteStatus: self = .rewriteStatus
        case .returnFile: self = .returnFile
        case .returnDirectory: self = .returnDirectory
        case .returnHandwritten: self = .returnHandwritten
        case .returnPreset: self = .returnPreset
        case .closeConnection(let mode): self = mode == .graceful ? .closeConnectionGraceful : .closeConnectionReset
        case .returnConnectTunnel: self = .returnConnectTunnel
        case .noDecrypt: self = .noDecrypt
        case .hide: self = .hide
        case .mark: self = .mark
        case .comment: self = .comment
        case .magicString: self = .magicString
        }
    }

    /// Why the judgment point (or the other actions) rule a type out.
    public enum Reason: Equatable, Sendable {
        case requestSideAtResponsePoint, onlyAnnotationAtCompletion, needsConnectPointConditions, connectOnlyMixed
    }

    public enum Availability: Equatable, Sendable { case available, unavailable(Reason) }

    /// What the judgment point and the other cards need to know about one action: where it can run.
    public struct Traits: Equatable, Sendable {
        public var isConnectOnly: Bool
        public var canRunAtConnect: Bool
        public var isAnnotation: Bool
    }

    /// The traits of the type. A magic string has none of its own (it takes those of what the text stands for), so
    /// this is the answer for a card that has no text yet; `traits(of:)` is the one that reads the text.
    public var traits: Traits { Traits(isConnectOnly: isConnectOnly, canRunAtConnect: canRunAtConnect, isAnnotation: isAnnotation) }

    /// The traits of a card of this type holding `kind`: for a magic string, those of the action its text resolves to
    /// (`*ReplyWithTunnel` is connect-only, `*drop` can run at the CONNECT), otherwise the type's own.
    public func traits(of kind: ActionKind?) -> Traits {
        guard self == .magicString, case .magicString(let text)? = kind, case .success(let resolved) = MagicStringAction.resolve(text)
        else { return traits }
        return Traits(
            isConnectOnly: resolved.isConnectOnly, canRunAtConnect: resolved.canRunAtConnect, isAnnotation: resolved.isAnnotation)
    }

    /// Whether the type may be chosen for a rule judged at `point`. `siblings` are the other actions of the rule.
    public func availability(at point: EvaluationPoint, conditionsAreConnectOnly: Bool, siblings: [ActionType]) -> Availability {
        availability(
            of: traits, at: point, conditionsAreConnectOnly: conditionsAreConnectOnly, siblings: siblings.map(\.traits))
    }

    /// The same question for given traits (a magic string card passes those of its text).
    public func availability(
        of traits: Traits, at point: EvaluationPoint, conditionsAreConnectOnly: Bool, siblings: [Traits]
    ) -> Availability {
        if point == .completion, !traits.isAnnotation { return .unavailable(.onlyAnnotationAtCompletion) }
        if traits.isConnectOnly, !conditionsAreConnectOnly { return .unavailable(.needsConnectPointConditions) }
        if !traits.canRunAtConnect, siblings.contains(where: \.isConnectOnly) { return .unavailable(.connectOnlyMixed) }
        if traits.isConnectOnly, siblings.contains(where: { !$0.canRunAtConnect }) { return .unavailable(.connectOnlyMixed) }
        return .available
    }

    /// The whole sentence that explains a grey entry (spec 6.4).
    public static func explanationKey(_ reason: Reason) -> String {
        switch reason {
        case .requestSideAtResponsePoint: "rules.unavailable.requestSideAtResponsePoint"
        case .onlyAnnotationAtCompletion: "rules.unavailable.onlyAnnotationAtCompletion"
        case .needsConnectPointConditions: "rules.unavailable.needsConnectPointConditions"
        case .connectOnlyMixed: "rules.unavailable.connectOnlyMixed"
        }
    }
}

public enum ActionCardState: Equatable, Sendable {
    case active, final, unreachable
    /// A request-side action in a rule judged at the response that can still change the recorded request: it saves,
    /// but only the record changes (warning 1, spec R8F2-6).
    case requestVisibleOnly
    /// The same, for a request-side action that cannot be applied to a record (breakpoint, tunnel, map remote...):
    /// it is skipped (warning 1, own wording).
    case requestSkippedAtResponse
    /// The judgment point or the other cards rule the type out (the card stays so the user sees what to fix).
    case blocked(ActionType.Reason)

    /// The tag a card shows, if any.
    public var labelKey: String? {
        switch self {
        case .active, .blocked, .requestVisibleOnly, .requestSkippedAtResponse: nil
        case .final: "rules.card.final"
        case .unreachable: "rules.card.unreachable"
        }
    }

    /// The sentence that explains why the card is greyed out or flagged.
    public var explanationKey: String? {
        switch self {
        case .active, .final: nil
        case .requestVisibleOnly: "rules.card.requestVisibleOnly"
        case .requestSkippedAtResponse: "rules.card.requestSkippedAtResponse"
        case .unreachable: "rules.card.afterFinal"
        case .blocked(let reason): ActionType.explanationKey(reason)
        }
    }
}

/// One line of a card's warning list (spec 12.6): the warning, whether it is an error (the card never runs), and its sentence.
public struct ActionCardNotice: Equatable, Hashable, Sendable {
    public var warning: ActionExecutionWarning
    public var isError: Bool { warning.isError }
    public var textKey: String
}

/// The strip above the cards when any card has a notice: errors name actions that never run, warnings only
/// actions that may not do what they say.
public enum ActionBanner: Equatable, Sendable {
    case errors, warnings

    public var textKey: String {
        switch self {
        case .errors: "rules.banner.actionsErrors"
        case .warnings: "rules.banner.actionsWarnings"
        }
    }
}

/// What the cards of a rule will and will not do, read from the engine's own `RuleValidation.executionWarnings`.
public enum ActionCardAnalysis {
    public struct Result: Equatable, Sendable {
        /// One state per card, in order.
        public var states: [ActionCardState]
        /// The warning list of each card, in order (empty: none).
        public var notices: [[ActionCardNotice]]
        public var banner: ActionBanner?
    }

    /// `rule` holds one action per card (a stand-in for a card that cannot be built yet); `types` are the cards' types.
    public static func analyze(rule: Rule, types: [ActionType], conditionsAreConnectOnly: Bool) -> Result {
        let point = rule.conditions.judgmentPoint
        let found = RuleValidation.executionWarnings(rule)
        var states: [ActionCardState] = []
        var notices: [[ActionCardNotice]] = []
        // A magic string card counts as what its text stands for.
        let traits = zip(types, rule.actions).map { $0.traits(of: $1.kind) }
        for (index, action) in rule.actions.enumerated() {
            let warnings = found[index] ?? []
            let resolved = resolvedKind(of: action)
            notices.append(warnings.map { ActionCardNotice(warning: $0, textKey: textKey($0, resolved: resolved)) })
            guard types.indices.contains(index) else {
                states.append(.active)
                continue
            }
            var siblings = traits
            siblings.remove(at: index)
            if case .unavailable(let reason) = types[index].availability(
                of: traits[index], at: point, conditionsAreConnectOnly: conditionsAreConnectOnly, siblings: siblings)
            {
                states.append(.blocked(reason))
            } else if warnings.contains(.afterFinalAction) {
                states.append(.unreachable)
            } else if warnings.contains(.requestActionVisibleOnly) {
                states.append(RecordedRequestEditing.appliesToRecord(resolved) ? .requestVisibleOnly : .requestSkippedAtResponse)
            } else if isEffectivelyFinal(action) {
                states.append(.final)
            } else {
                states.append(.active)
            }
        }
        let all = notices.joined()
        let banner: ActionBanner? = all.contains(where: \.isError) ? .errors : (all.isEmpty ? nil : .warnings)
        return Result(states: states, notices: notices, banner: banner)
    }

    /// The action a magic string stands for; any other action as it is.
    static func resolvedKind(of action: RuleAction) -> ActionKind {
        guard case .magicString(let text) = action.kind else { return action.kind }
        if case .success(let kind) = MagicStringAction.resolve(text) { return kind }
        return action.kind
    }

    private static func isEffectivelyFinal(_ action: RuleAction) -> Bool {
        if case .magicString(let text) = action.kind, MagicStringAction.isExit(text) { return true }
        return RuleAction(resolvedKind(of: action), isFinal: action.isFinal).isFinalEffective
    }

    /// Whole sentences, one key per warning (the first has two wordings: the action can change the record, or is skipped).
    static func textKey(_ warning: ActionExecutionWarning, resolved: ActionKind) -> String {
        switch warning {
        case .requestActionVisibleOnly:
            RecordedRequestEditing.appliesToRecord(resolved) ? "rules.card.requestVisibleOnly" : "rules.card.requestSkippedAtResponse"
        case .matchPointUncertain: "rules.notice.matchPointUncertain"
        case .requestActionAfterResponseAction: "rules.notice.requestAfterResponse"
        case .noDecryptNeedsSimpleConditions: "rules.notice.noDecryptConditions"
        case .multipleManualResponses: "rules.notice.multipleManualResponses"
        case .afterFinalAction: "rules.card.afterFinal"
        }
    }
}
