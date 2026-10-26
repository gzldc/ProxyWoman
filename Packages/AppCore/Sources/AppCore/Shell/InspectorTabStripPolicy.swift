import Foundation

/// Pure layout rules of the right-hand tab strip and its show/hide button.
public enum InspectorTabStripPolicy {
    /// Only the selected tab spells out its title; every other tab is an icon of fixed width.
    public static func showsTitle(selected: Bool) -> Bool { selected }

    /// One button for both states; only its help / VoiceOver label changes.
    public static func toggleLabelKey(isCollapsed: Bool) -> String {
        isCollapsed ? "inspector.toggle.show" : "inspector.toggle.hide"
    }

    /// Width of an unselected tab (icon only); constant, so switching tabs never shifts the others.
    public static let iconTabWidth: Double = 34
}
