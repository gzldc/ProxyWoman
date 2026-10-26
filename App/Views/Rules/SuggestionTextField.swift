import AppCore
import Localization
import SwiftUI

/// The scrolling viewport a suggestion list must fit in: its coordinate space and its height. Without it the list always
/// opens downward.
enum SuggestionViewport {
    static let space = "suggestionViewport"
}

private struct SuggestionViewportHeightKey: EnvironmentKey {
    static let defaultValue: CGFloat? = nil
}

extension EnvironmentValues {
    var suggestionViewportHeight: CGFloat? {
        get { self[SuggestionViewportHeightKey.self] }
        set { self[SuggestionViewportHeightKey.self] = newValue }
    }
}

/// The bottom edge of a suggestion box inside the viewport.
private struct SuggestionBoxBottomKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// Where a `SuggestionTextField` gets its candidates: `load` runs off the main actor, `key` tells when the candidates
/// of an earlier load no longer apply (another field or key).
struct SuggestionSource: Sendable {
    var key: String
    var load: @Sendable () -> [String]
}

/// A 28 pt bordered text box with a suggestion list under it while the user types: 200 ms after the last keystroke the
/// candidates that contain the text are offered; a click fills the text, Up / Down / Return pick from the keyboard
/// and Esc closes the list. Anything after the text (the clear mark, the case switch) goes in `trailing`.
struct SuggestionTextField<Trailing: View>: View {
    static var debounce: Duration { .milliseconds(200) }
    private static var rowHeight: CGFloat { 26 }
    private static var limit: Int { 8 }

    @Binding var text: String
    let placeholder: String
    let accessibilityLabel: String
    /// nil: no list (a regular expression, a body, a field without suggestions).
    let source: SuggestionSource?
    var focusOnAppear = false
    let trailing: Trailing

    @FocusState private var focused: Bool
    @State private var shown: [String] = []
    @State private var highlighted: Int?
    @State private var filled: String?
    /// The pointer is over the list: a click on an entry must land even though the text box lost the focus.
    @State private var overList = false
    @State private var boxBottom: CGFloat = 0
    @Environment(\.suggestionViewportHeight) private var viewportHeight

    init(
        text: Binding<String>, placeholder: String, accessibilityLabel: String, source: SuggestionSource?, focusOnAppear: Bool = false,
        @ViewBuilder trailing: () -> Trailing
    ) {
        _text = text
        self.placeholder = placeholder
        self.accessibilityLabel = accessibilityLabel
        self.source = source
        self.focusOnAppear = focusOnAppear
        self.trailing = trailing()
    }

    private var isOpen: Bool { !shown.isEmpty }

    /// Not enough room under the box inside the scrolling viewport, and more above it: the list opens upward.
    private var opensUpward: Bool {
        guard isOpen, let viewportHeight else { return false }
        let listHeight = CGFloat(shown.count) * Self.rowHeight + 6 + 2
        let below = viewportHeight - boxBottom
        let above = boxBottom - BuilderDropdownLabel<EmptyView>.height
        return below < listHeight && above > below
    }

    var body: some View {
        HStack(spacing: 6) {
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($focused)
                .accessibilityLabel(accessibilityLabel)
                .onKeyPress(.downArrow) { handleDown() }
                .onKeyPress(.upArrow) { handleUp() }
                .onKeyPress(.return) { handleReturn() }
                .onKeyPress(.escape) { handleEscape() }
            trailing
        }
        .builderBordered()
        .overlay {
            // The focused box shows the accent border, as the name field does.
            RoundedRectangle(cornerRadius: ShellStyle.cornerRadius)
                .strokeBorder(ShellStyle.color(.accent), lineWidth: focused ? 1 : 0)
                .allowsHitTesting(false)
        }
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: SuggestionBoxBottomKey.self, value: proxy.frame(in: .named(SuggestionViewport.space)).maxY)
            }
        }
        .onPreferenceChange(SuggestionBoxBottomKey.self) { boxBottom = $0 }
        .overlay(alignment: opensUpward ? .bottomLeading : .topLeading) {
            if isOpen {
                list.offset(y: (BuilderDropdownLabel<EmptyView>.height + 2) * (opensUpward ? -1 : 1))
            }
        }
        .onAppear {
            if focusOnAppear { Task { @MainActor in focused = true } }
        }
        .task(id: text) { await typed() }
        .onChange(of: focused) { _, now in
            // Leaving the box closes the list, unless the pointer is on it (a click on an entry is under way).
            if !now, !overList { close() }
        }
        .onChange(of: source?.key) { _, _ in close() }
    }

    // MARK: list

    private var list: some View {
        VStack(spacing: 0) {
            ForEach(Array(shown.enumerated()), id: \.offset) { index, candidate in
                Button {
                    fill(candidate)
                } label: {
                    Text(candidate)
                        .font(.system(size: 13))
                        .foregroundStyle(ShellStyle.color(.textPrimary))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 8)
                        .frame(maxWidth: .infinity, minHeight: Self.rowHeight, alignment: .leading)
                        .background(highlighted == index ? ShellStyle.color(.selection) : Color.clear)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { inside in if inside { highlighted = index } }
            }
        }
        .padding(.vertical, 3)
        .frame(minWidth: 160, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: ShellStyle.cornerRadius).fill(ShellStyle.color(.content)))
        .overlay(RoundedRectangle(cornerRadius: ShellStyle.cornerRadius).strokeBorder(ShellStyle.color(.separator), lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.string("rules.editor2.row.suggestions"))
        .onHover { inside in
            overList = inside
            // The pointer left a list whose box is no longer focused.
            if !inside, !focused { close() }
        }
    }

    // MARK: behaviour

    /// The text changed: after the debounce, list what recent traffic had that contains it.
    private func typed() async {
        if text != filled { filled = nil }
        guard let source, focused, filled == nil else { close(); return }
        try? await Task.sleep(for: Self.debounce)
        guard !Task.isCancelled else { return }
        await show(source: source, for: text)
    }

    private func show(source: SuggestionSource, for typedText: String) async {
        let load = source.load
        let candidates = await Task.detached(priority: .utility) { load() }.value
        // Another keystroke started a newer pass: this one is stale.
        guard !Task.isCancelled, typedText == text else { return }
        shown = ConditionSuggestions.matching(candidates, typed: typedText, limit: Self.limit)
        highlighted = nil
    }

    private func close() {
        if !shown.isEmpty { shown = [] }
        highlighted = nil
        overList = false
    }

    private func fill(_ candidate: String) {
        filled = candidate
        text = candidate
        close()
    }

    private func handleDown() -> KeyPress.Result {
        guard source != nil else { return .ignored }
        if isOpen {
            highlighted = highlighted.map { min($0 + 1, shown.count - 1) } ?? 0
        } else if let source {
            let current = text
            Task { await show(source: source, for: current) }
        }
        return .handled
    }

    private func handleUp() -> KeyPress.Result {
        guard isOpen else { return .ignored }
        highlighted = highlighted.map { max($0 - 1, 0) } ?? shown.count - 1
        return .handled
    }

    private func handleReturn() -> KeyPress.Result {
        guard isOpen, let highlighted, shown.indices.contains(highlighted) else { return .ignored }
        fill(shown[highlighted])
        return .handled
    }

    private func handleEscape() -> KeyPress.Result {
        guard isOpen else { return .ignored }
        close()
        return .handled
    }
}

extension SuggestionTextField where Trailing == EmptyView {
    init(text: Binding<String>, placeholder: String, accessibilityLabel: String, source: SuggestionSource?, focusOnAppear: Bool = false) {
        self.init(
            text: text, placeholder: placeholder, accessibilityLabel: accessibilityLabel, source: source, focusOnAppear: focusOnAppear
        ) { EmptyView() }
    }
}
