import Foundation
import Testing
@testable import RulesEngine

/// Builds packs with `ZipWriter`, each part breakable on its own.
enum RulePackFixtures {
    static func manifest(
        format: String = RulePackManifest.format, schema: Int = 1, rulesSchema: Int = 4, assetCount: Int = 0
    ) -> Data {
        let object: [String: Any] = [
            "format": format, "schema": schema, "rulesSchema": rulesSchema, "app": "ProxyWoman",
            "appVersion": "1.0", "exportedAt": "2026-10-25T00:00:00Z", "groupCount": 0, "ruleCount": 0,
            "assetCount": assetCount,
        ]
        return try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    static func content(
        groups: [RuleGroup] = [], rules: [Rule] = [], assets: [RulePackContent.AssetRecord] = []
    ) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try! encoder.encode(RulePackContent(groups: groups, rules: rules, assets: assets))
    }

    static func entryName(_ id: UUID) -> String { "assets/" + id.uuidString.lowercased() }

    /// `files` are stored AND listed; `listedOnly` are listed without an entry; `extra` are raw extra entries.
    static func makePack(
        groups: [RuleGroup] = [], rules: [Rule] = [],
        files: [(id: UUID, name: String, data: Data)] = [],
        listedOnly: [RulePackContent.AssetRecord] = [],
        recordSizeOffset: Int64 = 0,
        manifest: Data? = nil, rulesJSON: Data? = nil,
        omitManifest: Bool = false, omitRules: Bool = false,
        extra: [ZipEntryInput] = []
    ) -> Data {
        var records = files.map {
            RulePackContent.AssetRecord(id: $0.id, displayName: $0.name, size: Int64($0.data.count) + recordSizeOffset)
        }
        records += listedOnly
        var entries: [ZipEntryInput] = []
        if !omitManifest {
            entries.append(ZipEntryInput(name: "manifest.json", data: manifest ?? Self.manifest(assetCount: files.count)))
        }
        if !omitRules {
            entries.append(ZipEntryInput(
                name: "rules.json", data: rulesJSON ?? content(groups: groups, rules: rules, assets: records)))
        }
        for file in files { entries.append(ZipEntryInput(name: entryName(file.id), data: file.data)) }
        entries += extra
        return try! ZipWriter.write(entries)
    }
}

private func plain(_ name: String, group: UUID? = nil) -> Rule {
    Rule(name: name, groupID: group, actions: [RuleAction(.hide)])
}

private func fileRule(_ name: String, asset: UUID) -> Rule {
    Rule(name: name, actions: [RuleAction(.returnFile(MapLocalAction(assetID: asset, headers: [])))])
}

private func badRegexRule() -> Rule {
    Rule(name: "bad", actions: [RuleAction(.rewriteBody(
        direction: .response, BodyRewriteAction(find: "[a-", replacement: "x", syntax: .regex)))])
}

private func expectFailure(_ data: Data, _ expected: RulePackError, limits: RulesLimits = RulesLimits(),
                           sourceLocation: SourceLocation = #_sourceLocation) {
    do {
        _ = try RulePackReader.inspect(data, limits: limits)
        Issue.record("expected \(expected)", sourceLocation: sourceLocation)
    } catch let error as RulePackError {
        #expect(error == expected, sourceLocation: sourceLocation)
    } catch {
        Issue.record("unexpected \(error)", sourceLocation: sourceLocation)
    }
}

@Suite struct RulePackReaderTests {
    @Test func validPackProducesAPreviewWithCounts() throws {
        let group = RuleGroup(name: "G")
        let id = UUID()
        let body = Data("hello".utf8)
        let pack = RulePackFixtures.makePack(
            groups: [group], rules: [plain("a", group: group.id), fileRule("f", asset: id)],
            files: [(id, "body.txt", body)])
        let preview = try RulePackReader.inspect(pack, limits: RulesLimits())
        #expect(preview.groups == [group])
        #expect(preview.rules.count == 2)
        #expect(preview.assets.count == 1)
        #expect(preview.assets[0].id == id && preview.assets[0].size == 5)
        #expect(preview.assets[0].entryName == RulePackFixtures.entryName(id))
        #expect(preview.totalAssetBytes == 5)
        #expect(preview.ignoredAssetCount == 0)
        #expect(try preview.assetData(preview.assets[0]) == body)
    }

    @Test func notAZipIsNotAPack() {
        expectFailure(Data("just some text, long enough to pass the length check".utf8), .notAPack)
        expectFailure(Data(), .notAPack)
        expectFailure(Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]), .notAPack)
    }

    @Test func wrongFormatStringIsNotThisFormat() {
        expectFailure(RulePackFixtures.makePack(manifest: RulePackFixtures.manifest(format: "other")), .notThisFormat)
        expectFailure(RulePackFixtures.makePack(manifest: Data("[1,2]".utf8)), .notThisFormat)
        expectFailure(RulePackFixtures.makePack(manifest: Data("not json".utf8)), .notThisFormat)
    }

    @Test func missingManifestOrRulesIsNotThisFormat() {
        expectFailure(RulePackFixtures.makePack(omitManifest: true), .notThisFormat)
        expectFailure(RulePackFixtures.makePack(omitRules: true), .notThisFormat)
    }

    @Test func newerManifestSchemaIsRefusedWithItsNumber() {
        expectFailure(RulePackFixtures.makePack(manifest: RulePackFixtures.manifest(schema: 2)), .newerVersion(2))
    }

    @Test func newerRulesSchemaIsRefused() {
        expectFailure(RulePackFixtures.makePack(manifest: RulePackFixtures.manifest(rulesSchema: 5)), .newerVersion(5))
    }

    @Test func olderRulesSchemaIsNotThisFormat() {
        expectFailure(RulePackFixtures.makePack(manifest: RulePackFixtures.manifest(rulesSchema: 3)), .notThisFormat)
        expectFailure(RulePackFixtures.makePack(manifest: RulePackFixtures.manifest(schema: 0)), .notThisFormat)
    }

    @Test func undecodableRulesOfAKnownManifestSaySupportedByNewerVersion() {
        let json = #"{"groups":[],"rules":[{"id":"\#(UUID().uuidString)","name":"x","actions":[{"kind":{"teleport":{}}}]}],"assets":[]}"#
        expectFailure(RulePackFixtures.makePack(rulesJSON: Data(json.utf8)), .undecodableContent)
        expectFailure(RulePackFixtures.makePack(rulesJSON: Data("garbage".utf8)), .undecodableContent)
    }

    @Test func extraEntryIsRefused() {
        for name in ["__MACOSX/x", ".DS_Store", "notes.txt"] {
            let extra = [ZipEntryInput(name: name, data: Data("x".utf8))]
            expectFailure(RulePackFixtures.makePack(extra: extra), .unexpectedEntry)
        }
    }

    @Test func zeroByteEntryWithAnUnknownNameIsStillRefused() {
        let extra = [ZipEntryInput(name: "mystery", data: Data())]
        expectFailure(RulePackFixtures.makePack(extra: extra), .unexpectedEntry)
    }

    @Test func assetEntryNameMustBeAUUID() {
        for name in ["assets/readme", "assets/sub/" + UUID().uuidString.lowercased(),
                     "assets/" + UUID().uuidString.uppercased()] {
            let extra = [ZipEntryInput(name: name, data: Data("x".utf8))]
            expectFailure(RulePackFixtures.makePack(extra: extra), .unexpectedEntry)
        }
    }

    @Test func anAssetEntryNoRecordListsIsRefused() {
        let extra = [ZipEntryInput(name: RulePackFixtures.entryName(UUID()), data: Data("x".utf8))]
        expectFailure(RulePackFixtures.makePack(extra: extra), .unexpectedEntry)
    }

    @Test func invalidRuleRefusesTheWholePack() {
        expectFailure(RulePackFixtures.makePack(rules: [plain("ok"), badRegexRule()]), .invalidRule(index: 1))
    }

    @Test func handwrittenResponseConflictsAreRefused() {
        let bad = Rule(name: "hw", actions: [RuleAction(.returnHandwritten(HandwrittenResponse(text: "HTTP/2 200 OK")))])
        expectFailure(RulePackFixtures.makePack(rules: [plain("ok"), bad]), .invalidRule(index: 1))
    }

    @Test func duplicateIDsOrUnknownGroupOrCycleRefused() {
        let rule = plain("a")
        expectFailure(RulePackFixtures.makePack(rules: [rule, rule]), .invalidStructure)
        let group = RuleGroup(name: "G")
        expectFailure(RulePackFixtures.makePack(groups: [group, group]), .invalidStructure)
        expectFailure(RulePackFixtures.makePack(rules: [plain("a", group: UUID())]), .invalidStructure)
        var a = RuleGroup(name: "A"), b = RuleGroup(name: "B")
        a.parentID = b.id
        b.parentID = a.id
        expectFailure(RulePackFixtures.makePack(groups: [a, b]), .invalidStructure)
        let id = UUID()
        let listedTwice = RulePackContent.AssetRecord(id: id, displayName: "x", size: 1)
        expectFailure(RulePackFixtures.makePack(listedOnly: [listedTwice, listedTwice]), .invalidStructure)
    }

    @Test func overDeepGroupsAreNotRefusedHere() throws {
        var groups: [RuleGroup] = []
        for depth in 0..<5 {
            groups.append(RuleGroup(name: "g\(depth)", parentID: groups.last?.id))
        }
        let limits = RulesLimits(groupDepth: 2)
        let preview = try RulePackReader.inspect(RulePackFixtures.makePack(groups: groups), limits: limits)
        #expect(preview.groups.count == 5)
    }

    @Test func tooManyGroupsRefused() {
        let groups = (0..<3).map { RuleGroup(name: "g\($0)") }
        expectFailure(RulePackFixtures.makePack(groups: groups), .invalidStructure, limits: RulesLimits(packGroups: 2))
    }

    @Test func overLongGroupNameIsRefused() {
        let limits = RulesLimits()
        let long = RuleGroup(name: String(repeating: "g", count: limits.fieldBytes + 1))
        expectFailure(RulePackFixtures.makePack(groups: [long]), .invalidStructure)
        let edge = RuleGroup(name: String(repeating: "g", count: limits.fieldBytes))
        #expect((try? RulePackReader.inspect(RulePackFixtures.makePack(groups: [edge]), limits: limits)) != nil)
    }

    @Test func overLongNoteIsRefusedWithItsIndex() {
        let limits = RulesLimits()
        var long = plain("n")
        long.note = String(repeating: "n", count: limits.fieldBytes + 1)
        expectFailure(RulePackFixtures.makePack(rules: [plain("ok"), long]), .invalidRule(index: 1))
        var edge = plain("e")
        edge.note = String(repeating: "n", count: limits.fieldBytes)
        #expect((try? RulePackReader.inspect(RulePackFixtures.makePack(rules: [edge]), limits: limits)) != nil)
    }

    @Test func moreRulesThanTheCapAreRefusedBeforeValidating() {
        // The bad rule would be .invalidRule if validation ran first; the count check comes first.
        let rules = (0..<4).map { plain("r\($0)") } + [badRegexRule()]
        expectFailure(RulePackFixtures.makePack(rules: rules), .tooManyRules(have: 5, limit: 3), limits: RulesLimits(ruleCount: 3))
    }

    @Test func directoryMappingIsRefused() {
        let rule = Rule(name: "dir", actions: [RuleAction(.returnDirectory(
            MapLocalDirectoryAction(bookmark: Data([1]), displayName: "d"), pathPrefix: "/"))])
        expectFailure(RulePackFixtures.makePack(rules: [rule]), .directoryMapping)
    }

    @Test func missingOrMismatchedAssetIsRefused() {
        let id = UUID()
        let body = Data("12345".utf8)
        // Listed and referenced, no entry.
        let record = RulePackContent.AssetRecord(id: id, displayName: "x", size: 5)
        expectFailure(RulePackFixtures.makePack(rules: [fileRule("f", asset: id)], listedOnly: [record]), .missingAsset)
        // Referenced but not listed at all.
        expectFailure(RulePackFixtures.makePack(rules: [fileRule("f", asset: UUID())]), .missingAsset)
        // Declared size differs from the entry.
        expectFailure(
            RulePackFixtures.makePack(rules: [fileRule("f", asset: id)], files: [(id, "x", body)], recordSizeOffset: 1),
            .assetMismatch)
    }

    @Test func assetOverPackAssetBytesRefused() {
        let id = UUID()
        let limits = RulesLimits(packAssetBytes: 4)
        let pack = RulePackFixtures.makePack(rules: [fileRule("f", asset: id)], files: [(id, "x", Data("12345".utf8))])
        expectFailure(pack, .assetTooLarge(limit: 4), limits: limits)
    }

    @Test func unreferencedAssetsAreIgnoredAndCounted() throws {
        let used = UUID(), unused = UUID()
        let pack = RulePackFixtures.makePack(
            rules: [fileRule("f", asset: used)], files: [(used, "a", Data("a".utf8)), (unused, "b", Data("bb".utf8))])
        let preview = try RulePackReader.inspect(pack, limits: RulesLimits())
        #expect(preview.assets.map(\.id) == [used])
        #expect(preview.ignoredAssetCount == 1)
        #expect(preview.totalAssetBytes == 1)
    }

    @Test func displayNameIsSanitized() throws {
        let id = UUID()
        let hostile = "../../etc/passwd\u{0}\u{7}\r\nfile\\x"
        let pack = RulePackFixtures.makePack(rules: [fileRule("f", asset: id)], files: [(id, hostile, Data("a".utf8))])
        let name = try RulePackReader.inspect(pack, limits: RulesLimits()).assets[0].displayName
        #expect(!name.contains("/") && !name.contains("\\"))
        #expect(!name.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F })
        #expect(name.contains("passwd") && name.contains("file"))
        let preview = try RulePackReader.inspect(pack, limits: RulesLimits(fieldBytes: 4))
        #expect(preview.assets[0].displayName.utf8.count <= 4)
        let empty = RulePackFixtures.makePack(rules: [fileRule("f", asset: id)], files: [(id, "///", Data("a".utf8))])
        #expect(try RulePackReader.inspect(empty, limits: RulesLimits()).assets[0].displayName == "")
        // The entry name is the generated one, never the display name.
        #expect(try RulePackReader.inspect(pack, limits: RulesLimits()).assets[0].entryName == RulePackFixtures.entryName(id))
    }

    @Test func rejectsWithoutSideEffects() throws {
        let root = makeTempDirectory()
        defer { removeTree(root) }
        let limits = RulesLimits()
        let store = ManagedAssetStore(
            directory: root.appendingPathComponent("assets"), limits: limits,
            budgets: OwnedFileBudgets(limits: limits, freeDiskBytes: ample))
        let before = names(in: root)
        let id = UUID()
        let hostile = [
            RulePackFixtures.makePack(rules: [plain("ok"), badRegexRule()]),
            RulePackFixtures.makePack(extra: [ZipEntryInput(name: "notes.txt", data: Data("x".utf8))]),
            RulePackFixtures.makePack(rules: [fileRule("f", asset: id)], files: [(id, "../../x", Data("12".utf8))],
                                  recordSizeOffset: 3),
        ]
        for pack in hostile { #expect(throws: RulePackError.self) { try RulePackReader.inspect(pack, limits: limits) } }
        // A good pack is also pure.
        _ = try RulePackReader.inspect(
            RulePackFixtures.makePack(rules: [fileRule("f", asset: id)], files: [(id, "../../x", Data("12".utf8))]),
            limits: limits)
        #expect(names(in: root).subtracting(before).subtracting(["assets"]).isEmpty)
        #expect(names(in: root.appendingPathComponent("assets")).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("x").path))
        _ = store
    }

    @Test func packLargerThanTheCapIsRefusedBeforeReading() throws {
        let root = makeTempDirectory()
        defer { removeTree(root) }
        let file = writeFile(root.appendingPathComponent("big.pwrules"), Data(count: 11))
        // Unreadable: a size check that came after reading would report readFailed instead.
        chmod(file.path, 0)
        defer { chmod(file.path, 0o600) }
        do {
            _ = try RulePackReader.inspect(fileAt: file, limits: RulesLimits(packFileBytes: 10))
            Issue.record("expected tooLarge")
        } catch let error as RulePackError {
            #expect(error == .tooLarge(limit: 10))
        }
    }

    @Test func fileInspectionReadsAValidPack() throws {
        let root = makeTempDirectory()
        defer { removeTree(root) }
        let file = writeFile(root.appendingPathComponent("a.pwrules"), RulePackFixtures.makePack(rules: [plain("a")]))
        #expect(try RulePackReader.inspect(fileAt: file, limits: RulesLimits()).rules.count == 1)
        let missing = root.appendingPathComponent("none.pwrules")
        #expect(throws: RulePackError.readFailed) { try RulePackReader.inspect(fileAt: missing, limits: RulesLimits()) }
    }

    @Test func farxExtensionIsReportedNotParsed() throws {
        let root = makeTempDirectory()
        defer { removeTree(root) }
        let file = writeFile(root.appendingPathComponent("x.FARX"), RulePackFixtures.makePack(rules: [plain("a")]))
        #expect(throws: RulePackError.farxUnsupported) { try RulePackReader.inspect(fileAt: file, limits: RulesLimits()) }
        let absent = root.appendingPathComponent("y.farx")
        #expect(throws: RulePackError.farxUnsupported) { try RulePackReader.inspect(fileAt: absent, limits: RulesLimits()) }
    }

    @Test func zipErrorsMapToPackErrors() {
        let limits = RulesLimits()
        let table: [(ZipError, RulePackError)] = [
            (.entryTooLarge, .exportTooLarge),
            (.invalidName, .unsafeEntry),
            (.notAnArchive, .notAPack),
            (.tooLarge, .tooLarge(limit: limits.packFileBytes)),
            (.tooManyEntries, .tooManyEntries),
            (.expandedTooLarge, .expandedTooLarge),
            (.entryTooBig("assets/" + UUID().uuidString.lowercased()), .assetTooLarge(limit: limits.packAssetBytes)),
            (.entryTooBig("manifest.json"), .tooLarge(limit: limits.packManifestBytes)),
            (.entryTooBig("rules.json"), .tooLarge(limit: limits.configBytes)),
            (.entryTooBig("zzz"), .unexpectedEntry),
            (.unsafeName("../x"), .unsafeEntry),
            (.duplicateName("x"), .duplicateEntry),
            (.encrypted("x"), .encrypted),
            (.unsupportedMethod("x"), .unsupportedCompression),
            (.symlinkOrSpecial("x"), .symlink),
            (.zip64, .tooLarge(limit: limits.packFileBytes)),
            (.corrupt, .corrupt),
            (.crcMismatch("x"), .corrupt),
            (.sizeMismatch("x"), .corrupt),
            (.overlap, .corrupt),
        ]
        for (zip, pack) in table { #expect(RulePackError(zip) == pack, "\(zip)") }
    }

    @Test func zipFailuresSurfaceAsPackErrors() {
        var pack = RulePackFixtures.makePack(rules: [plain("a")])
        pack[pack.count - 30] ^= 0xFF
        #expect(throws: RulePackError.self) { try RulePackReader.inspect(pack, limits: RulesLimits()) }
        expectFailure(RulePackFixtures.makePack(rules: [plain("a")]), .tooLarge(limit: 10), limits: RulesLimits(packFileBytes: 10))
    }
}
