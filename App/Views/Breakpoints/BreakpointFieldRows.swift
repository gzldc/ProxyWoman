import AppCore
import Localization
import SwiftUI

/// A labelled single-line field of the breakpoint editor. A standard bordered text field with its own
/// accessibility label: a bare label-and-value row in a grouped form did not take accessibility value
/// writes (VoiceOver, automation), while the Compose page's plain fields do.
struct BreakpointFieldRow: View {
    let title: String
    @Binding var text: String
    var monospaced = false
    var isEditable = true

    var body: some View {
        // The visible label is hidden from accessibility: the field carries the same label itself, so
        // VoiceOver would otherwise read the title as a static text and again as the field's name.
        LabeledContent {
            TextField(title, text: $text)
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .font(monospaced ? .body.monospaced() : .body)
                .disabled(!isEditable)
                .accessibilityLabel(title)
        } label: {
            Text(title).accessibilityHidden(true)
        }
    }
}

/// One header of the breakpoint editor: name, value and a remove button, each a standard text field.
struct BreakpointHeaderEditRow: View {
    @Binding var row: HeaderFieldRow
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            TextField(L10n.string("breakpoints.editor.headerName"), text: $row.name)
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(L10n.string("breakpoints.editor.headerName"))
                .frame(maxWidth: 200)
            TextField(L10n.string("breakpoints.editor.headerValue"), text: $row.value)
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(L10n.string("breakpoints.editor.headerValue"))
            Button(L10n.string("breakpoints.editor.removeHeader"), systemImage: "minus.circle", action: remove)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
        }
    }
}
