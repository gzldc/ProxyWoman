import AppKit
import SwiftUI

/// Colour tokens and metrics of the single-window shell. Views take colours only from here, `Palette` and `MarkPalette`.
public enum ShellStyle {
    public enum Token: CaseIterable, Sendable {
        case content, sidebar, toolbar, separator, accent, accentSoft, selection,
             textPrimary, textSecondary, success, failure, request, response, paused,
             failureSoft, failureSoftPressed, failureBorder
    }

    public static func hex(_ token: Token, dark: Bool) -> UInt32 {
        switch token {
        case .content: dark ? 0x1E1F22 : 0xFFFFFF
        case .sidebar: dark ? 0x26272B : 0xF6F7F9
        case .toolbar: dark ? 0x2A2B2F : 0xFBFBFC
        case .separator: dark ? 0x3A3C42 : 0xE4E6EB
        case .accent: 0x2F6FED
        case .accentSoft: dark ? 0x22324F : 0xE8EFFD
        case .selection: dark ? 0x34363C : 0xE3E6EB
        case .textPrimary: dark ? 0xE6E7EA : 0x1F2328
        case .textSecondary: dark ? 0x9CA3AF : 0x6B7280
        case .success: dark ? 0x22C55E : 0x16A34A
        case .failure: dark ? 0xF87171 : 0xDC2626
        case .request: 0x2F6FED
        case .response: dark ? 0xF59E0B : 0xE8871E
        case .paused: dark ? 0x3D3423 : 0xFFF4D6
        // The delete buttons' pale red wash, its pressed state and its outline (the failure colour over the content colour).
        case .failureSoft: dark ? 0x2B2427 : 0xFDF2F2
        case .failureSoftPressed: dark ? 0x412C2F : 0xF9DCDC
        case .failureBorder: dark ? 0x754042 : 0xF1A8A8
        }
    }

    /// Dynamic colour: resolves against the appearance it is drawn in.
    public static func nsColor(_ token: Token) -> NSColor {
        NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return srgb(hex(token, dark: dark))
        }
    }

    public static func color(_ token: Token) -> Color { Color(nsColor: nsColor(token)) }

    private static func srgb(_ value: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }

    public static let railWidth: CGFloat = 44
    public static let sourceBarWidth: CGFloat = 170
    public static let inspectorDefaultWidth: CGFloat = 430
    public static let inspectorWidthRange: ClosedRange<CGFloat> = 320...760
    public static let rowHeight: CGFloat = 24
    public static let cornerRadius: CGFloat = 6
    public static let iconButtonSide: CGFloat = 24
    public static let tabUnderline: CGFloat = 2
}
