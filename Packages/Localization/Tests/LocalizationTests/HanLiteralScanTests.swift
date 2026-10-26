import Foundation
import Localization
import Testing
@testable import ProxyCore

private let sourceRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// Every non-test Swift source of the app and of all packages, relative to the repository root.
private func productionSources() throws -> [String] {
    var files: [String] = []
    var roots = [sourceRoot.appendingPathComponent("App")]
    let packages = sourceRoot.appendingPathComponent("Packages")
    for package in try FileManager.default.contentsOfDirectory(atPath: packages.path) {
        roots.append(packages.appendingPathComponent(package).appendingPathComponent("Sources"))
    }
    for directory in roots {
        guard let enumerator = FileManager.default.enumerator(atPath: directory.path) else { continue }
        for case let name as String in enumerator where name.hasSuffix(".swift") {
            files.append(String(directory.appendingPathComponent(name).path.dropFirst(sourceRoot.path.count + 1)))
        }
    }
    return files.sorted()
}

private func isHan(_ scalar: Unicode.Scalar) -> Bool {
    (0x4E00...0x9FFF).contains(scalar.value) || (0x3400...0x4DBF).contains(scalar.value)
}

/// The string literals of a Swift source that contain Han characters, as `(line, literal)`.
/// Comments are skipped; interpolations count as part of their literal.
func hanStringLiterals(in source: String) -> [(line: Int, literal: String)] {
    enum State { case code, lineComment, blockComment, string, multilineString }
    var found: [(Int, String)] = []
    let chars = Array(source.unicodeScalars)
    var state = State.code
    var blockDepth = 0
    var line = 1
    var literalStart = 0
    var literalLine = 1
    var index = 0
    func hasHan(_ range: Range<Int>) -> Bool { chars[range].contains(where: isHan) }
    func text(_ range: Range<Int>) -> String {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: chars[range])
        return String(view)
    }
    while index < chars.count {
        let c = chars[index]
        let next: Unicode.Scalar? = index + 1 < chars.count ? chars[index + 1] : nil
        let third: Unicode.Scalar? = index + 2 < chars.count ? chars[index + 2] : nil
        if c == "\n" { line += 1 }
        switch state {
        case .code:
            if c == "/", next == "/" { state = .lineComment; index += 1 }
            else if c == "/", next == "*" { state = .blockComment; blockDepth = 1; index += 1 }
            else if c == "\"", next == "\"", third == "\"" {
                state = .multilineString; literalStart = index; literalLine = line; index += 2
            } else if c == "\"" {
                state = .string; literalStart = index; literalLine = line
            }
        case .lineComment:
            if c == "\n" { state = .code }
        case .blockComment:
            if c == "/", next == "*" { blockDepth += 1; index += 1 }
            else if c == "*", next == "/" {
                blockDepth -= 1; index += 1
                if blockDepth == 0 { state = .code }
            }
        case .string:
            if c == "\\", next == "(" {
                // Skip the interpolation: balanced parentheses, nested strings included.
                var depth = 1
                index += 2
                while index < chars.count, depth > 0 {
                    if chars[index] == "\n" { line += 1 }
                    if chars[index] == "(" { depth += 1 } else if chars[index] == ")" { depth -= 1 }
                    index += 1
                }
                index -= 1
            } else if c == "\\" {
                index += 1
            } else if c == "\"" {
                let range = literalStart..<(index + 1)
                if hasHan(range) { found.append((literalLine, text(range))) }
                state = .code
            }
        case .multilineString:
            if c == "\\" { index += 1 }
            else if c == "\"", next == "\"", third == "\"" {
                let range = literalStart..<(index + 3)
                if hasHan(range) { found.append((literalLine, text(range))) }
                state = .code; index += 2
            }
        }
        index += 1
    }
    return found
}

/// A string literal with Han characters in production code needs a reason to exist here.
/// Everything the user can see goes through `L10n`; log, precondition and diagnostic text is English.
private let allowedHanLiterals: [(file: String, literal: String, reason: String)] = [
    ("Packages/FlowStore/Sources/FlowStore/FlowGrouping.swift", "\"未知\"",
     "Stable group key of records without client information; pinned apps and selections are stored under it. "
        + "Views show SourceBarItem.appDisplayName, which is localized."),
    ("Packages/Localization/Sources/Localization/LanguagePreference.swift", "\"简体中文\"",
     "The language picker names each language in that language (autonym), whatever the interface language is."),
]

@Suite(.productionChinese) struct HanLiteralScanTests {
    @Test func scannerFindsLiteralsAndSkipsComments() {
        let source = """
            // 注释 "中文"
            /* 块 /* 嵌套 */ 注释 */
            let a = "plain"
            let b = "中文 \\(name) 字"
            let c = "x \\("内部" + y) z"
            /// 文档 comment
            let d = \"\"\"
            多行
            \"\"\"
            """
        let hits = hanStringLiterals(in: source)
        #expect(hits.map(\.line) == [4, 5, 7])
    }

    @Test func noProductionStringLiteralContainsHanCharactersOutsideTheAllowlist() throws {
        let files = try productionSources()
        #expect(files.count > 100)
        var offenders: [String] = []
        var used: Set<Int> = []
        for file in files {
            let text = try String(contentsOf: sourceRoot.appendingPathComponent(file), encoding: .utf8)
            for hit in hanStringLiterals(in: text) {
                if let slot = allowedHanLiterals.firstIndex(where: { $0.file == file && $0.literal == hit.literal }) {
                    used.insert(slot)
                } else {
                    offenders.append("\(file):\(hit.line) \(hit.literal)")
                }
            }
        }
        #expect(offenders == [])
        #expect(used.count == allowedHanLiterals.count, "an allowlist entry no longer matches any literal")
    }
}

@Suite(.productionChinese) struct ProxyFailureLocalizationTests {
    private let en = Localizer(bundle: L10n.bundle, preferredLanguages: ["en"])

    @Test func upstreamProxyReasonsFollowTheLanguage() {
        let cases: [(UpstreamProxyError, String, String)] = [
            (.rejected(status: 403), "上游代理拒绝了 CONNECT（403）", "The upstream proxy rejected CONNECT (403)"),
            (.invalidResponse, "上游代理的响应无效", "The upstream proxy’s response is invalid"),
            (.closed, "上游代理关闭了连接", "The upstream proxy closed the connection"),
            (.timedOut, "上游代理响应超时", "The upstream proxy timed out"),
        ]
        for (error, zh, english) in cases {
            #expect(UpstreamConnector.describe(error) == zh)
            #expect(UpstreamConnector.describe(error, localizer: en) == english)
        }
        let unreachable = UpstreamProxyError.unreachable(proxy: "127.0.0.1:1", underlying: UpstreamProxyError.closed)
        #expect(UpstreamConnector.describe(unreachable, localizer: en)
            == "Upstream proxy 127.0.0.1:1: The upstream proxy closed the connection")
    }

    @Test func everyProxyFailureKeyIsTranslatedAndFreeOfChineseInEnglish() throws {
        let sources = try ["UpstreamConnector", "TLSInterception", "ProxyHandler", "HTTPExchange", "ClientConnectionContext"]
            .map { try String(contentsOf: sourceRoot.appendingPathComponent("Packages/ProxyCore/Sources/ProxyCore/\($0).swift"), encoding: .utf8) }
            .joined()
        let pattern = try NSRegularExpression(pattern: #""(proxyFailure\.[A-Za-z]+)""#)
        let keys = Set(pattern.matches(in: sources, range: NSRange(sources.startIndex..., in: sources)).map {
            String(sources[Range($0.range(at: 1), in: sources)!])
        })
        #expect(keys.count >= 20)
        for key in keys {
            let value = en.string(key)
            #expect(value != key, "\(key)")
            #expect(!value.unicodeScalars.contains(where: isHan), "\(key)")
        }
    }
}
