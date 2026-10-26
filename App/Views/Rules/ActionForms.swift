import AppCore
import AppKit
import FlowStore
import Localization
import RulesEngine
import SwiftUI

/// The problems of one action card, shown under the input each belongs to.
struct ActionIssues {
    var issues: [ActionField: RuleDraftIssue]
    var limits: RulesLimits

    func line(_ field: ActionField) -> some View {
        ActionIssueLine(issue: issues[field], limits: limits)
    }

    /// One line per distinct field, in order (several boxes of a table card share one field).
    @ViewBuilder func lines(_ fields: [ActionField?]) -> some View {
        let distinct = fields.reduce(into: [ActionField]()) { result, field in
            if let field, !result.contains(field) { result.append(field) }
        }
        ForEach(distinct, id: \.self) { ActionIssueLine(issue: issues[$0], limits: limits) }
    }
}

private struct ActionIssueLine: View {
    let issue: RuleDraftIssue?
    let limits: RulesLimits

    var body: some View {
        if let issue {
            Text(issue.message(limits: limits))
                .font(.caption)
                .foregroundStyle(Palette.failureColor)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// "Action 3's method": the name an input is announced with, so two cards' inputs are told apart.
func actionFieldLabel(index: Int, _ key: String) -> String {
    L10n.format("rules.card.fieldLabel", index + 1, L10n.string(key))
}

extension View {
    /// The bordered, rounded box of the builder's inputs for content taller than one line.
    func actionBox(minHeight: CGFloat = BuilderDropdownLabel<EmptyView>.height, vertical: CGFloat = 0, isInvalid: Bool = false) -> some View {
        padding(.horizontal, 8)
            .padding(.vertical, vertical)
            .frame(minHeight: minHeight, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: ShellStyle.cornerRadius).fill(ShellStyle.color(.content)))
            .overlay(
                RoundedRectangle(cornerRadius: ShellStyle.cornerRadius)
                    .strokeBorder(isInvalid ? Palette.failureColor : ShellStyle.color(.separator), lineWidth: 1))
    }
}

/// A text input in the builder's look with its accessibility label; `mono` for texts that are kept exactly as typed.
struct ActionTextField: View {
    let title: String
    @Binding var text: String
    var mono = false
    var multiline = false

    init(_ title: String, text: Binding<String>, mono: Bool = false, multiline: Bool = false) {
        self.title = title
        _text = text
        self.mono = mono
        self.multiline = multiline
    }

    var body: some View {
        Group {
            if multiline {
                TextField(title, text: $text, axis: .vertical).lineLimit(1...6).padding(.vertical, 5)
            } else {
                TextField(title, text: $text)
            }
        }
        .textFieldStyle(.plain)
        .font(.system(size: 13, design: mono ? .monospaced : .default))
        .actionBox()
        .accessibilityLabel(title)
    }
}

/// A box of several lines (a regular expression, a body, the magic string); `trailing` goes at its right edge.
struct ActionMultilineField<Trailing: View>: View {
    let placeholder: String
    let accessibilityLabel: String
    @Binding var text: String
    var minLines = 3
    let trailing: Trailing

    init(
        placeholder: String, accessibilityLabel: String, text: Binding<String>, minLines: Int = 3,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.placeholder = placeholder
        self.accessibilityLabel = accessibilityLabel
        _text = text
        self.minLines = minLines
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            TextField(placeholder, text: $text, axis: .vertical)
                .lineLimit(minLines...10)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .autocorrectionDisabled()
                .accessibilityLabel(accessibilityLabel)
            trailing
        }
        .actionBox(vertical: 6)
    }
}

/// Up, down and remove for one row of an ordered table.
struct ActionRowControls<Row: Identifiable>: View where Row.ID == UUID {
    @Binding var rows: [Row]
    let id: UUID

    var body: some View {
        let index = rows.firstIndex { $0.id == id } ?? 0
        HStack(spacing: 2) {
            Button(L10n.string("rules.list.moveUp"), systemImage: "chevron.up") { rows.swapAt(index, index - 1) }
                .disabled(index == 0)
                .accessibilityLabel(L10n.string("rules.list.moveUp"))
            Button(L10n.string("rules.list.moveDown"), systemImage: "chevron.down") { rows.swapAt(index, index + 1) }
                .disabled(index >= rows.count - 1)
                .accessibilityLabel(L10n.string("rules.list.moveDown"))
            Button(L10n.string("rules.headers.removeRow"), systemImage: "minus.circle") { rows.removeAll { $0.id == id } }
                .accessibilityLabel(L10n.string("rules.headers.removeRow"))
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
    }
}

/// A grey caption under a field or a section.
struct RuleHelpText: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: suggestions

/// What recent traffic offers while a key or a find box is typed in: the names or values of the field the card edits.
enum ActionSuggestions {
    static func field(for type: ActionType) -> ConditionField? {
        switch type {
        case .modifyURL: .url
        case .modifyQuery: .queryParam
        case .editRequestHeaders: .requestHeader
        case .editResponseHeaders: .responseHeader
        case .editRequestCookies: .requestCookie
        case .editResponseCookies: .responseCookie
        default: nil
        }
    }

    /// `role` names: the names (the key box); values: the values of that key (the find box), or of every key while the
    /// key is still empty.
    static func source(
        type: ActionType, name: String?, role: ConditionSuggestions.Role = .names, store: FlowStore
    ) -> SuggestionSource? {
        guard let field = field(for: type) else { return nil }
        let name = (name?.isEmpty ?? true) ? nil : name
        return SuggestionSource(key: "\(field)|\(name ?? "")|\(role)") {
            ConditionSuggestions.values(field: field, name: name, role: role, in: store.recentFlows(limit: 300), limit: 500)
        }
    }
}

/// The key box of a header, cookie or query card, in the card's header: every key while empty, and the key's "Aa".
struct ActionKeyField: View {
    let store: FlowStore
    let index: Int
    let descriptor: ActionEditorDescriptor
    @Binding var action: ActionDraft

    var body: some View {
        if case .autocomplete(let placeholder) = descriptor.keyControl {
            let caseOn = descriptor.keyCaseOn
            SuggestionTextField(
                text: $action.keyText, placeholder: placeholder,
                accessibilityLabel: actionFieldLabel(index: index, "rules.headers.name"),
                source: ActionSuggestions.source(type: action.type, name: nil, store: store)
            ) {
                if descriptor.showsKeyCase {
                    ConditionCaseToggle(isOn: caseOn, helpKey: "rules.editor3.key.caseSensitive") { action.setKeyCase(!caseOn) }
                }
            }
        }
    }
}

// MARK: the edit forms

/// The editor of the types that change a text: URL, query, header, cookie, body, status, delay, comment and the magic
/// string. Everything it draws is decided by the card's `ActionEditorDescriptor`.
struct ActionEditForm: View {
    let session: RuleEditorSession
    let store: FlowStore
    let index: Int
    let descriptor: ActionEditorDescriptor
    @Binding var action: ActionDraft
    let issues: ActionIssues

    @State private var converting = false
    /// The magic string names an existing file; looked up when its text changes, never while drawing.
    @State private var offersReturnFile = false

    var body: some View {
        let fields = action.editFields
        VStack(alignment: .leading, spacing: 8) {
            if !descriptor.modes.isEmpty {
                HStack(spacing: 8) {
                    modeDropdown(descriptor)
                    if case .singleLine(let suggests) = descriptor.find {
                        findBox(descriptor, suggests: suggests, multiline: false)
                    }
                }
            }
            if descriptor.find == .multiLine { findBox(descriptor, suggests: false, multiline: true) }
            valueControl(descriptor)
            legacyInputs(descriptor)
            issues.lines([fields.key, fields.find, fields.value, fields.list])
            if action.type == .delay { RuleHelpText(text: L10n.string("rules.delay.help")) }
            if action.type == .magicString { magicStringExtras(descriptor) }
        }
        .task(id: action.type == .magicString ? action.valueText : "") {
            offersReturnFile = action.type == .magicString && descriptor.offersReturnFile
        }
    }

    // MARK: pieces

    private func modeDropdown(_ descriptor: ActionEditorDescriptor) -> some View {
        let items = descriptor.modes.map {
            BuilderMenuItem(id: $0.id, title: $0.title, isSelected: $0.id == descriptor.selectedMode)
        }
        return BuilderMenuDropdown(
            label: actionFieldLabel(index: index, "rules.form.method"), title: items.first(where: \.isSelected)?.title ?? "", groups: [items]
        ) { id in
            action.setMode(id)
        }
        .frame(width: RuleBuilderMetrics.modeDropdownWidth(descriptor))
    }

    @ViewBuilder private func findBox(_ descriptor: ActionEditorDescriptor, suggests: Bool, multiline: Bool) -> some View {
        let label = actionFieldLabel(index: index, "rules.rewriteBody.find")
        let placeholder = L10n.string("rules.rewriteBody.find")
        let caseToggle = descriptor.showsValueCase
        if multiline {
            ActionMultilineField(placeholder: placeholder, accessibilityLabel: label, text: $action.findText) {
                if caseToggle { caseSwitch }
            }
        } else {
            let key = action.keyText
            SuggestionTextField(
                text: $action.findText, placeholder: placeholder, accessibilityLabel: label,
                source: suggests ? ActionSuggestions.source(type: action.type, name: key, role: .values, store: store) : nil
            ) {
                if !action.findText.isEmpty { ConditionClearButton { action.findText = "" } }
                if caseToggle { caseSwitch }
            }
            .frame(minWidth: 80, maxWidth: .infinity)
        }
    }

    private var caseSwitch: some View {
        ConditionCaseToggle(isOn: action.matchCase, helpKey: "rules.builder.caseSensitive") { action.matchCase.toggle() }
    }

    @ViewBuilder private func valueControl(_ descriptor: ActionEditorDescriptor) -> some View {
        switch descriptor.value {
        case .none:
            EmptyView()
        case .line(let placeholder):
            let label: String =
                switch action.type {
                case .rewriteStatus: actionFieldLabel(index: index, "rules.rewriteStatus.status")
                case .delay: actionFieldLabel(index: index, "rules.delay.milliseconds")
                default: actionFieldLabel(index: index, "rules.headers.value")
                }
            SuggestionTextField(
                text: $action.valueText,
                placeholder: placeholder, accessibilityLabel: label, source: nil
            ) {
                if !action.valueText.isEmpty { ConditionClearButton { action.valueText = "" } }
            }
            .frame(maxWidth: action.type == .delay ? 220 : .infinity)
        case .bigEditor:
            bigEditor(descriptor)
        case .multiLine:
            ActionMultilineField(
                placeholder: L10n.string("rules.magicString.placeholder"),
                accessibilityLabel: actionFieldLabel(index: index, "rules.headers.value"), text: $action.valueText
            ) {
                if !action.valueText.isEmpty { ConditionClearButton { action.valueText = "" } }
            }
        }
    }

    /// A body's value: a tall mono editor and, above it, the language the text is highlighted as (it never changes traffic).
    private func bigEditor(_ descriptor: ActionEditorDescriptor) -> some View {
        let fields = action.editFields
        let languages = descriptor.languages.map {
            BuilderMenuItem(id: $0.id, title: $0.title, isSelected: $0.id == descriptor.selectedLanguage)
        }
        return VStack(alignment: .trailing, spacing: 6) {
            BuilderMenuDropdown(
                label: actionFieldLabel(index: index, "rules.action.language"),
                title: languages.first(where: \.isSelected)?.title ?? "", groups: [languages]
            ) { id in
                action.setEditorLanguage(id)
            }
            .frame(width: RuleBuilderMetrics.languageDropdownWidth(descriptor))
            TextEditor(text: $action.valueText)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .autocorrectionDisabled()
                .frame(minHeight: 140, maxHeight: 320)
                .padding(.horizontal, -3)
                .actionBox(minHeight: 140, vertical: 4, isInvalid: issues.issues[fields.value ?? .bodyReplacement] != nil)
                .accessibilityLabel(actionFieldLabel(index: index, "rules.headers.value"))
        }
    }

    /// Old-style inputs a saved card still carries.
    @ViewBuilder private func legacyInputs(_ descriptor: ActionEditorDescriptor) -> some View {
        if descriptor.showsBodyScope {
            let scopes = [BodyReplaceScope.all, .first].map {
                BuilderDropdown.Option(value: $0, title: L10n.string($0 == .all ? "rules.rewriteBody.scope.all" : "rules.rewriteBody.scope.first"))
            }
            BuilderDropdown(label: L10n.string("rules.rewriteBody.scope"), options: scopes, selection: $action.body.scope)
                .frame(width: RuleBuilderMetrics.fixedChoiceWidth(minimum: 190, titles: scopes.map(\.title)))
        }
        if descriptor.showsIncludeLocalResponses {
            Toggle(L10n.string("rules.rewriteStatus.includeLocal"), isOn: $action.status.includeLocalResponses)
                .accessibilityLabel(L10n.string("rules.rewriteStatus.includeLocal"))
        }
        if descriptor.showsURLPreserveCredentials {
            Toggle(L10n.string("rules.mapRemote.credentials"), isOn: $action.url.preserveCredentials)
                .accessibilityLabel(L10n.string("rules.mapRemote.credentials"))
        }
    }

    /// The magic string's help, and "use Return File" when its text is the path of a file that exists.
    @ViewBuilder private func magicStringExtras(_ descriptor: ActionEditorDescriptor) -> some View {
        RuleHelpText(text: L10n.string("rules.magicString.help"))
        if offersReturnFile {
            Button {
                let id = action.id
                converting = true
                Task { @MainActor in
                    await session.convertMagicStringToReturnFile(forAction: id)
                    converting = false
                }
            } label: {
                Label(L10n.string("rules.action.convertToReturnFile"), systemImage: "doc.badge.arrow.up")
            }
            .buttonStyle(OutlineButtonStyle(minHeight: 28))
            .disabled(converting || session.importState == .importing)
            .accessibilityLabel(L10n.string("rules.action.convertToReturnFile"))
        }
    }
}

// MARK: legacy forms

/// The map-remote card of a saved rule (the menu does not offer it to new cards; R8F2-8).
struct MapRemoteForm: View {
    @Binding var action: ActionDraft
    let issues: ActionIssues

    var body: some View {
        let remote = action.remote
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                BuilderDropdown(
                    label: L10n.string("rules.mapRemote.scheme"),
                    options: [RuleTargetScheme.http, .https].map { BuilderDropdown.Option(value: $0, title: $0.rawValue) },
                    selection: $action.remote.targetScheme
                )
                .frame(width: 100)
                ActionTextField(L10n.string("rules.mapRemote.host"), text: $action.remote.targetHost)
                ActionTextField(L10n.string("rules.mapRemote.port"), text: $action.remote.targetPort).frame(width: 80)
            }
            issues.lines([.targetScheme, .targetHost, .targetPort])
            HStack(spacing: 8) {
                let pathChoices = [
                    BuilderDropdown.Option(value: RemotePathChoice.preserve, title: L10n.string("rules.mapRemote.preserve")),
                    BuilderDropdown.Option(value: RemotePathChoice.replace, title: L10n.string("rules.mapRemote.replace")),
                ]
                BuilderDropdown(label: L10n.string("rules.mapRemote.path"), options: pathChoices, selection: $action.remote.pathChoice)
                    .frame(width: RuleBuilderMetrics.fixedChoiceWidth(minimum: 170, titles: pathChoices.map(\.title)))
                if remote.pathChoice == .replace {
                    ActionTextField(L10n.string("rules.mapRemote.replace"), text: $action.remote.replacementPath, mono: true)
                }
            }
            issues.line(.targetPath)
            if let preview = remote.preview {
                LabeledContent(L10n.string("rules.mapRemote.preview")) {
                    Text(remote.pathChoice == .preserve ? L10n.format("rules.mapRemote.previewPreserving", preview) : preview)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                }
            }
            Toggle(L10n.string("rules.mapRemote.credentials"), isOn: $action.remote.preserveCredentials)
                .accessibilityLabel(L10n.string("rules.mapRemote.credentials"))
            RuleHelpText(text: L10n.format("rules.mapRemote.credentialsHelp", remote.preview ?? remote.targetHost))
            RuleHelpText(text: L10n.string("rules.mapRemote.firstMapWins"))
        }
    }
}

/// A breakpoint card has no input; it says what an old rule's non-default pause still does, and when pausing is unavailable.
struct BreakpointNotes: View {
    let session: RuleEditorSession
    let descriptor: ActionEditorDescriptor

    var body: some View {
        if let key = descriptor.legacyNoteKey { RuleHelpText(text: L10n.string(key)) }
        if !session.liveBreakpoints {
            Label(L10n.string("rules.breakpoint.unavailable"), systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
