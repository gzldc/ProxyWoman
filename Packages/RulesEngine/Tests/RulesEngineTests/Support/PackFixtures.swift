import Compression
import Foundation

@testable import RulesEngine

/// Hand-built zip bytes for the hostile corpus. Every field is overridable so a test can change exactly one
/// structural fact; with no overrides an archive is byte-identical in layout to what `ZipWriter` produces.
struct FixtureEntry {
    var name: [UInt8]
    var data: Data
    var method: UInt16 = 0
    /// Compressed bytes; nil = `data` for method 0, raw deflate of `data` for method 8.
    var payload: Data?
    var flags: UInt16 = 0
    var crc: UInt32?
    var compressedSize: UInt32?
    var size: UInt32?
    var externalAttributes: UInt32 = 0
    var madeBy: UInt16 = 20
    var centralExtra = Data()
    var localExtra = Data()
    var centralComment = Data()
    var localName: [UInt8]?
    var localMethod: UInt16?
    var localFlags: UInt16?
    var localOffset: UInt32?
    /// Bytes written after the payload (a data descriptor).
    var descriptor = Data()
    var diskStart: UInt16 = 0

    init(_ name: String, _ data: Data, method: UInt16 = 0) {
        self.name = Array(name.utf8)
        self.data = data
        self.method = method
    }

    init(rawName: [UInt8], _ data: Data) {
        self.name = rawName
        self.data = data
    }

    var resolvedPayload: Data {
        if let payload { return payload }
        return method == 8 ? PackFixtures.deflate(data) : data
    }
}

struct FixtureArchive {
    var entries: [FixtureEntry]
    var prefix = Data()
    var declaredCount: UInt16?
    var declaredCountThisDisk: UInt16?
    var centralOffset: UInt32?
    var centralSize: UInt32?
    var diskNumber: UInt16 = 0
    var comment = Data()
    var declaredCommentLength: UInt16?
    var trailing = Data()
    /// Bytes inserted between the last entry and the central directory.
    var gap = Data()
    /// Bytes inserted between the central directory and the end record.
    var beforeEnd = Data()
    /// Central records in this order (indices into `entries`); nil = entry order.
    var centralOrder: [Int]?

    init(_ entries: [FixtureEntry]) { self.entries = entries }

    /// Offsets of each local header and of the central directory in `bytes()`.
    func layout() -> (locals: [Int], centrals: [Int], central: Int, end: Int) {
        var locals: [Int] = []
        var offset = prefix.count
        for entry in entries {
            locals.append(offset)
            offset += 30 + (entry.localName ?? entry.name).count + entry.localExtra.count
                + entry.resolvedPayload.count + entry.descriptor.count
        }
        offset += gap.count
        let central = offset
        var centrals = [Int](repeating: 0, count: entries.count)
        for index in centralOrder ?? Array(entries.indices) {
            let entry = entries[index]
            centrals[index] = offset
            offset += 46 + entry.name.count + entry.centralExtra.count + entry.centralComment.count
        }
        return (locals, centrals, central, offset + beforeEnd.count)
    }

    func bytes() -> Data {
        var out = prefix
        var central = Data()
        let positions = layout()
        var centralRecords = [Data](repeating: Data(), count: entries.count)
        for (index, entry) in entries.enumerated() {
            var central = Data()
            let payload = entry.resolvedPayload
            let crc = entry.crc ?? ZipFormat.crc32(entry.data)
            let csize = entry.compressedSize ?? UInt32(payload.count)
            let size = entry.size ?? UInt32(entry.data.count)
            let localName = entry.localName ?? entry.name
            out.le(ZipFormat.localSignature)
            out.le(UInt16(20))
            out.le(entry.localFlags ?? entry.flags)
            out.le(entry.localMethod ?? entry.method)
            out.le(ZipFormat.dosTime)
            out.le(ZipFormat.dosDate)
            let deferred = (entry.flags & 0x0008) != 0
            out.le(deferred ? UInt32(0) : crc)
            out.le(deferred ? UInt32(0) : csize)
            out.le(deferred ? UInt32(0) : size)
            out.le(UInt16(localName.count))
            out.le(UInt16(entry.localExtra.count))
            out.append(contentsOf: localName)
            out.append(entry.localExtra)
            out.append(payload)
            out.append(entry.descriptor)

            central.le(ZipFormat.centralSignature)
            central.le(entry.madeBy)
            central.le(UInt16(20))
            central.le(entry.flags)
            central.le(entry.method)
            central.le(ZipFormat.dosTime)
            central.le(ZipFormat.dosDate)
            central.le(crc)
            central.le(csize)
            central.le(size)
            central.le(UInt16(entry.name.count))
            central.le(UInt16(entry.centralExtra.count))
            central.le(UInt16(entry.centralComment.count))
            central.le(entry.diskStart)
            central.le(UInt16(0))
            central.le(entry.externalAttributes)
            central.le(entry.localOffset ?? UInt32(positions.locals[index]))
            central.append(contentsOf: entry.name)
            central.append(entry.centralExtra)
            central.append(entry.centralComment)
            centralRecords[index] = central
        }
        for index in centralOrder ?? Array(entries.indices) { central.append(centralRecords[index]) }
        out.append(gap)
        out.append(central)
        out.append(beforeEnd)
        out.le(ZipFormat.endSignature)
        out.le(diskNumber)
        out.le(UInt16(0))
        out.le(declaredCountThisDisk ?? declaredCount ?? UInt16(entries.count))
        out.le(declaredCount ?? UInt16(entries.count))
        out.le(centralSize ?? UInt32(central.count))
        out.le(centralOffset ?? UInt32(positions.central))
        out.le(declaredCommentLength ?? UInt16(comment.count))
        out.append(comment)
        out.append(trailing)
        return out
    }
}

enum PackFixtures {
    static func deflate(_ data: Data) -> Data {
        let capacity = data.count + 1024
        var buffer = [UInt8](repeating: 0, count: capacity)
        let written = data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
            let base = src.bindMemory(to: UInt8.self).baseAddress ?? UnsafePointer<UInt8>(bitPattern: 1)
            guard let base else { return 0 }
            return buffer.withUnsafeMutableBufferPointer { dst in
                guard let out = dst.baseAddress else { return 0 }
                return compression_encode_buffer(out, capacity, base, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        return Data(buffer[0..<written])
    }

    /// A raw deflate stream (one dynamic-Huffman block) that inflates to exactly `zeroCount` zero bytes,
    /// `zeroCount` = 1 + 258·k. A 1 GiB stream is about 1 MiB: each 258-byte copy costs two bits.
    static func zeroBomb(copies: Int) -> Data {
        var w = BitWriter()
        w.bits(1, 1)  // BFINAL
        w.bits(2, 2)  // BTYPE = dynamic
        w.bits(29, 5)  // HLIT: 286 literal/length codes
        w.bits(1, 5)  // HDIST: 2 distance codes
        w.bits(14, 4)  // HCLEN: 18 code-length codes
        // Code-length code lengths in RFC 1951 order 16,17,18,0,8,7,9,6,10,5,11,4,12,3,13,2,14,1.
        let order = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1]
        let clLengths: [Int: Int] = [18: 1, 1: 2, 2: 2]
        for symbol in order { w.bits(clLengths[symbol] ?? 0, 3) }
        // Canonical codes: 18 -> 0, 1 -> 10, 2 -> 11.
        func cl(_ symbol: Int) {
            switch symbol {
            case 18: w.code(0b0, 1)
            case 1: w.code(0b10, 2)
            default: w.code(0b11, 2)
            }
        }
        func zeros(_ n: Int) {
            var left = n
            while left > 0 {
                let run = min(138, left)
                cl(18)
                w.bits(run - 11, 7)
                left -= run
            }
        }
        cl(2)  // literal 0: length 2
        zeros(255)  // literals 1...255
        cl(2)  // 256 (end of block): length 2
        zeros(28)  // 257...284
        cl(1)  // 285 (length 258): length 1
        cl(1)  // distance 0: length 1
        cl(1)  // distance 1: length 1
        // Literal/length codes: 285 -> 0, literal 0 -> 10, 256 -> 11. Distance 0 -> 0.
        w.code(0b10, 2)  // one literal zero
        // Each copy is code 0 (length) + code 0 (distance): two zero bits.
        w.zeroBits(2 * copies)
        w.code(0b11, 2)  // end of block
        w.flush()
        return Data(w.bytes)
    }

    /// Deterministic generator for the fuzz loops (SplitMix64).
    struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    static func patch16(_ data: inout Data, _ offset: Int, _ value: UInt16) {
        data[data.startIndex + offset] = UInt8(value & 0xFF)
        data[data.startIndex + offset + 1] = UInt8(value >> 8)
    }

    static func patch32(_ data: inout Data, _ offset: Int, _ value: UInt32) {
        patch16(&data, offset, UInt16(value & 0xFFFF))
        patch16(&data, offset + 2, UInt16(value >> 16))
    }
}

private struct BitWriter {
    var bytes: [UInt8] = []
    private var current: UInt8 = 0
    private(set) var bitCount = 0

    /// Value bits, least significant first (header fields and extra bits).
    mutating func bits(_ value: Int, _ count: Int) {
        for i in 0..<count { put((value >> i) & 1) }
    }

    /// A Huffman code, most significant bit first.
    mutating func code(_ value: Int, _ length: Int) {
        for i in stride(from: length - 1, through: 0, by: -1) { put((value >> i) & 1) }
    }

    mutating func zeroBits(_ n: Int) {
        var left = n
        while left > 0, bitCount != 0 {
            put(0)
            left -= 1
        }
        bytes.append(contentsOf: repeatElement(0, count: left / 8))
        for _ in 0..<(left % 8) { put(0) }
    }

    mutating func flush() {
        if bitCount > 0 {
            bytes.append(current)
            current = 0
            bitCount = 0
        }
    }

    private mutating func put(_ bit: Int) {
        current |= UInt8(bit) << UInt8(bitCount)
        bitCount += 1
        if bitCount == 8 {
            bytes.append(current)
            current = 0
            bitCount = 0
        }
    }
}

extension Data {
    fileprivate mutating func le<T: FixedWidthInteger>(_ value: T) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
}
