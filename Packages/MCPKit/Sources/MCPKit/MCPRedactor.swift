import FlowStore
import Foundation
import Viewers

/// Masks credentials before anything leaves the app through MCP (spec D13).
///
/// Policy: fail-closed best effort. Over-redaction is acceptable, leaks are not. It knows header names,
/// query/form keys, JSON keys and XML/HTML element or attribute names; it cannot find arbitrary secrets
/// inside free text. URLs embedded in bodies (JSON string values, HTML/XML attribute values and text,
/// plain text) get the same query/fragment rule as request URLs. Known gaps: single-quoted or unquoted JS
/// object keys, line-oriented `key: value` text, and userinfo (`user:pass@host`) inside URLs, which
/// `url(_:)` leaves alone.
public struct MCPRedactor: Sendable {
    public static let redactedValue = "[REDACTED]"
    /// Bodies larger than this are dropped from redacted flow copies instead of being scanned.
    static let maxBodyBytes = 1 << 20
    /// How many URL-valued query parameters are looked into (`redirect_uri=...%3Ftoken%3D...`).
    static let maxURLNesting = 2

    /// D13 names, normalized (see `normalize`).
    private static let fieldNames: Set<String> = [
        "token", "accesstoken", "idtoken", "refreshtoken", "apikey", "key", "secret", "password", "passwd", "pwd",
        "sig", "signature", "code", "session", "sessionid", "auth", "subscriptionkey", "ocpapimsubscriptionkey", "sid",
    ]
    private static let headerOnlyNames: Set<String> = [
        "authorization", "proxyauthorization", "cookie", "setcookie", "xapikey", "xauthtoken", "xcsrftoken",
        "xamzsecuritytoken",
    ]
    private static let fragments = ["token", "secret", "password", "passwd", "apikey", "signature", "credential", "authorization",
        "privatekey", "accesskey", "sessionid", "sessid",
    ]
    private static let headerFragments = ["cookie"]
    /// Headers whose values are URLs (or contain them).
    private static let urlHeaders: Set<String> = ["location", "referer", "referrer", "content-location", "link", "refresh"]
    /// The content kinds that may be shown as text at all (shared with `MCPBodyPreview`).
    static let textKinds: Set<ContentKind> = [
        .json, .html, .xml, .javascript, .css, .form, .graphql, .text,
    ]

    private let enabled: Bool
    private let extras: [String]

    public init(_ settings: MCPRedactionSettings) {
        enabled = settings.enabled
        extras = settings.normalizedExtraNames().map(Self.normalize).filter { !$0.isEmpty }
    }

    public var isEnabled: Bool { enabled }

    // MARK: Headers and URLs

    /// Sensitive headers get `[REDACTED]`; headers that carry URLs (Location, Referer, Content-Location,
    /// Link, Refresh) have the sensitive query parameters inside their value masked.
    public func headers(_ headers: [HeaderField]) -> [HeaderField] {
        guard enabled else { return headers }
        return headers.map { field in
            if isSensitiveHeader(field.name) { return HeaderField(name: field.name, value: Self.redactedValue) }
            let lower = field.name.lowercased()
            if lower == "link" { return HeaderField(name: field.name, value: redactLinkTargets(field.value)) }
            if Self.urlHeaders.contains(lower) {
                return HeaderField(name: field.name, value: redactURL(field.value, depth: 0))
            }
            return field
        }
    }

    /// The value of a rule's condition row, as the row's field would show it: a header row by the header's name
    /// (`headers(_:)`), a cookie row always (any cookie can hold a session), a query-parameter row by the
    /// sensitive-name list and a query-string row pair by pair. Every other field's value is left as it is.
    public func conditionValue(field: String, name: String?, value: String) -> String {
        guard enabled else { return value }
        switch field {
        case "requestHeader", "responseHeader":
            return headers([HeaderField(name: name ?? "", value: value)])[0].value
        case "requestCookie", "responseCookie":
            return value.isEmpty ? value : Self.redactedValue
        case "queryString":
            return redactPairs(Substring(value), depth: 0, lines: false)
        case "queryParam":
            return name.map(isSensitiveField) == true ? Self.redactedValue : value
        default:
            return value
        }
    }

    /// Replaces the values of sensitive keys in the query and in the fragment (OAuth implicit flows put
    /// tokens in `#access_token=...`; a fragment can show up in Location/Referer values), including
    /// sensitive parameters inside URL-valued parameters. Everything else (order, separators,
    /// percent-encoding) is kept byte for byte. Userinfo (`user:pass@host`) is intentionally not
    /// inspected.
    public func url(_ url: String) -> String {
        enabled ? redactURL(url, depth: 0) : url
    }

    // MARK: Bodies

    /// Always safe to call on any text: the JSON-key scanner runs on everything (it only reacts to a
    /// string literal followed by `:`, so it also covers JSON served as text/plain or html, JSONP and SSE
    /// `data:` lines); markup gets the element/attribute scanner; form types and text shaped like
    /// `k=v&k=v` get the pair scanner; multipart text gets a part scanner.
    public func bodyText(_ text: String, contentType: String?) -> String {
        guard enabled else { return text }
        let mime = contentType.map(Self.mimeEssence) ?? ""
        let kind = ContentKind.classify(contentType: contentType)
        var out = text
        if mime == "application/x-www-form-urlencoded" {
            out = redactPairs(out[...], depth: 0, lines: true)
        } else if let first = out.first(where: { !$0.isWhitespace }), first != "<" {
            if "{[".contains(first) {
                // Valid JSON is left to the JSON scanner. Anything else that merely starts like JSON
                // (INI `[section]`, a mislabelled `{token=abc&x=1`) gets the newline-only line scan.
                if !Self.isValidJSON(out) { out = redactPairs(out[...], depth: 0, lines: true, ampersand: false) }
            } else if out.contains("=") {
                out = redactPairs(out[...], depth: 0, lines: true)
                out = redactEmbeddedURLs(out)
            }
        }
        out = redactJSON(out)
        if mime.hasPrefix("multipart/") { out = redactMultipart(out) }
        if kind == .html || kind == .xml || Self.firstNonSpaceIs("<", out) { out = redactMarkup(out) }
        return out
    }

    // MARK: Flows

    /// A copy that is safe to hand out: headers, trailers, the query string, notes and text bodies
    /// redacted; binary, encoded, multipart or oversize bodies removed; message boundaries cleared
    /// because exports use the legacy request*/response* projection.
    public func flow(_ flow: Flow) -> Flow {
        guard enabled else { return flow }
        var copy = flow
        copy.path = url(flow.path)
        copy.requestHeaders = headers(flow.requestHeaders)
        copy.responseHeaders = headers(flow.responseHeaders)
        copy.requestTrailers = headers(flow.requestTrailers)
        copy.responseTrailers = headers(flow.responseTrailers)
        copy.requestBody = flow.requestBody.flatMap { redactedBody($0, headers: flow.requestHeaders) }
        copy.responseBody = flow.responseBody.flatMap { redactedBody($0, headers: flow.responseHeaders) }
        // Notes are fixed product strings and failure reasons are transport descriptions; neither is
        // known to contain URLs, but scrub them like URLs anyway.
        copy.note = flow.note.map { redactURL($0, depth: 0) }
        if case .failed(let reason) = flow.state { copy.state = .failed(redactURL(reason, depth: 0)) }
        copy.messages = [:]
        return copy
    }

    /// Argument summary for the audit log. `text` must be JSON text (the tool runner serializes the
    /// arguments); `"key":"value"` pairs of sensitive keys are masked, then the result is cut to `limit`
    /// characters with a trailing "…". Redaction runs first so a cut never exposes half a secret.
    public func summary(_ text: String, limit: Int) -> String {
        let redacted = enabled ? redactJSON(text) : text
        guard limit > 0 else { return "" }
        guard redacted.count > limit else { return redacted }
        return String(redacted.prefix(limit - 1)) + "…"
    }

    // MARK: Key sensitivity

    /// Lowercase and drop `-`, `_`, `[`, `]`, `.` and whitespace, so `accessToken`, `access_token`,
    /// `Access-Token` and `user[password]` compare alike.
    static func normalize(_ name: String) -> String {
        String(String.UnicodeScalarView(name.lowercased().unicodeScalars.filter { !"-_[]. \t\r\n+%".unicodeScalars.contains($0) }))
    }

    private func isSensitiveField(_ name: String) -> Bool {
        let n = Self.normalize(name)
        guard !n.isEmpty else { return false }
        return Self.fieldNames.contains(n) || Self.fragments.contains { n.contains($0) }
            || extras.contains { n.contains($0) }
    }

    private func isSensitiveHeader(_ name: String) -> Bool {
        let n = Self.normalize(name)
        return Self.headerOnlyNames.contains(n) || Self.headerFragments.contains { n.contains($0) }
            || isSensitiveField(name)
    }

    private static func mimeEssence(_ contentType: String) -> String {
        contentType.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)[0]
            .trimmingCharacters(in: .whitespaces).lowercased()
    }

    private static func firstNonSpaceIs(_ character: Character, _ text: String) -> Bool {
        text.first { !$0.isWhitespace } == character
    }

    /// The content type of a body that may be shown at all, nil when it must never be exposed: over the
    /// size cap, any `Content-Encoding` other than identity, no or non-text `Content-Type`, multipart.
    /// The one place that decides this, for get_flow/exports and for body search alike.
    func exposableContentType(headers: [HeaderField], size: Int) -> String? {
        guard size <= Self.maxBodyBytes else { return nil }
        let encodings = headers.values(for: "content-encoding").flatMap { $0.split(separator: ",") }
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        if encodings.contains(where: { !$0.isEmpty && $0 != "identity" }) { return nil }
        guard let contentType = headers.value(for: "content-type"),
            Self.textKinds.contains(ContentKind.classify(contentType: contentType)),
            !Self.mimeEssence(contentType).hasPrefix("multipart/")
        else { return nil }
        return contentType
    }

    /// Decoded text of an exposable body (`prefix` is the first bytes, or all of it when
    /// `prefix.count == size`); nil when the body is not exposable or does not decode. A prefix cut in the
    /// middle of a multi-byte character is retried with up to three trailing bytes dropped.
    func decodedExposableText(prefix data: Data, headers: [HeaderField], size: Int) -> (text: String, contentType: String)? {
        guard data.count <= Self.maxBodyBytes, let contentType = exposableContentType(headers: headers, size: size)
        else { return nil }
        if let text = TextDecoding.string(from: data, contentType: contentType) { return (text, contentType) }
        guard data.count < size else { return nil }
        for dropped in 1...3 where data.count > dropped {
            if let text = TextDecoding.string(from: data.dropLast(dropped), contentType: contentType) {
                return (text, contentType)
            }
        }
        return nil
    }

    /// Redacted text of an exposable body, nil when the body must not be exposed (see
    /// `exposableContentType`). Used by body search so that nothing hidden from get_flow can be matched.
    func redactedBodyText(prefix data: Data, headers: [HeaderField], size: Int) -> String? {
        guard let decoded = decodedExposableText(prefix: data, headers: headers, size: size) else { return nil }
        return bodyText(decoded.text, contentType: decoded.contentType)
    }

    private func redactedBody(_ body: BodyRef, headers: [HeaderField]) -> BodyRef? {
        guard exposableContentType(headers: headers, size: body.size) != nil, let data = try? body.load(),
            let decoded = decodedExposableText(prefix: data, headers: headers, size: body.size)
        else { return nil }
        let redacted = bodyText(decoded.text, contentType: decoded.contentType)
        return redacted == decoded.text ? body : .memory(Data(redacted.utf8))
    }

    // MARK: URL and pair scanning

    /// Query (`?...` up to `#` or the end) and fragment (after `#`) are both scanned as pair lists.
    /// `url` may be a bare path, an absolute URL, or text around one (Refresh values, error texts).
    private func redactURL(_ url: String, depth: Int) -> String {
        let hash = url.firstIndex(of: "#")
        let head = hash.map { url[..<$0] } ?? url[...]
        var result = String(head)
        if let question = head.firstIndex(of: "?") {
            let queryStart = head.index(after: question)
            result = String(head[..<queryStart]) + redactPairs(head[queryStart...], depth: depth, lines: false)
        }
        if let hash {
            let fragmentStart = url.index(after: hash)
            let fragment = url[fragmentStart...]
            if let question = fragment.firstIndex(of: "?") {
                // Hash routers: `#/cb?code=abc` carries a query inside the fragment.
                let queryStart = fragment.index(after: question)
                result += "#" + redactPairs(fragment[..<question], depth: depth, lines: false) + "?"
                    + redactPairs(fragment[queryStart...], depth: depth, lines: false)
            } else {
                result += "#" + redactPairs(fragment, depth: depth, lines: false)
            }
        }
        return result
    }

    /// `Link: <target>; rel="next", <target2>; ...`: each `<...>` target is a URL; the rest is kept.
    private func redactLinkTargets(_ value: String) -> String {
        var out = ""
        var rest = value[...]
        while let open = rest.firstIndex(of: "<") {
            guard let close = rest[open...].firstIndex(of: ">") else { break }
            out += rest[...open]
            out += redactURL(String(rest[rest.index(after: open)..<close]), depth: 0)
            rest = rest[close...]
        }
        // An unterminated target is scanned as a URL too (fail closed).
        if let open = rest.firstIndex(of: "<"), !rest[open...].contains(">") {
            out += rest[...open] + redactURL(String(rest[rest.index(after: open)...]), depth: 0)
            return out
        }
        return out + rest
    }

    /// `a=b&c=d` (query, fragment, urlencoded form) and, with `lines`, `k=v` lines (`ampersand: false`
    /// splits on newlines only). Separators are kept.
    /// Keys are compared leniently percent-decoded (malformed `%` sequences stay as written, and the raw
    /// key is checked too); the original text of every other segment is preserved. A non-sensitive value
    /// that, once decoded, is itself a URL with a query is scanned too (at most `maxURLNesting` levels)
    /// and re-encoded.
    private func redactPairs(_ text: Substring, depth: Int, lines: Bool, ampersand: Bool = true) -> String {
        var out = ""
        var segmentStart = text.startIndex
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if (ampersand && character == "&") || (lines && character.isNewline) {
                out += redactSegment(text[segmentStart..<index], depth: depth)
                out.append(character)
                segmentStart = text.index(after: index)
            }
            index = text.index(after: index)
        }
        return out + redactSegment(text[segmentStart...], depth: depth)
    }

    private func redactSegment(_ segment: Substring, depth: Int) -> String {
        guard let equals = segment.firstIndex(of: "=") else { return String(segment) }
        let key = segment[..<equals]
        let spaced = key.replacingOccurrences(of: "+", with: " ")
        if isSensitiveField(String(key)) || isSensitiveField(Self.lenientDecode(spaced)) {
            return "\(key)=\(Self.redactedValue)"
        }
        let value = String(segment[segment.index(after: equals)...])
        guard depth < Self.maxURLNesting, value.contains("%") || value.contains("?") else { return String(segment) }
        let inner = Self.lenientDecode(value)
        guard Self.looksLikeURL(inner) else { return String(segment) }
        let scrubbed = redactURL(inner, depth: depth + 1)
        return scrubbed == inner ? String(segment) : "\(key)=\(Self.percentEncode(scrubbed))"
    }

    /// Decodes valid `%XX` sequences and leaves anything malformed as written (never fails).
    static func lenientDecode(_ text: String) -> String {
        let bytes = Array(text.utf8)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        func hex(_ byte: UInt8) -> UInt8? {
            switch byte {
            case 0x30...0x39: byte - 0x30
            case 0x41...0x46: byte - 0x41 + 10
            case 0x61...0x66: byte - 0x61 + 10
            default: nil
            }
        }
        var i = 0
        while i < bytes.count {
            if bytes[i] == UInt8(ascii: "%"), i + 2 < bytes.count, let hi = hex(bytes[i + 1]), let lo = hex(bytes[i + 2]) {
                out.append(hi << 4 | lo)
                i += 3
            } else {
                out.append(bytes[i])
                i += 1
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    private static func looksLikeURL(_ text: String) -> Bool {
        let lower = text.lowercased()
        return text.contains("?") && (lower.hasPrefix("http://") || lower.hasPrefix("https://") || text.hasPrefix("/"))
    }

    private static func percentEncode(_ text: String) -> String {
        let allowed = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }

    private static func isValidJSON(_ text: String) -> Bool {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])) != nil
    }

    // MARK: Embedded URLs

    /// Free text (a plain-text body, an XML/HTML text node, a JSON string value, an attribute value) that
    /// may hold URLs: it is cut at whitespace, double quotes and angle brackets (kept as written), and every
    /// piece that looks like a URL with a query or fragment gets the request-URL rule. A piece that is not a
    /// URL is left alone, so prose and `a=b` expressions are never changed.
    private func redactEmbeddedURLs(_ text: String) -> String {
        guard Self.mayHoldQueryPairs(text) else { return text }
        var out = ""
        var token = ""
        for character in text {
            if character.isWhitespace || character == "\"" || character == "<" || character == ">" {
                out += redactURLToken(token)
                token = ""
                out.append(character)
            } else {
                token.append(character)
            }
        }
        return out + redactURLToken(token)
    }

    private func redactURLToken(_ token: String) -> String {
        guard Self.mayHoldQueryPairs(token) else { return token }
        // `&amp;` separates parameters in HTML and XML; the entity is restored where a parameter changed.
        guard token.contains("&amp;") else { return redactURL(token, depth: 0) }
        let plain = token.replacingOccurrences(of: "&amp;", with: "&")
        let redacted = redactURL(plain, depth: 0)
        return redacted == plain ? token : redacted.replacingOccurrences(of: "&", with: "&amp;")
    }

    private static func mayHoldQueryPairs(_ text: String) -> Bool {
        text.contains("=") && (text.contains("?") || text.contains("#"))
    }

    /// A JSON string literal (`literal` includes the quotes; the closing one is missing when the input was
    /// cut) whose value holds URLs: nil when nothing in it needs redacting, else the replacement bytes.
    /// Escapes are resolved first (`\/`, `\u0026`, `\u005f`), and the result is encoded again.
    private func redactedJSONStringLiteral(_ literal: ArraySlice<UInt8>, closed: Bool) -> [UInt8]? {
        let backslash = UInt8(ascii: "\\")
        let equals = UInt8(ascii: "=")
        let inner = literal.dropFirst().dropLast(closed ? 1 : 0)
        guard inner.contains(equals) || inner.contains(backslash) else { return nil }
        let raw = String(decoding: inner, as: UTF8.self)
        var text = raw
        var decodedFromEscapes = false
        if inner.contains(backslash), closed,
            let decoded = try? JSONDecoder().decode(String.self, from: Data(literal))
        {
            text = decoded
            decodedFromEscapes = true
        }
        guard Self.mayHoldQueryPairs(text) else { return nil }
        let redacted = redactEmbeddedURLs(text)
        guard redacted != text else { return nil }
        if decodedFromEscapes {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes]
            if let data = try? encoder.encode(redacted) { return Array(data) }
        }
        let quote = UInt8(ascii: "\"")
        return [quote] + Array(redacted.utf8) + (closed ? [quote] : [])
    }

    // MARK: JSON scanning

    /// Scans for `"key":` without parsing, so whitespace and everything else stay as written. When the
    /// key is sensitive its whole value (string, number, literal, or balanced object/array) becomes the
    /// string `"[REDACTED]"`; the output stays valid JSON. Unterminated (truncated) input is handled.
    private func redactJSON(_ text: String) -> String {
        let bytes = Array(text.utf8)
        let quote = UInt8(ascii: "\"")
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            guard bytes[i] == quote else {
                out.append(bytes[i])
                i += 1
                continue
            }
            let end = Self.stringEnd(bytes, from: i)
            let closed = end - i >= 2 && bytes[end - 1] == quote
            let colon = closed ? Self.skipWhitespace(bytes, from: end) : bytes.count
            let isKey = colon < bytes.count && bytes[colon] == UInt8(ascii: ":")
            guard isKey else {
                // A string value (or array element): URLs inside it get the request-URL rule.
                out.append(contentsOf: redactedJSONStringLiteral(bytes[i..<end], closed: closed) ?? Array(bytes[i..<end]))
                i = end
                continue
            }
            out.append(contentsOf: bytes[i..<end])
            guard isSensitiveField(Self.jsonKey(bytes[(i + 1)..<(end - 1)])) else {
                i = end
                continue
            }
            let valueStart = Self.skipWhitespace(bytes, from: colon + 1)
            out.append(contentsOf: bytes[end..<valueStart])
            let valueEnd = Self.valueEnd(bytes, from: valueStart)
            if valueEnd > valueStart { out.append(contentsOf: Array("\"\(Self.redactedValue)\"".utf8)) }
            i = max(valueEnd, valueStart)
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// End of the JSON value starting at `start` (== `start` when there is none, e.g. `,` or `}`).
    private static func valueEnd(_ bytes: [UInt8], from start: Int) -> Int {
        guard start < bytes.count else { return start }
        switch bytes[start] {
        case UInt8(ascii: "\""):
            return stringEnd(bytes, from: start)
        case UInt8(ascii: "{"), UInt8(ascii: "["):
            var depth = 0
            var j = start
            while j < bytes.count {
                switch bytes[j] {
                case UInt8(ascii: "\""):
                    j = stringEnd(bytes, from: j)
                    continue
                case UInt8(ascii: "{"), UInt8(ascii: "["):
                    depth += 1
                case UInt8(ascii: "}"), UInt8(ascii: "]"):
                    depth -= 1
                    if depth == 0 { return j + 1 }
                default:
                    break
                }
                j += 1
            }
            return bytes.count
        default:
            var j = start
            let stops: [UInt8] = [UInt8(ascii: ","), UInt8(ascii: "}"), UInt8(ascii: "]"), 0x20, 0x09, 0x0a, 0x0d]
            while j < bytes.count, !stops.contains(bytes[j]) { j += 1 }
            return j
        }
    }

    private static func skipWhitespace(_ bytes: [UInt8], from start: Int) -> Int {
        var j = start
        while j < bytes.count, bytes[j] == 0x20 || bytes[j] == 0x09 || bytes[j] == 0x0a || bytes[j] == 0x0d { j += 1 }
        return j
    }

    /// The key's text with JSON escapes resolved when it has any.
    private static func jsonKey(_ raw: ArraySlice<UInt8>) -> String {
        let plain = String(decoding: raw, as: UTF8.self)
        guard raw.contains(UInt8(ascii: "\\")) else { return plain }
        let quoted = Data([UInt8(ascii: "\"")] + raw + [UInt8(ascii: "\"")])
        return (try? JSONDecoder().decode(String.self, from: quoted)) ?? plain
    }

    /// Index just past the closing quote of the string that opens at `start`, or `bytes.count`.
    private static func stringEnd(_ bytes: [UInt8], from start: Int) -> Int {
        var j = start + 1
        while j < bytes.count {
            if bytes[j] == UInt8(ascii: "\\") {
                j += 2
            } else if bytes[j] == UInt8(ascii: "\"") {
                return j + 1
            } else {
                j += 1
            }
        }
        return bytes.count
    }

    // MARK: Markup scanning

    private static func isNameChar(_ byte: UInt8) -> Bool {
        (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5a) || (byte >= 0x61 && byte <= 0x7a)
            || byte == UInt8(ascii: "_") || byte == UInt8(ascii: ":") || byte == UInt8(ascii: ".")
            || byte == UInt8(ascii: "-")
    }

    private static func isSpace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0a || byte == 0x0d
    }

    /// Masks the text content of elements whose (prefix-stripped) name is sensitive, and attribute values
    /// of sensitive attributes. `<input name="password" value="x">` masks `value`.
    private func redactMarkup(_ text: String) -> String {
        let bytes = Array(text.utf8)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var i = 0
        // Text between tags is held back in `runStart..<i` so URLs in it can be redacted as a whole.
        var runStart = 0
        func flushRun(upTo end: Int) {
            guard runStart < end else { return }
            let run = bytes[runStart..<end]
            if run.contains(UInt8(ascii: "=")) {
                out.append(contentsOf: Array(redactEmbeddedURLs(String(decoding: run, as: UTF8.self)).utf8))
            } else {
                out.append(contentsOf: run)
            }
        }
        while i < bytes.count {
            guard bytes[i] == UInt8(ascii: "<"), i + 1 < bytes.count,
                Self.isNameChar(bytes[i + 1]), bytes[i + 1] != UInt8(ascii: "-")
            else {
                i += 1
                continue
            }
            flushRun(upTo: i)
            var nameEnd = i + 1
            while nameEnd < bytes.count, Self.isNameChar(bytes[nameEnd]) { nameEnd += 1 }
            let qualified = String(decoding: bytes[(i + 1)..<nameEnd], as: UTF8.self)
            let local = qualified.split(separator: ":").last.map(String.init) ?? qualified
            // The tag ends at the first '>' (quotes are not tracked, so an apostrophe in prose cannot
            // swallow the rest of the document) or at the next '<' (malformed: not a tag, keep scanning).
            var tagEnd = nameEnd
            while tagEnd < bytes.count, bytes[tagEnd] != UInt8(ascii: ">"), bytes[tagEnd] != UInt8(ascii: "<") {
                tagEnd += 1
            }
            out.append(contentsOf: bytes[i..<nameEnd])
            out.append(contentsOf: redactAttributes(bytes, from: nameEnd, to: tagEnd))
            guard tagEnd < bytes.count else {
                runStart = bytes.count
                break
            }
            guard bytes[tagEnd] == UInt8(ascii: ">") else {
                i = tagEnd
                runStart = i
                continue
            }
            out.append(UInt8(ascii: ">"))
            i = tagEnd + 1
            runStart = i
            let selfClosing = bytes[tagEnd - 1] == UInt8(ascii: "/")
            guard !selfClosing, isSensitiveField(local) else { continue }
            let closeStart = Self.indexOfMatchingClose(bytes, name: qualified, from: i)
            if closeStart > i { out.append(contentsOf: Array(Self.redactedValue.utf8)) }
            i = closeStart
            runStart = i
        }
        flushRun(upTo: bytes.count)
        return String(decoding: out, as: UTF8.self)
    }

    /// Start of the `</name>` that closes the element whose content starts at `start`, counting nested
    /// elements of the same name; `bytes.count` when it never closes (everything to the end is content).
    private static func indexOfMatchingClose(_ bytes: [UInt8], name: String, from start: Int) -> Int {
        let open = Array("<\(name)".lowercased().utf8)
        let close = Array("</\(name)".lowercased().utf8)
        func matches(_ needle: [UInt8], at j: Int) -> Bool {
            guard j + needle.count <= bytes.count,
                zip(bytes[j..<(j + needle.count)], needle).allSatisfy({ lower($0) == $1 })
            else { return false }
            return j + needle.count == bytes.count || !isNameChar(bytes[j + needle.count])
        }
        var depth = 1
        var j = start
        while j < bytes.count {
            guard bytes[j] == UInt8(ascii: "<") else {
                j += 1
                continue
            }
            if matches(close, at: j) {
                depth -= 1
                if depth == 0 { return j }
            } else if matches(open, at: j) {
                // Same tag rule as the main scan (ends at '>' or at the next '<'), and the scan resumes
                // after the tag, so the whole search is a single pass over the input.
                var end = j + open.count
                while end < bytes.count, bytes[end] != UInt8(ascii: ">"), bytes[end] != UInt8(ascii: "<") { end += 1 }
                if end < bytes.count, bytes[end] == UInt8(ascii: ">"), bytes[end - 1] != UInt8(ascii: "/") {
                    depth += 1
                }
                j = end
                continue
            }
            j += 1
        }
        return bytes.count
    }

    private static func lower(_ byte: UInt8) -> UInt8 {
        byte >= 0x41 && byte <= 0x5a ? byte + 0x20 : byte
    }

    private func redactAttributes(_ bytes: [UInt8], from start: Int, to end: Int) -> [UInt8] {
        struct Attribute {
            var name: String
            var value: Range<Int>?  // inside any quotes
        }
        var attributes: [Attribute] = []
        var j = start
        while j < end {
            while j < end, Self.isSpace(bytes[j]) || bytes[j] == UInt8(ascii: "/") { j += 1 }
            let nameStart = j
            while j < end, !Self.isSpace(bytes[j]), bytes[j] != UInt8(ascii: "="), bytes[j] != UInt8(ascii: "/") { j += 1 }
            guard j > nameStart else { break }
            let name = String(decoding: bytes[nameStart..<j], as: UTF8.self)
            var k = j
            while k < end, Self.isSpace(bytes[k]) { k += 1 }
            guard k < end, bytes[k] == UInt8(ascii: "=") else {
                attributes.append(Attribute(name: name, value: nil))
                continue
            }
            k += 1
            while k < end, Self.isSpace(bytes[k]) { k += 1 }
            if k < end, bytes[k] == UInt8(ascii: "\"") || bytes[k] == UInt8(ascii: "'") {
                let quote = bytes[k]
                var close = k + 1
                while close < end, bytes[close] != quote { close += 1 }
                attributes.append(Attribute(name: name, value: (k + 1)..<close))
                j = min(close + 1, end)
            } else {
                let valueStart = k
                while k < end, !Self.isSpace(bytes[k]) { k += 1 }
                attributes.append(Attribute(name: name, value: valueStart..<k))
                j = k
            }
        }
        // `name`/`id` naming a sensitive field means the sibling `value`/`content` is the secret.
        let namesSensitiveField = attributes.contains { attribute in
            ["name", "id"].contains(attribute.name.lowercased())
                && attribute.value.map { isSensitiveField(String(decoding: bytes[$0], as: UTF8.self)) } == true
        }
        var masked: [(range: Range<Int>, replacement: [UInt8])] = []
        for attribute in attributes {
            guard let value = attribute.value else { continue }
            let lower = attribute.name.lowercased()
            if isSensitiveField(attribute.name) || (namesSensitiveField && (lower == "value" || lower == "content")) {
                masked.append((value, Array(Self.redactedValue.utf8)))
            } else if bytes[value].contains(UInt8(ascii: "=")) {
                // Any other value may be a URL (`href`, `src`, `action`, `content="0; url=..."`).
                let text = String(decoding: bytes[value], as: UTF8.self)
                let redacted = redactEmbeddedURLs(text)
                if redacted != text { masked.append((value, Array(redacted.utf8))) }
            }
        }
        guard !masked.isEmpty else { return Array(bytes[start..<end]) }
        var out: [UInt8] = []
        var cursor = start
        for item in masked.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) where item.range.lowerBound >= cursor {
            out.append(contentsOf: bytes[cursor..<item.range.lowerBound])
            out.append(contentsOf: item.replacement)
            cursor = item.range.upperBound
        }
        out.append(contentsOf: bytes[cursor..<end])
        return out
    }

    // MARK: Multipart scanning

    /// Line-based: after a `Content-Disposition` header naming a sensitive field, the part's body lines
    /// (up to the next boundary line starting with `--`) become one `[REDACTED]` line.
    private func redactMultipart(_ text: String) -> String {
        // components(separatedBy:) splits on UTF-16 units; a Swift Character would fuse "\r\n".
        let lines = text.components(separatedBy: "\n")
        var out: [String] = []
        var sensitivePart = false
        var inBody = false
        var emitted = false
        for line in lines {
            if line.hasPrefix("--") {
                sensitivePart = false
                inBody = false
                out.append(String(line))
                continue
            }
            if !inBody {
                let lower = line.lowercased()
                if lower.hasPrefix("content-disposition"), let range = lower.range(of: " name=") ?? lower.range(of: ";name=") {
                    var rest = lower[range.upperBound...]
                    if rest.hasPrefix("\"") { rest = rest.dropFirst() }
                    let name = rest.prefix { $0 != "\"" && $0 != ";" && $0 != "\r" }
                    sensitivePart = sensitivePart || isSensitiveField(String(name))
                }
                if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { inBody = true; emitted = false }
                out.append(String(line))
                continue
            }
            if sensitivePart {
                if !emitted {
                    out.append(Self.redactedValue + (line.hasSuffix("\r") ? "\r" : ""))
                    emitted = true
                }
            } else {
                out.append(String(line))
            }
        }
        return out.joined(separator: "\n")
    }
}
