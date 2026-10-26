import FlowStore
import Foundation
import RulesEngine
import Testing

@testable import AppCore

/// Rules 2.0 R7, Task 12: hostile packs go through the real importer and leave nothing behind, and no pack or
/// template source can spawn a process, load code, touch the network or mutate the file system on its own.
@MainActor @Suite(.timeLimit(.minutes(2)), .productionChinese) struct RulePackIsolationTests {
    // MARK: hostile packs

    private struct Trace: Equatable {
        var ruleIDs: [UUID]
        var groupIDs: [UUID]
        var revision: UInt64
        var rulesFile: Data?
        var budgetBytes: [String: Int64]
        var files: Set<String>
    }

    private func trace(_ fixture: RulesFixture, _ model: RulesEditorModel) -> Trace {
        var files = Set<String>()
        if let names = FileManager.default.enumerator(atPath: fixture.root.path) {
            for case let name as String in names { files.insert(name) }
        }
        let bytes = fixture.budgets.snapshot().bytes
        return Trace(
            ruleIDs: model.rules.map(\.id), groupIDs: model.groups.map(\.id), revision: model.revision,
            rulesFile: try? Data(contentsOf: fixture.configFile),
            budgetBytes: Dictionary(uniqueKeysWithValues: bytes.map { ("\($0.key)", Int64($0.value)) }),
            files: files)
    }

    private func jsonArray<T: Encodable>(_ values: [T]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return "[" + (try values.map { String(decoding: try encoder.encode($0), as: UTF8.self) }).joined(separator: ",") + "]"
    }

    /// A structurally valid pack, built by hand so every part can be made hostile.
    private func pack(
        groups: [RuleGroup] = [], rules: [Rule] = [], files: [(id: UUID, name: String, data: Data)] = [],
        extra: [ZipEntryInput] = []
    ) throws -> Data {
        let records = files.map { #"{"id":"\#($0.id.uuidString)","displayName":\#(jsonString($0.name)),"size":\#($0.data.count)}"# }
        let content = #"{"groups":\#(try jsonArray(groups)),"rules":\#(try jsonArray(rules)),"assets":[\#(records.joined(separator: ","))]}"#
        let manifest = try JSONEncoder().encode(RulePackManifest(
            appVersion: "t", exportedAt: "2026-10-25T00:00:00Z", groupCount: groups.count, ruleCount: rules.count,
            assetCount: files.count))
        var entries = [ZipEntryInput(name: "manifest.json", data: manifest), ZipEntryInput(name: "rules.json", data: Data(content.utf8))]
        for file in files { entries.append(ZipEntryInput(name: "assets/" + file.id.uuidString.lowercased(), data: file.data)) }
        return try ZipWriter.write(entries + extra)
    }

    private func jsonString(_ text: String) -> String {
        String(decoding: (try? JSONEncoder().encode(text)) ?? Data(), as: UTF8.self)
    }

    private func fileRule(_ asset: UUID) -> Rule {
        Rule(name: "file", order: 0, actions: [RuleAction(.returnFile(MapLocalAction(assetID: asset, headers: [])))])
    }

    private struct Case {
        var name: String
        var data: Data
        /// nil: the pack is accepted for preview but nothing is written until confirmation.
        var expected: RulePackError?
    }

    private func corpus(limits: RulesLimits) throws -> [Case] {
        let fileID = UUID(), data = Data("body".utf8)
        let valid = try pack(rules: [fileRule(fileID)], files: [(fileID, "ok.txt", data)])

        // The entry name of the file becomes a path: same length, patched in the local and the central header.
        var traversal = valid
        let original = Data(("assets/" + fileID.uuidString.lowercased()).utf8)
        let patched = Data(("assets/" + String(repeating: "../", count: 12)).utf8)
        #expect(original.count == patched.count)
        while let range = traversal.range(of: original) { traversal.replaceSubrange(range, with: patched) }

        // 10 nested groups.
        var chain: [RuleGroup] = []
        for level in 0..<10 {
            chain.append(RuleGroup(name: "g\(level)", parentID: chain.last?.id, order: 0))
        }

        // 500 file entries nobody lists.
        let stray = (0..<500).map { _ in ZipEntryInput(name: "assets/" + UUID().uuidString.lowercased(), data: Data([1])) }
        // More entries than the pack may hold.
        let flood = (0..<(limits.packEntries + 1)).map { _ in ZipEntryInput(name: "assets/" + UUID().uuidString.lowercased(), data: Data()) }

        return try [
            Case(name: "path-form entry name", data: traversal, expected: .unsafeEntry),
            Case(name: "display name ../../x", data: try pack(
                rules: [fileRule(fileID)], files: [(fileID, "../../x", data)]), expected: nil),
            Case(name: "too many rules", data: try pack(
                rules: (0..<6).map { Rule(name: "r\($0)", order: $0, actions: [RuleAction(.hide)]) }),
                expected: .tooManyRules(have: 6, limit: limits.ruleCount)),
            Case(name: "ten nested groups", data: try pack(groups: chain), expected: nil),
            Case(name: "500 unlisted file entries", data: try pack(extra: stray), expected: .unexpectedEntry),
            Case(name: "entry flood", data: try pack(extra: flood), expected: .tooManyEntries),
            Case(name: "unknown entry", data: try pack(extra: [ZipEntryInput(name: "evil.sh", data: Data("rm -rf".utf8))]),
                 expected: .unexpectedEntry),
            Case(name: "random bytes", data: Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }), expected: .notAPack),
            Case(name: "directory mapping", data: try pack(rules: [Rule(
                name: "dir", order: 0, actions: [RuleAction(.returnDirectory(MapLocalDirectoryAction(
                    bookmark: Data([1, 2, 3]), displayName: "d"), pathPrefix: "/d/"))])]),
                expected: .directoryMapping),
            Case(name: "missing file", data: try pack(rules: [fileRule(UUID())]), expected: .missingAsset),
        ]
    }

    @Test func hostileCorpusLeavesNoTrace() async throws {
        var limits = RulesLimits()
        limits.ruleCount = 5
        let fixture = RulesFixture(); defer { fixture.remove() }
        let packs = FileManager.default.temporaryDirectory.appendingPathComponent("pw-hostile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: packs, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: packs) }

        let group = RuleGroup(name: "Mine", order: 1)
        let model = try await loadedModel(
            fixture, groups: [group], rules: [plainRule("keep", order: 0), plainRule("inside", group: group.id)], limits: limits)
        let client = RulePackClient.live(assets: fixture.assets, limits: limits, appVersion: "1")
        let before = trace(fixture, model)
        #expect(before.ruleIDs.count == 2)

        let cases = try corpus(limits: limits)
        for hostile in cases {
            let url = packs.appendingPathComponent("\(UUID().uuidString).pwrules")
            try hostile.data.write(to: url)
            let importer = RulePackImporter(model: model, client: client, localizer: zhLocalizer)
            await importer.begin(file: url)
            if let expected = hostile.expected {
                #expect(importer.phase == .failed(expected), "\(hostile.name): \(importer.phase)")
            } else {
                // Accepted for preview only: the user has not confirmed, so nothing is written.
                guard case .preview(let shown) = importer.phase else {
                    Issue.record("\(hostile.name): \(importer.phase)")
                    continue
                }
                // Ten nested groups are lifted, and the preview says so.
                if hostile.name == "ten nested groups" { #expect(!shown.warnings.isEmpty) }
                importer.cancel()
            }
            importer.dismiss()
            #expect(importer.phase == .idle, Comment(rawValue: hostile.name))
            #expect(trace(fixture, model) == before, "\(hostile.name) left a trace")
        }

        // The tolerated cases are neutralized, not just ignored.
        let neutral = try RulePackReader.inspect(cases[1].data, limits: limits)
        #expect(!neutral.assets[0].displayName.contains("/") && !neutral.assets[0].displayName.contains("\\"))
    }

    // MARK: sources

    private static let repositoryRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private static let directories = [
        "Packages/RulesEngine/Sources/RulesEngine/Pack",
        "Packages/RulesEngine/Sources/RulesEngine/Templates",
        "Packages/AppCore/Sources/AppCore/Rules/Pack",
    ]

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

    @Test func noPackSourceSpawnsProcessesOrTouchesTheNetwork() throws {
        let files = try Self.sources()
        // The scan is not vacuous: it reads all three directories.
        for directory in Self.directories { #expect(files.contains { $0.path.hasPrefix(directory) }, "\(directory)") }
        let forbidden = try NSRegularExpression(
            pattern: #"Process\(|NSTask|posix_spawn|dlopen|NSAppleScript|NWConnection|URLSession|createSymbolicLink|createDirectory|moveItem|copyItem|removeItem|replaceItem|FileHandle|Socket|NIO|ProxyCore"#)
        // Writing the exported pack to the place the user picked is the one file write; the managed asset
        // store (not these sources) does every copy of an imported file.
        let write = try NSRegularExpression(pattern: #"\.write\(to:"#)
        for (path, text) in files {
            let range = NSRange(text.startIndex..., in: text)
            let hits = forbidden.matches(in: text, range: range).map { (text as NSString).substring(with: $0.range) }
            #expect(hits.isEmpty, "\(path) uses \(hits)")
            let writes = write.numberOfMatches(in: text, range: range)
            #expect(writes == (path.hasSuffix("/RulePackClient.swift") ? 1 : 0), "\(path) writes a file \(writes) time(s)")
        }
    }
}
