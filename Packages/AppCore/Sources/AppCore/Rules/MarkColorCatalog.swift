import FlowStore
import Foundation
import Localization
import RulesEngine

/// One of the 28 session colours of the mark action's dropdowns (spec 12.7), in the reference's order.
public struct MarkColorEntry: Equatable, Sendable, Identifiable {
    public var id: String
    /// `#RRGGBBAA`: the colour with its opacity.
    public var rgba: String
    public var titleKey: String

    /// What a rule stores: the exact `#RRGGBBAA` of the entry, so a solid and a semi-transparent entry of one colour
    /// store different text and a reload shows the entry the user picked (R8F2 final review; before, both stored the
    /// 6-digit colour).
    public var stored: String { rgba }

    /// The `#RRGGBB` part: what a 6-digit (older) rule stores.
    public var rgb: String { String(rgba.prefix(7)) }

    /// 0...1.
    public var opacity: Double {
        guard rgba.count == 9, let value = Int(rgba.suffix(2), radix: 16) else { return 1 }
        return Double(value) / 255
    }
}

/// What a colour dropdown of the mark action shows as chosen.
public enum MarkColorChoice: Equatable, Sendable {
    /// The session keeps the colour it has.
    case unchanged
    /// The colour of the theme.
    case themeDefault
    case entry(String)
    /// A stored colour that is none of the 28 (an older rule): shown as its hex text.
    case custom(String)
}

public enum MarkColorCatalog {
    private static func entry(_ id: String, _ rgba: String, _ titleKey: String) -> MarkColorEntry {
        MarkColorEntry(id: id, rgba: rgba, titleKey: titleKey)
    }

    /// The 28 colours in the reference's order.
    public static let entries: [MarkColorEntry] = [
        entry("yellowTransparent", "#FFEC1A4D", "rules.markColor.yellowTransparent"),
        entry("fuchsiaTransparent", "#FF19FF4D", "rules.markColor.fuchsiaTransparent"),
        entry("redTransparent", "#F985904D", "rules.markColor.redTransparent"),
        entry("oliveTransparent", "#A7C7054D", "rules.markColor.oliveTransparent"),
        entry("purpleTransparent", "#9F80FF4D", "rules.markColor.purpleTransparent"),
        entry("maroonTransparent", "#C982824D", "rules.markColor.maroonTransparent"),
        entry("aquaTransparent", "#55E9F64D", "rules.markColor.aquaTransparent"),
        entry("limeTransparent", "#86F9864D", "rules.markColor.limeTransparent"),
        entry("greenTransparent", "#2F9E2F33", "rules.markColor.greenTransparent"),
        entry("tealTransparent", "#40BFAA4D", "rules.markColor.tealTransparent"),
        entry("blueTransparent", "#478CD133", "rules.markColor.blueTransparent"),
        entry("navyTransparent", "#00158033", "rules.markColor.navyTransparent"),
        entry("yellow", "#FFEC1AFF", "rules.markColor.yellow"),
        entry("fuchsia", "#FF19FFFF", "rules.markColor.fuchsia"),
        entry("red", "#DB3B4BFF", "rules.markColor.red"),
        entry("olive", "#808000FF", "rules.markColor.olive"),
        entry("purple", "#800080FF", "rules.markColor.purple"),
        entry("maroon", "#800000FF", "rules.markColor.maroon"),
        entry("aqua", "#03FFFFFF", "rules.markColor.aqua"),
        entry("lime", "#03FF00FF", "rules.markColor.lime"),
        entry("green", "#008000FF", "rules.markColor.green"),
        entry("teal", "#008080FF", "rules.markColor.teal"),
        entry("blue", "#336CDCFF", "rules.markColor.blue"),
        entry("navy", "#0404ABFF", "rules.markColor.navy"),
        entry("white", "#FFFFFFFF", "rules.markColor.white"),
        entry("silverTransparent", "#99999960", "rules.markColor.silverTransparent"),
        entry("grayTransparent", "#999999C0", "rules.markColor.grayTransparent"),
        entry("black", "#000000FF", "rules.markColor.black"),
    ]

    public static func entry(id: String) -> MarkColorEntry? { entries.first { $0.id == id } }

    /// The entry that stores `hex` (any case): an 8-digit colour names its entry exactly; a 6-digit colour (an older rule)
    /// the first entry of that colour.
    public static func entry(forStored hex: String) -> MarkColorEntry? {
        guard let normalized = FlowMark.normalizedHex(hex) else { return nil }
        if normalized.count == 9 { return entries.first { $0.stored == normalized } }
        return entries.first { $0.rgb == normalized }
    }

    /// How a stored colour reads: nothing stored is "unchanged", `default` is the theme, a catalogue colour is its entry
    /// (the first of the colours that store the same text), anything else is a custom colour.
    public static func choice(forStored stored: String?) -> MarkColorChoice {
        guard let stored, stored != MarkAction.unchangedColor else { return .unchanged }
        if stored == MarkAction.defaultColor { return .themeDefault }
        if let found = entry(forStored: stored) { return .entry(found.id) }
        return .custom(stored)
    }

    /// How opaque a choice paints: a catalogue colour or an 8-digit custom colour its own opacity, any other colour fully.
    public static func opacity(of choice: MarkColorChoice) -> Double {
        switch choice {
        case .entry(let id): return entry(id: id)?.opacity ?? 1
        case .custom(let hex): return MarkPalette.opacity(ofHex: hex)
        case .unchanged, .themeDefault: return 1
        }
    }

    /// The text a rule stores for a choice: `""` for unchanged, `default`, or the entry's `#RRGGBBAA`.
    public static func stored(for choice: MarkColorChoice) -> String {
        switch choice {
        case .unchanged: MarkAction.unchangedColor
        case .themeDefault: MarkAction.defaultColor
        case .entry(let id): entry(id: id)?.stored ?? MarkAction.unchangedColor
        case .custom(let hex): hex
        }
    }

    public static func title(of choice: MarkColorChoice, localizer: Localizer = L10n.localizer) -> String {
        switch choice {
        case .unchanged: localizer.string("rules.markColor.unchanged")
        case .themeDefault: localizer.string("rules.markColor.default")
        case .entry(let id): entry(id: id).map { localizer.string($0.titleKey) } ?? id
        case .custom(let hex): hex
        }
    }

    /// The dropdown's rows: unchanged, default, then the 28 colours; `current` adds a custom colour as the last row.
    public static func choices(including current: MarkColorChoice? = nil) -> [MarkColorChoice] {
        var result: [MarkColorChoice] = [.unchanged, .themeDefault] + entries.map { .entry($0.id) }
        if case .custom? = current, let current { result.append(current) }
        return result
    }
}
