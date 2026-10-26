import AppCore
import AppKit
import FlowStore
import Localization
import RulesEngine
import SwiftUI

/// The name and value rows of the extra response headers of a returned file or directory.
private struct ResponseHeaderRows: View {
    @Binding var rows: [HeaderFieldRow]
    let issues: ActionIssues

    var body: some View {
        Text(L10n.string("rules.mapLocal.headers")).font(.subheadline)
        ForEach($rows) { $row in
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    ActionTextField(L10n.string("rules.headers.name"), text: $row.name, mono: true)
                    ActionTextField(L10n.string("rules.headers.value"), text: $row.value, mono: true)
                    ActionRowControls(rows: $rows, id: row.id)
                }
                issues.line(.headerRow(row.id))
            }
        }
        Button { rows.append(HeaderFieldRow(name: "", value: "")) } label: {
            Label(L10n.string("rules.mapLocal.addHeader"), systemImage: "plus")
        }
        .buttonStyle(OutlineButtonStyle(minHeight: 28))
        .accessibilityLabel(L10n.string("rules.mapLocal.addHeader"))
    }
}

/// Return a managed copy of a file: import it (button or drop), or pick one saved rules already use.
struct ReturnFileForm: View {
    let session: RuleEditorSession
    @Binding var action: ActionDraft
    let issues: ActionIssues

    @State private var importTask: Task<Void, Never>?
    @State private var showsMore = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content }
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first(where: \.isFileURL), session.importState != .importing else { return false }
                start(url)
                return true
            }
    }

    @ViewBuilder private var content: some View {
        HStack(spacing: 8) {
            if session.importState == .importing, importTask != nil {
                ProgressView().controlSize(.small).accessibilityLabel(L10n.string("rules.mapLocal.importing"))
                Text(L10n.string("rules.mapLocal.importing")).foregroundStyle(.secondary)
                Button(L10n.string("rules.mapLocal.cancelImport")) { importTask?.cancel() }
                    .buttonStyle(OutlineButtonStyle(minHeight: 28))
                    .accessibilityLabel(L10n.string("rules.mapLocal.cancelImport"))
            } else {
                Button(L10n.string("rules.action.browse"), action: chooseFile)
                    .buttonStyle(OutlineButtonStyle(minHeight: 28))
                    .disabled(session.importState == .importing)
                    .accessibilityLabel(L10n.string("rules.action.browse"))
                if let asset = action.file.asset {
                    Image(systemName: "doc").foregroundStyle(ShellStyle.color(.textSecondary)).accessibilityHidden(true)
                    Text(asset.displayName.isEmpty ? L10n.string("rules.mapLocal.unknownAsset") : asset.displayName)
                        .font(.system(size: 13))
                        .lineLimit(1).truncationMode(.middle)
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(ShellStyle.color(.success))
                        .accessibilityLabel(L10n.string("rules.mapLocal.fileReady"))
                        .help(L10n.string("rules.mapLocal.fileReady"))
                } else {
                    Text(L10n.string("rules.mapLocal.noFile")).font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        }
        issues.line(.file)
        if case .failed(let error) = session.importState {
            Text(error.message()).font(.caption).foregroundStyle(Palette.failureColor)
        }
        // Everything but the file itself stays editable, folded away so the card reads as the file alone; a problem in
        // it opens the section.
        DisclosureGroup(
            isExpanded: Binding(get: { showsMore || hasExtraIssue }, set: { showsMore = $0 }),
            content: { extras.padding(.top, 6) },
            label: { Text(L10n.string("rules.action.moreOptions")).font(.system(size: 13)) }
        )
        .accessibilityLabel(L10n.string("rules.action.moreOptions"))
    }

    private var hasExtraIssue: Bool {
        issues.issues[.status] != nil || issues.issues.keys.contains { if case .headerRow = $0 { true } else { false } }
    }

    @ViewBuilder private var extras: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let asset = action.file.asset, asset.importedAt != .distantPast {
                RuleHelpText(text: L10n.format("rules.mapLocal.assetDetails", Formatting.size(Int(asset.size)), Self.date(asset.importedAt)))
            }
            let reusable = session.reusableAssets
            if !reusable.isEmpty {
                Menu(L10n.string("rules.mapLocal.reuse")) {
                    ForEach(reusable) { asset in
                        Button(asset.displayName.isEmpty ? L10n.string("rules.mapLocal.unknownAsset") : asset.displayName) {
                            action.file.asset = asset
                        }
                    }
                }
                .fixedSize()
                .accessibilityLabel(L10n.string("rules.mapLocal.reuse"))
            }
            RuleHelpText(text: L10n.string("rules.mapLocal.copyHelp"))
            ActionTextField(L10n.string("rules.mapLocal.status"), text: $action.file.status).frame(maxWidth: 160)
            issues.line(.status)
            ResponseHeaderRows(rows: $action.file.headers, issues: issues)
        }
    }

    private func start(_ url: URL) {
        let id = action.id
        importTask?.cancel()
        importTask = Task { @MainActor in
            guard !Task.isCancelled else { return }
            await session.importFile(url, forAction: id)
            importTask = nil
        }
    }

    /// A non-modal panel; the copy runs inside the picked file's security scope.
    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in start(url) }
        }
    }

    private static func date(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = L10n.locale
        formatter.setLocalizedDateFormatFromTemplate("yyyyMMMd HHmm")
        return formatter.string(from: date)
    }
}

/// Serve a folder live: the folder (by name only), the path prefix, the missing-file policy and extra headers.
struct ReturnDirectoryForm: View {
    let session: RuleEditorSession
    @Binding var action: ActionDraft
    let issues: ActionIssues

    var body: some View {
        LabeledContent(L10n.string("rules.mapLocalDirectory.directory")) {
            if action.directory.bookmark != nil {
                Text(action.directory.displayName).lineLimit(1).truncationMode(.middle)
            } else {
                Text(L10n.string("rules.mapLocalDirectory.noDirectory")).foregroundStyle(.secondary)
            }
        }
        issues.line(.directory)
        HStack {
            Button(L10n.string("rules.mapLocalDirectory.choose"), action: chooseDirectory)
                .buttonStyle(OutlineButtonStyle(minHeight: 28))
                .disabled(session.importState == .importing)
                .accessibilityLabel(L10n.string("rules.mapLocalDirectory.choose"))
            if session.importState == .importing { ProgressView().controlSize(.small).accessibilityLabel(L10n.string("rules.mapLocal.importing")) }
        }
        if case .failed(let error) = session.importState {
            Text(error.message()).font(.caption).foregroundStyle(Palette.failureColor)
        }
        RuleHelpText(text: L10n.string("rules.mapLocalDirectory.liveHelp"))
        ActionTextField(L10n.string("rules.returnDirectory.prefix"), text: $action.directoryPrefix, mono: true)
        issues.line(.directoryPrefix)
        RuleHelpText(text: L10n.string("rules.mapLocalDirectory.prefixHelp"))
        Toggle(L10n.string("rules.mapLocalDirectory.servesIndex"), isOn: $action.directory.servesIndex)
            .accessibilityLabel(L10n.string("rules.mapLocalDirectory.servesIndex"))
        let missingChoices = [MissingFilePolicy.notFound, .network].map { BuilderDropdown.Option(value: $0, title: L10n.string($0.titleKey)) }
        BuilderDropdown(label: L10n.string("rules.mapLocalDirectory.missing"), options: missingChoices, selection: $action.directory.missing)
            .frame(width: RuleBuilderMetrics.fixedChoiceWidth(minimum: 220, titles: missingChoices.map(\.title)))
        ResponseHeaderRows(rows: $action.directory.headers, issues: issues)
    }

    /// A non-modal folder panel; the bookmark is made inside the folder's security scope.
    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = false
        let id = action.id
        let session = self.session
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in await session.chooseDirectory(url, forAction: id) }
        }
    }
}

/// A full HTTP response typed by hand, with a byte counter against the limit. A response that cannot be sent (a bad
/// status line) turns the editor's border red with the reason under it.
struct HandwrittenForm: View {
    let session: RuleEditorSession
    let index: Int
    @Binding var action: ActionDraft
    let issues: ActionIssues

    var body: some View {
        let limit = session.limits.handwrittenResponseBytes
        let bytes = HandwrittenCounter.bytes(action.handwrittenText)
        let isInvalid = issues.issues[.handwritten] != nil
        VStack(alignment: .leading, spacing: 6) {
            TextEditor(text: $action.handwrittenText)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .autocorrectionDisabled()
                .frame(minHeight: 120, maxHeight: 280)
                .padding(.horizontal, -3)
                .actionBox(minHeight: 120, vertical: 4, isInvalid: isInvalid)
                .accessibilityLabel(actionFieldLabel(index: index, "rules.handwritten.label"))
            Text(L10n.format("rules.handwritten.counter", bytes, limit))
                .font(.caption.monospacedDigit())
                .foregroundStyle(HandwrittenCounter.isOver(action.handwrittenText, limit: limit) ? Palette.failureColor : .secondary)
            issues.line(.handwritten)
        }
    }
}

/// One of the predefined responses, in a dropdown grouped by the first character of the name; a redirect has its
/// Location below. An old rule's preset not in the list is the last entry, marked old style.
struct PresetForm: View {
    let index: Int
    let descriptor: ActionEditorDescriptor
    @Binding var action: ActionDraft
    let issues: ActionIssues

    var body: some View {
        let groups = descriptor.presetGroups.map { group in
            group.map { BuilderMenuItem(id: $0.id, title: $0.title, isSelected: $0.preset == action.preset) }
        }
        VStack(alignment: .leading, spacing: 8) {
            BuilderMenuDropdown(
                label: actionFieldLabel(index: index, "rules.preset.label"),
                title: groups.joined().first(where: \.isSelected)?.title ?? L10n.string(action.preset.titleKey), groups: groups
            ) { id in
                if let preset = PresetResponse.Preset(rawValue: id) { action.preset = preset }
            }
            .frame(width: RuleBuilderMetrics.presetDropdownWidth(descriptor, current: L10n.string(action.preset.titleKey)))
            if descriptor.showsPresetLocation {
                HStack(spacing: 8) {
                    Text(L10n.string("rules.preset.location")).font(.system(size: 13))
                    ActionTextField(L10n.string("rules.preset.location"), text: $action.presetLocation, mono: true)
                }
                issues.line(.presetLocation)
            }
            if descriptor.showsPresetChallenge {
                ActionTextField(L10n.string("rules.preset.challenge"), text: $action.presetChallenge, mono: true)
                issues.line(.presetChallenge)
            }
            if descriptor.showsPresetBody {
                ActionTextField(L10n.string("rules.preset.body"), text: $action.presetBody, mono: true, multiline: true)
                issues.line(.presetBody)
            }
        }
    }
}
