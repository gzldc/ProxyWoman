import FlowStore
import Foundation
import Localization
import RulesEngine

/// Why a draft made from a captured flow has no body.
public enum ComposeBodyOmission: Equatable, Sendable {
    /// The captured original request is not eligible (same rules as Replay).
    case replay(ReplayBlockReason)
    /// The capture was eligible but can no longer be read (for example, the record was cleared).
    case unreadable
    /// The capture was whole but copying it into a managed asset did not finish (the record was
    /// cleared meanwhile, the asset store is full, or the import was cancelled).
    case importFailed

    public var localizationKey: String {
        switch self {
        case .replay(let reason): reason.localizationKey
        case .unreadable: "compose.body.unreadable"
        case .importFailed: "compose.body.importFailed"
        }
    }

    public var localizedDescription: String { L10n.string(localizationKey) }
}

/// A complete captured request body that is too big (or on disk) to read inline and is waiting to
/// be copied, chunk by chunk, into a managed asset. Only this description is held.
public struct CapturedBodyImport: Sendable, Equatable {
    public var slice: HTTPBodySlice
    public var displayName: String
    public var size: Int64

    public init(slice: HTTPBodySlice, displayName: String, size: Int64) {
        self.slice = slice
        self.displayName = displayName
        self.size = size
    }
}

public enum ComposeBodyMode: String, CaseIterable, Identifiable, Sendable {
    case none, text, hex, file

    public var id: Self { self }
    public var localizationKey: String {
        switch self {
        case .none: "compose.body.mode.none"
        case .text: "compose.body.mode.text"
        case .hex: "compose.body.mode.hex"
        case .file: "compose.body.mode.file"
        }
    }
}

public enum ComposeDraftBody: Equatable, Sendable {
    case none
    /// Sent as its UTF-8 bytes.
    case text(String)
    /// Hex digits, whitespace ignored; sent as the bytes they spell.
    case hex(String)
    /// The captured body could not be copied. The draft cannot be sent until the user picks
    /// another body explicitly: a truncated or missing capture is never sent as if it were whole.
    case omitted(ComposeBodyOmission)
    /// A managed copy of a file, streamed when sent. It is not in memory (`bytes` is nil) and can
    /// only be entered by attaching a file, never by converting another body.
    case file(ComposeBodyFile)
    /// A captured body still to be copied into a managed asset: nothing is sent until the copy is
    /// done (it then becomes `.file`) and it is never in memory (`bytes` is nil).
    case pending(CapturedBodyImport)

    /// Nil while the body is omitted or pending: no mode is chosen yet.
    public var mode: ComposeBodyMode? {
        switch self {
        case .none: ComposeBodyMode.none
        case .text: .text
        case .hex: .hex
        case .file: .file
        case .omitted, .pending: nil
        }
    }

    /// The same bytes in `mode`, or nil when that would lose or invent bytes (invalid hex, or
    /// bytes that are not UTF-8 shown as text). An omitted body starts empty in any mode.
    func converted(to mode: ComposeBodyMode) -> ComposeDraftBody? {
        if self.mode == mode { return self }
        // A file is only ever attached, so no other body converts to one.
        if mode == .file { return nil }
        // An omitted or pending body or a file starts empty in any mode (nothing is read).
        switch self {
        case .omitted, .pending, .file: return mode == .none ? ComposeDraftBody.none : mode == .text ? .text("") : .hex("")
        default: break
        }
        switch mode {
        case .file: return nil
        case .none: return ComposeDraftBody.none
        case .hex: return bytes.map { .hex(Self.hexText($0)) }
        case .text:
            guard let bytes else { return nil }
            let text = String(decoding: bytes, as: UTF8.self)
            return Data(text.utf8) == bytes ? .text(text) : nil
        }
    }

    /// The localized reason of an omitted body.
    public var omissionReason: String? {
        if case .omitted(let reason) = self { reason.localizedDescription } else { nil }
    }

    /// The bytes to send; nil when the body is omitted or the hex text is not valid.
    var bytes: Data? {
        switch self {
        case .none: Data()
        case .text(let text): Data(text.utf8)
        case .hex(let text): Self.parseHex(text)
        case .omitted, .file, .pending: nil
        }
    }

    /// The attached file, if the body is one.
    public var file: ComposeBodyFile? {
        if case .file(let file) = self { file } else { nil }
    }

    static func parseHex(_ text: String) -> Data? {
        var data = Data()
        var high: UInt8?
        for byte in text.utf8 {
            if byte == 32 || byte == 9 || byte == 10 || byte == 13 { continue }
            guard let nibble = hexValue(byte) else { return nil }
            if let first = high {
                data.append(first << 4 | nibble)
                high = nil
            } else {
                high = nibble
            }
        }
        return high == nil ? data : nil
    }

    static func hexText(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: byte - 48
        case 65...70: byte - 55
        case 97...102: byte - 87
        default: nil
        }
    }
}

/// The send options. Rules are off unless switched on (design RC-09); HTTP version is automatic
/// unless restricted to HTTP/1.1.
public struct ComposeDraftPolicy: Equatable, Sendable {
    public static let timeoutRange = 1...600

    public var applyRules: Bool
    public var timeoutSeconds: Int
    public var http1Only: Bool

    public init(applyRules: Bool = false, timeoutSeconds: Int = 60, http1Only: Bool = false) {
        self.applyRules = applyRules
        self.timeoutSeconds = timeoutSeconds
        self.http1Only = http1Only
    }
}

/// One problem of a draft. Errors keep it from being sent; warnings only inform.
public struct ComposeDraftIssue: Hashable, Sendable {
    public enum Code: String, CaseIterable, Sendable, Error {
        case unsupportedScheme, invalidURL, userinfoNotAllowed, invalidPercentEncoding
        case invalidMethod, connectNotAllowed
        case invalidHeaderName, invalidHeaderValue, headersTooLarge, upgradeNotSupported
        case invalidHex, bodyOmitted, bodyImporting, timeoutOutOfRange
        case missingContentType, bodyNotJSON, hostHeaderMismatch

        public var severity: Severity {
            switch self {
            case .missingContentType, .bodyNotJSON, .hostHeaderMismatch: .warning
            default: .error
            }
        }

        public var localizationKey: String {
            switch self {
            case .unsupportedScheme: "compose.issue.unsupportedScheme"
            case .invalidURL: "compose.issue.invalidURL"
            case .userinfoNotAllowed: "compose.issue.userinfoNotAllowed"
            case .invalidPercentEncoding: "compose.issue.invalidPercentEncoding"
            case .invalidMethod: "compose.issue.invalidMethod"
            case .connectNotAllowed: "compose.issue.connectNotAllowed"
            case .invalidHeaderName: "compose.issue.invalidHeaderName"
            case .invalidHeaderValue: "compose.issue.invalidHeaderValue"
            case .headersTooLarge: "compose.issue.headersTooLarge"
            case .upgradeNotSupported: "compose.issue.upgradeNotSupported"
            case .invalidHex: "compose.issue.invalidHex"
            case .bodyOmitted: "compose.issue.bodyOmitted"
            case .bodyImporting: "compose.issue.bodyImporting"
            case .timeoutOutOfRange: "compose.issue.timeoutOutOfRange"
            case .missingContentType: "compose.issue.missingContentType"
            case .bodyNotJSON: "compose.issue.bodyNotJSON"
            case .hostHeaderMismatch: "compose.issue.hostHeaderMismatch"
            }
        }
    }

    public enum Field: Hashable, Sendable {
        case method, url, headers, body, policy
        case header(UUID)
    }

    public enum Severity: Sendable {
        case error, warning
    }

    public let code: Code
    public let field: Field

    public init(code: Code, field: Field) {
        self.code = code
        self.field = field
    }

    public var severity: Severity { code.severity }
    public var localizedDescription: String { L10n.string(code.localizationKey) }
}

/// What the Compose window edits. `url` is the text of the URL field and the only source of the
/// query table: table edits rewrite exactly their own segment of it (see `EditableQuery`).
/// Nothing here touches the network; a draft is not persisted.
public struct ComposeDraft: Equatable, Sendable {
    public let id: UUID
    /// The captured flow this draft was made from (provenance of the sends).
    public var sourceFlowID: Int?
    public var method: String
    public private(set) var url: String
    public private(set) var query: EditableQuery
    /// In order, duplicates kept.
    public var headers: [HeaderFieldRow]
    public var body: ComposeDraftBody
    public var policy: ComposeDraftPolicy

    public init(id: UUID = UUID(), sourceFlowID: Int? = nil, method: String = "GET", url: String = "",
                headers: [HeaderFieldRow] = [], body: ComposeDraftBody = .none, policy: ComposeDraftPolicy = ComposeDraftPolicy()) {
        self.id = id
        self.sourceFlowID = sourceFlowID
        self.method = method
        self.url = url
        self.query = EditableQuery(raw: String(URLText(url).query ?? ""))
        self.headers = headers
        self.body = body
        self.policy = policy
    }

    /// A draft of the captured original request — the same boundary `ReplayEligibility` judges:
    /// the downstream request snapshot when there is one, the legacy request fields otherwise,
    /// never what was sent upstream after rules. A small in-memory body is read; a complete body
    /// that is on disk or over 1 MiB becomes `.pending` (copied later through a read lease); any
    /// other body is omitted with its reason. Nothing is read from disk here.
    public init(from flow: Flow, variant: ComposeRequestVariant = .original) {
        if variant == .effective, let upstream = flow.messages[.upstreamRequest], let target = upstream.target {
            // What was really sent to the origin: its target and headers (transport-generated
            // fields left out; the transport makes them again) and its body, judged by the same
            // rules as the original body.
            let headers = Self.strippingTransportFields(upstream.headers, target: target)
            self.init(sourceFlowID: flow.id, method: target.method, url: Self.url(of: target),
                      headers: headers.map { HeaderFieldRow(name: $0.name, value: $0.value) },
                      body: Self.capturedBody(of: flow, boundary: .upstreamRequest))
            return
        }
        let (target, headers) = Self.originalRequest(of: flow)
        self.init(sourceFlowID: flow.id, method: target.method, url: Self.url(of: target),
                  headers: headers.map { HeaderFieldRow(name: $0.name, value: $0.value) },
                  body: Self.capturedBody(of: flow, boundary: .downstreamRequest))
    }

    /// The target and headers of the captured original request (snapshot first, legacy fields otherwise).
    static func originalRequest(of flow: Flow) -> (HTTPMessageTarget, [HeaderField]) {
        let original = flow.messages[.downstreamRequest]
        let target = original?.target
            ?? HTTPMessageTarget(scheme: flow.scheme, host: flow.host, port: flow.port, method: flow.method, pathAndQuery: flow.path)
        return (target, original?.headers ?? flow.requestHeaders)
    }

    /// Fields the transport writes by itself. `Host` goes only when it names the target's own
    /// authority; every other field keeps its place and its duplicates.
    static func strippingTransportFields(_ headers: [HeaderField], target: HTTPMessageTarget) -> [HeaderField] {
        let bracketed = target.host.contains(":") && !target.host.hasPrefix("[") ? "[\(target.host)]" : target.host
        let isDefaultPort = (target.scheme == "http" && target.port == 80) || (target.scheme == "https" && target.port == 443)
        var authorities = ["\(bracketed):\(target.port)".lowercased()]
        if isDefaultPort { authorities.append(bracketed.lowercased()) }
        return headers.filter { field in
            let name = field.name.lowercased()
            if transportFieldNames.contains(name) { return false }
            if name == "host" {
                return !authorities.contains(field.value.trimmingCharacters(in: .whitespaces).lowercased())
            }
            return true
        }
    }

    private static let transportFieldNames: Set<String> = [
        "content-length", "transfer-encoding", "connection", "keep-alive", "proxy-connection",
    ]

    /// Whether `other` would send and show the same thing: id, provenance and the query table
    /// (derived from the URL text, with row identities of its own) are not compared.
    func hasSameContent(as other: ComposeDraft) -> Bool {
        method == other.method && url == other.url && body == other.body && policy == other.policy
            && headers.map { [$0.name, $0.value] } == other.headers.map { [$0.name, $0.value] }
    }

    // MARK: URL and query table

    /// The URL field changed: the table is read again from its bytes, rows keeping their places.
    public mutating func setURL(_ text: String) {
        url = text
        query = EditableQuery(raw: String(URLText(text).query ?? ""), reusing: query.rows)
    }

    /// The name cell of a table row changed: only that name is rewritten (encoded); its value and
    /// the rest of the URL are left byte for byte.
    public mutating func setQueryName(_ id: UUID, _ name: String) {
        query.setName(id, name)
        rebuildURL(keepsQuestionMark: true)
    }

    /// The value cell of a table row changed: only that value is rewritten; nil removes the `=`.
    public mutating func setQueryValue(_ id: UUID, _ value: String?) {
        query.setValue(id, value)
        rebuildURL(keepsQuestionMark: true)
    }

    @discardableResult
    public mutating func appendQueryRow(name: String, value: String?) -> UUID {
        let id = query.appendRow(name: name, value: value)
        rebuildURL(keepsQuestionMark: true)
        return id
    }

    public mutating func removeQueryRow(_ id: UUID) {
        query.removeRow(id)
        rebuildURL(keepsQuestionMark: !query.rawValue.isEmpty)
    }

    private mutating func rebuildURL(keepsQuestionMark: Bool) {
        let parts = URLText(url)
        let raw = query.rawValue
        url = String(parts.base) + (keepsQuestionMark || !raw.isEmpty ? "?" + raw : "") + String(parts.fragment ?? "")
    }

    // MARK: Body

    public func canSwitchBody(to mode: ComposeBodyMode) -> Bool {
        body.converted(to: mode) != nil
    }

    /// Converts the body to `mode`, keeping its bytes; false (and unchanged) when it cannot.
    @discardableResult
    public mutating func switchBody(to mode: ComposeBodyMode) -> Bool {
        guard let converted = body.converted(to: mode) else { return false }
        body = converted
        return true
    }

    // MARK: Validation

    /// Errors first (method, URL, headers, body, options), then warnings.
    public func validate() -> [ComposeDraftIssue] {
        var errors: [ComposeDraftIssue] = []
        var warnings: [ComposeDraftIssue] = []
        if !HTTPTokens.isToken(method) {
            errors.append(.init(code: .invalidMethod, field: .method))
        } else if method.uppercased() == "CONNECT" {
            errors.append(.init(code: .connectNotAllowed, field: .method))
        }
        let target = WireTarget.parse(url)
        if case .failure(let code) = target { errors.append(.init(code: code, field: .url)) }

        var headerError = false
        for row in headers {
            if !HTTPTokens.isToken(row.name) {
                errors.append(.init(code: .invalidHeaderName, field: .header(row.id)))
                headerError = true
            } else if !HTTPTokens.isFieldValue(row.value) {
                errors.append(.init(code: .invalidHeaderValue, field: .header(row.id)))
                headerError = true
            }
        }
        let fields = headers.map { HeaderField(name: $0.name, value: $0.value) }
        if HTTPMutationValidator.isUpgradeCandidate(fields) {
            errors.append(.init(code: .upgradeNotSupported, field: .headers))
        } else if !headerError, errors.isEmpty, case .success(let wire) = target {
            // The rest of the proxy's own request validation (header block size, Connection
            // tokens), with framing left to the transport exactly as the Compose service does.
            let unframed = fields.filter { !["content-length", "transfer-encoding"].contains($0.name.lowercased()) }
            do {
                try HTTPMutationValidator.validate(
                    head: .request(HTTPMessageTarget(scheme: wire.scheme, host: wire.host, port: wire.port, method: method,
                                                     pathAndQuery: wire.pathAndQuery), headers: unframed),
                    body: HTTPBodyDescriptor(length: nil, complete: true, changed: false))
            } catch let error as HTTPMutationError {
                errors.append(Self.issue(for: error))
            } catch {
                errors.append(.init(code: .invalidURL, field: .url))
            }
        }

        switch body {
        case .omitted: errors.append(.init(code: .bodyOmitted, field: .body))
        case .pending: errors.append(.init(code: .bodyImporting, field: .body))
        case .hex where body.bytes == nil: errors.append(.init(code: .invalidHex, field: .body))
        default: break
        }
        if !ComposeDraftPolicy.timeoutRange.contains(policy.timeoutSeconds) {
            errors.append(.init(code: .timeoutOutOfRange, field: .policy))
        }

        let contentType = fields.value(for: "Content-Type")?.lowercased()
        // A file body counts as non-empty when it has bytes (its content is never read here).
        let bodyBytes = body.bytes
        if let bytes = bodyBytes, !bytes.isEmpty {
            if contentType == nil {
                warnings.append(.init(code: .missingContentType, field: .body))
            } else if let contentType, contentType.contains("json"), case .text = body,
                      (try? JSONSerialization.jsonObject(with: bytes, options: .fragmentsAllowed)) == nil {
                warnings.append(.init(code: .bodyNotJSON, field: .body))
            }
        } else if let file = body.file, file.size > 0, contentType == nil {
            warnings.append(.init(code: .missingContentType, field: .body))
        }
        if case .success(let wire) = target, let host = fields.value(for: "Host"), !wire.accepts(hostHeader: host) {
            warnings.append(.init(code: .hostHeaderMismatch, field: .headers))
        }
        return errors + warnings
    }

    /// The request a Send freezes, or nil while the draft has an error. Its URL is the wire form:
    /// the fragment is dropped and each byte a URL cannot carry (space, non-ASCII, `|`, …) is
    /// percent-encoded on its own; every other byte, existing escapes included, is unchanged.
    public func outgoingRequest(id: UUID) -> ComposeOutgoingRequest? {
        guard !validate().contains(where: { $0.severity == .error }), case .success(let wire) = WireTarget.parse(url) else { return nil }
        let bodyAsset = body.file
        guard let bytes = bodyAsset == nil ? body.bytes : Data() else { return nil }
        return ComposeOutgoingRequest(
            id: id, method: method, url: wire.url, headers: headers.map { HeaderField(name: $0.name, value: $0.value) },
            body: bytes, sourceFlowID: sourceFlowID, applyRules: policy.applyRules, timeoutSeconds: policy.timeoutSeconds,
            http1Only: policy.http1Only, bodyAsset: bodyAsset)
    }

    private static func issue(for error: HTTPMutationError) -> ComposeDraftIssue {
        switch error.code {
        case .invalidMethod: .init(code: .invalidMethod, field: .method)
        case .connectNotAllowed: .init(code: .connectNotAllowed, field: .method)
        case .invalidScheme: .init(code: .unsupportedScheme, field: .url)
        case .userinfoNotAllowed: .init(code: .userinfoNotAllowed, field: .url)
        case .headerBlockTooLarge, .tooManyHeaderFields: .init(code: .headersTooLarge, field: .headers)
        case .invalidHeaderName, .protectedHeader: .init(code: .invalidHeaderName, field: .headers)
        case .invalidHeaderValue: .init(code: .invalidHeaderValue, field: .headers)
        default: .init(code: .invalidURL, field: .url)
        }
    }

    // MARK: From a flow

    static func url(of target: HTTPMessageTarget) -> String {
        let host = target.host.contains(":") && !target.host.hasPrefix("[") ? "[\(target.host)]" : target.host
        let isDefaultPort = (target.scheme == "http" && target.port == 80) || (target.scheme == "https" && target.port == 443)
        return "\(target.scheme)://\(host)\(isDefaultPort ? "" : ":\(target.port)")\(target.pathAndQuery)"
    }

    /// The name a captured body gets as a managed asset (a file name, not text for the user).
    static let capturedBodyName = "request-body.bin"

    private static func capturedBody(of flow: Flow, boundary: HTTPMessageBoundary) -> ComposeDraftBody {
        switch ComposeImportEligibility.evaluate(flow: flow, boundary: boundary) {
        case .blocked(let reason): return .omitted(.replay(reason))
        case .importable(let slice):
            // Not read here: the window copies it through a read lease after it opens.
            return .pending(CapturedBodyImport(slice: slice, displayName: capturedBodyName, size: Int64(slice.count)))
        case .inline: break
        }
        let data: Data
        do {
            // Inline bodies are complete, in memory and at most 1 MiB: no file is opened.
            if let message = flow.messages[boundary] {
                data = try message.body?.load() ?? Data()
            } else {
                data = try flow.requestBody?.load() ?? Data()
            }
        } catch {
            return .omitted(.unreadable)
        }
        if data.isEmpty { return .none }
        let text = String(decoding: data, as: UTF8.self)
        return Data(text.utf8) == data ? .text(text) : .hex(ComposeDraftBody.hexText(data))
    }
}

// MARK: - Entries

/// Why a flow cannot be edited or replayed in Compose.
public enum ComposeEntryBlock: Equatable, Sendable {
    /// A CONNECT tunnel is not a request that can be sent again.
    case tunnel
    /// A WebSocket (or other Upgrade) handshake cannot be sent from Compose.
    case upgrade
    /// Replay only: the captured body cannot be sent as it was.
    case body(ReplayBlockReason)
    /// The request actually sent upstream is not available, or is the same as the original.
    case noEffectiveRequest

    /// The cases with their own text (body reasons reuse the Replay texts).
    public static let staticCases: [ComposeEntryBlock] = [.tunnel, .upgrade, .noEffectiveRequest]

    public var localizationKey: String {
        switch self {
        case .tunnel: "compose.entry.blocked.tunnel"
        case .upgrade: "compose.entry.blocked.upgrade"
        case .body(let reason): reason.localizationKey
        case .noEffectiveRequest: "compose.entry.blocked.noEffective"
        }
    }

    public var localizedDescription: String { L10n.string(localizationKey) }
}

/// Which request an Edit starts from: the captured original (default), or the one the proxy
/// actually sent to the origin after rules, Map Remote and cache changes (spec C6). Replay and
/// Repeat always use the original.
public enum ComposeRequestVariant: String, Sendable, Equatable, CaseIterable {
    case original, effective
}

/// The flow-table entries. Edit opens any plain HTTP request (an ineligible body is left out with
/// its reason); Replay sends the captured original request once and needs its whole body.
public enum ComposeEntry {
    public static func edit(_ flow: Flow, variant: ComposeRequestVariant = .original) -> ComposeEntryBlock? {
        if flow.method == "CONNECT" || flow.state == .tunnel { return .tunnel }
        let headers = flow.messages[.downstreamRequest]?.headers ?? flow.requestHeaders
        if HTTPMutationValidator.isUpgradeCandidate(headers) { return .upgrade }
        if variant == .effective, !effectiveAvailable(flow) { return .noEffectiveRequest }
        return nil
    }

    /// Whether the flow has a snapshot of the request sent upstream that differs from the original
    /// one in its target, its headers (transport-generated fields left out) or its body size. A flow
    /// that never reached an origin (blocked, answered locally) has none.
    /// Headers as compared between the original and the upstream request: transport fields and the
    /// ones an HTTP/1 <-> HTTP/2 translation drops or rewrites (`te`, `upgrade`) left out, names
    /// lowercased (HTTP/2 lowercases them), and several `cookie` fields read as one joined with
    /// "; " (HTTP/2 splits it, HTTP/1 joins it). Used only to decide availability, never for drafts.
    private static func comparableFields(_ headers: [HeaderField], target: HTTPMessageTarget) -> [[String]] {
        var result: [[String]] = []
        var cookieIndex: Int?
        for field in ComposeDraft.strippingTransportFields(headers, target: target) {
            let name = field.name.lowercased()
            if name == "te" || name == "upgrade" { continue }
            if name == "cookie" {
                if let index = cookieIndex {
                    result[index][1] += "; " + field.value
                } else {
                    cookieIndex = result.count
                    result.append([name, field.value])
                }
            } else {
                result.append([name, field.value])
            }
        }
        return result
    }

    public static func effectiveAvailable(_ flow: Flow) -> Bool {
        guard let upstream = flow.messages[.upstreamRequest], let upstreamTarget = upstream.target else { return false }
        let (target, headers) = ComposeDraft.originalRequest(of: flow)
        if upstreamTarget != target { return true }
        if comparableFields(headers, target: target) != comparableFields(upstream.headers, target: upstreamTarget) { return true }
        let originalSize = flow.messages[.downstreamRequest]?.observedBytes ?? UInt64(max(0, flow.bytesSent))
        return upstream.observedBytes != originalSize
    }

    public static func replay(_ flow: Flow) -> ComposeEntryBlock? {
        if let block = edit(flow) { return block }
        if case .failure(let reason) = ReplayEligibility.evaluate(flow: flow) { return .body(reason) }
        return nil
    }
}

// MARK: - Parsing helpers

/// `base[?query][#fragment]` of URL text, split without decoding anything.
struct URLText {
    let base: Substring
    let query: Substring?
    let fragment: Substring?

    init(_ text: String) {
        let hash = text.firstIndex(of: "#")
        fragment = hash.map { text[$0...] }
        let beforeFragment = text[..<(hash ?? text.endIndex)]
        if let mark = beforeFragment.firstIndex(of: "?") {
            base = beforeFragment[..<mark]
            query = beforeFragment[beforeFragment.index(after: mark)...]
        } else {
            base = beforeFragment
            query = nil
        }
    }
}

/// The parts of a draft URL the proxy needs, and its wire form.
struct WireTarget {
    let scheme: String
    let host: String
    let port: Int
    let authority: Substring
    /// Origin-form, query included, minimally encoded.
    let pathAndQuery: String

    var url: String { scheme + "://" + authority + pathAndQuery }

    /// Whether a Host header names this target (case-insensitive; the default port may be explicit).
    func accepts(hostHeader: String) -> Bool {
        let bracketed = host.contains(":") ? "[\(host)]" : host
        let defaultPort = scheme == "https" ? 443 : 80
        var accepted = ["\(bracketed):\(port)"]
        if port == defaultPort { accepted.append(bracketed) }
        let value = hostHeader.trimmingCharacters(in: .whitespaces).lowercased()
        return accepted.contains { $0.lowercased() == value }
    }

    static func parse(_ text: String) -> Result<WireTarget, ComposeDraftIssue.Code> {
        guard let separator = text.range(of: "://") else { return .failure(.unsupportedScheme) }
        let scheme = text[..<separator.lowerBound]
        guard ["http", "https"].contains(scheme.lowercased()) else { return .failure(.unsupportedScheme) }
        let rest = text[separator.upperBound...]
        let authorityEnd = rest.firstIndex { $0 == "/" || $0 == "?" || $0 == "#" } ?? rest.endIndex
        let authority = rest[..<authorityEnd]
        if authority.contains("@") { return .failure(.userinfoNotAllowed) }
        guard let (host, port) = hostAndPort(authority, defaultPort: scheme.lowercased() == "https" ? 443 : 80) else {
            return .failure(.invalidURL)
        }
        let parts = URLText(String(rest[authorityEnd...]))
        let path = parts.base.isEmpty ? "/" : String(parts.base)
        let target = path + (parts.query.map { "?" + $0 } ?? "")
        guard hasValidEscapes(target) else { return .failure(.invalidPercentEncoding) }
        return .success(WireTarget(scheme: String(scheme), host: host, port: port, authority: authority,
                                   pathAndQuery: encodeForWire(target)))
    }

    private static func hostAndPort(_ authority: Substring, defaultPort: Int) -> (String, Int)? {
        var host = authority
        var portText: Substring?
        if authority.hasPrefix("[") {
            guard let close = authority.firstIndex(of: "]") else { return nil }
            host = authority[authority.index(after: authority.startIndex)..<close]
            let after = authority[authority.index(after: close)...]
            if !after.isEmpty {
                guard after.hasPrefix(":") else { return nil }
                portText = after.dropFirst()
            }
        } else if let colon = authority.lastIndex(of: ":") {
            host = authority[..<colon]
            portText = authority[authority.index(after: colon)...]
        }
        guard !host.isEmpty else { return nil }
        guard let portText else { return (String(host), defaultPort) }
        guard !portText.isEmpty, portText.allSatisfy(\.isASCII), portText.allSatisfy(\.isNumber),
              let port = Int(portText), (1...65_535).contains(port) else { return nil }
        return (String(host), port)
    }

    private static func hasValidEscapes(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        var index = 0
        while index < bytes.count {
            if bytes[index] == 37 {
                guard index + 2 < bytes.count, isHex(bytes[index + 1]), isHex(bytes[index + 2]) else { return false }
                index += 3
            } else {
                index += 1
            }
        }
        return true
    }

    private static func isHex(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
    }

    /// RFC 3986 characters of a path and query (`%` is valid here: escapes were checked).
    private static let wireBytes: Set<UInt8> =
        Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~!$&'()*+,;=:@/?%".utf8)

    private static func encodeForWire(_ text: String) -> String {
        var result = ""
        for byte in text.utf8 {
            if wireBytes.contains(byte) {
                result.unicodeScalars.append(UnicodeScalar(byte))
            } else {
                result += String(format: "%%%02X", byte)
            }
        }
        return result
    }
}

/// RFC 9110 token and field-value checks (the same rules the proxy validates with).
enum HTTPTokens {
    static func isToken(_ text: String) -> Bool {
        !text.isEmpty && text.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
                || [33, 35, 36, 37, 38, 39, 42, 43, 45, 46, 94, 95, 96, 124, 126].contains(byte)
        }
    }

    static func isFieldValue(_ text: String) -> Bool {
        text.utf8.allSatisfy { $0 == 9 || ($0 >= 32 && $0 != 127) }
    }
}
