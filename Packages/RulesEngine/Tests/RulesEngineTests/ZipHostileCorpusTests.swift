import Foundation
import Testing

@testable import RulesEngine

/// Each case changes one structural fact of an otherwise valid archive and expects the exact `ZipError`.
@Suite("Zip hostile corpus")
struct ZipHostileCorpusTests {
    static let roomy: @Sendable (String) -> Int = { _ in 4 * 1024 * 1024 }

    private func open(
        _ fixture: FixtureArchive, limits: RulesLimits = RulesLimits(), entryLimit: @escaping (String) -> Int = roomy
    ) throws -> ZipArchive {
        try ZipArchive.open(fixture.bytes(), limits: limits, entryLimit: entryLimit)
    }

    private func one(_ entry: FixtureEntry) -> FixtureArchive { FixtureArchive([entry]) }
    private func plain(_ name: String = "a") -> FixtureEntry { FixtureEntry(name, Data("payload".utf8)) }

    /// A small valid pack with stored and deflated entries, for truncation and bit flips.
    private func validPack() throws -> Data {
        try ZipWriter.write([
            ZipEntryInput(name: "manifest.json", data: Data(#"{"format":"proxywoman-rules","schema":1}"#.utf8)),
            ZipEntryInput(name: "rules.json", data: Data(String(repeating: #"{"rule":1},"#, count: 30).utf8)),
            ZipEntryInput(name: "assets/0f0e0d0c-0000-4000-8000-000000000001", data: Data([1, 2, 3, 4, 5, 6, 7])),
        ])
    }

    // MARK: names

    @Test func pathTraversalNames() {
        let names = [
            "../a", "a/../b", "/abs", "a//b", "./a", "a\\b", "a\u{0}b", "a\u{1}b", "a\u{7F}b", "a\u{85}b",
            String(repeating: "n", count: 256), "assets/..", "a/.", "a\u{202E}b", "a\u{200B}b", "\u{FEFF}a",
            "a\u{2028}b",
        ]
        for name in names {
            var entry = plain(name)
            if name.utf8.contains(where: { $0 >= 0x80 }) { entry.flags = 0x0800 }
            #expect(throws: ZipError.unsafeName(name), "\(name.debugDescription)") { try open(one(entry)) }
        }
    }

    @Test func nameBytesMustBeUTF8AndFlagged() {
        var invalid = FixtureEntry(rawName: [0x61, 0xFF, 0x62], Data())
        invalid.flags = 0x0800
        #expect(throws: ZipError.self) { try open(one(invalid)) }
        do {
            _ = try open(one(invalid))
        } catch let error as ZipError {
            guard case .unsafeName = error else { Issue.record("got \(error)"); return }
        } catch { Issue.record("got \(error)") }

        // Non-ASCII without the UTF-8 flag would be CP437 to other tools: ambiguous, refused.
        let unflagged = plain("assets/é")
        #expect(throws: ZipError.unsafeName("assets/é")) { try open(one(unflagged)) }
    }

    @Test func directoryEntryRefused() {
        #expect(throws: ZipError.unsafeName("assets/")) { try open(one(FixtureEntry("assets/", Data()))) }
    }

    @Test func duplicateNamesIncludingCaseFold() {
        #expect(throws: ZipError.duplicateName("a")) { try open(FixtureArchive([plain("a"), plain("a")])) }
        #expect(throws: ZipError.duplicateName("RULES.json")) {
            try open(FixtureArchive([plain("rules.json"), plain("RULES.json")]))
        }
        // NFC vs NFD of the same name.
        var nfc = plain("assets/\u{E9}")
        nfc.flags = 0x0800
        var nfd = plain("assets/e\u{301}")
        nfd.flags = 0x0800
        #expect(throws: ZipError.duplicateName("assets/e\u{301}")) { try open(FixtureArchive([nfc, nfd])) }
        // KELVIN SIGN folds to k.
        var kelvin = plain("\u{212A}.json")
        kelvin.flags = 0x0800
        #expect(throws: ZipError.duplicateName("\u{212A}.json")) { try open(FixtureArchive([plain("k.json"), kelvin])) }
    }

    // MARK: entry kinds

    @Test func encryptedFlagRefused() {
        for flag: UInt16 in [0x0001, 0x0040, 0x2000] {
            var entry = plain()
            entry.flags = flag
            #expect(throws: ZipError.encrypted("a")) { try open(one(entry)) }
        }
        var aes = plain()
        aes.centralExtra = Data([0x01, 0x99, 0x07, 0x00, 0x02, 0x00, 0x41, 0x45, 0x03, 0x08, 0x00])
        #expect(throws: ZipError.encrypted("a")) { try open(one(aes)) }
    }

    @Test func unknownFlagBitRefused() {
        var entry = plain()
        entry.flags = 0x0010
        #expect(throws: ZipError.corrupt) { try open(one(entry)) }
    }

    @Test func unknownMethodRefused() {
        for method: UInt16 in [12, 14, 9, 1, 99] {
            var entry = plain()
            entry.method = method
            entry.payload = Data("payload".utf8)
            #expect(throws: ZipError.unsupportedMethod("a")) { try open(one(entry)) }
        }
    }

    @Test func symlinkExternalAttributesRefused() {
        for mode: UInt32 in [0o120777, 0o010644, 0o020644, 0o060644, 0o140755, 0o040755] {
            var entry = plain()
            entry.madeBy = 0x0314
            entry.externalAttributes = mode << 16
            #expect(throws: ZipError.symlinkOrSpecial("a"), "mode \(String(mode, radix: 8))") { try open(one(entry)) }
        }
        var dosDirectory = plain()
        dosDirectory.externalAttributes = 0x10
        #expect(throws: ZipError.symlinkOrSpecial("a")) { try open(one(dosDirectory)) }

        var regular = plain()
        regular.madeBy = 0x0314
        regular.externalAttributes = UInt32(0o100644) << 16
        #expect(throws: Never.self) { try open(one(regular)) }
    }

    @Test func zip64MarkersRefused() {
        var count = FixtureArchive([plain()])
        count.declaredCount = 0xFFFF
        #expect(throws: ZipError.zip64) { try open(count) }

        var offset = FixtureArchive([plain()])
        offset.centralOffset = 0xFFFF_FFFF
        #expect(throws: ZipError.zip64) { try open(offset) }

        var directorySize = FixtureArchive([plain()])
        directorySize.centralSize = 0xFFFF_FFFF
        #expect(throws: ZipError.zip64) { try open(directorySize) }

        for field in 0..<3 {
            var entry = plain()
            switch field {
            case 0: entry.size = 0xFFFF_FFFF
            case 1: entry.compressedSize = 0xFFFF_FFFF
            default: entry.localOffset = 0xFFFF_FFFF
            }
            #expect(throws: ZipError.zip64) { try open(one(entry)) }
        }

        var disk = plain()
        disk.diskStart = 0xFFFF
        #expect(throws: ZipError.zip64) { try open(one(disk)) }

        var extra = plain()
        extra.centralExtra = Data([0x01, 0x00, 0x08, 0x00, 7, 0, 0, 0, 0, 0, 0, 0])
        #expect(throws: ZipError.zip64) { try open(one(extra)) }

        var locator = FixtureArchive([plain()])
        locator.beforeEnd = Data([0x50, 0x4b, 0x06, 0x07]) + Data(count: 16)
        #expect(throws: ZipError.zip64) { try open(locator) }
    }

    // MARK: end record

    @Test func archiveCommentRefused() {
        var archive = FixtureArchive([plain()])
        archive.comment = Data("hi".utf8)
        #expect(throws: ZipError.corrupt) { try open(archive) }

        // A comment that is itself a fake end record pointing at nothing.
        var fake = FixtureArchive([plain()])
        let inner = FixtureArchive([]).bytes()
        fake.comment = inner
        #expect(throws: ZipError.corrupt) { try open(fake) }

        // Declared comment length that runs past the file.
        var overlong = FixtureArchive([plain()])
        overlong.declaredCommentLength = 5
        #expect(throws: ZipError.corrupt) { try open(overlong) }

        var entryComment = plain()
        entryComment.centralComment = Data("c".utf8)
        #expect(throws: ZipError.corrupt) { try open(one(entryComment)) }
    }

    @Test func trailingGarbageAfterEndRecordRefused() {
        for trailing in [Data([0]), Data("junk".utf8), Data(count: 1000)] {
            var archive = FixtureArchive([plain()])
            archive.trailing = trailing
            #expect(throws: ZipError.corrupt) { try open(archive) }
        }
        // A second archive appended after the first.
        var two = FixtureArchive([plain()])
        two.trailing = FixtureArchive([plain("b")]).bytes()
        #expect(throws: ZipError.corrupt) { try open(two) }

        // Data before the first entry (a self-extracting stub) and between entries and directory.
        var prefixed = FixtureArchive([plain()])
        prefixed.prefix = Data("MZ stub".utf8)
        #expect(throws: ZipError.corrupt) { try open(prefixed) }
        var gap = FixtureArchive([plain()])
        gap.gap = Data("hidden".utf8)
        #expect(throws: ZipError.corrupt) { try open(gap) }
    }

    @Test func notAnArchive() {
        for bytes in [Data(), Data(count: 21), Data(count: 22), Data("PK\u{3}\u{4} not really".utf8)] {
            #expect(throws: ZipError.notAnArchive) { try ZipArchive.open(bytes, limits: RulesLimits(), entryLimit: Self.roomy) }
        }
    }

    @Test func nonZeroDiskNumbersRefused() {
        var archive = FixtureArchive([plain()])
        archive.diskNumber = 1
        #expect(throws: ZipError.corrupt) { try open(archive) }
        var entry = plain()
        entry.diskStart = 1
        #expect(throws: ZipError.corrupt) { try open(one(entry)) }
    }

    @Test func entryCountAboveLimitRefused() {
        var limits = RulesLimits()
        limits.packEntries = 3
        let four = FixtureArchive(["a", "b", "c", "d"].map { plain($0) })
        #expect(throws: ZipError.tooManyEntries) { try open(four, limits: limits) }
        let three = FixtureArchive(["a", "b", "c"].map { plain($0) })
        #expect(throws: Never.self) { try open(three, limits: limits) }
    }

    @Test func declaredCountDoesNotMatchCentralDirectory() {
        var fewer = FixtureArchive([plain("a"), plain("b")])
        fewer.declaredCount = 1
        #expect(throws: ZipError.corrupt) { try open(fewer) }
        var more = FixtureArchive([plain("a"), plain("b")])
        more.declaredCount = 3
        #expect(throws: ZipError.corrupt) { try open(more) }
        var disks = FixtureArchive([plain("a"), plain("b")])
        disks.declaredCountThisDisk = 1
        #expect(throws: ZipError.corrupt) { try open(disks) }
    }

    @Test func centralDirectoryOutsideFile() {
        var offset = FixtureArchive([plain()])
        offset.centralOffset = 0x00FF_FFFF
        #expect(throws: ZipError.corrupt) { try open(offset) }
        var size = FixtureArchive([plain()])
        size.centralSize = 0x00FF_FFFF
        #expect(throws: ZipError.corrupt) { try open(size) }
        var short = FixtureArchive([plain()])
        short.centralSize = 10
        #expect(throws: ZipError.corrupt) { try open(short) }
    }

    // MARK: local headers and ranges

    @Test func localHeaderOffsetOutsideFile() {
        for offset: UInt32 in [0x07FF_FFFF, 0xFFFF_FFFE] {
            var entry = plain()
            entry.localOffset = offset
            #expect(throws: ZipError.corrupt) { try open(one(entry)) }
        }
    }

    @Test func localHeaderNameMismatch() {
        var entry = plain("a")
        entry.localName = Array("b".utf8)
        #expect(throws: ZipError.corrupt) { try open(one(entry)) }
        var longer = plain("a")
        longer.localName = Array("a/../../etc".utf8)
        #expect(throws: ZipError.corrupt) { try open(one(longer)) }
    }

    @Test func localHeaderMethodMismatch() {
        var entry = plain()
        entry.localMethod = 8
        #expect(throws: ZipError.corrupt) { try open(one(entry)) }
        var flags = plain()
        flags.localFlags = 0x0001
        #expect(throws: ZipError.corrupt) { try open(one(flags)) }
    }

    @Test func localHeaderSignatureMustMatch() {
        var bytes = FixtureArchive([plain()]).bytes()
        PackFixtures.patch32(&bytes, 0, 0x0201_4b50)
        #expect(throws: ZipError.corrupt) { try ZipArchive.open(bytes, limits: RulesLimits(), entryLimit: Self.roomy) }
    }

    @Test func overlappingEntryRanges() {
        // Entry "a" stores, as its data, a complete local header for "b"; "b" points inside "a".
        let inner = FixtureArchive([FixtureEntry("b", Data("x".utf8))]).bytes()
        let innerLocal = inner.prefix(30 + 1 + 1)
        var b = FixtureEntry("b", Data("x".utf8))
        b.localOffset = UInt32(30 + 1)
        let archive = FixtureArchive([FixtureEntry("a", innerLocal), b])
        #expect(throws: ZipError.overlap) { try open(archive) }

        // Two central records for one local header (different names cannot both match, so the
        // second shares the exact same range).
        var same = plain("b")
        same.localOffset = 0
        same.localName = Array("a".utf8)
        #expect(throws: ZipError.self) { try open(FixtureArchive([plain("a"), same])) }
    }

    @Test func entryRangeInsideCentralDirectory() {
        let fixture = FixtureArchive([plain()])
        var pointing = plain()
        pointing.localOffset = UInt32(fixture.layout().central)
        #expect(throws: ZipError.overlap) { try open(one(pointing)) }

        var long = plain()
        long.compressedSize = UInt32(Data("payload".utf8).count + 10)
        long.size = long.compressedSize
        #expect(throws: ZipError.overlap) { try open(one(long)) }
    }

    // MARK: sizes

    @Test func declaredSizeAboveEntryLimit() {
        let entry = FixtureEntry("assets/x", Data(count: 11))
        #expect(throws: ZipError.entryTooBig("assets/x")) { try open(one(entry), entryLimit: { _ in 10 }) }
        #expect(throws: Never.self) { try open(one(entry), entryLimit: { _ in 11 }) }
        // A zero limit refuses any non-empty entry.
        #expect(throws: ZipError.entryTooBig("assets/x")) { try open(one(entry), entryLimit: { _ in 0 }) }
    }

    @Test func expandedTotalAboveLimit() {
        var limits = RulesLimits()
        limits.packExpandedBytes = 10
        let archive = FixtureArchive([FixtureEntry("a", Data(count: 6)), FixtureEntry("b", Data(count: 6))])
        #expect(throws: ZipError.expandedTooLarge) { try open(archive, limits: limits) }
    }

    @Test func declaredSizeSmallerThanActualIsABomb() throws {
        // One byte more than declared.
        var small = FixtureEntry("a", Data(repeating: 0x33, count: 101), method: 8)
        small.size = 100
        let archive = try open(one(small))
        #expect(throws: ZipError.sizeMismatch("a")) { try archive.contents(of: "a") }

        // A 1 GiB zero stream (about 1 MiB of deflate) declared as 1 MiB.
        let copies = (1 << 30) / 258
        let payload = PackFixtures.zeroBomb(copies: copies)
        let declared = 1 << 20
        var bomb = FixtureEntry("assets/bomb", Data(), method: 8)
        bomb.payload = payload
        bomb.size = UInt32(declared)
        bomb.crc = 0
        let started = ContinuousClock.now
        let bombArchive = try open(one(bomb), entryLimit: { _ in declared })
        #expect(throws: ZipError.sizeMismatch("assets/bomb")) { try bombArchive.contents(of: "assets/bomb") }

        var peak = 0
        #expect(throws: ZipError.sizeMismatch("assets/bomb")) {
            try ZipArchive.inflate(payload, declared: declared, name: "assets/bomb") { peak = max(peak, $0) }
        }
        #expect(peak <= declared + 1)
        #expect(peak > 0)
        #expect(ContinuousClock.now - started < .seconds(20))
    }

    @Test func impossibleRatioRefusedAtOpen() {
        var entry = FixtureEntry("a", Data("tiny".utf8), method: 8)
        entry.size = 10_000_000
        #expect(throws: ZipError.sizeMismatch("a")) { try open(one(entry), entryLimit: { _ in 20_000_000 }) }
    }

    @Test func declaredSizeLargerThanActual() throws {
        var deflated = FixtureEntry("a", Data(repeating: 0x33, count: 100), method: 8)
        deflated.size = 101
        let archive = try open(one(deflated))
        #expect(throws: ZipError.sizeMismatch("a")) { try archive.contents(of: "a") }

        var stored = plain()
        stored.size = 8
        #expect(throws: ZipError.sizeMismatch("a")) { try open(one(stored)) }
    }

    @Test func corruptDeflateStreamIsTyped() throws {
        var garbage = FixtureEntry("a", Data(count: 100), method: 8)
        garbage.payload = Data(repeating: 0xFF, count: 40)
        let archive = try open(one(garbage))
        #expect(throws: ZipError.self) { try archive.contents(of: "a") }

        var truncated = FixtureEntry("b", Data(repeating: 0x61, count: 3000), method: 8)
        truncated.payload = PackFixtures.deflate(truncated.data).prefix(3)
        let second = try open(one(truncated))
        #expect(throws: ZipError.self) { try second.contents(of: "b") }
    }

    @Test func fileLargerThanPackFileBytesRefused() {
        var limits = RulesLimits()
        limits.packFileBytes = 100
        let archive = FixtureArchive([FixtureEntry("a", Data(count: 200))])
        #expect(throws: ZipError.tooLarge) { try open(archive, limits: limits) }
    }

    // MARK: robustness

    @Test func truncatedFile() throws {
        let pack = try validPack()
        for length in 0..<pack.count {
            let prefix = pack.prefix(length)
            do {
                _ = try ZipArchive.open(prefix, limits: RulesLimits(), entryLimit: Self.roomy)
                Issue.record("prefix \(length) opened")
            } catch is ZipError {
            } catch { Issue.record("prefix \(length): \(error)") }
        }
    }

    @Test func randomBytesNeverCrash() throws {
        var rng = PackFixtures.SeededGenerator(seed: 0x5EED_2026)
        for round in 0..<2000 {
            let count = Int.random(in: 0..<400, using: &rng)
            var bytes = Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &rng) })
            if round % 2 == 0, count >= 22 {
                // Plant an end record so parsing goes past the signature search.
                let end = count - 22
                PackFixtures.patch32(&bytes, end, ZipFormat.endSignature)
                PackFixtures.patch32(&bytes, end + 4, 0)
                let entries = UInt16.random(in: 0...4, using: &rng)
                PackFixtures.patch16(&bytes, end + 8, entries)
                PackFixtures.patch16(&bytes, end + 10, entries)
                let size = UInt32.random(in: 0...UInt32(end), using: &rng)
                PackFixtures.patch32(&bytes, end + 12, size)
                PackFixtures.patch32(&bytes, end + 16, UInt32(end) - size)
                PackFixtures.patch16(&bytes, end + 20, 0)
                if round % 4 == 0, size >= 4 {
                    PackFixtures.patch32(&bytes, end - Int(size), ZipFormat.centralSignature)
                }
            }
            exercise(bytes, label: "random \(round)")
        }

        let pack = try validPack()
        for flip in 0..<500 {
            var bytes = pack
            let index = Int.random(in: 0..<bytes.count, using: &rng)
            let bit = UInt8(1) << UInt8.random(in: 0..<8, using: &rng)
            bytes[index] ^= bit
            exercise(bytes, label: "flip \(flip) at \(index)")
        }
    }

    /// Either a `ZipError` or a fully readable archive; nothing else.
    private func exercise(_ bytes: Data, label: String) {
        let archive: ZipArchive
        do {
            archive = try ZipArchive.open(bytes, limits: RulesLimits(), entryLimit: Self.roomy)
        } catch is ZipError {
            return
        } catch {
            Issue.record("\(label): \(error)")
            return
        }
        for entry in archive.entries {
            do {
                let data = try archive.contents(of: entry.name)
                #expect(data.count == entry.size, "\(label)")
            } catch is ZipError {
            } catch { Issue.record("\(label): \(error)") }
        }
    }
}
