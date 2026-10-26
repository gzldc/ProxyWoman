import Foundation
import Observation

/// The page shown by the icon rail of the single main window.
public enum ShellPage: String, CaseIterable, Sendable, Identifiable {
    case traffic, compose

    public var id: Self { self }

    public var titleKey: String {
        switch self {
        case .traffic: "shell.page.traffic"
        case .compose: "shell.page.compose"
        }
    }

    public var icon: String {
        switch self {
        case .traffic: "eye"
        case .compose: "paperplane"
        }
    }
}

/// App-level state of the main window (current page, inspector layout). Lives on the app model so closing and
/// reopening the window loses nothing; the inspector layout is persisted through `persist`.
@MainActor @Observable public final class MainShellModel {
    public var page: ShellPage = .traffic
    public private(set) var inspector: InspectorLayout
    /// The Execute run whose banner the user dismissed.
    public var dismissedExecuteRunID: UUID?

    @ObservationIgnored private let persist: @MainActor (InspectorLayout) -> Void

    public init(inspector: InspectorLayout, persist: @escaping @MainActor (InspectorLayout) -> Void) {
        self.inspector = inspector
        self.persist = persist
    }

    public func selectTab(_ tab: InspectorTab) {
        update { $0.tab = tab; $0.isCollapsed = false }
    }

    public func setCollapsed(_ collapsed: Bool) {
        update { $0.isCollapsed = collapsed }
    }

    public func toggleCollapsed() { setCollapsed(!inspector.isCollapsed) }

    public func setWidth(_ width: Double) {
        let clamped = InspectorLayout.clamped(width)
        guard abs(clamped - inspector.width) >= 1 else { return }
        update { $0.width = clamped }
    }

    public func setSourceBarVisible(_ visible: Bool) {
        update { $0.sourceBarVisible = visible }
    }

    public func focusRequestDetails() {
        page = .traffic
        selectTab(.requestDetails)
    }

    public func showRules() {
        page = .traffic
        selectTab(.rules)
    }

    private func update(_ change: (inout InspectorLayout) -> Void) {
        var next = inspector
        change(&next)
        guard next != inspector else { return }
        inspector = next
        persist(next)
    }
}
