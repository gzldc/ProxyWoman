import Foundation
import Localization
import Testing

private let sourceRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// Every Swift source file of the app target and of all packages (tests excluded), relative to the repository root.
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
    return files
}

@Suite(.productionChinese) struct LiteralKeyScanTests {
    /// A localization key is always written out in full (a `switch` from the case to its key), so a
    /// scan for key literals sees every key and "defined but never used" means something. Building a
    /// key from a prefix and a case name (`"a.b." + rawValue`, `"a.b.\(rawValue)"`) hides it.
    @Test func noProductionSourceBuildsALocalizationKeyFromAPrefix() throws {
        let files = try productionSources()
        #expect(files.count > 100)
        let concatenated = try NSRegularExpression(pattern: #""[a-z][A-Za-z0-9]*(\.[A-Za-z0-9]+)+\."\s*\+"#)
        let interpolated = try NSRegularExpression(pattern: #""[a-z][A-Za-z0-9]*(\.[A-Za-z0-9]+)+\.\\\("#)
        var offenders: [String] = []
        for file in files {
            let text = try String(contentsOf: sourceRoot.appendingPathComponent(file), encoding: .utf8)
            for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let code = String(line)
                guard !code.trimmingCharacters(in: .whitespaces).hasPrefix("//") else { continue }
                let range = NSRange(code.startIndex..., in: code)
                if concatenated.firstMatch(in: code, range: range) != nil || interpolated.firstMatch(in: code, range: range) != nil {
                    offenders.append("\(file):\(number + 1)")
                }
            }
        }
        #expect(offenders == [])
    }

    /// The families whose keys used to be built from a case name: every literal in them is defined in
    /// production zh-Hans (the fixture tables of the rewrite and mock families are checked by their own tests).
    @Test func everyFormerlyConcatenatedKeyLiteralIsDefinedInProduction() throws {
        let prefixes = ["webSocket.", "replay.blocked.", "settings.page.", "traffic.preset.", "traffic.error.",
                        "traffic.badge.", "compose.tab.", "compose.response.", "compose.body.mode.", "compose.issue.",
                        "rules.kind.", "rules.issue.", "rules.error.", "rules.mock.blocked.", "breakpoints.body.",
                        "breakpoints.issue.", "messagePane.tab."]
        let pattern = try NSRegularExpression(
            pattern: "\"((?:" + prefixes.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|") + #")[A-Za-z0-9_.]+)""#)
        var used: Set<String> = []
        for file in try productionSources() {
            let text = try String(contentsOf: sourceRoot.appendingPathComponent(file), encoding: .utf8)
            for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                used.insert((text as NSString).substring(with: match.range(at: 1)))
            }
        }
        #expect(used.count > 150)
        let url = try #require(L10n.bundle.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: "zh-Hans"))
        let production = try #require(NSDictionary(contentsOf: url) as? [String: String])
        #expect(used.subtracting(production.keys).sorted() == [])
    }
}
