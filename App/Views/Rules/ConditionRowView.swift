import AppCore
import FlowStore
import Localization
import RulesEngine
import SwiftUI

/// The color of the dot in front of a field or action: which message it belongs to. The words always come with it.
struct DirectionDot: View {
    enum Direction { case request, response, both, none }

    let direction: Direction

    init(_ side: ConditionSide) {
        switch side {
        case .request: direction = .request
        case .response: direction = .response
        case .both: direction = .both
        case .neither: direction = .none
        }
    }

    init(direction: Direction) { self.direction = direction }

    private var color: Color {
        switch direction {
        case .request: ShellStyle.color(RuleBuilderPresentation.dot(for: ConditionSide.request))
        case .response: ShellStyle.color(RuleBuilderPresentation.dot(for: ConditionSide.response))
        case .both, .none: ShellStyle.color(RuleBuilderPresentation.dot(for: ConditionSide.both))
        }
    }

    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8).accessibilityHidden(true)
    }
}

/// A problem found by the last failed save (or by the edits since), under the input it belongs to.
struct RuleDocumentIssueText: View {
    let session: RuleEditorSession
    let field: RuleDocumentField

    var body: some View {
        if let issue = session.validation?.issues[field] {
            Text(issue.message(limits: session.limits))
                .font(.caption)
                .foregroundStyle(Palette.failureColor)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The bordered, rounded look of an input of the rule builder.
extension View {
    func builderBordered() -> some View {
        padding(.horizontal, 8)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: ShellStyle.cornerRadius).fill(ShellStyle.color(.content)))
            .overlay(RoundedRectangle(cornerRadius: ShellStyle.cornerRadius).strokeBorder(ShellStyle.color(.separator), lineWidth: 1))
    }
}

/// One condition row of the editor's left column (spec 12.3). What it draws is decided by the row's descriptor: field
/// dropdown, key control, comparison, value control, delete. On one line, except a certificate row, which puts its value
/// on a second line under the sub-item.
struct ConditionRowView: View {
    /// 170 and 150 for Chinese; wider where the language's longest field or comparison needs it.
    static let fieldWidth: CGFloat = RuleBuilderMetrics.fieldColumnWidth()
    static let operatorWidth: CGFloat = RuleBuilderMetrics.operatorColumnWidth()

    let session: RuleEditorSession
    let rowID: UUID
    let store: FlowStore
    /// A new rule's first row opens with the cursor in its value.
    var focusValueOnAppear = false

    /// The opening focus is given once; a row scrolling or re-appearing later never takes it again.
    @State private var didFocusOnAppear = false

    private var row: ConditionRowDraft? {
        session.document?.conditions.rows.first { $0.id == rowID }
    }

    var body: some View {
        if let row {
            VStack(alignment: .leading, spacing: 8) {
                if ConditionRowPresentation.isReadOnly(row) {
                    legacyRow(row)
                } else {
                    editableRow(row, descriptor: row.descriptor())
                }
                RuleDocumentIssueText(session: session, field: .conditionRow(rowID))
            }
            .padding(12)
            .accessibilityElement(children: .contain)
            .onAppear { didFocusOnAppear = true }
        }
    }

    // MARK: rows

    private func editableRow(_ row: ConditionRowDraft, descriptor: ConditionRowDescriptor) -> some View {
        let key = row.name.isEmpty ? nil : row.name
        return VStack(alignment: .leading, spacing: 6) {
            if row.field == .certificate {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        fieldDropdown(row)
                        keyControl(row, descriptor)
                        operatorControl(row, descriptor)
                        deleteButton
                    }
                    // The suggestion list of the key box hangs over what is below.
                    .zIndex(1)
                    if descriptor.showsValue {
                        HStack(spacing: 8) {
                            // Aligned under the sub-item.
                            Color.clear.frame(width: Self.fieldWidth, height: 1)
                            valueControl(row, descriptor)
                        }
                    }
                }
                .zIndex(1)
            } else {
                HStack(spacing: 8) {
                    fieldDropdown(row)
                    keyControl(row, descriptor)
                    operatorControl(row, descriptor)
                    if descriptor.showsValue { valueControl(row, descriptor) } else { Spacer(minLength: 0) }
                    deleteButton
                }
                .zIndex(1)
            }
            if descriptor.showsValue, let hint = ConditionRowPresentation.hint(field: row.field, name: key, op: row.op) {
                RuleHelpText(text: hint)
            }
        }
    }

    /// An old-style comparison: shown, not edited; it is saved as it was. It can still be removed.
    private func legacyRow(_ row: ConditionRowDraft) -> some View {
        HStack(spacing: 6) {
            Text(ConditionPresentation.rowSummary(row.row))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            Text(L10n.string("rules.editor2.legacyTag"))
                .font(.caption)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Palette.neutralBadgeFillColor))
                .foregroundStyle(.secondary)
            deleteButton
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: field and comparison

    private func fieldDropdown(_ row: ConditionRowDraft) -> some View {
        ConditionFieldDropdown(field: row.field, isLegacyField: row.isLegacyField) { field in
            edit { $0.setField(field) }
        }
        .frame(width: Self.fieldWidth)
    }

    @ViewBuilder private func operatorControl(_ row: ConditionRowDraft, _ descriptor: ConditionRowDescriptor) -> some View {
        switch descriptor.operatorControl {
        case .none:
            EmptyView()
        case .fixed(let text):
            Text(text)
                .font(.system(size: 13))
                .frame(height: BuilderDropdownLabel<EmptyView>.height)
                .fixedSize()
                .accessibilityLabel(L10n.string("rules.editor2.row.operator"))
                .accessibilityValue(text)
        case .menu(let groups):
            let items = groups.enumerated().map { groupIndex, group in
                group.enumerated().map { index, item in
                    BuilderMenuItem(
                        id: "\(groupIndex).\(index)", title: item.title, isSelected: row.isSelected(item), isLegacy: item.isLegacy)
                }
            }
            let current = items.joined().first(where: \.isSelected)?.title ?? ConditionPresentation.operatorTitle(row.op)
            BuilderMenuDropdown(label: L10n.string("rules.editor2.row.operator"), title: current, groups: items) { id in
                let parts = id.split(separator: ".").compactMap { Int($0) }
                guard parts.count == 2, groups.indices.contains(parts[0]), groups[parts[0]].indices.contains(parts[1]) else { return }
                let item = groups[parts[0]][parts[1]]
                edit { $0.select(item) }
            }
            .frame(width: Self.operatorWidth)
        }
    }

    // MARK: key

    @ViewBuilder private func keyControl(_ row: ConditionRowDraft, _ descriptor: ConditionRowDescriptor) -> some View {
        switch descriptor.keyControl {
        case .none:
            EmptyView()
        case .autocomplete(let placeholder, let showsCase):
            SuggestionTextField(
                text: nameBinding(row), placeholder: placeholder, accessibilityLabel: L10n.string("rules.editor2.row.name"),
                source: suggestionSource(field: row.field, name: nil)
            ) {
                if showsCase {
                    ConditionCaseToggle(isOn: row.nameCaseSensitive, helpKey: "rules.editor3.key.caseSensitive") {
                        edit { $0.nameCaseSensitive.toggle() }
                    }
                }
            }
            .frame(minWidth: 96, idealWidth: 132, maxWidth: 160)
        case .text(let placeholder):
            SuggestionTextField(
                text: nameBinding(row), placeholder: placeholder, accessibilityLabel: L10n.string("rules.editor2.row.name"),
                source: suggestionSource(field: row.field, name: nil)
            )
            .frame(minWidth: 80, idealWidth: 120, maxWidth: 140)
        case .choices(let choices):
            keyDropdown(row, groups: [choices], selectedName: row.name)
        case .certificate(let groups, let legacy):
            let selected = row.name.isEmpty ? CertificateField.default.rawValue : row.name
            keyDropdown(row, groups: groups + (legacy.map { [[$0]] } ?? []), selectedName: selected)
        }
    }

    private func keyDropdown(_ row: ConditionRowDraft, groups: [[ConditionChoice]], selectedName: String) -> some View {
        let items = groups.map { $0.map { BuilderMenuItem(id: $0.value, title: $0.title, isSelected: $0.value == selectedName, isLegacy: $0.isLegacy) } }
        let current = items.joined().first(where: \.isSelected)?.title ?? CertificateFieldPresentation.title(key: row.name)
        return BuilderMenuDropdown(label: L10n.string("rules.editor2.row.name"), title: current, groups: items) { picked in
            edit { $0.setName(picked) }
        }
        .frame(minWidth: 120, maxWidth: .infinity)
    }

    // MARK: value

    @ViewBuilder private func valueControl(_ row: ConditionRowDraft, _ descriptor: ConditionRowDescriptor) -> some View {
        switch descriptor.valueControl {
        case .none:
            EmptyView()
        case .text(let suggests):
            let key = row.name.isEmpty ? nil : row.name
            SuggestionTextField(
                text: valueBinding(row), placeholder: descriptor.placeholder ?? "",
                accessibilityLabel: L10n.string("rules.editor2.row.value"),
                source: suggests && row.op != .regex ? suggestionSource(field: row.field, name: key, role: .values) : nil,
                focusOnAppear: focusValueOnAppear && !didFocusOnAppear
            ) {
                if !row.value.isEmpty { ConditionClearButton { edit { $0.value = "" } } }
                if descriptor.showsValueCase {
                    ConditionCaseToggle(isOn: row.caseSensitive, helpKey: "rules.builder.caseSensitive") {
                        edit { $0.caseSensitive.toggle() }
                    }
                }
            }
            .frame(minWidth: 80, maxWidth: .infinity)
            .layoutPriority(1)
        case .dropdown(let choices):
            valueDropdown(row, groups: [choices])
        case .groupedDropdown(let groups):
            valueDropdown(row, groups: groups)
        case .date:
            ConditionDateBox(
                value: row.value, placeholder: descriptor.placeholder ?? "",
                setDate: { date in edit { $0.setDate(date) } }, clear: { edit { $0.value = "" } }
            )
            .frame(minWidth: 120, maxWidth: .infinity)
            .layoutPriority(1)
        }
    }

    private func valueDropdown(_ row: ConditionRowDraft, groups: [[ConditionChoice]]) -> some View {
        let current = row.value.lowercased()
        // The old options go last, marked.
        let regular = groups.map { $0.filter { !$0.isLegacy } }.filter { !$0.isEmpty }
        let legacy = groups.flatMap { $0.filter(\.isLegacy) }
        let all = regular + (legacy.isEmpty ? [] : [legacy])
        let items = all.map {
            $0.map { BuilderMenuItem(id: $0.value, title: $0.title, isSelected: $0.value.lowercased() == current, isLegacy: $0.isLegacy) }
        }
        let title = items.joined().first(where: \.isSelected)?.title ?? row.value
        return BuilderMenuDropdown(label: L10n.string("rules.editor2.row.value"), title: title, groups: items) { picked in
            edit { $0.value = picked }
        }
        .frame(minWidth: 120, maxWidth: .infinity)
        .layoutPriority(1)
    }

    // MARK: delete

    private var deleteButton: some View {
        Button {
            session.update { $0.conditions.removeRow(rowID) }
        } label: {
            Image(systemName: "trash")
        }
        .buttonStyle(DeleteSquareButtonStyle())
        .disabled(!(session.document?.conditions.canRemoveRows ?? false))
        .help(L10n.string("rules.builder.deleteCondition"))
        .accessibilityLabel(L10n.string("rules.builder.deleteCondition"))
    }

    // MARK: editing

    private func edit(_ change: (inout ConditionRowDraft) -> Void) {
        session.update { document in
            guard let index = document.conditions.rows.firstIndex(where: { $0.id == rowID }) else { return }
            change(&document.conditions.rows[index])
        }
    }

    private func valueBinding(_ fallback: ConditionRowDraft) -> Binding<String> {
        Binding(get: { (self.row ?? fallback).value }, set: { new in edit { $0.value = new } })
    }

    private func nameBinding(_ fallback: ConditionRowDraft) -> Binding<String> {
        Binding(get: { (self.row ?? fallback).name }, set: { new in edit { $0.setName(new) } })
    }

    /// What recent traffic had for this field and key; read off the main actor. A large candidate set is loaded: the box
    /// filters it by what is typed and then keeps the first few, so the cap must not cut before the filter.
    private func suggestionSource(
        field: ConditionField, name: String?, role: ConditionSuggestions.Role = .names
    ) -> SuggestionSource {
        let store = store
        return SuggestionSource(key: "\(field)|\(name ?? "")|\(role)") {
            ConditionSuggestions.values(field: field, name: name, role: role, in: store.recentFlows(limit: 300), limit: 500)
        }
    }
}

/// A 28 x 28 square button with a light red outline and a pale red wash, for deleting a condition or an action.
struct DeleteSquareButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13))
            .foregroundStyle(ShellStyle.color(.failure))
            .frame(width: BuilderDropdownLabel<EmptyView>.height, height: BuilderDropdownLabel<EmptyView>.height)
            .background(
                RoundedRectangle(cornerRadius: ShellStyle.cornerRadius)
                    .fill(ShellStyle.color(configuration.isPressed ? .failureSoftPressed : .failureSoft)))
            .overlay(
                RoundedRectangle(cornerRadius: ShellStyle.cornerRadius)
                    .strokeBorder(ShellStyle.color(.failureBorder), lineWidth: 1))
            .opacity(isEnabled ? 1 : 0.5)
            .contentShape(RoundedRectangle(cornerRadius: ShellStyle.cornerRadius))
    }
}
