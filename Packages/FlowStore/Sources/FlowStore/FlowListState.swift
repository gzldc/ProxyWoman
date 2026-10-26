import Foundation

/// 主窗口列表的数据：在 `FlowCollection` 之上增量维护过滤结果和按主机、应用的分组计数。
/// 每个批次的开销只与批次大小（和分组数）有关，只有修改过滤条件时才全量重新过滤。
public struct FlowListState: Sendable {
    public private(set) var collection = FlowCollection()
    public private(set) var filter = FlowFilter()
    public private(set) var hostGroups: [GroupCount] = []
    public private(set) var appGroups: [GroupCount] = []

    /// 只在“过滤条件不是默认值，或集合里有隐藏流量”时维护，按 id 升序。
    private var filtered: [Flow] = []
    private var hostTally: [String: Int] = [:]
    private var appTally: [String: Int] = [:]
    /// app → host → count, for the hosts listed under an app in the sidebar.
    private var appHostTally: [String: [String: Int]] = [:]
    /// 集合里隐藏流量的条数。
    public private(set) var hiddenCount = 0

    public init() {}

    /// 没有任何需要排除的东西时直接就是 `collection.flows`，不另存一份。
    public var visible: [Flow] {
        maintainsFiltered ? filtered : collection.flows
    }

    /// The hosts `app` has talked to, ascending by name. O(hosts of that app).
    public func hostGroups(ofApp app: String) -> [GroupCount] {
        appHostTally[app].map(Self.groups) ?? []
    }

    /// Sidebar tallies only count flows that are not hidden; this is the key a flow counts under.
    private struct TallyKey: Equatable {
        var host: String
        var app: String
        init?(_ flow: Flow) {
            guard !flow.isHidden else { return nil }
            host = flow.host
            app = FlowGrouping.appName(of: flow)
        }
    }

    public mutating func apply(_ change: FlowChange) {
        let wasMaintaining = maintainsFiltered
        if change.cleared {
            collection.apply(FlowChange(cleared: true, upserted: []))
            filtered.removeAll()
            hostTally.removeAll()
            appTally.removeAll()
            appHostTally.removeAll()
            hiddenCount = 0
        }
        var groupsChanged = change.cleared
        if !change.removed.isEmpty {
            for id in change.removed {
                guard let old = collection.flow(id: id) else { continue }
                if let key = TallyKey(old) {
                    removeTally(key)
                    groupsChanged = true
                } else {
                    hiddenCount -= 1
                }
            }
            collection.apply(FlowChange(cleared: false, removed: change.removed, upserted: []))
            if wasMaintaining { filtered.removeFlows(withIDs: change.removed) }
        }
        for flow in change.upserted {
            let old = collection.flow(id: flow.id)
            // An update only moves counts when its eligibility (not hidden), host or app changed
            // (the client is looked up after the flow was created).
            let oldKey = old.flatMap(TallyKey.init)
            let key = TallyKey(flow)
            if oldKey != key {
                if let oldKey { removeTally(oldKey) }
                if let key { addTally(key) }
                groupsChanged = true
            }
            if old?.isHidden == true { hiddenCount -= 1 }
            if flow.isHidden { hiddenCount += 1 }
            collection.apply(FlowChange(cleared: false, upserted: [flow]))
        }
        if groupsChanged {
            hostGroups = Self.groups(hostTally)
            appGroups = Self.groups(appTally)
        }

        if !scopeExists {
            // Its group is gone (cleared, hidden, or the client was back-filled): show everything again.
            var filter = self.filter
            filter.scope = .all
            setFilter(filter)
        } else if maintainsFiltered {
            if wasMaintaining {
                for flow in change.upserted { refilter(flow) }
            } else {
                filtered = collection.flows.filter(filter.matches)
            }
        } else if wasMaintaining {
            filtered = []
        }
    }

    public mutating func setFilter(_ filter: FlowFilter) {
        guard filter != self.filter else { return }
        self.filter = filter
        filtered = maintainsFiltered ? collection.flows.filter(filter.matches) : []
    }

    private var maintainsFiltered: Bool { filter != FlowFilter() || hiddenCount > 0 }

    private var scopeExists: Bool {
        switch filter.scope {
        case .all: true
        case .host(let host): hostTally[host] != nil
        case .app(let name): appTally[name] != nil
        case .appHost(let app, let host): appHostTally[app]?[host] != nil
        }
    }

    private mutating func addTally(_ key: TallyKey) {
        hostTally[key.host, default: 0] += 1
        appTally[key.app, default: 0] += 1
        appHostTally[key.app, default: [:]][key.host, default: 0] += 1
    }

    private mutating func removeTally(_ key: TallyKey) {
        Self.decrement(&hostTally, key.host)
        Self.decrement(&appTally, key.app)
        decrementPair(app: key.app, host: key.host)
    }

    /// Inserts, replaces or removes one flow in `filtered`.
    private mutating func refilter(_ flow: Flow) {
        let index = filtered.insertionIndex(forID: flow.id)
        let isPresent = index < filtered.count && filtered[index].id == flow.id
        switch (isPresent, filter.matches(flow)) {
        case (true, true): filtered[index] = flow
        case (true, false): filtered.remove(at: index)
        case (false, true): filtered.insert(flow, at: index)
        case (false, false): break
        }
    }

    private mutating func decrementPair(app: String, host: String) {
        guard var hosts = appHostTally[app] else { return }
        Self.decrement(&hosts, host)
        appHostTally[app] = hosts.isEmpty ? nil : hosts
    }

    private static func decrement(_ tally: inout [String: Int], _ name: String) {
        guard let count = tally[name] else { return }
        tally[name] = count > 1 ? count - 1 : nil
    }

    /// Ascending by name, like `FlowGrouping`.
    private static func groups(_ tally: [String: Int]) -> [GroupCount] {
        tally.map { GroupCount(name: $0.key, count: $0.value) }.sorted { $0.name < $1.name }
    }
}
