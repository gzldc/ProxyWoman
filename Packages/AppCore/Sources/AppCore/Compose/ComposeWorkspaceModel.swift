import Foundation
import Localization
import Observation

/// The Compose page's tabs. It lives on the app model, so closing the main window loses nothing:
/// every tab (and its draft) is still here when the window opens again. Closing a tab that has
/// unsent changes or a running send asks first; "save draft" parks the tab (its model stays open,
/// files kept) in a list that lasts for this run only.
@MainActor @Observable public final class ComposeWorkspaceModel {
    public enum CloseChoice: Sendable { case saveDraft, discard, cancel }

    public struct Parked: Identifiable {
        public let id: UUID
        public let model: ComposeViewModel
        public let parkedAt: Date
    }

    public static let maxParked = 20
    public static let messageKeys = ["compose.page.untitled", "compose.tab.title"]

    public private(set) var tabs: [ComposeViewModel] = []
    public var selectedID: UUID?
    /// Newest first; this run only; at most `maxParked`.
    public private(set) var parked: [Parked] = []
    /// The tab waiting for the user's three-way answer.
    public private(set) var pendingClose: UUID?
    /// Tabs whose clean close is in flight, so a second × cannot run `close()` twice.
    @ObservationIgnored private var closing: Set<UUID> = []
    @ObservationIgnored private let make: @MainActor (ComposeDraft) -> ComposeViewModel
    @ObservationIgnored private let now: () -> Date

    public init(make: @escaping @MainActor (ComposeDraft) -> ComposeViewModel, now: @escaping () -> Date = Date.init) {
        self.make = make
        self.now = now
    }

    public var selected: ComposeViewModel? { tabs.first { $0.id == selectedID } }

    /// Adds a tab for `draft` and selects it.
    @discardableResult public func open(_ draft: ComposeDraft) -> ComposeViewModel {
        let model = make(draft)
        tabs.append(model)
        selectedID = model.id
        return model
    }

    @discardableResult public func newBlankTab() -> ComposeViewModel {
        open(ComposeDraft())
    }

    /// A tab with nothing to lose closes at once; otherwise the user is asked (`pendingClose`).
    public func requestClose(_ id: UUID) async {
        // One question at a time: a request made while another tab is being asked about is ignored.
        guard pendingClose == nil, !closing.contains(id), let model = tabs.first(where: { $0.id == id }) else { return }
        if model.closeAssessment == .none {
            // Closed first, removed after: the tab never disappears while its files are still held.
            closing.insert(id)
            await model.close()
            removeTab(id)
            closing.remove(id)
        } else {
            pendingClose = id
        }
    }

    /// The page went away (another page was chosen) while a question was open: answer it as cancel,
    /// so later closes are not ignored.
    public func cancelPendingClose() {
        pendingClose = nil
    }

    public func resolveClose(_ choice: CloseChoice) async {
        guard let id = pendingClose else { return }
        pendingClose = nil
        guard choice != .cancel, let model = tabs.first(where: { $0.id == id }) else { return }
        switch choice {
        case .saveDraft:
            // A running send is stopped; a running import is left to finish so the parked draft
            // keeps its body.
            model.cancel()
            removeTab(id)
            parked.insert(Parked(id: model.id, model: model, parkedAt: now()), at: 0)
            if parked.count > Self.maxParked {
                let dropped = parked.removeLast()
                await dropped.model.close()
            }
        case .discard:
            await model.closeConfirmed()
            removeTab(id)
        case .cancel:
            break
        }
    }

    /// Brings a parked draft back as a tab (the same model object) and selects it.
    public func reopen(_ parkedID: UUID) {
        guard let index = parked.firstIndex(where: { $0.id == parkedID }) else { return }
        let entry = parked.remove(at: index)
        tabs.append(entry.model)
        selectedID = entry.model.id
    }

    public func discardParked(_ parkedID: UUID) async {
        guard let index = parked.firstIndex(where: { $0.id == parkedID }) else { return }
        let entry = parked.remove(at: index)
        await entry.model.close()
    }

    /// "METHOD host", or "New request" when the URL has no host.
    public static func title(of model: ComposeViewModel, localizer: Localizer = L10n.localizer) -> String {
        let draft = model.draft
        guard let host = URLComponents(string: draft.url)?.host, !host.isEmpty else {
            return localizer.string("compose.page.untitled")
        }
        return localizer.format("compose.tab.title", arguments: [draft.method, host])
    }

    private func removeTab(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: index)
        if selectedID == id {
            if index < tabs.count {
                selectedID = tabs[index].id
            } else {
                selectedID = tabs.last?.id
            }
        }
    }
}
