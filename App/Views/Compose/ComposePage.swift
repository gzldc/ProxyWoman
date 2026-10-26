import AppCore
import Localization
import SwiftUI

/// The Compose page of the main window: parked drafts on the left, the open requests as tabs on
/// top and the selected one below. Every tab and draft lives on `AppModel.composeWorkspace`, so
/// switching tabs or pages, or closing the window, never loses a draft.
struct ComposePage: View {
    let appModel: AppModel
    let flowList: FlowListModel
    /// The question's text, kept while the alert fades out after `pendingClose` clears.
    @State private var closeText = ""

    var body: some View {
        let workspace = appModel.composeWorkspace
        HStack(spacing: 0) {
            ComposeDraftsColumn(workspace: workspace)
                .frame(width: ShellStyle.sourceBarWidth + 30)
                .background(ShellStyle.color(.sidebar))
            Divider()
            VStack(spacing: 0) {
                ComposeTabStrip(workspace: workspace)
                if let model = workspace.selected {
                    // The content is rebuilt per tab: its sub-tab and scroll position restart on a switch; the draft itself lives on the tab's model and is kept.
                    ComposeContent(model: model, appModel: appModel, flowList: flowList)
                        .id(model.id)
                } else {
                    ComposeEmptyState(workspace: workspace)
                }
            }
            .background(ShellStyle.color(.content))
        }
        .frame(minWidth: 820)
        .onDisappear { appModel.composeWorkspace.cancelPendingClose() }
        .onChange(of: closeMessage(workspace), initial: true) { _, text in
            if let text { closeText = text }
        }
        .alert(
            ComposeCloseAssessment.titleText,
            isPresented: Binding(get: { workspace.pendingClose != nil }, set: { _ in })
        ) {
            Button(L10n.string("compose.close.saveDraft")) { resolve(.saveDraft) }
            Button(L10n.string("compose.close.discard"), role: .destructive) { resolve(.discard) }
            Button(L10n.string("common.cancel"), role: .cancel) { resolve(.cancel) }
        } message: {
            Text(closeText)
        }
    }

    private func closeMessage(_ workspace: ComposeWorkspaceModel) -> String? {
        guard let id = workspace.pendingClose else { return nil }
        return workspace.tabs.first { $0.id == id }?.closeAssessment.messageText
    }

    private func resolve(_ choice: ComposeWorkspaceModel.CloseChoice) {
        let workspace = appModel.composeWorkspace
        Task { await workspace.resolveClose(choice) }
    }
}

// MARK: tabs

private struct ComposeTabStrip: View {
    let workspace: ComposeWorkspaceModel

    var body: some View {
        HStack(spacing: 0) {
            ForEach(workspace.tabs) { model in
                tab(model, selected: model.id == workspace.selectedID)
            }
            Button {
                workspace.newBlankTab()
            } label: {
                Image(systemName: "plus")
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(ShellStyle.color(.textSecondary))
            .help(L10n.string("compose.page.newTab"))
            .accessibilityLabel(L10n.string("compose.page.newTab"))
            Spacer(minLength: 0)
        }
        .background(ShellStyle.color(.toolbar))
        .overlay(alignment: .bottom) {
            Rectangle().fill(ShellStyle.color(.separator)).frame(height: 1)
        }
    }

    private func tab(_ model: ComposeViewModel, selected: Bool) -> some View {
        let title = ComposeWorkspaceModel.title(of: model)
        return HStack(spacing: 0) {
            Button {
                workspace.selectedID = model.id
            } label: {
                Text(title)
                    .lineLimit(1)
                    .frame(maxWidth: 220, alignment: .leading)
                    .padding(.leading, 10)
                    .padding(.trailing, 4)
                    .frame(height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityAddTraits(selected ? .isSelected : [])
            Button {
                Task { await workspace.requestClose(model.id) }
            } label: {
                Image(systemName: "xmark").imageScale(.small)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 8)
            .help(L10n.string("compose.page.closeTab"))
            .accessibilityLabel(L10n.string("compose.page.closeTab"))
        }
        .font(.system(size: 12, weight: selected ? .medium : .regular))
        .foregroundStyle(selected ? ShellStyle.color(.textPrimary) : ShellStyle.color(.textSecondary))
        .background(selected ? ShellStyle.color(.content) : Color.clear)
        .overlay(alignment: .bottom) {
            if selected {
                Rectangle().fill(ShellStyle.color(.accent)).frame(height: ShellStyle.tabUnderline)
            }
        }
    }
}

private struct ComposeEmptyState: View {
    let workspace: ComposeWorkspaceModel

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "paperplane")
                .font(.system(size: 28))
                .foregroundStyle(ShellStyle.color(.textSecondary))
                .accessibilityHidden(true)
            Text(L10n.string("compose.page.empty"))
                .foregroundStyle(ShellStyle.color(.textSecondary))
            Button(L10n.string("compose.page.newTab")) { workspace.newBlankTab() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: drafts

private struct ComposeDraftsColumn: View {
    let workspace: ComposeWorkspaceModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L10n.string("compose.page.drafts"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(ShellStyle.color(.textSecondary))
                .padding(.horizontal, 10)
                .frame(height: 30)
            if workspace.parked.isEmpty {
                Text(L10n.string("compose.page.drafts.empty"))
                    .font(.caption)
                    .foregroundStyle(ShellStyle.color(.textSecondary))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(workspace.parked) { entry in row(entry) }
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func row(_ entry: ComposeWorkspaceModel.Parked) -> some View {
        let title = ComposeWorkspaceModel.title(of: entry.model)
        return HStack(spacing: 4) {
            Button {
                workspace.reopen(entry.id)
            } label: {
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: ShellStyle.rowHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            Button {
                Task { await workspace.discardParked(entry.id) }
            } label: {
                Image(systemName: "trash").imageScale(.small)
                    .frame(width: ShellStyle.iconButtonSide, height: ShellStyle.iconButtonSide)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(ShellStyle.color(.textSecondary))
            .help(L10n.string("compose.page.deleteDraft"))
            .accessibilityLabel(L10n.string("compose.page.deleteDraft"))
        }
        .font(.system(size: 12))
        .padding(.leading, 10)
        .padding(.trailing, 4)
    }
}
