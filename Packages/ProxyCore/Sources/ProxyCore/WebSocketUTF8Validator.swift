import Foundation

/// Actor-confined streaming validator. No decoded strings or payload copies are retained.
public final class WebSocketUTF8Validator {
    private var remaining = 0
    private var lower: UInt8 = 0x80
    private var upper: UInt8 = 0xBF
    private var valid = true
    public init() {}

    public func feed(_ bytes: Data) -> Bool {
        for byte in bytes {
            guard accept(byte) else { return false }
        }
        return valid
    }

    public func finish() -> Bool { valid && remaining == 0 }

    /// Longest strictly valid prefix ending at a scalar boundary. Does not change this validator.
    public func completePrefixLength(in bytes: Data) -> Int {
        let prefix = WebSocketUTF8Validator()
        var complete = 0
        for (index, byte) in bytes.enumerated() {
            guard prefix.accept(byte) else { break }
            if prefix.remaining == 0 { complete = index + 1 }
        }
        return complete
    }

    private func accept(_ byte: UInt8) -> Bool {
        guard valid else { return false }
        if remaining > 0 {
            guard byte >= lower && byte <= upper else { valid = false; return false }
            remaining -= 1; lower = 0x80; upper = 0xBF
        } else {
            switch byte {
            case 0...0x7F: break
            case 0xC2...0xDF: remaining = 1
            case 0xE0: remaining = 2; lower = 0xA0
            case 0xE1...0xEC, 0xEE...0xEF: remaining = 2
            case 0xED: remaining = 2; upper = 0x9F
            case 0xF0: remaining = 3; lower = 0x90
            case 0xF1...0xF3: remaining = 3
            case 0xF4: remaining = 3; upper = 0x8F
            default: valid = false
            }
        }
        return valid
    }
}
