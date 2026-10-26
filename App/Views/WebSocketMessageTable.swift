import AppCore
import AppKit
import FlowStore
import Localization
import SwiftUI

struct WebSocketMessageTable: NSViewRepresentable {
    let model: WebSocketViewModel
    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        table.style = .fullWidth; table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false; table.allowsEmptySelection = true
        table.setAccessibilityLabel(L10n.string("webSocket.tableAccessibility"))
        let columns: [(key: String, titleKey: String, width: Double)] = [
            ("direction", "webSocket.column.direction", 150), ("time", "webSocket.column.time", 200),
            ("type", "webSocket.column.type", 65), ("length", "webSocket.column.length", 90),
            ("preview", "webSocket.column.preview", 220), ("status", "webSocket.column.status", 130),
        ]
        for (key, titleKey, width) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(key))
            column.title = L10n.string(titleKey); column.width = width; table.addTableColumn(column)
        }
        table.delegate = context.coordinator; table.dataSource = context.coordinator
        let scroll = MessageScrollView(); scroll.documentView = table
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.onUserScroll = { [weak model] in model?.userDidScroll() }
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        // Explicit reads make SwiftUI observe changes to the bounded production model.
        _ = model.page; _ = model.selectedID; _ = model.autoFollow
        guard let table = scroll.documentView as? NSTableView else { return }
        context.coordinator.update(table)
    }
    @MainActor final class MessageScrollView: NSScrollView {
        var onUserScroll: (() -> Void)?
        override func scrollWheel(with event: NSEvent) { onUserScroll?(); super.scrollWheel(with: event) }
        override func mouseDown(with event: NSEvent) { onUserScroll?(); super.mouseDown(with: event) }
    }
    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        let model: WebSocketViewModel
        var updating = false
        var lastID: UInt64?
        init(model: WebSocketViewModel) { self.model = model }
        func update(_ table: NSTableView) {
            updating = true; defer { updating = false }
            table.reloadData()
            if let id = model.selectedID, let index = model.page.firstIndex(where: { $0.id == id }) {
                table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            } else { table.deselectAll(nil) }
            if model.autoFollow && lastID != model.page.last?.id && !model.page.isEmpty { table.scrollRowToVisible(model.page.count - 1) }
            lastID = model.page.last?.id
        }
        func numberOfRows(in tableView: NSTableView) -> Int { model.page.count }
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let table = notification.object as? NSTableView else { return }
            let index = table.selectedRow
            model.select(eventID: model.page.indices.contains(index) ? model.page[index].id : nil)
        }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row index: Int) -> NSView? {
            guard model.page.indices.contains(index) else { return nil }
            let row = model.page[index]
            let key = tableColumn?.identifier.rawValue ?? ""
            let text: String
            switch key {
            case "direction": text = L10n.string(row.direction.localizationKey)
            case "time": text = WebSocketPane.time(row.firstObservedAt)
            case "type": text = L10n.string(row.kind.localizationKey)
            case "length": text = WebSocketPane.bytes(row.decodedBytes)
            case "status": text = L10n.string(row.isCaptureTerminal ? row.integrity.localizationKey : "webSocket.status.pending")
            default:
                if let snapshot = model.store.webSocketPayloadChunk(token: model.token, eventID: row.id, kind: .application, offset: 0, maxBytes: 96, expectedRevision: row.revision) {
                    let decoded = row.kind == .text ? String(data: snapshot.bytes, encoding: .utf8) : nil
                    text = decoded?.replacingOccurrences(of: "\n", with: " ↵ ") ?? snapshot.bytes.prefix(24).map { String(format: "%02X", $0) }.joined(separator: " ")
                } else { text = L10n.string(row.isCaptureTerminal ? "webSocket.unavailable" : "webSocket.pending") }
            }
            let field = NSTextField(labelWithString: text)
            field.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            field.lineBreakMode = .byTruncatingTail; field.toolTip = text
            field.setAccessibilityLabel(text)
            if key == "direction" {
                let image = NSImageView(image: NSImage(systemSymbolName: row.direction == .clientToServer ? "arrow.up" : "arrow.down", accessibilityDescription: text)!)
                let stack = NSStackView(views: [image, field]); stack.spacing = 3; return stack
            }
            return field
        }
    }
}
