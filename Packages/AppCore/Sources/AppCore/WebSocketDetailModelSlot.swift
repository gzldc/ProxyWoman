import Foundation
import FlowStore
import Observation

/// Owns a session detail view's model across SwiftUI view-value churn. Constructing the slot
/// subscribes nothing; the model is created when the view appears, reused while it stays
/// live, and replaced after a disappear (or anything else) cancelled it.
@MainActor @Observable public final class WebSocketDetailModelSlot {
    public private(set) var model: WebSocketViewModel?
    public init() {}
    @discardableResult
    public func activate(store: FlowStore, hub: WebSocketInvalidationHub, token: WebSocketSessionToken) -> WebSocketViewModel {
        if let model, !model.isCancelled, model.token == token { return model }
        model?.cancel()
        let fresh = WebSocketViewModel(store: store, hub: hub, token: token)
        model = fresh
        return fresh
    }
    public func deactivate() { model?.cancel(); model = nil }
    /// Whether a detail view for `flow` needs WebSocket invalidations at all: only a 101 or an
    /// attempted Upgrade can carry a session, so plain HTTP details never re-render on them.
    public static func observesInvalidations(_ flow: Flow) -> Bool {
        flow.statusCode == 101 || FlowProtocol.of(flow) == .websocket
    }
}
