import Foundation

/// The fixed `Content-Type` table for files served from a Map Local directory (spec F7).
public enum MIMETypes {
    public static let fallback = "application/octet-stream"

    /// Looks up the last extension of `name`, ASCII case-insensitively; unknown or missing extensions
    /// are `application/octet-stream`. Text types carry `; charset=utf-8`.
    public static func contentType(forFileName name: String) -> String {
        guard let dot = name.utf8.lastIndex(of: UInt8(ascii: ".")) else { return fallback }
        let ext = name.utf8[name.utf8.index(after: dot)...]
        guard !ext.isEmpty, ext.count <= 8, ext.allSatisfy({ $0 < 0x80 }) else { return fallback }
        let lowered = String(decoding: ext.map { (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains($0) ? $0 | 0x20 : $0 }, as: UTF8.self)
        return table[lowered] ?? fallback
    }

    private static let utf8 = "; charset=utf-8"

    private static let table: [String: String] = [
        "html": "text/html" + utf8,
        "htm": "text/html" + utf8,
        "css": "text/css" + utf8,
        "js": "text/javascript" + utf8,
        "mjs": "text/javascript" + utf8,
        "json": "application/json" + utf8,
        "map": "application/json" + utf8,
        "txt": "text/plain" + utf8,
        "xml": "application/xml" + utf8,
        "csv": "text/csv" + utf8,
        "md": "text/markdown" + utf8,
        "svg": "image/svg+xml",
        "png": "image/png",
        "jpg": "image/jpeg",
        "jpeg": "image/jpeg",
        "gif": "image/gif",
        "webp": "image/webp",
        "avif": "image/avif",
        "ico": "image/x-icon",
        "bmp": "image/bmp",
        "woff": "font/woff",
        "woff2": "font/woff2",
        "ttf": "font/ttf",
        "otf": "font/otf",
        "wasm": "application/wasm",
        "pdf": "application/pdf",
        "mp4": "video/mp4",
        "webm": "video/webm",
        "mp3": "audio/mpeg",
        "wav": "audio/wav",
        "zip": "application/zip",
    ]
}
