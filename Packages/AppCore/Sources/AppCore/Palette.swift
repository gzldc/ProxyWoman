import AppKit
import SwiftUI

/// 语义色常量：全部来自系统语义色，随浅色/深色外观自动适配。
/// 标签底色 = 色调颜色 15% 透明度，文字 = 色调颜色。
public enum Palette {
    private static let badgeFillAlpha: CGFloat = 0.15

    public static var success: NSColor { .systemGreen }
    public static var pending: NSColor { .systemOrange }
    public static var failure: NSColor { .systemRed }
    public static var neutral: NSColor { .secondaryLabelColor }

    public static var successBadgeFill: NSColor { success.withAlphaComponent(badgeFillAlpha) }
    public static var pendingBadgeFill: NSColor { pending.withAlphaComponent(badgeFillAlpha) }
    public static var failureBadgeFill: NSColor { failure.withAlphaComponent(badgeFillAlpha) }
    public static var neutralBadgeFill: NSColor { .quaternaryLabelColor }

    public static func text(for tone: BadgeTone) -> NSColor {
        switch tone {
        case .neutral: neutral
        case .success: success
        case .pending: pending
        case .failure: failure
        }
    }

    public static func badgeFill(for tone: BadgeTone) -> NSColor {
        switch tone {
        case .neutral: neutralBadgeFill
        case .success: successBadgeFill
        case .pending: pendingBadgeFill
        case .failure: failureBadgeFill
        }
    }

    // SwiftUI 版本
    public static var successColor: Color { Color(nsColor: success) }
    public static var pendingColor: Color { Color(nsColor: pending) }
    public static var failureColor: Color { Color(nsColor: failure) }
    public static var neutralColor: Color { Color(nsColor: neutral) }
    public static var neutralBadgeFillColor: Color { Color(nsColor: neutralBadgeFill) }

    public static func textColor(for tone: BadgeTone) -> Color { Color(nsColor: text(for: tone)) }
    public static func badgeFillColor(for tone: BadgeTone) -> Color { Color(nsColor: badgeFill(for: tone)) }
}
