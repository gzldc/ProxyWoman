import AppCore
import FlowStore
import Localization
import RulesEngine
import SwiftUI

/// "N matches in the current tab" for the whole group of conditions, at the end of the list: red at zero, otherwise
/// secondary grey, with a "view" link when something matched. Counted off the main actor, again whenever the group
/// changes and whenever the store changes; a group that is not valid yet reads as zero.
struct ConditionGroupCountLine: View {
    /// nil while the rows or the count are not valid yet.
    let group: ConditionGroup?
    let store: FlowStore
    let showMatches: ([Int]) -> Void

    @State private var service = LiveMatchService()
    @State private var report: LiveMatchReport?

    var body: some View {
        let line = ConditionGroupPresentation.matchCountLine(count: report?.matchedIDs.count, groupIsValid: group != nil)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                // The line keeps its height while the first count is still running.
                Text(line?.text ?? L10n.string("rules.liveCount.counting"))
                    .font(.system(size: 12))
                    .foregroundStyle(ShellStyle.color(line?.tone == .failure ? .failure : .textSecondary))
                if let line, line.showsViewLink, let report {
                    Button(L10n.string("rules.liveCount.view")) { showMatches(report.matchedIDs) }
                        .buttonStyle(.link)
                        .font(.system(size: 12))
                }
            }
            .frame(minHeight: 16, alignment: .leading)
            if group != nil, let report, report.skippedLargeBodies > 0 {
                RuleHelpText(text: L10n.format("rules.liveCount.skippedLargeBodies", report.skippedLargeBodies))
            }
        }
        .accessibilityElement(children: .contain)
        // The previous count stays until the new one is in, so the line does not flicker while typing. The stream
        // counts once after the debounce, then follows the store (sessions finishing, pausing, arriving); the task
        // ends with the view or when the group changes.
        .task(id: group) {
            guard let group else { report = nil; return }
            for await next in service.updates(group, store: store) { report = next }
        }
    }
}

/// The yellow card under the rows when a row uses a field that is being retired.
struct ConditionDeprecationCard: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Palette.pendingColor)
                .accessibilityHidden(true)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(ShellStyle.color(.textPrimary))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: ShellStyle.cornerRadius).fill(ShellStyle.color(.paused)))
        .overlay(RoundedRectangle(cornerRadius: ShellStyle.cornerRadius).strokeBorder(Palette.pendingColor.opacity(0.5), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

/// "Sessions will be matched on Request." with the direction icon in front and the info mark behind.
struct ConditionExecutionLineView: View {
    let line: ConditionExecutionLine

    var body: some View {
        HStack(spacing: 6) {
            ConditionDirectionIcon(direction: line.direction)
            Text(line.text)
            Image(systemName: "info.circle")
                .foregroundStyle(ShellStyle.color(.textSecondary))
                .help(L10n.string("rules.builder.matchedAt.help"))
                .accessibilityLabel(L10n.string("rules.builder.matchedAt.help"))
        }
        .font(.system(size: 13))
        .accessibilityElement(children: .combine)
    }
}
