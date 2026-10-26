import AppCore
import FlowStore
import Localization
import RulesEngine
import SwiftUI
import Viewers

/// Time left from the ticket's absolute deadline; redrawn each second, no timer of its own.
struct BreakpointCountdownText: View {
    let deadline: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let seconds = BreakpointCountdown.remainingSeconds(until: deadline, now: context.date)
            Text(L10n.format("breakpoints.list.remaining", seconds))
                .monospacedDigit()
                .font(.callout)
                .foregroundStyle(BreakpointCountdown.isWarning(remainingSeconds: seconds) ? Palette.failureColor : Palette.neutralColor)
        }
    }
}

struct BreakpointEditorPane: View {
    let queue: BreakpointQueueModel
    @Bindable var editor: BreakpointEditorModel
    let flowList: FlowListModel
    let rules: RulesEditorModel
    // Continue, Abort and collecting the body live in `BreakpointInspector`'s header (Ruling R8-1).

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    if editor.ticket.direction == .request {
                        BreakpointFieldRow(
                            title: L10n.string("breakpoints.editor.method"), text: $editor.method, isEditable: editor.canEditTarget)
                        FieldIssue(editor: editor, field: .method)
                        BreakpointFieldRow(
                            title: L10n.string("breakpoints.editor.url"), text: $editor.url, monospaced: true,
                            isEditable: editor.canEditTarget)
                        FieldIssue(editor: editor, field: .url)
                        if editor.ticket.isLocalRoute {
                            HelpText(text: L10n.string("breakpoints.editor.localRoute"))
                        }
                    } else {
                        if let url = BreakpointPresentation.url(of: editor.ticket, flowList: flowList) {
                            LabeledContent(L10n.string("breakpoints.editor.url")) {
                                Text(verbatim: url).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                            }
                        }
                        BreakpointFieldRow(title: L10n.string("breakpoints.editor.status"), text: $editor.status)
                        FieldIssue(editor: editor, field: .status)
                        BreakpointFieldRow(title: L10n.string("breakpoints.editor.reason"), text: $editor.reason)
                        FieldIssue(editor: editor, field: .reason)
                    }
                    if editor.ticket.flowID == nil {
                        HelpText(text: L10n.string("breakpoints.editor.unrecorded"))
                    }
                    HelpText(text: matchedRules)
                } header: {
                    Text(L10n.string(editor.ticket.direction == .request ? "breakpoints.list.request" : "breakpoints.list.response"))
                }
                Section(L10n.string("breakpoints.editor.headers")) {
                    ForEach($editor.headers) { $row in
                        let id = row.id
                        BreakpointHeaderEditRow(row: $row) { editor.headers.removeAll { $0.id == id } }
                        FieldIssue(editor: editor, field: .header(id))
                    }
                    Button(L10n.string("breakpoints.editor.addHeader"), systemImage: "plus") {
                        editor.headers.append(HeaderFieldRow(name: "", value: ""))
                    }
                    FieldIssue(editor: editor, field: .headers)
                }
                Section(L10n.string("breakpoints.editor.body")) {
                    BreakpointBodySection(queue: queue, editor: editor)
                }
            }
            .formStyle(.grouped)
            .disabled(queue.isPerforming)
            Divider()
            HStack(spacing: 10) {
                FieldIssue(editor: editor, field: .message)
                Spacer()
                if queue.isPerforming { ProgressView().controlSize(.small) }
                Button(L10n.string("breakpoints.action.revert")) { editor.revert() }
                    .disabled(!editor.isDirty || queue.isPerforming)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    private var matchedRules: String {
        let names = editor.ticket.matchedRuleIDs.compactMap { id in rules.rules.first { $0.id == id }.map { RulePresentation.displayName($0.name) } }
        guard !names.isEmpty else { return L10n.format("breakpoints.editor.matchedRuleCount", editor.ticket.matchedRuleCount) }
        return L10n.format("breakpoints.editor.matchedRules", names.joined(separator: L10n.string("breakpoints.editor.nameSeparator")))
    }
}

struct BreakpointBodySection: View {
    let queue: BreakpointQueueModel
    @Bindable var editor: BreakpointEditorModel

    var body: some View {
        if editor.isEncoded {
            Picker(L10n.string("breakpoints.body.boundary"), selection: $editor.boundary) {
                ForEach(HTTPBoundarySelection.allCases) { Text(L10n.string($0.localizationKey)).tag($0) }
            }
            .pickerStyle(.segmented)
            if editor.canEditBody { HelpText(text: L10n.string("breakpoints.body.decodedNotice")) }
        }
        let content = editor.displayedBody
        switch content {
        case .text:
            if editor.canEditBody {
                TextEditor(text: $editor.bodyText)
                    .font(.body.monospaced())
                    .frame(minHeight: 160)
            }
        case .readOnlyText(let truncated):
            RawTextView(text: editor.bodyText, isTruncated: truncated)
                .frame(minHeight: 160)
        case .hex(let data, _):
            HexBody(data: data).frame(minHeight: 160)
        default:
            EmptyView()
        }
        if editor.replacementFile == nil, let message = message(for: content) {
            HelpText(text: message)
        }
        if editor.hasHiddenDecodedEdit {
            HelpText(text: L10n.string("breakpoints.body.hiddenDecodedEdit"))
        }
        if let file = editor.replacementFile {
            HelpText(text: L10n.format("breakpoints.body.replacementFile", file.fileName, Formatting.size(Int(clamping: file.size))))
        }
        if editor.isImportingFile {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                HelpText(text: L10n.string("breakpoints.body.importing"))
            }
        }
        if editor.canReplaceBodyFromFile {
            Button(L10n.string("breakpoints.action.replaceFromFile")) { chooseFile() }
                .disabled(queue.isPerforming || editor.isImportingFile)
        }
        FieldIssue(editor: editor, field: .body)
    }

    /// A non-modal panel; the proxy copies the picked file inside its security scope.
    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = false
        let editor = self.editor
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in await editor.replaceBody(from: url) }
        }
    }

    private func message(for content: BreakpointBodyContent) -> String? {
        guard let key = content.messageKey else { return nil }
        let limits = editor.limits
        switch content {
        case .tooLargeToCollect:
            return L10n.format(key, Formatting.size(limits.breakpointBodyBytes))
        case .readOnlyText:
            return L10n.format(key, Formatting.size(Int(clamping: editor.ticket.bodyLength ?? 0)), Formatting.size(limits.editorBodyBytes))
        case .budgetExhausted:
            return L10n.format(key, Formatting.size(limits.editorMemoryBytes))
        default:
            return L10n.string(key)
        }
    }
}

/// The hex dump, formatted off the main actor.
struct HexBody: View {
    let data: Data
    @State private var dump: String?

    var body: some View {
        Group {
            if let dump {
                RawTextView(text: dump, wrapsLines: false)
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .task(id: data.count) {
            let data = self.data
            let text = await Task.detached(priority: .userInitiated) { HexDump.format(data) }.value
            if !Task.isCancelled { dump = text }
        }
    }
}

struct FieldIssue: View {
    let editor: BreakpointEditorModel
    let field: BreakpointEditorField

    var body: some View {
        if let issue = editor.fieldErrors[field] {
            Text(L10n.string(issue.localizationKey))
                .font(.caption)
                .foregroundStyle(Palette.failureColor)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct HelpText: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The paused ticket of the selected flow inside the request details tab: a header (state,
/// time left, Abort, Continue, collect body) above the editor. Drafts live on the queue's editors.
struct BreakpointInspector: View {
    let queue: BreakpointQueueModel
    @Bindable var editor: BreakpointEditorModel
    let flowList: FlowListModel
    let rules: RulesEditorModel

    var body: some View {
        VStack(spacing: 0) {
            if let notice = queue.notice {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Palette.pendingColor)
                    Text(L10n.string(notice.localizationKey)).frame(maxWidth: .infinity, alignment: .leading)
                    Button(L10n.string("breakpoints.notice.dismiss")) { queue.dismissNotice() }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Palette.pendingColor.opacity(0.12))
                Divider()
            }
            header
            Divider()
            BreakpointEditorPane(queue: queue, editor: editor, flowList: flowList, rules: rules)
        }
    }

    private var header: some View {
        let isRequest = editor.ticket.direction == .request
        // The commands act on the queue's selection: only offer them while it is the ticket shown.
        let isActive = queue.selectedID == editor.id
        return HStack(spacing: 10) {
            Image(systemName: "pause.circle.fill").foregroundStyle(Palette.pendingColor).accessibilityHidden(true)
            Text(L10n.string(isRequest ? "breakpoints.inspector.paused.request" : "breakpoints.inspector.paused.response"))
                .fontWeight(.semibold)
            BreakpointCountdownText(deadline: editor.ticket.deadline)
            Spacer()
            if queue.isPerforming { ProgressView().controlSize(.small) }
            if editor.canCollectBody {
                Button(L10n.string("breakpoints.action.collectBody")) { Task { await queue.collectBodySelected() } }
                    .disabled(queue.isPerforming || !isActive)
            }
            Button(L10n.string("breakpoints.action.abort"), role: .destructive) { Task { await queue.cancelSelected() } }
                .disabled(queue.isPerforming || !isActive)
            Button(L10n.string("breakpoints.action.continue")) { Task { await queue.continueSelected() } }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(queue.isPerforming || editor.isImportingFile || !isActive)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
