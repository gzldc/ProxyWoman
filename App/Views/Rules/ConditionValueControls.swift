import AppCore
import Localization
import SwiftUI

/// The small "x" inside a box that empties it.
struct ConditionClearButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
        }
        .buttonStyle(.plain)
        .foregroundStyle(ShellStyle.color(.textSecondary))
        .help(L10n.string("rules.builder.clearValue"))
        .accessibilityLabel(L10n.string("rules.builder.clearValue"))
    }
}

/// The "Aa" switch inside a box: accent while the comparison is case sensitive.
struct ConditionCaseToggle: View {
    let isOn: Bool
    let helpKey: String
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            Text(verbatim: "Aa")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isOn ? ShellStyle.color(.accent) : ShellStyle.color(.textSecondary))
        }
        .buttonStyle(.plain)
        .help(L10n.string(helpKey))
        .accessibilityLabel(L10n.string(helpKey))
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// The date value as an `MM/DD/YYYY` field. Without a stored day it shows the placeholder, and a click starts on today.
struct ConditionDateBox: View {
    /// The stored value (`yyyy-MM-dd`, or empty).
    let value: String
    let placeholder: String
    let setDate: (Date) -> Void
    let clear: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            if let date = ConditionDate.date(from: value) {
                ConditionDateField(date: date, setDate: setDate)
                Spacer(minLength: 0)
            } else {
                Button {
                    setDate(Date())
                } label: {
                    HStack {
                        Text(value.isEmpty ? placeholder : value)
                            .font(.system(size: 13))
                            .foregroundStyle(ShellStyle.color(.textSecondary))
                        Spacer(minLength: 0)
                        Image(systemName: "calendar").foregroundStyle(ShellStyle.color(.textSecondary))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L10n.string("rules.editor3.date.choose"))
                .accessibilityLabel(L10n.string("rules.editor3.date.choose"))
            }
            if !value.isEmpty { ConditionClearButton(action: clear) }
        }
        .builderBordered()
    }
}

/// The month / day / year field of a date row. It keeps its own copy of the
/// picked date and hands every change back, so no setter closure has to cross
/// into the picker's binding.
private struct ConditionDateField: View {
    let date: Date
    let setDate: (Date) -> Void
    @State private var picked: Date

    init(date: Date, setDate: @escaping (Date) -> Void) {
        self.date = date
        self.setDate = setDate
        _picked = State(initialValue: date)
    }

    var body: some View {
        DatePicker(
            L10n.string("rules.editor2.row.value"),
            selection: $picked,
            displayedComponents: .date
        )
        .labelsHidden()
        .datePickerStyle(.field)
        // The field always reads month / day / year.
        .environment(\.locale, Locale(identifier: "en_US"))
        .accessibilityLabel(L10n.string("rules.editor2.row.value"))
        .onChange(of: date) { _, new in if new != picked { picked = new } }
        .onChange(of: picked) { _, new in if new != date { setDate(new) } }
    }
}
