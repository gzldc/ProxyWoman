import Foundation

/// Keeps the URL readable while letting it use the space left by the other columns.
public enum FlowTableLayout {
    public static func urlWidth(viewport: Double, fixedColumns: Double, spacing: Double) -> Double {
        max(120, floor(viewport - fixedColumns - spacing))
    }
}
