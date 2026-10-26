import AppKit
import FlowStore
import Foundation
import Localization
import Testing

@testable import AppCore

private func components(of color: NSColor, appearance name: NSAppearance.Name) throws -> (r: Int, g: Int, b: Int, a: Double) {
    let appearance = try #require(NSAppearance(named: name))
    var result: (Int, Int, Int, Double)?
    appearance.performAsCurrentDrawingAppearance {
        if let rgb = color.usingColorSpace(.sRGB) {
            result = (Int((rgb.redComponent * 255).rounded()), Int((rgb.greenComponent * 255).rounded()),
                      Int((rgb.blueComponent * 255).rounded()), Double(rgb.alphaComponent))
        }
    }
    let value = try #require(result)
    return (value.0, value.1, value.2, value.3)
}

private func rgb(_ hex: String) -> (Int, Int, Int) {
    let v = Int(hex.dropFirst(), radix: 16)!
    return ((v >> 16) & 255, (v >> 8) & 255, v & 255)
}

@Suite(.productionChinese) struct MarkPaletteTests {
    @Test func eightPresetsInOrderWithSystemValues() {
        let expected: [(MarkColorName, String, String)] = [
            (.red, "#FF3B30", "#FF453A"), (.orange, "#FF9500", "#FF9F0A"), (.yellow, "#FFCC00", "#FFD60A"),
            (.green, "#34C759", "#30D158"), (.cyan, "#30B0C7", "#40C8E0"), (.blue, "#007AFF", "#0A84FF"),
            (.purple, "#AF52DE", "#BF5AF2"), (.gray, "#8E8E93", "#98989D"),
        ]
        #expect(MarkPalette.presets.count == 8)
        for (preset, row) in zip(MarkPalette.presets, expected) {
            #expect(preset.name == row.0 && preset.lightHex == row.1 && preset.darkHex == row.2, "\(row.0)")
            #expect(preset.id == row.0.rawValue)
        }
        #expect(MarkPalette.presets.map(\.name) == MarkColorName.allCases)
        #expect(MarkPalette.rowFillAlpha == 0.15)
    }

    @Test func adaptedForDarkLowersSaturationAndBrightness() {
        #expect(MarkPalette.adaptedForDark("#FF0000") == "#CC1F1F")
        #expect(MarkPalette.adaptedForDark("#00FF00") == "#1FCC1F")
        #expect(MarkPalette.adaptedForDark("#FFFFFF") == "#CCCCCC")
        #expect(MarkPalette.adaptedForDark("#000000") == "#000000")
        #expect(MarkPalette.adaptedForDark("zz") == "zz")
    }

    @Test func darkHexUsesThePairForPresetsAndTheAlgorithmForOthers() {
        #expect(MarkPalette.darkHex(forLightHex: "#FF3B30") == "#FF453A")
        #expect(MarkPalette.darkHex(forLightHex: "#ff3b30") == "#FF453A")
        #expect(MarkPalette.darkHex(forLightHex: "#123456") == MarkPalette.adaptedForDark("#123456"))
    }

    @Test func presetLookupMatchesEitherValueCaseInsensitively() {
        #expect(MarkPalette.preset(forHex: "#ff3b30")?.name == .red)
        #expect(MarkPalette.preset(forHex: "#0a84ff")?.name == .blue)
        #expect(MarkPalette.preset(forHex: "#123456") == nil)
        #expect(MarkPalette.preset(forHex: "nope") == nil)
    }

    @Test func hexFromColourIsSRGBUppercase() {
        #expect(MarkPalette.hex(from: NSColor(srgbRed: 1, green: 0.5, blue: 0, alpha: 1)) == "#FF8000")
        #expect(MarkPalette.hex(from: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)) == "#000000")
    }

    @Test func rowBackgroundIsTranslucentAndFollowsAppearance() throws {
        let mark = try #require(FlowMark(background: "#FF3B30", source: .manual))
        let color = MarkPalette.rowBackground(for: mark)
        let light = try components(of: color, appearance: .aqua)
        let dark = try components(of: color, appearance: .darkAqua)
        #expect(light.a == 0.15 && dark.a == 0.15)
        #expect((light.r, light.g, light.b) == rgb("#FF3B30"))
        #expect((dark.r, dark.g, dark.b) == rgb("#FF453A"))
    }

    @Test func foregroundOnlyWhenGiven() throws {
        let plain = try #require(FlowMark(background: "#FF3B30", source: .manual))
        #expect(MarkPalette.foreground(for: plain) == nil)
        let styled = try #require(FlowMark(background: "#FF3B30", foreground: "#007AFF", source: .manual))
        let color = try #require(MarkPalette.foreground(for: styled))
        let light = try components(of: color, appearance: .aqua)
        #expect((light.r, light.g, light.b) == rgb("#007AFF") && light.a == 1)
        let dark = try components(of: color, appearance: .darkAqua)
        #expect((dark.r, dark.g, dark.b) == rgb("#0A84FF"))
    }

    @Test func swatchIsFullStrength() throws {
        let light = try components(of: MarkPalette.swatch(forHex: "#34C759"), appearance: .aqua)
        #expect(light.a == 1 && (light.r, light.g, light.b) == rgb("#34C759"))
        let dark = try components(of: MarkPalette.swatch(forHex: "#34C759"), appearance: .darkAqua)
        #expect((dark.r, dark.g, dark.b) == rgb("#30D158"))
    }

    @Test func everyPresetHasALocalizationKeyThatIsDefined() {
        let keys = MarkPalette.presets.map(\.localizationKey)
        #expect(Set(keys).count == 8)
        for key in keys {
            #expect(L10n.string(key) != key, "\(key)")
        }
        #expect(L10n.string("mark.color.custom") != "mark.color.custom")
    }

    // MARK: eight-digit colours (opacity)

    @Test func sixDigitRowFillIsAsBeforeAndEightDigitScalesWithItsOpacity() throws {
        #expect(MarkPalette.rowFillAlpha(forHex: "#FF3B30") == 0.15)
        #expect(MarkPalette.rowFillAlpha(forHex: "#FF3B30FF") == MarkPalette.solidRowFillAlpha)
        let translucent = MarkPalette.rowFillAlpha(forHex: "#FFEC1A4D")
        #expect(abs(translucent - MarkPalette.solidRowFillAlpha * 77.0 / 255) < 0.0001)
        // A translucent entry paints lighter than the solid one of the same colour, and a solid one stays under the text.
        #expect(translucent < MarkPalette.rowFillAlpha(forHex: "#FFEC1AFF"))
        #expect(MarkPalette.solidRowFillAlpha <= 0.4)
        #expect(MarkPalette.opacity(ofHex: "#FFEC1A") == 1)
        #expect(MarkPalette.opacity(ofHex: "#99999960") == 96.0 / 255)

        let solid = try #require(FlowMark(background: "#FFEC1AFF", source: .manual))
        let semi = try #require(FlowMark(background: "#FFEC1A4D", source: .manual))
        let solidLight = try components(of: MarkPalette.rowBackground(for: solid), appearance: .aqua)
        let semiLight = try components(of: MarkPalette.rowBackground(for: semi), appearance: .aqua)
        #expect((solidLight.r, solidLight.g, solidLight.b) == rgb("#FFEC1A"))
        #expect((semiLight.r, semiLight.g, semiLight.b) == rgb("#FFEC1A"))
        #expect(abs(solidLight.a - MarkPalette.solidRowFillAlpha) < 0.005)
        #expect(semiLight.a < solidLight.a)
        // Yellow and yellow (semi-transparent) are no longer the same row.
        #expect(semiLight.a != solidLight.a)
    }

    @Test func eightDigitDarkDerivationIgnoresTheOpacity() throws {
        #expect(MarkPalette.darkHex(forLightHex: "#FF3B30FF") == "#FF453A")
        #expect(MarkPalette.darkHex(forLightHex: "#123456AA") == MarkPalette.adaptedForDark("#123456"))
        #expect(MarkPalette.adaptedForDark("#123456AA") == MarkPalette.adaptedForDark("#123456"))
        let mark = try #require(FlowMark(background: "#FF3B3080", source: .manual))
        let dark = try components(of: MarkPalette.rowBackground(for: mark), appearance: .darkAqua)
        #expect((dark.r, dark.g, dark.b) == rgb("#FF453A"))
        #expect(abs(dark.a - MarkPalette.solidRowFillAlpha * 128.0 / 255) < 0.005)
    }

    @Test func textColourHonoursTheOpacityOfAnEightDigitColourDownToALegibleMinimum() throws {
        let styled = try #require(FlowMark(background: "#FF3B30FF", foreground: "#007AFFB3", source: .manual))
        let light = try components(of: try #require(MarkPalette.foreground(for: styled)), appearance: .aqua)
        #expect((light.r, light.g, light.b) == rgb("#007AFF"))
        #expect(abs(light.a - 179.0 / 255) < 0.005)
        // A nearly invisible text colour is clamped, so the text stays readable.
        let faint = try #require(FlowMark(background: "#FF3B30FF", foreground: "#007AFF1A", source: .manual))
        let clamped = try components(of: try #require(MarkPalette.foreground(for: faint)), appearance: .aqua)
        #expect(abs(clamped.a - MarkPalette.minimumTextOpacity) < 0.005)
        // Six digits stay solid.
        let solid = try #require(FlowMark(background: "#FF3B30FF", foreground: "#007AFF", source: .manual))
        #expect(try components(of: try #require(MarkPalette.foreground(for: solid)), appearance: .aqua).a == 1)
        // The swatch shows the colour itself, not its opacity.
        let swatch = try components(of: MarkPalette.swatch(forHex: "#34C75980"), appearance: .aqua)
        #expect(swatch.a == 1 && (swatch.r, swatch.g, swatch.b) == rgb("#34C759"))
    }
}
