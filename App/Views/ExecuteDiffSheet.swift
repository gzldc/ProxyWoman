import AppCore
import FlowStore
import Localization
import SwiftUI

/// What an Execute run changed in one session (request and response sections). The comparison reads bodies, so it
/// runs off the main actor and is cancelled with the sheet.
struct ExecuteDiffSheet: View {
    let flow: Flow
    @Environment(\.dismiss) private var dismiss
    @State private var report: ExecuteDiffReport?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.string("executeDiff.title")).font(.headline)
            if let report {
                if report.isEmpty {
                    Text(L10n.string("executeDiff.noChanges")).foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            section(L10n.string("executeDiff.request"), report.request)
                            section(L10n.string("executeDiff.response"), report.response)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } else {
                ProgressView().controlSize(.small)
            }
            HStack {
                Spacer()
                Button(L10n.string("rules.execute.close")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel(L10n.string("rules.execute.close"))
            }
        }
        .padding(16)
        .frame(minWidth: 420, idealWidth: 520, minHeight: 200, idealHeight: 320)
        .task(id: flow.id) {
            let snapshot = flow
            let task = Task.detached(priority: .userInitiated) { ExecuteDiff.compare(snapshot) }
            let result = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
            if !Task.isCancelled { report = result }
        }
    }

    @ViewBuilder private func section(_ title: String, _ lines: [ExecuteDiffReport.Line]) -> some View {
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold))
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line.text).font(.callout).textSelection(.enabled)
                }
            }
        }
    }
}
