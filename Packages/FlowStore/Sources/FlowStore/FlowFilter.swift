import Foundation

public enum StatusClass: String, CaseIterable, Sendable {
    case informational, success, redirect, clientError, serverError, failed

    /// 有状态码时按状态码归类；没有状态码时，只有失败的请求归入 `.failed`，其余返回 nil。
    public static func of(_ flow: Flow) -> StatusClass? {
        if let code = flow.statusCode {
            switch code {
            case 100..<200: return .informational
            case 200..<300: return .success
            case 300..<400: return .redirect
            case 400..<500: return .clientError
            case 500..<600: return .serverError
            default: return nil
            }
        }
        if case .failed = flow.state { return .failed }
        return nil
    }
}

/// 按传输方式划分，三者互斥：WebSocket 优先于 HTTPS，HTTPS 优先于 HTTP。
public enum FlowProtocol: String, CaseIterable, Sendable {
    case http, https, websocket

    public static func of(_ flow: Flow) -> FlowProtocol {
        of(flow, webSocketSummary: nil)
    }

    /// Classifies attempted upgrades; only the supplied assessment proves success.
    public static func of(_ flow: Flow, webSocketSummary: WebSocketSummary?) -> FlowProtocol {
        func containsToken(_ name: String, _ token: String) -> Bool {
            flow.requestHeaders.filter { $0.name.utf8.allSatisfy { $0 < 128 } && $0.name.caseInsensitiveCompare(name) == .orderedSame }
                .flatMap { $0.value.split(separator: ",") }
                .contains {
                    let candidate = $0.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
                    return candidate.utf8.allSatisfy { $0 < 128 } && candidate.caseInsensitiveCompare(token) == .orderedSame
                }
        }
        if webSocketSummary != nil || (flow.method == "GET" && containsToken("Upgrade", "websocket") && containsToken("Connection", "upgrade")) {
            return .websocket
        }
        if flow.scheme == "https" || flow.method == "CONNECT" { return .https }
        return .http
    }
}

public enum FlowScope: Sendable, Hashable {
    case all
    case host(String)
    /// `.app(FlowGrouping.unknownApp)` 匹配没有 client 的记录。
    case app(String)
    /// 某个应用访问某个主机的记录（左栏应用下展开的域名）。
    case appHost(app: String, host: String)
}

/// 来源栏的只读过滤维度，与 `hasMark` 互相独立。
public enum FlowSourceFilter: Sendable, Hashable {
    case any
    /// `displayMark != nil`。
    case marked
    /// 只显示隐藏的流量（无需 `includeHidden`）。
    case hidden
    /// 未解密的隧道行：`method == "CONNECT"`（含失败的）。
    case undecrypted
}

public struct FlowFilter: Sendable, Equatable {
    /// 在完整 URL 上做大小写不敏感的包含匹配；空或纯空白表示不限。
    public var text = ""
    /// 以下集合为空都表示不限，各条件之间是 AND 关系。
    public var methods: Set<String> = []
    public var statusClasses: Set<StatusClass> = []
    public var contentKinds: Set<ContentKind> = []
    public var protocols: Set<FlowProtocol> = []
    public var scope: FlowScope = .all
    /// `displayMark != nil`（手动标记优先，规则标记次之）。
    public var hasMark = false
    /// `flow.provenance.rulesModified || flow.executeOverlay != nil`（实时改写与 Execute 修改层都算；只有标记 / 注释 / 隐藏的 Execute 不算）。
    public var rulesModified = false
    /// 在备注上做大小写不敏感的包含匹配；去首尾空白后为空表示不限，备注为 nil 不匹配。
    public var commentContains = ""
    /// false 时隐藏的流量一律不匹配。
    public var includeHidden = false
    /// nil = 不限；非 nil 时只有这些 id 匹配（空集合什么都不匹配），与其余条件是 AND。
    public var ids: Set<Int>? = nil
    /// 来源栏维度；`.any` 时与此前的行为完全一致，其余与各维度 AND。
    public var source: FlowSourceFilter = .any

    public init() {}

    public func matches(_ flow: Flow) -> Bool {
        if flow.isHidden && !includeHidden && source != .hidden { return false }
        switch source {
        case .any: break
        case .marked: if flow.displayMark == nil { return false }
        case .hidden: if !flow.isHidden { return false }
        case .undecrypted: if flow.method != "CONNECT" { return false }
        }
        if let ids, !ids.contains(flow.id) { return false }
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !needle.isEmpty && !flow.url.localizedCaseInsensitiveContains(needle) { return false }
        if !methods.isEmpty && !methods.contains(flow.method) { return false }
        if !statusClasses.isEmpty {
            guard let statusClass = StatusClass.of(flow), statusClasses.contains(statusClass) else { return false }
        }
        if !protocols.isEmpty && !protocols.contains(FlowProtocol.of(flow)) { return false }
        if !contentKinds.isEmpty && !ContentKind.matches(flow, anyOf: contentKinds) { return false }
        if hasMark && flow.displayMark == nil { return false }
        if rulesModified && !(flow.provenance.rulesModified || flow.executeOverlay != nil) { return false }
        let commentNeedle = commentContains.trimmingCharacters(in: .whitespacesAndNewlines)
        if !commentNeedle.isEmpty {
            guard let comment = flow.comment, comment.localizedCaseInsensitiveContains(commentNeedle) else { return false }
        }
        switch scope {
        case .all: return true
        case .host(let host): return flow.host == host
        case .app(let name): return FlowGrouping.appName(of: flow) == name
        case .appHost(let app, let host): return flow.host == host && FlowGrouping.appName(of: flow) == app
        }
    }
}
