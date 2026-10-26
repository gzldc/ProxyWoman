import AppKit
import Testing

@testable import AppCore

@Suite(.productionChinese) struct ShellStyleTests {
    @Test func lightValuesMatchTheSpec() {
        let expected: [(ShellStyle.Token, UInt32)] = [
            (.content, 0xFFFFFF), (.sidebar, 0xF6F7F9), (.toolbar, 0xFBFBFC), (.separator, 0xE4E6EB),
            (.accent, 0x2F6FED), (.accentSoft, 0xE8EFFD), (.selection, 0xE3E6EB), (.textPrimary, 0x1F2328),
            (.textSecondary, 0x6B7280), (.success, 0x16A34A), (.failure, 0xDC2626), (.request, 0x2F6FED),
            (.response, 0xE8871E), (.paused, 0xFFF4D6),
            (.failureSoft, 0xFDF2F2), (.failureSoftPressed, 0xF9DCDC), (.failureBorder, 0xF1A8A8),
        ]
        for (token, value) in expected { #expect(ShellStyle.hex(token, dark: false) == value, "\(token)") }
        #expect(expected.count == ShellStyle.Token.allCases.count)
    }

    @Test func darkValues() {
        let expected: [(ShellStyle.Token, UInt32)] = [
            (.content, 0x1E1F22), (.sidebar, 0x26272B), (.toolbar, 0x2A2B2F), (.separator, 0x3A3C42),
            (.accent, 0x2F6FED), (.accentSoft, 0x22324F), (.selection, 0x34363C), (.textPrimary, 0xE6E7EA),
            (.textSecondary, 0x9CA3AF), (.success, 0x22C55E), (.failure, 0xF87171), (.request, 0x2F6FED),
            (.response, 0xF59E0B), (.paused, 0x3D3423),
            (.failureSoft, 0x2B2427), (.failureSoftPressed, 0x412C2F), (.failureBorder, 0x754042),
        ]
        for (token, value) in expected { #expect(ShellStyle.hex(token, dark: true) == value, "\(token)") }
        #expect(expected.count == ShellStyle.Token.allCases.count)
    }

    @Test func everyTokenHasBothAppearances() {
        for token in ShellStyle.Token.allCases {
            _ = ShellStyle.hex(token, dark: false)
            _ = ShellStyle.hex(token, dark: true)
            _ = ShellStyle.nsColor(token)
            _ = ShellStyle.color(token)
        }
        for token in [ShellStyle.Token.content, .sidebar, .separator, .textPrimary] {
            #expect(ShellStyle.hex(token, dark: false) != ShellStyle.hex(token, dark: true), "\(token)")
        }
    }

    @Test func dynamicColorResolvesPerAppearance() throws {
        for (name, dark) in [(NSAppearance.Name.aqua, false), (.darkAqua, true)] {
            let appearance = try #require(NSAppearance(named: name))
            for token in ShellStyle.Token.allCases {
                var resolved: NSColor?
                appearance.performAsCurrentDrawingAppearance {
                    resolved = ShellStyle.nsColor(token).usingColorSpace(.sRGB)
                }
                let color = try #require(resolved)
                let hex = ShellStyle.hex(token, dark: dark)
                let parts = [CGFloat((hex >> 16) & 0xFF), CGFloat((hex >> 8) & 0xFF), CGFloat(hex & 0xFF)].map { $0 / 255 }
                #expect(abs(color.redComponent - parts[0]) <= 1.0 / 255, "\(token) \(name.rawValue) red")
                #expect(abs(color.greenComponent - parts[1]) <= 1.0 / 255, "\(token) \(name.rawValue) green")
                #expect(abs(color.blueComponent - parts[2]) <= 1.0 / 255, "\(token) \(name.rawValue) blue")
            }
        }
    }

    @Test func metricsMatchTheSpec() {
        #expect(ShellStyle.railWidth == 44)
        #expect(ShellStyle.sourceBarWidth == 170)
        #expect(ShellStyle.inspectorDefaultWidth == 430)
        #expect(ShellStyle.inspectorWidthRange == 320...760)
        #expect(ShellStyle.rowHeight == 24)
        #expect(ShellStyle.cornerRadius == 6)
        #expect(ShellStyle.iconButtonSide == 24)
        #expect(ShellStyle.tabUnderline == 2)
    }
}
