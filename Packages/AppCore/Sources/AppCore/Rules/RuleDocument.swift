import FlowStore
import Foundation
import Localization
import RulesEngine

/// The input of the rule editor a problem belongs to.
public enum RuleDocumentField: Hashable, Sendable {
    case name, group, conditions, conditionRow(UUID), occurrence, actions
    case action(UUID, ActionField)
}

/// What the user must agree to before the rule is saved.
public enum RuleDocumentConfirmation: Equatable, Sendable {
    /// A final action with no condition: the rule acts on all traffic and cuts every lower-priority rule.
    case everySessionFinal

    public var titleKey: String {
        switch self {
        case .everySessionFinal: "rules.warning.everySessionFinal.title"
        }
    }

    public var messageKey: String {
        switch self {
        case .everySessionFinal: "rules.warning.everySessionFinal.message"
        }
    }
}

extension ActionWarning {
    public var localizationKey: String {
        switch self {
        case .contentLengthCorrected: "rules.warning.contentLengthCorrected"
        case .hideCutsLowerRules: "rules.warning.hideIsFinal"
        case .markTextColorNeedsBackground: "rules.warning.markTextColorNeedsBackground"
        }
    }
}

/// The verdict on a document: the rule when it can be saved, else what is wrong where.
public struct RuleDocumentValidation: Equatable, Sendable {
    /// The rule to save; nil while any issue stands.
    public var rule: Rule?
    public var issues: [RuleDocumentField: RuleDraftIssue]
    /// One state per card, also when the rule cannot be saved.
    public var cardStates: [UUID: ActionCardState]
    /// Valid but probably unintended, by card.
    public var warnings: [UUID: [ActionWarning]]
    public var confirmations: [RuleDocumentConfirmation]
    /// The warning list of each card from the engine's execution check (spec 12.6), also when the rule cannot be saved.
    public var notices: [UUID: [ActionCardNotice]]
    /// The strip above the cards when any card has a notice.
    public var banner: ActionBanner?

    public init(
        rule: Rule? = nil, issues: [RuleDocumentField: RuleDraftIssue] = [:], cardStates: [UUID: ActionCardState] = [:],
        warnings: [UUID: [ActionWarning]] = [:], confirmations: [RuleDocumentConfirmation] = [],
        notices: [UUID: [ActionCardNotice]] = [:], banner: ActionBanner? = nil
    ) {
        self.rule = rule
        self.issues = issues
        self.cardStates = cardStates
        self.warnings = warnings
        self.confirmations = confirmations
        self.notices = notices
        self.banner = banner
    }
}

/// One rule as the editor window holds it: everything a stored rule has, as the texts the user types. Nothing a stored
/// rule can carry is lost on the way in and out (several actions, ticked finals, occurrence ranges, old-style comparisons,
/// the note, the place in the tree).
public struct RuleDocument: Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var enabled: Bool
    public var groupID: UUID?
    public var note: String
    /// The place among the siblings; kept so a rule saved in place stays where it is.
    public var order: Int
    public var conditions: ConditionsDraft
    public var actions: [ActionDraft]

    /// A new rule: every session, no action yet, enabled.
    public init(newIn groupID: UUID?) {
        id = UUID()
        name = ""
        enabled = true
        self.groupID = groupID
        note = ""
        order = 0
        conditions = ConditionsDraft()
        actions = []
    }

    /// What the editor opens for "new rule": one empty "URL contains" row and one mark card.
    public init(startingIn groupID: UUID?) {
        self.init(newIn: groupID)
        conditions.addRow()
        actions = [ActionDraft(type: .mark)]
    }

    public init(rule: Rule) {
        id = rule.id
        name = rule.name
        enabled = rule.enabled
        groupID = rule.groupID
        note = rule.note ?? ""
        order = rule.order
        conditions = ConditionsDraft(group: rule.conditions)
        actions = rule.actions.flatMap { ActionDraft.cards(for: $0) }
    }

    /// The name the lists show; a rule without one is "unnamed".
    public var displayName: String { RulePresentation.displayName(name) }

    // MARK: judgment point

    /// The latest point at which any condition row has its value.
    public var judgmentPoint: EvaluationPoint { conditions.judgmentPoint }

    private static let connectFields: Set<ConditionField> = [.allSessions, .url, .scheme, .host, .port, .clientIP, .clientApp]

    /// The conditions only use what is known on the CONNECT line (the whitelist of the no-decrypt and CONNECT-tunnel actions).
    public var conditionsAreConnectOnly: Bool {
        judgmentPoint == .connect && conditions.rows.allSatisfy { Self.connectFields.contains($0.row.field) }
    }

    /// Whether `type` may be chosen for a card; `id` is the card it would replace (nil: a new card).
    public func availability(of type: ActionType, replacing id: UUID?) -> ActionType.Availability {
        type.availability(
            of: type.traits, at: judgmentPoint, conditionsAreConnectOnly: conditionsAreConnectOnly,
            siblings: actions.filter { $0.id != id }.map(\.traits))
    }

    /// The rows match every session.
    private var matchesEverySession: Bool {
        conditions.rows.isEmpty || (conditions.mode != .none && conditions.rows.allSatisfy { $0.row.field == .allSessions })
    }

    // MARK: validation

    /// Checks every input and puts the rule together. The cards are read one by one, so every broken field is reported at
    /// once and none is dropped; then the judgment point rules (a card the point forbids stays and is flagged), and last
    /// the whole rule goes through the engine's own check.
    public func validate(limits: RulesLimits) -> RuleDocumentValidation {
        var issues: [RuleDocumentField: RuleDraftIssue] = [:]
        var warnings: [UUID: [ActionWarning]] = [:]

        if (try? Rule(name: name, actions: [RuleAction(.hide)]).validate(limits: limits)) == nil {
            issues[.name] = .fieldTooLong
        }
        for (rowID, issue) in conditions.validate(limits: limits) {
            issues[rowID == ConditionsDraft.groupIssueID ? .conditions : .conditionRow(rowID)] = issue
        }
        if let issue = conditions.occurrenceIssue() { issues[.occurrence] = issue }

        var results: [ActionBuildResult] = []
        for card in actions {
            let result = card.build(limits: limits)
            results.append(result)
            for (field, issue) in result.issues { issues[.action(card.id, field)] = issue }
            if !result.warnings.isEmpty { warnings[card.id] = result.warnings }
        }
        if actions.isEmpty {
            issues[.actions] = .noActions
        } else if assembledActionCount(limits: limits) > limits.ruleActions {
            issues[.actions] = .tooManyActions
        }

        let point = judgmentPoint
        let analysis = cardAnalysis(results: results, limits: limits)
        var cardStates: [UUID: ActionCardState] = [:]
        var notices: [UUID: [ActionCardNotice]] = [:]
        for (index, card) in actions.enumerated() {
            let state = analysis.states[index]
            cardStates[card.id] = state
            if !analysis.notices[index].isEmpty { notices[card.id] = analysis.notices[index] }
            if case .blocked(let reason) = state {
                issues[.action(card.id, .type)] = Self.issue(of: reason)
            }
            // A final action must be known before the response arrives (spec 5.5.4 item 6). Hiding changes the record
            // only, so it is allowed wherever it is.
            if card.isFinal, point >= .response, card.type != .hide {
                issues[.action(card.id, .final)] = .finalActionAtLaterPoint
            }
        }

        var confirmations: [RuleDocumentConfirmation] = []
        if matchesEverySession, analysis.states.contains(.final) { confirmations.append(.everySessionFinal) }

        var rule: Rule?
        let assembly = assemble(results, limits: limits)
        if issues.isEmpty, let group = conditions.conditionGroup(), let assembled = assembly {
            let candidate = Rule(
                id: id, name: name, enabled: enabled, groupID: groupID, order: order, conditions: group,
                actions: assembled.actions, note: note.isEmpty ? nil : note)
            do {
                try candidate.validate(limits: limits)
                rule = candidate
            } catch let error as RuleValidationError {
                issues[field(of: error, owners: assembled.owners)] = RuleDraftIssue(documentError: error)
            } catch {
                issues[.name] = .headerInvalid
            }
        }
        return RuleDocumentValidation(
            rule: rule, issues: issues, cardStates: cardStates, warnings: warnings, confirmations: confirmations,
            notices: notices, banner: analysis.banner)
    }

    // MARK: assembling

    /// One action of the assembled rule: the cards `range` it comes from and, when nobody touched those cards, the
    /// stored action they were opened from.
    private struct Piece {
        var range: Range<Int>
        var restored: RuleAction?
    }

    /// The cards that make one action each. The cards of a stored multi-edit action that nobody touched, still side by
    /// side and in order, go back as that one action (R8F2-9: opening a rule and saving it unedited changes nothing).
    /// With `merging`, neighbouring header, cookie or query cards of one stored action also share an action again, so a
    /// long stored action that was edited still fits the action limit.
    private func pieces(limits: RulesLimits, merging: Bool) -> [Piece] {
        var pieces: [Piece] = []
        var index = 0
        while index < actions.count {
            if let origin = actions[index].split, origin.index == 0, index + origin.count <= actions.count,
                (0..<origin.count).allSatisfy({ share in
                    let card = actions[index + share]
                    return card.split?.group == origin.group && card.split?.index == share && card.split?.count == origin.count
                        && card.isUntouched(limits: limits) && card.isFinal == card.baseline?.original.isFinal
                }),
                actions[index + origin.count - 1].isFinal == origin.original.isFinal
            {
                pieces.append(Piece(range: index..<index + origin.count, restored: origin.original))
                index += origin.count
                continue
            }
            if merging, let last = pieces.last, last.restored == nil, canMerge(actions[last.range.upperBound - 1], actions[index]) {
                pieces[pieces.count - 1].range = last.range.lowerBound..<index + 1
            } else {
                pieces.append(Piece(range: index..<index + 1, restored: nil))
            }
            index += 1
        }
        return pieces
    }

    /// Two neighbouring cards that came from one stored action and hold the same kind of edit; the first must not carry
    /// the stop tick (the merged action keeps the last card's).
    private func canMerge(_ first: ActionDraft, _ second: ActionDraft) -> Bool {
        guard let a = first.split, let b = second.split, a.group == b.group, first.type == second.type, !first.isFinal else {
            return false
        }
        switch first.type {
        case .editRequestHeaders, .editResponseHeaders, .editRequestCookies, .editResponseCookies, .modifyQuery: return true
        default: return false
        }
    }

    /// The number of actions the rule will hold, by the cards' structure (the fewest it can come to).
    func assembledActionCount(limits: RulesLimits) -> Int { pieces(limits: limits, merging: true).count }

    /// The rule's actions from the built cards: every card is one action, except what `pieces` puts back together
    /// (untouched stored actions, and, only when the plain split would pass the action limit, the neighbouring cards of
    /// one stored action as one multi-edit action built from the cards' current edits). `owners[i]` is the index of the
    /// first card of action `i`. Nil while any card has no action.
    func assemble(_ results: [ActionBuildResult], limits: RulesLimits = RulesLimits()) -> (actions: [RuleAction], owners: [Int])? {
        guard results.count == actions.count else { return nil }
        var plan = pieces(limits: limits, merging: false)
        if plan.count > limits.ruleActions { plan = pieces(limits: limits, merging: true) }
        var built: [RuleAction] = []
        var owners: [Int] = []
        for piece in plan {
            if let original = piece.restored {
                built.append(original)
            } else {
                let cards = piece.range.compactMap { results[$0].action }
                guard cards.count == piece.range.count, var merged = cards.first else { return nil }
                for next in cards.dropFirst() {
                    guard let kind = merged.kind.appendingEdits(of: next.kind) else { return nil }
                    merged = RuleAction(kind, isFinal: next.isFinal)
                }
                built.append(merged)
            }
            owners.append(piece.range.lowerBound)
        }
        return (built, owners)
    }

    /// The card each stored action of the rule starts at: `owners[i]` is the first card of stored action `i`. A rule opened
    /// in the editor shows one stored action as several cards when it edits several things, so the number a person
    /// reads ("action 3") is the card's, not the stored index the engine reports.
    public func storedActionOwners(limits: RulesLimits = RulesLimits()) -> [Int] {
        var plan = pieces(limits: limits, merging: false)
        if plan.count > limits.ruleActions { plan = pieces(limits: limits, merging: true) }
        return plan.map(\.range.lowerBound)
    }

    /// The card each stored action of the rule ends at. The stop tick of a final action lives on the last card of a split
    /// action (ruling T8f), so stop outcomes are numbered by it.
    public func storedActionLastCards(limits: RulesLimits = RulesLimits()) -> [Int] {
        var plan = pieces(limits: limits, merging: false)
        if plan.count > limits.ruleActions { plan = pieces(limits: limits, merging: true) }
        return plan.map { $0.range.upperBound - 1 }
    }

    /// The card that carries stored action `index`; nil when the rule has no such action.
    public func cardIndex(forStoredAction index: Int, limits: RulesLimits = RulesLimits()) -> Int? {
        let owners = storedActionOwners(limits: limits)
        return owners.indices.contains(index) ? owners[index] : nil
    }

    // MARK: execution analysis

    /// What each card will and will not do, from the engine's own check on the cards as they are now. A card that
    /// cannot be built yet stands in with its type's usual action, so the warnings of the others still show.
    public func cardAnalysis(limits: RulesLimits = RulesLimits()) -> ActionCardAnalysis.Result {
        cardAnalysis(results: actions.map { $0.build(limits: limits) }, limits: limits)
    }

    /// The analysis with the warnings each card's build gave, from one build of every card: what the cards column draws
    /// from before any check has run.
    public func liveCardReport(limits: RulesLimits = RulesLimits()) -> (analysis: ActionCardAnalysis.Result, buildWarnings: [[ActionWarning]]) {
        let results = actions.map { $0.build(limits: limits) }
        return (cardAnalysis(results: results, limits: limits), results.map(\.warnings))
    }

    private func cardAnalysis(results: [ActionBuildResult], limits: RulesLimits) -> ActionCardAnalysis.Result {
        let probes = zip(actions, results).map { card, result in result.action ?? card.standInAction() }
        let probe = Rule(
            name: "", conditions: ConditionGroup(mode: conditions.mode, rows: conditions.rows.map(\.row)), actions: probes)
        return ActionCardAnalysis.analyze(
            rule: probe, types: actions.map(\.type), conditionsAreConnectOnly: conditionsAreConnectOnly)
    }

    private static func issue(of reason: ActionType.Reason) -> RuleDraftIssue {
        switch reason {
        case .requestSideAtResponsePoint: .actionNotAllowedAtResponsePoint
        case .onlyAnnotationAtCompletion: .actionNotAllowedAtCompletionPoint
        case .needsConnectPointConditions: .connectActionCondition
        case .connectOnlyMixed: .connectActionMixed
        }
    }

    /// Where an engine error of the assembled rule is shown (each part was checked before, so this is the safety net).
    private func field(of error: RuleValidationError, owners: [Int]) -> RuleDocumentField {
        switch error.field {
        case .name: .name
        case .group: .group
        case .conditionRow(let index): conditions.rows.indices.contains(index) ? .conditionRow(conditions.rows[index].id) : .conditions
        case .action(let index):
            owners.indices.contains(index) && actions.indices.contains(owners[index])
                ? .action(actions[owners[index]].id, .type) : .actions
        case .conditions, .scheme, .hostPattern, .port, .method, .path, .statusRange: .conditions
        default: .actions
        }
    }

    // MARK: cards

    public mutating func addAction(_ type: ActionType, after id: UUID? = nil) {
        var card = ActionDraft(type: type)
        card.defaultKeyCaseOff()
        if let id, let index = actions.firstIndex(where: { $0.id == id }) {
            actions.insert(card, at: index + 1)
        } else {
            actions.append(card)
        }
    }

    public mutating func duplicateAction(_ id: UUID) {
        guard let index = actions.firstIndex(where: { $0.id == id }) else { return }
        actions.insert(actions[index].detachedCopy(), at: index + 1)
    }

    /// The delete button is off while one card is left (as the reference does).
    public var canRemoveAction: Bool { actions.count > 1 }

    public mutating func removeAction(_ id: UUID) {
        guard canRemoveAction else { return }
        actions.removeAll { $0.id == id }
    }

    /// Moves a card by `delta` places, stopping at either end.
    public mutating func moveAction(_ id: UUID, by delta: Int) {
        guard let index = actions.firstIndex(where: { $0.id == id }) else { return }
        let target = min(max(index + delta, 0), actions.count - 1)
        guard target != index else { return }
        actions.insert(actions.remove(at: index), at: target)
    }

    /// Gives a card another type; the final tick and every form's content stay.
    public mutating func changeType(of id: UUID, to type: ActionType) {
        guard let index = actions.firstIndex(where: { $0.id == id }) else { return }
        actions[index].setType(type)
    }
}

// MARK: seeds

extension RuleDocument {
    /// The document for a draft of the old form (a flow's "new rule from this traffic", a saved response mock, an external
    /// writer). A draft that passes its own check gives exactly the rule it produces; otherwise only what it holds is
    /// taken over: the match fields as condition rows and one card of the same kind with the form's texts.
    public static func seed(from draft: RuleEditorDraft, limits: RulesLimits) -> RuleDocument {
        if let rule = draft.validate(order: 0, limits: limits).rule {
            var document = RuleDocument(rule: rule)
            document.attachAsset(of: draft)
            return document
        }
        var document = RuleDocument(newIn: nil)
        document.id = draft.id
        document.name = draft.name
        document.enabled = draft.enabled
        document.conditions = ConditionsDraft(group: draft.lenientConditions)
        var card = ActionDraft(type: draft.actionType)
        card.takeOver(draft)
        document.actions = [card]
        document.attachAsset(of: draft)
        return document
    }

    /// The managed file of a mock draft goes on the file card, with its real name and size.
    private mutating func attachAsset(of draft: RuleEditorDraft) {
        guard let asset = draft.mapLocal.asset else { return }
        for index in actions.indices where actions[index].type == .returnFile {
            let assetID = actions[index].file.asset?.id ?? asset.id
            if assetID == asset.id { actions[index].file.asset = asset }
        }
    }
}

extension RuleEditorDraft {
    /// The match fields as rows, whether or not they are valid (a field that cannot be read is left out).
    fileprivate var lenientConditions: ConditionGroup {
        var matcher = RuleMatcher()
        matcher.scheme = match.scheme == .any ? nil : match.scheme.rawValue
        let host = match.host.trimmingCharacters(in: .whitespaces)
        matcher.hostPattern = host.isEmpty ? nil : host
        matcher.hostSyntax = host.isEmpty ? .literal : match.syntax
        matcher.port = Int(match.port.trimmingCharacters(in: .whitespaces))
        let method = match.method.trimmingCharacters(in: .whitespaces)
        matcher.method = method.isEmpty ? nil : method
        switch match.syntax {
        case .literal:
            switch match.pathMode {
            case .any: matcher.path = .any
            case .exact: matcher.path = match.path.isEmpty ? .any : .exact(match.path)
            case .prefix: matcher.path = match.path.isEmpty ? .any : .prefix(match.path)
            }
        case .wildcard: matcher.path = match.path.isEmpty ? .any : .wildcard(match.path)
        case .regex: matcher.path = match.path.isEmpty ? .any : .regex(match.path)
        }
        if let low = Int(match.statusLower.trimmingCharacters(in: .whitespaces)),
            let high = Int(match.statusUpper.trimmingCharacters(in: .whitespaces)), low <= high
        {
            matcher.statusRange = low...high
        }
        var group = Rule(id: id, name: "", enabled: true, order: 0, matcher: matcher, annotation: .hide).conditions
        group.mode = matchMode
        return group
    }

    /// The editor's type of the draft's action.
    fileprivate var actionType: ActionType {
        switch kind {
        case .mapLocal: .returnFile
        case .mapLocalDirectory: .returnDirectory
        case .mapRemote: .mapRemote
        case .editHeaders: effectiveDirection == .request ? .editRequestHeaders : .editResponseHeaders
        case .breakpoint: effectiveDirection == .request ? .requestBreakpoint : .responseBreakpoint
        case .rewriteBody: effectiveDirection == .request ? .rewriteRequestBody : .rewriteResponseBody
        case .rewriteStatus: .rewriteStatus
        case .mark: .mark
        case .comment: .comment
        case .hide: .hide
        }
    }
}

extension ActionDraft {
    /// Copies the form of the old draft's kind onto this card.
    fileprivate mutating func takeOver(_ draft: RuleEditorDraft) {
        remote = draft.mapRemote
        file = draft.mapLocal
        directory = draft.mapLocalDirectory
        if draft.match.pathMode == .prefix, !draft.match.path.isEmpty { directoryPrefix = draft.match.path }
        headerRows = draft.headerOperations.map { row in
            let method: HeaderMethod =
                switch row.kind {
                case .set: .set
                case .append: .append
                case .remove: .remove
                }
            return HeaderEditRow(id: row.id, method: method, name: row.name, value: row.value)
        }
        if headerRows.isEmpty { headerRows = [HeaderEditRow()] }
        body = BodyEditDraft(
            syntax: draft.bodyRewrite.syntax, find: draft.bodyRewrite.find, replacement: draft.bodyRewrite.replacement,
            caseSensitive: draft.bodyRewrite.caseSensitive, scope: draft.bodyRewrite.scope)
        status = draft.rewriteStatus
        breakpointMode = draft.breakpointMode
        mark = draft.mark
        comment = draft.comment
    }
}
