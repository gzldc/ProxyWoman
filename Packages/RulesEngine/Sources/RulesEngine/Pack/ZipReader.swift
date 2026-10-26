import Compression
import Foundation

/// A zip archive read from untrusted bytes. `open` trusts only the central directory and checks every
/// structural fact before anything is inflated; `contents(of:)` inflates one entry with its declared size
/// as a hard output cap and verifies the CRC. Nothing is ever written to disk.
public struct ZipArchive: Sendable {
    public struct Entry: Sendable, Equatable {
        public let name: String
        public let compressedSize: Int
        public let size: Int
    }

    private struct Record: Sendable {
        let method: UInt16
        let crc: UInt32
        /// Offset of the compressed bytes from the start of `data`.
        let dataStart: Int
        let compressedSize: Int
        let size: Int
    }

    /// Central-directory order.
    public let entries: [Entry]
    private let data: Data
    private let records: [String: Record]

    private init(entries: [Entry], data: Data, records: [String: Record]) {
        self.entries = entries
        self.data = data
        self.records = records
    }

    /// Validates the whole structure; inflates nothing. `entryLimit(name)` is that entry's uncompressed cap.
    public static func open(_ data: Data, limits: RulesLimits, entryLimit: (String) -> Int) throws -> ZipArchive {
        guard data.count <= limits.packFileBytes else { throw ZipError.tooLarge }
        guard data.count >= endRecordLength else { throw ZipError.notAnArchive }
        let parsed = try withoutActuallyEscaping(entryLimit) { limit in
            try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                try Parser(bytes: raw, limits: limits, entryLimit: limit).parse()
            }
        }
        return ZipArchive(entries: parsed.entries, data: data, records: parsed.records)
    }

    /// Inflates one entry. Output never exceeds the declared size; one byte more fails; CRC is verified.
    public func contents(of name: String) throws -> Data {
        guard let record = records[name] else { throw ZipError.corrupt }
        let start = try checkedAdd(data.startIndex, record.dataStart)
        let end = try checkedAdd(start, record.compressedSize)
        guard start >= data.startIndex, end <= data.endIndex else { throw ZipError.corrupt }
        let payload = data[start..<end]
        let output: Data
        switch record.method {
        case 0:
            guard payload.count == record.size else { throw ZipError.sizeMismatch(name) }
            output = Data(payload)
        case 8:
            output = try Self.inflate(payload, declared: record.size, name: name)
        default:
            throw ZipError.unsupportedMethod(name)
        }
        guard ZipFormat.crc32(output) == record.crc else { throw ZipError.crcMismatch(name) }
        return output
    }

    // MARK: - Inflate

    static let inflateChunk = 64 * 1024

    /// Raw deflate, decoded in chunks. Each call to the decoder gets at most the room left up to
    /// `declared + 1`, so the output can never grow past that; reaching it means the stream holds more
    /// than declared (`sizeMismatch`). `observe` sees the running total after every chunk (tests).
    static func inflate(
        _ payload: Data, declared: Int, name: String, observe: (Int) -> Void = { _ in }
    ) throws -> Data {
        guard declared >= 0 else { throw ZipError.sizeMismatch(name) }
        let cap = try checkedAdd(declared, 1)
        guard !payload.isEmpty else { throw ZipError.corrupt }
        let scratch = UnsafeMutablePointer<UInt8>.allocate(capacity: inflateChunk)
        defer { scratch.deallocate() }
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        stream.initialize(
            to: compression_stream(
                dst_ptr: scratch, dst_size: 0, src_ptr: UnsafePointer(scratch), src_size: 0, state: nil))
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK
        else { throw ZipError.corrupt }
        defer { compression_stream_destroy(stream) }

        return try payload.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Data in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { throw ZipError.corrupt }
            var output = Data()
            output.reserveCapacity(min(declared, 16 * 1024 * 1024))
            var total = 0
            stream.pointee.src_ptr = base
            stream.pointee.src_size = raw.count
            while true {
                let room = min(inflateChunk, cap - total)
                guard room > 0 else { throw ZipError.sizeMismatch(name) }
                stream.pointee.dst_ptr = scratch
                stream.pointee.dst_size = room
                let sourceBefore = stream.pointee.src_size
                let status = compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = room - stream.pointee.dst_size
                guard produced >= 0, produced <= room else { throw ZipError.corrupt }
                if produced > 0 {
                    total = try checkedAdd(total, produced)
                    observe(total)
                    guard total <= declared else { throw ZipError.sizeMismatch(name) }
                    output.append(scratch, count: produced)
                }
                switch status {
                case COMPRESSION_STATUS_END:
                    guard total == declared else { throw ZipError.sizeMismatch(name) }
                    return output
                case COMPRESSION_STATUS_OK:
                    // No output and no input consumed: truncated or stuck stream.
                    if produced == 0, stream.pointee.src_size == sourceBefore { throw ZipError.corrupt }
                default:
                    throw ZipError.corrupt
                }
            }
        }
    }

    // MARK: - Structure

    static let endRecordLength = 22
    static let centralRecordLength = 46
    static let localHeaderLength = 30
    /// Deflate cannot expand by more than 1032:1 (a 258-byte copy in two bits).
    static let maxDeflateRatio = 1032

    private struct Parsed {
        var entries: [Entry]
        var records: [String: Record]
    }

    private struct Parser {
        let bytes: UnsafeRawBufferPointer
        let limits: RulesLimits
        let entryLimit: (String) -> Int

        var count: Int { bytes.count }

        func parse() throws -> Parsed {
            let end = count - endRecordLength  // count >= 22 is checked by the caller.
            guard end >= 0 else { throw ZipError.notAnArchive }

            // The end record must be the last 22 bytes. Any signature elsewhere in the tail means a comment,
            // trailing data or an appended archive: refused. No signature at all: not an archive.
            let tailStart = max(0, end - Int(UInt16.max))
            var abutting = 0
            var signatures = 0
            var position = tailStart
            while position <= end {
                if try u32(position) == ZipFormat.endSignature {
                    signatures += 1
                    let size = Int(try u32(position + 12))
                    let offset = Int(try u32(position + 16))
                    if try checkedAdd(offset, size) == position { abutting += 1 }
                }
                position += 1
            }
            guard signatures > 0 else { throw ZipError.notAnArchive }
            guard try u32(end) == ZipFormat.endSignature else { throw ZipError.corrupt }

            let disk = try u16(end + 4)
            let directoryDisk = try u16(end + 6)
            let countThisDisk = try u16(end + 8)
            let total = try u16(end + 10)
            let directorySize = try u32(end + 12)
            let directoryOffset = try u32(end + 16)
            let commentLength = try u16(end + 20)
            if disk == .max || directoryDisk == .max || countThisDisk == .max || total == .max
                || directorySize == .max || directoryOffset == .max
            {
                throw ZipError.zip64
            }
            if end >= 20, try u32(end - 20) == ZipFormat.zip64LocatorSignature { throw ZipError.zip64 }
            guard commentLength == 0 else { throw ZipError.corrupt }
            guard disk == 0, directoryDisk == 0, countThisDisk == total else { throw ZipError.corrupt }
            let entryCount = Int(total)
            guard entryCount <= limits.packEntries else { throw ZipError.tooManyEntries }

            let directoryStart = Int(directoryOffset)
            let directoryEnd = try checkedAdd(directoryStart, Int(directorySize))
            guard directoryEnd == end, abutting == 1 else { throw ZipError.corrupt }
            guard try checkedMultiply(entryCount, ZipArchive.centralRecordLength) <= Int(directorySize) else {
                throw ZipError.corrupt
            }

            var entries: [Entry] = []
            entries.reserveCapacity(entryCount)
            var records: [String: Record] = [:]
            var seen = Set<String>()
            var ranges: [(start: Int, end: Int)] = []
            var expanded = 0
            var cursor = directoryStart
            for _ in 0..<entryCount {
                let parsed = try centralRecord(at: cursor, directoryStart: directoryStart, directoryEnd: directoryEnd)
                cursor = parsed.next
                let name = parsed.entry.name
                guard seen.insert(name.lowercased()).inserted else { throw ZipError.duplicateName(name) }
                expanded = try checkedAdd(expanded, parsed.entry.size)
                guard expanded <= limits.packExpandedBytes else { throw ZipError.expandedTooLarge }
                entries.append(parsed.entry)
                records[name] = parsed.record
                ranges.append(parsed.range)
            }
            guard cursor == directoryEnd else { throw ZipError.corrupt }

            // Entries may not share bytes; together they must fill [0, central directory) exactly.
            ranges.sort { $0.start < $1.start }
            for index in ranges.indices.dropFirst() where ranges[index].start < ranges[index - 1].end {
                throw ZipError.overlap
            }
            var expected = 0
            for range in ranges {
                guard range.start == expected else { throw ZipError.corrupt }
                expected = range.end
            }
            guard expected == directoryStart else { throw ZipError.corrupt }
            return Parsed(entries: entries, records: records)
        }

        private func centralRecord(
            at cursor: Int, directoryStart: Int, directoryEnd: Int
        ) throws -> (entry: Entry, record: Record, range: (start: Int, end: Int), next: Int) {
            guard try checkedAdd(cursor, ZipArchive.centralRecordLength) <= directoryEnd else { throw ZipError.corrupt }
            guard try u32(cursor) == ZipFormat.centralSignature else { throw ZipError.corrupt }
            let flags = try u16(cursor + 8)
            let method = try u16(cursor + 10)
            let crc = try u32(cursor + 16)
            let compressed = try u32(cursor + 20)
            let uncompressed = try u32(cursor + 24)
            let nameLength = Int(try u16(cursor + 28))
            let extraLength = Int(try u16(cursor + 30))
            let commentLength = Int(try u16(cursor + 32))
            let diskStart = try u16(cursor + 34)
            let external = try u32(cursor + 38)
            let localOffset = try u32(cursor + 42)

            let nameStart = cursor + ZipArchive.centralRecordLength
            let extraStart = try checkedAdd(nameStart, nameLength)
            let commentStart = try checkedAdd(extraStart, extraLength)
            let next = try checkedAdd(commentStart, commentLength)
            guard next <= directoryEnd else { throw ZipError.corrupt }

            if compressed == .max || uncompressed == .max || localOffset == .max || diskStart == .max {
                throw ZipError.zip64
            }

            let nameBytes = try slice(nameStart, nameLength)
            let name = try decodeName(nameBytes, flags: flags)

            if flags & 0x2041 != 0 { throw ZipError.encrypted(name) }
            // Deflate option bits, data descriptor, UTF-8 names; anything else is unknown.
            guard flags & ~UInt16(0x0002 | 0x0004 | 0x0008 | 0x0800) == 0 else { throw ZipError.corrupt }
            guard method == 0 || method == 8 else { throw ZipError.unsupportedMethod(name) }
            try checkExtra(try slice(extraStart, extraLength), name: name)

            let fileType = (external >> 16) & 0o170000
            if (fileType != 0 && fileType != 0o100000) || external & 0x10 != 0 {
                throw ZipError.symlinkOrSpecial(name)
            }
            guard commentLength == 0, diskStart == 0 else { throw ZipError.corrupt }

            let compressedSize = Int(compressed)
            let size = Int(uncompressed)
            guard size <= max(0, entryLimit(name)) else { throw ZipError.entryTooBig(name) }
            if method == 0 {
                guard compressedSize == size else { throw ZipError.sizeMismatch(name) }
            } else {
                let ceiling = try checkedAdd(
                    try checkedMultiply(compressedSize, ZipArchive.maxDeflateRatio), ZipArchive.maxDeflateRatio)
                guard size <= ceiling else { throw ZipError.sizeMismatch(name) }
            }

            // Local header: inside the file, before the central directory, and agreeing with it.
            let local = Int(localOffset)
            let headerEnd = try checkedAdd(local, ZipArchive.localHeaderLength)
            guard headerEnd <= count else { throw ZipError.corrupt }
            guard headerEnd <= directoryStart else { throw ZipError.overlap }
            guard try u32(local) == ZipFormat.localSignature else { throw ZipError.corrupt }
            let localFlags = try u16(local + 6)
            let localMethod = try u16(local + 8)
            let localCRC = try u32(local + 14)
            let localCompressed = try u32(local + 18)
            let localUncompressed = try u32(local + 22)
            let localNameLength = Int(try u16(local + 26))
            let localExtraLength = Int(try u16(local + 28))
            let localNameEnd = try checkedAdd(headerEnd, localNameLength)
            let dataStart = try checkedAdd(localNameEnd, localExtraLength)
            let dataEnd = try checkedAdd(dataStart, compressedSize)
            guard dataEnd <= directoryStart else { throw ZipError.overlap }
            guard localFlags == flags, localMethod == method else { throw ZipError.corrupt }
            guard localNameLength == nameLength, try slice(headerEnd, localNameLength).elementsEqual(nameBytes) else {
                throw ZipError.corrupt
            }
            try checkExtra(try slice(localNameEnd, localExtraLength), name: name)

            var rangeEnd = dataEnd
            if flags & 0x0008 != 0 {
                var fields = dataEnd
                if try checkedAdd(dataEnd, 4) <= directoryStart, try u32(dataEnd) == ZipFormat.descriptorSignature {
                    fields = dataEnd + 4
                }
                rangeEnd = try checkedAdd(fields, 12)
                guard rangeEnd <= directoryStart else { throw ZipError.overlap }
                guard try u32(fields) == crc, try u32(fields + 4) == compressed, try u32(fields + 8) == uncompressed
                else { throw ZipError.corrupt }
                let zeroed = localCRC == 0 && localCompressed == 0 && localUncompressed == 0
                let equal = localCRC == crc && localCompressed == compressed && localUncompressed == uncompressed
                guard zeroed || equal else { throw ZipError.corrupt }
            } else {
                guard localCRC == crc, localCompressed == compressed, localUncompressed == uncompressed else {
                    throw ZipError.corrupt
                }
            }

            let entry = Entry(name: name, compressedSize: compressedSize, size: size)
            let record = Record(
                method: method, crc: crc, dataStart: dataStart, compressedSize: compressedSize, size: size)
            return (entry, record, (local, rangeEnd), next)
        }

        /// UTF-8 (flagged when not ASCII), the shared name rule, and no invisible format or separator
        /// characters (bidi overrides, zero-width, BOM, line separators).
        private func decodeName(_ raw: UnsafeRawBufferPointer.SubSequence, flags: UInt16) throws -> String {
            let lossy = String(decoding: raw, as: UTF8.self)
            let ascii = raw.allSatisfy { $0 < 0x80 }
            guard ascii || flags & 0x0800 != 0 else { throw ZipError.unsafeName(lossy) }
            guard let name = String(bytes: raw, encoding: .utf8), Array(name.utf8).elementsEqual(raw) else {
                throw ZipError.unsafeName(lossy)
            }
            do {
                try ZipFormat.validateName(name)
            } catch {
                throw ZipError.unsafeName(name)
            }
            for scalar in name.unicodeScalars {
                switch scalar.properties.generalCategory {
                case .format, .lineSeparator, .paragraphSeparator, .control, .surrogate, .unassigned, .privateUse:
                    throw ZipError.unsafeName(name)
                default:
                    continue
                }
            }
            return name
        }

        /// Extra fields must be well-formed tag/length pairs; zip64 and AES-encryption fields are refused.
        private func checkExtra(_ extra: UnsafeRawBufferPointer.SubSequence, name: String) throws {
            var offset = extra.startIndex
            while offset < extra.endIndex {
                guard try checkedAdd(offset, 4) <= extra.endIndex else { throw ZipError.corrupt }
                let tag = try u16(offset)
                let length = Int(try u16(offset + 2))
                let next = try checkedAdd(offset + 4, length)
                guard next <= extra.endIndex else { throw ZipError.corrupt }
                if tag == 0x0001 { throw ZipError.zip64 }
                if tag == 0x9901 { throw ZipError.encrypted(name) }
                offset = next
            }
        }

        private func slice(_ offset: Int, _ length: Int) throws -> UnsafeRawBufferPointer.SubSequence {
            let end = try checkedAdd(offset, length)
            guard offset >= 0, length >= 0, end <= count else { throw ZipError.corrupt }
            return bytes[offset..<end]
        }

        private func u16(_ offset: Int) throws -> UInt16 {
            let end = try checkedAdd(offset, 2)
            guard offset >= 0, end <= count else { throw ZipError.corrupt }
            return UInt16(bytes[offset]) | UInt16(bytes[end - 1]) << 8
        }

        private func u32(_ offset: Int) throws -> UInt32 {
            let end = try checkedAdd(offset, 4)
            guard offset >= 0, end <= count else { throw ZipError.corrupt }
            return UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16
                | UInt32(bytes[end - 1]) << 24
        }
    }
}

private func checkedAdd(_ a: Int, _ b: Int) throws -> Int {
    let (sum, overflow) = a.addingReportingOverflow(b)
    guard !overflow else { throw ZipError.corrupt }
    return sum
}

private func checkedMultiply(_ a: Int, _ b: Int) throws -> Int {
    let (product, overflow) = a.multipliedReportingOverflow(by: b)
    guard !overflow else { throw ZipError.corrupt }
    return product
}
