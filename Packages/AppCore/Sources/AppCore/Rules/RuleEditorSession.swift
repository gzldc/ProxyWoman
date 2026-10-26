import FlowStore
import Foundation
import Observation
import RulesEngine

/// The rule editor window's state: one document at a time, what it was when it was opened (so the window knows whether
/// there is anything to lose), the question about unsaved changes, and the managed files the document imported.
///
/// The saved tree can change under an open document (the outline toggles, moves and deletes, other writers save).
/// `reconcile()` brings the document in line: the switch, the place in the tree and a deleted rule or group are followed
/// without counting as the user's edits, and a rule whose content someone else changed is never overwritten silently.
/// The window calls it when the saved rules change; every operation of the session calls it first.
@MainActor @Observable public final class RuleEditorSession {
    public enum PendingSwitch: Equatable, Sendable {
        case rule(UUID)
        case new(inGroup: UUID?)
        case seed(RuleEditorDraft)
    }

    public enum PendingChoice: Sendable { case save, discard, cancel }

    /// What closing the window with its close button or ⌘W does (R8F3-8). Cancel never asks.
    public enum CloseDecision: Equatable, Sendable {
        /// Nothing to lose: close.
        case closeNow
        /// Unsaved changes that could be saved: Save / Don't Save / Cancel. `name` is the rule's name for the question.
        case askSave(name: String)
        /// Unsaved changes that cannot be saved as they are: only Don't Save / Cancel.
        case askDiscardOnly
    }

    public enum SaveResult: Equatable, Sendable {
        case saved
        /// Field problems: nothing was saved; `validation` says where.
        case invalid
        case needsConfirmation([RuleDocumentConfirmation])
        case failed(RulesEditorError)
        /// A save or a file import is running.
        case busy
    }

    public private(set) var document: RuleDocument?
    /// The document is not (or no longer) a saved rule.
    public private(set) var isNew = false
    /// The verdict shown next to the inputs: nil until a save failed, then refreshed with every edit.
    public private(set) var validation: RuleDocumentValidation?
    public private(set) var pendingSwitch: PendingSwitch?
    public private(set) var importState: RulesEditorModel.ImportState = .idle
    /// A save is running.
    public private(set) var isBusy = false

    @ObservationIgnored private let model: RulesEditorModel
    /// The document as it was opened or last saved; nil for a document whose rule vanished (it is all unsaved).
    private var baseline: RuleDocument?
    /// The saved rule `baseline` was made from.
    @ObservationIgnored private var baselineRule: Rule?
    /// Managed files this session imported and no saved rule has adopted yet.
    @ObservationIgnored private var sessionImports: Set<UUID> = []
    @ObservationIgnored private var sessionAssets: [UUID: ManagedAsset] = [:]
    /// The Content-Type row an import suggested for a card, while the user has not touched it.
    @ObservationIgnored private var suggestedTypes: [UUID: HeaderFieldRow] = [:]
    @ObservationIgnored private var cleanup: Task<Void, Never>?

    public init(model: RulesEditorModel) {
        self.model = model
    }

    /// The limits the window's problem texts name.
    public var limits: RulesLimits { model.limits }

    /// Live breakpoints are available (otherwise a breakpoint rule is saved turned off).
    public var liveBreakpoints: Bool { model.liveBreakpoints }

    /// Managed files saved rules already use, for the "return file" card's "use an imported file" menu.
    public var reusableAssets: [ManagedAsset] { model.reusableAssets }

    /// The saved groups, for the "group" menu.
    public var groups: [RuleGroup] { model.groups }

    /// The saved rules' revision; the window calls `reconcile()` whenever it changes.
    public var modelRevision: UInt64 { model.revision }

    public var isDirty: Bool { document != nil && document != baseline }

    /// The enable switch works; a rule with a breakpoint cannot be enabled while no breakpoint window exists.
    public var canEnable: Bool {
        guard let document, !model.liveBreakpoints else { return true }
        return !document.actions.contains { $0.type == .requestBreakpoint || $0.type == .responseBreakpoint }
    }

    /// The saved rule's content differs from what the document was opened from: someone else changed it. A save is
    /// refused until the user keeps their version or takes the saved one.
    public var hasExternalChange: Bool {
        guard !isNew, let baselineRule, let saved = model.rules.first(where: { $0.id == baselineRule.id }) else { return false }
        return Self.content(of: saved) != Self.content(of: baselineRule)
    }

    /// The rule without the parts the outline changes on its own (switch, place).
    private static func content(of rule: Rule) -> Rule {
        var rule = rule
        rule.enabled = true
        rule.order = 0
        rule.groupID = nil
        return rule
    }

    // MARK: opening

    public func openRule(_ id: UUID) {
        reconcile()
        guard document?.id != id, model.rules.contains(where: { $0.id == id }) else { return }
        request(.rule(id))
    }

    public func openNew(inGroup groupID: UUID?) {
        reconcile()
        request(.new(inGroup: groupID))
    }

    public func openSeed(_ draft: RuleEditorDraft) {
        reconcile()
        request(.seed(draft))
    }

    private func request(_ target: PendingSwitch) {
        guard !isBusy else {
            discardSeedAsset(of: target)
            return
        }
        if document != nil, isDirty {
            // An unanswered question is replaced: its seed (if any) will never open.
            if let old = pendingSwitch { discardSeedAsset(of: old) }
            pendingSwitch = target
            return
        }
        perform(target)
    }

    private func perform(_ target: PendingSwitch) {
        guard !isBusy else { return }
        if case .rule(let id) = target, !model.rules.contains(where: { $0.id == id }) {
            pendingSwitch = nil
            return
        }
        close()
        switch target {
        case .rule(let id):
            guard let rule = model.rules.first(where: { $0.id == id }) else { return }
            var opened = RuleDocument(rule: rule)
            let missing = resolveAssets(in: &opened)
            document = opened
            baseline = opened
            baselineRule = rule
            isNew = false
            fetch(missing, for: opened.id)
        case .new(let groupID):
            let opened = RuleDocument(startingIn: groupID.flatMap { group in model.groups.contains { $0.id == group } ? group : nil })
            document = opened
            baseline = opened
            isNew = true
        case .seed(let draft):
            var opened = RuleDocument.seed(from: draft, limits: model.limits)
            opened.groupID = nil
            document = opened
            baseline = opened
            isNew = true
            if let asset = draft.mapLocal.asset, opened.actions.contains(where: { $0.file.asset?.id == asset.id }),
                !Self.referencedAssets(in: model.rules).contains(asset.id)
            {
                sessionImports.insert(asset.id)
                sessionAssets[asset.id] = asset
            }
        }
    }

    /// Answers the question the window asked. `save` continues only when the save worked; when it needs the user's
    /// confirmation or fixes, the question stays (the window then calls `save(confirmed:)` and asks again).
    public func resolvePendingSwitch(_ choice: PendingChoice) async {
        guard let target = pendingSwitch else { return }
        switch choice {
        case .cancel:
            pendingSwitch = nil
            discardSeedAsset(of: target)
        case .discard:
            perform(target)
        case .save:
            // Saved already (the window confirmed and saved): nothing left to write.
            if isDirty { guard await save() == .saved, pendingSwitch == target else { return } }
            perform(target)
        }
    }

    /// A mock seed that will not open leaves its copied file with nobody: drop it unless something holds it.
    private func discardSeedAsset(of target: PendingSwitch) {
        guard case .seed(let draft) = target, let asset = draft.mapLocal.asset, !sessionImports.contains(asset.id),
            !Self.referencedAssets(in: model.rules).contains(asset.id),
            document?.actions.contains(where: { $0.file.asset?.id == asset.id }) != true
        else { return }
        scheduleDiscard([asset.id])
    }

    /// The question the window asks before it closes; the window then saves, discards or stays open.
    public func closeDecision() -> CloseDecision {
        reconcile()
        guard var current = document, isDirty else { return .closeNow }
        if current.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            current.name = RuleEditorWindowPresentation.autoName()
        }
        return current.validate(limits: model.limits).rule == nil ? .askDiscardOnly : .askSave(name: current.name)
    }

    /// Closes the document, dropping what was imported for it unless a saved rule uses it.
    public func discard() {
        guard !isBusy else { return }
        close()
    }

    private func close() {
        let unused = sessionImports.subtracting(Self.referencedAssets(in: model.rules))
        scheduleDiscard(unused)
        sessionImports = []
        sessionAssets = [:]
        suggestedTypes = [:]
        document = nil
        baseline = nil
        baselineRule = nil
        isNew = false
        validation = nil
        pendingSwitch = nil
        importState = .idle
    }

    // MARK: following the saved tree

    /// Brings the document in line with the saved rules. Safe to call at any time.
    public func reconcile() {
        guard var current = document, model.loadState == .loaded else { return }
        let groupExists = { (id: UUID?) in id == nil || self.model.groups.contains { $0.id == id } }
        if isNew {
            guard !groupExists(current.groupID) else { return }
            current.groupID = nil
            baseline?.groupID = nil
            document = current
            return
        }
        guard let saved = model.rules.first(where: { $0.id == current.id }) else {
            // Deleted behind the editor: what is open is a new rule now, and all of it is unsaved.
            isNew = true
            baseline = nil
            baselineRule = nil
            if !groupExists(current.groupID) { current.groupID = nil }
            document = current
            return
        }
        guard var base = baseline, var old = baselineRule else { return }
        if saved.enabled != old.enabled {
            current.enabled = saved.enabled
            base.enabled = saved.enabled
            old.enabled = saved.enabled
        }
        if saved.order != old.order {
            current.order = saved.order
            base.order = saved.order
            old.order = saved.order
        }
        if saved.groupID != old.groupID {
            if current.groupID == base.groupID { current.groupID = saved.groupID }
            base.groupID = saved.groupID
            old.groupID = saved.groupID
        }
        if !groupExists(current.groupID) { current.groupID = saved.groupID }
        document = current
        baseline = base
        baselineRule = old
    }

    /// Overwrite the other writer's change on purpose: the next save goes through.
    public func keepMyVersion() {
        reconcile()
        guard let saved = model.rules.first(where: { $0.id == document?.id }) else { return }
        baselineRule = saved
    }

    /// Take the saved rule and drop the edits.
    public func reloadSaved() {
        reconcile()
        guard let saved = model.rules.first(where: { $0.id == document?.id }) else { return }
        var reloaded = RuleDocument(rule: saved)
        let missing = resolveAssets(in: &reloaded)
        document = reloaded
        baseline = reloaded
        baselineRule = saved
        isNew = false
        validation = nil
        fetch(missing, for: reloaded.id)
    }

    // MARK: editing

    /// The only way to change the document. Ignored while a save runs; the document keeps its identity.
    public func update(_ edit: (inout RuleDocument) -> Void) {
        reconcile()
        guard !isBusy, var changed = document else { return }
        let id = changed.id
        edit(&changed)
        changed.id = id
        document = changed
        if validation != nil { validation = changed.validate(limits: model.limits) }
    }

    // MARK: saving

    @discardableResult public func save(confirmed: Bool = false) async -> SaveResult {
        reconcile()
        guard !isBusy, importState != .importing else { return .busy }
        guard var saving = document else { return .invalid }
        if hasExternalChange { return .failed(.conflict) }
        // A rule without a name is named for the user (R8F T4; replaces "the name is required").
        if saving.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            saving.name = RuleEditorWindowPresentation.autoName()
        }
        let verdict = saving.validate(limits: model.limits)
        guard var rule = verdict.rule else {
            validation = verdict
            return .invalid
        }
        if validation != nil { validation = verdict }
        if !confirmed, !verdict.confirmations.isEmpty { return .needsConfirmation(verdict.confirmations) }

        // What the tree could not take is refused here, with its own reason, before anything is written.
        if isNew {
            if model.rules.contains(where: { $0.id == saving.id }) || model.groups.contains(where: { $0.id == saving.id }) {
                return .failed(.invalidRule)
            }
            if let group = saving.groupID, !model.groups.contains(where: { $0.id == group }) { return .failed(.invalidRule) }
            if model.rules.count >= model.limits.ruleCount { return .failed(.configurationTooLarge) }
        }
        guard model.loadState == .loaded else { return .failed(.notLoaded) }
        guard model.conflict == nil else { return .failed(.conflict) }
        guard model.canMutate else { return .busy }
        if rule.enabled, rule.containsBreakpoint, !model.liveBreakpoints {
            rule.enabled = false
            saving.enabled = false
        }

        isBusy = true
        defer { isBusy = false }
        let wasNew = isNew
        model.error = nil
        let written = wasNew
            ? await model.commitNewRule(rule, inParent: rule.groupID) : await model.commitEditedRule(rule)
        guard written, let stored = model.rules.first(where: { $0.id == rule.id }) else {
            return .failed(model.error ?? (model.conflict != nil ? .conflict : .invalidRule))
        }
        // The document was closed or replaced while the save ran: the rule is saved, there is nothing to update.
        guard document?.id == saving.id else { return .saved }
        saving.order = stored.order
        saving.groupID = stored.groupID
        saving.enabled = stored.enabled
        document = saving
        baseline = saving
        baselineRule = stored
        isNew = false
        validation = nil
        // Files nothing uses any more (no saved rule, no card, not even a hidden form) go away; a card that was
        // switched to another type keeps its file for the way back.
        let keep = Self.referencedAssets(in: model.rules).union(Self.heldAssets(in: saving))
        let unused = sessionImports.subtracting(keep)
        sessionImports.subtract(unused)
        scheduleDiscard(unused)
        return .saved
    }

    // MARK: managed files

    /// Copies a chosen file into the managed store for a "return file" card. The file the card had before goes away
    /// when nothing else uses it.
    public func importFile(_ url: URL, forAction id: UUID) async {
        _ = await importFileReportingSuccess(url, forAction: id)
    }

    /// `importFile`, saying whether the card now holds the imported copy (false: refused, failed, cancelled, or the card
    /// went away meanwhile). The same file imported twice gives the same managed copy, so the card's asset alone cannot tell.
    private func importFileReportingSuccess(_ url: URL, forAction id: UUID) async -> Bool {
        reconcile()
        guard let docID = document?.id, document?.actions.contains(where: { $0.id == id }) == true, !isBusy,
            importState != .importing
        else { return false }
        importState = .importing
        let asset: ManagedAsset
        do {
            asset = try await model.importManagedFile(from: url)
        } catch {
            let code = (error as? OwnedFileError)?.code ?? .ioFailure
            importState = (code == .cancelled || error is CancellationError) ? .idle : .failed(.importFailed(code))
            return false
        }
        guard document?.id == docID, var changed = document, let index = changed.actions.firstIndex(where: { $0.id == id }) else {
            importState = .idle
            scheduleDiscard([asset.id])
            return false
        }
        let previous = changed.actions[index].file.asset
        changed.actions[index].file.asset = asset
        suggestContentType(for: url.lastPathComponent, in: &changed.actions[index])
        sessionImports.insert(asset.id)
        sessionAssets[asset.id] = asset
        document = changed
        importState = .idle
        if validation != nil { validation = changed.validate(limits: model.limits) }
        if let previous, previous.id != asset.id, sessionImports.contains(previous.id),
            !Self.heldAssets(in: changed).contains(previous.id), !Self.referencedAssets(in: model.rules).contains(previous.id)
        {
            sessionImports.remove(previous.id)
            scheduleDiscard([previous.id])
        }
        return true
    }

    /// A magic string that is the path of a local file cannot be saved (a rule holds managed copies only). This imports that
    /// file as the card's managed copy and turns the card into Return File. Nothing changes when the text is no existing
    /// file or the import fails.
    public func convertMagicStringToReturnFile(forAction id: UUID) async {
        reconcile()
        guard let card = document?.actions.first(where: { $0.id == id }), let url = card.magicStringFileURL() else { return }
        guard await importFileReportingSuccess(url, forAction: id) else { return }
        update { $0.changeType(of: id, to: .returnFile) }
    }

    /// Makes the bookmark for a "return directory" card.
    public func chooseDirectory(_ url: URL, forAction id: UUID) async {
        reconcile()
        guard let docID = document?.id, document?.actions.contains(where: { $0.id == id }) == true, !isBusy,
            importState != .importing
        else { return }
        importState = .importing
        let bookmark: Data
        do {
            bookmark = try await model.makeDirectoryBookmark(for: url)
        } catch {
            importState = .failed(.directoryFailed)
            return
        }
        guard document?.id == docID, var changed = document, let index = changed.actions.firstIndex(where: { $0.id == id }) else {
            importState = .idle
            return
        }
        changed.actions[index].directory.bookmark = bookmark
        changed.actions[index].directory.displayName = url.lastPathComponent
        document = changed
        importState = .idle
        if validation != nil { validation = changed.validate(limits: model.limits) }
    }

    /// The type of a file is suggested as a `Content-Type` header while the user has not edited the suggestion.
    private func suggestContentType(for name: String, in card: inout ActionDraft) {
        let type = RulesEditorModel.contentType(for: name)
        if let suggested = suggestedTypes[card.id], let index = card.file.headers.firstIndex(of: suggested) {
            card.file.headers[index].value = type
            suggestedTypes[card.id] = card.file.headers[index]
        } else if !card.file.headers.contains(where: { $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame }) {
            let row = HeaderFieldRow(name: "Content-Type", value: type)
            card.file.headers.insert(row, at: 0)
            suggestedTypes[card.id] = row
        }
    }

    // MARK: assets

    private static func referencedAssets(in rules: [Rule]) -> Set<UUID> {
        Set(rules.flatMap { rule in
            rule.actions.compactMap { action in
                if case .returnFile(let local) = action.kind { local.assetID } else { nil }
            }
        })
    }

    /// Every file a card holds, also in the form of a type the card is not showing.
    private static func heldAssets(in document: RuleDocument) -> Set<UUID> {
        Set(document.actions.flatMap { card in
            [card.file.asset?.id].compactMap { $0 } + Array(card.referencedAssetIDs())
        })
    }

    /// A rebuilt file card has a placeholder (no name, no size); the real asset is looked up from what the model knows.
    /// Returns the ids it could not find yet.
    private func resolveAssets(in document: inout RuleDocument) -> Set<UUID> {
        var missing: Set<UUID> = []
        for index in document.actions.indices {
            guard let placeholder = document.actions[index].file.asset, placeholder.displayName.isEmpty, placeholder.size == 0 else {
                continue
            }
            if let real = model.knownAssets[placeholder.id] ?? sessionAssets[placeholder.id] {
                document.actions[index].file.asset = real
            } else {
                missing.insert(placeholder.id)
            }
        }
        return missing
    }

    /// Looks the missing assets up in the store and puts them on the open document and its baseline, so the document
    /// stays clean.
    private func fetch(_ ids: Set<UUID>, for documentID: UUID) {
        guard !ids.isEmpty else { return }
        let lookup = model.client.asset
        Task { @MainActor in
            for id in ids {
                guard let asset = await lookup(id), document?.id == documentID else { continue }
                sessionAssets[id] = asset
                func apply(_ target: inout RuleDocument?) {
                    guard var changed = target else { return }
                    for index in changed.actions.indices where changed.actions[index].file.asset?.id == id {
                        changed.actions[index].file.asset = asset
                    }
                    target = changed
                }
                apply(&document)
                apply(&baseline)
            }
        }
    }

    private func scheduleDiscard(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let previous = cleanup
        let model = self.model
        cleanup = Task { @MainActor in
            await previous?.value
            await model.discardManagedAssets(ids)
        }
    }

    /// Waits for the file clean-up started so far (tests).
    func settled() async {
        await cleanup?.value
    }
}
