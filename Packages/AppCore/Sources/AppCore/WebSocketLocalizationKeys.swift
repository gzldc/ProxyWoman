import FlowStore
import Viewers

/// Localization keys of the WebSocket pane, each written out in full so a scan for key literals sees them.

extension WebSocketDirection {
    public var localizationKey: String {
        switch self {
        case .clientToServer: "webSocket.direction.clientToServer"
        case .serverToClient: "webSocket.direction.serverToClient"
        }
    }
}

extension WebSocketEventKind {
    public var localizationKey: String {
        switch self {
        case .text: "webSocket.kind.text"
        case .binary: "webSocket.kind.binary"
        case .ping: "webSocket.kind.ping"
        case .pong: "webSocket.kind.pong"
        case .close: "webSocket.kind.close"
        case .opaqueFrame: "webSocket.kind.opaqueFrame"
        case .diagnostic: "webSocket.kind.diagnostic"
        }
    }
}

extension WebSocketLifecycle {
    public var localizationKey: String {
        switch self {
        case .open: "webSocket.lifecycle.open"
        case .transportClosed: "webSocket.lifecycle.transportClosed"
        case .transportEndedWithoutClose: "webSocket.lifecycle.transportEndedWithoutClose"
        }
    }
}

extension WebSocketCaptureState {
    public var localizationKey: String {
        switch self {
        case .observing: "webSocket.capture.observing"
        case .metadataOnly: "webSocket.capture.metadataOnly"
        case .paused: "webSocket.capture.paused"
        case .resumePendingBoundary: "webSocket.capture.resumePendingBoundary"
        case .contentStoppedUntilReconnect: "webSocket.capture.contentStoppedUntilReconnect"
        case .opaquePausedUntilReconnect: "webSocket.capture.opaquePausedUntilReconnect"
        }
    }
}

extension WebSocketIntegrity {
    public var localizationKey: String {
        switch self {
        case .transportComplete: "webSocket.status.transportComplete"
        case .captureTruncated: "webSocket.status.captureTruncated"
        case .incompleteTransport: "webSocket.status.incompleteTransport"
        case .invalid: "webSocket.status.invalid"
        case .opaque: "webSocket.status.opaque"
        case .partialPaused: "webSocket.status.partialPaused"
        case .observationStopped: "webSocket.status.observationStopped"
        }
    }
}

extension WebSocketPreparedStatus {
    public var localizationKey: String {
        switch self {
        case .available: "webSocket.status.available"
        case .invalid: "webSocket.status.invalid"
        case .incomplete: "webSocket.status.incomplete"
        case .truncated: "webSocket.status.truncated"
        case .opaque: "webSocket.status.opaque"
        }
    }
}

extension WebSocketPayloadDisplayMode {
    public var localizationKey: String {
        switch self {
        case .text: "webSocket.mode.text"
        case .hex: "webSocket.mode.hex"
        case .json: "webSocket.mode.json"
        }
    }
}

extension WebSocketExportStatus {
    public var localizationKey: String {
        switch self {
        case .complete: "webSocket.export.complete"
        case .partial: "webSocket.export.partial"
        case .cancelled: "webSocket.export.cancelled"
        }
    }
}

extension WebSocketExportReason {
    public var localizationKey: String {
        switch self {
        case .activeAtCutoff: "webSocket.error.activeAtCutoff"
        case .changedAfterCutoff: "webSocket.error.changedAfterCutoff"
        case .evicted: "webSocket.error.evicted"
        case .payloadUnavailable: "webSocket.error.payloadUnavailable"
        case .unprocessed: "webSocket.error.unprocessed"
        case .cancelled: "webSocket.error.cancelled"
        case .tokenInvalidated: "webSocket.error.tokenInvalidated"
        case .ordinalExhausted: "webSocket.error.ordinalExhausted"
        case .invalidPolicy: "webSocket.error.invalidPolicy"
        case .consumerLimit: "webSocket.error.consumerLimit"
        case .metadataBudget: "webSocket.error.metadataBudget"
        case .io: "webSocket.error.io"
        }
    }
}

extension WebSocketHandshakeStatus {
    public var localizationKey: String {
        switch self {
        case .verified: "webSocket.assessment.verified"
        case .invalid: "webSocket.assessment.invalid"
        case .negotiationUnverified: "webSocket.assessment.negotiationUnverified"
        case .opaqueExtension: "webSocket.assessment.opaqueExtension"
        }
    }
}
