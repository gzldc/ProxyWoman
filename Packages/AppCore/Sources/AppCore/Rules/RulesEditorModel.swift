import FlowStore
import Foundation
import Localization
import Observation
import RulesEngine
import UniformTypeIdentifiers

/// The repository operations the editor uses, as Foundation-only closures. Production uses
/// `live(repository:assets:)`; tests may wrap the live closures to count or gate calls.
public struct RulesRepositoryClient: Sendable {
    public var load: @Sendable () async throws -> RuleSnapshot
    /// Saves the groups and rules as the next revision. A conflict is `RuleRepositoryError.conflict`; the editor
    /// takes the newer state from `published`.
    public var save: @Sendable (_ groups: [RuleGroup], _ rules: [Rule], _ expectedRevision: UInt64) async throws
        -> RuleSnapshot
    public var reset: @Sendable () async throws -> RuleConfigurationReset
    public var importFile: @Sendable (_ source: URL, _ displayName: String) async throws -> ManagedAsset
    public var discardImports: @Sendable (Set<UUID>) async -> Void
    public var asset: @Sendable (UUID) async -> ManagedAsset?
    /// Copies `expectedSize` bytes produced by `read` into a new managed asset, one bounded chunk at a time.
    public var importStream: @Sendable (
        _ expectedSize: Int64, _ displayName: String,
        _ read: @escaping @Sendable (_ offset: Int64, _ maxBytes: Int) async throws -> Data
    ) async throws -> ManagedAsset
    /// The snapshot the proxy currently uses.
    public var published: @Sendable () -> RuleSnapshot
    /// Marks the stored upgrade notice as read. Only that flag changes: no revision is spent (D11), so an open
    /// draft does not conflict.
    public var acknowledgeNotice: @Sendable () async throws -> RuleSnapshot
    /// Adds the built-in template set once per version, replacing an untouched first-generation group (R8F3).
    /// Throws `notLoaded` unless a client supplies it.
    public var installTemplates: @Sendable (_ set: DefaultTemplateSet, _ legacy: LegacyTemplateTexts?, _ expectedRevision: UInt64)
        async throws -> RuleSnapshot

    public init(
        load: @escaping @Sendable () async throws -> RuleSnapshot,
        save: @escaping @Sendable ([RuleGroup], [Rule], UInt64) async throws -> RuleSnapshot,
        reset: @escaping @Sendable () async throws -> RuleConfigurationReset,
        importFile: @escaping @Sendable (URL, String) async throws -> ManagedAsset,
        discardImports: @escaping @Sendable (Set<UUID>) async -> Void,
        asset: @escaping @Sendable (UUID) async -> ManagedAsset?,
        published: @escaping @Sendable () -> RuleSnapshot,
        importStream: @escaping @Sendable (Int64, String, @escaping @Sendable (Int64, Int) async throws -> Data) async throws
            -> ManagedAsset,
        acknowledgeNotice: @escaping @Sendable () async throws -> RuleSnapshot,
        installTemplates: @escaping @Sendable (DefaultTemplateSet, LegacyTemplateTexts?, UInt64) async throws -> RuleSnapshot
    ) {
        self.load = load
        self.save = save
        self.reset = reset
        self.importFile = importFile
        self.discardImports = discardImports
        self.asset = asset
        self.published = published
        self.importStream = importStream
        self.acknowledgeNotice = acknowledgeNotice
        self.installTemplates = installTemplates
    }

    public static func live(repository: RuleRepository, assets: ManagedAssetStore) -> Self {
        Self(
            load: { try await repository.load() },
            save: { try await repository.save(groups: $0, rules: $1, expectedRevision: $2) },
            reset: { try await repository.resetUnreadableConfiguration() },
            importFile: { try await assets.importFile($0, displayName: $1) },
            discardImports: { await assets.discardImports($0) },
            asset: { await assets.asset($0) },
            published: { repository.provider.current() },
            importStream: { try await assets.importStream(expectedSize: $0, displayName: $1, read: $2) },
            acknowledgeNotice: { try await repository.acknowledgeMigrationNotice() },
            installTemplates: { try await repository.installDefaultTemplates($0, legacy: $1, expectedRevision: $2) })
    }
}

/// Access to a user-picked file. With a security-scoped URL the scope must enclose the whole
/// awaited copy; `start` returning false (no sandbox) is not a failure, and then nothing is stopped.
public struct ScopedFileAccess: Sendable {
    public var start: @Sendable (URL) -> Bool
    public var stop: @Sendable (URL) -> Void

    public init(start: @escaping @Sendable (URL) -> Bool, stop: @escaping @Sendable (URL) -> Void) {
        self.start = start
        self.stop = stop
    }

    public static let securityScoped = ScopedFileAccess(
        start: { $0.startAccessingSecurityScopedResource() }, stop: { $0.stopAccessingSecurityScopedResource() })

    /// Runs `body` inside the scope; the scope taken is released once, after `body` finished or threw.
    public func withAccess<T: Sendable>(to url: URL, _ body: @Sendable () async throws -> T) async throws -> T {
        let started = start(url)
        defer { if started { stop(url) } }
        return try await body()
    }
}

/// Makes the bookmark a Map Local directory rule stores, as a Foundation-only closure. Production uses
/// `live`; tests inject a fake so no real bookmark (and no path) is needed.
public struct DirectoryBookmarking: Sendable {
    public var make: @Sendable (_ directory: URL) throws -> Data

    public init(make: @escaping @Sendable (URL) throws -> Data) {
        self.make = make
    }

    public static let live = DirectoryBookmarking(make: { try DirectoryBookmark.make(for: $0) })
}

/// A failure the rules editor shows. Messages are whole localized sentences.
public enum RulesEditorError: Equatable, Sendable {
    /// Another save published first; the user must rebase or discard before saving again.
    case conflict
    case unavailable(RuleConfigurationProblem)
    case notLoaded
    case loadFailed
    case invalidRule
    case unknownAsset
    case configurationTooLarge
    case revisionExhausted
    case storage(OwnedFileError.Code)
    case backupFailed(OwnedFileError.Code)
    case importFailed(OwnedFileError.Code)
    /// No bookmark could be made for the chosen directory.
    case directoryFailed
    /// Breakpoint rules cannot be enabled until the breakpoint editor exists (T9a-GPT-R37).
    case breakpointsUnavailable

    public var localizationKey: String {
        switch self {
        case .conflict: "rules.error.conflict"
        case .unavailable(let problem):
            switch problem {
            case .corrupt: "rules.error.unavailable.corrupt"
            case .unsupportedSchema: "rules.error.unavailable.unsupportedSchema"
            case .tooLarge: "rules.error.unavailable.tooLarge"
            case .unreadable: "rules.error.unavailable.unreadable"
            case .migrationFailed: "rules.error.unavailable.migrationFailed"
            }
        case .notLoaded: "rules.error.notLoaded"
        case .loadFailed: "rules.error.loadFailed"
        case .invalidRule: "rules.error.invalidRule"
        case .unknownAsset: "rules.error.unknownAsset"
        case .configurationTooLarge: "rules.error.configurationTooLarge"
        case .revisionExhausted: "rules.error.revisionExhausted"
        case .storage(let code): code == .insufficientDiskSpace ? "rules.error.storage.diskFull" : "rules.error.storage"
        case .backupFailed(let code):
            switch code {
            case .insufficientDiskSpace: "rules.error.backup.diskFull"
            case .notRegularFile: "rules.error.backup.notRegularFile"
            default: "rules.error.backup"
            }
        case .importFailed(let code):
            switch code {
            case .notRegularFile: "rules.error.import.notRegularFile"
            case .fileTooLarge: "rules.error.import.fileTooLarge"
            case .capacityExceeded: "rules.error.import.capacityExceeded"
            case .insufficientDiskSpace: "rules.error.import.insufficientDiskSpace"
            case .sourceChanged: "rules.error.import.sourceChanged"
            default: "rules.error.import"
            }
        case .directoryFailed: "rules.error.directory"
        case .breakpointsUnavailable: "rules.error.breakpointsUnavailable"
        }
    }

    public func message(localizer: Localizer = L10n.localizer) -> String {
        localizer.string(localizationKey)
    }

    init(_ error: any Error) {
        switch error {
        case let error as RuleRepositoryError:
            switch error {
            case .conflict: self = .conflict
            case .unavailable(let problem): self = .unavailable(problem)
            case .notLoaded: self = .notLoaded
            case .invalidRule: self = .invalidRule
            case .unknownAsset: self = .unknownAsset
            case .configurationTooLarge: self = .configurationTooLarge
            case .revisionExhausted: self = .revisionExhausted
            case .storage(let error): self = .storage(error.code)
            case .configurationReadable: self = .loadFailed
            case .backupFailed(let error): self = .backupFailed(error.code)
            }
        case let error as OwnedFileError where error.code == .unknownAsset:
            self = .unknownAsset
        case let error as OwnedFileError:
            self = .storage(error.code)
        default:
            self = .loadFailed
        }
    }
}

/// The app-lifetime rules editor shared by every view of the rules. It loads the repository exactly once,
/// edits one draft at a time, and changes the published rules only through repository saves, which
/// publish after the file is durable. One mutation runs at a time; while it is in flight (or a
/// revision conflict is unresolved, or the stored file is unreadable) every other mutation is refused.
@MainActor @Observable public final class RulesEditorModel {
    public enum LoadState: Equatable, Sendable {
        case notLoaded, loading, loaded
        /// The stored file could not be read. A failed migration offers a retry; every other problem offers
        /// a reset (with backup).
        case unavailable(RuleConfigurationProblem)
        case failed
    }

    public enum ImportState: Equatable, Sendable {
        case idle, importing
        case failed(RulesEditorError)
    }

    /// A navigation that would drop unsaved changes, waiting for the user's confirmation.
    public enum PendingNavigation: Equatable, Sendable {
        case select(UUID?)
        case draft(RuleEditorDraft)
    }

    public private(set) var loadState: LoadState = .notLoaded
    /// The last committed rules, in stored order (the evaluation order while there are no groups).
    public private(set) var rules: [Rule] = []
    /// The groups of the committed rules. This editor does not change them; a save writes them back as they are.
    public private(set) var groups: [RuleGroup] = []
    public private(set) var revision: UInt64 = 0
    @ObservationIgnored private let cardNumbering = RuleCardNumbering()
    /// The card number (0-based) an outcome of a committed rule's stored action is shown against; nil keeps the stored
    /// number. The rule's document is built once per rule and revision.
    public func outcomeCardIndex(rule id: UUID, stored: Int, code: RuleOutcomeCode) -> Int? {
        cardNumbering.index(rule: rules.first { $0.id == id }, revision: revision, stored: stored, code: code)
    }
    /// The upgrade notice of the stored file (spec 5.6.4), kept with its pairs after it was read so "view
    /// upgrade notes" can show it again. Saves carry it along unchanged.
    public private(set) var migrationNotice: MigrationNotice?
    /// The user asked to see an already read notice again.
    public private(set) var isUpgradeNoticeReopened = false
    /// The selected rule (or the unsaved new draft).
    public private(set) var selection: UUID?
    public private(set) var draft: RuleEditorDraft?
    /// Field errors of the last save attempt, refreshed while the user fixes them.
    public private(set) var issues: [RuleDraftField: RuleDraftIssue] = [:]
    public internal(set) var error: RulesEditorError?
    /// The newer saved state a stale save ran into; saving stays closed until rebase or discard.
    public private(set) var conflict: RuleSnapshot?
    public internal(set) var isBusy = false
    public private(set) var importState: ImportState = .idle
    /// Bytes of a captured response copied so far and in all, while `beginMockDraft` runs.
    public private(set) var mockImportProgress: (done: Int64, total: Int64)?
    public private(set) var pendingNavigation: PendingNavigation?
    /// File name of the backup written by the last reset.
    public private(set) var lastBackupName: String?
    /// A reset finished and its notice was not dismissed yet.
    public private(set) var didReset = false
    /// Metadata of managed assets saved rules reference.
    public private(set) var knownAssets: [UUID: ManagedAsset] = [:]
    /// False until the breakpoint editor can continue paused traffic: breakpoint rules are then saved
    /// disabled and cannot be enabled, so no request is ever paused without a way to continue it.
    public let liveBreakpoints: Bool
    public let limits: RulesLimits

    @ObservationIgnored let client: RulesRepositoryClient
    @ObservationIgnored let fileAccess: ScopedFileAccess
    @ObservationIgnored let directoryBookmarking: DirectoryBookmarking
    @ObservationIgnored private var directoryGeneration = 0
    @ObservationIgnored var templateInstallAttempted = false
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    /// The saved state of the current draft; nil for a draft that was never saved.
    @ObservationIgnored private var baseline: RuleEditorDraft?
    /// Where a new duplicate goes once saved.
    @ObservationIgnored private var insertAfter: UUID?
    @ObservationIgnored private var pendingInsertAfter: UUID?
    /// Changes whenever the draft is replaced, so late import results can tell they are stale.
    @ObservationIgnored private var draftSession = UUID()
    /// Fresh imports made for the current draft session and not yet adopted by a save.
    @ObservationIgnored private var sessionImports: Set<UUID> = []
    @ObservationIgnored private var importGeneration = 0
    @ObservationIgnored private var importTask: Task<ManagedAsset, any Error>?
    /// The fresh copy of a mock draft that waits for the user's answer about unsaved changes.
    @ObservationIgnored private var pendingNavigationAsset: UUID?
    /// Callers waiting for the running mutation to finish (import completions).
    @ObservationIgnored private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    /// The Content-Type row the last import suggested, while the user has not edited it.
    @ObservationIgnored private var suggestedContentType: HeaderFieldRow?
    /// Test seam: called when an import result has to wait for a running mutation.
    @ObservationIgnored var importDeferredHook: (() -> Void)?

    public init(
        client: RulesRepositoryClient, limits: RulesLimits, liveBreakpoints: Bool = false,
        fileAccess: ScopedFileAccess = .securityScoped, directoryBookmarking: DirectoryBookmarking = .live
    ) {
        self.client = client
        self.limits = limits
        self.liveBreakpoints = liveBreakpoints
        self.fileAccess = fileAccess
        self.directoryBookmarking = directoryBookmarking
    }

    public convenience init(
        repository: RuleRepository, assets: ManagedAssetStore, limits: RulesLimits, liveBreakpoints: Bool = false,
        directoryBookmarking: DirectoryBookmarking = .live
    ) {
        self.init(
            client: .live(repository: repository, assets: assets), limits: limits, liveBreakpoints: liveBreakpoints,
            directoryBookmarking: directoryBookmarking)
    }

    // MARK: state

    /// Mutations (saves, toggles, deletes, moves, new drafts) are allowed.
    public var canMutate: Bool { loadState == .loaded && !isBusy && conflict == nil }

    /// The draft may be saved: mutations are allowed, the draft is one this editor can state, and no file
    /// import for it is still running, so a save never races an import that would replace or release the
    /// asset it references.
    public var canSave: Bool {
        canMutate && draft != nil && draft?.readOnlyReason == nil && importState != .importing
    }

    /// The stored rules could not be migrated: reading them again is the way out.
    public var offersMigrationRetry: Bool { loadState == .unavailable(.migrationFailed) }

    /// The stored file is unreadable and a reset (which backs it up and starts empty) is the way out. Never
    /// for a failed migration (the file is fine, and a reset would clear every rule in it) nor for a file
    /// made by another version (`unsupportedSchema`, which that version still reads).
    public var offersReset: Bool {
        if case .unavailable(let problem) = loadState { problem.allowsReset } else { false }
    }

    /// The stored file has an upgrade notice with something to show (a listed pair, or pairs it counts).
    public var hasUpgradeNotice: Bool { migrationNotice?.listsAffectedRules == true }

    /// There is an upgrade notice the user has not acknowledged yet.
    public var hasUnreadUpgradeNotice: Bool { hasUpgradeNotice && migrationNotice?.acknowledged == false }

    /// The block at the top of the Rules tab: the notice, while it is unread or after "view upgrade notes".
    public var showsUpgradeNotice: Bool { hasUnreadUpgradeNotice || (hasUpgradeNotice && isUpgradeNoticeReopened) }

    /// "Got it" can be pressed: closing a notice that was read before needs nothing; writing the flag needs the
    /// editor to be idle (no other mutation, no unresolved conflict).
    public var canAcknowledgeUpgradeNotice: Bool {
        hasUpgradeNotice && (migrationNotice?.acknowledged == true || canMutate)
    }

    /// What the block shows; nil while it is not shown. Rules deleted since the migration keep their row, under
    /// the placeholder name.
    public var upgradeNotice: UpgradeNoticePresentation? {
        guard showsUpgradeNotice else { return nil }
        let names = Dictionary(rules.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        return UpgradeNoticePresentation.make(notice: migrationNotice, ruleName: { names[$0] })
    }

    /// The saved rule is one this editor cannot state (several actions, a final flag, an occurrence range,
    /// a condition it has no field for). It can be switched, copied, moved and deleted, not edited.
    public func isReadOnly(_ id: UUID) -> Bool {
        rules.first { $0.id == id }.map { $0.oldEditorForm == nil } ?? false
    }

    /// "Copying the response body… 3 MB / 12 MB" while a captured response is copied.
    public var mockImportProgressText: String? {
        mockImportProgress.map {
            L10n.format("rules.mock.importing", Formatting.size(Int(clamping: $0.done)), Formatting.size(Int(clamping: $0.total)))
        }
    }

    public var isDraftNew: Bool { draft.map { id in !rules.contains { $0.id == id.id } } ?? false }

    /// Unsaved changes: a new draft, or one that differs from its saved state.
    public var isDraftDirty: Bool {
        guard let draft else { return false }
        return baseline != draft
    }

    /// The selected saved breakpoint rule is turned off. Builds before the breakpoint editor saved
    /// every breakpoint rule turned off, so the form says how to turn it on.
    public var showsSavedDisabledBreakpointNotice: Bool {
        guard liveBreakpoints, let draft, draft.kind == .breakpoint, !isDraftNew,
              let rule = rules.first(where: { $0.id == draft.id }),
              rule.simple.map({ RuleKind($0.action) }) == .breakpoint else { return false }
        return !rule.enabled
    }

    /// Managed assets saved rules already use, newest import first.
    public var reusableAssets: [ManagedAsset] {
        let referenced = referencedAssetIDs(in: rules)
        return knownAssets.values.filter { referenced.contains($0.id) }
            .sorted { ($0.importedAt, $0.id.uuidString) > ($1.importedAt, $1.id.uuidString) }
    }

    // MARK: load

    /// Reads the repository once per app lifetime; concurrent and later calls share that one read.
    /// A failure keeps the last valid (initially empty) published rules and is shown, never reset.
    public func load() async {
        if let loadTask {
            await loadTask.value
            return
        }
        let task = Task { @MainActor in await self.performLoad() }
        loadTask = task
        await task.value
    }

    /// Reads the file again after a failed migration (the old file was left as it was; every try makes its
    /// own backup). Does nothing in any other state.
    public func retryMigration() async {
        guard offersMigrationRetry, !isBusy else { return }
        loadTask = nil
        error = nil
        await load()
    }

    private func performLoad() async {
        loadState = .loading
        do {
            let snapshot = try await client.load()
            apply(snapshot)
            loadState = .loaded
            await refreshAssets()
        } catch RuleRepositoryError.unavailable(let problem) {
            apply(client.published())
            loadState = .unavailable(problem)
        } catch {
            apply(client.published())
            loadState = .failed
            self.error = .loadFailed
        }
    }

    // MARK: navigation

    /// Selects a saved rule (nil: none). With unsaved changes this only asks (`pendingNavigation`).
    public func requestSelection(_ id: UUID?) {
        guard !isBusy, id != selection else { return }
        if isDraftDirty {
            discardPendingNavigationAsset()
            pendingNavigation = .select(id)
            return
        }
        select(id)
    }

    /// Starts an unsaved draft for a new rule of `kind`.
    public func beginDraft(kind: RuleKind) {
        guard canMutate else { return }
        var draft = RuleEditorDraft(kind: kind)
        if kind == .breakpoint, !liveBreakpoints { draft.enabled = false }
        navigate(to: draft)
    }

    /// Starts an unsaved draft matching `flow`'s original request (T9a-GPT-R32). Nothing is saved.
    public func beginDraft(from flow: Flow, kind: RuleKind) {
        guard canMutate else { return }
        var draft = RuleEditorDraft.fromFlow(flow, kind: kind)
        if kind == .breakpoint, !liveBreakpoints { draft.enabled = false }
        navigate(to: draft)
    }

    /// An unsaved copy of a saved rule with a new identity; once saved it goes right after the original. A
    /// rule this editor cannot state has no draft to hold its copy: `duplicateReadOnly` copies those.
    public func duplicate(id: UUID) {
        guard canMutate, let rule = rules.first(where: { $0.id == id }), rule.oldEditorForm != nil else { return }
        var copy = RuleEditorDraft(rule: rule, asset: assetForRule(rule))
        copy.id = UUID()
        navigate(to: copy, after: id)
    }

    /// Saves a copy of a rule this editor cannot state at once, right after the original: every action, the
    /// conditions, the group and the note as they are, under a new identity. False when there is no such
    /// rule or the copy was not saved; the editor's draft is left alone.
    @discardableResult public func duplicateReadOnly(id: UUID) async -> Bool {
        guard canMutate, let index = rules.firstIndex(where: { $0.id == id }), rules[index].oldEditorForm == nil else { return false }
        var copy = rules[index]
        copy.id = UUID()
        var next = rules
        next.insert(copy, at: index + 1)
        return await commit(next)
    }

    public func confirmPendingNavigation() {
        guard let pending = pendingNavigation, !isBusy else { return }
        pendingNavigation = nil
        switch pending {
        case .select(let id): select(id)
        case .draft(let draft):
            let adopted = pendingNavigationAsset
            pendingNavigationAsset = nil
            replaceDraft(with: draft, baseline: nil, after: pendingInsertAfter)
            if let adopted { sessionImports.insert(adopted) }
        }
    }

    public func cancelPendingNavigation() {
        clearPendingNavigation()
    }

    /// `importedAsset` is a fresh copy the new draft already references: it belongs to the draft's
    /// session once the draft opens, and goes if the user declines to replace the unsaved one.
    private func navigate(to draft: RuleEditorDraft, after: UUID? = nil, importedAsset: UUID? = nil) {
        if isDraftDirty {
            discardPendingNavigationAsset()
            pendingNavigation = .draft(draft)
            pendingInsertAfter = after
            pendingNavigationAsset = importedAsset
            return
        }
        replaceDraft(with: draft, baseline: nil, after: after)
        if let importedAsset { sessionImports.insert(importedAsset) }
    }

    private func clearPendingNavigation() {
        discardPendingNavigationAsset()
        pendingNavigation = nil
    }

    private func discardPendingNavigationAsset() {
        guard let id = pendingNavigationAsset else { return }
        pendingNavigationAsset = nil
        let client = self.client
        Task { await client.discardImports([id]) }
    }

    private func select(_ id: UUID?) {
        guard let id, let rule = rules.first(where: { $0.id == id }) else {
            replaceDraft(with: nil, baseline: nil, after: nil)
            return
        }
        let draft = RuleEditorDraft(rule: rule, asset: assetForRule(rule))
        replaceDraft(with: draft, baseline: draft, after: nil)
    }

    /// Ends the current draft session: abandons its import and discards its unadopted imports.
    private func replaceDraft(with draft: RuleEditorDraft?, baseline: RuleEditorDraft?, after: UUID?) {
        cancelImport()
        discardSessionImports()
        directoryGeneration += 1
        draftSession = UUID()
        suggestedContentType = nil
        self.draft = draft
        self.baseline = baseline
        selection = draft?.id
        insertAfter = after
        issues = [:]
        clearPendingNavigation()
    }

    // MARK: upgrade notice

    /// "Got it": writes that the notice was read and hides the block. The failure keeps the block and shows
    /// the error, so the user can try again. Closing a notice that was already read (opened again by
    /// `reopenUpgradeNotice`) writes nothing.
    public func acknowledgeUpgradeNotice() async {
        guard let notice = migrationNotice, notice.listsAffectedRules else { return }
        if notice.acknowledged {
            isUpgradeNoticeReopened = false
            return
        }
        guard canMutate else { return }
        isBusy = true
        defer { endBusy() }
        do {
            // Only the flag changed in the file, so only the notice is taken over: the rules the editor shows
            // are the ones it committed, and the revision stays.
            migrationNotice = try await client.acknowledgeNotice().migrationNotice
            isUpgradeNoticeReopened = false
            error = nil
        } catch {
            self.error = RulesEditorError(error)
        }
    }

    /// "View upgrade notes": shows a notice that was acknowledged before.
    public func reopenUpgradeNotice() {
        if hasUpgradeNotice { isUpgradeNoticeReopened = true }
    }

    /// A click on a pair of the notice: selects the rule with the lower priority (asking first when the
    /// current draft has unsaved changes). A rule that was deleted since the migration cannot be selected.
    public func select(fromNotice item: UpgradeNoticeItem) {
        guard rules.contains(where: { $0.id == item.lowerID }) else { return }
        requestSelection(item.lowerID)
    }

    // MARK: editing

    /// The editor's binding setter. Ignored while a mutation runs or for another draft's state.
    public func setDraft(_ updated: RuleEditorDraft) {
        guard !isBusy, let current = draft, current.id == updated.id, current.readOnlyReason == nil else { return }
        var updated = updated
        if updated.kind == .breakpoint, !liveBreakpoints { updated.enabled = false }
        draft = updated
        if !issues.isEmpty { issues = updated.validate(order: 0, limits: limits).issues }
    }

    /// Uses an asset that is already managed (for example one another rule uses).
    public func useAsset(_ asset: ManagedAsset) {
        guard !isBusy, var draft else { return }
        let previous = draft.mapLocal.asset
        draft.mapLocal.asset = asset
        self.draft = draft
        if let previous, previous.id != asset.id { release(previous.id) }
    }

    /// Reverts to the saved state (a new draft is closed). Resolves a conflict by taking the newer rules.
    public func discardChanges() {
        guard !isBusy else { return }
        if let conflict {
            self.conflict = nil
            apply(conflict)
        }
        error = nil
        clearPendingNavigation()
        let id = draft?.id
        select(rules.contains { $0.id == id } ? id : nil)
    }

    /// Keeps the dirty draft but continues from the newer saved rules, so the next save is explicit.
    public func rebaseOnLatest() {
        guard let conflict, !isBusy else { return }
        self.conflict = nil
        error = nil
        apply(conflict)
        if let draft, !rules.contains(where: { $0.id == draft.id }) { baseline = nil }
        Task { await refreshAssets() }
    }

    public func dismissError() {
        error = nil
    }

    public func dismissResetNotice() {
        lastBackupName = nil
        didReset = false
    }

    // MARK: Map Local import

    /// Copies `source` into the managed asset store for the current draft, inside the file's
    /// security scope. A result for a draft that was replaced or cancelled meanwhile is discarded.
    public func importAsset(from source: URL) async {
        guard draft != nil, !isBusy else { return }
        cancelImport()
        importGeneration += 1
        let generation = importGeneration, session = draftSession
        importState = .importing
        let client = self.client, access = self.fileAccess
        let name = source.lastPathComponent
        let task = Task { try await access.withAccess(to: source) { try await client.importFile(source, name) } }
        importTask = task
        let result = await task.result
        // A mutation started while the file was copied: its transaction may reference the current
        // asset, so the draft is neither changed nor any asset released until it has finished.
        if isBusy {
            importDeferredHook?()
            await waitUntilIdle()
        }
        let isCurrent = generation == importGeneration && session == draftSession && draft != nil
        switch result {
        case .success(let asset):
            guard isCurrent, var draft else {
                await client.discardImports([asset.id])
                return
            }
            importTask = nil
            importState = .idle
            sessionImports.insert(asset.id)
            knownAssets[asset.id] = asset
            let previous = draft.mapLocal.asset
            draft.mapLocal.asset = asset
            let type = Self.contentType(for: name)
            if let suggested = suggestedContentType, let index = draft.mapLocal.headers.firstIndex(of: suggested) {
                // Still the untouched suggestion for the previous file: follow the new file.
                draft.mapLocal.headers[index].value = type
                suggestedContentType = draft.mapLocal.headers[index]
            } else if !draft.mapLocal.headers.contains(where: { $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame }) {
                let row = HeaderFieldRow(name: "Content-Type", value: type)
                draft.mapLocal.headers.insert(row, at: 0)
                suggestedContentType = row
            }
            self.draft = draft
            if !issues.isEmpty { issues = draft.validate(order: 0, limits: limits).issues }
            if let previous, previous.id != asset.id { await release(previous.id)?.value }
        case .failure(let failure):
            guard isCurrent else { return }
            importTask = nil
            if (failure as? OwnedFileError)?.code == .cancelled || failure is CancellationError {
                importState = .idle
            } else {
                importState = .failed(.importFailed((failure as? OwnedFileError)?.code ?? .ioFailure))
            }
        }
    }

    /// Stops the running import; its copy (if it still completes) is discarded.
    public func cancelImport() {
        importGeneration += 1
        importTask?.cancel()
        importTask = nil
        importState = .idle
        mockImportProgress = nil
    }

    // MARK: response mock

    /// Starts an unsaved Map Local draft from the response `flow` carried to the client: its status,
    /// its usable headers and a managed copy of its body (copied in 64 KiB chunks through a read
    /// lease, never loaded whole). A flow that cannot become a mock returns the reason at once and
    /// changes nothing. A failed copy sets `error`; a cancelled or superseded one is silent; neither
    /// leaves a draft or a managed file behind. With unsaved changes the draft waits for the user's
    /// confirmation like any other new draft. With `deliver` the finished draft goes there (the rule editor window) and
    /// the model keeps none; the copied file is then the receiver's.
    public func beginMockDraft(
        from flow: Flow, acquireBody: BodyLeaseAcquirer?, deliver: (@MainActor (RuleEditorDraft) -> Void)? = nil
    ) async -> MockBlockReason? {
        guard canMutate else { return nil }
        let source: ResponseMockSource
        switch ResponseMockExtractor.extract(from: flow, limits: limits) {
        case .failure(let reason): return reason
        case .success(let extracted): source = extracted
        }
        cancelImport()
        let generation = importGeneration
        error = nil
        importState = .importing
        mockImportProgress = (0, source.size)
        let client = self.client
        let progress: @Sendable (Int64) async -> Void = { [weak self] done in
            await self?.setMockImportProgress(done: done, total: source.size, generation: generation)
        }
        let task = Task { () throws -> ManagedAsset in
            guard let body = source.body else {
                return try await client.importStream(0, source.displayName) { _, _ in Data() }
            }
            guard let acquireBody else { throw OwnedFileError(.ioFailure) }
            let lease = try acquireBody(body.ref)
            // The lease is released however the copy ends.
            defer { lease.cancel() }
            return try await client.importStream(
                source.size, source.displayName, ResponseMockDraft.reader(lease: lease, slice: body, progress: progress))
        }
        importTask = task
        let result = await task.result
        // A mutation started while the body was copied: the draft is replaced only after it finished.
        if isBusy {
            importDeferredHook?()
            await waitUntilIdle()
        }
        let isCurrent = generation == importGeneration
        switch result {
        case .success(let asset):
            guard isCurrent else {
                await client.discardImports([asset.id])
                return nil
            }
            importTask = nil
            importState = .idle
            mockImportProgress = nil
            let made = ResponseMockDraft.make(from: flow, source: source, asset: asset)
            if let deliver { deliver(made) } else { navigate(to: made, importedAsset: asset.id) }
        case .failure(let failure):
            guard isCurrent else { return nil }
            importTask = nil
            importState = .idle
            mockImportProgress = nil
            if (failure as? OwnedFileError)?.code != .cancelled, !(failure is CancellationError) {
                error = .importFailed((failure as? OwnedFileError)?.code ?? .ioFailure)
            }
        }
        return nil
    }

    /// Stops a running response copy; nothing is kept.
    public func cancelMockImport() {
        cancelImport()
    }

    private func setMockImportProgress(done: Int64, total: Int64, generation: Int) {
        guard generation == importGeneration, importState == .importing else { return }
        mockImportProgress = (done, total)
    }

    /// The suggested type of a newly imported file; unknown types are `application/octet-stream`.
    static func contentType(for name: String) -> String {
        let fileExtension = (name as NSString).pathExtension
        return UTType(filenameExtension: fileExtension)?.preferredMIMEType ?? "application/octet-stream"
    }

    // MARK: Map Local directory

    /// Makes the bookmark for `url` inside the directory's security scope (`access`, by default the
    /// model's) and stores it in the current draft with the directory's name. The picked path itself is
    /// never kept. A result for a draft that was replaced meanwhile, or superseded by a newer choice, is
    /// dropped; a failure shows `rules.error.directory` and leaves the draft as it was.
    public func chooseDirectory(_ url: URL, access: ScopedFileAccess? = nil) async {
        guard draft != nil, !isBusy else { return }
        directoryGeneration += 1
        let generation = directoryGeneration, session = draftSession
        let access = access ?? fileAccess, bookmarking = directoryBookmarking
        let task = Task { () -> Result<Data, any Error> in
            do { return .success(try await access.withAccess(to: url) { try bookmarking.make(url) }) } catch { return .failure(error) }
        }
        let result = await task.value
        // A mutation started meanwhile may be saving this draft: change it only after it has finished.
        if isBusy { await waitUntilIdle() }
        guard generation == directoryGeneration, session == draftSession, var draft else { return }
        switch result {
        case .success(let bookmark):
            draft.mapLocalDirectory.bookmark = bookmark
            draft.mapLocalDirectory.displayName = url.lastPathComponent
            self.draft = draft
            error = nil
            if !issues.isEmpty { issues = draft.validate(order: 0, limits: limits).issues }
        case .failure:
            error = .directoryFailed
        }
    }

    // MARK: mutations

    /// Validates and saves the draft. Field errors save nothing; a failed save keeps the committed
    /// rules and the dirty draft (with its imports) for a retry.
    @discardableResult public func save() async -> Bool {
        guard canSave, var draft else { return false }
        if draft.kind == .breakpoint, !liveBreakpoints { draft.enabled = false }
        let index = rules.firstIndex { $0.id == draft.id }
        // A rule that became one this editor cannot state (another window saved it with several actions)
        // is not overwritten by the form that still shows its old single action.
        if let index, rules[index].oldEditorForm == nil {
            error = .conflict
            return false
        }
        let validation = draft.validate(order: index ?? rules.count, limits: limits)
        guard var rule = validation.rule else {
            issues = validation.issues
            return false
        }
        issues = [:]
        var next = rules
        if let index {
            rule = rule.replacing(rules[index])
            next[index] = rule
        } else if let after = insertAfter, let position = next.firstIndex(where: { $0.id == after }) {
            next.insert(rule, at: position + 1)
        } else {
            next.append(rule)
        }
        let session = draftSession
        guard await commit(next) else { return false }
        if session == draftSession {
            self.draft = draft
            baseline = draft
            selection = draft.id
            insertAfter = nil
            if draft.kind == .mapLocal, let asset = draft.mapLocal.asset { knownAssets[asset.id] = asset }
            discardSessionImports()
        }
        return true
    }

    /// Enables or disables a saved rule and publishes that at once.
    @discardableResult public func setEnabled(id: UUID, enabled: Bool) async -> Bool {
        guard canMutate, let index = rules.firstIndex(where: { $0.id == id }) else { return false }
        if enabled, rules[index].containsBreakpoint, !liveBreakpoints {
            error = .breakpointsUnavailable
            return false
        }
        var next = rules
        next[index].enabled = enabled
        guard await commit(next) else { return false }
        if draft?.id == id {
            draft?.enabled = enabled
            baseline?.enabled = enabled
        }
        return true
    }

    /// Deletes a saved rule (the caller confirms first); an unsaved draft is just closed.
    @discardableResult public func delete(id: UUID) async -> Bool {
        guard canMutate else { return false }
        guard rules.contains(where: { $0.id == id }) else {
            if draft?.id == id { replaceDraft(with: nil, baseline: nil, after: nil) }
            return false
        }
        guard await commit(rules.filter { $0.id != id }) else { return false }
        if selection == id { replaceDraft(with: nil, baseline: nil, after: nil) }
        return true
    }

    /// Moves saved rules like `Array.move(fromOffsets:toOffset:)` and publishes the new order.
    @discardableResult public func move(fromOffsets source: IndexSet, toOffset destination: Int) async -> Bool {
        guard canMutate, source.allSatisfy({ rules.indices.contains($0) }), (0...rules.count).contains(destination) else {
            return false
        }
        let moving = source.map { rules[$0] }
        var next = rules.enumerated().filter { !source.contains($0.offset) }.map(\.element)
        let insertion = destination - source.filter { $0 < destination }.count
        next.insert(contentsOf: moving, at: insertion)
        return await commit(next)
    }

    /// Saves the rules in the order of `ids`, which must be a permutation of the saved rule IDs.
    @discardableResult public func reorder(ids: [UUID]) async -> Bool {
        guard canMutate, ids.count == rules.count, Set(ids) == Set(rules.map(\.id)) else { return false }
        let byID = Dictionary(uniqueKeysWithValues: rules.map { ($0.id, $0) })
        return await commit(ids.compactMap { byID[$0] })
    }

    /// Backs up the unreadable configuration and replaces it with an empty one (explicit user action).
    @discardableResult public func resetUnavailableConfiguration() async -> Bool {
        guard offersReset, !isBusy else { return false }
        isBusy = true
        defer { endBusy() }
        do {
            let reset = try await client.reset()
            apply(reset.snapshot)
            lastBackupName = reset.backupName
            didReset = true
            loadState = .loaded
            error = nil
            return true
        } catch {
            self.error = RulesEditorError(error)
            return false
        }
    }

    // MARK: helpers

    func endBusy() {
        isBusy = false
        let waiters = idleWaiters
        idleWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    private func waitUntilIdle() async {
        while isBusy {
            await withCheckedContinuation { idleWaiters.append($0) }
        }
    }

    /// Saves `next` (numbered, see `numbered`) with the committed groups against the committed revision.
    /// A caller that already holds `isBusy` (the pack importer) keeps it: only the owner releases it.
    func commit(_ next: [Rule], groups newGroups: [RuleGroup]? = nil) async -> Bool {
        let heldByCaller = isBusy
        isBusy = true
        defer { if !heldByCaller { endBusy() } }
        do {
            let snapshot = try await client.save(newGroups ?? groups, newGroups == nil ? numbered(next) : next, revision)
            apply(snapshot)
            error = nil
            return true
        } catch RuleRepositoryError.conflict {
            // The newer rules are what the repository published.
            conflict = client.published()
            error = .conflict
            return false
        } catch {
            self.error = RulesEditorError(error)
            return false
        }
    }

    func apply(_ snapshot: RuleSnapshot) {
        // Kept in sibling order, so saving by array position never reorders what the tree set.
        rules = RuleTree(groups: snapshot.groups, rules: snapshot.rules).normalized().rules
        groups = snapshot.groups
        revision = snapshot.revision
        migrationNotice = snapshot.migrationNotice
    }

    /// `rules` numbered for saving. A rule's number is its position among the rules of its parent, as the list
    /// shows them. Groups are not this editor's to move (D20): where a parent also holds groups, its rules keep
    /// the numbers they have (handed on to the rules in their new sequence) so no group changes place among
    /// them, and a rule without a number yet goes after everything else there.
    private func numbered(_ rules: [Rule]) -> [Rule] {
        var result = rules
        let saved = Set(self.rules.map(\.id))
        for parent in Set(rules.map(\.groupID)) {
            let indices = result.indices.filter { result[$0].groupID == parent }
            let groupNumbers = groups.filter { $0.parentID == parent }.map(\.order)
            guard !groupNumbers.isEmpty else {
                for (position, index) in indices.enumerated() { result[index].order = position }
                continue
            }
            var numbers = indices.filter { saved.contains(result[$0].id) }.map { result[$0].order }.sorted()
            var next = (numbers + groupNumbers).max().map { $0 + 1 } ?? 0
            for index in indices {
                if saved.contains(result[index].id) {
                    result[index].order = numbers.removeFirst()
                } else {
                    result[index].order = next
                    next += 1
                }
            }
        }
        return result
    }

    func refreshAssets() async {
        for id in referencedAssetIDs(in: rules) where knownAssets[id] == nil {
            if let asset = await client.asset(id) { knownAssets[id] = asset }
        }
    }

    private func referencedAssetIDs(in rules: [Rule]) -> Set<UUID> {
        Set(rules.flatMap { rule in
            rule.actions.compactMap { action in
                if case .returnFile(let local) = action.kind { local.assetID } else { nil }
            }
        })
    }

    private func assetForRule(_ rule: Rule) -> ManagedAsset? {
        if case .mapLocal(let local)? = rule.simple?.action { knownAssets[local.assetID] } else { nil }
    }

    /// Discards one fresh import of this session unless a saved rule uses it. Never called while a
    /// mutation runs, so no in-flight transaction can reference it.
    @discardableResult private func release(_ id: UUID) -> Task<Void, Never>? {
        guard !isBusy, sessionImports.remove(id) != nil, !referencedAssetIDs(in: rules).contains(id) else { return nil }
        let client = self.client
        return Task { await client.discardImports([id]) }
    }

    private func discardSessionImports() {
        let unused = sessionImports.subtracting(referencedAssetIDs(in: rules))
        sessionImports = []
        guard !unused.isEmpty else { return }
        let client = self.client
        Task { await client.discardImports(unused) }
    }
}

// MARK: external writers (MCP, spec D12)

/// What an external writer (the MCP rules adapter) gets back. Nothing here touches the editor session the
/// user may have open: no draft is replaced, no field error or banner is set for a refusal.
public enum ExternalRuleOutcome: Equatable, Sendable {
    case saved(id: UUID, enabled: Bool, revision: UInt64)
    /// The rule was not saved; the editor's own validation found these field problems.
    case invalid([RuleDraftField: RuleDraftIssue])
    case notFound
    /// A mutation runs, or the rules are not loaded: try again.
    case busy
    /// The user has unsaved changes to this rule in the editor.
    case beingEdited
    /// The rule is enabled and the caller may not change enabled rules.
    case ruleIsEnabled
    /// The saved rules changed under the write (the editor keeps the conflict for the user to resolve).
    case conflict
    /// A breakpoint rule cannot be enabled until the breakpoint editor can continue paused traffic.
    case breakpointsUnavailable
}

extension RulesEditorModel {
    /// Reads the repository on first use (the editor window may never have been opened).
    public func loadIfNeeded() async {
        await load()
    }

    /// Saves a draft built by an external writer, validated by the same `RuleEditorDraft.validate` the
    /// editor's save uses and committed through the same revision-checked `commit`. A new id appends; an
    /// existing id replaces the rule in place, so the order never changes. The open editor session is left
    /// alone, except that a clean form showing the saved rule is refreshed to what was saved.
    @discardableResult public func commitExternal(
        draft external: RuleEditorDraft, isNew: Bool, allowEnabledRule: Bool
    ) async -> ExternalRuleOutcome {
        guard canMutate else { return conflict != nil ? .conflict : .busy }
        var external = external
        let index = rules.firstIndex { $0.id == external.id }
        if let refusal = externalRefusal(of: external.id, at: index, isNew: isNew, allowEnabledRule: allowEnabledRule) {
            return refusal
        }
        // Changed to one this editor cannot state since the writer read it: not overwritten.
        if let index, rules[index].oldEditorForm == nil, external.readOnlyReason == nil { return .conflict }
        if external.kind == .breakpoint, !liveBreakpoints { external.enabled = false }
        let validation = external.validate(order: index ?? rules.count, limits: limits)
        guard let rule = validation.rule else { return .invalid(validation.issues) }
        return await writeExternal(rule, at: index)
    }

    /// Saves a whole rule built by an external writer, for rules a single draft cannot hold (several actions).
    /// The same rules as the draft overload: a new id appends, an existing id replaces the rule in place (group,
    /// note and position stay), and the open editor session is left alone. The writer has validated the rule and
    /// names the problems itself; the check here is the guard that nothing the shared validator rejects is saved,
    /// and it can only name the rule as a whole (`.name`). A rule with a breakpoint is saved disabled until
    /// breakpoints can go live, like a breakpoint draft.
    @discardableResult public func commitExternal(
        rule external: Rule, isNew: Bool, allowEnabledRule: Bool
    ) async -> ExternalRuleOutcome {
        guard canMutate else { return conflict != nil ? .conflict : .busy }
        let index = rules.firstIndex { $0.id == external.id }
        if let refusal = externalRefusal(of: external.id, at: index, isNew: isNew, allowEnabledRule: allowEnabledRule) {
            return refusal
        }
        var rule = external
        if rule.containsBreakpoint, !liveBreakpoints { rule.enabled = false }
        rule.order = index.map { rules[$0].order } ?? rules.count
        do {
            try rule.validate(limits: limits)
        } catch let error as RuleValidationError {
            return .invalid([.name: RuleDraftIssue(error)])
        } catch {
            return .invalid([.name: .headerInvalid])
        }
        return await writeExternal(rule, at: index)
    }

    /// Why an external write of the rule `id` (at `index` among the saved rules, nil when it is not saved) cannot
    /// go ahead; nil when it can.
    private func externalRefusal(of id: UUID, at index: Int?, isNew: Bool, allowEnabledRule: Bool) -> ExternalRuleOutcome? {
        switch (isNew, index) {
        case (true, .some): return .conflict
        case (false, .none): return .notFound
        case (false, .some(let existing)):
            if draft?.id == id, isDraftDirty { return .beingEdited }
            if rules[existing].enabled, !allowEnabledRule { return .ruleIsEnabled }
            return nil
        case (true, .none): return nil
        }
    }

    /// Appends `rule`, or replaces the saved rule at `index` with it, and commits.
    private func writeExternal(_ rule: Rule, at index: Int?) async -> ExternalRuleOutcome {
        var rule = rule
        var next = rules
        if let index {
            rule = rule.replacing(rules[index])
            next[index] = rule
        } else {
            next.append(rule)
        }
        guard await commit(next) else { return conflict != nil ? .conflict : .busy }
        refreshCleanDraft(of: rule.id)
        return savedOutcome(for: rule.id)
    }

    /// Enables or disables a saved rule and publishes that at once. Asking for the state the rule already has
    /// writes nothing.
    @discardableResult public func setEnabledExternal(id: UUID, enabled: Bool) async -> ExternalRuleOutcome {
        guard canMutate else { return conflict != nil ? .conflict : .busy }
        guard let index = rules.firstIndex(where: { $0.id == id }) else { return .notFound }
        if draft?.id == id, isDraftDirty { return .beingEdited }
        if enabled, rules[index].containsBreakpoint, !liveBreakpoints { return .breakpointsUnavailable }
        guard rules[index].enabled != enabled else { return savedOutcome(for: id) }
        var next = rules
        next[index].enabled = enabled
        guard await commit(next) else { return conflict != nil ? .conflict : .busy }
        // The form was clean (a dirty one is refused above): it follows the saved state.
        if draft?.id == id {
            draft?.enabled = enabled
            baseline?.enabled = enabled
        }
        return savedOutcome(for: id)
    }

    private func savedOutcome(for id: UUID) -> ExternalRuleOutcome {
        .saved(id: id, enabled: rules.first { $0.id == id }?.enabled ?? false, revision: revision)
    }

    /// A form that shows `id` without unsaved changes is rebuilt from the committed rule, so a later save of
    /// that form cannot silently undo the external change. A dirty form is never reached (it is refused first).
    private func refreshCleanDraft(of id: UUID) {
        guard draft?.id == id, !isDraftDirty, let rule = rules.first(where: { $0.id == id }) else { return }
        let fresh = RuleEditorDraft(rule: rule, asset: assetForRule(rule))
        draft = fresh
        baseline = fresh
    }
}

// MARK: rules as this editor shows them

extension Rule {
    /// Some action of the rule is a breakpoint, which cannot be enabled until the breakpoint editor exists.
    public var containsBreakpoint: Bool {
        actions.contains { if case .breakpoint = $0.kind { true } else { false } }
    }

    /// This rule saved over `stored` by an editor that shows only part of a rule. What the editor does not
    /// show stays (group, note, position number), and so do the stored rows when nothing the editor shows
    /// changed: they may be in an order the editor does not write, and rewriting them would restart the
    /// rule's hit count for nothing.
    fileprivate func replacing(_ stored: Rule) -> Rule {
        var rule = self
        rule.groupID = stored.groupID
        rule.note = stored.note
        rule.order = stored.order
        if let old = stored.oldEditorForm, old == oldEditorForm { rule.conditions = stored.conditions }
        return rule
    }
}
