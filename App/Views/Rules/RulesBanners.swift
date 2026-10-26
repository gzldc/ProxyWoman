import AppCore
import Localization
import RulesEngine
import SwiftUI

/// Shown while the global switch has every rule paused; the rules can still be edited.
struct RulesPausedBanner: View {
    let rulesSwitch: GlobalRulesSwitch

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "bolt.slash").foregroundStyle(Palette.pendingColor)
                Text(L10n.string("rules.globalSwitch.offNotice"))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                Button(L10n.string("rules.globalSwitch.toggle")) { rulesSwitch.setOn(true) }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Palette.pendingColor.opacity(0.12))
            Divider()
        }
    }
}

struct RulesBanners: View {
    let model: RulesEditorModel
    @State private var confirmsReset = false

    var body: some View {
        VStack(spacing: 0) {
            if case .unavailable(let problem) = model.loadState {
                banner(symbol: "exclamationmark.octagon.fill", tint: Palette.failureColor) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.string("rules.corrupt.title")).fontWeight(.semibold)
                        Text(RulesEditorError.unavailable(problem).message()).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    // A failed migration leaves the old file whole: reading it again is the way out, and a
                    // reset (which would start an empty list) is not offered.
                    if model.offersMigrationRetry {
                        Button(L10n.string("rules.error.migrationFailed.retry")) { Task { await model.retryMigration() } }
                            .disabled(model.isBusy)
                    }
                    if model.offersReset {
                        Button(L10n.string("rules.corrupt.reset")) { confirmsReset = true }
                            .disabled(model.isBusy)
                    }
                }
                .confirmationDialog(L10n.string("rules.corrupt.confirmTitle"), isPresented: $confirmsReset) {
                    Button(L10n.string("rules.corrupt.confirm"), role: .destructive) {
                        Task { await model.resetUnavailableConfiguration() }
                    }
                    Button(L10n.string("common.cancel"), role: .cancel) {}
                } message: {
                    Text(L10n.string("rules.corrupt.confirmMessage"))
                }
            }
            if model.conflict != nil {
                banner(symbol: "arrow.triangle.2.circlepath", tint: Palette.pendingColor) {
                    Text(RulesEditorError.conflict.message()).frame(maxWidth: .infinity, alignment: .leading)
                    Button(L10n.string("rules.conflict.discard")) { model.discardChanges() }
                    Button(L10n.string("rules.conflict.rebase")) { model.rebaseOnLatest() }
                        .keyboardShortcut(.defaultAction)
                }
            } else if let error = model.error {
                banner(symbol: "exclamationmark.triangle.fill", tint: Palette.pendingColor) {
                    Text(error.message()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    Button(L10n.string("common.close"), systemImage: "xmark") { model.dismissError() }
                        .labelStyle(.iconOnly).buttonStyle(.borderless)
                }
            }
            if let text = model.mockImportProgressText {
                banner(symbol: "doc.on.doc", tint: Color.accentColor) {
                    Text(text).monospacedDigit().frame(maxWidth: .infinity, alignment: .leading)
                    if let progress = model.mockImportProgress, progress.total > 0 {
                        ProgressView(value: Double(progress.done), total: Double(progress.total)).frame(width: 120)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    Button(L10n.string("rules.mock.importCancel")) { model.cancelMockImport() }
                }
            }
            if model.didReset {
                banner(symbol: "checkmark.circle.fill", tint: Palette.successColor) {
                    Text(model.lastBackupName.map { L10n.format("rules.reset.done", $0) }
                         ?? L10n.string("rules.reset.doneWithoutBackup"))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    Button(L10n.string("common.close"), systemImage: "xmark") { model.dismissResetNotice() }
                        .labelStyle(.iconOnly).buttonStyle(.borderless)
                }
            }
        }
    }

    private func banner(symbol: String, tint: Color, @ViewBuilder content: () -> some View) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: symbol).foregroundStyle(tint)
                content()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(tint.opacity(0.12))
            Divider()
        }
    }
}
