import FlowStore
import Localization

/// 过滤栏的快捷标签。协议类和内容类各自是一组：组内多选取并集，组与组之间取交集。
public enum QuickFilterChip: CaseIterable, Hashable, Sendable {
    case all, http, https, websocket
    case json, form, xml, javascript, css, graphql, document, media, other

    public var title: String {
        switch self {
        case .all: L10n.string("common.all")
        case .http: "HTTP"
        case .https: "HTTPS"
        case .websocket: "WebSocket"
        case .json: "JSON"
        case .form: L10n.string("quickFilter.form")
        case .xml: "XML"
        case .javascript: "JS"
        case .css: "CSS"
        case .graphql: "GraphQL"
        case .document: L10n.string("quickFilter.document")
        case .media: L10n.string("quickFilter.media")
        case .other: L10n.string("quickFilter.other")
        }
    }

    var flowProtocol: FlowProtocol? {
        switch self {
        case .http: .http
        case .https: .https
        case .websocket: .websocket
        default: nil
        }
    }

    var contentKinds: Set<ContentKind> {
        switch self {
        case .json: [.json]
        case .form: [.form]
        case .xml: [.xml]
        case .javascript: [.javascript]
        case .css: [.css]
        case .graphql: [.graphql]
        case .document: [.html]
        case .media: [.image, .font, .media]
        case .other: [.text, .other]
        case .all, .http, .https, .websocket: []
        }
    }
}

public enum QuickFilter {
    /// 菜单里“更多过滤”的激活数：方法、状态类别各算一项，加上标记、被规则修改过、注释包含。
    public static func moreFilterCount(_ filter: FlowFilter) -> Int {
        filter.methods.count + filter.statusClasses.count + (filter.hasMark ? 1 : 0)
            + (filter.rulesModified ? 1 : 0) + (filter.commentContains.isEmpty ? 0 : 1)
    }

    /// “查看”规则命中：只显示这些 id（静态快照），其余条件不动。
    public static func showRuleMatches(ids: [Int], in filter: inout FlowFilter) {
        filter.ids = Set(ids)
    }

    public static func clearRuleMatches(_ filter: inout FlowFilter) {
        filter.ids = nil
    }

    /// 过滤栏上“规则命中 N 条 ×”标签的文字；没有按 id 过滤时为 nil。它有自己的标签，不计入 `moreFilterCount`。
    public static func ruleMatchesTitle(_ filter: FlowFilter, localizer: Localizer = L10n.localizer) -> String? {
        filter.ids.map { localizer.format("quickFilterBar.ruleMatches", arguments: [$0.count]) }
    }

    /// 只把标记、被规则修改过、注释包含归位，其余条件不动。
    public static func clearAnnotationFilters(_ filter: inout FlowFilter) {
        filter.hasMark = false
        filter.rulesModified = false
        filter.commentContains = ""
    }

    /// 把选中的标签写进过滤条件的 `protocols` 和 `contentKinds`，不动其他条件。
    /// 选中“全部”（或什么都没选）就清空这两项。
    public static func apply(_ selected: Set<QuickFilterChip>, to filter: inout FlowFilter) {
        if selected.contains(.all) {
            filter.protocols = []
            filter.contentKinds = []
            return
        }
        filter.protocols = Set(selected.compactMap(\.flowProtocol))
        filter.contentKinds = selected.reduce(into: []) { $0.formUnion($1.contentKinds) }
    }

    /// 点一下标签后的选择：点“全部”只剩“全部”；点其他标签就在当前选择（去掉“全部”）里加上或去掉它，
    /// 去空了回到“全部”。
    public static func toggling(_ chip: QuickFilterChip, in selection: Set<QuickFilterChip>) -> Set<QuickFilterChip> {
        guard chip != .all else { return [.all] }
        var result = selection.subtracting([.all])
        if result.remove(chip) == nil { result.insert(chip) }
        return result.isEmpty ? [.all] : result
    }

    /// `apply` 的逆运算，用来显示当前状态。协议和内容类都为空时是 `[.all]`；
    /// 内容类只有一部分命中某个多类别标签（如只有“图片”）时，该标签不算选中。
    public static func selection(from filter: FlowFilter) -> Set<QuickFilterChip> {
        if filter.protocols.isEmpty && filter.contentKinds.isEmpty { return [.all] }
        return Set(
            QuickFilterChip.allCases.filter { chip in
                if let flowProtocol = chip.flowProtocol { return filter.protocols.contains(flowProtocol) }
                let kinds = chip.contentKinds
                return !kinds.isEmpty && kinds.isSubset(of: filter.contentKinds)
            })
    }
}
