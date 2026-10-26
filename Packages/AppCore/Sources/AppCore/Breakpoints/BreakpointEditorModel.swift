import FlowStore
import Foundation
import Observation
import RulesEngine
import Viewers

/// Which form of an encoded (`Content-Encoding`) body the editor shows. Decoded is the default;
/// the raw bytes are shown as read-only hex.
public enum HTTPBoundarySelection: String, Sendable, CaseIterable, Identifiable {
    case decoded, raw
    public var id: String { rawValue }
    public var localizationKey: String {
        switch self {
        case .decoded: "breakpoints.body.decoded"
        case .raw: "breakpoints.body.raw"
        }
    }
}

/// What the body area shows for a ticket.
public enum BreakpointBodyContent: Equatable, Sendable {
    /// Paused at the head: nothing was read; continuing streams the body unchanged.
    case streaming
    case collecting
    /// The announced length is over the collection limit: it can only stream unchanged.
    case tooLargeToCollect
    case loading
    /// Editable UTF-8 text in `bodyText`.
    case text
    /// Text over the per-editor limit: `bodyText` holds the first part; kept unchanged.
    case readOnlyText(truncated: Bool)
    /// Binary, not UTF-8, or not decodable: kept unchanged.
    case hex(Data, truncated: Bool)
    /// The editors' shared memory is used up: not loaded, kept unchanged.
    case budgetExhausted
    case loadFailed

    /// The explanation shown with this content (format arguments see `BreakpointEditorModel.bodyMessage`).
    public var messageKey: String? {
        switch self {
        case .streaming: "breakpoints.body.streaming"
        case .collecting: "breakpoints.body.collecting"
        case .tooLargeToCollect: "breakpoints.body.tooLargeToCollect"
        case .loading: "breakpoints.body.loading"
        case .text: nil
        case .readOnlyText: "breakpoints.body.readOnlyTooLarge"
        case .hex: "breakpoints.body.hexReadOnly"
        case .budgetExhausted: "breakpoints.body.budgetExhausted"
        case .loadFailed: "breakpoints.body.loadFailed"
        }
    }

    public static let messageKeys = [
        "breakpoints.body.streaming", "breakpoints.body.collecting", "breakpoints.body.tooLargeToCollect",
        "breakpoints.body.loading", "breakpoints.body.readOnlyTooLarge", "breakpoints.body.hexReadOnly",
        "breakpoints.body.budgetExhausted", "breakpoints.body.loadFailed", "breakpoints.body.decodedNotice",
    ]
}

/// The editor area an error belongs to.
public enum BreakpointEditorField: Hashable, Sendable {
    case method, url, status, reason, headers, body, message
    case header(UUID)
}

/// Why an edit cannot be sent; whole localized sentences.
public enum BreakpointEditIssue: String, CaseIterable, Sendable {
    case invalidMethod, invalidURL, invalidStatus, invalidReason, invalidHeader, protectedHeader
    case headerBlockTooLarge, invalidFraming, encodingChoiceRequired, bodyTooLarge
    /// The decoded text was edited but the raw bytes are shown: Continue would send what is not on screen.
    case decodedEditNotShown
    /// The picked file could not be used as the body (not a regular file, too large, unreadable).
    case replacementFileUnavailable
    /// The proxy did not accept an edit that looked valid here (for example the ticket moved on).
    case rejected

    public var localizationKey: String {
        switch self {
        case .invalidMethod: "breakpoints.issue.invalidMethod"
        case .invalidURL: "breakpoints.issue.invalidURL"
        case .invalidStatus: "breakpoints.issue.invalidStatus"
        case .invalidReason: "breakpoints.issue.invalidReason"
        case .invalidHeader: "breakpoints.issue.invalidHeader"
        case .protectedHeader: "breakpoints.issue.protectedHeader"
        case .headerBlockTooLarge: "breakpoints.issue.headerBlockTooLarge"
        case .invalidFraming: "breakpoints.issue.invalidFraming"
        case .encodingChoiceRequired: "breakpoints.issue.encodingChoiceRequired"
        case .bodyTooLarge: "breakpoints.issue.bodyTooLarge"
        case .decodedEditNotShown: "breakpoints.issue.decodedEditNotShown"
        case .replacementFileUnavailable: "breakpoints.issue.replacementFileUnavailable"
        case .rejected: "breakpoints.issue.rejected"
        }
    }

    init(_ code: HTTPMutationError.Code) {
        switch code {
        case .invalidHeaderName, .invalidHeaderValue: self = .invalidHeader
        case .protectedHeader, .nominatedHeader: self = .protectedHeader
        case .headerBlockTooLarge, .tooManyHeaderFields: self = .headerBlockTooLarge
        case .invalidMethod, .connectNotAllowed: self = .invalidMethod
        case .invalidScheme, .invalidHost, .userinfoNotAllowed, .fragmentNotAllowed, .invalidPort, .invalidPath:
            self = .invalidURL
        case .invalidStatus: self = .invalidStatus
        case .invalidReason: self = .invalidReason
        case .invalidContentLength, .invalidFraming: self = .invalidFraming
        case .encodingChoiceRequired: self = .encodingChoiceRequired
        case .bodyIncomplete, .messageKindMismatch: self = .rejected
        }
    }
}

/// The edit of one paused message: request line or status, ordered headers and (once the whole
/// body was read) the body. Body bytes are loaded within `HTTPEditorMemoryBudget`; anything too
/// large, binary or undecodable is shown read-only and continues unchanged.
@MainActor @Observable public final class BreakpointEditorModel: Identifiable {
    public let id: UUID
    public private(set) var ticket: BreakpointTicketSnapshot
    public var method: String
    public var url: String
    public var status: String
    public var reason: String
    /// Ordered; repeated names stay repeated. Rows with an empty name and value are ignored.
    public var headers: [HeaderFieldRow]
    public var bodyText = ""
    public var boundary: HTTPBoundarySelection = .decoded
    public private(set) var body: BreakpointBodyContent
    public private(set) var fieldErrors: [BreakpointEditorField: BreakpointEditIssue] = [:]
    /// The body carries a real `Content-Encoding`.
    public private(set) var isEncoded = false
    /// The file chosen to replace the body (the proxy holds its copy); sent instead of any text edit.
    public private(set) var replacementFile: BreakpointImportedBody?
    public private(set) var isImportingFile = false
    public let limits: RulesLimits

    @ObservationIgnored private let client: any BreakpointClient
    @ObservationIgnored private let budget: HTTPEditorMemoryBudget
    @ObservationIgnored private var reservation: HTTPEditorReservation?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var originalText: String?
    @ObservationIgnored private var rawBody: Data?
    @ObservationIgnored private var rawTruncated = false
    @ObservationIgnored private var initialHead: HTTPMessageHead
    /// Method, URL, status and reason as the ticket arrived.
    @ObservationIgnored private var initialLine: [String] = []
    @ObservationIgnored private(set) var isClosed = false

    public init(ticket: BreakpointTicketSnapshot, client: any BreakpointClient, budget: HTTPEditorMemoryBudget,
                limits: RulesLimits = RulesLimits()) {
        id = ticket.id
        self.ticket = ticket
        self.client = client
        self.budget = budget
        self.limits = limits
        initialHead = ticket.effectiveHead
        switch ticket.effectiveHead {
        case .request(let target, _):
            method = target.method
            url = BreakpointURL.display(target)
            status = ""
            reason = ""
        case .response(let code, let phrase, _):
            method = ""
            url = ""
            status = String(code)
            reason = phrase ?? ""
        }
        headers = ticket.effectiveHead.headers.map { HeaderFieldRow(name: $0.name, value: $0.value) }
        body = Self.unloadedContent(for: ticket)
        initialLine = [method, url, status, reason]
    }

    // MARK: state

    /// Method and URL can change (not for a response, nor for a Map Local request).
    public var canEditTarget: Bool { ticket.direction == .request && !ticket.isLocalRoute }

    public var canEditBody: Bool { body == .text && (!isEncoded || boundary == .decoded) && replacementFile == nil }

    private var hasTextEdit: Bool {
        if case .text = body, let originalText, bodyText != originalText { return true }
        return false
    }

    /// The decoded text was edited while the raw bytes are on screen. Continue refuses until the
    /// decoded view is shown again or the edit is reverted: what is sent is what is visible.
    public var hasHiddenDecodedEdit: Bool {
        isEncoded && boundary == .raw && hasTextEdit
    }

    /// A collected body (of any size) can be replaced by a file the proxy copies itself; a Map
    /// Local request has no body to send.
    public var canReplaceBodyFromFile: Bool {
        ticket.phase == .pausedBody && !(ticket.direction == .request && ticket.isLocalRoute) && !isClosed
    }

    /// Picks `url` as the new body. The proxy copies the file into its private spool while the
    /// security scope is held for the whole await; the UI never reads it. A failure keeps the body.
    public func replaceBody(from url: URL, access: ScopedFileAccess = .securityScoped) async {
        guard canReplaceBodyFromFile, !isImportingFile else { return }
        isImportingFile = true
        fieldErrors[.body] = nil
        let client = self.client, token = ticket.token
        let imported = try? await access.withAccess(to: url) { try await client.replaceBodyFromFile(token, url: url) }
        isImportingFile = false
        guard !isClosed else { return }
        if let imported { replacementFile = imported } else { fieldErrors[.body] = .replacementFileUnavailable }
    }

    /// What the body area shows for the current `boundary`.
    public var displayedBody: BreakpointBodyContent {
        if isEncoded, boundary == .raw, let rawBody { return .hex(rawBody, truncated: rawTruncated) }
        return body
    }

    /// Any editable field differs from the paused message: request line or status line, headers or body text.
    public var isDirty: Bool {
        if hasTextEdit || replacementFile != nil { return true }
        if [method, url, status, reason] != initialLine { return true }
        return currentHeadFields() != Self.fields(of: initialHead)
    }

    /// The body can be read for editing (a headers-only pause whose length allows it).
    public var canCollectBody: Bool { ticket.phase == .pausedHeaders && !ticket.bodyTooLargeToCollect }

    /// Bytes this editor holds against the budget.
    public var reservedBytes: Int { reservation?.bytes ?? 0 }

    // MARK: ticket updates

    /// A newer copy of the same ticket. The draft stays; a body collected meanwhile becomes loadable.
    func update(_ snapshot: BreakpointTicketSnapshot) {
        guard snapshot.id == id, !isClosed else { return }
        let phaseChanged = snapshot.phase != ticket.phase
        ticket = snapshot
        if phaseChanged, loadTask == nil, reservation == nil { body = Self.unloadedContent(for: snapshot) }
    }

    /// Loads a collected body once (concurrent calls await the same load). A load refused for
    /// memory or one that failed is tried again by the next call (selecting the ticket again).
    public func loadBodyIfNeeded() async {
        if let loadTask {
            await loadTask.value
            return
        }
        guard !isClosed, ticket.phase == .pausedBody else { return }
        let task = Task { @MainActor in await self.performLoad() }
        loadTask = task
        await task.value
        if loadTask == task, body == .budgetExhausted || body == .loadFailed { loadTask = nil }
    }

    /// Releases the body memory; a load still running discards its result.
    public func close() {
        isClosed = true
        reservation?.release()
        reservation = nil
        rawBody = nil
    }

    /// Back to the paused message as it arrived.
    public func revert() {
        let fresh = BreakpointEditorModel(ticket: ticket, client: client, budget: budget, limits: limits)
        method = fresh.method
        url = fresh.url
        status = fresh.status
        reason = fresh.reason
        headers = fresh.headers
        if let originalText, case .text = body { bodyText = originalText }
        replacementFile = nil
        fieldErrors = [:]
    }

    // MARK: commands

    /// The continue command for this draft, or nil with `fieldErrors` set when it cannot be sent.
    func continueCommand() -> BreakpointClientCommand? {
        fieldErrors = [:]
        let fields = currentHeadFields()
        let head: HTTPMessageHead
        switch ticket.effectiveHead {
        case .request(let paused, _):
            var target = paused
            if canEditTarget {
                let verb = method.trimmingCharacters(in: .whitespaces)
                guard let parsed = BreakpointURL.parse(url, method: verb) else {
                    fieldErrors[.url] = .invalidURL
                    return nil
                }
                target = parsed
            }
            head = .request(target, headers: fields)
        case .response:
            guard let code = Int(status.trimmingCharacters(in: .whitespaces)) else {
                fieldErrors[.status] = .invalidStatus
                return nil
            }
            head = .response(status: code, reason: reason.isEmpty ? nil : reason, headers: fields)
        }

        var replacement = BreakpointBodyReplacement.unchanged
        var choice = BodyEncodingChoice.unchanged
        if let replacementFile {
            replacement = .file(replacementFile)
            // A picked file is plain bytes; it is never assumed to be encoded (T8a-GPT-R4).
            choice = Self.realEncoding(in: ticket.effectiveHead.headers) == nil ? .unchanged : .removeEncoding
        } else if hasHiddenDecodedEdit {
            fieldErrors[.body] = .decodedEditNotShown
            return nil
        } else if case .text = body, let originalText, bodyText != originalText {
            let data = Data(bodyText.utf8)
            guard data.count <= budget.perEditorBytes, data.count <= limits.editorBodyBytes else {
                fieldErrors[.body] = .bodyTooLarge
                return nil
            }
            replacement = .replace(data)
            // Edited decoded text is sent plain; there is no recompression (T8a-GPT-R4).
            choice = isEncoded ? .removeEncoding : .unchanged
        }

        do {
            if ticket.phase == .pausedBody {
                var length = ticket.bodyLength
                if case .replace(let data) = replacement { length = Int64(data.count) }
                if case .file(let file) = replacement { length = file.size }
                let descriptor = HTTPBodyDescriptor(
                    length: length, complete: true, changed: replacement != .unchanged, encodingChoice: choice)
                // Framing belongs to the transport: the edited head keeps the paused framing fields.
                let reconciled = Self.replacingFraming(head, with: ticket.effectiveHead.headers)
                try HTTPMutationValidator.validateEdit(
                    original: ticket.effectiveHead, edited: reconciled, body: descriptor, limits: limits)
                _ = try HTTPMutationValidator.normalize(head: reconciled, body: descriptor, limits: limits)
            } else {
                try HTTPMutationValidator.validateEdit(
                    original: ticket.effectiveHead, edited: head,
                    body: HTTPBodyDescriptor(length: nil, complete: false, changed: false),
                    upgradeCandidate: HTTPMutationValidator.isUpgradeCandidate(ticket.originalHead.headers), limits: limits)
            }
        } catch let error as HTTPMutationError {
            fieldErrors[field(for: error.field)] = BreakpointEditIssue(error.code)
            return nil
        } catch {
            fieldErrors[.message] = .rejected
            return nil
        }
        return .continue(ticket.token, BreakpointClientEdit(head: head, body: replacement, encodingChoice: choice))
    }

    /// The proxy rejected a locally valid edit; the draft stays as it is.
    func markRejected() {
        fieldErrors = [.message: .rejected]
    }

    // MARK: body loading

    private func performLoad() async {
        let length = max(0, ticket.bodyLength ?? 0)
        let wanted = Int(min(length, Int64(budget.perEditorBytes)))
        guard let reservation = budget.reserve(bytes: wanted) else {
            body = .budgetExhausted
            return
        }
        self.reservation = reservation
        body = .loading
        let preview: BreakpointBodyPreview
        do {
            preview = try await client.loadBody(ticket.token, maxBytes: wanted)
        } catch {
            releaseReservation()
            if !isClosed { body = .loadFailed }
            return
        }
        guard !isClosed else {
            releaseReservation()
            return
        }
        let raw = preview.data.count > wanted ? preview.data.prefix(wanted) : preview.data
        reservation.shrink(to: raw.count)
        let truncated = Int64(raw.count) < preview.totalLength

        // Text is edited and sent as UTF-8: a body labelled with another charset stays raw bytes.
        let utf8 = Self.isUTF8Compatible(ticket.effectiveHead.headers)
        if let encoding = Self.realEncoding(in: ticket.effectiveHead.headers) {
            isEncoded = true
            rawBody = raw
            rawTruncated = truncated
            body = .hex(raw, truncated: truncated)
            // A partial encoded stream cannot be decoded reliably.
            guard !truncated, utf8 else { return }
            // The decoded copy is charged before it exists and bounded by what was charged;
            // decoding runs off the main actor.
            let cap = min(budget.perEditorBytes, budget.totalBytes - budget.reservedBytes)
            guard cap > 0, reservation.grow(by: cap) else { return }
            let decoded = await Task.detached(priority: .userInitiated) { () -> (count: Int, text: String?) in
                let result = BodyDecoder.decode(raw, contentEncoding: encoding, maxOutputBytes: cap)
                guard result.error == nil else { return (0, nil) }
                return (result.data.count, Self.text(result.data))
            }.value
            // A closed editor already gave back its whole reservation.
            guard !isClosed else { return }
            guard let text = decoded.text else {
                reservation.shrink(to: raw.count)
                return
            }
            reservation.shrink(to: raw.count + decoded.count)
            setText(text)
        } else if utf8, let text = Self.text(raw, allowingCutSequence: truncated) {
            if truncated {
                bodyText = text
                body = .readOnlyText(truncated: true)
            } else {
                setText(text)
            }
        } else {
            body = .hex(raw, truncated: truncated)
        }
    }

    private func setText(_ text: String) {
        originalText = text
        bodyText = text
        body = .text
    }

    private func releaseReservation() {
        reservation?.release()
        reservation = nil
    }

    // MARK: helpers

    private func currentHeadFields() -> [HeaderField] {
        headers.filter { !($0.name.isEmpty && $0.value.isEmpty) }.map { HeaderField(name: $0.name, value: $0.value) }
    }

    private static func fields(of head: HTTPMessageHead) -> [HeaderField] { head.headers }

    private func field(for field: HTTPMutationError.Field) -> BreakpointEditorField {
        switch field {
        case .method: return canEditTarget ? .method : .message
        case .scheme, .host, .port, .path: return canEditTarget ? .url : .message
        case .status: return .status
        case .reason: return .reason
        case .header(let name), .headerValue(let name):
            if let row = headers.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) { return .header(row.id) }
            return .headers
        case .headers, .contentLength: return .headers
        case .body, .trailers, .contentEncoding: return .body
        case .message, .trailer: return .message
        }
    }

    private static func unloadedContent(for ticket: BreakpointTicketSnapshot) -> BreakpointBodyContent {
        switch ticket.phase {
        case .collectingBody: .collecting
        case .pausedBody: .loading
        default: ticket.bodyTooLargeToCollect ? .tooLargeToCollect : .streaming
        }
    }

    private static func realEncoding(in headers: [HeaderField]) -> String? {
        let values = headers.filter { $0.name.caseInsensitiveCompare("Content-Encoding") == .orderedSame }.map(\.value)
        let joined = values.joined(separator: ",")
        let real = joined.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty && $0 != "identity" }
        return real.isEmpty ? nil : joined
    }

    /// No `charset` parameter, or UTF-8 (US-ASCII cannot carry every edit, so it is not included).
    private static func isUTF8Compatible(_ headers: [HeaderField]) -> Bool {
        for field in headers where field.name.caseInsensitiveCompare("Content-Type") == .orderedSame {
            for parameter in field.value.split(separator: ";").dropFirst() {
                let pair = parameter.split(separator: "=", maxSplits: 1)
                guard pair.count == 2, pair[0].trimmingCharacters(in: .whitespaces).lowercased() == "charset" else { continue }
                let charset = pair[1].trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"'")))
                    .lowercased()
                if charset != "utf-8" && charset != "utf8" { return false }
            }
        }
        return true
    }

    /// Strict UTF-8 without NUL bytes; a body cut at the preview limit may end inside a character.
    nonisolated private static func text(_ data: Data, allowingCutSequence: Bool = false) -> String? {
        guard !data.contains(0) else { return nil }
        if let text = String(data: data, encoding: .utf8) { return text }
        guard allowingCutSequence else { return nil }
        for cut in 1...3 where data.count > cut {
            if let text = String(data: data.dropLast(cut), encoding: .utf8) { return text }
        }
        return nil
    }

    private static func replacingFraming(_ head: HTTPMessageHead, with fields: [HeaderField]) -> HTTPMessageHead {
        let names: Set<String> = ["content-length", "transfer-encoding", "trailer"]
        let headers = head.headers.filter { !names.contains($0.name.lowercased()) }
            + fields.filter { names.contains($0.name.lowercased()) }
        switch head {
        case .request(let target, _): return .request(target, headers: headers)
        case .response(let status, let reason, _): return .response(status: status, reason: reason, headers: headers)
        }
    }
}

/// The URL text of a request target, and back. Nothing is normalized: the path and query are kept
/// byte for byte (duplicate query items, percent spelling and case included).
public enum BreakpointURL {
    public static func display(_ target: HTTPMessageTarget) -> String {
        let scheme = target.scheme.lowercased()
        let isDefault = (scheme == "http" && target.port == 80) || (scheme == "https" && target.port == 443)
        let host = target.host.contains(":") && !target.host.hasPrefix("[") ? "[\(target.host)]" : target.host
        return "\(scheme)://\(host)\(isDefault ? "" : ":\(target.port)")\(target.pathAndQuery)"
    }

    public static func parse(_ text: String, method: String) -> HTTPMessageTarget? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let separator = trimmed.range(of: "://") else { return nil }
        let scheme = trimmed[..<separator.lowerBound].lowercased()
        guard !scheme.isEmpty else { return nil }
        let rest = trimmed[separator.upperBound...]
        let end = rest.firstIndex { $0 == "/" || $0 == "?" } ?? rest.endIndex
        let authority = rest[..<end]
        var pathAndQuery = String(rest[end...])
        if pathAndQuery.isEmpty { pathAndQuery = "/" } else if pathAndQuery.hasPrefix("?") { pathAndQuery = "/" + pathAndQuery }
        let defaultPort = scheme == "https" ? 443 : 80
        var host: Substring
        var port = defaultPort
        if authority.hasPrefix("[") {
            guard let close = authority.firstIndex(of: "]") else { return nil }
            host = authority[authority.index(after: authority.startIndex)..<close]
            let after = authority[authority.index(after: close)...]
            if !after.isEmpty {
                guard after.hasPrefix(":"), let value = Int(after.dropFirst()) else { return nil }
                port = value
            }
        } else if let colon = authority.lastIndex(of: ":"), authority.filter({ $0 == ":" }).count == 1 {
            host = authority[..<colon]
            guard let value = Int(authority[authority.index(after: colon)...]) else { return nil }
            port = value
        } else {
            host = authority
        }
        guard !host.isEmpty else { return nil }
        return HTTPMessageTarget(scheme: scheme, host: String(host), port: port, method: method, pathAndQuery: pathAndQuery)
    }
}
