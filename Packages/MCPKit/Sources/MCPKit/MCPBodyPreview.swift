import FlowStore
import Foundation
import MCPWire
import Viewers

/// Builds the body object `get_flow` returns for one message body (spec D14).
///
/// Output is `{size, shown, truncated, contentType, kind, encoding, text}` for a text body, or
/// `{size, contentType, kind, omitted}` when nothing may be shown. `omitted` is one of:
/// - `binary`: not a text content type, or the bytes are not valid text;
/// - `unavailable`: the stored body cannot be read (file removed, record cleared);
/// - `decode_failed`: the `Content-Encoding` could not be undone (corrupt, unsupported, too large, or a
///   capture that stopped early, which leaves an undecodable prefix of the compressed stream);
/// - `withheld_by_redaction`: with redaction on, the same rule that removes bodies from redacted exports
///   (`MCPRedactor.exposableContentType`: over 1 MiB, multipart, ...) hides it. The rule is applied to the
///   DECODED bytes, so a gzip body is shown when its decoded form qualifies.
///
/// `text` never exceeds the requested cap in UTF-8 bytes, also after redaction made it longer.
public struct MCPBodyPreview: Sendable, Equatable {
    public static let defaultMaxBytes = 16 * 1024
    public static let hardMaxBytes = 256 * 1024
    /// A compressed body larger than this is not decoded (a partial stream cannot be decoded).
    static let maxEncodedInputBytes = 8 * 1024 * 1024
    /// `Viewers.BodyDecoder` cannot return a prefix: when the output would exceed its limit it fails as a
    /// whole. So the limit is generous (the preview is cut afterwards) instead of `maxBytes + 1`.
    static let maxDecodedBytes = 8 * 1024 * 1024
    private static let readChunkBytes = 64 * 1024
    /// The (localized) text `BodyDecoder` reports when the output limit is hit, obtained by hitting it on
    /// purpose: a gzip stream of "ab" decoded with a limit of one byte. Lets a size failure be told from a
    /// corrupt stream without depending on the decoder's wording.
    static let outputLimitMessage: String? = BodyDecoder.decode(
        Data(base64Encoded: "H4sIAAAAAAAC/0tMAgBtSIOeAgAAAA==")!, contentEncoding: "gzip", maxOutputBytes: 1
    ).error

    public static func make(
        body: BodyRef?, store: FlowStore, headers: [HeaderField], truncatedAtCapture: Bool, maxBytes: Int,
        redactor: MCPRedactor
    ) async throws -> JSONValue {
        guard let body else { return .null }
        let cap = min(max(maxBytes, 0), hardMaxBytes)
        let contentType = headers.value(for: "content-type")
        let kind = ContentKind.classify(contentType: contentType)
        var base: [String: JSONValue] = [
            "size": .int(body.size),
            "kind": .string(kind.rawValue),
            "contentType": contentType.flatMap(MCPFlowSummary.contentTypeSummary)
                .map { .string(String(redactor.url($0).prefix(MCPFlowSummary.maxContentTypeLength))) } ?? .null,
        ]
        func omitted(_ reason: String, _ extra: [String: JSONValue] = [:]) -> JSONValue {
            base["omitted"] = .string(reason)
            for (key, value) in extra { base[key] = value }
            return .object(base)
        }

        guard MCPRedactor.textKinds.contains(kind) else { return omitted("binary") }

        let codings = headers.values(for: "content-encoding").flatMap { $0.split(separator: ",") }
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty && $0 != "identity" }
        let encoded = !codings.isEmpty
        // Only letters, digits and a few separators survive: this value comes from the wire.
        let encodingNames = JSONValue.string(
            String(codings.joined(separator: ", ").filter { $0.isASCII && ($0.isLetter || $0.isNumber || "-, ".contains($0)) }.prefix(64)))
        // The redaction rule looks at the message as the client would see it after decoding.
        let decodedHeaders = headers.filter { $0.name.caseInsensitiveCompare("content-encoding") != .orderedSame }
        if redactor.isEnabled,
            redactor.exposableContentType(headers: decodedHeaders, size: encoded ? 0 : body.size) == nil
        {
            return omitted("withheld_by_redaction")
        }

        if body.size == 0 {
            base["shown"] = .int(0)
            base["truncated"] = .bool(truncatedAtCapture)
            base["encoding"] = .null
            base["text"] = .string("")
            return .object(base)
        }

        if encoded, truncatedAtCapture || body.size > maxEncodedInputBytes {
            return omitted("decode_failed", ["encoding": encodingNames, "truncated": .bool(true)])
        }

        guard let lease = try? store.acquireBody(body) else { return omitted("unavailable") }
        defer { lease.cancel() }

        // Plain bodies need only a few times the cap (the text is cut at `cap` UTF-8 bytes); with
        // redaction on the whole body is read (at most 1 MiB, see the exposable rule) so that the
        // redactor never sees a value cut in the middle. Compressed bodies are needed whole.
        let readLimit: Int
        if encoded || redactor.isEnabled {
            readLimit = body.size
        } else {
            readLimit = min(body.size, cap * 4)
        }
        var raw = Data()
        do {
            while raw.count < readLimit {
                let chunk = try await lease.read(offset: raw.count, maxBytes: min(readChunkBytes, readLimit - raw.count))
                if chunk.isEmpty { break }
                raw.append(chunk)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return omitted("unavailable")
        }
        if raw.isEmpty && readLimit > 0 { return omitted("unavailable") }
        var incomplete = raw.count < readLimit

        var working = raw
        var totalAvailable = body.size
        var encodingName: JSONValue = .null
        if encoded {
            let decoded = BodyDecoder.decode(raw, contentEncoding: codings.joined(separator: ", "), maxOutputBytes: maxDecodedBytes)
            try Task.checkCancellation()
            guard decoded.error == nil, let applied = decoded.encoding else {
                // Too large to decode is, with redaction on, simply "over the exposable size".
                if redactor.isEnabled, decoded.error == outputLimitMessage {
                    return omitted("withheld_by_redaction")
                }
                return omitted("decode_failed", ["encoding": encodingNames, "truncated": .bool(truncatedAtCapture)])
            }
            encodingName = .string(applied)
            working = decoded.data
            raw = Data()
            totalAvailable = decoded.data.count
            incomplete = false
            base["decodedSize"] = .int(totalAvailable)
            if redactor.isEnabled, redactor.exposableContentType(headers: decodedHeaders, size: totalAvailable) == nil {
                return omitted("withheld_by_redaction")
            }
        }
        // Without redaction only the start of the (decoded) bytes is turned into text.
        let prefix: Data
        if redactor.isEnabled || working.count <= cap * 4 {
            prefix = working
        } else {
            prefix = Data(working.prefix(cap * 4))
        }
        let mayEndMidCharacter = prefix.count < totalAvailable || incomplete || truncatedAtCapture
        guard let text = decodeText(prefix, contentType: contentType, mayEndMidCharacter: mayEndMidCharacter) else {
            return omitted("binary")
        }
        let shownText = redactor.isEnabled ? redactor.bodyText(text, contentType: contentType) : text
        let (cut, wasCut) = cut(shownText, toBytes: cap)
        base["shown"] = .int(cut.utf8.count)
        base["truncated"] = .bool(wasCut || prefix.count < totalAvailable || incomplete || truncatedAtCapture)
        base["encoding"] = encodingName
        base["text"] = .string(cut)
        return .object(base)
    }

    /// The text of `data`; a body that was cut may end inside a multi-byte character, so up to three
    /// trailing bytes are dropped before giving up.
    private static func decodeText(_ data: Data, contentType: String?, mayEndMidCharacter: Bool) -> String? {
        if let text = TextDecoding.string(from: data, contentType: contentType) { return text }
        guard mayEndMidCharacter else { return nil }
        for dropped in 1...3 where data.count > dropped {
            if let text = TextDecoding.string(from: data.dropLast(dropped), contentType: contentType) { return text }
        }
        return nil
    }

    /// At most `limit` UTF-8 bytes, cut between characters.
    static func cut(_ text: String, toBytes limit: Int) -> (text: String, wasCut: Bool) {
        if text.utf8.count <= limit { return (text, false) }
        let scalars = text.unicodeScalars
        var index = scalars.startIndex
        var used = 0
        while index < scalars.endIndex {
            let width = UTF8.width(scalars[index])
            if used + width > limit { break }
            used += width
            index = scalars.index(after: index)
        }
        return (String(scalars[..<index]), true)
    }
}
