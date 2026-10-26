import Foundation
import Testing

@testable import RulesEngine

@Suite struct MIMETypesTests {
    static let table: [(String, String)] = [
        ("html", "text/html; charset=utf-8"),
        ("htm", "text/html; charset=utf-8"),
        ("css", "text/css; charset=utf-8"),
        ("js", "text/javascript; charset=utf-8"),
        ("mjs", "text/javascript; charset=utf-8"),
        ("json", "application/json; charset=utf-8"),
        ("map", "application/json; charset=utf-8"),
        ("txt", "text/plain; charset=utf-8"),
        ("xml", "application/xml; charset=utf-8"),
        ("csv", "text/csv; charset=utf-8"),
        ("md", "text/markdown; charset=utf-8"),
        ("svg", "image/svg+xml"),
        ("png", "image/png"),
        ("jpg", "image/jpeg"),
        ("jpeg", "image/jpeg"),
        ("gif", "image/gif"),
        ("webp", "image/webp"),
        ("avif", "image/avif"),
        ("ico", "image/x-icon"),
        ("bmp", "image/bmp"),
        ("woff", "font/woff"),
        ("woff2", "font/woff2"),
        ("ttf", "font/ttf"),
        ("otf", "font/otf"),
        ("wasm", "application/wasm"),
        ("pdf", "application/pdf"),
        ("mp4", "video/mp4"),
        ("webm", "video/webm"),
        ("mp3", "audio/mpeg"),
        ("wav", "audio/wav"),
        ("zip", "application/zip"),
    ]

    @Test(arguments: table) func everyExtensionInTheTable(_ ext: String, _ expected: String) {
        #expect(MIMETypes.contentType(forFileName: "file.\(ext)") == expected)
    }

    @Test func extensionMatchIsCaseInsensitive() {
        #expect(MIMETypes.contentType(forFileName: "INDEX.HTML") == "text/html; charset=utf-8")
        #expect(MIMETypes.contentType(forFileName: "Logo.Svg") == "image/svg+xml")
        #expect(MIMETypes.contentType(forFileName: "photo.JpEg") == "image/jpeg")
        #expect(MIMETypes.contentType(forFileName: "font.WOFF2") == "font/woff2")
    }

    @Test func missingOrUnknownExtensionIsOctetStream() {
        for name in ["Makefile", "README", "file.", "file.unknown", "file.htmlx", "file.exe", "", "html", "app.js.bak"] {
            #expect(MIMETypes.contentType(forFileName: name) == "application/octet-stream", "\(name)")
        }
    }

    @Test func onlyTheLastExtensionCounts() {
        #expect(MIMETypes.contentType(forFileName: "a.tar.gz") == "application/octet-stream")
        #expect(MIMETypes.contentType(forFileName: "bundle.min.js") == "text/javascript; charset=utf-8")
        #expect(MIMETypes.contentType(forFileName: "app.js.map") == "application/json; charset=utf-8")
        #expect(MIMETypes.contentType(forFileName: "archive.html.zip") == "application/zip")
    }

    @Test func nonASCIIAndControlBytesFallBack() {
        #expect(MIMETypes.contentType(forFileName: "页面.html") == "text/html; charset=utf-8")
        #expect(MIMETypes.contentType(forFileName: "a.\u{130}co") == "application/octet-stream")
        #expect(MIMETypes.contentType(forFileName: "a.ht\r\nml") == "application/octet-stream")
    }
}
