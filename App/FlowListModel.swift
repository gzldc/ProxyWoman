import AppCore
import FlowStore
import Foundation
import Observation

/// The main window's view of the captured flows: mirrors the store, applies the filter and keeps
/// the sidebar groups. There is one instance per app because the store has a single subscriber.
@MainActor @Observable final class FlowListModel {
    /// Changing it recomputes `visible`.
    var filter = FlowFilter() {
        didSet {
            guard filter != state.filter else { return }
            state.setFilter(filter)
            revision &+= 1
        }
    }
    var selectedID: Int?
    /// Flows with a paused breakpoint, oldest first (written by the main window from the breakpoint
    /// queue). They are pinned to the top of `displayed`; the selection is by id and does not move.
    var pausedFlowIDs: [Int] = [] {
        didSet {
            guard pausedFlowIDs != oldValue else { return }
            revision &+= 1
        }
    }
    /// The status bar's "自动选中" switch: select the newest visible flow now and with every
    /// batch. The table turns it off when the user selects a row (so they keep what they read).
    var autoSelectsLatest = false {
        didSet {
            if autoSelectsLatest, !oldValue { selectLatest() }
        }
    }
    private(set) var hostGroups: [GroupCount] = []
    private(set) var appGroups: [GroupCount] = []
    /// Counts behind the source bar's marked / hidden / undecrypted rows.
    private(set) var sourceTally = SourceBarTally()
    /// Bumped whenever `collection` or `visible` changes; the table reloads only then.
    private(set) var revision = 0

    /// Mutated in place and not observed itself, so its large arrays are never copied per batch;
    /// the accessors below make readers observe `revision` instead. Do not hold on to the arrays
    /// they return: a lingering reference makes the next batch copy them.
    @ObservationIgnored private var state = FlowListState()
    @ObservationIgnored private var displayedCache: (revision: Int, rows: [Flow])?
    @ObservationIgnored private let store: FlowStore
    /// App name → an executable path seen for it, for the sidebar's icons. Updated per batch and
    /// kept across clears (one entry per app name).
    @ObservationIgnored private var appPaths: [String: String] = [:]
    /// Every Clear entry point goes through it: paused breakpoints of the cleared flows are counted,
    /// confirmed and then cancelled explicitly before the store is cleared.
    @ObservationIgnored private(set) var clearConfirmation: FlowClearConfirmation!

    init(store: FlowStore, breakpoints: (any BreakpointClient)? = nil) {
        self.store = store
        let changes = store.changes()
        // Runs for the app's lifetime; ends with the stream or once the model is gone.
        Task { [weak self] in
            for await change in changes {
                guard let self else { return }
                self.apply(change)
            }
        }
        clearConfirmation = FlowClearConfirmation(client: breakpoints) { [weak self] in self?.performClear() }
    }

    var collection: FlowCollection {
        _ = revision
        return state.collection
    }

    var visible: [Flow] {
        _ = revision
        return state.visible
    }

    /// The rows as the table shows them: `visible` with the paused flows pinned on top. With nothing
    /// paused it is `visible` itself. Every lookup by row index goes through it.
    var displayed: [Flow] {
        _ = revision
        guard !pausedFlowIDs.isEmpty else { return state.visible }
        if let cache = displayedCache, cache.revision == revision { return cache.rows }
        let rows = FlowDisplayOrder.pausedFirst(state.visible, paused: pausedFlowIDs)
        displayedCache = (revision, rows)
        return rows
    }

    /// The row of a flow in `displayed`, or nil when it is not listed.
    func displayedRow(ofID id: Int) -> Int? {
        let rows = displayed
        guard !pausedFlowIDs.isEmpty else { return rows.index(ofID: id) }
        let pinned = pausedFlowIDs.filter { state.visible.index(ofID: $0) != nil }
        var seen = Set<Int>()
        let top = pinned.filter { seen.insert($0).inserted }
        if let row = top.firstIndex(of: id) { return row }
        guard let index = state.visible.index(ofID: id) else { return nil }
        // The rest keeps `visible` order, minus the pinned flows that came before it.
        return index - top.filter { $0 < id }.count + top.count
    }

    /// How many flows the "不显示" rules (or the user) are keeping out of the list.
    var hiddenCount: Int {
        _ = revision
        return state.hiddenCount
    }

    /// The flow with this id unless it is hidden or gone; every window that opens a flow by id uses it.
    func shownFlow(id: Int) -> Flow? {
        collection.flow(id: id).flatMap { $0.isHidden && !showsHiddenFlows ? nil : $0 }
    }

    /// The 已隐藏 view (and "显示隐藏的流量") lists hidden flows, so they can be selected there.
    private var showsHiddenFlows: Bool { filter.source == .hidden || filter.includeHidden }

    var selectedFlow: Flow? {
        selectedID.flatMap { shownFlow(id: $0) }
    }

    /// The highlighted chips of the quick filter bar, derived from `filter`.
    var quickFilterSelection: Set<QuickFilterChip> {
        QuickFilter.selection(from: filter)
    }

    func toggleQuickFilter(_ chip: QuickFilterChip) {
        var filter = self.filter
        QuickFilter.apply(QuickFilter.toggling(chip, in: quickFilterSelection), to: &filter)
        self.filter = filter
    }

    /// "查看": shows only these flows (a snapshot: later flows that match do not join it) until cleared.
    func showRuleMatches(ids: [Int]) {
        var filter = self.filter
        QuickFilter.showRuleMatches(ids: ids, in: &filter)
        self.filter = filter
    }

    func clearRuleMatches() {
        var filter = self.filter
        QuickFilter.clearRuleMatches(&filter)
        self.filter = filter
    }

    /// The hosts an app has talked to; cheap (per-app tallies are kept incrementally), so the
    /// sidebar asks only for the apps that are expanded.
    func hostGroups(ofApp app: String) -> [GroupCount] {
        _ = revision
        return state.hostGroups(ofApp: app)
    }

    /// An executable path of the app, for its icon; nil for "未知" or when the lookup had none.
    func executablePath(ofApp app: String) -> String? {
        appPaths[app]
    }

    /// What every Clear button and command calls. With paused breakpoints of recorded flows the
    /// main window first asks (`clearConfirmation.pausedTicketCount`); otherwise it clears at once.
    func requestClear() {
        Task { await clearConfirmation.request() }
    }

    /// The store publishes the (empty) result with its next batch. The scope is reset so new
    /// traffic is not hidden behind a group that no longer exists. Clearing the store also revokes
    /// any ticket still registered for a cleared flow, so each ticket ends exactly once.
    private func performClear() {
        selectedID = nil
        filter.scope = .all
        store.clear()
    }

    func apply(_ change: FlowChange) {
        var tally = sourceTally
        tally.apply(change, previous: { state.collection.flow(id: $0) })
        if tally != sourceTally { sourceTally = tally }
        state.apply(change)
        for flow in change.upserted {
            if let client = flow.client, let path = client.executablePath, appPaths[client.name] == nil {
                appPaths[client.name] = path
            }
        }
        // The selected flow was evicted to stay within the store's limits.
        // Or it became hidden (unless the list is showing hidden flows).
        if let selectedID, let flow = state.collection.flow(id: selectedID) {
            if flow.isHidden && !showsHiddenFlows { self.selectedID = nil }
        } else if selectedID != nil {
            selectedID = nil
        }
        revision &+= 1
        // The state resets a scope whose group disappeared.
        if state.filter != filter { filter = state.filter }
        if state.hostGroups != hostGroups { hostGroups = state.hostGroups }
        if state.appGroups != appGroups { appGroups = state.appGroups }
        if autoSelectsLatest { selectLatest() }
    }

    /// Selects the oldest paused flow (`ids` is the breakpoint queue's list, oldest first); no pause keeps the selection.
    func selectEarliestPaused(of ids: [Int]) {
        guard let first = ids.first, first != selectedID else { return }
        selectedID = first
    }

    private func selectLatest() {
        guard let latest = state.visible.last?.id, latest != selectedID else { return }
        selectedID = latest
    }
}
