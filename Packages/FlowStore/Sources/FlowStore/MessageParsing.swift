import Foundation

public struct NameValue: Sendable, Hashable {
    public var name: String
    public var value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

public struct ResponseCookie: Sendable, Hashable {
    public var name: String
    public var value: String
    /// Set-Cookie 里分号后面的各项，原样保留（如 "Path=/"、"HttpOnly"）。
    public var attributes: [String]

    public init(name: String, value: String, attributes: [String]) {
        self.name = name
        self.value = value
        self.attributes = attributes
    }
}

public enum MessageParsing {
    /// 解析 origin-form path 的 query：百分号解码，"+" 解码为空格，保留顺序和重复项。
    public static func queryItems(path: String) -> [NameValue] {
        guard let questionMark = path.firstIndex(of: "?") else { return [] }
        var query = path[path.index(after: questionMark)...]
        if let hash = query.firstIndex(of: "#") { query = query[..<hash] }
        return query.split(separator: "&").map { pair in
            let (name, value) = splitPair(pair)
            return NameValue(name: decodeComponent(name), value: decodeComponent(value))
        }
    }

    /// 合并所有 Cookie 头，按出现顺序返回。
    public static func requestCookies(_ headers: [HeaderField]) -> [NameValue] {
        headers.values(for: "cookie").flatMap { header in
            header.split(separator: ";").compactMap { part -> NameValue? in
                let (name, value) = splitPair(part.drop { $0 == " " || $0 == "\t" })
                let trimmedName = name.trimmingCharacters(in: .whitespaces)
                guard !trimmedName.isEmpty else { return nil }
                return NameValue(name: trimmedName, value: value.trimmingCharacters(in: .whitespaces))
            }
        }
    }

    /// 每个 Set-Cookie 头对应一项。
    public static func responseCookies(_ headers: [HeaderField]) -> [ResponseCookie] {
        headers.values(for: "set-cookie").compactMap { header in
            let parts = header.split(separator: ";", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard let first = parts.first else { return nil }
            let (name, value) = splitPair(Substring(first))
            let trimmedName = name.trimmingCharacters(in: .whitespaces)
            guard !trimmedName.isEmpty else { return nil }
            return ResponseCookie(
                name: trimmedName,
                value: value.trimmingCharacters(in: .whitespaces),
                attributes: parts.dropFirst().filter { !$0.isEmpty }
            )
        }
    }

    /// 以第一个 "=" 分成名称和值；没有 "=" 时值为空。
    private static func splitPair(_ pair: Substring) -> (Substring, Substring) {
        guard let equals = pair.firstIndex(of: "=") else { return (pair, "") }
        return (pair[..<equals], pair[pair.index(after: equals)...])
    }

    private static func decodeComponent(_ component: Substring) -> String {
        let spaced = component.replacingOccurrences(of: "+", with: " ")
        return spaced.removingPercentEncoding ?? spaced
    }
}
