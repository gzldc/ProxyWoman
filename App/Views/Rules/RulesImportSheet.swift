import AppCore
import Localization
import SwiftUI

/// The import's one sheet, rendered from the importer's phase: reading, the preview (nothing is saved until
/// Import), the copy/save progress, the result, or a whole-sentence failure.
struct RulesImportSheet: View {
    let importer: RulePackImporter
    /// Called with the wrapper group's id when the user closes a finished import.
    let selectWrapper: @MainActor (UUID) -> Void

    var body: some View {
        let phase = importer.phase
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.string("rules.import.title")).font(.headline)
            content(phase)
        }
        .padding(20)
        .frame(width: 440)
        // Esc and the like go through the same rules as the buttons (no leaving while the save runs).
        .interactiveDismissDisabled(!Self.canCancel(phase) && !Self.isResult(phase))
    }

    @ViewBuilder private func content(_ phase: RulePackImporter.Phase) -> some View {
        switch phase {
        case .idle:
            EmptyView()
        case .reading(let fileName):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).accessibilityLabel(L10n.string("rules.import.title"))
                Text(L10n.format("rules.import.fileName", fileName))
            }
            buttons { cancelButton }
        case .preview(let preview):
            Text(L10n.format("rules.import.fileName", preview.fileName)).foregroundStyle(.secondary)
            Text(preview.groupName).fontWeight(.semibold)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(preview.lines.enumerated()), id: \.offset) { Text($0.element) }
            }
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(preview.warnings.enumerated()), id: \.offset) { warning in
                    Label(warning.element, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Palette.pendingColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Text(preview.note).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            buttons {
                cancelButton
                Button(L10n.string("rules.import.confirm")) { Task { await importer.confirm() } }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityLabel(L10n.string("rules.import.confirm"))
            }
        case .importing(let done, let total):
            ProgressView(value: Double(done), total: Double(max(total, 1)))
                .accessibilityLabel(L10n.string("rules.import.title"))
            Text(L10n.format("rules.import.working", done, total)).monospacedDigit().foregroundStyle(.secondary)
            // Once every file is copied the single save runs and cannot be undone, so Cancel is not offered.
            buttons { if Self.canCancel(phase) { cancelButton } }
        case .finished(let rules, let groups, let wrapperID):
            Label(RulePackPresentation.finished(rules: rules, groups: groups), systemImage: "checkmark.circle.fill")
                .foregroundStyle(Palette.successColor)
            buttons { closeButton { selectWrapper(wrapperID) } }
        case .failed(let error):
            Label(RulePackPresentation.message(error), systemImage: "exclamationmark.octagon.fill")
                .foregroundStyle(Palette.failureColor)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            buttons { closeButton {} }
        }
    }

    private var cancelButton: some View {
        Button(L10n.string("rules.import.cancel")) { importer.cancel() }
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel(L10n.string("rules.import.cancel"))
    }

    private func closeButton(then: @escaping () -> Void) -> some View {
        Button(L10n.string("rules.import.close")) {
            then()
            importer.dismiss()
        }
        .keyboardShortcut(.defaultAction)
        .accessibilityLabel(L10n.string("rules.import.close"))
    }

    private func buttons(@ViewBuilder _ content: () -> some View) -> some View {
        HStack { Spacer(); content() }
    }

    /// Reading, the preview, and copying files can be cancelled; the final save (all files copied) cannot.
    static func canCancel(_ phase: RulePackImporter.Phase) -> Bool {
        switch phase {
        case .reading, .preview: true
        case .importing(let done, let total): done < total
        default: false
        }
    }

    static func isResult(_ phase: RulePackImporter.Phase) -> Bool {
        switch phase {
        case .finished, .failed: true
        default: false
        }
    }
}

/// Which rules an export left out (selectable text), or the one sentence saying how it ended.
struct RulesExportReportSheet: View {
    let report: RulesExportReport
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(report.title).font(.headline).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            if let summary = report.summary { Text(summary) }
            if !report.lines.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(report.lines.enumerated()), id: \.offset) { Text($0.element).foregroundStyle(.secondary) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                }
                .frame(maxHeight: 220)
            }
            HStack {
                Spacer()
                Button(L10n.string("common.close"), action: close)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityLabel(L10n.string("common.close"))
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}
