import AppCore
import Localization
import RulesEngine
import SwiftUI

/// The rules tab of the main window's right-hand area (R8): a toolbar over a list of rule cards. A rule opens in the
/// rule editor window (double-click, Return, "Add Rule"). Every change goes through the shared `RulesEditorModel`;
/// nothing here touches files. Selection, the delete confirmation and the note being edited live on
/// `appModel.rulesTab`, so switching tabs and coming back loses none of them.
struct RulesTab: View {
    let appModel: AppModel
    let flowList: FlowListModel
    /// Shows the rule editor window (the session already holds the document).
    let openEditor: () -> Void
    @State private var outlineCache = RuleOutlineCache()
    @State private var exportReport: RulesExportReport?
    /// A file panel is open: Import / Export wait for it.
    @State private var panelOpen = false
    /// How many sessions "Undo last run" just restored; shown once.
    @State private var undone: Int?

    private var model: RulesEditorModel { appModel.rulesEditor }
    private var state: RulesTabState { appModel.rulesTab }

    var body: some View {
        let tree = model.tree
        let selection = state.selection
        let saved = RuleOutlineCommands.knownSelection(Array(selection), tree: tree)
        // Rebuilt only when the tree or the open groups change, not on every hit-count refresh.
        let outline = outlineCache.outline(
            for: RuleOutlineCache.Key(
                revision: model.revision, expanded: Set(tree.groups.map(\.id)), onlyEnabled: state.filter.onlyEnabled, query: state.filter.query)
        ) {
            RuleOutline(
                tree: tree, expanded: Set(tree.groups.map(\.id)), onlyEnabled: state.filter.onlyEnabled, query: state.filter.query
            ) {
                RulePresentation.searchFields(of: $0, assetName: assetName)
            }
        }
        VStack(spacing: 0) {
            if !appModel.rulesSwitch.isOn { RulesPausedBanner(rulesSwitch: appModel.rulesSwitch) }
            // The one-time upgrade notice, or the button that shows it again once it was read.
            UpgradeNoticeBlock(model: model) { state.selection = [$0] }
            RulesBanners(model: model)
            toolbar(saved: saved)
            searchRow
            Divider()
            RulesOutlineView(
                model: model, outline: outline, hits: appModel.ruleHits, health: appModel.patternHealth, state: state,
                selection: selection, renaming: state.renaming,
                onOpen: { id in
                    appModel.ruleEditorSession.openRule(id)
                    openEditor()
                },
                onDelete: { state.pendingDeletion = $0 }, onNewRule: { newRule(in: selectionParent) },
                onNewRuleIn: newRule(in:), onNewGroupIn: newGroup(in:), onEditNote: { state.noteEditing = $0 },
                onRun: { runRules([$0]) }, runBusy: runBusy, hitCounts: appModel.ruleHits.counts, assetName: assetName
            )
            .overlay { emptyState(filteredOut: outline.rows.isEmpty) }
        }
        .background(ShellStyle.color(.sidebar))
        // Edit ▸ Delete Rule acts on this tab's selection (with the same confirmation).
        .focusedSceneValue(
            \.rulesWindowCommands,
            RulesWindowCommandTarget(
                canDeleteSelection: !saved.isEmpty && model.canMutate,
                deleteSelection: { state.pendingDeletion = saved })
        )
        .task { await model.load() }
        .task { await refreshHits() }
        // A group removed, moved or switched, or a rule changed by another writer: the open document follows, and
        // what the tab remembers about vanished items goes.
        .onChange(of: model.revision) { _, _ in
            appModel.ruleEditorSession.reconcile()
            state.prune(to: model.tree)
        }
        .sheet(isPresented: Binding(get: { appModel.rulePackImporter.phase != .idle }, set: { if !$0 { closeImport() } })) {
            RulesImportSheet(importer: appModel.rulePackImporter) { state.selection = [$0] }
        }
        .sheet(item: $exportReport) { report in RulesExportReportSheet(report: report) { exportReport = nil } }
        .sheet(item: noteTarget) { target in
            RuleNoteSheet(
                ruleName: target.name, initialNote: target.note,
                save: { text in
                    state.noteEditing = nil
                    Task { await model.setNote(ruleID: target.id, note: text) }
                },
                cancel: { state.noteEditing = nil })
        }
        .alert(
            state.pendingDeletion.flatMap { RuleOutlinePresentation.deleteQuestion(for: $0, tree: tree) } ?? "",
            isPresented: Binding(get: { state.pendingDeletion != nil }, set: { if !$0 { state.pendingDeletion = nil } }),
            presenting: state.pendingDeletion
        ) { ids in
            Button(L10n.string("rules.delete.confirm"), role: .destructive) { delete(ids) }
            Button(L10n.string("common.cancel"), role: .cancel) {}
        } message: { _ in
            Text(L10n.string("rules.delete.message"))
        }
        .alert(
            undone.map { L10n.format("rules.execute.undone", $0) } ?? "",
            isPresented: Binding(get: { undone != nil }, set: { if !$0 { undone = nil } })
        ) {
            Button(L10n.string("rules.execute.close"), role: .cancel) {}
        }
    }

    // MARK: toolbar

    private func toolbar(saved: [UUID]) -> some View {
        // Narrow panes first drop the icons in front of the two text buttons, then fold the icon buttons into the ⋮
        // menu, so the row never wraps or clips.
        ViewThatFits(in: .horizontal) {
            toolbarRow(saved: saved, withLabelIcons: true, folded: false)
            toolbarRow(saved: saved, withLabelIcons: false, folded: false)
            toolbarRow(saved: saved, withLabelIcons: false, folded: true)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(ShellStyle.color(.toolbar))
    }

    private func toolbarRow(saved: [UUID], withLabelIcons: Bool, folded: Bool) -> some View {
        let busy = runBusy
        return HStack(spacing: 6) {
            Button { newRule(in: selectionParent) } label: {
                HStack(spacing: 4) {
                    if withLabelIcons { Image(systemName: "plus").imageScale(.small) }
                    Text(L10n.string("rules.tab.addRule")).lineLimit(1)
                }
                .fixedSize()
            }
            .buttonStyle(OutlineButtonStyle(minHeight: 28))
            .disabled(!model.canMutate)
            .help(L10n.string("rules.tab.addRule"))

            Button { newGroup(in: selectionParent) } label: {
                HStack(spacing: 4) {
                    if withLabelIcons { Image(systemName: "folder").imageScale(.small) }
                    Text(L10n.string("rules.tab.addGroup")).lineLimit(1)
                }
                .fixedSize()
            }
            .buttonStyle(OutlineButtonStyle(minHeight: 28))
            .disabled(!model.canMutate)
            .help(L10n.string("rules.tab.addGroup"))

            Spacer(minLength: 4)

            if !folded {
                Button { runRules(Set(saved)) } label: { Image(systemName: "play").foregroundStyle(ShellStyle.color(.accent)) }
                    .buttonStyle(IconSquareButtonStyle(side: 28))
                    .disabled(model.loadState != .loaded || model.rules.isEmpty || busy)
                    .help(L10n.string(saved.isEmpty ? "rules.tab.runAll" : "rules.tab.runSelected"))
                    .accessibilityLabel(L10n.string(saved.isEmpty ? "rules.tab.runAll" : "rules.tab.runSelected"))
                Button(action: importRules) { Image(systemName: "square.and.arrow.down") }
                    .buttonStyle(IconSquareButtonStyle(side: 28))
                    .disabled(!model.canMutate || panelOpen)
                    .help(L10n.string("rules.tab.import"))
                    .accessibilityLabel(L10n.string("rules.tab.import"))
                Menu {
                    Button(L10n.string("rules.export.selected")) { exportRules(Set(saved)) }
                        .disabled(saved.isEmpty)
                    Button(L10n.string("rules.export.all")) { exportRules(nil) }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .menuStyle(.button)
                .buttonStyle(IconSquareButtonStyle(side: 28))
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(model.rules.isEmpty || panelOpen)
                .help(L10n.string("rules.tab.export"))
                .accessibilityLabel(L10n.string("rules.tab.export"))
                Button { state.pendingDeletion = saved } label: { Image(systemName: "trash") }
                    .buttonStyle(IconSquareButtonStyle(side: 28))
                    .disabled(saved.isEmpty || !model.canMutate)
                    .help(L10n.string("rules.tab.deleteSelected"))
                    .accessibilityLabel(L10n.string("rules.tab.deleteSelected"))
            }
            Menu {
                if folded {
                    Button(L10n.string(saved.isEmpty ? "rules.tab.runAll" : "rules.tab.runSelected")) { runRules(Set(saved)) }
                        .disabled(model.loadState != .loaded || model.rules.isEmpty || busy)
                    Button(L10n.string("rules.tab.import"), action: importRules)
                        .disabled(!model.canMutate || panelOpen)
                    Button(L10n.string("rules.export.selected")) { exportRules(Set(saved)) }
                        .disabled(saved.isEmpty || model.rules.isEmpty || panelOpen)
                    Button(L10n.string("rules.export.all")) { exportRules(nil) }
                        .disabled(model.rules.isEmpty || panelOpen)
                    Button(L10n.string("rules.tab.deleteSelected")) { state.pendingDeletion = saved }
                        .disabled(saved.isEmpty || !model.canMutate)
                    Divider()
                }
                Toggle(L10n.string("toolWindow.bar.onlyEnabled"), isOn: Binding(get: { state.filter.onlyEnabled }, set: { state.filter.onlyEnabled = $0 }))
                Divider()
                Button(L10n.string("rules.outline.clearHits")) { appModel.ruleHits.clearAll(ids: model.rules.map(\.id)) }
                    .disabled(model.rules.isEmpty)
                Button(L10n.string("rules.outline.showUpgradeNotes")) { model.reopenUpgradeNotice() }
                    .disabled(!model.hasUpgradeNotice || model.showsUpgradeNotice)
                Button(L10n.string("rules.execute.undoLast")) { undone = appModel.executeRunner.undoLastRun() }
                    .disabled(!appModel.executeRunner.canUndoLastRun)
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.button)
            .buttonStyle(IconSquareButtonStyle(side: 28))
            .menuIndicator(.hidden)
            .fixedSize()
            .help(L10n.string("rules.row.more"))
            .accessibilityLabel(L10n.string("rules.row.more"))
        }
    }

    /// The search field; with a query or "only enabled" on, the list is filtered and dragging is off.
    private var searchRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(ShellStyle.color(.textSecondary)).accessibilityHidden(true)
            TextField(
                L10n.string("toolWindow.bar.filterPrompt"),
                text: Binding(get: { state.filter.query }, set: { state.filter.query = $0 })
            )
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .accessibilityLabel(L10n.string("toolWindow.bar.filter"))
            if state.filter.isActive {
                Button {
                    state.filter = ToolListFilter()
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(ShellStyle.color(.textSecondary))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.string("common.close"))
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(ShellStyle.color(.content))
        .overlay(alignment: .top) { Rectangle().fill(ShellStyle.color(.separator)).frame(height: 1) }
    }

    // MARK: pieces

    private var runBusy: Bool {
        if case .running = appModel.executeRunner.phase { true } else { false }
    }

    private var selectionParent: UUID? {
        RuleOutlineCommands.newItemParent(selection: Array(state.selection), tree: model.tree)
    }

    private func assetName(_ id: UUID) -> String? { model.knownAssets[id]?.displayName }

    /// The note sheet's target, while a saved rule is being edited.
    private var noteTarget: Binding<NoteTarget?> {
        Binding(
            get: {
                guard let id = state.noteEditing, let rule = model.rules.first(where: { $0.id == id }) else { return nil }
                return NoteTarget(id: id, name: RulePresentation.displayName(rule.name), note: rule.note ?? "")
            },
            set: { if $0 == nil { state.noteEditing = nil } })
    }

    private struct NoteTarget: Identifiable, Equatable {
        let id: UUID
        let name: String
        let note: String
    }

    @ViewBuilder private func emptyState(filteredOut: Bool) -> some View {
        if model.loadState == .loading {
            ProgressView(L10n.string("rules.loading"))
        } else if model.loadState == .loaded, model.rules.isEmpty, model.groups.isEmpty {
            VStack(spacing: 10) {
                Text(L10n.string("rules.tab.empty"))
                    .font(.callout)
                    .foregroundStyle(ShellStyle.color(.textSecondary))
                    .multilineTextAlignment(.center)
                Button(L10n.string("rules.tab.addRule")) { newRule(in: nil) }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!model.canMutate)
            }
            .padding(24)
        } else if model.loadState == .loaded, filteredOut {
            ToolEmptyState(message: L10n.string("toolWindow.noMatches"), showsNewHint: false)
        }
    }

    // MARK: actions

    /// Hit counts are read twice a second for as long as the tab shows this view.
    private func refreshHits() async {
        while !Task.isCancelled {
            appModel.ruleHits.refresh(ids: model.rules.map(\.id))
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    /// A new rule goes at the top of the given group, enabled.
    private func newRule(in parent: UUID?) {
        appModel.ruleEditorSession.openNew(inGroup: parent)
        openEditor()
    }

    private func newGroup(in parent: UUID?) {
        Task {
            if let id = await model.addGroup(name: L10n.string("rules.outline.newGroupName"), inParent: parent) {
                state.selection = [id]
                state.renaming = id
            }
        }
    }

    /// Runs the chosen rules (empty: every enabled rule) over the sessions the list shows; the main window's banner reports.
    private func runRules(_ items: Set<UUID>) {
        appModel.executeNow(
            rules: items, selectedIDs: flowList.selectedID.map { [$0] } ?? [], visibleIDs: flowList.visible.map(\.id),
            scope: .filtered)
    }

    /// A tree delete; an open editor document follows through the session's reconcile (revision change).
    private func delete(_ ids: [UUID]) {
        Task {
            if await model.deleteItems(ids) { state.selection.subtract(ids) }
            appModel.ruleEditorSession.reconcile()
        }
    }

    private func importRules() {
        guard !panelOpen else { return }
        panelOpen = true
        Task {
            let url = await RulesPackActions.chooseImportFile()
            panelOpen = false
            if let url { await appModel.rulePackImporter.begin(file: url) }
        }
    }

    /// The sheet was dismissed by the system (Esc): same rules as its buttons.
    private func closeImport() {
        let importer = appModel.rulePackImporter
        if RulesImportSheet.canCancel(importer.phase) { importer.cancel() } else { importer.dismiss() }
    }

    private func exportRules(_ ids: Set<UUID>?) {
        guard !panelOpen else { return }
        panelOpen = true
        Task {
            let report = await RulesPackActions.export(ids: ids, model: model, client: appModel.rulePackClient)
            panelOpen = false
            if let report { exportReport = report }
        }
    }
}
