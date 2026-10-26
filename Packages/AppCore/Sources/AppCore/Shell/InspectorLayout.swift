import Foundation

/// The tabs of the right-hand inspector, in display order.
public enum InspectorTab: String, Codable, CaseIterable, Sendable, Identifiable {
    case overview, requestDetails, rules

    public var id: Self { self }

    public var titleKey: String {
        switch self {
        case .overview: "inspector.tab.overview"
        case .requestDetails: "inspector.tab.requestDetails"
        case .rules: "inspector.tab.rules"
        }
    }

    public var icon: String {
        switch self {
        case .overview: "chart.bar.doc.horizontal"
        case .requestDetails: "doc.text.magnifyingglass"
        case .rules: "bolt"
        }
    }
}

/// Persisted layout of the right-hand inspector; missing keys decode to defaults, the width is always clamped.
public struct InspectorLayout: Codable, Equatable, Sendable {
    public static let widthRange = Double(ShellStyle.inspectorWidthRange.lowerBound)...Double(ShellStyle.inspectorWidthRange.upperBound)
    public static let defaultWidth = Double(ShellStyle.inspectorDefaultWidth)

    public var width: Double = InspectorLayout.defaultWidth {
        didSet {
            let clamped = Self.clamped(width)
            if clamped != width { width = clamped }
        }
    }
    public var isCollapsed = false
    public var tab: InspectorTab = .requestDetails
    public var sourceBarVisible = true

    public init() {}

    static func clamped(_ value: Double) -> Double {
        value.isFinite ? min(max(value, widthRange.lowerBound), widthRange.upperBound) : defaultWidth
    }

    private enum CodingKeys: String, CodingKey { case width, isCollapsed, tab, sourceBarVisible }

    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let value = try c.decodeIfPresent(Double.self, forKey: .width) { width = Self.clamped(value) }
        isCollapsed = try c.decodeIfPresent(Bool.self, forKey: .isCollapsed) ?? isCollapsed
        // A tab name from another version falls back to the default instead of dropping the whole layout.
        if let raw = try c.decodeIfPresent(String.self, forKey: .tab), let known = InspectorTab(rawValue: raw) { tab = known }
        sourceBarVisible = try c.decodeIfPresent(Bool.self, forKey: .sourceBarVisible) ?? sourceBarVisible
    }
}
