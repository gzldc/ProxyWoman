import Testing

@testable import AppCore

@Suite(.productionChinese) struct SidebarNavigationTests {
    private let rows: [SidebarNavigationRow<String>] = [
        .init(id: "pinned", canExpand: true, isExpanded: true),
        .init(id: "unavailable", parent: "pinned", isEnabled: false),
        .init(id: "saved", parent: "pinned"),
        .init(id: "apps", canExpand: true, isExpanded: true),
        .init(id: "app", parent: "apps", canExpand: true),
        .init(id: "hosts", canExpand: true),
    ]

    @Test func verticalMovementFollowsVisibleOrderAndSkipsDisabledRows() {
        #expect(SidebarNavigation.action(.down, selected: "pinned", rows: rows) == .select("saved"))
        #expect(SidebarNavigation.action(.up, selected: "saved", rows: rows) == .select("pinned"))
        #expect(SidebarNavigation.action(.down, selected: "hosts", rows: rows) == nil)
        #expect(SidebarNavigation.action(.up, selected: "pinned", rows: rows) == nil)
    }

    @Test func hiddenOrMissingSelectionStartsAtVisibleBoundary() {
        #expect(SidebarNavigation.action(.down, selected: "hidden", rows: rows) == .select("pinned"))
        #expect(SidebarNavigation.action(.up, selected: nil, rows: rows) == .select("hosts"))
        #expect(SidebarNavigation.action(.down, selected: "unavailable", rows: rows) == .select("saved"))
    }

    @Test func rightExpandsBeforeEnteringFirstEnabledChild() {
        #expect(SidebarNavigation.action(.right, selected: "app", rows: rows) == .expand("app", true))
        #expect(SidebarNavigation.action(.right, selected: "pinned", rows: rows) == .select("saved"))
        #expect(SidebarNavigation.action(.right, selected: "saved", rows: rows) == nil)
    }

    @Test func leftCollapsesBeforeReturningToParent() {
        #expect(SidebarNavigation.action(.left, selected: "apps", rows: rows) == .expand("apps", false))
        #expect(SidebarNavigation.action(.left, selected: "app", rows: rows) == .select("apps"))
        #expect(SidebarNavigation.action(.left, selected: "saved", rows: rows) == .select("pinned"))
        #expect(SidebarNavigation.action(.left, selected: "hosts", rows: rows) == nil)
    }

    @Test func activationCannotSelectUnavailableOrHiddenRows() {
        #expect(SidebarNavigation.action(.activate, selected: "saved", rows: rows) == .select("saved"))
        #expect(SidebarNavigation.action(.activate, selected: "unavailable", rows: rows) == nil)
        #expect(SidebarNavigation.action(.activate, selected: "hidden", rows: rows) == nil)
        #expect(SidebarNavigation.action(.down, selected: nil, rows: [SidebarNavigationRow<String>]()) == nil)
    }

    @Test func expandedEmptyGroupDoesNotEnterFollowingSibling() {
        let empty = [SidebarNavigationRow(id: "empty", canExpand: true, isExpanded: true), .init(id: "sibling")]
        #expect(SidebarNavigation.action(.right, selected: "empty", rows: empty) == nil)
    }
}
