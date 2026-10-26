import Foundation
import Testing

@testable import RulesEngine

@Suite("ZipWriter")
struct ZipWriterTests {
    private func u16(_ d: Data, _ o: Int) -> Int { Int(d[d.startIndex + o]) | Int(d[d.startIndex + o + 1]) << 8 }
    private func u32(_ d: Data, _ o: Int) -> Int { u16(d, o) | u16(d, o + 2) << 16 }

    @Test func crc32MatchesKnownVectors() {
        #expect(ZipFormat.crc32(Data()) == 0)
        #expect(ZipFormat.crc32(Data("123456789".utf8)) == 0xCBF4_3926)
    }

    @Test func writtenArchiveHasTheExpectedSignaturesAndCounts() throws {
        let a = Data("hello".utf8)
        let b = Data("world!!".utf8)
        let zip = try ZipWriter.write([ZipEntryInput(name: "a.txt", data: a), ZipEntryInput(name: "dir/b.txt", data: b)])
        #expect(u32(zip, 0) == Int(ZipFormat.localSignature))
        let eocd = zip.count - 22
        #expect(u32(zip, eocd) == Int(ZipFormat.endSignature))
        #expect(u16(zip, eocd + 8) == 2)
        #expect(u16(zip, eocd + 10) == 2)
        #expect(u16(zip, eocd + 20) == 0)
        let cdSize = u32(zip, eocd + 12)
        let cdOffset = u32(zip, eocd + 16)
        #expect(cdOffset + cdSize == eocd)
        #expect(u32(zip, cdOffset) == Int(ZipFormat.centralSignature))
        // Second central record follows the first (46 + name length).
        #expect(u32(zip, cdOffset + 46 + 5) == Int(ZipFormat.centralSignature))
        // Fixed DOS time on the first local header.
        #expect(u16(zip, 10) == Int(ZipFormat.dosTime))
        #expect(u16(zip, 12) == Int(ZipFormat.dosDate))
        // CRC and sizes in the central record.
        #expect(u32(zip, cdOffset + 16) == Int(ZipFormat.crc32(a)))
        #expect(u32(zip, cdOffset + 24) == a.count)
    }

    @Test func equalInputGivesEqualBytes() throws {
        let entries = [
            ZipEntryInput(name: "one", data: Data(repeating: 7, count: 4096)),
            ZipEntryInput(name: "two", data: Data("x".utf8)),
        ]
        #expect(try ZipWriter.write(entries) == ZipWriter.write(entries))
    }

    @Test func compressibleEntryIsDeflatedAndIncompressibleIsStored() throws {
        let compressible = Data(repeating: 0x41, count: 10_000)
        var rng = SystemRandomNumberGenerator()
        let random = Data((0..<2048).map { _ in UInt8.random(in: 0...255, using: &rng) })
        let zip = try ZipWriter.write([
            ZipEntryInput(name: "c", data: compressible), ZipEntryInput(name: "r", data: random),
        ])
        let eocd = zip.count - 22
        let cd = u32(zip, eocd + 16)
        #expect(u16(zip, cd + 10) == 8)
        let secondCD = cd + 46 + 1
        #expect(u16(zip, secondCD + 10) == 0)
        #expect(u32(zip, secondCD + 20) == random.count)
        #expect(u32(zip, cd + 20) < compressible.count)
        #expect(u32(zip, cd + 24) == compressible.count)
    }

    @Test func namesAreValidatedOnWrite() {
        for bad in ["../x", "/x", "a\\b", "", "a/../b", "a//b", "a/", "./a", "a\u{0}b"] {
            #expect(throws: ZipError.invalidName) { try ZipWriter.write([ZipEntryInput(name: bad, data: Data())]) }
        }
        #expect(throws: ZipError.invalidName) {
            try ZipWriter.write([ZipEntryInput(name: "a", data: Data()), ZipEntryInput(name: "a", data: Data())])
        }
        #expect(throws: ZipError.invalidName) {
            try ZipWriter.write([ZipEntryInput(name: "Ab", data: Data()), ZipEntryInput(name: "aB", data: Data())])
        }
        #expect(throws: ZipError.invalidName) {
            try ZipWriter.write([ZipEntryInput(name: String(repeating: "a", count: 256), data: Data())])
        }
    }

    @Test func newLimitsHaveTheDocumentedDefaults() {
        let l = RulesLimits()
        #expect(l.packFileBytes == 134_217_728)
        #expect(l.packExpandedBytes == 268_435_456)
        #expect(l.packAssetBytes == 67_108_864)
        #expect(l.packEntries == 600)
        #expect(l.packManifestBytes == 65_536)
        #expect(l.packGroups == 500)
    }
}
