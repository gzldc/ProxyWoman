import FlowStore
import Foundation
import Localization
import NIOHTTP1

enum HTTPTranslationError: Error {
    case invalidHeader, invalidContentLength, unsupportedTransferCoding, requestLengthRequired, invalidFraming

    func description(localizer: Localizer = L10n.localizer) -> String {
        let key: String
        switch self {
        case .invalidHeader: key = "httpTranslation.invalidHeader"
        case .invalidContentLength: key = "httpTranslation.invalidContentLength"
        case .unsupportedTransferCoding: key = "httpTranslation.unsupportedTransferCoding"
        case .requestLengthRequired: key = "httpTranslation.requestLengthRequired"
        case .invalidFraming: key = "httpTranslation.invalidFraming"
        }
        return localizer.format(key, arguments: [])
    }
}

/// Transforms copies of semantic heads. Original fields and h2 length validation remain at
/// the capture/codec boundary. A .http2 result is codec input, never HTTP/1 encoder input.
enum HTTPMessageTranslation {
    /// `bodyLength` is the exact length of the body the caller will send instead of the source's
    /// (an edited or locally produced body); it replaces every source framing field. A zero length
    /// leaves a request that declared no body without one. `nil` keeps the source framing.
    static func request(_ head: HTTPRequestHead, target: RequestTarget, source: HTTPWireVersion,
                        destination: HTTPWireVersion, endStream: Bool, bodyLength: UInt64? = nil, framingPlan: FramingPlan? = nil) throws -> HTTPRequestHead {
        if let framingPlan {
            var result = head
            result.version = version(destination)
            result.uri = head.method == .CONNECT ? target.authority : target.originForm
            result.headers = try plannedFields(framingPlan, destination: destination)
            if !result.headers.contains(name: "host") { result.headers.add(name: destination == .http2 ? "host" : "Host", value: target.hostHeader) }
            return result
        }
        if let bodyLength {
            try validate(head.headers)
            var result = head
            result.version = version(destination)
            result.uri = head.method == .CONNECT ? target.authority : target.originForm
            result.headers = try fields(head.headers, destination: destination, preserveUpgrade: source != .http2 && destination != .http2)
            if !result.headers.contains(name: "host") { result.headers.add(name: destination == .http2 ? "host" : "Host", value: target.hostHeader) }
            let declared = head.headers.contains(name: "content-length") || head.headers.contains(name: "transfer-encoding")
            result.headers.remove(name: "transfer-encoding")
            if bodyLength > 0 || declared { setLength(bodyLength, on: &result.headers, destination: destination) }
            else { result.headers.remove(name: "content-length") }
            if destination == .http1_0 {
                result.headers.remove(name: "trailer")
                if head.isKeepAlive { result.headers.replaceOrAdd(name: "Connection", value: "keep-alive") }
            }
            return result
        }
        let codings = try checkedCodings(head.headers, source: source, destination: destination)
        if !codings.isEmpty, codings.last != "chunked" { throw HTTPTranslationError.unsupportedTransferCoding }
        var result = head
        result.version = version(destination)
        result.uri = head.method == .CONNECT ? target.authority : target.originForm
        result.headers = try fields(head.headers, destination: destination, preserveUpgrade: source != .http2 && destination != .http2)
        if !result.headers.contains(name: "host") { result.headers.add(name: destination == .http2 ? "host" : "Host", value: target.hostHeader) }
        if destination == .http2 {
            result.headers.remove(name: "transfer-encoding")
        } else if source == .http2 {
            if endStream {
                result.headers.replaceOrAdd(name: "Content-Length", value: "0")
            } else if destination == .http1_1 {
                result.headers.remove(name: "content-length")
                result.headers.replaceOrAdd(name: "Transfer-Encoding", value: "chunked")
            } else if !result.headers.contains(name: "content-length") {
                throw HTTPTranslationError.requestLengthRequired
            }
        } else if destination == .http1_0 {
            let positiveLength = head.headers[canonicalForm: "content-length"].contains { value in
                guard let length = UInt64(value) else { return false }
                return length > 0
            }
            if !codings.isEmpty || (positiveLength && !result.headers.contains(name: "content-length")) {
                throw HTTPTranslationError.requestLengthRequired
            }
            result.headers.remove(name: "transfer-encoding")
        } else if !codings.isEmpty {
            result.headers.remove(name: "content-length")
            setTransferCoding(head.headers, on: &result.headers, codings: codings)
        } else if head.headers.contains(name: "content-length"), !result.headers.contains(name: "content-length") {
            // A Connection-nominated length cannot be forwarded, but its decoded body still
            // needs a boundary on this new hop.
            result.headers.add(name: "Transfer-Encoding", value: "chunked")
        }
        if destination == .http1_0 {
            result.headers.remove(name: "trailer")
            if head.isKeepAlive { result.headers.replaceOrAdd(name: "Connection", value: "keep-alive") }
        }
        return result
    }

    /// `bodyLength` is the exact length of the body the caller will send instead of the source's
    /// (an edited or local response); it replaces every source framing field. On a bodyless
    /// HEAD/304 response it describes the representation; 1xx/204 never carry a length.
    static func response(_ head: HTTPResponseHead, requestMethod: HTTPMethod, source: HTTPWireVersion,
                         destination: HTTPWireVersion, endStream: Bool, bodyLength: UInt64? = nil, framingPlan: FramingPlan? = nil) throws -> HTTPResponseHead {
        if let framingPlan {
            var result = head
            result.version = version(destination)
            result.headers = try plannedFields(framingPlan, destination: destination)
            return result
        }
        let codings: [String]
        if bodyLength == nil { codings = try checkedCodings(head.headers, source: source, destination: destination) }
        else { try validate(head.headers); codings = [] }
        var result = head
        result.version = version(destination)
        result.headers = try fields(head.headers, destination: destination, preserveUpgrade: head.status == .switchingProtocols && source != .http2 && destination != .http2)
        let bodyAllowed = responseBodyAllowed(requestMethod: requestMethod, status: head.status)
        if let bodyLength {
            result.headers.remove(name: "transfer-encoding")
            if !bodyAllowed { result.headers.remove(name: "trailer") }
            if (100..<200).contains(head.status.code) || head.status == .noContent { result.headers.remove(name: "content-length") }
            else { setLength(bodyLength, on: &result.headers, destination: destination) }
        } else if !bodyAllowed {
            result.headers.remove(name: "transfer-encoding")
            result.headers.remove(name: "trailer")
            if (100..<200).contains(head.status.code) || head.status == .noContent
                || (requestMethod != .HEAD && head.status != .notModified) { result.headers.remove(name: "content-length") }
        } else if destination == .http2 {
            result.headers.remove(name: "transfer-encoding")
        } else if source == .http2 && endStream {
            result.headers.replaceOrAdd(name: "Content-Length", value: "0")
        } else if source == .http2 && destination == .http1_1 {
            result.headers.remove(name: "content-length")
            result.headers.replaceOrAdd(name: "Transfer-Encoding", value: "chunked")
        } else if destination == .http1_0 {
            result.headers.remove(name: "transfer-encoding")
        } else if !codings.isEmpty {
            result.headers.remove(name: "content-length")
            setTransferCoding(head.headers, on: &result.headers, codings: codings)
        } else if !result.headers.contains(name: "content-length") {
            result.headers.add(name: "Transfer-Encoding", value: "chunked")
        }
        if destination != .http2 {
            if destination == .http1_0 { result.headers.remove(name: "trailer") }
            // Recompute bodyless persistence from the actual fields: NIO's parser caches
            // EOF-delimited keep-alive before its HEAD skip-body override has run.
            let sourcePersistent = responseIsPersistent(head, requestMethod: requestMethod)
            let closeDelimited = bodyAllowed && !result.headers.contains(name: "content-length")
                && (destination == .http1_0 || (!codings.isEmpty && codings.last != "chunked"))
            if head.status != .switchingProtocols {
                if closeDelimited || !sourcePersistent { result.headers.replaceOrAdd(name: "Connection", value: "close") }
                else if destination == .http1_0 { result.headers.replaceOrAdd(name: "Connection", value: "keep-alive") }
            }
        }
        return result
    }

    /// Filter received hop fields before deriving this hop's full-body framing.
    static func framingBaseFields(_ headers: HTTPHeaders, destination: HTTPWireVersion) throws -> HTTPHeaders {
        try fields(headers, destination: destination, preserveUpgrade: false)
    }

    private static func plannedFields(_ plan: FramingPlan, destination: HTTPWireVersion) throws -> HTTPHeaders {
        let original = HTTPHeaders(fields: plan.head.headers)
        var result = try fields(original, destination: destination, preserveUpgrade: false)
        if destination == .http1_1 {
            for value in original["transfer-encoding"] { result.add(name: "Transfer-Encoding", value: value) }
        }
        if destination != .http2, plan.closeDelimited || original[canonicalForm: "connection"].contains("close") {
            result.replaceOrAdd(name: "Connection", value: "close")
        }
        return result
    }

    /// HTTP/1.0 and body-forbidden trailers are capture-only. A fixed-length HTTP/1
    /// writer must likewise omit these fields; it cannot retroactively change its head.
    static func trailers(_ fields: HTTPHeaders, destination: HTTPWireVersion, bodyAllowed: Bool) throws -> HTTPHeaders? {
        try validate(fields)
        guard destination != .http1_0, bodyAllowed else { return nil }
        var result = try self.fields(fields, destination: destination, preserveUpgrade: false)
        for name in ["content-length", "transfer-encoding", "host", "trailer", "te"] { result.remove(name: name) }
        return result.isEmpty ? nil : result
    }

    static func responseBodyAllowed(requestMethod: HTTPMethod, status: HTTPResponseStatus) -> Bool {
        requestMethod != .HEAD && !(100..<200).contains(status.code) && status != .noContent && status != .notModified
    }

    static func responseIsPersistent(_ head: HTTPResponseHead, requestMethod: HTTPMethod) -> Bool {
        if head.version == .http2 { return true }
        if responseBodyAllowed(requestMethod: requestMethod, status: head.status) { return head.isKeepAlive }
        return HTTPResponseHead(version: head.version, status: head.status,
            headers: HTTPHeaders(head.headers.map { ($0.name, $0.value) })).isKeepAlive
    }

    static func requestEncoder() -> HTTPRequestEncoder {
        var configuration = HTTPRequestEncoder.Configuration()
        configuration.automaticallySetFramingHeaders = false
        return HTTPRequestEncoder(configuration: configuration)
    }
    static func responseEncoder() -> HTTPResponseEncoder {
        var configuration = HTTPResponseEncoder.Configuration()
        configuration.automaticallySetFramingHeaders = false
        return HTTPResponseEncoder(configuration: configuration)
    }

    static func transferCodings(_ headers: HTTPHeaders) throws -> [String] {
        var result: [String] = []
        for value in headers["transfer-encoding"] {
            for item in try codingValues(value) {
                let coding = item.trimmingCharacters(in: .whitespaces)
                // Transfer extension parameters are opaque entity-coding metadata on an
                // unchanged h1 hop. Framing only depends on the final coding token.
                let token = coding.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)[0].trimmingCharacters(in: .whitespaces).lowercased()
                guard !token.isEmpty, token.utf8.allSatisfy(isToken), token != "chunked" || coding.lowercased() == "chunked" else {
                    throw HTTPTranslationError.unsupportedTransferCoding
                }
                result.append(token)
            }
        }
        if let chunk = result.firstIndex(of: "chunked"), chunk != result.count - 1 { throw HTTPTranslationError.unsupportedTransferCoding }
        return result
    }

    /// Transfer parameters can contain quoted commas and escaped quotes. Preserve their
    /// spelling; only an unquoted comma separates the framing-relevant coding tokens.
    private static func codingValues(_ value: String) throws -> [String] {
        var items: [String] = []
        var item = ""
        var quoted = false
        var escaped = false
        for character in value {
            if escaped { item.append(character); escaped = false; continue }
            if quoted && character == "\\" { item.append(character); escaped = true; continue }
            if character == "\"" { quoted.toggle() }
            if character == "," && !quoted { items.append(item); item = "" }
            else { item.append(character) }
        }
        guard !quoted && !escaped else { throw HTTPTranslationError.unsupportedTransferCoding }
        items.append(item)
        return items
    }

    static func validate(_ headers: HTTPHeaders) throws {
        for (name, value) in headers {
            guard !name.isEmpty, name.utf8.allSatisfy(isToken),
                  value.utf8.allSatisfy({ $0 == 9 || ($0 >= 32 && $0 != 127) }) else { throw HTTPTranslationError.invalidHeader }
        }
    }
    static func checkedCodings(_ headers: HTTPHeaders, source: HTTPWireVersion, destination: HTTPWireVersion) throws -> [String] {
        try validate(headers)
        let lengths = headers["content-length"].flatMap { value in
            value.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        }
        for length in lengths {
            guard !length.isEmpty, length.utf8.allSatisfy({ (48...57).contains($0) }), UInt64(length) != nil,
                  length == lengths.first else { throw HTTPTranslationError.invalidContentLength }
        }
        let codings = try transferCodings(headers)
        if !codings.isEmpty && !lengths.isEmpty { throw HTTPTranslationError.invalidFraming }
        if source == .http2 && !codings.isEmpty { throw HTTPTranslationError.unsupportedTransferCoding }
        if destination != .http1_1 && codings.contains(where: { $0 != "chunked" }) { throw HTTPTranslationError.unsupportedTransferCoding }
        return codings
    }
    private static func fields(_ headers: HTTPHeaders, destination: HTTPWireVersion, preserveUpgrade: Bool) throws -> HTTPHeaders {
        try validate(headers)
        let nominated = Set(headers[canonicalForm: "connection"].map { $0.lowercased() })
        guard nominated.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy(isToken) }) else { throw HTTPTranslationError.invalidHeader }
        let upgrade = preserveUpgrade && nominated.contains("upgrade") && headers.contains(name: "upgrade")
        let blocked: Set<String> = ["connection", "proxy-connection", "keep-alive", "transfer-encoding", "upgrade"]
        var result = HTTPHeaders()
        let cookies = headers["cookie"]
        var wroteCookie = false
        for (name, value) in headers {
            let lower = name.lowercased()
            if blocked.contains(lower) || nominated.contains(lower) { continue }
            if lower == "te" {
                if destination == .http2 {
                    guard value.trimmingCharacters(in: .whitespaces).lowercased() == "trailers" else { throw HTTPTranslationError.invalidHeader }
                    result.add(name: "te", value: "trailers")
                }
                continue
            }
            if lower == "cookie" && destination != .http2 {
                if !wroteCookie { result.add(name: name, value: cookies.joined(separator: "; ")); wroteCookie = true }
            } else { result.add(name: destination == .http2 ? lower : name, value: value) }
        }
        if upgrade {
            for value in headers["upgrade"] { result.add(name: "Upgrade", value: value) }
            result.add(name: "Connection", value: "Upgrade")
        }
        return result
    }
    private static func setLength(_ length: UInt64, on headers: inout HTTPHeaders, destination: HTTPWireVersion) {
        headers.remove(name: "content-length")
        headers.add(name: destination == .http2 ? "content-length" : "Content-Length", value: String(length))
    }
    private static func setTransferCoding(_ original: HTTPHeaders, on headers: inout HTTPHeaders, codings: [String]) {
        if codings == ["chunked"] { headers.add(name: "Transfer-Encoding", value: "chunked") }
        else { for value in original["transfer-encoding"] { headers.add(name: "Transfer-Encoding", value: value) } }
    }
    private static func version(_ wire: HTTPWireVersion) -> HTTPVersion {
        switch wire {
        case .http1_0: .http1_0
        case .http1_1: .http1_1
        case .http2: .init(major: 2, minor: 0)
        }
    }
    private static func isToken(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
            || [33, 35, 36, 37, 38, 39, 42, 43, 45, 46, 94, 95, 96, 124, 126].contains(byte)
    }
}
