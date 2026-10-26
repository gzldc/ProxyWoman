import AppCore
import Localization
import SwiftUI

/// The repeat-send panel: how many sends, how many at once, the pause between them, whether the
/// published rules run, and (for a method that is not a plain read) the confirmation, then the
/// progress and the first failures of the run. The sends are ordinary Compose sends recorded in the
/// traffic list. Closing the sheet, by any route, cancels a run that is still going.
struct RepeatSheet: View {
    @Bindable var model: RepeatRunModel
    @Environment(\.dismiss) private var dismiss

    private var isRunning: Bool { model.phase == .running }
    private var isReady: Bool { model.phase == .ready }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.string("repeat.sheet.title")).font(.title2.bold())
            Text("\(model.draft.method) \(model.draft.url)")
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
            optionsGrid
                .disabled(!isReady)
            if model.requiresConfirmation {
                // The count is the one Start sends; the model withdraws the confirmation when it changes.
                Toggle(L10n.format("repeat.safety.confirm", model.options.count), isOn: $model.confirmedUnsafe)
                    .disabled(!isReady)
            }
            if !isReady { progressBlock }
            if !model.failures.isEmpty { failureList }
            Text(L10n.string("repeat.sheet.resultsHint"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(L10n.string("repeat.sheet.close")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L10n.string("repeat.sheet.cancel")) { model.cancel() }
                    .disabled(!isRunning)
                Button(L10n.string("repeat.sheet.start")) { Task { await model.start() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canStart)
            }
        }
        .padding(24)
        .frame(width: 520)
        .onDisappear { model.cancel() }
    }

    private var optionsGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
            fieldRows("repeat.sheet.count", .count, value: \.count)
            fieldRows("repeat.sheet.concurrency", .concurrency, value: \.concurrency)
            fieldRows("repeat.sheet.interval", .interval, value: \.intervalMilliseconds, step: 100)
            GridRow {
                Color.clear.frame(width: 0, height: 0)
                Toggle(L10n.string("repeat.sheet.applyRules"), isOn: applyRulesBinding)
            }
        }
    }

    /// A label, the field (typed text applies at once) with its stepper, and its inline error if any.
    @ViewBuilder
    private func fieldRows(_ key: String, _ field: RepeatField, value: KeyPath<RepeatOptions, Int>, step: Int = 1) -> some View {
        GridRow {
            Text(L10n.string(key))
            RepeatNumberField(title: L10n.string(key), text: textBinding(field), value: stepperBinding(field, value),
                              range: field.range, step: step)
        }
        if let message = model.message(of: field) {
            GridRow {
                Color.clear.frame(width: 0, height: 0)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(Palette.failureColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var progressBlock: some View {
        let progress = model.progress
        return VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: Double(progress.finished), total: Double(max(progress.total, 1)))
            Text(L10n.format("repeat.sheet.progress", progress.started, progress.total, progress.succeeded,
                             progress.failed, progress.cancelled))
                .font(.callout.monospacedDigit())
        }
    }

    private var failureList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.format("repeat.sheet.failures", RepeatRunModel.failureLimit)).font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(model.failures.enumerated()), id: \.offset) { _, failure in
                        Text(failureText(failure))
                            .font(.caption)
                            .foregroundStyle(Palette.failureColor)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxHeight: 120)
        }
    }

    /// Index 0 is the run itself (nothing could be sent), any other index is that send.
    private func failureText(_ failure: RepeatFailure) -> String {
        failure.index > 0
            ? L10n.format("repeat.sheet.failureRow", failure.index, failure.message, failure.code)
            : L10n.format("repeat.sheet.failureRunRow", failure.message, failure.code)
    }

    private func textBinding(_ field: RepeatField) -> Binding<String> {
        Binding(get: { model.text(of: field) }, set: { model.setText($0, of: field) })
    }

    /// The stepper steps from the current number (pulled into range) and writes the result as text.
    private func stepperBinding(_ field: RepeatField, _ value: KeyPath<RepeatOptions, Int>) -> Binding<Int> {
        Binding(
            get: { min(max(model.options[keyPath: value], field.range.lowerBound), field.range.upperBound) },
            set: { model.setText(String($0), of: field) })
    }

    private var applyRulesBinding: Binding<Bool> {
        Binding(get: { model.options.applyRules }, set: { model.options.applyRules = $0 })
    }
}

/// A number typed in a field (the text is the model's, applied on every keystroke) or stepped.
private struct RepeatNumberField: View {
    let title: String
    @Binding var text: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    var step = 1

    var body: some View {
        HStack(spacing: 6) {
            TextField(title, text: $text)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 80)
                .labelsHidden()
            Stepper(title, value: $value, in: range, step: step)
                .labelsHidden()
        }
    }
}
