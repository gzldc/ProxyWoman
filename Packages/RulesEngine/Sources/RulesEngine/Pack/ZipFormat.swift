import Foundation

/// Typed reasons a zip archive is refused or cannot be written. Cases are only ever appended.
public enum ZipError: Error, Equatable, Sendable {
    // Writing.
    case entryTooLarge, invalidName
    // Reading: the archive as a whole.
    case notAnArchive, tooLarge, tooManyEntries, expandedTooLarge, entryTooBig(String)
    // Reading: one entry (the associated value is the entry's name).
    case unsafeName(String), duplicateName(String), encrypted(String), unsupportedMethod(String)
    case symlinkOrSpecial(String), zip64, corrupt, crcMismatch(String), sizeMismatch(String), overlap
}

/// Constants and helpers shared by the zip writer and reader.
enum ZipFormat {
    static let localSignature: UInt32 = 0x0403_4b50
    static let centralSignature: UInt32 = 0x0201_4b50
    static let endSignature: UInt32 = 0x0605_4b50
    static let zip64LocatorSignature: UInt32 = 0x0706_4b50
    static let descriptorSignature: UInt32 = 0x0807_4b50
    /// 1980-01-01 00:00:00.
    static let dosTime: UInt16 = 0
    static let dosDate: UInt16 = 0x0021

    static let maxNameBytes = 255

    private static let crcTable: [UInt32] = (0..<256).map { index -> UInt32 in
        var c = UInt32(index)
        for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1) }
        return c
    }

    /// IEEE CRC-32, table driven.
    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for byte in raw { crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        }
        return crc ^ 0xFFFF_FFFF
    }

    /// The one rule for entry names, used when writing and when reading: non-empty, at most 255 UTF-8 bytes,
    /// no control characters, no leading slash, no backslash, and no empty, `.` or `..` segment
    /// (which also refuses directory entries, which this format never has).
    static func validateName(_ name: String) throws {
        let bytes = Array(name.utf8)
        guard !bytes.isEmpty, bytes.count <= maxNameBytes else { throw ZipError.invalidName }
        for scalar in name.unicodeScalars {
            if scalar.value < 0x20 || scalar.value == 0x7F || (0x80...0x9F).contains(scalar.value) {
                throw ZipError.invalidName
            }
        }
        guard !name.hasPrefix("/"), !name.contains("\\") else { throw ZipError.invalidName }
        for segment in name.split(separator: "/", omittingEmptySubsequences: false) {
            if segment.isEmpty || segment == "." || segment == ".." { throw ZipError.invalidName }
        }
    }

    /// Duplicate detection key: ASCII letters folded to lower case, everything else untouched.
    static func foldedKey(_ name: String) -> [UInt8] {
        name.utf8.map { (0x41...0x5A).contains($0) ? $0 + 0x20 : $0 }
    }
}
