import Foundation

/// 内容类型的粗分类，用于过滤栏。
/// `classify` 给出单个内容类型的分类；过滤时一条流可同时属于多个类别（见 `matches`）。
public enum ContentKind: String, CaseIterable, Sendable {
    case json, html, xml, javascript, css, form, graphql, image, font, media, text, other

    public static func classify(contentType: String?) -> ContentKind {
        guard let contentType else { return .other }
        let mime = contentType
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)[0]
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        let parts = mime.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return .other }
        let type = String(parts[0])
        let subtype = String(parts[1])

        // 先按顶层类型判断，保证 image/svg+xml 归入图片而不是 XML。
        switch type {
        case "image": return .image
        case "font": return .font
        case "video", "audio": return .media
        default: break
        }
        if subtype.hasPrefix("font-") || subtype.hasPrefix("x-font-") || subtype == "vnd.ms-fontobject" {
            return .font
        }
        if isForm(type: type, subtype: subtype) { return .form }
        if type == "application" && subtype == "graphql" { return .graphql }
        if subtype == "json" || subtype.hasSuffix("+json") { return .json }
        if subtype == "html" || subtype == "xhtml+xml" { return .html }
        if subtype == "xml" || subtype.hasSuffix("+xml") { return .xml }
        if subtype == "javascript" || subtype == "x-javascript" || subtype == "ecmascript" { return .javascript }
        if type == "text" && subtype == "css" { return .css }
        if type == "text" { return .text }
        return .other
    }

    /// 流是否属于 `kinds` 中的任意一类。form、graphql 请求和响应命中任意一边即可，
    /// graphql 还可以靠路径以 `/graphql` 结尾（忽略 query）；其余类别只看响应。
    /// 过滤每个批次的每条流都会调用，所以按需判断、不用正则。
    static func matches(_ flow: Flow, anyOf kinds: Set<ContentKind>) -> Bool {
        let responseType = flow.responseHeaders.value(for: "content-type")
        if kinds.contains(classify(contentType: responseType)) { return true }
        // classify 把 application/graphql-response+json 归为 JSON；它同时也是 GraphQL。
        let needsForm = kinds.contains(.form)
        let needsGraphQL = kinds.contains(.graphql)
        guard needsForm || needsGraphQL else { return false }

        let requestType = flow.requestHeaders.value(for: "content-type")
        if needsForm, mime(of: responseType).map(isForm) == true || mime(of: requestType).map(isForm) == true {
            return true
        }
        if needsGraphQL {
            if mime(of: responseType).map(isGraphQL) == true || mime(of: requestType).map(isGraphQL) == true {
                return true
            }
            let pathOnly = flow.path.prefix { $0 != "?" && $0 != "#" }
            if pathOnly.lowercased().hasSuffix("/graphql") { return true }
        }
        return false
    }

    private static func mime(of contentType: String?) -> (type: String, subtype: String)? {
        guard let contentType else { return nil }
        let essence = contentType
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)[0]
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        let parts = essence.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        return (String(parts[0]), String(parts[1]))
    }

    private static func isForm(type: String, subtype: String) -> Bool {
        (type == "application" && subtype == "x-www-form-urlencoded") || (type == "multipart" && subtype == "form-data")
    }

    private static func isGraphQL(type: String, subtype: String) -> Bool {
        type == "application" && (subtype == "graphql" || subtype == "graphql-response+json")
    }
}
