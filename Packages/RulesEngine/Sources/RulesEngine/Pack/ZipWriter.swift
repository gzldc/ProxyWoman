import Compression
import Foundation

public struct ZipEntryInput: Sendable {
    public var name: String
    public var data: Data
    public init(name: String, data: Data) {
        self.name = name
        self.data = data
    }
}

public enum ZipWriter {
    /// Entries in the given order. Each is deflated when that is smaller, otherwise stored. No data descriptors,
    /// no zip64, no extra fields, no comment, fixed DOS time: equal input gives equal bytes.
    /// Throws `ZipError.entryTooLarge` for any entry or total beyond what 32-bit sizes can hold.
    public static func write(_ entries: [ZipEntryInput]) throws -> Data {
        guard entries.count <= Int(UInt16.max) - 1 else { throw ZipError.entryTooLarge }
        var seen = Set<[UInt8]>()
        for entry in entries {
            try ZipFormat.validateName(entry.name)
            guard seen.insert(ZipFormat.foldedKey(entry.name)).inserted else { throw ZipError.invalidName }
        }

        var out = Data()
        var central = Data()
        // 0xFFFFFFFF marks zip64 for the reader, so the largest entry is one byte less.
        let limit = Int(UInt32.max - 1)
        for entry in entries {
            guard entry.data.count <= limit else { throw ZipError.entryTooLarge }
            let nameBytes = Data(entry.name.utf8)
            let (method, payload) = compress(entry.data)
            let offset = out.count
            guard offset <= limit else { throw ZipError.entryTooLarge }
            let crc = ZipFormat.crc32(entry.data)
            let flags: UInt16 = nameBytes.contains(where: { $0 >= 0x80 }) ? 0x0800 : 0
            let version: UInt16 = method == 8 ? 20 : 10

            out.appendLE(ZipFormat.localSignature)
            out.appendLE(version)
            out.appendLE(flags)
            out.appendLE(method)
            out.appendLE(ZipFormat.dosTime)
            out.appendLE(ZipFormat.dosDate)
            out.appendLE(crc)
            out.appendLE(UInt32(payload.count))
            out.appendLE(UInt32(entry.data.count))
            out.appendLE(UInt16(nameBytes.count))
            out.appendLE(UInt16(0))
            out.append(nameBytes)
            out.append(payload)

            central.appendLE(ZipFormat.centralSignature)
            central.appendLE(version)  // made by
            central.appendLE(version)  // needed
            central.appendLE(flags)
            central.appendLE(method)
            central.appendLE(ZipFormat.dosTime)
            central.appendLE(ZipFormat.dosDate)
            central.appendLE(crc)
            central.appendLE(UInt32(payload.count))
            central.appendLE(UInt32(entry.data.count))
            central.appendLE(UInt16(nameBytes.count))
            central.appendLE(UInt16(0))  // extra
            central.appendLE(UInt16(0))  // comment
            central.appendLE(UInt16(0))  // disk
            central.appendLE(UInt16(0))  // internal attributes
            central.appendLE(UInt32(0))  // external attributes
            central.appendLE(UInt32(offset))
            central.append(nameBytes)
        }
        let directoryOffset = out.count
        guard directoryOffset + central.count + 22 <= limit else { throw ZipError.entryTooLarge }
        out.append(central)
        out.appendLE(ZipFormat.endSignature)
        out.appendLE(UInt16(0))
        out.appendLE(UInt16(0))
        out.appendLE(UInt16(entries.count))
        out.appendLE(UInt16(entries.count))
        out.appendLE(UInt32(central.count))
        out.appendLE(UInt32(directoryOffset))
        out.appendLE(UInt16(0))
        return out
    }

    /// Raw deflate when strictly smaller than the input, otherwise the bytes unchanged.
    private static func compress(_ data: Data) -> (method: UInt16, payload: Data) {
        guard data.count > 1 else { return (0, data) }
        let capacity = data.count - 1
        var buffer = [UInt8](repeating: 0, count: capacity)
        let written = data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
            guard let base = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return buffer.withUnsafeMutableBufferPointer { dst in
                guard let out = dst.baseAddress else { return 0 }
                return compression_encode_buffer(out, capacity, base, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0, written < data.count else { return (0, data) }
        return (8, Data(buffer[0..<written]))
    }
}

extension Data {
    fileprivate mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
}
