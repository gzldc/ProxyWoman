import AppKit
import FlowStore
import Foundation

public enum MarkColorName: String, CaseIterable, Sendable {
    case red, orange, yellow, green, cyan, blue, purple, gray
}

public struct MarkPreset: Sendable, Equatable, Identifiable {
    public let name: MarkColorName
    public let lightHex: String
    public let darkHex: String
    public var id: String { name.rawValue }

    /// 整串字面键，不拼接（见 LiteralKeyScanTests）。
    public var localizationKey: String {
        switch name {
        case .red: "mark.color.red"
        case .orange: "mark.color.orange"
        case .yellow: "mark.color.yellow"
        case .green: "mark.color.green"
        case .cyan: "mark.color.cyan"
        case .blue: "mark.color.blue"
        case .purple: "mark.color.purple"
        case .gray: "mark.color.gray"
        }
    }
}

/// 标记颜色：8 个系统色预设（浅 / 深两套）、自定义色的深色换算和行底色。记录里只存浅色 `#RRGGBB`。
public enum MarkPalette {
    /// The row fill of a 6-digit (opacity-less) mark colour, as it always was.
    public static let rowFillAlpha: Double = 0.15
    /// The row fill of an 8-digit colour at full opacity; the colour's own opacity scales it, so a solid entry paints
    /// clearly (but stays readable under the text) and a semi-transparent one paints lighter.
    public static let solidRowFillAlpha: Double = 0.35

    /// The opacity (0...1) an `#RRGGBBAA` carries; 1 for `#RRGGBB` and anything else.
    public static func opacity(ofHex hex: String) -> Double {
        guard hex.count == 9, hex.first == "#", let value = Int(hex.suffix(2), radix: 16) else { return 1 }
        return Double(value) / 255
    }

    /// What a mark background fills a row with: `rowFillAlpha` for `#RRGGBB`, the colour's opacity times
    /// `solidRowFillAlpha` for `#RRGGBBAA`.
    public static func rowFillAlpha(forHex hex: String) -> Double {
        hex.count == 9 ? solidRowFillAlpha * opacity(ofHex: hex) : rowFillAlpha
    }

    public static let presets: [MarkPreset] = [
        MarkPreset(name: .red, lightHex: "#FF3B30", darkHex: "#FF453A"),
        MarkPreset(name: .orange, lightHex: "#FF9500", darkHex: "#FF9F0A"),
        MarkPreset(name: .yellow, lightHex: "#FFCC00", darkHex: "#FFD60A"),
        MarkPreset(name: .green, lightHex: "#34C759", darkHex: "#30D158"),
        MarkPreset(name: .cyan, lightHex: "#30B0C7", darkHex: "#40C8E0"),
        MarkPreset(name: .blue, lightHex: "#007AFF", darkHex: "#0A84FF"),
        MarkPreset(name: .purple, lightHex: "#AF52DE", darkHex: "#BF5AF2"),
        MarkPreset(name: .gray, lightHex: "#8E8E93", darkHex: "#98989D"),
    ]

    public static func preset(forHex hex: String) -> MarkPreset? {
        let upper = hex.uppercased()
        return presets.first { $0.lightHex == upper || $0.darkHex == upper }
    }

    public static func darkHex(forLightHex hex: String) -> String {
        // The opacity of an `#RRGGBBAA` is not part of the colour: the dark pair is of the `#RRGGBB`.
        let upper = hex.count == 9 ? String(hex.uppercased().prefix(7)) : hex.uppercased()
        if let preset = presets.first(where: { $0.lightHex == upper }) { return preset.darkHex }
        return adaptedForDark(hex)
    }

    /// HSB：饱和度 ×0.85、亮度 ×0.80，逐通道四舍五入到 8 位。非法输入原样返回。纯函数。
    public static func adaptedForDark(_ hex: String) -> String {
        guard let channels = channels(of: hex) else { return hex }
        let r = Double(channels.0) / 255, g = Double(channels.1) / 255, b = Double(channels.2) / 255
        let maxV = max(r, g, b), minV = min(r, g, b)
        let delta = maxV - minV
        var hue = 0.0
        if delta > 0 {
            if maxV == r {
                hue = (g - b) / delta
                if hue < 0 { hue += 6 }
            } else if maxV == g {
                hue = (b - r) / delta + 2
            } else {
                hue = (r - g) / delta + 4
            }
        }
        let saturation = (maxV == 0 ? 0 : delta / maxV) * 0.85
        let value = maxV * 0.80
        let chroma = value * saturation
        let low = value - chroma
        let x = chroma * (1 - abs(hue.truncatingRemainder(dividingBy: 2) - 1))
        let (r1, g1, b1): (Double, Double, Double)
        switch Int(hue) {
        case 0: (r1, g1, b1) = (chroma, x, 0)
        case 1: (r1, g1, b1) = (x, chroma, 0)
        case 2: (r1, g1, b1) = (0, chroma, x)
        case 3: (r1, g1, b1) = (0, x, chroma)
        case 4: (r1, g1, b1) = (x, 0, chroma)
        default: (r1, g1, b1) = (chroma, 0, x)
        }
        func byte(_ v: Double) -> Int { min(255, max(0, Int(((v + low) * 255).rounded()))) }
        return String(format: "#%02X%02X%02X", byte(r1), byte(g1), byte(b1))
    }

    /// 转 sRGB，`#RRGGBB` 大写；无法转换时 nil。
    public static func hex(from color: NSColor) -> String? {
        guard let rgb = color.usingColorSpace(.sRGB) else { return nil }
        func byte(_ v: CGFloat) -> Int { min(255, max(0, Int((v * 255).rounded()))) }
        return String(format: "#%02X%02X%02X", byte(rgb.redComponent), byte(rgb.greenComponent), byte(rgb.blueComponent))
    }

    public static func rowBackground(for mark: FlowMark) -> NSColor {
        dynamicColor(lightHex: mark.background, alpha: rowFillAlpha(forHex: mark.background))
    }

    /// The least opacity a text colour paints with, so a very transparent `#RRGGBBAA` stays legible.
    public static let minimumTextOpacity: Double = 0.5

    /// The text colour of a mark: an `#RRGGBBAA` keeps its opacity down to `minimumTextOpacity`.
    public static func foreground(for mark: FlowMark) -> NSColor? {
        mark.foreground.map { dynamicColor(lightHex: $0, alpha: max(minimumTextOpacity, opacity(ofHex: $0))) }
    }

    public static func swatch(forHex hex: String) -> NSColor {
        dynamicColor(lightHex: hex, alpha: 1)
    }

    private static func dynamicColor(lightHex: String, alpha: Double) -> NSColor {
        let dark = darkHex(forLightHex: lightHex)
        return NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return color(hex: isDark ? dark : lightHex, alpha: alpha)
        }
    }

    private static func color(hex: String, alpha: Double) -> NSColor {
        guard let c = channels(of: hex) else { return NSColor.clear }
        return NSColor(srgbRed: CGFloat(c.0) / 255, green: CGFloat(c.1) / 255, blue: CGFloat(c.2) / 255, alpha: CGFloat(alpha))
    }

    private static func channels(of hex: String) -> (Int, Int, Int)? {
        // `#RRGGBB` or `#RRGGBBAA`; the opacity is read by `opacity(ofHex:)`, never part of the colour channels.
        guard hex.count == 7 || hex.count == 9, hex.first == "#", let value = Int(hex.dropFirst().prefix(6), radix: 16)
        else { return nil }
        return ((value >> 16) & 255, (value >> 8) & 255, value & 255)
    }
}
