/// Protocol version observed or selected at one HTTP message boundary.
public enum HTTPWireVersion: String, Sendable, Equatable, Codable {
    case http1_0 = "HTTP/1.0"
    case http1_1 = "HTTP/1.1"
    case http2 = "HTTP/2"
}

/// Request and response versions are independent, even on the same HTTP/1 connection.
/// Unknown boundaries stay nil; CONNECT tunnels do not imply an HTTP version.
public struct HTTPTransportMetadata: Sendable, Equatable {
    public var downstreamRequest: HTTPWireVersion?
    public var downstreamResponse: HTTPWireVersion?
    public var upstreamRequest: HTTPWireVersion?
    public var upstreamResponse: HTTPWireVersion?
    public var downstreamStreamID: Int?
    public var upstreamStreamID: Int?
    public var downstreamTLSVersion: String? = nil
    public var upstreamTLSVersion: String? = nil

    public init(
        downstreamRequest: HTTPWireVersion? = nil,
        downstreamResponse: HTTPWireVersion? = nil,
        upstreamRequest: HTTPWireVersion? = nil,
        upstreamResponse: HTTPWireVersion? = nil,
        downstreamStreamID: Int? = nil,
        upstreamStreamID: Int? = nil,
        downstreamTLSVersion: String? = nil,
        upstreamTLSVersion: String? = nil
    ) {
        self.downstreamRequest = downstreamRequest
        self.downstreamResponse = downstreamResponse
        self.upstreamRequest = upstreamRequest
        self.upstreamResponse = upstreamResponse
        self.downstreamStreamID = downstreamStreamID
        self.upstreamStreamID = upstreamStreamID
        self.downstreamTLSVersion = downstreamTLSVersion
        self.upstreamTLSVersion = upstreamTLSVersion
    }
}
