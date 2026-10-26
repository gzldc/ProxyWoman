import AppCore
import AppKit
import FlowStore
import Localization
import RulesEngine
import SwiftUI

/// The preferences the flow table follows.
struct FlowTableStyle: Equatable {
    var fontSize: Int
    var monospaced: Bool
    var zebraRows: Bool
    var truncation: TruncationStyle
    var use24HourTime: Bool
    var fullTimeFormat: Bool
    var showsCommentColumn: Bool

    init(_ preferences: Preferences) {
        fontSize = preferences.fontSize
        monospaced = preferences.monospaced
        zebraRows = preferences.zebraRows
        truncation = preferences.truncation
        use24HourTime = preferences.use24HourTime
        fullTimeFormat = preferences.fullTimeFormat
        showsCommentColumn = preferences.showCommentColumn
    }
}

/// The flow list. An `NSTableView` so that many thousands of rows stay smooth.
/// Rows are read from `model.displayed` on demand rather than copied, so the next batch can
/// mutate the model's array in place. Per-row work is constant: cached formatters and icons.
struct FlowTableView: NSViewRepresentable {
    let model: FlowListModel
    let appModel: AppModel
    /// `model.revision`, read by the caller so that a change triggers `updateNSView`.
    let revision: Int
    let style: FlowTableStyle
    @Binding var selectedID: Int?
    /// A double click on a row (the click has already selected it).
    var onDoubleClick: (Int) -> Void = { _ in }
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model, appModel: appModel, selectedID: $selectedID)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let tableView = NSTableView()
        tableView.style = .fullWidth
        // fullWidth defaults to 17-point gaps, which waste almost 190 points across 11 columns.
        tableView.intercellSpacing = NSSize(width: 3, height: 2)
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true
        tableView.allowsColumnReordering = false
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        for column in Column.defaultColumns { tableView.addTableColumn(column.makeTableColumn()) }
        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator
        // A click on a row, even the selected one, ends "自动选中".
        tableView.target = context.coordinator
        tableView.action = #selector(Coordinator.rowClicked(_:))
        tableView.doubleAction = #selector(Coordinator.rowDoubleClicked(_:))

        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = context.coordinator
        tableView.menu = menu
        let headerMenu = NSMenu()
        headerMenu.autoenablesItems = false
        headerMenu.delegate = context.coordinator
        tableView.headerView?.menu = headerMenu

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        context.coordinator.tableView = tableView
        // The window sizes the table only after it was built: fit the URL column to the width.
        scrollView.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            context.coordinator, selector: #selector(Coordinator.clipViewDidResize(_:)),
            name: NSView.frameDidChangeNotification, object: scrollView.contentView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.selectedID = $selectedID
        context.coordinator.onDoubleClick = onDoubleClick
        let openWindow = self.openWindow
        let openSettings = self.openSettings
        let appModelForRules = self.appModel
        context.coordinator.openRules = {
            appModelForRules.shell.showRules()
            MainWindowLocator.bringToFront(openWindow: openWindow)
        }
        context.coordinator.openRuleEditor = { openWindow(id: ProxyWomanApp.ruleEditorWindowID) }
        let appModel = self.appModel
        context.coordinator.openCompose = {
            appModel.openCompose($0, isReplay: $1)
            MainWindowLocator.bringToFront(openWindow: openWindow)
        }
        context.coordinator.openTrafficTools = {
            appModel.prepareTrafficControl($0)
            openSettings()
        }
        context.coordinator.update(revision: revision, style: style, selectedID: selectedID)
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.releaseColorPanel()
    }

    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        var selectedID: Binding<Int?>
        var onDoubleClick: (Int) -> Void = { _ in }
        weak var tableView: NSTableView?
        /// Opens the main window's Rules tab.
        var openRules: (() -> Void)?
        var openRuleEditor: (() -> Void)?
        /// Opens the Compose page for a new request.
        var openCompose: ((ComposeDraft, Bool) -> Void)?
        /// Opens the Settings traffic-control page on a tab.
        var openTrafficTools: ((TrafficToolsTab) -> Void)?
        private let model: FlowListModel
        private let appModel: AppModel
        private var revision: Int?
        private var style: FlowTableStyle?
        private var metrics = FlowTableMetrics(fontSize: 12, monospaced: true, generation: 0)
        private var urlLineBreakMode: NSLineBreakMode = .byTruncatingTail
        /// The row count of the last reload: the model may already be ahead of the table.
        private var rowCount = 0
        /// Selection changes made by `update` are not user selections and must not be written back.
        private var isUpdating = false
        private var isFittingColumns = false
        /// The flow the colour panel is choosing a custom mark for.
        private var customColorFlowID: Int?
        private var colorPanelToken: Int?
        private var colorPanelCloseObserver: NSObjectProtocol?
        private var columnFitScheduled = false

        init(model: FlowListModel, appModel: AppModel, selectedID: Binding<Int?>) {
            self.model = model
            self.appModel = appModel
            self.selectedID = selectedID
            super.init()
            NotificationCenter.default.addObserver(
                self, selector: #selector(iconDidLoad(_:)), name: AppIconCache.didLoadIcon, object: nil)
        }

        func update(revision: Int, style: FlowTableStyle, selectedID: Int?) {
            guard let tableView else { return }
            isUpdating = true
            defer { isUpdating = false }

            let styleChanged = style != self.style
            if styleChanged { apply(style, to: tableView) }

            guard revision != self.revision || styleChanged else {
                if selectedID != currentSelectedID(in: tableView) {
                    select(selectedID, in: tableView)
                    if tableView.selectedRow >= 0 { tableView.scrollRowToVisible(tableView.selectedRow) }
                }
                return
            }
            let wasAtBottom = isScrolledToBottom(tableView)
            self.revision = revision
            rowCount = model.displayed.count
            tableView.reloadData()
            scheduleColumnFit()
            select(selectedID, in: tableView)
            if rowCount > 0, model.autoSelectsLatest || wasAtBottom {
                // The newest flow is on top when it is a pinned paused one: follow the selection then.
                if model.autoSelectsLatest, tableView.selectedRow >= 0 {
                    tableView.scrollRowToVisible(tableView.selectedRow)
                } else {
                    tableView.scrollRowToVisible(rowCount - 1)
                }
            }
        }

        private func apply(_ style: FlowTableStyle, to tableView: NSTableView) {
            let previous = self.style
            self.style = style
            if previous?.fontSize != style.fontSize || previous?.monospaced != style.monospaced {
                metrics = FlowTableMetrics(
                    fontSize: style.fontSize, monospaced: style.monospaced, generation: metrics.generation + 1)
                tableView.rowHeight = metrics.rowHeight
            }
            urlLineBreakMode =
                switch style.truncation {
                case .head: .byTruncatingHead
                case .middle: .byTruncatingMiddle
                case .tail: .byTruncatingTail
                }
            tableView.usesAlternatingRowBackgroundColors = style.zebraRows
            if previous?.showsCommentColumn != style.showsCommentColumn {
                syncCommentColumn(in: tableView, shown: style.showsCommentColumn)
                scheduleColumnFit()
            }
            if previous == nil || previous?.fontSize != style.fontSize || previous?.monospaced != style.monospaced
                || previous?.use24HourTime != style.use24HourTime || previous?.fullTimeFormat != style.fullTimeFormat
            {
                fitTimeColumn(in: tableView, style: style)
                scheduleColumnFit()
            }
        }

        private func syncCommentColumn(in tableView: NSTableView, shown: Bool) {
            let existing = tableView.tableColumn(withIdentifier: Column.comment.identifier)
            switch (shown, existing) {
            case (true, nil): tableView.addTableColumn(Column.comment.makeTableColumn())
            case (false, let column?): tableView.removeTableColumn(column)
            default: break
            }
        }

        /// Wide enough for the chosen time format in the chosen font.
        private func fitTimeColumn(in tableView: NSTableView, style: FlowTableStyle) {
            guard let column = tableView.tableColumn(withIdentifier: Column.time.identifier) else { return }
            let sample = Formatting.time(
                Date(timeIntervalSince1970: 1_791_000_000), use24Hour: style.use24HourTime, full: style.fullTimeFormat)
            let width = (sample as NSString).size(withAttributes: [.font: metrics.numberFont]).width
            column.width = ceil(width) + 14
        }

        private func currentSelectedID(in tableView: NSTableView) -> Int? {
            flow(at: tableView.selectedRow)?.id
        }

        private func flow(at row: Int) -> Flow? {
            let rows = model.displayed
            return row >= 0 && row < min(rowCount, rows.count) ? rows[row] : nil
        }

        /// A flow hidden by the filter stays selected in the model but has no row to highlight.
        private func select(_ id: Int?, in tableView: NSTableView) {
            // Paused flows are pinned on top, so the row comes from the displayed order.
            if let id, let row = model.displayedRow(ofID: id), row < rowCount {
                tableView.selectRowIndexes([row], byExtendingSelection: false)
            } else {
                tableView.deselectAll(nil)
            }
        }

        private func isScrolledToBottom(_ tableView: NSTableView) -> Bool {
            guard let clipView = tableView.enclosingScrollView?.contentView else { return true }
            return clipView.documentVisibleRect.maxY >= tableView.bounds.height - tableView.rowHeight
        }

        /// Only the URL column follows the viewport width.
        @objc func clipViewDidResize(_ notification: Notification) {
            scheduleColumnFit()
        }

        func tableViewColumnDidResize(_ notification: Notification) {
            scheduleColumnFit()
        }

        /// AppKit can deliver these notifications from inside its own delegate call.
        /// Coalesce one pass after that stack unwinds; our own mutations do not queue more work.
        private func scheduleColumnFit() {
            guard !isFittingColumns, !columnFitScheduled else { return }
            columnFitScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.columnFitScheduled = false
                if let table = self.tableView { self.fitURLColumn(in: table) }
            }
        }

        private func fitURLColumn(in table: NSTableView) {
            guard !isFittingColumns, let clip = table.enclosingScrollView?.contentView,
                clip.bounds.width > 0, let url = table.tableColumn(withIdentifier: Column.url.identifier)
            else { return }
            isFittingColumns = true
            defer { isFittingColumns = false }
            let fixed = table.tableColumns.filter { $0 !== url }.reduce(0) { $0 + $1.width }
            // fullWidth also adds leading/trailing margins. Measure actual column geometry
            // rather than assuming the spacing property accounts for those margins.
            let columnWidths = table.tableColumns.reduce(0) { $0 + $1.width }
            let spacing = max(0, table.rect(ofColumn: table.numberOfColumns - 1).maxX - columnWidths)
            let width = FlowTableLayout.urlWidth(viewport: clip.bounds.width, fixedColumns: fixed, spacing: spacing)
            if abs(url.width - width) > 0.5 {
                url.width = width
                table.tile()
            }
            // tile() grows a table for its columns but does not shrink a previously wider frame.
            let contentWidth = table.rect(ofColumn: table.numberOfColumns - 1).maxX
            let fittedWidth = max(clip.bounds.width, contentWidth)
            if abs(table.frame.width - fittedWidth) > 0.5 {
                table.setFrameSize(NSSize(width: fittedWidth, height: table.frame.height))
            }
        }

        /// Only the app column of the rows on screen can show the new icon.
        @objc private func iconDidLoad(_ notification: Notification) {
            guard let tableView, rowCount > 0 else { return }
            let column = tableView.column(withIdentifier: Column.app.identifier)
            let rows = tableView.rows(in: tableView.visibleRect)
            guard column >= 0, rows.length > 0 else { return }
            tableView.reloadData(
                forRowIndexes: IndexSet(integersIn: rows.location..<rows.location + rows.length),
                columnIndexes: [column])
        }

        // MARK: NSTableViewDataSource / NSTableViewDelegate

        func numberOfRows(in tableView: NSTableView) -> Int {
            rowCount
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn, let column = Column(rawValue: tableColumn.identifier.rawValue),
                let flow = flow(at: row), let style
            else { return nil }
            let reused = tableView.makeView(withIdentifier: column.identifier, owner: self)
            switch column {
            case .dot:
                let cell = reused as? FlowDotCell ?? Self.makeDotCell()
                cell.color = Palette.text(for: FlowIndicators.dotTone(of: flow))
                return cell
            case .method, .status:
                let cell = reused as? FlowBadgeCell ?? Self.makeBadgeCell(column)
                if column == .method {
                    cell.configure(text: flow.method, tone: .neutral, font: metrics.badgeFont)
                } else {
                    let badge = StatusBadge.of(flow)
                    cell.configure(text: badge.text, tone: badge.tone, font: metrics.badgeFont)
                }
                return cell
            case .ssl:
                let cell = reused as? FlowSymbolCell ?? FlowSymbolCell(identifier: column.identifier)
                cell.show(FlowIndicators.ssl(of: flow))
                return cell
            case .id, .url, .app, .time, .duration, .request, .response, .comment:
                let cell =
                    reused as? FlowTextCell ?? FlowTextCell(identifier: column.identifier, hasImage: column == .app)
                cell.style(
                    font: column.isNumeric ? metrics.numberFont : metrics.textFont,
                    lineBreakMode: column == .url ? urlLineBreakMode : .byTruncatingTail,
                    metrics: metrics)
                if column == .id, model.pausedFlowIDs.contains(flow.id) {
                    cell.textField?.attributedStringValue = pausedIDText(flow.id, font: metrics.numberFont)
                    cell.textField?.setAccessibilityLabel(
                        L10n.format("breakpoints.row.pausedA11y", L10n.string("breakpoints.row.paused"), flow.id))
                } else {
                    cell.textField?.setAccessibilityLabel(nil)
                    cell.textField?.stringValue = text(of: column, for: flow, style: style)
                }
                cell.markForeground = column == .url ? flow.displayMark.flatMap(MarkPalette.foreground) : nil
                if column == .app {
                    cell.imageView?.image = FlowIndicators.appSymbolName(of: flow)
                        .flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: FlowIndicators.appName(of: flow)) }
                        ?? AppIconCache.shared.icon(forExecutable: flow.client?.executablePath)
                }
                return cell
            }
        }

        /// "⏸ 12": the pause symbol before the number marks a flow held at a breakpoint.
        private func pausedIDText(_ id: Int, font: NSFont) -> NSAttributedString {
            let label = L10n.string("breakpoints.row.paused")
            let attachment = NSTextAttachment()
            attachment.image = NSImage(systemSymbolName: "pause.circle.fill", accessibilityDescription: label)?
                .withSymbolConfiguration(.init(paletteColors: [Palette.pending]))
            let text = NSMutableAttributedString(attachment: attachment)
            text.append(NSAttributedString(string: " \(id)", attributes: [.font: font, .foregroundColor: NSColor.labelColor]))
            return text
        }

        private func text(of column: Column, for flow: Flow, style: FlowTableStyle) -> String {
            switch column {
            case .id: String(flow.id)
            case .url: flow.url
            case .app: FlowIndicators.appName(of: flow)
            case .time: Formatting.time(flow.startedAt, use24Hour: style.use24HourTime, full: style.fullTimeFormat)
            case .duration: Formatting.duration(flow.duration)
            case .request: Formatting.size(flow.bytesSent)
            case .response: Formatting.size(flow.bytesReceived)
            case .comment: flow.comment ?? ""
            case .dot, .method, .status, .ssl: ""
            }
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let rowView =
                tableView.makeView(withIdentifier: MarkedRowView.identifier, owner: self) as? MarkedRowView
                ?? {
                    let created = MarkedRowView()
                    created.identifier = MarkedRowView.identifier
                    return created
                }()
            let flow = flow(at: row)
            rowView.apply(flow, isPaused: flow.map { model.pausedFlowIDs.contains($0.id) } ?? false)
            return rowView
        }

        private static func makeDotCell() -> FlowDotCell {
            let cell = FlowDotCell()
            cell.identifier = Column.dot.identifier
            return cell
        }

        private static func makeBadgeCell(_ column: Column) -> FlowBadgeCell {
            let cell = FlowBadgeCell()
            cell.identifier = column.identifier
            return cell
        }

        /// A selection the user made (click, arrow keys) ends "自动选中" so the newest flow does not
        /// take the selection away from what they are reading.
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isUpdating, let tableView else { return }
            model.autoSelectsLatest = false
            selectedID.wrappedValue = currentSelectedID(in: tableView)
        }

        @objc func rowDoubleClicked(_ sender: NSTableView) {
            guard let flow = flow(at: sender.clickedRow) else { return }
            onDoubleClick(flow.id)
        }

        @objc func rowClicked(_ sender: NSTableView) {
            if sender.clickedRow >= 0 { model.autoSelectsLatest = false }
        }

        // MARK: Context menu

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            if menu === tableView?.headerView?.menu {
                let toggle = NSMenuItem(
                    title: L10n.string("traffic.column.comment"), action: #selector(toggleCommentColumn(_:)),
                    keyEquivalent: "")
                toggle.target = self
                toggle.state = appModel.settings.preferences.showCommentColumn ? .on : .off
                menu.addItem(toggle)
                return
            }
            guard let row = tableView?.clickedRow, let flow = flow(at: row) else { return }
            let preferences = appModel.settings.preferences

            menu.addItem(item(L10n.string("flowTableView.copyURL"), #selector(copyURL(_:)), flow))
            let copyCurl = item(L10n.string("appCommands.copyCurl"), #selector(copyCurl(_:)), flow)
            // A tunnel is not a request curl could replay.
            copyCurl.isEnabled = flow.method != "CONNECT"
            menu.addItem(copyCurl)
            menu.addItem(markMenu(for: flow))
            let hasComment = flow.comment != nil
            menu.addItem(
                item(
                    L10n.string(hasComment ? "flowMenu.comment.edit" : "flowMenu.comment.add"),
                    #selector(editComment(_:)), flow))
            menu.addItem(.separator())
            addComposeItems(for: flow, to: menu)
            menu.addItem(.separator())

            let app = flow.client?.name
            let pinApp = item(
                app.map { preferences.isPinned(app: $0) } == true
                    ? L10n.string("flowTableView.unpinApp") : L10n.string("flowTableView.pinApp"),
                #selector(togglePinnedApp(_:)), flow)
            pinApp.isEnabled = app != nil
            menu.addItem(pinApp)
            menu.addItem(
                item(
                    preferences.isPinned(host: flow.host)
                        ? L10n.string("flowTableView.unpinHost") : L10n.string("flowTableView.pinHost"),
                    #selector(togglePinnedHost(_:)), flow))
            menu.addItem(.separator())

            menu.addItem(item(L10n.string("traffic.flowMenu.blockHost"), #selector(blockHost(_:)), flow))
            menu.addItem(item(L10n.string("traffic.flowMenu.captureOnlyHost"), #selector(captureOnlyHost(_:)), flow))
            menu.addItem(throttleMenu(for: flow))
            menu.addItem(.separator())

            let excluded = appModel.settings.decryption.hasActiveExactExclusion(for: flow.host)
            menu.addItem(
                item(
                    excluded
                        ? L10n.string("sidebarView.enableHostDecryption")
                        : L10n.string("sidebarView.disableHostDecryption"),
                    #selector(toggleDecryption(_:)), flow))
            menu.addItem(.separator())
            menu.addItem(newRuleItem(for: flow))
            menu.addItem(saveMockItem(for: flow))
            menu.addItem(executeItem(for: flow))
        }

        /// "对此会话执行规则…": runs every enabled rule over this session right away. A tunnel is
        /// offered too (Execute only marks, comments or hides it); a session still in progress is not.
        private func executeItem(for flow: Flow) -> NSMenuItem {
            let entry = item(L10n.string("flowMenu.execute"), #selector(executeOnFlow(_:)), flow)
            entry.isEnabled = flow.state != .inProgress
            return entry
        }

        @objc private func executeOnFlow(_ sender: NSMenuItem) {
            guard let flow = current(sender), flow.state != .inProgress else { return }
            appModel.executeNow(rules: [], selectedIDs: [flow.id], visibleIDs: model.visible.map(\.id), scope: .selected)
        }

        /// "标记 ▸ presets, custom, clear": the preset matching the manual mark is checked; Clear needs a manual mark.
        private func markMenu(for flow: Flow) -> NSMenuItem {
            let parent = NSMenuItem(title: L10n.string("flowMenu.mark"), action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            submenu.autoenablesItems = false
            let manual = flow.manualMark
            for (index, preset) in MarkPalette.presets.enumerated() {
                let entry = item(L10n.string(preset.localizationKey), #selector(markPreset(_:)), flow)
                entry.tag = index
                entry.image = Self.swatchImage(MarkPalette.swatch(forHex: preset.lightHex))
                entry.state = manual?.background.uppercased() == preset.lightHex ? .on : .off
                submenu.addItem(entry)
            }
            submenu.addItem(.separator())
            submenu.addItem(item(L10n.string("flowMenu.mark.custom"), #selector(markCustomColor(_:)), flow))
            let clear = item(L10n.string("flowMenu.mark.clear"), #selector(clearMark(_:)), flow)
            clear.isEnabled = manual != nil
            submenu.addItem(clear)
            parent.submenu = submenu
            return parent
        }

        private static func swatchImage(_ color: NSColor) -> NSImage {
            let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
                color.setFill()
                NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
                return true
            }
            return image
        }

        @objc private func markPreset(_ sender: NSMenuItem) {
            guard let flow = current(sender), MarkPalette.presets.indices.contains(sender.tag) else { return }
            appModel.flowAnnotations.mark(MarkPalette.presets[sender.tag], flowID: flow.id)
        }

        @objc private func clearMark(_ sender: NSMenuItem) {
            guard let flow = current(sender) else { return }
            appModel.flowAnnotations.clearMark(flowID: flow.id)
        }

        /// Opens the shared colour panel aimed at this coordinator; the target flow is remembered by id.
        @objc private func markCustomColor(_ sender: NSMenuItem) {
            guard let flow = current(sender) else { return }
            customColorFlowID = flow.id
            removeColorPanelCloseObserver()
            colorPanelToken = ColorPanelOwnership.shared.claim()
            let panel = NSColorPanel.shared
            panel.setTarget(self)
            panel.setAction(#selector(customColorChanged(_:)))
            panel.showsAlpha = false
            if let hex = flow.manualMark?.background, let initial = Self.color(fromHex: hex) { panel.color = initial }
            colorPanelCloseObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: panel, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.releaseColorPanel() }
            }
            panel.orderFront(nil)
        }

        /// Stops the shared colour panel from messaging this coordinator (it holds its target unretained),
        /// unless a newer coordinator has taken it over since.
        func releaseColorPanel() {
            removeColorPanelCloseObserver()
            customColorFlowID = nil
            if let token = colorPanelToken {
                colorPanelToken = nil
                ColorPanelOwnership.shared.release(token)
            }
        }

        private func removeColorPanelCloseObserver() {
            if let observer = colorPanelCloseObserver { NotificationCenter.default.removeObserver(observer) }
            colorPanelCloseObserver = nil
        }

        deinit {
            // The close observer holds the coordinator weakly and is removed on the next claim or release.
            guard let token = colorPanelToken else { return }
            Task { @MainActor in ColorPanelOwnership.shared.release(token) }
        }

        @objc private func customColorChanged(_ sender: NSColorPanel) {
            guard let id = customColorFlowID, let hex = MarkPalette.hex(from: sender.color) else { return }
            // The panel reports every drag step: skip a colour the flow already carries.
            if let stored = model.collection.flow(id: id)?.manualMark?.background, stored.uppercased() == hex { return }
            appModel.flowAnnotations.markCustom(hex: hex, flowID: id)
        }

        private static func color(fromHex hex: String) -> NSColor? {
            guard hex.count == 7, hex.first == "#", let value = Int(hex.dropFirst(), radix: 16) else { return nil }
            return NSColor(
                srgbRed: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255,
                blue: CGFloat(value & 255) / 255, alpha: 1)
        }

        @objc private func editComment(_ sender: NSMenuItem) {
            guard let flow = current(sender) else { return }
            switch CommentPrompt.run(current: flow.comment) {
            case .save(let text): appModel.flowAnnotations.setComment(text, flowID: flow.id)
            case .clear: appModel.flowAnnotations.setComment(nil, flowID: flow.id)
            case .cancel: break
            }
        }

        /// "用这个请求新建规则": an unsaved rule matching this request, opened in the rule editor window.
        private func newRuleItem(for flow: Flow) -> NSMenuItem {
            let entry = item(L10n.string("rules.flowMenu.newRule"), #selector(newRule(_:)), flow)
            // A tunnel has no request target to match; a busy or unreadable editor shows why in its window.
            entry.isEnabled = flow.method != "CONNECT" && appModel.rulesEditor.canMutate
            return entry
        }

        /// "保存响应为模拟规则…": enabled when the captured response can become a mock and the editor can
        /// take a new draft; otherwise disabled, and the reason is the tooltip.
        private func saveMockItem(for flow: Flow) -> NSMenuItem {
            let entry = item(L10n.string("rules.mock.menu"), #selector(saveResponseAsMock(_:)), flow)
            entry.isEnabled = appModel.canSaveResponseAsMock(flow: flow)
            entry.toolTip = appModel.responseMockBlockReason(flow: flow)
            return entry
        }

        /// "对此主机限速 ▸ presets". Every entry works on the host only, so a CONNECT tunnel gets them too.
        private func throttleMenu(for flow: Flow) -> NSMenuItem {
            let parent = NSMenuItem(title: L10n.string("traffic.flowMenu.throttleHost"), action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            submenu.autoenablesItems = false
            for (index, preset) in NetworkPreset.allCases.enumerated() {
                let item = item(TrafficPresentation.title(of: preset), #selector(throttleHost(_:)), flow)
                item.tag = index
                submenu.addItem(item)
            }
            parent.submenu = submenu
            return parent
        }

        /// "在 Compose 中编辑", "重放" and "重复发送…". An entry that cannot be used is disabled, and why is shown
        /// right below it (and as its tooltip); Copy cURL above stays an export either way.
        private func addComposeItems(for flow: Flow, to menu: NSMenu) {
            let editBlock = ComposeEntry.edit(flow)
            let replayBlock = ComposeEntry.replay(flow)
            let edit = item(L10n.string("compose.entry.edit"), #selector(editInCompose(_:)), flow)
            edit.isEnabled = editBlock == nil
            edit.toolTip = editBlock?.localizedDescription
            menu.addItem(edit)
            // The request the proxy really sent upstream, only when it differs from the original.
            if editBlock == nil, ComposeEntry.effectiveAvailable(flow) {
                let effective = item(L10n.string("compose.edit.variant.effective"), #selector(editEffectiveInCompose(_:)), flow)
                effective.isEnabled = ComposeEntry.edit(flow, variant: .effective) == nil
                menu.addItem(effective)
            }
            let replay = item(L10n.string("compose.entry.replay"), #selector(replayInCompose(_:)), flow)
            replay.isEnabled = replayBlock == nil
            replay.toolTip = replayBlock?.localizedDescription ?? L10n.string("compose.entry.replay.help")
            menu.addItem(replay)
            // Repeating needs exactly what Replay needs (a whole, plain request), so it is disabled
            // for the same reason.
            let repeatItem = item(L10n.string("repeat.entry.menu"), #selector(repeatSend(_:)), flow)
            repeatItem.isEnabled = appModel.canRepeat(flow: flow)
            repeatItem.toolTip = replayBlock?.localizedDescription
            menu.addItem(repeatItem)
            var reasons: [String] = []
            for block in [editBlock, replayBlock].compactMap({ $0 }) where !reasons.contains(block.localizedDescription) {
                reasons.append(block.localizedDescription)
            }
            for reason in reasons {
                let note = NSMenuItem(title: reason, action: nil, keyEquivalent: "")
                note.isEnabled = false
                note.indentationLevel = 1
                note.attributedTitle = NSAttributedString(string: reason, attributes: [
                    .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize), .foregroundColor: NSColor.secondaryLabelColor,
                ])
                menu.addItem(note)
            }
        }

        /// The latest recorded state of the flow (the menu's copy may be older).
        private func current(_ sender: NSMenuItem) -> Flow? {
            guard let flow = sender.representedObject as? Flow else { return nil }
            return model.collection.flow(id: flow.id) ?? flow
        }

        @objc private func editInCompose(_ sender: NSMenuItem) {
            guard let flow = current(sender), let draft = appModel.composeDraft(flow: flow, variant: .original) else { return }
            openCompose?(draft, false)
        }

        /// Opens the request actually sent upstream (after rules, Map Remote and cache changes) in Compose.
        @objc private func editEffectiveInCompose(_ sender: NSMenuItem) {
            guard let flow = current(sender), let draft = appModel.composeDraft(flow: flow, variant: .effective) else { return }
            openCompose?(draft, false)
        }

        /// Opens the captured original request in Compose with its default options; GET/HEAD/OPTIONS
        /// are sent once at once, other methods wait for Send (`ComposeReplay`). This is an explicit
        /// user send, not the proxy's transport retry.
        @objc private func replayInCompose(_ sender: NSMenuItem) {
            guard let flow = current(sender), ComposeEntry.replay(flow) == nil else { return }
            openCompose?(ComposeDraft(from: flow), true)
        }

        /// Opens the repeat sheet for the captured original request; nothing is sent until Start.
        @objc private func repeatSend(_ sender: NSMenuItem) {
            guard let flow = current(sender) else { return }
            appModel.beginRepeat(flow: flow)
        }

        private func item(_ title: String, _ action: Selector, _ flow: Flow) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = flow
            return item
        }

        @objc private func newRule(_ sender: NSMenuItem) {
            guard let flow = sender.representedObject as? Flow else { return }
            appModel.ruleEditorSession.openSeed(
                RuleEditorDraft.fromFlow(flow, kind: RuleKind.kindForNewDraft(selected: nil)))
            openRuleEditor?()
        }

        /// See `AppModel.saveResponseAsMock`; the menu bar command starts the same draft.
        @objc private func saveResponseAsMock(_ sender: NSMenuItem) {
            guard let flow = current(sender) else { return }
            let openRules = self.openRules, openEditor = self.openRuleEditor
            appModel.saveResponseAsMock(flow: flow, openRules: { openRules?() }, openEditor: { openEditor?() })
        }

        // MARK: Traffic tools

        /// Adds a block entry for the flow's host (once) and turns the Block list on.
        @objc private func blockHost(_ sender: NSMenuItem) {
            guard let flow = current(sender) else { return }
            let tools = appModel.trafficTools
            if let existing = hostEntry(in: tools.policy.blockEntries, host: flow.host) {
                tools.setEntryEnabled(existing.id, enabled: true)
                tools.setBlockEnabled(true)
                return
            }
            switch tools.addBlock(host: flow.host, port: nil, scheme: nil, method: nil, pathPrefix: nil) {
            case .success: tools.setBlockEnabled(true)
            case .failure(let error): report(error)
            }
        }

        /// Adds an allow entry for the flow's host (once), turns the Allow list on and shows it.
        @objc private func captureOnlyHost(_ sender: NSMenuItem) {
            guard let flow = current(sender) else { return }
            let tools = appModel.trafficTools
            if let existing = hostEntry(in: tools.policy.allowEntries, host: flow.host) {
                tools.setEntryEnabled(existing.id, enabled: true)
            } else if case .failure(let error) = tools.addAllow(host: flow.host, port: nil) {
                report(error)
                return
            }
            tools.setAllowEnabled(true)
            openTrafficTools?(.allow)
        }

        /// A host rule for the flow's host replaces an earlier one for the same host (the first
        /// match wins, so a second rule would never apply), then Network Conditions turn on.
        @objc private func throttleHost(_ sender: NSMenuItem) {
            guard let flow = current(sender), NetworkPreset.allCases.indices.contains(sender.tag) else { return }
            let tools = appModel.trafficTools
            if let pattern = HostPattern.normalizedUserPattern(flow.host) {
                for rule in tools.policy.conditions.hostRules where rule.hostPattern == pattern && rule.port == nil {
                    tools.removeHostCondition(rule.id)
                }
            }
            switch tools.addHostCondition(host: flow.host, port: nil, selection: .preset(NetworkPreset.allCases[sender.tag])) {
            case .success: tools.setConditionsEnabled(true)
            case .failure(let error): report(error)
            }
        }

        /// An entry that matches exactly this host and nothing else.
        private func hostEntry(in entries: [TrafficFilterEntry], host: String) -> TrafficFilterEntry? {
            guard let pattern = HostPattern.normalizedUserPattern(host) else { return nil }
            return entries.first { $0.matcher == RuleMatcher(hostPattern: pattern) }
        }

        private func report(_ error: TrafficPolicyError) {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = L10n.string("traffic.flowMenu.failedTitle")
            alert.informativeText = TrafficPresentation.message(for: error)
            alert.addButton(withTitle: L10n.string("common.close"))
            alert.runModal()
        }

        @objc private func copyURL(_ sender: NSMenuItem) {
            guard let flow = sender.representedObject as? Flow else { return }
            Self.copy(flow.url)
        }

        @objc private func copyCurl(_ sender: NSMenuItem) {
            guard let flow = sender.representedObject as? Flow else { return }
            let preferences = appModel.settings.preferences
            let port = appModel.listeningPort ?? appModel.settings.port
            let options = CurlOptions(
                proxy: preferences.copyAddsProxy ? "http://\(appModel.listenHost):\(port)" : nil,
                preserveOriginalHeaders: preferences.copyPreservesOriginalHeaders)
            Self.copy(CurlExporter.command(for: flow, options: options))
        }

        @objc private func toggleCommentColumn(_ sender: NSMenuItem) {
            appModel.settings.preferences.showCommentColumn.toggle()
        }

        @objc private func togglePinnedApp(_ sender: NSMenuItem) {
            guard let app = (sender.representedObject as? Flow)?.client?.name else { return }
            let isPinned = appModel.settings.preferences.isPinned(app: app)
            appModel.settings.preferences.setPinned(!isPinned, app: app)
        }

        @objc private func togglePinnedHost(_ sender: NSMenuItem) {
            guard let host = (sender.representedObject as? Flow)?.host else { return }
            let isPinned = appModel.settings.preferences.isPinned(host: host)
            appModel.settings.preferences.setPinned(!isPinned, host: host)
        }

        @objc private func toggleDecryption(_ sender: NSMenuItem) {
            guard let host = (sender.representedObject as? Flow)?.host else { return }
            let excluded = appModel.settings.decryption.hasActiveExactExclusion(for: host)
            appModel.setDecryption(excluded: !excluded, for: host)
        }

        private static func copy(_ text: String) {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }
    }

    /// In the order of the mockup.
    enum Column: String, CaseIterable {
        case dot, id, url, app, method, status, time, duration, request, response, ssl
        /// Added and removed by the "show comment column" preference.
        case comment

        static var defaultColumns: [Column] { allCases.filter { $0 != .comment } }

        @MainActor func makeTableColumn() -> NSTableColumn {
            let tableColumn = NSTableColumn(identifier: identifier)
            tableColumn.title = title
            tableColumn.width = headerWidth(in: L10n.localizer)
            tableColumn.minWidth = minWidth
            tableColumn.resizingMask = .userResizingMask
            return tableColumn
        }

        /// False for the columns whose header is never translated (a dot, "#", "URL", "SSL"): they keep `width` in every
        /// language, so a longer English UI does not widen them.
        var widthFollowsTitle: Bool {
            switch self {
            case .dot, .id, .url, .ssl: false
            default: true
            }
        }

        /// `width` (drawn for the Chinese titles), or wider when this language's header title needs more room.
        func headerWidth(in localizer: Localizer) -> CGFloat {
            widthFollowsTitle ? TableHeaderMetrics.columnWidth(minimum: width, title: title(in: localizer)) : width
        }

        var identifier: NSUserInterfaceItemIdentifier { NSUserInterfaceItemIdentifier(rawValue) }

        var title: String { title(in: L10n.localizer) }

        func title(in localizer: Localizer) -> String {
            switch self {
            case .dot: ""
            case .id: "#"
            case .url: "URL"
            case .app: localizer.string("sidebarView.apps")
            case .method: localizer.string("quickFilterBar.method")
            case .status: localizer.string("quickFilterBar.status")
            case .time: localizer.string("flowTableView.time")
            case .duration: localizer.string("flowTableView.duration")
            case .request: localizer.string("common.request")
            case .response: localizer.string("common.response")
            case .ssl: "SSL"
            case .comment: localizer.string("traffic.column.comment")
            }
        }

        var width: CGFloat {
            switch self {
            case .dot: 16
            case .id: 42
            case .url: 360
            case .app: 112
            case .method: 66
            case .status: 56
            case .time: 100
            case .duration: 66
            case .request: 66
            case .response: 70
            case .ssl: 30
            case .comment: 160
            }
        }

        var minWidth: CGFloat {
            switch self {
            case .dot: 16
            case .ssl: 18
            case .url: 120
            case .comment: 60
            default: 36
            }
        }

        var isNumeric: Bool {
            switch self {
            case .id, .time, .duration, .request, .response: true
            default: false
            }
        }
    }
}
