import Foundation
import Testing

/// Execute is offline and read-only towards the live pipeline (spec 4.5, D13 / D14): its sources name no network
/// type and never hand the evaluator a hit counter.
@Suite struct ExecuteIsolationTests {
    private static let repositoryRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private static let directories = [
        "Packages/RulesEngine/Sources/RulesEngine/Execute",
        "Packages/AppCore/Sources/AppCore/Execute",
    ]

    /// Every Swift source under the two Execute directories: (relative path, text).
    private static func sources() throws -> [(path: String, text: String)] {
        var found: [(String, String)] = []
        for directory in directories {
            let url = repositoryRoot.appendingPathComponent(directory)
            let names = try #require(FileManager.default.enumerator(atPath: url.path), "\(directory) is missing")
            for case let name as String in names where name.hasSuffix(".swift") {
                found.append((directory + "/" + name, try String(contentsOf: url.appendingPathComponent(name), encoding: .utf8)))
            }
        }
        return found
    }

    @Test func noNetworkTypesInExecuteSources() throws {
        let files = try Self.sources()
        // The scan is not vacuous: it reads both directories.
        #expect(files.contains { $0.path.hasPrefix(Self.directories[0]) && $0.path.hasSuffix("ExecuteEngine.swift") })
        #expect(files.contains { $0.path.hasPrefix(Self.directories[1]) && $0.path.hasSuffix("ExecuteRunner.swift") })
        let forbidden = try NSRegularExpression(
            pattern: "NWConnection|URLSession|NIO|ProxyCore|ProxyServer|UpstreamConnector|Socket")
        for (path, text) in files {
            let hits = forbidden.matches(in: text, range: NSRange(text.startIndex..., in: text))
                .map { (text as NSString).substring(with: $0.range) }
            #expect(hits.isEmpty, "\(path) names a network type: \(hits)")
        }
    }

    @Test func engineNeverPassesAHitCounter() throws {
        let files = try Self.sources()
        let call = try NSRegularExpression(pattern: #"RuleEvaluator\s*\.\s*(connect|request|response|completion)\s*\("#)
        var calls = 0
        for (path, text) in files {
            #expect(!text.contains("RuleHitCounter"), "\(path) names RuleHitCounter")
            #expect(!text.contains("recordHit"), "\(path) records a hit")
            let utf16 = text as NSString
            for match in call.matches(in: text, range: NSRange(location: 0, length: utf16.length)) {
                calls += 1
                // The argument list: from the opening parenthesis to its matching one.
                let open = text.index(text.startIndex, offsetBy: match.range.upperBound)
                var depth = 1
                var index = open
                while index < text.endIndex, depth > 0 {
                    if text[index] == "(" { depth += 1 } else if text[index] == ")" { depth -= 1 }
                    if depth > 0 { index = text.index(after: index) }
                }
                let arguments = String(text[open..<index])
                #expect(arguments.contains("hits: nil"), "\(path): \(utf16.substring(with: match.range)) is called without `hits: nil`")
            }
        }
        // The engine calls all four evaluation points.
        #expect(calls >= 4)
    }
}
