import AppKit
import Localization
import SwiftUI

/// One row of the JSON tree. Children are a lazy view over the parent's storage: rows are made
/// only when the outline asks for them, so a huge document never materializes unexpanded rows.
struct JSONTreeItem: Identifiable, Sendable {
    enum Kind: Sendable {
        case object, array, string, number, bool, null
    }

    /// Scalars longer than this are cut in `summary`.
    static let summaryLimit = 1000

    /// The index path from the root, e.g. "0.3.1" (keys may repeat, indices do not).
    let id: String
    /// The member's key when the parent is an object.
    let key: String?
    /// The element's index when the parent is an array.
    let index: Int?
    let value: JSONNode

    /// The key, "[i]" for an array element, nil for the root itself.
    var label: String? {
        key ?? index.map { "[\($0)]" }
    }

    /// The rows shown at the top level: the root container's members, or the root itself
    /// when it is empty or not a container.
    static func roots(for node: JSONNode) -> JSONChildren {
        let root = JSONTreeItem(id: "", key: nil, index: nil, value: node)
        return root.children ?? JSONChildren(storage: .single(root))
    }

    /// nil for scalars and empty containers, so they show no disclosure triangle. O(1).
    var children: JSONChildren? {
        let prefix = id.isEmpty ? "" : id + "."
        switch value {
        case .object(let members) where !members.isEmpty:
            return JSONChildren(storage: .members(members, idPrefix: prefix))
        case .array(let items) where !items.isEmpty:
            return JSONChildren(storage: .items(items, idPrefix: prefix))
        default:
            return nil
        }
    }

    var kind: Kind {
        switch value {
        case .object: .object
        case .array: .array
        case .string: .string
        case .number: .number
        case .bool: .bool
        case .null: .null
        }
    }

    /// One-line rendering: scalars as JSON (cut after `summaryLimit` characters with "…"),
    /// containers as their element count.
    var summary: String {
        switch value {
        case .object(let members): return members.isEmpty ? "{}" : "{\(members.count)}"
        case .array(let items): return items.isEmpty ? "[]" : "[\(items.count)]"
        case .string(let string):
            let head = string.prefix(Self.summaryLimit + 1)
            guard head.count > Self.summaryLimit else { return value.prettyPrinted() }
            // Escape only the shown part; drop the closing quote, the text goes on.
            return String(JSONNode.string(String(head.prefix(Self.summaryLimit))).prettyPrinted().dropLast()) + "…"
        case .number(let raw):
            return raw.count > Self.summaryLimit ? String(raw.prefix(Self.summaryLimit)) + "…" : raw
        case .bool, .null:
            return value.prettyPrinted()
        }
    }

    /// What "复制值" puts on the pasteboard: strings without quotes, containers pretty-printed.
    var copyText: String {
        if case .string(let string) = value { return string }
        return value.prettyPrinted()
    }
}

/// The rows of one container, made on access.
struct JSONChildren: RandomAccessCollection, Sendable {
    enum Storage: Sendable {
        case members([(key: String, value: JSONNode)], idPrefix: String)
        case items([JSONNode], idPrefix: String)
        case single(JSONTreeItem)
    }

    let storage: Storage

    var startIndex: Int { 0 }

    var endIndex: Int {
        switch storage {
        case .members(let members, _): members.count
        case .items(let items, _): items.count
        case .single: 1
        }
    }

    subscript(position: Int) -> JSONTreeItem {
        switch storage {
        case .members(let members, let prefix):
            let member = members[position]
            return JSONTreeItem(id: prefix + String(position), key: member.key, index: nil, value: member.value)
        case .items(let items, let prefix):
            return JSONTreeItem(id: prefix + String(position), key: nil, index: position, value: items[position])
        case .single(let item):
            precondition(position == 0, "index out of range")
            return item
        }
    }
}

/// An outline of a JSON document: keys in their original order, values colored by type.
struct JSONTreeView: View {
    /// Prepared off the main actor (`BodyContent.jsonRoots`).
    let roots: JSONChildren
    var style = ViewerStyle()

    var body: some View {
        List(roots, children: \.children) { item in
            JSONTreeRow(item: item, style: style)
        }
        .listStyle(.inset)
    }
}

private struct JSONTreeRow: View {
    let item: JSONTreeItem
    let style: ViewerStyle

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            if let label = item.label {
                Text(label + ":")
                    .foregroundStyle(.primary)
            }
            Text(item.summary)
                .foregroundStyle(color)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .font(style.font)
        .contextMenu {
            Button(L10n.string("common.copyValue")) { copy(item.copyText) }
            if let key = item.key {
                Button(L10n.string("jSONTreeView.copyKey")) { copy(key) }
            }
        }
    }

    private var color: Color {
        switch item.kind {
        case .string: Color(nsColor: .systemRed)
        case .number: Color(nsColor: .systemBlue)
        case .bool: Color(nsColor: .systemPurple)
        case .null: .secondary
        case .object, .array: .secondary
        }
    }

    private func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
