import FlowStore
import Foundation
import Observation
import RulesEngine
import os

/// Runs the rules over captured flows in the background (D13): scope, batching, cancellation, summary and
/// the in-memory "undo last run". Nothing here touches the network, the hit counts or rules.json.
@MainActor @Observable
public final class ExecuteRunner {
    public enum Phase: Equatable, Sendable {
        case idle
        case running(done: Int, total: Int)
        case finished(ExecuteSummary)
    }

    public private(set) var phase: Phase = .idle
    public private(set) var request: ExecuteRequest?
    public var flowScope: ExecuteFlowScope = .selected
    public private(set) var lastRun: (runID: UUID, flowIDs: [Int])?

    @ObservationIgnored private let store: FlowStore
    @ObservationIgnored private let snapshot: @Sendable () -> RuleSnapshot
    @ObservationIgnored private let environment: @Sendable () -> ExecuteEnvironment
    @ObservationIgnored private let batchSize: Int
    @ObservationIgnored private let afterFlow: (@Sendable (Int) async -> Void)?
    /// The rules as they were when the request was prepared (only for the count shown before starting).
    @ObservationIgnored private var preparedRules: RuleSnapshot?
    @ObservationIgnored private var frozen: Frozen?
    @ObservationIgnored private var cancelFlag = CancelFlag()
    /// Test seam: runs between evaluating a flow and writing its result.
    @ObservationIgnored var beforeWrite: (@Sendable (Int) async -> Void)?
    @ObservationIgnored private var worker: Task<Tally, Never>?

    public init(
        store: FlowStore, snapshot: @escaping @Sendable () -> RuleSnapshot,
        environment: @escaping @Sendable () -> ExecuteEnvironment, batchSize: Int = 64,
        afterFlow: (@Sendable (Int) async -> Void)? = nil
    ) {
        self.store = store
        self.snapshot = snapshot
        self.environment = environment
        self.batchSize = max(1, batchSize)
        self.afterFlow = afterFlow
    }

    // MARK: - Preparing

    /// Records what to run without running it. Ignored while a run is in progress.
    public func prepare(_ request: ExecuteRequest) {
        guard !isRunning else { return }
        self.request = request
        preparedRules = snapshot()
        flowScope = request.selectedIDs.isEmpty ? .filtered : .selected
        phase = .idle
    }

    /// How many rules the prepared request will run.
    public var ruleCount: Int {
        guard let request, let preparedRules else { return 0 }
        return ExecuteRuleSet.ruleCount(in: preparedRules, scope: request.rules)
    }

    /// How many flows `scope` offers right now.
    public func flowCount(for scope: ExecuteFlowScope) -> Int {
        guard let request else { return 0 }
        switch scope {
        case .selected: return request.selectedIDs.count
        case .filtered: return request.filteredIDs.count
        case .all: return store.visibleFlowCount
        }
    }

    public var canStart: Bool { ruleCount > 0 && flowCount(for: flowScope) > 0 && !isRunning }

    private var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    // MARK: - Running

    /// Freezes rules and flow ids now, then runs in the background. Ignored while running.
    @discardableResult
    public func start() -> Task<Void, Never>? {
        guard freeze() else { return nil }
        return Task { @MainActor [self] in await run() }
    }

    /// Prepares `request`, runs it over `scope` right away. Does nothing (nil) when there is nothing to run.
    @discardableResult
    public func runNow(_ request: ExecuteRequest, scope: ExecuteFlowScope) -> Task<Void, Never>? {
        guard !isRunning else { return nil }
        let previous = phase
        prepare(request)
        flowScope = scope
        if canStart { return start() }
        phase = previous  // a refused run keeps the last result (and its banner / Undo)
        return nil
    }

    /// The body of the run `start()` spawned. Called without `start()` it freezes first; ignored while a run is in progress.
    public func run() async {
        if frozen == nil, !freeze() { return }
        guard let frozen else { return }
        self.frozen = nil
        let store = store, batchSize = batchSize, afterFlow = afterFlow, beforeWrite = beforeWrite
        let total = frozen.ids.count
        let report: @Sendable @MainActor (Int) -> Void = { [weak self] done in
            self?.setProgress(done: done, total: total)
        }
        let worker = Task.detached(priority: .userInitiated) {
            await Self.execute(
                frozen, store: store, batchSize: batchSize, afterFlow: afterFlow, beforeWrite: beforeWrite, progress: report)
        }
        self.worker = worker
        let tally = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
        self.worker = nil
        let summary = tally.summary(runID: frozen.runID, order: frozen.snapshot.evaluationOrder.map(\.id))
        let owned = tally.writtenIDs.filter { store.flow($0)?.execute?.runID == frozen.runID }
        lastRun = owned.isEmpty ? nil : (frozen.runID, owned)
        phase = .finished(summary)
    }

    public func cancel() {
        guard isRunning else { return }
        cancelFlag.set()
        worker?.cancel()
    }

    private func freeze() -> Bool {
        guard let request, !isRunning else { return false }
        let rules = ExecuteRuleSet.snapshot(from: snapshot(), scope: request.rules)
        let ids: [Int]
        switch flowScope {
        case .selected: ids = request.selectedIDs
        case .filtered: ids = request.filteredIDs
        case .all: ids = store.visibleFlowIDs()
        }
        guard !rules.evaluationOrder.isEmpty, !ids.isEmpty else { return false }
        cancelFlag = CancelFlag()
        frozen = Frozen(
            runID: UUID(), snapshot: rules, environment: environment(), ids: ids, flag: cancelFlag)
        phase = .running(done: 0, total: ids.count)
        return true
    }

    private func setProgress(done: Int, total: Int) {
        if case .running = phase { phase = .running(done: done, total: total) }
    }

    // MARK: - Undo

    /// True only while at least one flow still carries the last run's record (cleared or evicted flows do not count).
    public var canUndoLastRun: Bool {
        guard let lastRun, !isRunning else { return false }
        return lastRun.flowIDs.contains { store.flow($0)?.execute?.runID == lastRun.runID }
    }

    /// Puts back everything the last run still owns; returns how many flows changed.
    @discardableResult
    public func undoLastRun() -> Int {
        guard let lastRun, !isRunning else { return 0 }
        var undone = 0
        for id in lastRun.flowIDs {
            var changed = false
            store.update(id) { changed = ExecuteWriter.undo(&$0, onlyRun: lastRun.runID) }
            if changed { undone += 1 }
        }
        self.lastRun = nil
        return undone
    }

    /// Undoes whatever Execute last wrote to this one flow, whichever run it was.
    @discardableResult
    public func undoFlow(_ id: Int) -> Bool {
        guard !isRunning else { return false }
        var changed = false
        store.update(id) { changed = ExecuteWriter.undo(&$0) }
        if changed, let lastRun {
            let rest = lastRun.flowIDs.filter { $0 != id }
            self.lastRun = rest.isEmpty ? nil : (lastRun.runID, rest)
        }
        return changed
    }

    // MARK: - Background loop

    private struct Frozen: Sendable {
        var runID: UUID
        var snapshot: RuleSnapshot
        var environment: ExecuteEnvironment
        var ids: [Int]
        var flag: CancelFlag
    }

    private struct Tally: Sendable {
        var lineCounts: [UUID: Int] = [:]
        var considered = 0
        var matched = 0
        var modified = 0
        var hidden = 0
        var annotated = 0
        var skippedInProgress = 0
        var skippedHidden = 0
        var notApplicable = 0
        var vanished = 0
        var cancelled = false
        var writtenIDs: [Int] = []

        func summary(runID: UUID, order: [UUID]) -> ExecuteSummary {
            ExecuteSummary(
                runID: runID, rules: order.map { .init(ruleID: $0, flows: lineCounts[$0] ?? 0) },
                considered: considered, matchedFlows: matched, modifiedFlows: modified, hiddenFlows: hidden,
                annotatedFlows: annotated, skippedInProgress: skippedInProgress, skippedHidden: skippedHidden,
                notApplicableActions: notApplicable, vanished: vanished, wasCancelled: cancelled)
        }
    }

    private nonisolated static func execute(
        _ run: Frozen, store: FlowStore, batchSize: Int, afterFlow: (@Sendable (Int) async -> Void)?,
        beforeWrite: (@Sendable (Int) async -> Void)?,
        progress: @escaping @Sendable @MainActor (Int) -> Void
    ) async -> Tally {
        var tally = Tally()
        ExecuteEngine.prepare(run.snapshot, cache: run.environment.cache)
        var done = 0
        for id in run.ids {
            if run.flag.isSet || Task.isCancelled {
                tally.cancelled = true
                break
            }
            guard await process(id, run: run, store: store, beforeWrite: beforeWrite, tally: &tally) else { break }
            done += 1
            if done % batchSize == 0 || done == run.ids.count { await progress(done) }
            await afterFlow?(id)
        }
        return tally
    }

    /// false: the run was cancelled inside this flow (nothing was written for it, it does not count as done).
    private nonisolated static func process(
        _ id: Int, run: Frozen, store: FlowStore, beforeWrite: (@Sendable (Int) async -> Void)?, tally: inout Tally
    ) async -> Bool {
        guard let flow = store.flow(id) else {
            tally.vanished += 1
            return true
        }
        let result: ExecuteFlowResult
        do {
            result = try await ExecuteEngine.run(flow, snapshot: run.snapshot, environment: run.environment)
        } catch {
            tally.cancelled = true
            return false
        }
        tally.considered += 1
        switch result.skipped {
        case .inProgress: tally.skippedInProgress += 1; return true
        case .hidden: tally.skippedHidden += 1; return true
        case nil: break
        }
        await beforeWrite?(id)
        // A flow cleared or evicted since it was read: `update` reports it and releases the bodies this
        // result brought, so a dropped overlay never leaks a managed body.
        var record: ExecuteRecord?
        let found = store.update(id) { stored in
            ExecuteWriter.apply(result, runID: run.runID, to: &stored)
            record = stored.execute
        }
        if !found {
            tally.vanished += 1
            return true
        }
        if let ids = result.matches?.ruleIDs, !ids.isEmpty {
            tally.matched += 1
            for ruleID in Set(ids) { tally.lineCounts[ruleID, default: 0] += 1 }
        }
        tally.notApplicable += result.notApplicableActions
        if result.overlay != nil { tally.modified += 1 }
        if let record, record.runID == run.runID {
            tally.writtenIDs.append(id)
            if record.written.isHidden && !record.baseline.isHidden { tally.hidden += 1 }
            if record.written.ruleMark != record.baseline.ruleMark || record.written.comment != record.baseline.comment {
                tally.annotated += 1
            }
        }
        return true
    }
}

private final class CancelFlag: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: false)
    var isSet: Bool { state.withLock { $0 } }
    func set() { state.withLock { $0 = true } }
}
