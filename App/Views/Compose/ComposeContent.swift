import AppCore
import AppKit
import FlowStore
import Localization
import SwiftUI
import UniformTypeIdentifiers
import Viewers

struct ComposeContent: View {
    @Bindable var model: ComposeViewModel
    let appModel: AppModel
    let flowList: FlowListModel
    @State private var tab = ComposeTab.query

    var body: some View {
        VSplitView {
            VStack(spacing: 0) {
                ComposeRequestBar(model: model)
                if let notice = model.notice {
                    Label(notice, systemImage: "info.circle.fill")
                        .foregroundStyle(Palette.pendingColor)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 4)
                }
                // Every problem is listed here, whichever tab is open, so a disabled Send always says why.
                ComposeIssueList(issues: model.shownIssues)
                Picker(L10n.string("compose.sections.accessibility"), selection: $tab) {
                    ForEach(ComposeTab.allCases) { Text(L10n.string($0.localizationKey)).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                Divider()
                Group {
                    switch tab {
                    case .query: ComposeQueryEditor(model: model)
                    case .headers: ComposeHeaderEditor(model: model)
                    case .body: ComposeBodyEditor(model: model)
                    case .options: ComposeOptionsEditor(model: model)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(minHeight: 260)
            ComposeResponsePane(model: model, appModel: appModel, flowList: flowList)
                .frame(minHeight: 200)
        }
    }
}

private enum ComposeTab: String, CaseIterable, Identifiable {
    case query, headers, body, options
    var id: Self { self }
    var localizationKey: String {
        switch self {
        case .query: "compose.tab.query"
        case .headers: "compose.tab.headers"
        case .body: "compose.tab.body"
        case .options: "compose.tab.options"
        }
    }
}

// MARK: request bar

private struct ComposeRequestBar: View {
    @Bindable var model: ComposeViewModel
    private static let methods = ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"]

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 0) {
                TextField(L10n.string("compose.method"), text: $model.draft.method)
                    .labelsHidden()
                    .font(.body.monospaced())
                    .frame(width: 92)
                Menu {
                    ForEach(Self.methods, id: \.self) { method in
                        Button(method) { model.draft.method = method }
                    }
                } label: {
                    Image(systemName: "chevron.down")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help(L10n.string("compose.method.menu"))
                .accessibilityLabel(L10n.string("compose.method.menu"))
            }
            TextField(
                L10n.string("compose.url"),
                text: Binding(get: { model.draft.url }, set: { model.setURL($0) }),
                prompt: Text(L10n.string("compose.url.placeholder"))
            )
            .labelsHidden()
            .font(.body.monospaced())
            if model.isSending {
                ProgressView().controlSize(.small)
                Button(L10n.string("compose.cancel"), role: .cancel) { model.cancel() }
                    .keyboardShortcut(.cancelAction)
            } else {
                Button(L10n.string("compose.send")) { Task { await model.send() } }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.isSendEnabled)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 6)
    }
}

/// Errors in red, warnings in orange; each a full localized sentence.
private struct ComposeIssueList: View {
    let issues: [ComposeDraftIssue]

    var body: some View {
        if !issues.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(issues.enumerated()), id: \.offset) { _, issue in
                    Label(issue.localizedDescription,
                          systemImage: issue.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(issue.severity == .error ? Palette.failureColor : Palette.pendingColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.bottom, 4)
        }
    }
}

private struct ComposeHelpText: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: query

private struct ComposeQueryEditor: View {
    @Bindable var model: ComposeViewModel

    var body: some View {
        Form {
            Section {
                if model.draft.query.rows.isEmpty {
                    ComposeHelpText(text: L10n.string("compose.query.empty"))
                }
                ForEach(model.draft.query.rows) { row in
                    HStack(spacing: 6) {
                        TextField(L10n.string("compose.query.name"), text: Binding(
                            get: { model.draft.query.rows.first { $0.id == row.id }?.name ?? "" },
                            set: { name in
                                // Only a real change re-encodes, and only this name (its value keeps its bytes).
                                guard name != model.draft.query.rows.first(where: { $0.id == row.id })?.name else { return }
                                model.draft.setQueryName(row.id, name)
                            }))
                            .labelsHidden()
                            .frame(maxWidth: 220)
                        TextField(L10n.string("compose.query.value"), text: Binding(
                            get: { model.draft.query.rows.first { $0.id == row.id }?.value ?? "" },
                            set: { text in
                                let current = model.draft.query.rows.first { $0.id == row.id }?.value
                                // A segment without "=" stays so until something is typed.
                                let value: String? = current == nil && text.isEmpty ? nil : text
                                guard value != current else { return }
                                model.draft.setQueryValue(row.id, value)
                            }),
                            prompt: row.value == nil ? Text(L10n.string("compose.query.noEquals")) : nil)
                            .labelsHidden()
                        Button(L10n.string("compose.query.remove"), systemImage: "minus.circle") {
                            model.draft.removeQueryRow(row.id)
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                    }
                    .font(.body.monospaced())
                }
                Button(L10n.string("compose.query.add"), systemImage: "plus") {
                    model.draft.appendQueryRow(name: "", value: "")
                }
            } footer: {
                ComposeHelpText(text: L10n.string("compose.query.help"))
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: headers

private struct ComposeHeaderEditor: View {
    @Bindable var model: ComposeViewModel

    var body: some View {
        // Validated once per update, not once per row.
        let issues = model.issues
        Form {
            Section {
                if model.draft.headers.isEmpty {
                    ComposeHelpText(text: L10n.string("compose.headers.empty"))
                }
                ForEach($model.draft.headers) { $row in
                    HStack(spacing: 6) {
                        TextField(L10n.string("compose.headers.name"), text: $row.name)
                            .labelsHidden()
                            .frame(maxWidth: 220)
                        TextField(L10n.string("compose.headers.value"), text: $row.value)
                            .labelsHidden()
                        Button(L10n.string("compose.headers.remove"), systemImage: "minus.circle") {
                            model.draft.headers.removeAll { $0.id == row.id }
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                    }
                    .font(.body.monospaced())
                    ComposeIssueList(issues: issues.filter { $0.field == .header(row.id) })
                }
                Button(L10n.string("compose.headers.add"), systemImage: "plus") {
                    model.draft.headers.append(HeaderFieldRow(name: "", value: ""))
                }
            } footer: {
                ComposeHelpText(text: L10n.string("compose.headers.framingHelp"))
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: body

private struct ComposeBodyEditor: View {
    @Bindable var model: ComposeViewModel
    @State private var isChoosingFile = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker(L10n.string("compose.body.mode"), selection: Binding<ComposeBodyMode?>(
                get: { model.draft.body.mode },
                set: { mode in
                    guard let mode else { return }
                    // A file body only comes from a chosen file: picking the mode opens the chooser.
                    if mode == .file {
                        if model.draft.body.mode != .file { isChoosingFile = true }
                    } else {
                        model.draft.switchBody(to: mode)
                    }
                }
            )) {
                ForEach(ComposeBodyMode.allCases) { mode in
                    Text(L10n.string(mode.localizationKey)).tag(Optional(mode))
                        .selectionDisabled(mode != .file && !model.draft.canSwitchBody(to: mode))
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            if let reason = model.draft.body.omissionReason {
                Label(L10n.format("compose.body.omitted", reason), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Palette.pendingColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = model.fileError {
                Label(error, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(Palette.failureColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            switch model.draft.body {
            case .text:
                TextEditor(text: Binding(
                    get: { if case .text(let text) = model.draft.body { text } else { "" } },
                    set: { model.draft.body = .text($0) }))
                    .font(.body.monospaced())
            case .hex:
                TextEditor(text: Binding(
                    get: { if case .hex(let text) = model.draft.body { text } else { "" } },
                    set: { model.draft.body = .hex($0) }))
                    .font(.body.monospaced())
                ComposeHelpText(text: L10n.string("compose.body.hexHelp"))
                if !model.draft.canSwitchBody(to: .text) {
                    ComposeHelpText(text: L10n.string("compose.body.textUnavailable"))
                }
            case .file(let file):
                HStack(spacing: 8) {
                    Image(systemName: "doc")
                    Text(file.summary).font(.body.monospaced()).textSelection(.enabled)
                    Spacer()
                    if model.isImportingFile { ProgressView().controlSize(.small) }
                    Button(L10n.string("compose.body.file.replace")) { isChoosingFile = true }
                        .disabled(model.isImportingFile)
                    Button(L10n.string("compose.body.file.remove"), role: .destructive) {
                        Task { await model.removeFile() }
                    }
                }
                ComposeHelpText(text: L10n.string("compose.body.file.hint"))
                Spacer()
            case .pending:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(model.importProgressText ?? "").font(.body.monospaced())
                    Spacer()
                    Button(L10n.string("compose.body.importCancel")) { model.cancelImport() }
                }
                Spacer()
            case .none, .omitted:
                Button(L10n.string("compose.body.file.choose")) { isChoosingFile = true }
                    .disabled(model.isImportingFile)
                ComposeHelpText(text: L10n.string("compose.body.file.hint"))
                Spacer()
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .fileImporter(isPresented: $isChoosingFile, allowedContentTypes: [.data], allowsMultipleSelection: false) { result in
            // The security scope is held by the model for the whole copy.
            guard case .success(let urls) = result, let url = urls.first else { return }
            Task { await model.attachFile(url) }
        }
    }
}

// MARK: options

private struct ComposeOptionsEditor: View {
    @Bindable var model: ComposeViewModel

    var body: some View {
        Form {
            Section {
                Toggle(L10n.string("compose.options.applyRules"), isOn: $model.draft.policy.applyRules)
                ComposeHelpText(text: L10n.string("compose.options.applyRules.help"))
            }
            Section {
                TextField(L10n.string("compose.options.timeout"), value: $model.draft.policy.timeoutSeconds, format: .number)
                    .frame(maxWidth: 260)
                ComposeHelpText(text: L10n.string("compose.options.timeout.help"))
                Picker(L10n.string("compose.options.httpVersion"), selection: $model.draft.policy.http1Only) {
                    Text(L10n.string("compose.options.httpVersion.automatic")).tag(false)
                    Text(L10n.string("compose.options.httpVersion.http1")).tag(true)
                }
            }
            Section {
                ComposeHelpText(text: L10n.string("compose.options.notice"))
            }
        }
        .formStyle(.grouped)
    }
}
