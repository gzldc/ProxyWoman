import AppCore
import AppKit
import FlowStore
import Localization
import SwiftUI

/// The swatch of one colour choice of the mark action: the colour itself (a half-transparent one with its opacity), a
/// black and white split for "unchanged", a half-filled circle for the theme's own colour.
struct MarkSwatch: View {
    let choice: MarkColorChoice
    var side: CGFloat = 16

    var body: some View {
        Group {
            switch choice {
            case .unchanged:
                ZStack {
                    Rectangle().fill(Color.white)
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: 0))
                        path.addLine(to: CGPoint(x: 0, y: side))
                        path.addLine(to: CGPoint(x: side, y: side))
                        path.closeSubpath()
                    }
                    .fill(Color.black)
                }
            case .themeDefault:
                Image(systemName: "circle.lefthalf.filled")
                    .font(.system(size: side - 2))
                    .foregroundStyle(ShellStyle.color(.textSecondary))
            case .entry(let id):
                if let entry = MarkColorCatalog.entry(id: id) {
                    Rectangle().fill(Color(nsColor: MarkPalette.swatch(forHex: entry.stored)).opacity(entry.opacity))
                } else {
                    Rectangle().fill(Color.clear)
                }
            case .custom(let hex):
                Rectangle().fill(Color(nsColor: MarkPalette.swatch(forHex: hex)))
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(ShellStyle.color(.separator), lineWidth: 1))
        .accessibilityHidden(true)
    }
}

/// One of the mark's two colour dropdowns: the closed box shows the swatch and the colour's name, the list opens in a
/// popover with every colour of the descriptor (unchanged, default, the 28 colours, an old rule's own colour).
struct MarkColorDropdown: View {
    let label: String
    let choices: [MarkColorChoice]
    let selected: MarkColorChoice
    let choose: (MarkColorChoice) -> Void

    @State private var isOpen = false

    var body: some View {
        let title = MarkColorCatalog.title(of: selected)
        Button { isOpen.toggle() } label: {
            BuilderDropdownLabel(title: title) { MarkSwatch(choice: selected) }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(title)
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(choices.enumerated()), id: \.offset) { index, choice in
                        if index == 2 { Divider().padding(.vertical, 3) }
                        row(choice)
                    }
                }
                .padding(4)
            }
            .frame(width: RuleBuilderMetrics.markListWidth(), height: 360)
        }
    }

    private func row(_ choice: MarkColorChoice) -> some View {
        let title = MarkColorCatalog.title(of: choice)
        return Button {
            isOpen = false
            choose(choice)
        } label: {
            HStack(spacing: 8) {
                MarkSwatch(choice: choice)
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(ShellStyle.color(.textPrimary))
                    .lineLimit(1)
                Spacer(minLength: 8)
                if choice == selected { Image(systemName: "checkmark").font(.system(size: 11)) }
            }
            .padding(.horizontal, 6)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: ShellStyle.cornerRadius)
                    .fill(choice == selected ? ShellStyle.color(.selection) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(choice == selected ? .isSelected : [])
    }
}

/// The mark action: a background and a text colour, each a dropdown of the reference's session colours, and a live
/// sample of the result. An old rule's label stays an input while it holds text.
struct MarkForm: View {
    let index: Int
    let descriptor: ActionEditorDescriptor
    @Binding var action: ActionDraft
    let issues: ActionIssues

    var body: some View {
        let mark = action.mark
        VStack(alignment: .leading, spacing: 8) {
            // One line when the card is wide enough; otherwise each colour on its own line (the longer English names).
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    backgroundPicker(mark, descriptor)
                    foregroundPicker(mark, descriptor)
                    Spacer(minLength: 8)
                    sample(mark)
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) { backgroundPicker(mark, descriptor) }
                    HStack(spacing: 8) { foregroundPicker(mark, descriptor) }
                    sample(mark)
                }
            }
            issues.lines([.markColor, .markForeground])
            if descriptor.showsMarkText {
                ActionTextField(L10n.string("rules.mark.text"), text: $action.mark.text)
                issues.line(.markText)
            }
        }
    }

    private static let dropdownWidth = RuleBuilderMetrics.markDropdownWidth()

    @ViewBuilder private func backgroundPicker(_ mark: MarkDraft, _ descriptor: ActionEditorDescriptor) -> some View {
        Text(L10n.string("rules.builder.background")).font(.system(size: 13)).fixedSize()
        MarkColorDropdown(
            label: actionFieldLabel(index: index, "rules.builder.background"), choices: descriptor.backgroundChoices,
            selected: mark.backgroundChoice
        ) { action.mark.setBackground($0) }
        .frame(width: Self.dropdownWidth)
    }

    @ViewBuilder private func foregroundPicker(_ mark: MarkDraft, _ descriptor: ActionEditorDescriptor) -> some View {
        Text(L10n.string("rules.builder.textColor")).font(.system(size: 13)).fixedSize()
        MarkColorDropdown(
            label: actionFieldLabel(index: index, "rules.builder.textColor"), choices: descriptor.foregroundChoices,
            selected: mark.foregroundChoice
        ) { action.mark.setForeground($0) }
        .frame(width: Self.dropdownWidth)
    }

    private func sample(_ mark: MarkDraft) -> some View {
        func painted(_ choice: MarkColorChoice, stored: String?) -> Color? {
            switch choice {
            case .unchanged, .themeDefault: nil
            case .entry, .custom:
                stored.map { Color(nsColor: MarkPalette.swatch(forHex: $0)).opacity(MarkColorCatalog.opacity(of: choice)) }
            }
        }
        let foreground = painted(mark.foregroundChoice, stored: mark.foreground) ?? ShellStyle.color(.textPrimary)
        let fill = painted(mark.backgroundChoice, stored: mark.background) ?? Color.clear
        return Text(mark.text.isEmpty ? L10n.string("rules.builder.sampleText") : mark.text)
            .font(.system(size: 13))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .foregroundStyle(foreground)
            .background(RoundedRectangle(cornerRadius: 3).fill(fill))
            .accessibilityLabel(L10n.string("rules.builder.sampleText"))
    }
}
