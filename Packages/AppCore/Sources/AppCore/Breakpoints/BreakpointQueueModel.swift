import FlowStore
import Foundation
import Observation
import RulesEngine

/// A one-time message about a ticket that ended or an action that did not happen.
public enum BreakpointNotice: Equatable, Sendable {
    /// The ticket ended elsewhere (timeout, Clear, connection closed). `draftDiscarded`: unsent edits were dropped.
    case ended(draftDiscarded: Bool)
    /// Continue came too late: the exchange was ended and nothing was sent.
    case expired
    /// The body of this ticket cannot be read for editing.
    case bodyUnavailable
    /// The proxy did not accept a cancel or read request (the ticket probably ended).
    case actionRejected

    public var localizationKey: String {
        switch self {
        case .ended(let discarded): discarded ? "breakpoints.notice.endedDraftDiscarded" : "breakpoints.notice.ended"
        case .expired: "breakpoints.notice.expired"
        case .bodyUnavailable: "breakpoints.notice.bodyUnavailable"
        case .actionRejected: "breakpoints.notice.actionRejected"
        }
    }
}

/// Why a ticket the user had opened ended without their own Continue or Abort.
public enum BreakpointEnded: Equatable, Sendable { case timedOut, aborted }

/// Remaining time of a ticket, from its absolute deadline (no timer of its own).
public enum BreakpointCountdown {
    public static let warningSeconds = 10

    /// Whole seconds left, rounded up; 0 once the deadline passed.
    public static func remainingSeconds(until deadline: Date, now: Date) -> Int {
        let interval = deadline.timeIntervalSince(now)
        guard interval > 0 else { return 0 }
        return Int(interval.rounded(.up))
    }

    public static func isWarning(remainingSeconds: Int) -> Bool { remainingSeconds <= warningSeconds }
}

/// The app's one view of paused breakpoint tickets, shared by the breakpoint window and the toolbar
/// badge. It is the only subscriber of the client's change feed. Each ticket keeps its own editor
/// draft until the ticket ends; a draft is never dropped without a notice. New tickets never open
/// or raise a window and never move the selection: only the count changes.
@MainActor @Observable public final class BreakpointQueueModel {
    /// Oldest first.
    public private(set) var tickets: [BreakpointTicketSnapshot] = []
    public private(set) var selectedID: UUID?
    public private(set) var notice: BreakpointNotice?
    /// A command for the selected ticket is in flight.
    public private(set) var isPerforming = false
    /// Whether matching messages are paused (the proxy's admission switch).
    public private(set) var admissionEnabled = true
    /// Turning breakpoints off with paused tickets asks whether to keep or end them.
    public private(set) var isConfirmingAdmissionOff = false
    /// Opened tickets that ended without the user's own command, by flow (the newest 64).
    /// The flow the inspector shows: a later ticket of it (a response after its request) is selected by `refresh`.
    @ObservationIgnored private var viewedFlowID: Int?
    private var endedByFlow: [Int: BreakpointEnded] = [:]
    @ObservationIgnored private var endedOrder: [Int] = []
    static let endedLimit = 64
    public let budget: HTTPEditorMemoryBudget
    public let limits: RulesLimits

    @ObservationIgnored private let client: any BreakpointClient
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var editors: [UUID: BreakpointEditorModel] = [:]
    @ObservationIgnored private var subscription: Task<Void, Never>?
    /// Overlapping refreshes: only the most recently started one applies its (newest) read.
    @ObservationIgnored private var refreshGeneration = 0
    /// The ticket whose command is awaiting its result. A refresh that finds it gone leaves the
    /// outcome to that result, so an accepted Continue is never reported as a discarded draft.
    @ObservationIgnored private var performingID: UUID?
    /// Test seam: called after every refresh.
    @ObservationIgnored var refreshObserver: (@MainActor () -> Void)?

    public init(client: any BreakpointClient, limits: RulesLimits = RulesLimits(),
                now: @escaping @Sendable () -> Date = Date.init) {
        self.client = client
        self.limits = limits
        self.now = now
        budget = HTTPEditorMemoryBudget(limits: limits)
    }

    public var pendingCount: Int { tickets.count }

    /// Flows with a paused ticket, oldest ticket first; unrecorded exchanges are skipped.
    public var pausedFlowIDs: [Int] {
        var seen = Set<Int>()
        return tickets.compactMap(\.flowID).filter { seen.insert($0).inserted }
    }

    public func ticket(forFlow id: Int) -> BreakpointTicketSnapshot? {
        tickets.first { $0.flowID == id }
    }

    /// Selects the ticket of that flow (its draft, if any, is kept); no ticket clears the selection.
    public func selectFlow(_ id: Int?) {
        select(id.flatMap { ticket(forFlow: $0)?.id })
        viewedFlowID = id
    }

    public func ended(forFlow id: Int) -> BreakpointEnded? { endedByFlow[id] }

    public func acknowledgeEnded(forFlow id: Int) {
        endedByFlow[id] = nil
        endedOrder.removeAll { $0 == id }
    }

    private func recordEnded(_ ticket: BreakpointTicketSnapshot, _ reason: BreakpointEnded) {
        guard let flow = ticket.flowID else { return }
        acknowledgeEnded(forFlow: flow)
        endedByFlow[flow] = reason
        endedOrder.append(flow)
        if endedOrder.count > Self.endedLimit { endedByFlow[endedOrder.removeFirst()] = nil }
    }

    public var selectedTicket: BreakpointTicketSnapshot? {
        selectedID.flatMap { id in tickets.first { $0.id == id } }
    }

    public var selectedEditor: BreakpointEditorModel? {
        _ = selectedID
        return selectedID.flatMap { editors[$0] }
    }

    // MARK: change feed

    /// Subscribes once for the model's lifetime; later calls do nothing.
    public func start() {
        guard subscription == nil else { return }
        let changes = client.changes()
        subscription = Task { [weak self] in
            for await _ in changes {
                guard let self else { return }
                await self.refresh()
            }
        }
    }

    /// Re-reads the tickets. Editors of tickets that ended are closed; the selected one (and any
    /// dirty draft) produces one notice.
    public func refresh() async {
        refreshGeneration += 1
        let generation = refreshGeneration
        let read = await client.tickets()
        guard generation == refreshGeneration else { return }
        let latest = read.sorted { ($0.matchedAt, $0.id.uuidString) < ($1.matchedAt, $1.id.uuidString) }
        let previous = Set(tickets.map(\.id))
        let current = Set(latest.map(\.id))
        tickets = latest

        // Every editor closed here is an opened ticket that ended without our own accepted command
        // (it may have vanished during a command the proxy then rejected): say why, oldest first.
        let time = now()
        let gone = editors.values.map(\.ticket).filter { !current.contains($0.id) && $0.id != performingID }
        for ticket in gone.sorted(by: { ($0.matchedAt, $0.id.uuidString) < ($1.matchedAt, $1.id.uuidString) }) {
            recordEnded(ticket, time >= ticket.deadline ? .timedOut : .aborted)
        }
        for flow in latest.compactMap(\.flowID) where endedByFlow[flow] != nil { acknowledgeEnded(forFlow: flow) }

        var discarded = false
        var selectedEnded = false
        for (id, editor) in editors where !current.contains(id) && id != performingID {
            if editor.isDirty { discarded = true }
            editor.close()
            editors[id] = nil
        }
        if let selectedID, !current.contains(selectedID), selectedID != performingID {
            selectedEnded = true
            self.selectedID = nil
        }
        if selectedEnded || discarded { notice = .ended(draftDiscarded: discarded) }

        for ticket in latest { editors[ticket.id]?.update(ticket) }
        if let editor = selectedEditor, editor.ticket.phase == .pausedBody { loadBody(of: editor) }

        if let viewed = viewedFlowID, let next = ticket(forFlow: viewed), !previous.contains(next.id), selectedID != next.id {
            select(next.id)
            viewedFlowID = viewed
        }

        refreshObserver?()
    }

    // MARK: selection

    public func select(_ id: UUID?) {
        guard let id, let ticket = tickets.first(where: { $0.id == id }) else {
            selectedID = nil
            viewedFlowID = nil
            return
        }
        viewedFlowID = ticket.flowID
        let editor = editors[id] ?? BreakpointEditorModel(ticket: ticket, client: client, budget: budget, limits: limits)
        editors[id] = editor
        selectedID = id
        if ticket.phase == .pausedBody { loadBody(of: editor) }
    }

    public func editor(for id: UUID) -> BreakpointEditorModel? { editors[id] }

    public func dismissNotice() {
        notice = nil
    }

    private func loadBody(of editor: BreakpointEditorModel) {
        Task { await editor.loadBodyIfNeeded() }
    }

    // MARK: commands

    /// Sends the selected draft. Invalid input stays with field errors and is not sent; a rejected
    /// edit keeps the ticket and draft; an expired ticket closes with a notice.
    public func continueSelected() async {
        guard !isPerforming, let editor = selectedEditor, !editor.isImportingFile else { return }
        guard let command = editor.continueCommand() else { return }
        isPerforming = true
        performingID = editor.id
        let result = await client.perform(command)
        performingID = nil
        isPerforming = false
        switch result {
        case .accepted: finish(editor, notice: nil)
        case .expired: finish(editor, notice: .expired)
        case .invalid, .unsupported: editor.markRejected()
        }
        await refresh()
    }

    /// Ends the selected exchange (a local error goes to the client; nothing more is forwarded).
    public func cancelSelected() async {
        guard !isPerforming, let editor = selectedEditor else { return }
        isPerforming = true
        performingID = editor.id
        let result = await client.perform(.cancel(editor.ticket.token))
        performingID = nil
        isPerforming = false
        switch result {
        case .accepted: finish(editor, notice: nil)
        case .expired: finish(editor, notice: .expired)
        case .invalid, .unsupported: notice = .actionRejected
        }
        await refresh()
    }

    /// Reads the whole body of a headers-only pause so it can be edited.
    public func collectBodySelected() async {
        guard !isPerforming, let editor = selectedEditor, editor.canCollectBody else { return }
        isPerforming = true
        performingID = editor.id
        let result = await client.perform(.collectBody(editor.ticket.token))
        performingID = nil
        isPerforming = false
        switch result {
        case .accepted: break
        case .expired: finish(editor, notice: .expired)
        case .unsupported: notice = .bodyUnavailable
        case .invalid: notice = .actionRejected
        }
        await refresh()
    }

    private func finish(_ editor: BreakpointEditorModel, notice: BreakpointNotice?) {
        if notice == .expired { recordEnded(editor.ticket, .timedOut) }
        editor.close()
        editors[editor.id] = nil
        if selectedID == editor.id { selectedID = nil }
        if let notice { self.notice = notice }
    }

    // MARK: admission

    /// Turning on applies at once. Turning off with paused tickets first asks (`isConfirmingAdmissionOff`).
    public func setAdmissionEnabled(_ enabled: Bool) async {
        if enabled {
            isConfirmingAdmissionOff = false
            await client.setAdmission(enabled: true, cancelExisting: false)
            admissionEnabled = true
            return
        }
        guard admissionEnabled else { return }
        let paused = await client.tickets()
        if paused.isEmpty {
            await client.setAdmission(enabled: false, cancelExisting: false)
            admissionEnabled = false
        } else {
            isConfirmingAdmissionOff = true
        }
    }

    /// The user's choice for the paused tickets: keep waiting, or end them all.
    public func resolveAdmissionOff(cancelExisting: Bool) async {
        guard isConfirmingAdmissionOff else { return }
        isConfirmingAdmissionOff = false
        await client.setAdmission(enabled: false, cancelExisting: cancelExisting)
        admissionEnabled = false
        await refresh()
    }

    public func cancelAdmissionOff() {
        isConfirmingAdmissionOff = false
    }
}

/// Clearing the flow list also ends the paused tickets of those flows. With any paused, the user
/// is first told how many; confirming cancels them explicitly through the client, then clears.
/// Tickets of unrecorded exchanges (no flow) are not affected by Clear.
@MainActor @Observable public final class FlowClearConfirmation {
    /// Non-nil while asking: the number of paused tickets the clear will end.
    public private(set) var pausedTicketCount: Int?

    @ObservationIgnored private let client: (any BreakpointClient)?
    @ObservationIgnored private let clear: @MainActor () -> Void

    public init(client: (any BreakpointClient)?, clear: @escaping @MainActor () -> Void) {
        self.client = client
        self.clear = clear
    }

    public func request() async {
        guard let client else {
            clear()
            return
        }
        let count = await client.tickets().filter { $0.flowID != nil }.count
        if count == 0 {
            pausedTicketCount = nil
            clear()
        } else {
            pausedTicketCount = count
        }
    }

    /// Ends the paused tickets of recorded flows, then clears. Only after `request` asked.
    public func confirm() async {
        guard pausedTicketCount != nil else { return }
        pausedTicketCount = nil
        if let client {
            let flows = Set(await client.tickets().compactMap(\.flowID))
            if !flows.isEmpty { await client.cancelTickets(forFlows: flows) }
        }
        clear()
    }

    public func dismiss() {
        pausedTicketCount = nil
    }
}
