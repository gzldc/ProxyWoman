import FlowStore
import Foundation
import NIOHTTP1
import RulesEngine

/// A transport decision over a proven complete entity. No storage or connection is owned here.
struct FramingPlan {
    let head: HTTPMessageHead
    let trailers: [HeaderField]
    let bodyAllowed: Bool
    let closeDelimited: Bool
    let outcomes: [RuleOutcomeCode]
}

enum BreakpointFraming {
    static func plan(original: HTTPMessageHead, edited: HTTPMessageHead, body: HTTPBodyDescriptor,
                     source: HTTPWireVersion, target: HTTPWireVersion, requestMethod: String,
                     limits: RulesLimits = .init()) throws -> FramingPlan {
        guard body.complete, let length = body.length, length >= 0 else {
            throw HTTPMutationError(code: .bodyIncomplete, field: .body)
        }
        try HTTPMutationValidator.validateBodyEdit(original: original, edited: edited, body: body, limits: limits)
        var allowed = true
        if case .response(let status, _, _) = edited {
            allowed = HTTPMessageTranslation.responseBodyAllowed(requestMethod: .init(rawValue: requestMethod), status: .init(statusCode: status))
        }
        var descriptor = body
        if !allowed { descriptor.changed = false; descriptor.trailers = [] }
        let clean = replacingFraming(edited, with: original.headers)
        let normalized = try HTTPMutationValidator.normalize(head: clean, body: descriptor, limits: limits)
        var headers = try HTTPMessageTranslation.framingBaseFields(HTTPHeaders(fields: normalized.head.headers), destination: target)
        let originalHeaders = HTTPHeaders(fields: original.headers)
        let codings = body.changed ? [] : try HTTPMessageTranslation.checkedCodings(originalHeaders, source: source, destination: target)
        let originalChunked = codings.last == "chunked"
        if case .request = edited, !codings.isEmpty, !originalChunked { throw HTTPTranslationError.unsupportedTransferCoding }
        let opaqueEOF = !codings.isEmpty && !originalChunked
        let close = allowed && !body.changed && target != .http2 && (opaqueEOF
            || (source == .http1_0 && target == .http1_0 && !originalHeaders.contains(name: "content-length") && !originalChunked))
        var trailers = allowed && !body.changed && target != .http1_0 ? body.trailers : []
        var outcomes: [RuleOutcomeCode] = []
        if body.changed && !allowed { outcomes.append(.breakpointBodyIgnored) }
        if body.changed && !body.trailers.isEmpty { outcomes.append(.breakpointTrailersDropped) }
        let keepTransferCoding = allowed && !body.changed && target == .http1_1
            && (!codings.isEmpty || (source == .http2 && !trailers.isEmpty))
        headers.remove(name: "content-length")
        headers.remove(name: "transfer-encoding")
        if !allowed {
            trailers = []
            if case .response(let status, _, _) = edited, status != 204, !(100..<200).contains(status),
               let representation = originalHeaders.first(name: "content-length") {
                headers.add(name: target == .http2 ? "content-length" : "Content-Length", value: representation)
            }
        } else if keepTransferCoding {
            if !codings.isEmpty {
                for value in originalHeaders["transfer-encoding"] { headers.add(name: "Transfer-Encoding", value: value) }
            } else { headers.add(name: "Transfer-Encoding", value: "chunked") }
        } else if !close { headers.add(name: target == .http2 ? "content-length" : "Content-Length", value: String(length)) }
        if trailers.isEmpty { headers.remove(name: "trailer") }
        if target != .http2, close || originalHeaders[canonicalForm: "connection"].contains("close") {
            headers.replaceOrAdd(name: "Connection", value: "close")
        }
        let supplied = HTTPHeaders(fields: edited.headers)["content-length"]
        if supplied != headers["content-length"] { outcomes.append(.breakpointLengthCorrected) }
        return FramingPlan(head: withHeaders(normalized.head, headers.fields), trailers: trailers,
                           bodyAllowed: allowed, closeDelimited: close, outcomes: outcomes)
    }

    static func withHeaders(_ head: HTTPMessageHead, _ headers: [HeaderField]) -> HTTPMessageHead {
        switch head {
        case .request(let target, _): return .request(target, headers: headers)
        case .response(let status, let reason, _): return .response(status: status, reason: reason, headers: headers)
        }
    }
    static func replacingFraming(_ head: HTTPMessageHead, with fields: [HeaderField]) -> HTTPMessageHead {
        let names: Set<String> = ["content-length", "transfer-encoding", "trailer"]
        return withHeaders(head, head.headers.filter { !names.contains($0.name.lowercased()) }
            + fields.filter { names.contains($0.name.lowercased()) })
    }
}
