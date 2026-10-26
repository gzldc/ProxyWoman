import Foundation
import FlowStore

/// How a replaced body relates to the message's `Content-Encoding`.
public enum BodyEncodingChoice: Sendable, Equatable, Hashable, Codable {
    /// Nothing was decided (valid only while the body is unchanged or has no encoding).
    case unchanged
    /// The new bytes are already encoded as `Content-Encoding` says.
    case retainEncodedBytes
    /// The new bytes are plain: drop `Content-Encoding`.
    case removeEncoding
}

public struct HTTPBodyDescriptor: Sendable, Equatable {
    /// Exact entity length (transfer framing removed, content encoding untouched) when known.
    public var length: Int64?
    /// Every byte of the entity is available.
    public var complete: Bool
    /// The user replaced the bytes.
    public var changed: Bool
    public var encodingChoice: BodyEncodingChoice
    public var trailers: [HeaderField]

    public init(
        length: Int64?, complete: Bool, changed: Bool, encodingChoice: BodyEncodingChoice = .unchanged,
        trailers: [HeaderField] = []
    ) {
        self.length = length
        self.complete = complete
        self.changed = changed
        self.encodingChoice = encodingChoice
        self.trailers = trailers
    }
}

/// A typed failure of the shared edit validator: stable code plus the field the UI should mark.
public struct HTTPMutationError: Error, Equatable, Sendable {
    public enum Code: String, Sendable, Equatable {
        case invalidHeaderName, invalidHeaderValue, protectedHeader, nominatedHeader
        case headerBlockTooLarge, tooManyHeaderFields
        case invalidMethod, connectNotAllowed, invalidScheme, invalidHost, userinfoNotAllowed
        case fragmentNotAllowed, invalidPort, invalidPath, invalidStatus, invalidReason
        case invalidContentLength, invalidFraming, bodyIncomplete, encodingChoiceRequired, messageKindMismatch
    }

    public enum Field: Sendable, Equatable {
        case message, method, scheme, host, port, path, status, reason, headers, trailers, body
        case contentLength, contentEncoding
        case header(name: String)
        case headerValue(name: String)
        case trailer(name: String)
    }

    public var code: Code
    public var field: Field

    public init(code: Code, field: Field) {
        self.code = code
        self.field = field
    }
}

/// The one validator for rule header edits, breakpoint edits and Compose edits. Pure, Foundation only.
/// It never manufactures wire framing: the transport writer owns Host/:authority, Content-Length,
/// Transfer-Encoding and the other connection-managed fields.
public enum HTTPMutationValidator {
    /// Fields the editor must not touch: routing, connection management, framing, proxy and
    /// expectation handling.
    private static let protectedNames: Set<String> = [
        "host", "connection", "proxy-connection", "keep-alive", "upgrade", "te", "transfer-encoding",
        "content-length", "trailer", "expect",
    ]
    private static let integrityFields: Set<String> = ["content-md5", "digest", "content-digest", "repr-digest"]

    // MARK: edits

    /// Rejects operations on protected or Connection-nominated fields and malformed names/values.
    /// `originalHeaders` is the message the operations will run on (its Connection nominates fields).
    public static func validateEdits(
        _ operations: [HeaderEdit], originalHeaders: [HeaderField], upgradeCandidate: Bool = false
    ) throws {
        let guarded = guardedNames(originalHeaders, upgradeCandidate: upgradeCandidate)
        for operation in operations {
            let name = operation.name
            if name.isEmpty {
                // "All keys": the protected fields are skipped when the edit runs. Only the edits that
                // look at existing fields or set them all have no name to add or test.
                switch operation {
                case .append, .addIfMissing: throw HTTPMutationError(code: .invalidHeaderName, field: .header(name: name))
                default: break
                }
            } else if let error = protectionError(name, guarded) { throw error }
            if let value = operation.value, !isValidValue(value) {
                throw HTTPMutationError(code: .invalidHeaderValue, field: .headerValue(name: name))
            }
        }
    }

    /// Compares an edited head (breakpoint/Compose tables) with the original: every protected,
    /// nominated or handshake field must be exactly as it was; then the edited head must be valid.
    public static func validateEdit(
        original: HTTPMessageHead, edited: HTTPMessageHead, body: HTTPBodyDescriptor,
        upgradeCandidate: Bool = false, limits: RulesLimits = RulesLimits()
    ) throws {
        switch (original, edited) {
        case (.request, .request), (.response, .response): break
        default: throw HTTPMutationError(code: .messageKindMismatch, field: .message)
        }
        let guarded = guardedNames(original.headers, upgradeCandidate: upgradeCandidate)
        var checked = Set<String>()
        for field in original.headers + edited.headers {
            let lower = field.name.lowercased()
            guard guarded.isProtected(lower), checked.insert(lower).inserted else { continue }
            guard original.headers.values(for: lower) == edited.headers.values(for: lower) else {
                let spelled = edited.headers.first { $0.name.lowercased() == lower }?.name ?? field.name
                let nominatedOnly = guarded.nominated.contains(lower) && !guarded.isStaticallyProtected(lower)
                throw HTTPMutationError(code: nominatedOnly ? .nominatedHeader : .protectedHeader, field: .header(name: spelled))
            }
        }
        try validate(head: edited, body: body, limits: limits)
    }

    /// Full-body framing belongs to the transport. Validate raw syntax/budget first, then
    /// reconcile only CL/TE/Trailer for the ordinary protected-field comparison.
    package static func validateBodyEdit(original: HTTPMessageHead, edited: HTTPMessageHead,
                                        body: HTTPBodyDescriptor, limits: RulesLimits) throws {
        try validateBreakpointHeadBudget(edited, limits: limits)
        let framing: Set<String> = ["content-length", "transfer-encoding", "trailer"]
        let fields = edited.headers.filter { !framing.contains($0.name.lowercased()) }
            + original.headers.filter { framing.contains($0.name.lowercased()) }
        let reconciled: HTTPMessageHead
        switch edited {
        case .request(let target, _): reconciled = .request(target, headers: fields)
        case .response(let status, let reason, _): reconciled = .response(status: status, reason: reason, headers: fields)
        }
        try validateEdit(original: original, edited: reconciled, body: body, limits: limits)
    }

    // MARK: structure

    /// Structural validity of a final message head and its body description.
    public static func validate(
        head: HTTPMessageHead, body: HTTPBodyDescriptor, limits: RulesLimits = RulesLimits()
    ) throws {
        switch head {
        case .request(let target, _):
            if let error = targetError(target) { throw error }
        case .response(let status, let reason, _):
            guard (200...599).contains(status) else {
                throw HTTPMutationError(code: .invalidStatus, field: .status)
            }
            if let reason, !isValidValue(reason) {
                throw HTTPMutationError(code: .invalidReason, field: .reason)
            }
        }
        try validateBlock(head.headers, trailers: false, limits: limits)
        try validateFraming(head.headers)
        if let length = body.length, length < 0 {
            throw HTTPMutationError(code: .invalidContentLength, field: .body)
        }
        if body.changed, !body.complete {
            throw HTTPMutationError(code: .bodyIncomplete, field: .body)
        }
        try validateBlock(body.trailers, trailers: true, limits: limits)
    }

    /// Budget for a retained breakpoint head, including its structured metadata. Ordinary rule
    /// validation keeps its header-only budget; this charge is not an exact heap-size estimate.
    package static func validateBreakpointHeadBudget(
        _ head: HTTPMessageHead, limits: RulesLimits = RulesLimits()
    ) throws {
        var bytes = 0
        let metadata: [String]
        switch head {
        case .request(let target, _):
            metadata = [target.scheme, target.host, String(target.port), target.method, target.pathAndQuery]
        case .response(let status, let reason, _):
            metadata = [String(status), reason ?? ""]
        }
        for value in metadata {
            try chargeBytes(value.utf8.count, to: &bytes, limit: limits.headerBytes, field: .headers)
        }
        try validateBlock(head.headers, trailers: false, limits: limits, initialBytes: bytes)
    }

    /// Head and trailers after the edit decisions are applied.
    public struct NormalizedMessage: Sendable, Equatable {
        public var head: HTTPMessageHead
        public var trailers: [HeaderField]
    }

    /// Applies the consequences of a body replacement and validates the result. When the body
    /// changed: digest/integrity fields, `Trailer`, framing fields and (responses) `ETag` are
    /// removed, body trailers are dropped, and a present `Content-Encoding` needs an explicit choice.
    public static func normalize(
        head: HTTPMessageHead, body: HTTPBodyDescriptor, limits: RulesLimits = RulesLimits()
    ) throws -> NormalizedMessage {
        guard body.changed else {
            try validate(head: head, body: body, limits: limits)
            return NormalizedMessage(head: head, trailers: body.trailers)
        }
        let hasEncoding = head.headers.contains { $0.name.lowercased() == "content-encoding" && hasRealEncoding($0.value) }
        if hasEncoding, body.encodingChoice == .unchanged {
            throw HTTPMutationError(code: .encodingChoiceRequired, field: .contentEncoding)
        }
        var dropped = integrityFields.union(["trailer", "content-length", "transfer-encoding"])
        if case .response = head { dropped.insert("etag") }
        if body.encodingChoice == .removeEncoding { dropped.insert("content-encoding") }
        let headers = head.headers.filter { !dropped.contains($0.name.lowercased()) }
        let normalized: HTTPMessageHead
        switch head {
        case .request(let target, _): normalized = .request(target, headers: headers)
        case .response(let status, let reason, _): normalized = .response(status: status, reason: reason, headers: headers)
        }
        var settled = body
        settled.trailers = []
        try validate(head: normalized, body: settled, limits: limits)
        return NormalizedMessage(head: normalized, trailers: [])
    }

    public static func normalizeEdited(
        head: HTTPMessageHead, body: HTTPBodyDescriptor, limits: RulesLimits = RulesLimits()
    ) throws -> HTTPMessageHead {
        try normalize(head: head, body: body, limits: limits).head
    }

    /// True for a handshake that asks to switch protocols (`Connection: upgrade` plus `Upgrade`).
    public static func isUpgradeCandidate(_ headers: [HeaderField]) -> Bool {
        connectionTokens(headers).contains("upgrade") && !headers.values(for: "Upgrade").isEmpty
    }

    // MARK: pieces shared with the rest of the module

    static func isToken(_ text: String) -> Bool {
        !text.isEmpty && text.utf8.allSatisfy(isTokenByte)
    }

    static func isTokenByte(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
            || [33, 35, 36, 37, 38, 39, 42, 43, 45, 46, 94, 95, 96, 124, 126].contains(byte)
    }

    /// Visible text, tab and UTF-8; no CR, LF, NUL or other controls.
    static func isValidValue(_ text: String) -> Bool {
        text.utf8.allSatisfy { $0 == 9 || ($0 >= 32 && $0 != 127) }
    }

    static func validateBlock(_ fields: [HeaderField], trailers: Bool, limits: RulesLimits, initialBytes: Int = 0) throws {
        var bytes = initialBytes
        var count = 0
        for field in fields {
            func fail(_ code: HTTPMutationError.Code, value: Bool = false) -> HTTPMutationError {
                HTTPMutationError(code: code, field: trailers
                    ? .trailer(name: field.name) : (value ? .headerValue(name: field.name) : .header(name: field.name)))
            }
            if field.name.hasPrefix(":") { throw fail(.protectedHeader) }
            guard isToken(field.name) else { throw fail(.invalidHeaderName) }
            guard isValidValue(field.value) else { throw fail(.invalidHeaderValue, value: true) }
            if trailers {
                let lower = field.name.lowercased()
                if protectedNames.contains(lower) || lower.hasPrefix("proxy-") { throw fail(.protectedHeader) }
            }
            let nextCount = count.addingReportingOverflow(1)
            guard !nextCount.overflow, nextCount.partialValue <= limits.headerFields else {
                throw HTTPMutationError(code: .tooManyHeaderFields, field: trailers ? .trailers : .headers)
            }
            count = nextCount.partialValue
            let errorField: HTTPMutationError.Field = trailers ? .trailers : .headers
            try chargeBytes(field.name.utf8.count, to: &bytes, limit: limits.headerBytes, field: errorField)
            try chargeBytes(field.value.utf8.count, to: &bytes, limit: limits.headerBytes, field: errorField)
            try chargeBytes(32, to: &bytes, limit: limits.headerBytes, field: errorField)
        }
    }

    private static func chargeBytes(_ amount: Int, to bytes: inout Int, limit: Int, field: HTTPMutationError.Field) throws {
        let next = bytes.addingReportingOverflow(amount)
        guard !next.overflow, next.partialValue <= limit else {
            throw HTTPMutationError(code: .headerBlockTooLarge, field: field)
        }
        bytes = next.partialValue
    }

    /// Mirrors the transport's Content-Length and Connection token checks.
    private static func validateFraming(_ headers: [HeaderField]) throws {
        for field in headers where field.name.lowercased() == "connection" {
            for item in field.value.split(separator: ",", omittingEmptySubsequences: false) {
                guard isToken(item.trimmingCharacters(in: .whitespaces)) else {
                    throw HTTPMutationError(code: .invalidHeaderValue, field: .headerValue(name: field.name))
                }
            }
        }
        let lengths = headers.values(for: "Content-Length").flatMap { value in
            value.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        }
        for length in lengths {
            guard !length.isEmpty, length.utf8.allSatisfy({ (48...57).contains($0) }), UInt64(length) != nil,
                  length == lengths.first else {
                throw HTTPMutationError(code: .invalidContentLength, field: .contentLength)
            }
        }
        if !lengths.isEmpty, !headers.values(for: "Transfer-Encoding").isEmpty {
            throw HTTPMutationError(code: .invalidFraming, field: .contentLength)
        }
    }

    private static func hasRealEncoding(_ value: String) -> Bool {
        value.split(separator: ",").contains {
            let token = $0.trimmingCharacters(in: .whitespaces).lowercased()
            return !token.isEmpty && token != "identity"
        }
    }

    // MARK: target

    private static func targetError(_ target: HTTPMessageTarget) -> HTTPMutationError? {
        guard isToken(target.method) else { return HTTPMutationError(code: .invalidMethod, field: .method) }
        if target.method.uppercased() == "CONNECT" { return HTTPMutationError(code: .connectNotAllowed, field: .method) }
        guard ["http", "https"].contains(target.scheme.lowercased()) else {
            return HTTPMutationError(code: .invalidScheme, field: .scheme)
        }
        if let error = hostError(target.host) { return error }
        guard (1...65_535).contains(target.port) else { return HTTPMutationError(code: .invalidPort, field: .port) }
        return pathError(target.pathAndQuery, method: target.method)
    }

    /// Host without userinfo, fragment, path or port; IPv6 literals parsed (brackets optional).
    static func hostError(_ host: String) -> HTTPMutationError? {
        let field = HTTPMutationError.Field.host
        guard !host.isEmpty else { return HTTPMutationError(code: .invalidHost, field: field) }
        if host.contains("@") { return HTTPMutationError(code: .userinfoNotAllowed, field: field) }
        if host.contains("#") { return HTTPMutationError(code: .fragmentNotAllowed, field: field) }
        if host.contains(":") || host.contains("[") {
            var literal = Substring(host)
            if literal.hasPrefix("["), literal.hasSuffix("]") { literal = literal.dropFirst().dropLast() }
            var address = in6_addr()
            guard inet_pton(AF_INET6, String(literal), &address) == 1 else {
                return HTTPMutationError(code: .invalidHost, field: field)
            }
            return nil
        }
        let valid = host.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" }
        return valid ? nil : HTTPMutationError(code: .invalidHost, field: field)
    }

    /// Origin-form path and query (`OPTIONS *` allowed); no fragment, spaces or controls.
    static func pathError(_ path: String, method: String) -> HTTPMutationError? {
        let field = HTTPMutationError.Field.path
        if method.uppercased() == "OPTIONS", path == "*" { return nil }
        if path.contains("#") { return HTTPMutationError(code: .fragmentNotAllowed, field: field) }
        guard path.hasPrefix("/"), !path.utf8.contains(where: { $0 <= 32 || $0 == 127 }) else {
            return HTTPMutationError(code: .invalidPath, field: field)
        }
        return nil
    }

    // MARK: protection

    private struct Guarded {
        var nominated: Set<String>
        var upgrade: Bool

        func isStaticallyProtected(_ lower: String) -> Bool {
            lower.hasPrefix(":") || HTTPMutationValidator.protectedNames.contains(lower) || lower.hasPrefix("proxy-")
                || (upgrade && lower.hasPrefix("sec-websocket-"))
        }

        func isProtected(_ lower: String) -> Bool { isStaticallyProtected(lower) || nominated.contains(lower) }
    }

    /// Whether an "all keys" header edit must leave a field of that name alone: routing, framing,
    /// connection-managed, `Connection`-nominated and pseudo fields.
    package static func guardedFieldCheck(for headers: [HeaderField]) -> (String) -> Bool {
        let guarded = guardedNames(headers, upgradeCandidate: false)
        return { guarded.isProtected($0.lowercased()) }
    }

    private static func guardedNames(_ headers: [HeaderField], upgradeCandidate: Bool) -> Guarded {
        Guarded(nominated: connectionTokens(headers), upgrade: upgradeCandidate || isUpgradeCandidate(headers))
    }

    private static func protectionError(_ name: String, _ guarded: Guarded) -> HTTPMutationError? {
        let field = HTTPMutationError.Field.header(name: name)
        let lower = name.lowercased()
        if lower.hasPrefix(":") { return HTTPMutationError(code: .protectedHeader, field: field) }
        guard isToken(name) else { return HTTPMutationError(code: .invalidHeaderName, field: field) }
        if guarded.isStaticallyProtected(lower) { return HTTPMutationError(code: .protectedHeader, field: field) }
        if guarded.nominated.contains(lower) { return HTTPMutationError(code: .nominatedHeader, field: field) }
        return nil
    }

    private static func connectionTokens(_ headers: [HeaderField]) -> Set<String> {
        var tokens = Set<String>()
        for value in headers.values(for: "Connection") {
            for item in value.split(separator: ",") {
                let token = item.trimmingCharacters(in: .whitespaces).lowercased()
                if !token.isEmpty { tokens.insert(token) }
            }
        }
        return tokens
    }
}
