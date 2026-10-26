import FlowStore
import Foundation
import Localization
import Observation
import RulesEngine

/// Drives importing a `.pwrules` file: read and inspect, show what would be added, then on confirmation copy
/// the files into the managed store and save everything in one revision. It only adds: the saved list is the
/// existing one plus one disabled wrapper group. Files are copied only after the user confirms and the plan
/// succeeded; if anything fails or is cancelled the copies made so far are discarded, so no file is orphaned.
@MainActor @Observable public final class RulePackImporter {
    public enum Phase: Equatable, Sendable {
        case idle
        case reading(fileName: String)
        /// Counts and warnings come from the plan (what will be added), not from the file's manifest.
        case preview(RulePackPresentation.Preview)
        case importing(done: Int, total: Int)
        case finished(rules: Int, groups: Int, wrapperID: UUID)
        case failed(RulePackError)
    }

    public private(set) var phase: Phase = .idle

    @ObservationIgnored private let model: RulesEditorModel
    @ObservationIgnored private let client: RulePackClient
    @ObservationIgnored private let localizer: Localizer
    /// Changes whenever the operation is cancelled or replaced, so late results can tell they are stale.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var fileName = ""
    @ObservationIgnored private var loaded: RulePackPreview?
    @ObservationIgnored private var readTask: Task<RulePackPreview, any Error>?
    @ObservationIgnored private var copyTask: Task<ManagedAsset, any Error>?
    /// The save has started: cancelling can no longer undo it.
    @ObservationIgnored private var isCommitting = false

    public init(model: RulesEditorModel, client: RulePackClient, localizer: Localizer = L10n.localizer) {
        self.model = model
        self.client = client
        self.localizer = localizer
    }

    // MARK: begin

    /// idle → reading → preview | failed. Does nothing while the editor is busy or not loaded.
    public func begin(file: URL) async {
        guard phase == .idle, model.canMutate else { return }
        let name = file.lastPathComponent
        fileName = name
        if file.pathExtension.lowercased() == "farx" {
            phase = .failed(.farxUnsupported)
            return
        }
        generation += 1
        let mine = generation
        phase = .reading(fileName: name)
        let access = model.fileAccess, packClient = client
        let task = Task.detached(priority: .userInitiated) {
            try await access.withAccess(to: file) { try await packClient.read(file) }
        }
        readTask = task
        do {
            let preview = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard mine == generation else { return }
            let plan = try await makePlan(preview)
            guard mine == generation else { return }
            loaded = preview
            phase = .preview(RulePackPresentation.preview(plan: plan, fileName: name, localizer: localizer))
        } catch {
            guard mine == generation else { return }
            phase = .failed(packError(error))
        }
        readTask = nil
    }

    // MARK: confirm

    /// preview → importing → finished | failed. Copies the files one by one, then saves once.
    public func confirm() async {
        guard case .preview = phase, let preview = loaded, model.canMutate else { return }
        generation += 1
        let mine = generation
        model.isBusy = true
        defer { model.endBusy() }

        var imported: [UUID: UUID] = [:]  // planned id → managed asset id
        func discardAll() async {
            let ids = Set(imported.values)
            if !ids.isEmpty { await model.discardManagedAssets(ids) }
        }

        let plan: RulePackImportPlan
        do {
            plan = try await makePlan(preview)
        } catch {
            if mine == generation { phase = .failed(packError(error)) }
            return
        }
        guard mine == generation else { return }
        phase = .importing(done: 0, total: plan.assets.count)

        do {
            for (index, planned) in plan.assets.enumerated() {
                guard mine == generation else { throw CancellationError() }
                let asset = try await copy(planned, from: preview)
                imported[planned.newID] = asset.id
                guard mine == generation else { throw CancellationError() }
                phase = .importing(done: index + 1, total: plan.assets.count)
            }
        } catch {
            await discardAll()
            if mine == generation { phase = .failed(packError(error)) }
            return
        }

        var final = plan
        final.rules = plan.rules.map { rule in
            var rule = rule
            rule.actions = rule.actions.map { action in
                var action = action
                if case .returnFile(var local) = action.kind, let id = imported[local.assetID] {
                    local.assetID = id
                    action.kind = .returnFile(local)
                }
                return action
            }
            return rule
        }
        guard mine == generation else {
            await discardAll()
            return
        }
        isCommitting = true
        let saved = await model.commitImport(final)
        isCommitting = false
        if saved {
            loaded = nil
            phase = .finished(rules: plan.importedRuleCount, groups: plan.importedGroupCount, wrapperID: plan.wrapper.id)
        } else {
            await discardAll()
            phase = .failed(.saveFailed)
        }
    }

    // MARK: cancel / dismiss

    /// Any phase → idle. Copies made so far are discarded by the running `confirm`, which keeps the editor busy
    /// until that cleanup ends, so a `begin` issued at once is ignored until `confirm` has returned. The view
    /// must not offer Cancel while the final save runs (`cancel` is a no-op then). A save that already started
    /// cannot be undone, so it ends in `finished`.
    public func cancel() {
        guard !isCommitting else { return }
        generation += 1
        readTask?.cancel()
        copyTask?.cancel()
        loaded = nil
        phase = .idle
    }

    public func dismiss() {
        switch phase {
        case .finished, .failed:
            loaded = nil
            phase = .idle
        default: break
        }
    }

    // MARK: helpers

    /// The plan against the rules as they are now, computed off the main actor.
    private func makePlan(_ preview: RulePackPreview) async throws -> RulePackImportPlan {
        let existing = RuleSnapshot(revision: model.revision, groups: model.groups, rules: model.rules)
        let wrapperName = RulePackPresentation.groupName(forFile: fileName, localizer: localizer)
        let limits = model.limits, live = model.liveBreakpoints
        let task = Task.detached(priority: .userInitiated) {
            try RulePackTransform.plan(
                preview, into: existing, wrapperName: wrapperName, limits: limits, breakpointsLive: live)
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    /// Inflates one file and streams it into the managed store, away from the main actor.
    private func copy(_ planned: RulePackImportPlan.PlannedAsset, from preview: RulePackPreview) async throws -> ManagedAsset {
        guard let entry = preview.assets.first(where: { $0.id == planned.oldID }) else { throw RulePackError.missingAsset }
        let name = planned.displayName.isEmpty ? localizer.string("rules.import.defaultAssetName") : planned.displayName
        let size = planned.size
        let repository = model.client
        let task = Task.detached(priority: .userInitiated) { () -> ManagedAsset in
            let data = try preview.assetData(entry)
            guard Int64(data.count) == size else { throw RulePackError.assetMismatch }
            return try await repository.importStream(size, name) { offset, maxBytes in
                try Task.checkCancellation()
                let start = data.startIndex + Int(offset)
                let end = min(data.endIndex, start + maxBytes)
                return data.subdata(in: start..<end)
            }
        }
        copyTask = task
        defer { copyTask = nil }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    private func packError(_ error: any Error) -> RulePackError {
        switch error {
        case let error as RulePackError: error
        case is CancellationError: .cancelled
        case let error as ZipError: RulePackError(error, limits: model.limits)
        case is OwnedFileError: .saveFailed
        default: .readFailed
        }
    }
}
