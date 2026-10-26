import AppCore
import AppKit
import Localization
import RulesEngine
import SwiftUI

/// The rules as a single-column outline of one-line rows: a group row (chevron, folder, name, grey count) or a rule row
/// (name, one grey summary line), both with run, switch and more in a fixed column at the right. Hit counts are in the
/// row's hover help. Groups are expandable rows. The view owns nothing but the
/// table's look: the tree, the drops and the commands are `RuleTree`, `RuleOutlineDrop`, `RuleOutlineCommands`,
/// `RuleRowMenu` and the model's group operations. Selection, the groups the user folded and a pending rename live on
/// `RulesTabState`, so rebuilding this view loses none of them.
///
/// `outline` must be built with every group open: the table keeps its own expanded state (a collapsed group
/// keeps its children, so a drop onto it has a target).
struct RulesOutlineView: NSViewRepresentable {
    let model: RulesEditorModel
    let outline: RuleOutline
    let hits: RuleHitsModel
    /// Rules whose regular expression was switched off after repeated timeouts get a warning mark.
    let health: PatternHealthMonitor
    let state: RulesTabState
    /// Read by the owner's body (like `hitCounts`), so a change re-runs `updateNSView`.
    let selection: Set<UUID>
    let renaming: UUID?
    let onOpen: @MainActor (UUID) -> Void
    let onDelete: @MainActor ([UUID]) -> Void
    /// A new rule where the selection says (⌘N).
    let onNewRule: @MainActor () -> Void
    /// A new rule / group in this group (nil: at the top level), from a row's menu.
    let onNewRuleIn: @MainActor (UUID?) -> Void
    let onNewGroupIn: @MainActor (UUID?) -> Void
    let onEditNote: @MainActor (UUID) -> Void
    /// Runs this one rule or group.
    let onRun: @MainActor (UUID) -> Void
    /// True while an Execute run is going: the run buttons are disabled.
    let runBusy: Bool
    /// Read by the owner's body, so a change of any count re-runs `updateNSView`.
    let hitCounts: [UUID: Int]
    /// Resolves a saved file's display name for the action text.
    let assetName: @MainActor (UUID) -> String?

    func makeCoordinator() -> RulesOutlineCoordinator { RulesOutlineCoordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        let table = RulesOutlineTableView()
        table.coordinator = context.coordinator
        context.coordinator.table = table
        table.style = .fullWidth
        table.selectionHighlightStyle = .none
        table.backgroundColor = ShellStyle.nsColor(.sidebar)
        table.usesAlternatingRowBackgroundColors = false
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.headerView = nil
        table.intercellSpacing = .zero
        // The card draws its own chevron and indentation.
        table.indentationPerLevel = 0
        table.autoresizesOutlineColumn = false
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(RulesOutlineCoordinator.doubleClicked(_:))
        table.registerForDraggedTypes([NSPasteboard.PasteboardType(RuleOutlineDrop.pasteboardType)])
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        table.draggingDestinationFeedbackStyle = .regular
        table.setAccessibilityLabel(L10n.string("rules.outline.accessibility.table"))
        let column = NSTableColumn(identifier: RulesOutlineCoordinator.columnID)
        column.minWidth = 160
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.outlineTableColumn = column
        scroll.documentView = table
        context.coordinator.apply()
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.apply()
    }
}

// MARK: table view

/// Keys are handled here, so they only fire while the table is the first responder: while a group's name is
/// edited the first responder is the field editor and typing, Space and ⌫ stay with the text.
final class RulesOutlineTableView: NSOutlineView {
    weak var coordinator: RulesOutlineCoordinator?

    override func keyDown(with event: NSEvent) {
        if !route(event) { super.keyDown(with: event) }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        return route(event) || super.performKeyEquivalent(with: event)
    }

    private func route(_ event: NSEvent) -> Bool {
        guard window?.firstResponder === self, let coordinator else { return false }
        var press = ToolKeyPress(event)
        // A bare ⌫ deletes like ⌘⌫ (the confirmation still comes first).
        if press.modifiers.intersection(.deviceIndependentFlagsMask).isEmpty, [51, 117].contains(press.keyCode) {
            press.modifiers = .command
        }
        return coordinator.actions().handle(press)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0 else { return nil }
        if !selectedRowIndexes.contains(row) { selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        guard let node = item(atRow: row) as? RulesOutlineNode else { return nil }
        return coordinator?.menu(for: node.id)
    }

    /// The card draws its own chevron.
    override func frameOfOutlineCell(atRow row: Int) -> NSRect { .zero }
}

final class RulesOutlineNode: NSObject {
    let row: RuleOutlineRow
    var children: [RulesOutlineNode] = []
    init(_ row: RuleOutlineRow) { self.row = row }
    var id: UUID { row.id }
    var isGroup: Bool { if case .group = row.item { true } else { false } }
}

// MARK: coordinator

@MainActor final class RulesOutlineCoordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTextFieldDelegate {
    static let columnID = NSUserInterfaceItemIdentifier("outline-card")

    var parent: RulesOutlineView
    weak var table: RulesOutlineTableView?
    private var roots: [RulesOutlineNode] = []
    private var nodes: [UUID: RulesOutlineNode] = [:]
    private var isReloading = false
    private var lastRows: [RuleOutlineRow]?
    private var lastCanMutate: Bool?
    private var lastRunBusy: Bool?
    private var lastHits: [UUID: Int] = [:]
    private var lastTree: RuleTree?
    private var lastDisabledPatterns = Set<UUID>()

    private static let dragType = NSPasteboard.PasteboardType(RuleOutlineDrop.pasteboardType)

    init(_ parent: RulesOutlineView) { self.parent = parent }

    private var model: RulesEditorModel { parent.model }
    private var collapsed: Set<UUID> {
        get { parent.state.collapsed }
        set { parent.state.collapsed = newValue }
    }

    // MARK: applying the model

    func apply() {
        guard let table else { return }
        let tree = model.tree
        let canMutate = model.canMutate
        let rows = parent.outline.rows
        let disabledPatterns = Set(tree.rules.filter { $0.enabled && parent.health.isDisabled($0) }.map(\.id))
        let runBusy = parent.runBusy
        if rows != lastRows || canMutate != lastCanMutate || runBusy != lastRunBusy || tree != lastTree || disabledPatterns != lastDisabledPatterns {
            lastDisabledPatterns = disabledPatterns
            lastRows = rows
            lastCanMutate = canMutate
            lastRunBusy = runBusy
            lastTree = tree
            reload(table, rows: rows)
        }
        let counts = hitCounts(tree: tree)
        // A reload would end a name being edited: the badges catch up when the edit is over.
        if counts != lastHits, table.currentEditor() == nil {
            let changed = counts.filter { lastHits[$0.key] != $0.value }.keys
            lastHits = counts
            let rows = IndexSet(changed.compactMap { nodes[$0] }.map { table.row(forItem: $0) }.filter { $0 >= 0 })
            if !rows.isEmpty { table.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integer: 0)) }
        }
        syncSelection(table)
        startRenameIfRequested(table)
    }

    private func hitCounts(tree: RuleTree) -> [UUID: Int] {
        var result: [UUID: Int] = [:]
        for node in nodes.values where !node.isGroup { result[node.id] = parent.hitCounts[node.id] ?? 0 }
        return result
    }

    private func reload(_ table: RulesOutlineTableView, rows: [RuleOutlineRow]) {
        isReloading = true
        defer { isReloading = false }
        let selected = parent.selection
        nodes = [:]
        roots = []
        for row in rows {
            let node = RulesOutlineNode(row)
            nodes[row.id] = node
            if let parentID = row.parentID, let owner = nodes[parentID] {
                owner.children.append(node)
            } else {
                roots.append(node)
            }
        }
        table.reloadData()
        let filtered = parent.outline.isFiltered
        // Parents before children (`rows` is in outline order): a group expanded while its parent is still closed
        // stays closed in the table, so its rows went missing behind an open chevron.
        for row in rows {
            guard let node = nodes[row.id], node.isGroup, !node.children.isEmpty else { continue }
            if filtered || !collapsed.contains(node.id) { table.expandItem(node) }
        }
        let indexes = IndexSet(selected.compactMap { nodes[$0] }.map { table.row(forItem: $0) }.filter { $0 >= 0 })
        table.selectRowIndexes(indexes, byExtendingSelection: false)
    }

    private func syncSelection(_ table: RulesOutlineTableView) {
        let wanted = IndexSet(parent.selection.compactMap { nodes[$0] }.map { table.row(forItem: $0) }.filter { $0 >= 0 })
        guard wanted != table.selectedRowIndexes else { return }
        isReloading = true
        table.selectRowIndexes(wanted, byExtendingSelection: false)
        isReloading = false
        if let first = wanted.first { table.scrollRowToVisible(first) }
    }

    private func startRenameIfRequested(_ table: RulesOutlineTableView) {
        guard let id = parent.renaming, let node = nodes[id], node.isGroup else { return }
        // A group made inside a closed group: open the ones above it first.
        var ancestor = node.row.parentID
        while let current = ancestor, let owner = nodes[current] {
            collapsed.remove(current)
            table.expandItem(owner)
            ancestor = owner.row.parentID
        }
        let row = table.row(forItem: node)
        guard row >= 0 else { return }
        table.scrollRowToVisible(row)
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.editColumn(0, row: row, with: nil, select: true)
        Task { @MainActor in self.parent.state.renaming = nil }
    }

    // MARK: data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? RulesOutlineNode)?.children.count ?? roots.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? RulesOutlineNode)?.children[index] ?? roots[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? RulesOutlineNode).map { $0.isGroup && !$0.children.isEmpty } ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, persistentObjectForItem item: Any?) -> Any? {
        (item as? RulesOutlineNode)?.id.uuidString
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        ((item as? RulesOutlineNode)?.isGroup == true ? RuleCardCell.groupHeight : RuleCardCell.ruleHeight) + RuleCardCell.gap
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? { RuleCardRowView() }

    // MARK: cells

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? RulesOutlineNode else { return nil }
        let cell = outlineView.makeView(withIdentifier: RuleCardCell.identifier, owner: nil) as? RuleCardCell ?? RuleCardCell()
        cell.show(
            content(of: node), target: self, delegate: self,
            actions: (#selector(chevronClicked(_:)), #selector(runClicked(_:)), #selector(toggled(_:)), #selector(moreClicked(_:))))
        let row = outlineView.row(forItem: node)
        cell.background.isSelected = row >= 0 && outlineView.isRowSelected(row)
        return cell
    }

    private func content(of node: RulesOutlineNode) -> RuleCardContent {
        let name = name(of: node)
        var blocked = !model.canMutate
        let card: (title: String, summary: String, help: String?)
        let hitsText: String?
        var warning: String?
        switch node.row.item {
        case .group(let group):
            let counts = node.row.counts ?? (enabled: 0, total: 0)
            let presented = RuleCardPresentation.group(group, counts: counts)
            card = (presented.title, presented.countText, nil)
            hitsText = nil
        case .rule(let rule):
            let count = parent.hitCounts[node.id] ?? 0
            let presented = RuleCardPresentation.card(
                for: rule, hits: count, isReadOnly: model.isReadOnly(rule.id), assetName: { parent.assetName($0) })
            card = (presented.title, presented.summary, presented.helpText)
            hitsText = L10n.format("rules.outline.accessibility.hits", count)
            if rule.containsBreakpoint, !model.liveBreakpoints, !rule.enabled { blocked = true }
            if lastDisabledPatterns.contains(rule.id) { warning = L10n.string("pattern.disabled.help.rule") }
        }
        let filtered = parent.outline.isFiltered
        return RuleCardContent(
            depth: node.row.depth, isGroup: node.isGroup, hasChildren: !node.children.isEmpty, title: card.title, summary: card.summary, help: card.help,
            isEnabled: isEnabled(node), canToggle: !blocked, isExpanded: filtered || !collapsed.contains(node.id),
            canRun: !parent.runBusy, canEditTitle: node.isGroup && model.canMutate,
            canShowMenu: !RuleRowMenu.entries(
                for: node.id, tree: model.tree, canMutate: model.canMutate, isReadOnly: model.isReadOnly(node.id)
            ).isEmpty,
            toggleLabel: node.isGroup ? L10n.format("rules.outline.enableGroup", name) : L10n.format("rules.list.enableRule", name),
            runLabel: L10n.string(node.isGroup ? "rules.outline.run.group" : "rules.row.run"),
            moreLabel: L10n.string("rules.row.more"),
            collapseLabel: L10n.format("rules.row.collapse", name), expandLabel: L10n.format("rules.row.expand", name),
            hitsAccessibility: hitsText, warning: warning)
    }

    private func name(of node: RulesOutlineNode) -> String {
        switch node.row.item {
        case .group(let group): RulePresentation.displayName(group.name)
        case .rule(let rule): RulePresentation.displayName(rule.name)
        }
    }

    private func isEnabled(_ node: RulesOutlineNode) -> Bool {
        switch node.row.item {
        case .group(let group): group.enabled
        case .rule(let rule): rule.enabled
        }
    }

    private func node(of sender: NSView) -> RulesOutlineNode? {
        guard let table else { return nil }
        let row = table.row(for: sender)
        return row >= 0 ? table.item(atRow: row) as? RulesOutlineNode : nil
    }

    @objc func runClicked(_ sender: NSButton) {
        guard !parent.runBusy, let node = node(of: sender) else { return }
        parent.onRun(node.id)
    }

    @objc func chevronClicked(_ sender: NSButton) {
        guard let table, let node = node(of: sender) else { return }
        if table.isItemExpanded(node) { table.collapseItem(node) } else { table.expandItem(node) }
    }

    @objc func moreClicked(_ sender: NSButton) {
        guard let node = node(of: sender), let menu = menu(for: node.id, selectionAware: false) else { return }
        menu.popUp(
            positioning: nil, at: ToolBarMenuAnchor.popUpLocation(in: sender.bounds, isFlipped: sender.isFlipped), in: sender)
    }

    // MARK: selection, expansion, clicks

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isReloading, let table else { return }
        let ids = Set(table.selectedRowIndexes.compactMap { (table.item(atRow: $0) as? RulesOutlineNode)?.id })
        if ids != parent.selection { parent.state.selection = ids }
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? RulesOutlineNode else { return }
        showExpanded(true, node)
        guard !isReloading else { return }
        collapsed.remove(node.id)
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? RulesOutlineNode else { return }
        showExpanded(false, node)
        guard !isReloading, !parent.outline.isFiltered else { return }
        collapsed.insert(node.id)
    }

    private func showExpanded(_ expanded: Bool, _ node: RulesOutlineNode) {
        guard let table else { return }
        let row = table.row(forItem: node)
        if row >= 0, let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? RuleCardCell {
            cell.setExpanded(expanded)
        }
    }

    @objc func doubleClicked(_ sender: Any?) {
        guard let table, table.clickedRow >= 0, let node = table.item(atRow: table.clickedRow) as? RulesOutlineNode else { return }
        if !node.isGroup {
            if RuleOutlineCommands.availability(
                selection: [node.id], tree: model.tree, canMutate: model.canMutate, liveBreakpoints: model.liveBreakpoints
            ).canOpen { parent.onOpen(node.id) }
        } else if model.canMutate {
            table.editColumn(0, row: table.clickedRow, with: nil, select: true)
        }
    }

    // MARK: edits in the table

    @objc func toggled(_ sender: NSSwitch) {
        guard let table, let node = node(of: sender) else { return }
        let row = table.row(forItem: node)
        let enabled = sender.state == .on
        // Several selected rows switch together when the clicked row is one of them.
        let ids = table.selectedRowIndexes.contains(row) ? selectedIDs() : [node.id]
        set(ids, enabled: enabled)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, let node = node(of: field), case .group(let group) = node.row.item
        else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty || text == group.name {
            field.stringValue = name(of: node)
            return
        }
        Task { await model.renameGroup(id: group.id, name: text) }
    }

    // MARK: commands

    private func selectedIDs() -> [UUID] {
        guard let table else { return [] }
        return table.selectedRowIndexes.compactMap { (table.item(atRow: $0) as? RulesOutlineNode)?.id }
    }

    private func availability(_ ids: [UUID]) -> (canDuplicate: Bool, canDelete: Bool, canToggle: Bool, canOpen: Bool, canMoveUp: Bool, canMoveDown: Bool) {
        RuleOutlineCommands.availability(
            selection: ids, tree: model.tree, canMutate: model.canMutate, liveBreakpoints: model.liveBreakpoints)
    }

    /// What the keys do for the current selection; a command that cannot run now is not offered, so its key goes on.
    func actions() -> ToolTableActions {
        let ids = selectedIDs()
        let can = availability(ids)
        var actions = ToolTableActions()
        if RuleOutlineCommands.canCreate(canMutate: model.canMutate) { actions.new = { [weak self] in self?.parent.onNewRule() } }
        if can.canOpen, let id = ids.first { actions.edit = { [weak self] in self?.parent.onOpen(id) } }
        if can.canDelete { actions.delete = { [weak self] in self?.parent.onDelete(ids) } }
        if can.canDuplicate, let id = ids.first { actions.duplicate = { [weak self] in self?.duplicate(id) } }
        if can.canToggle, !ids.isEmpty {
            actions.toggleEnabled = { [weak self] in
                guard let self else { return }
                set(ids, enabled: RuleOutlineCommands.toggleTarget(selection: ids, tree: model.tree))
            }
        }
        return actions
    }

    private func duplicate(_ id: UUID) {
        let model = model
        Task { await model.duplicateItem(id) }
    }

    private func move(_ id: UUID, by delta: Int) {
        let model = model
        Task { await model.moveItem(id, by: delta) }
    }

    /// Switches rules and groups one save at a time, in table order, and stops at the first refusal.
    private func set(_ ids: [UUID], enabled: Bool) {
        let model = model
        let tree = model.tree
        Task {
            var failed = false
            for id in ids where !failed {
                if let rule = tree.rules.first(where: { $0.id == id }) {
                    if rule.enabled != enabled, await !model.setEnabled(id: id, enabled: enabled) { failed = true }
                } else if let group = tree.groups.first(where: { $0.id == id }) {
                    if group.enabled != enabled, await !model.setGroupEnabled(id: id, enabled: enabled) { failed = true }
                }
            }
            // A refused save leaves the switch in the state that was clicked: draw the saved state again.
            if failed {
                lastRows = nil
                apply()
            }
        }
    }

    /// The row menu (right-click and the ⋮ button): `RuleRowMenu.entries`, nothing else.
    func menu(for id: UUID, selectionAware: Bool = true) -> NSMenu? {
        let entries = RuleRowMenu.entries(
            for: id, tree: model.tree, canMutate: model.canMutate, isReadOnly: model.isReadOnly(id))
        guard !entries.isEmpty else { return nil }
        let items = entries.map { entry in
            ToolBarMenuItem(
                title: L10n.string(entry.item.titleKey), systemImage: Self.symbol(entry.item), isEnabled: entry.isEnabled
            ) { [weak self] in self?.perform(entry.item, on: id, selectionAware: selectionAware) }
        }
        return ToolBarMenu.make(items)
    }

    private static func symbol(_ item: RuleRowMenuItem) -> String {
        switch item {
        case .moveUp: "arrow.up"
        case .moveDown: "arrow.down"
        case .addGroup: "folder.badge.plus"
        case .addRule: "plus.rectangle"
        case .duplicate: "plus.square.on.square"
        case .rename: "pencil"
        case .editNote: "note.text"
        case .delete: "trash"
        }
    }

    private func perform(_ item: RuleRowMenuItem, on id: UUID, selectionAware: Bool) {
        let newParent = RuleRowMenu.newItemParent(for: id, tree: model.tree)
        switch item {
        case .moveUp: move(id, by: -1)
        case .moveDown: move(id, by: 1)
        case .addGroup: parent.onNewGroupIn(newParent)
        case .addRule: parent.onNewRuleIn(newParent)
        case .duplicate: duplicate(id)
        case .rename: parent.state.renaming = id
        case .editNote: parent.onEditNote(id)
        case .delete:
            // Right-click on one of several selected rows acts on all of them.
            let selected = selectedIDs()
            parent.onDelete(selectionAware && selected.contains(id) ? selected : [id])
        }
    }

    // MARK: drag and drop

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard model.canMutate, !parent.outline.isFiltered, let node = item as? RulesOutlineNode else { return nil }
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(RuleOutlineDrop.pasteboardString(node.id), forType: Self.dragType)
        return pasteboardItem
    }

    private func draggedIDs(_ info: NSDraggingInfo) -> [UUID] {
        let strings = info.draggingPasteboard.pasteboardItems?.compactMap { $0.string(forType: Self.dragType) } ?? []
        return RuleOutlineDrop.ids(fromPasteboardStrings: strings)
    }

    func outlineView(
        _ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int
    ) -> NSDragOperation {
        let moving = draggedIDs(info)
        let proposed = (item as? RulesOutlineNode)?.id
        let tree = model.tree
        outlineView.setAccessibilityHelp(nil)
        guard model.canMutate, !parent.outline.isFiltered, !moving.isEmpty,
            let target = RuleOutlineDrop.target(proposedItem: proposed, childIndex: index, moving: moving, tree: tree)
        else { return [] }
        let verdict = tree.canMove(moving, toParent: target.parent, at: target.insertionIndex, limits: model.limits)
        // A refused drop gets no cursor and no alert; the reason is only described for assistive technology.
        outlineView.setAccessibilityHelp(RuleOutlinePresentation.dropMessage(verdict))
        guard verdict == .allowed else { return [] }
        // A drop on a group highlights the group; any other proposal is put at its slot.
        let onGroup = (item as? RulesOutlineNode)?.isGroup == true && index < 0
        if !onGroup {
            outlineView.setDropItem(target.parent.flatMap { nodes[$0] }, dropChildIndex: target.tableIndex)
        }
        return .move
    }

    func outlineView(
        _ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int
    ) -> Bool {
        let moving = draggedIDs(info)
        let tree = model.tree
        guard let target = RuleOutlineDrop.target(
            proposedItem: (item as? RulesOutlineNode)?.id, childIndex: index, moving: moving, tree: tree)
        else { return false }
        let model = model
        Task { await model.moveItems(moving, toParent: target.parent, at: target.insertionIndex) }
        return true
    }
}
