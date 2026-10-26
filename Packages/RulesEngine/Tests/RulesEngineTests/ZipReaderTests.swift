import Foundation
import Testing

@testable import RulesEngine

@Suite("ZipReader")
struct ZipReaderTests {
    static let roomy: @Sendable (String) -> Int = { _ in 4 * 1024 * 1024 }

    static func randomData(_ count: Int, seed: UInt64) -> Data {
        var rng = PackFixtures.SeededGenerator(seed: seed)
        return Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &rng) })
    }

    @Test func roundTripsWriterOutput() throws {
        let inputs = [
            ZipEntryInput(name: "empty", data: Data()),
            ZipEntryInput(name: "big.txt", data: Data(repeating: 0x61, count: 1024 * 1024)),
            ZipEntryInput(name: "assets/random", data: Self.randomData(64 * 1024, seed: 7)),
            ZipEntryInput(name: "assets/é", data: Data("utf8 flag".utf8)),
        ]
        let zip = try ZipWriter.write(inputs)
        let archive = try ZipArchive.open(zip, limits: RulesLimits(), entryLimit: Self.roomy)
        #expect(archive.entries.map(\.name) == inputs.map(\.name))
        #expect(archive.entries.map(\.size) == inputs.map(\.data.count))
        for input in inputs { #expect(try archive.contents(of: input.name) == input.data) }
    }

    @Test func readsStoredAndDeflatedEntries() throws {
        let text = Data(String(repeating: "stored or deflated ", count: 200).utf8)
        let zip = FixtureArchive([
            FixtureEntry("s", text, method: 0), FixtureEntry("d", text, method: 8),
        ]).bytes()
        let archive = try ZipArchive.open(zip, limits: RulesLimits(), entryLimit: Self.roomy)
        #expect(archive.entries[0].compressedSize == text.count)
        #expect(archive.entries[1].compressedSize < text.count)
        #expect(try archive.contents(of: "s") == text)
        #expect(try archive.contents(of: "d") == text)
    }

    @Test func contentsOfUnknownNameThrows() throws {
        let zip = try ZipWriter.write([ZipEntryInput(name: "a", data: Data("x".utf8))])
        let archive = try ZipArchive.open(zip, limits: RulesLimits(), entryLimit: Self.roomy)
        #expect(throws: ZipError.corrupt) { try archive.contents(of: "b") }
        #expect(throws: ZipError.corrupt) { try archive.contents(of: "A") }
    }

    @Test func entryOrderIsCentralDirectoryOrder() throws {
        var fixture = FixtureArchive([
            FixtureEntry("first", Data("1".utf8)), FixtureEntry("second", Data("22".utf8)),
            FixtureEntry("third", Data("333".utf8)),
        ])
        fixture.centralOrder = [2, 0, 1]
        let archive = try ZipArchive.open(fixture.bytes(), limits: RulesLimits(), entryLimit: Self.roomy)
        #expect(archive.entries.map(\.name) == ["third", "first", "second"])
        #expect(try archive.contents(of: "second") == Data("22".utf8))
    }

    @Test func crcIsVerifiedOnRead() throws {
        for method: UInt16 in [0, 8] {
            var entry = FixtureEntry("a", Data(repeating: 0x42, count: 300), method: method)
            entry.crc = ZipFormat.crc32(entry.data) ^ 1
            let archive = try ZipArchive.open(
                FixtureArchive([entry]).bytes(), limits: RulesLimits(), entryLimit: Self.roomy)
            #expect(throws: ZipError.crcMismatch("a")) { try archive.contents(of: "a") }
        }
    }

    @Test func acceptsADataSlice() throws {
        let zip = try ZipWriter.write([ZipEntryInput(name: "a", data: Data("hello".utf8))])
        let padded = Data([1, 2, 3, 4, 5]) + zip
        let slice = padded[padded.startIndex + 5..<padded.endIndex]
        let archive = try ZipArchive.open(slice, limits: RulesLimits(), entryLimit: Self.roomy)
        #expect(try archive.contents(of: "a") == Data("hello".utf8))
    }

    @Test func emptyArchiveHasNoEntries() throws {
        let archive = try ZipArchive.open(try ZipWriter.write([]), limits: RulesLimits(), entryLimit: Self.roomy)
        #expect(archive.entries.isEmpty)
    }

    @Test func zeroBombFixtureInflatesToExactlyItsLength() throws {
        let payload = PackFixtures.zeroBomb(copies: 1000)
        var entry = FixtureEntry("z", Data(count: 258_001), method: 8)
        entry.payload = payload
        let archive = try ZipArchive.open(FixtureArchive([entry]).bytes(), limits: RulesLimits(), entryLimit: Self.roomy)
        #expect(try archive.contents(of: "z") == Data(count: 258_001))
    }

    @Test func dataDescriptorIsAcceptedAndMustAgree() throws {
        let data = Data("described".utf8)
        func descriptor(signature: Bool, crc: UInt32) -> Data {
            var d = Data()
            func le(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
            if signature { le(0x0807_4b50) }
            le(crc)
            le(UInt32(data.count))
            le(UInt32(data.count))
            return d
        }
        for signature in [true, false] {
            var entry = FixtureEntry("d", data)
            entry.flags = 0x0008
            entry.descriptor = descriptor(signature: signature, crc: ZipFormat.crc32(data))
            let archive = try ZipArchive.open(
                FixtureArchive([entry]).bytes(), limits: RulesLimits(), entryLimit: Self.roomy)
            #expect(try archive.contents(of: "d") == data)

            entry.descriptor = descriptor(signature: signature, crc: ZipFormat.crc32(data) ^ 0xFF)
            #expect(throws: ZipError.corrupt) {
                try ZipArchive.open(FixtureArchive([entry]).bytes(), limits: RulesLimits(), entryLimit: Self.roomy)
            }
        }
        var missing = FixtureEntry("d", data)
        missing.flags = 0x0008
        #expect(throws: ZipError.self) {
            try ZipArchive.open(FixtureArchive([missing]).bytes(), limits: RulesLimits(), entryLimit: Self.roomy)
        }
    }

    @Test func wellFormedUnknownExtraFieldIsAccepted() throws {
        var entry = FixtureEntry("x", Data("v".utf8))
        entry.centralExtra = Data([0x55, 0x54, 0x01, 0x00, 0x00])  // 0x5455, one byte
        entry.localExtra = Data([0x55, 0x54, 0x01, 0x00, 0x00])
        let archive = try ZipArchive.open(FixtureArchive([entry]).bytes(), limits: RulesLimits(), entryLimit: Self.roomy)
        #expect(try archive.contents(of: "x") == Data("v".utf8))
    }
}
