import AppCore
import Localization
import RulesEngine
import SwiftUI

/// The one-time upgrade notice at the top of the Rules window (spec 5.6.4), or, once it was read, the
/// button that opens it again. Nothing is shown when the stored file has no notice. Everything comes from
/// `RulesEditorModel`; the sentences are built there from the stored classes and rule ids.
struct UpgradeNoticeBlock: View {
    let model: RulesEditorModel
    /// Selects (and scrolls to) the rule in the outline; the editor is not opened.
    let select: (UUID) -> Void

    var body: some View {
        if let notice = model.upgradeNotice {
            block(notice)
        } else if model.hasUpgradeNotice {
            reopenRow
        }
    }

    // MARK: the notice

    private func block(_ notice: UpgradeNoticePresentation) -> some View {
        // Which listed rules still exist: a deleted rule's row stays but cannot be opened.
        let existing = Set(model.rules.map(\.id))
        return VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(Color.accentColor)
                    Text(L10n.string("rules.upgrade.title")).font(.headline)
                    Spacer(minLength: 8)
                    Button(L10n.string("rules.upgrade.acknowledge")) { Task { await model.acknowledgeUpgradeNotice() } }
                        .disabled(!model.canAcknowledgeUpgradeNotice)
                }
                // Everything else scrolls, so a long list never pushes the rules table out of the window.
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(notice.introText())
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(notice.sections, id: \.changeClass) { section in
                            self.section(section, in: notice, existing: existing)
                        }
                        if let omitted = notice.omittedText() {
                            Text(omitted).fixedSize(horizontal: false, vertical: true)
                        }
                        if notice.showsAdvice {
                            Text(L10n.string("rules.upgrade.advice"))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 90, idealHeight: 170, maxHeight: 220)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.accentColor.opacity(0.08))
            Divider()
        }
    }

    private func section(_ section: UpgradeNoticeSection, in notice: UpgradeNoticePresentation, existing: Set<UUID>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.string(section.titleKey)).fontWeight(.semibold)
            Text(L10n.string(section.bodyKey))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // A stored notice lists up to thousands of pairs; only the rows in view are built.
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(section.items) { item in
                    Button {
                        select(item.lowerID)
                    } label: {
                        Text(notice.pairText(item))
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(existing.contains(item.lowerID) ? Color.accentColor : Color.secondary)
                    .disabled(!existing.contains(item.lowerID))
                }
            }
        }
    }

    // MARK: after it was read

    /// "View upgrade notes": in the banner area until the Rules window has a menu for it (R5).
    private var reopenRow: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer(minLength: 0)
                Button(L10n.string("rules.upgrade.reopen")) { model.reopenUpgradeNotice() }
                    .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            Divider()
        }
    }
}
