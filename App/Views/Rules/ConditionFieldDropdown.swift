import AppCore
import Localization
import RulesEngine
import SwiftUI

/// The circular direction arrow in front of a field (request blue, response orange, both green).
struct ConditionDirectionIcon: View {
    let direction: ConditionDirection
    var dimmed = false
    var size: CGFloat = 14

    var body: some View {
        Image(systemName: direction.symbolName)
            .font(.system(size: size))
            .foregroundStyle(ShellStyle.color(direction.token))
            .opacity(dimmed ? 0.45 : 1)
            .accessibilityHidden(true)
    }
}

/// The direction a field is shown with: the menu's, or for an old field the menu does not list, the side the engine reads.
func conditionDirection(of field: ConditionField) -> ConditionDirection {
    if ConditionFieldCatalog.menuFields.contains(field) { return ConditionFieldCatalog.direction(of: field) }
    switch field.side {
    case .request, .neither: return .request
    case .response: return .response
    case .both: return .both
    }
}

/// The field dropdown of a condition row: the closed box shows the direction icon and the field (with an "old style" tag
/// for a saved field the menu does not offer); the list opens in a popover.
struct ConditionFieldDropdown: View {
    let field: ConditionField
    let isLegacyField: Bool
    let choose: (ConditionField) -> Void

    @State private var showsList = false

    var body: some View {
        Button {
            showsList.toggle()
        } label: {
            BuilderDropdownLabel(
                title: ConditionPresentation.fieldTitle(field),
                tag: isLegacyField ? L10n.string("rules.editor2.legacyTag") : nil
            ) {
                ConditionDirectionIcon(direction: conditionDirection(of: field))
            }
        }
        .buttonStyle(.plain)
        .help(conditionDirection(of: field).title())
        .accessibilityLabel(L10n.string("rules.editor2.row.field"))
        .accessibilityValue(L10n.format("rules.editor3.fieldValue", ConditionPresentation.fieldTitle(field), conditionDirection(of: field).title()))
        .popover(isPresented: $showsList, arrowEdge: .bottom) {
            ConditionFieldList(selected: field) { picked in
                showsList = false
                choose(picked)
            }
        }
    }
}

/// The field list: three headed sections (request, response, other), a direction icon in front of each field, the deprecated ones grey
/// and not selectable (hover and VoiceOver say "deprecated").
private struct ConditionFieldList: View {
    private static let width = RuleBuilderMetrics.fieldListWidth()

    let selected: ConditionField
    let choose: (ConditionField) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(ConditionFieldCatalog.menuSections.enumerated()), id: \.offset) { index, section in
                        header(section.kind, first: index == 0)
                        ForEach(section.entries, id: \.field) { entry in row(entry).id(entry.field) }
                    }
                }
                .padding(4)
            }
            // The list opens with the current field in view.
            .onAppear { proxy.scrollTo(selected, anchor: .center) }
        }
        .frame(width: Self.width, height: 360)
    }

    /// A caption that names the section; not a button, so arrow keys and Tab skip it, and VoiceOver reads it as a heading.
    private func header(_ kind: ConditionFieldSectionKind, first: Bool) -> some View {
        Text(kind.title())
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(ShellStyle.color(.textSecondary))
            .padding(.horizontal, 6)
            .padding(.top, first ? 2 : 10)
            .padding(.bottom, 3)
            .accessibilityAddTraits(.isHeader)
    }

    private func row(_ entry: ConditionMenuEntry) -> some View {
        let title = ConditionPresentation.fieldTitle(entry.field)
        let deprecated = L10n.string("rules.editor3.deprecated.tag")
        return Button {
            choose(entry.field)
        } label: {
            HStack(spacing: 8) {
                ConditionDirectionIcon(direction: entry.direction, dimmed: entry.isDeprecated)
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(ShellStyle.color(entry.isDeprecated ? .textSecondary : .textPrimary))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                if entry.field == selected { Image(systemName: "checkmark").font(.system(size: 11)) }
            }
            .padding(.horizontal, 6)
            .frame(height: 24)
            .background(
                RoundedRectangle(cornerRadius: ShellStyle.cornerRadius)
                    .fill(entry.field == selected ? ShellStyle.color(.selection) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(entry.isDeprecated)
        .help(entry.isDeprecated ? deprecated : entry.direction.title())
        .accessibilityLabel(entry.isDeprecated ? L10n.format("rules.editor3.deprecatedLabel", title) : title)
        .accessibilityValue(entry.direction.title())
    }
}
