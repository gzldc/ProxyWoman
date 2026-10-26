import AppCore
import AppKit
import FlowStore
import Localization
import SwiftUI
import Viewers

extension Preferences {
    var viewerStyle: ViewerStyle {
        ViewerStyle(
            fontSize: Double(fontSize), monospaced: monospaced,
            wrapsLines: wordWrap, showsInvisibles: showInvisibles)
    }
}

/// One side of the selected exchange; bodies are loaded and inspected off the main actor.
struct MessagePane: View {
    enum Side: String {
        case request, response
        var title: String { self == .request ? L10n.string("common.request") : L10n.string("common.response") }
    }
    private enum Tab: String, Identifiable {
        case headers, query, body, cookies, setCookie, raw, tree
        var id: Self { self }
        var title: String { L10n.string(titleKey) }
        private var titleKey: String {
            switch self {
            case .headers: "messagePane.tab.headers"
            case .query: "messagePane.tab.query"
            case .body: "messagePane.tab.body"
            case .cookies: "messagePane.tab.cookies"
            case .setCookie: "messagePane.tab.setCookie"
            case .raw: "messagePane.tab.raw"
            case .tree: "messagePane.tab.tree"
            }
        }
    }
    let flow: Flow
    let side: Side
    let preferences: Preferences
    @State private var tab = Tab.headers
    @State private var loaded: LoadedBody?

    private var headers: [HeaderField] { side == .request ? flow.requestHeaders : flow.responseHeaders }
    private var ref: BodyRef? { side == .request ? flow.requestBody : flow.responseBody }
    private var captureTruncated: Bool { side == .request ? flow.requestBodyTruncated : flow.responseBodyTruncated }
    private var tabs: [Tab] {
        side == .request ? [.headers, .query, .body, .cookies, .raw] : [.headers, .body, .setCookie, .raw, .tree]
    }
    private var key: BodyKey {
        BodyKey(
            id: flow.id, side: side.rawValue, size: ref?.size, contentType: headers.value(for: "content-type"),
            contentEncoding: headers.value(for: "content-encoding"), captureTruncated: captureTruncated)
    }

    /// Responses prepare once even from Header so Tree is immediately discoverable.
    /// Requests have no Tree tab; their Body work starts only when Body is selected.
    private var loadKey: BodyKey? { side == .response || tab == .body ? key : nil }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(side.title).font(.headline)
                Spacer()
                Menu {
                    Button(L10n.string("messagePane.copyAll"), action: copyAll)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help(L10n.format("messagePane.sideActions", side.title))
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            HStack(spacing: 3) {
                ForEach(tabs) { item in
                    Button {
                        tab = item
                    } label: {
                        Text(item.title)
                            .font(.system(size: 12, weight: tab == item ? .semibold : .regular))
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(
                                tab == item ? Color.primary.opacity(0.08) : .clear,
                                in: RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)
                    .disabled(item == .tree && (loaded?.key != key || loaded?.isJSON != true))
                    .accessibilityAddTraits(tab == item ? .isSelected : [])
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6).padding(.bottom, 5)
            Divider()
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .task(id: loadKey) {
            loaded = nil
            guard let key = loadKey, let ref else { return }
            let worker = Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                let body = try ref.load(maxBytes: BodyView.displayLimit)
                try Task.checkCancellation()
                let prepared = try PreparedBody.prepare(
                    data: body.data, contentType: key.contentType, contentEncoding: key.contentEncoding,
                    isTruncated: body.isTruncated, isCaptureTruncated: key.captureTruncated)
                return LoadedBody(key: key, prepared: prepared)
            }
            do {
                let result = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                guard !Task.isCancelled, self.loadKey == key else { return }
                loaded = result
                if tab == .tree && !result.isJSON { tab = .body }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, self.loadKey == key else { return }
                loaded = LoadedBody(key: key, error: error.localizedDescription)
                if tab == .tree { tab = .body }
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch tab {
        case .headers:
            NameValueTable(
                rows: headers.map { NameValue(name: $0.name, value: $0.value) }, style: preferences.viewerStyle)
        case .query:
            NameValueTable(rows: MessageParsing.queryItems(path: flow.path), style: preferences.viewerStyle)
        case .cookies:
            NameValueTable(rows: MessageParsing.requestCookies(headers), style: preferences.viewerStyle)
        case .setCookie:
            NameValueTable(
                rows: MessageParsing.responseCookies(headers).map {
                    NameValue(name: $0.name, value: ([$0.value] + $0.attributes).joined(separator: "; "))
                }, style: preferences.viewerStyle)
        case .raw:
            RawMessagePane(flow: flow, side: side, style: preferences.viewerStyle)
        case .body, .tree:
            if ref == nil {
                placeholder(
                    flow.state == .inProgress && side == .response
                        ? L10n.string("messagePane.receiving") : L10n.string("common.empty"))
            } else if let loaded, loaded.key == key {
                if let error = loaded.error {
                    placeholder(L10n.format("messagePane.readFailed", String(describing: error)))
                } else if let prepared = loaded.prepared {
                    BodyView(prepared: prepared, style: preferences.viewerStyle, treeOnly: tab == .tree)
                        .equatable().id(key)
                }
            } else {
                ProgressView()
            }
        }
    }

    private func copyAll() {
        let flow = flow
        let side = side
        Task {
            let text = await Task.detached(priority: .userInitiated) {
                side == .request ? RawMessage.request(flow) : RawMessage.response(flow)
            }.value
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }
    private func placeholder(_ text: String) -> some View { Text(text).foregroundStyle(.secondary) }

    private struct BodyKey: Hashable, Sendable {
        var id: Int
        var side: String
        var size: Int?
        var contentType: String?
        var contentEncoding: String?
        var captureTruncated: Bool
    }
    private struct LoadedBody: Sendable {
        var key: BodyKey
        var prepared: PreparedBody?
        var error: String?
        var isJSON: Bool { prepared?.hasJSONTree == true }
    }
}

private struct RawMessagePane: View {
    let flow: Flow
    let side: MessagePane.Side
    let style: ViewerStyle
    @State private var text: String?
    private var key: RawMessagePresentationKey {
        RawMessagePresentationKey(flow: flow, isRequest: side == .request)
    }
    var body: some View {
        Group {
            if let text { RawTextView(text: text, style: style) } else { ProgressView() }
        }
        .task(id: key) {
            text = nil
            let flow = flow
            let side = side
            let result = await Task.detached(priority: .userInitiated) {
                side == .request ? RawMessage.request(flow) : RawMessage.response(flow)
            }.value
            if !Task.isCancelled { text = result }
        }
    }

}

/// Wrapping key/value rows with native text selection and per-row copy actions.
struct NameValueTable: View {
    let rows: [NameValue]
    let style: ViewerStyle
    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                row(name: L10n.string("messagePane.key"), value: L10n.string("messagePane.value")).fontWeight(.semibold)
                    .background(Color(nsColor: .controlBackgroundColor))
                Divider()
                ForEach(Array(rows.enumerated()), id: \.offset) { index, item in
                    row(name: item.name, value: item.value)
                        .background(index.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.025))
                        .contextMenu {
                            Button(L10n.string("messagePane.copy")) { copy("\(item.name): \(item.value)") }
                            Button(L10n.string("common.copyValue")) { copy(item.value) }
                        }
                    Divider()
                }
                if rows.isEmpty { Text(L10n.string("messagePane.none")).foregroundStyle(.secondary).padding() }
            }
        }
        .font(.system(size: style.fontSize, design: style.monospaced ? .monospaced : .default))
        .textSelection(.enabled)
    }
    private func row(name: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(name).frame(width: 140, alignment: .leading)
            Text(value).frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
