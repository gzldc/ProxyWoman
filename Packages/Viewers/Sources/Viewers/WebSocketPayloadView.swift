import SwiftUI
import Localization

public enum WebSocketPayloadDisplayMode: String, CaseIterable, Sendable { case text, hex, json }
public struct WebSocketPayloadView: View {
    private let prepared: WebSocketPreparedPayload
    private let mode: WebSocketPayloadDisplayMode
    public init(prepared: WebSocketPreparedPayload, mode: WebSocketPayloadDisplayMode) {
        self.prepared = prepared; self.mode = mode
    }
    public var body: some View {
        Group {
            switch mode {
            case .text:
                if let text = prepared.text { RawTextView(text: text, isTruncated: prepared.displayTruncated) }
                else { Text(L10n.string("webSocket.noText")) }
            case .hex: HexView(data: prepared.bytes).id(prepared.bytes)
            case .json:
                if let json = prepared.json { JSONTreeView(roots: JSONTreeItem.roots(for: json)) }
                else { Text(L10n.string("webSocket.noJSON")) }
            }
        }
    }
}
