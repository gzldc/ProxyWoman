import AppCore
import Localization
import SwiftUI

/// The note of one rule: a private reminder shown nowhere but here. Saving an empty text clears it.
struct RuleNoteSheet: View {
    let ruleName: String
    let initialNote: String
    let save: (String) -> Void
    let cancel: () -> Void
    @State private var text: String

    init(ruleName: String, initialNote: String, save: @escaping (String) -> Void, cancel: @escaping () -> Void) {
        self.ruleName = ruleName
        self.initialNote = initialNote
        self.save = save
        self.cancel = cancel
        _text = State(initialValue: initialNote)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.string("rules.note.title")).font(.headline)
            Text(ruleName).foregroundStyle(ShellStyle.color(.textSecondary)).lineLimit(1)
            TextEditor(text: $text)
                .font(.system(size: 13))
                .frame(minHeight: 110)
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text(L10n.string("rules.note.placeholder"))
                            .foregroundStyle(ShellStyle.color(.textSecondary))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: ShellStyle.cornerRadius).strokeBorder(ShellStyle.color(.separator)))
                .accessibilityLabel(L10n.string("rules.note.title"))
            HStack {
                Spacer()
                Button(L10n.string("common.cancel"), action: cancel)
                    .buttonStyle(OutlineButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button(L10n.string("rules.note.save")) { save(text) }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 380)
    }
}
