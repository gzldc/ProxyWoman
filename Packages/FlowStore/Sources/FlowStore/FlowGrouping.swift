import Foundation

public struct GroupCount: Sendable, Hashable {
    public var name: String
    public var count: Int

    public init(name: String, count: Int) {
        self.name = name
        self.count = count
    }
}

public enum FlowGrouping {
    /// 没有 client 信息的记录归入的分组名。It is a stable grouping key, not display text: pinned apps and
    /// selections are stored under it, so it never changes with the interface language. Views show
    /// `AppCore.SourceBarItem.appDisplayName(_:)` instead.
    public static let unknownApp = "未知"

    static func appName(of flow: Flow) -> String {
        flow.client?.name ?? unknownApp
    }

    /// 按主机名升序。
    public static func hosts(_ flows: [Flow]) -> [GroupCount] {
        counts(flows.lazy.map(\.host))
    }

    /// 按应用名升序；没有 client 的归为 "未知"。
    public static func apps(_ flows: [Flow]) -> [GroupCount] {
        counts(flows.lazy.map(appName(of:)))
    }

    /// 某个应用访问过的主机，按主机名升序。
    public static func hosts(_ flows: [Flow], ofApp app: String) -> [GroupCount] {
        counts(flows.lazy.filter { appName(of: $0) == app }.map(\.host))
    }

    private static func counts(_ names: some Sequence<String>) -> [GroupCount] {
        var tally: [String: Int] = [:]
        for name in names { tally[name, default: 0] += 1 }
        return tally.map { GroupCount(name: $0.key, count: $0.value) }.sorted { $0.name < $1.name }
    }
}
