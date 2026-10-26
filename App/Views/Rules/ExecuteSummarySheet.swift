import AppCore
import Localization
import RulesEngine
import SwiftUI

/// The lines of one finished run: per-rule counts, modified / hidden / annotated flows and what was skipped.
struct ExecuteSummaryLines: View {
    let summary: ExecuteSummary
    /// Rule names for the result lines.
    let rules: RulesEditorModel

    var body: some View {
        let names = Dictionary(rules.rules.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let lines = ExecuteSummaryPresentation.lines(summary, ruleName: { names[$0] })
        ScrollView {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .textSelection(.enabled)
        }
    }
}

/// "View Details" of the main window's Execute banner: the result of the run the banner reports.
struct ExecuteSummarySheet: View {
    let summary: ExecuteSummary
    let rules: RulesEditorModel
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.string("execute.summary.title")).font(.headline)
            ExecuteSummaryLines(summary: summary, rules: rules)
            HStack {
                Spacer()
                Button(L10n.string("execute.runBanner.dismiss"), action: close)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel(L10n.string("execute.runBanner.dismiss"))
            }
        }
        .padding(16)
        .frame(minWidth: 420, minHeight: 300)
    }
}
