import FlowStore
import Localization

/// Presents observed message boundaries without inferring a version from a scheme or tunnel.
public enum HTTPTransportPresentation {
    public static func summary(_ transport: HTTPTransportMetadata, localizer: Localizer = L10n.localizer) -> String {
        let client = leg(request: transport.downstreamRequest, response: transport.downstreamResponse,
                         streamID: transport.downstreamStreamID, localizer: localizer)
        let upstream = leg(request: transport.upstreamRequest, response: transport.upstreamResponse,
                           streamID: transport.upstreamStreamID, localizer: localizer)
        return localizer.format("httpTransport.summary", arguments: [client, upstream])
    }

    public static func capabilityDescription(localizer: Localizer = L10n.localizer) -> String {
        localizer.string("httpTransport.capabilityDescription")
    }

    private static func leg(request: HTTPWireVersion?, response: HTTPWireVersion?, streamID: Int?,
                            localizer: Localizer) -> String {
        let unknown = localizer.string("httpTransport.unknown")
        var text = request == response ? (request?.rawValue ?? unknown)
            : localizer.format("httpTransport.requestResponse", arguments: [request?.rawValue ?? unknown, response?.rawValue ?? unknown])
        if let streamID { text += localizer.format("httpTransport.stream", arguments: [String(streamID)]) }
        return text
    }
}
