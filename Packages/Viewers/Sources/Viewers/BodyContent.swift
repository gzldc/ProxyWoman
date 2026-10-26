import Foundation
import ImageIO
import Localization

/// The display modes of `BodyView`, in the order the picker shows them.
enum BodyMode: String, CaseIterable, Identifiable, Sendable {
    case json, text, hex, image

    var id: Self { self }

    var title: String {
        switch self {
        case .json: L10n.string("bodyContent.jsonMode")
        case .text: L10n.string("common.raw")
        case .hex: L10n.string("bodyContent.hexMode")
        case .image: L10n.string("bodyContent.image")
        }
    }
}

/// A decoded image, ready to draw: decoding happens off the main actor.
struct PreviewImage: Sendable {
    var cgImage: CGImage
    /// The size of the original image (`cgImage` may be scaled down).
    var pixelWidth: Int
    var pixelHeight: Int

    func dimensionsDescription(localizer: Localizer = L10n.localizer) -> String {
        localizer.format("imagePreview.pixelDimensions", arguments: [pixelWidth, pixelHeight])
    }
}

/// Everything `BodyView` shows for one body, prepared off the main actor: decompressed bytes,
/// the JSON tree, the (capped) text and the decoded image.
struct BodyContent: Sendable {
    /// The raw-text view shows at most this many UTF-8 bytes.
    static let textLimit = 2 * 1024 * 1024
    /// Larger bodies are not parsed into a JSON tree.
    static let jsonLimit = 10 * 1024 * 1024
    /// Longer image sides are scaled down for the preview.
    static let imageMaxPixelSize = 4096

    /// Decompressed bytes, or the bytes as given when decompression failed or was skipped.
    var data: Data
    /// Only a prefix of the body was given: it is shown as is, never decompressed or parsed.
    var isTruncated = false
    var decodeError: String?
    /// Only objects and arrays: a scalar is no tree worth showing.
    var json: JSONNode?
    /// The top-level rows of the JSON tree, built here so the main actor never does it.
    var jsonRoots: JSONChildren?
    /// Pretty-printed JSON or the decoded text, capped at `textLimit`; nil if not text.
    var text: String?
    /// Set only when `text` exists and was cut.
    var isTextTruncated = false
    var image: PreviewImage?

    var modes: [BodyMode] {
        (json != nil ? [.json] : []) + [.text, .hex] + (image != nil ? [.image] : [])
    }

    var defaultMode: BodyMode {
        if image != nil { return .image }
        if json != nil { return .json }
        return text != nil ? .text : .hex
    }

    /// The notice shown above a body that is only a prefix, or nil when the whole body is shown.
    /// `displayTruncated`: only `BodyView.displayLimit` bytes were loaded. `captureTruncated`: the
    /// proxy stopped recording after `recordedBytes`. `isEncoded`: the prefix is shown undecompressed.
    static func truncationNotice(
        displayTruncated: Bool, captureTruncated: Bool, recordedBytes: Int, isEncoded: Bool,
        localizer: Localizer = L10n.localizer
    ) -> String? {
        if displayTruncated {
            return localizer.format(
                isEncoded ? "bodyContent.encodedDisplayLimit" : "bodyContent.displayLimit",
                arguments: [BodyView.displayLimit / 1024 / 1024])
        }
        if captureTruncated {
            let size = ByteCountFormatter.string(fromByteCount: Int64(recordedBytes), countStyle: .file)
            return localizer.format(
                isEncoded ? "bodyContent.encodedCaptureLimit" : "bodyContent.captureLimit",
                arguments: [recordedBytes, size])
        }
        return nil
    }

    /// Never decodes an empty body: HEAD/204/304 responses carry Content-Encoding without bytes.
    static func make(
        data raw: Data, contentType: String?, contentEncoding: String?, isTruncated: Bool = false
    ) -> BodyContent {
        guard !Task.isCancelled else { return BodyContent(data: raw) }
        guard !raw.isEmpty else { return BodyContent(data: raw, text: "") }
        guard !isTruncated else {
            // A cut-off stream would not decompress, parse or decode as an image anyway.
            var content = BodyContent(data: raw, isTruncated: true)
            (content.text, content.isTextTruncated) = text(of: raw, contentType: contentType)
            return content
        }

        let decoded = BodyDecoder.decode(raw, contentEncoding: contentEncoding)
        var content = BodyContent(data: decoded.data, decodeError: decoded.error)
        let data = decoded.data
        guard !Task.isCancelled else { return content }

        if data.count <= jsonLimit, let node = try? JSONParser.parse(data) {
            guard !Task.isCancelled else { return content }
            // The separate tree tab accepts every JSON value, including a scalar root.
            content.jsonRoots = JSONTreeItem.roots(for: node)
            switch node {
            case .object, .array:
                content.json = node
            default: break
            }
        }

        guard !Task.isCancelled else { return content }
        if let json = content.json {
            (content.text, content.isTextTruncated) = truncated(json.prettyPrinted())
        } else {
            (content.text, content.isTextTruncated) = text(of: data, contentType: contentType)
        }

        guard !Task.isCancelled else { return content }
        content.image = previewImage(from: data)
        return content
    }

    /// Decodes at most `textLimit` bytes. The cut may split a multi-byte character, so the
    /// prefix backs off a few bytes until it decodes.
    private static func text(of data: Data, contentType: String?) -> (String?, Bool) {
        guard data.count > textLimit else { return (TextDecoding.string(from: data, contentType: contentType), false) }
        for backoff in 0..<4 {
            if let text = TextDecoding.string(from: data.prefix(textLimit - backoff), contentType: contentType) {
                return (text, true)
            }
        }
        return (nil, false)
    }

    /// Cuts `text` to at most `textLimit` UTF-8 bytes on a Unicode scalar boundary.
    private static func truncated(_ text: String) -> (String, Bool) {
        let utf8 = text.utf8
        guard utf8.count > textLimit else { return (text, false) }
        var end = utf8.index(utf8.startIndex, offsetBy: textLimit)
        while end > utf8.startIndex, UTF8.isContinuation(utf8[end]) {
            end = utf8.index(before: end)
        }
        return (String(text[..<end]), true)
    }

    /// Decodes the first image, scaled down to `imageMaxPixelSize`; nil if the bytes are no image.
    private static func previewImage(from data: Data) -> PreviewImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            CGImageSourceGetCount(source) > 0,
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: min(imageMaxPixelSize, max(width, height)),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return PreviewImage(cgImage: image, pixelWidth: width, pixelHeight: height)
    }
}
