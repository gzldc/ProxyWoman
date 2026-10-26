import Foundation
import Testing

@testable import Viewers

@Suite(.productionChinese) struct HexDumpTests {
    @Test func hexLineFormat() {
        let pad = String(repeating: " ", count: 47 - 14)
        #expect(HexDump.format(Data("Hello".utf8)) == "00000000  48 65 6c 6c 6f\(pad)  |Hello|")
    }

    @Test func hexFullLine() {
        let data = Data("0123456789abcdef".utf8)
        #expect(
            HexDump.format(data)
                == "00000000  30 31 32 33 34 35 36 37 38 39 61 62 63 64 65 66  |0123456789abcdef|")
    }

    @Test func hexNonPrintableAndMultiline() {
        let data = Data((0x00...0x10).map { UInt8($0) })
        let lines = HexDump.format(data).split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.count == 2)
        #expect(
            lines[0]
                == "00000000  00 01 02 03 04 05 06 07 08 09 0a 0b 0c 0d 0e 0f  |................|")
        #expect(lines[1] == "00000010  10" + String(repeating: " ", count: 47 - 2) + "  |.|")
    }

    @Test func hexTruncatesAtMaxBytes() {
        let data = Data(repeating: 0x41, count: 32)
        let out = HexDump.format(data, bytesPerLine: 16, maxBytes: 16)
        let lines = out.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.count == 2)
        #expect(lines[0].hasPrefix("00000000  41 41"))
        #expect(lines[1] == "…（已截断，共 32 字节）")
    }

    @Test func hexEmptyIsEmptyString() {
        #expect(HexDump.format(Data()) == "")
    }

    @Test func hexCustomBytesPerLine() {
        let out = HexDump.format(Data("abcd".utf8), bytesPerLine: 8)
        #expect(out == "00000000  61 62 63 64" + String(repeating: " ", count: 23 - 11) + "  |abcd|")
    }
}
