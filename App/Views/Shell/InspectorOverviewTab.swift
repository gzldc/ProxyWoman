import AppCore
import FlowStore
import Localization
import SwiftUI

/// The inspector's overview tab: summary, timing, sizes, connection and matched rules for the selected flow.
struct InspectorOverviewTab: View {
    let flow: Flow
    let ruleName: (UUID) -> String?
    var cardIndex: OutcomeCardIndex? = nil
    var use24Hour = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(FlowOverviewPresentation.sections(for: flow, ruleName: ruleName, use24Hour: use24Hour, cardIndex: cardIndex)) { section in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(section.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(ShellStyle.color(.textSecondary))
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(section.rows.enumerated()), id: \.offset) { _, row in
                                rowView(row)
                            }
                        }
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private func rowView(_ row: OverviewRow) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if !row.title.isEmpty {
                Text(row.title)
                    .foregroundStyle(ShellStyle.color(.textSecondary))
                    .frame(width: 84, alignment: .trailing)
            }
            Text(row.value)
                .foregroundStyle(color(row.tone))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
    }

    private func color(_ tone: BadgeTone?) -> Color {
        switch tone {
        case .failure: ShellStyle.color(.failure)
        case .success: Palette.successColor
        case .pending: Palette.pendingColor
        case .neutral, nil: ShellStyle.color(.textPrimary)
        }
    }
}
