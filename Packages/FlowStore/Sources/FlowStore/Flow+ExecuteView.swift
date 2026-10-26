import Foundation

extension Flow {
    /// A copy that shows the Execute overlay: legacy request/response projection and the client-visible
    /// boundaries replaced by the overlay's messages; everything else (ids, timing, provenance) unchanged.
    /// Not stored anywhere; its bodies are the overlay's own handles.
    public func viewingExecuteOverlay() -> Flow {
        guard let overlay = executeOverlay, !overlay.isEmpty else { return self }
        var copy = self
        // A flow recorded without boundaries claims none now either.
        let hasBoundaries = !messages.isEmpty
        if let request = overlay.request {
            if let target = request.target {
                copy.scheme = target.scheme
                copy.method = target.method
                copy.host = target.host
                copy.port = target.port
                copy.path = target.pathAndQuery
            }
            copy.requestHeaders = request.headers
            copy.requestTrailers = request.trailers
            copy.requestBody = Self.legacyBody(request.body)
            copy.requestBodyTruncated = request.bodyState == .truncated
            if hasBoundaries {
                let boundary: HTTPMessageBoundary = provenance.isCompose ? .composeSubmitted : .downstreamRequest
                var shown = request
                shown.boundary = boundary
                copy.messages[boundary] = shown
            }
        }
        if let response = overlay.response {
            copy.statusCode = response.status
            copy.statusReason = response.reason
            copy.responseHeaders = response.headers
            copy.responseTrailers = response.trailers
            copy.responseBody = Self.legacyBody(response.body)
            copy.responseBodyTruncated = response.bodyState == .truncated
            if hasBoundaries {
                let boundary: HTTPMessageBoundary = provenance.isCompose ? .composeDelivered : .downstreamResponse
                var shown = response
                shown.boundary = boundary
                copy.messages[boundary] = shown
            }
        }
        return copy
    }

    private static func legacyBody(_ slice: HTTPBodySlice?) -> BodyRef? {
        // The old projection cannot carry an offset; overlay bodies are always whole.
        slice?.ref
    }
}
