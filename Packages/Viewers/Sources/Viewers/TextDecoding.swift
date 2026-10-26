import Foundation

/// 按 Content-Type 里的 charset 把 Body 字节解成文本，失败再试 UTF-8。
public enum TextDecoding {
    public static func string(from data: Data, contentType: String?) -> String? {
        if data.isEmpty { return "" }

        if let charset = charset(in: contentType), let encoding = encoding(forCharset: charset),
            encoding != .utf8,
            let text = String(data: data, encoding: encoding)
        {
            return text
        }

        var utf8 = data
        if utf8.starts(with: [0xef, 0xbb, 0xbf]) { utf8 = utf8.dropFirst(3) }
        return String(data: utf8, encoding: .utf8)
    }

    private static func charset(in contentType: String?) -> String? {
        guard let contentType else { return nil }
        for part in contentType.split(separator: ";").dropFirst() {
            let pair = part.split(separator: "=", maxSplits: 1)
            guard pair.count == 2,
                pair[0].trimmingCharacters(in: .whitespaces).lowercased() == "charset"
            else { continue }
            let value = pair[1].trimmingCharacters(
                in: CharacterSet.whitespaces.union(
                    CharacterSet(charactersIn: "\"'")))
            return value.isEmpty ? nil : value
        }
        return nil
    }

    private static func encoding(forCharset name: String) -> String.Encoding? {
        let lower = name.lowercased()
        let cf: CFStringEncoding
        if ["gbk", "gb2312", "gb_2312", "x-gbk", "gb_2312-80"].contains(lower) {
            cf = CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        } else {
            cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        }
        guard cf != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
    }
}
