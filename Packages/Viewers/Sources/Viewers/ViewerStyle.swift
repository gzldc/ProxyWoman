import AppKit
import SwiftUI

/// Display preferences supplied by the app without coupling viewers to its settings model.
public struct ViewerStyle: Equatable, Sendable {
    public var fontSize: Double
    public var monospaced: Bool
    public var wrapsLines: Bool
    public var showsInvisibles: Bool

    public init(fontSize: Double = 12, monospaced: Bool = true, wrapsLines: Bool = true, showsInvisibles: Bool = false)
    {
        self.fontSize = fontSize
        self.monospaced = monospaced
        self.wrapsLines = wrapsLines
        self.showsInvisibles = showsInvisibles
    }

    var font: Font { .system(size: fontSize, design: monospaced ? .monospaced : .default) }
    var nsFont: NSFont {
        monospaced ? .monospacedSystemFont(ofSize: fontSize, weight: .regular) : .systemFont(ofSize: fontSize)
    }
}
