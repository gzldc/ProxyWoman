import FlowStore
import Foundation

/// Header edits for the "No Caching" tool. Pure; the proxy applies them to messages it forwards.
public enum NoCaching {
    public static let requestEdits: [HeaderEdit] = [
        .remove(name: "If-None-Match"),
        .remove(name: "If-Modified-Since"),
        .set(name: "Cache-Control", value: "no-cache"),
        .set(name: "Pragma", value: "no-cache"),
    ]

    public static let responseEdits: [HeaderEdit] = [
        .remove(name: "ETag"),
        .remove(name: "Last-Modified"),
        .remove(name: "Expires"),
        .set(name: "Cache-Control", value: "no-cache, no-store"),
        .set(name: "Expires", value: "0"),
    ]

    /// Handshakes and 101 responses are returned untouched. Otherwise the edits run through the
    /// shared validator and the resulting block must fit `limits`.
    public static func apply(
        _ headers: [HeaderField], direction: HTTPMessageDirection, status: Int? = nil,
        upgradeCandidate: Bool, limits: RulesLimits = RulesLimits()
    ) throws -> [HeaderField] {
        if upgradeCandidate || (direction == .response && status == 101) { return headers }
        let edits = direction == .request ? requestEdits : responseEdits
        try HTTPMutationValidator.validateEdits(edits, originalHeaders: headers, upgradeCandidate: false)
        let result = headers.applying(edits)
        try HTTPMutationValidator.validateBlock(result, trailers: false, limits: limits)
        return result
    }
}
