import FlowStore
import Foundation

/// Pure readers of the parts of an HTTP message that condition rows look at (D5, D8).
enum MessageFields {
    static func header(_ name: String, in headers: [HeaderField]) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    /// The first `name=value` pair of the `Cookie` headers; the name is case sensitive.
    static func cookie(_ name: String, inRequestHeaders headers: [HeaderField]) -> String? {
        for field in headers where field.name.caseInsensitiveCompare("Cookie") == .orderedSame {
            for pair in field.value.split(separator: ";") {
                if let value = value(of: name, inPair: pair) { return value }
            }
        }
        return nil
    }

    /// The first `Set-Cookie` line that sets `name`; attributes after the first `;` are not cookies.
    static func setCookie(_ name: String, inResponseHeaders headers: [HeaderField]) -> String? {
        for field in headers where field.name.caseInsensitiveCompare("Set-Cookie") == .orderedSame {
            if let first = field.value.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first,
                let value = value(of: name, inPair: first)
            {
                return value
            }
        }
        return nil
    }

    // MARK: every match (R8F2): an empty key means any header / cookie

    private static func namesMatch(_ actual: String, _ wanted: String?, caseSensitive: Bool) -> Bool {
        guard let wanted else { return true }
        return caseSensitive ? actual == wanted : actual.caseInsensitiveCompare(wanted) == .orderedSame
    }

    /// The values of every header called `name` (any header when nil), in order.
    static func headerValues(_ name: String?, in headers: [HeaderField], nameCaseSensitive: Bool) -> [String] {
        headers.filter { namesMatch($0.name, name, caseSensitive: nameCaseSensitive) }.map(\.value)
    }

    private static func pairValue(_ pair: Substring, name: String?, nameCaseSensitive: Bool) -> String? {
        let trimmed = pair.drop { $0 == " " || $0 == "\t" }
        guard let equals = trimmed.firstIndex(of: "=") else { return nil }
        guard namesMatch(String(trimmed[..<equals]), name, caseSensitive: nameCaseSensitive) else { return nil }
        return String(trimmed[trimmed.index(after: equals)...])
    }

    /// The value of every `name=value` pair of the `Cookie` headers whose name matches (all pairs when nil).
    static func cookieValues(_ name: String?, inRequestHeaders headers: [HeaderField], nameCaseSensitive: Bool)
        -> [String]
    {
        var values: [String] = []
        for field in headers where field.name.caseInsensitiveCompare("Cookie") == .orderedSame {
            for pair in field.value.split(separator: ";") {
                if let value = pairValue(pair, name: name, nameCaseSensitive: nameCaseSensitive) { values.append(value) }
            }
        }
        return values
    }

    /// The value of every `Set-Cookie` line whose cookie name matches (all lines when nil).
    static func setCookieValues(_ name: String?, inResponseHeaders headers: [HeaderField], nameCaseSensitive: Bool)
        -> [String]
    {
        var values: [String] = []
        for field in headers where field.name.caseInsensitiveCompare("Set-Cookie") == .orderedSame {
            if let first = field.value.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first,
                let value = pairValue(first, name: name, nameCaseSensitive: nameCaseSensitive)
            {
                values.append(value)
            }
        }
        return values
    }

    private static func value(of name: String, inPair pair: Substring) -> String? {
        let trimmed = pair.drop { $0 == " " || $0 == "\t" }
        guard let equals = trimmed.firstIndex(of: "=") else { return nil }
        guard trimmed[..<equals] == name[...] else { return nil }
        return String(trimmed[trimmed.index(after: equals)...])
    }

    /// The first parameter called `name` (exactly); name and value are percent-decoded and `+` stays `+`.
    static func queryParam(_ name: String, inPathAndQuery pathAndQuery: String) -> String? {
        for pair in queryString(of: pathAndQuery).split(separator: "&", omittingEmptySubsequences: true) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = String(parts[0])
            guard (key.removingPercentEncoding ?? key) == name else { continue }
            guard parts.count == 2 else { return "" }
            let raw = String(parts[1])
            return raw.removingPercentEncoding ?? raw
        }
        return nil
    }

    /// Everything before `?` (or `#`).
    static func path(of pathAndQuery: String) -> String {
        let end = pathAndQuery.firstIndex(where: { $0 == "?" || $0 == "#" }) ?? pathAndQuery.endIndex
        return String(pathAndQuery[..<end])
    }

    /// What follows the first `?`, without the fragment; empty when there is none.
    static func queryString(of pathAndQuery: String) -> String {
        guard let mark = pathAndQuery.firstIndex(of: "?") else { return "" }
        let rest = pathAndQuery[pathAndQuery.index(after: mark)...]
        return String(rest[..<(rest.firstIndex(of: "#") ?? rest.endIndex)])
    }

    /// One main class per exchange, in this order: websocket > socketio > grpc > rpc > sse > http (D8,
    /// R8F2-5). `sse` needs a response; `rpc` is read from the request and, when there is one, the response.
    static func appProtocol(requestHeaders: [HeaderField], target: HTTPMessageTarget, responseHeaders: [HeaderField]?)
        -> String
    {
        if containsToken(header: "Upgrade", token: "websocket", in: requestHeaders),
            containsToken(header: "Connection", token: "upgrade", in: requestHeaders)
        {
            return "websocket"
        }
        if path(of: target.pathAndQuery).hasPrefix("/socket.io/") { return "socketio" }
        if let type = header("Content-Type", in: requestHeaders),
            type.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("application/grpc")
        {
            return "grpc"
        }
        if isRPC(requestHeaders: requestHeaders, responseHeaders: responseHeaders) { return "rpc" }
        if let responseHeaders, let type = header("Content-Type", in: responseHeaders),
            mediaType(type) == "text/event-stream"
        {
            return "sse"
        }
        return "http"
    }

    /// The response Content-Type is read only when `responseHeaders` is given, i.e. when the rule is judged at the
    /// response point or later; an RPC-only rule is judged at the request and sees the request cues alone.
    ///
    /// A non-gRPC RPC-style exchange (R8F2-5): a Content-Type of the request or response that is JSON-RPC,
    /// Thrift, Protobuf, Connect or SOAP 1.2, or a `Connect-Protocol-Version` / `SOAPAction` request header.
    static func isRPC(requestHeaders: [HeaderField], responseHeaders: [HeaderField]?) -> Bool {
        if header("Connect-Protocol-Version", in: requestHeaders) != nil || header("SOAPAction", in: requestHeaders) != nil {
            return true
        }
        for headers in [requestHeaders, responseHeaders ?? []] {
            guard let type = header("Content-Type", in: headers) else { continue }
            let media = mediaType(type)
            if ["application/json-rpc", "application/x-thrift", "application/x-protobuf", "application/protobuf",
                "application/soap+xml"].contains(media)
                || media.hasPrefix("application/vnd.apache.thrift.") || media.hasPrefix("application/connect+")
            {
                return true
            }
        }
        return false
    }

    private static func mediaType(_ contentType: String) -> String {
        let base = contentType.split(separator: ";", maxSplits: 1).first ?? ""
        return base.trimmingCharacters(in: .whitespaces).lowercased()
    }

    private static func containsToken(header name: String, token: String, in headers: [HeaderField]) -> Bool {
        headers.contains { field in
            field.name.caseInsensitiveCompare(name) == .orderedSame
                && field.value.split(separator: ",").contains {
                    $0.trimmingCharacters(in: CharacterSet(charactersIn: " \t")).caseInsensitiveCompare(token) == .orderedSame
                }
        }
    }

    /// The old coarse label, `h1` / `h2`, which saved rows compare with.
    static func httpVersionLabel(_ version: HTTPWireVersion) -> String {
        switch version {
        case .http1_0, .http1_1: "h1"
        case .http2: "h2"
        }
    }

    /// The text rows compare with: `HTTP/1.0`, `HTTP/1.1`, `HTTP/2`.
    static func httpVersionText(_ version: HTTPWireVersion) -> String {
        switch version {
        case .http1_0: "HTTP/1.0"
        case .http1_1: "HTTP/1.1"
        case .http2: "HTTP/2"
        }
    }
}
