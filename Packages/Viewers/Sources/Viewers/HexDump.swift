import Foundation
import Localization

/// 把二进制数据格式化成经典的十六进制转储：`偏移  字节区  |ASCII|`。
public enum HexDump {
    public static func format(
        _ data: Data, bytesPerLine: Int = 16, maxBytes: Int = 1_048_576, localizer: Localizer = L10n.localizer
    ) -> String {
        guard !data.isEmpty else { return "" }
        let perLine = max(1, bytesPerLine)
        let shown = data.prefix(max(0, maxBytes))
        let hexDigits = Array("0123456789abcdef")
        let hexAreaWidth = perLine * 3 - 1

        var lines: [String] = []
        var offset = 0
        let bytes = Array(shown)
        while offset < bytes.count {
            let chunk = bytes[offset..<min(offset + perLine, bytes.count)]

            var line = String(offset, radix: 16)
            line = String(repeating: "0", count: max(0, 8 - line.count)) + line
            line += "  "

            var hex = ""
            hex.reserveCapacity(hexAreaWidth)
            var ascii = ""
            for (i, b) in chunk.enumerated() {
                if i > 0 { hex.append(" ") }
                hex.append(hexDigits[Int(b >> 4)])
                hex.append(hexDigits[Int(b & 0x0f)])
                ascii.append(b >= 0x20 && b <= 0x7e ? Character(UnicodeScalar(b)) : ".")
            }
            hex += String(repeating: " ", count: hexAreaWidth - hex.count)

            lines.append(line + hex + "  |" + ascii + "|")
            offset += perLine
        }
        if data.count > shown.count {
            lines.append(localizer.format("hexDump.truncated", arguments: [data.count]))
        }
        return lines.joined(separator: "\n")
    }
}
