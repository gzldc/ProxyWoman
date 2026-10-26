import AppCore
import Localization
import SwiftUI

/// The narrow page switcher on the left edge of the main window. The page lives on the shell model.
struct IconRail: View {
    let shell: MainShellModel
    let openSettings: () -> Void

    var body: some View {
        VStack(spacing: 4) {
            ForEach(ShellPage.allCases) { page in
                railButton(
                    symbol: page.icon, label: L10n.string(page.titleKey), help: help(for: page),
                    selected: shell.page == page
                ) { shell.page = page }
            }
            Spacer(minLength: 0)
            railButton(
                symbol: "gearshape", label: L10n.string("shell.rail.settings"),
                help: L10n.string("shell.rail.settings"), selected: false, action: openSettings)
        }
        .padding(.vertical, 8)
        .frame(width: ShellStyle.railWidth)
        .frame(maxHeight: .infinity)
        .background(ShellStyle.color(.sidebar))
        .overlay(alignment: .trailing) {
            Rectangle().fill(ShellStyle.color(.separator)).frame(width: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.string("shell.rail.label"))
    }

    private func help(for page: ShellPage) -> String {
        switch page {
        case .traffic: L10n.string("shell.rail.help.traffic")
        case .compose: L10n.string("shell.rail.help.compose")
        }
    }

    private func railButton(
        symbol: String, label: String, help: String, selected: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16))
                .foregroundStyle(selected ? ShellStyle.color(.accent) : ShellStyle.color(.textSecondary))
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: ShellStyle.cornerRadius)
                        .fill(selected ? ShellStyle.color(.accentSoft) : Color.clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: ShellStyle.cornerRadius))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
