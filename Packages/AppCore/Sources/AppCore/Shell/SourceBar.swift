import FlowStore
import Foundation
import Localization

/// A row of the source bar. Group rows (`all`, `pinned`, `apps`, `hosts`, `marked`, `hidden`,
/// `undecrypted`) address everything; leaf rows narrow by app / host.
public enum SourceBarItem: Hashable, Sendable {
    case all, pinned, pinnedApp(String), pinnedHost(String), apps, app(String)
    case appHost(app: String, host: String)
    case hosts, host(String)
    case marked, hidden, undecrypted, undecryptedHost(String)

    /// The text a view shows for an app group. The group key of records without client information is a
    /// stable internal value, so only its label is localized; real application names are shown as they are.
    public static func appDisplayName(_ name: String, localizer: Localizer = L10n.localizer) -> String {
        name == FlowGrouping.unknownApp ? localizer.string("sourceBar.unknownApp") : name
    }

    public var scope: FlowScope {
        switch self {
        case .app(let name): .app(name)
        case .appHost(let app, let host): .appHost(app: app, host: host)
        case .host(let host), .undecryptedHost(let host): .host(host)
        case .pinnedApp(let name): .app(name)
        case .pinnedHost(let host): .host(host)
        case .all, .pinned, .apps, .hosts, .marked, .hidden, .undecrypted: .all
        }
    }

    public var source: FlowSourceFilter {
        switch self {
        case .marked: .marked
        case .hidden: .hidden
        case .undecrypted, .undecryptedHost: .undecrypted
        default: .any
        }
    }

    /// Changes only `scope` and `source`.
    public func apply(to filter: inout FlowFilter) {
        filter.scope = scope
        filter.source = source
    }

    public static func item(for filter: FlowFilter) -> SourceBarItem {
        switch filter.source {
        case .marked: return .marked
        case .hidden: return .hidden
        case .undecrypted:
            if case .host(let host) = filter.scope { return .undecryptedHost(host) }
            return .undecrypted
        case .any:
            switch filter.scope {
            case .all: return .all
            case .app(let name): return .app(name)
            case .host(let host): return .host(host)
            case .appHost(let app, let host): return .appHost(app: app, host: host)
            }
        }
    }
}

/// Incrementally maintained counts behind the source bar's marked / hidden / undecrypted rows.
public struct SourceBarTally: Equatable, Sendable {
    public private(set) var allCount = 0
    public private(set) var markedCount = 0
    public private(set) var hiddenCount = 0
    public private(set) var undecryptedCount = 0
    private var undecryptedByHost: [String: Int] = [:]

    public var undecryptedHosts: [GroupCount] {
        undecryptedByHost.map { GroupCount(name: $0.key, count: $0.value) }.sorted { $0.name < $1.name }
    }

    public init() {}

    /// `previous` looks a flow up in the state from before this change.
    public mutating func apply(_ change: FlowChange, previous: (Int) -> Flow?) {
        if change.cleared { self = SourceBarTally() }
        var latest: [Int: Flow?] = [:]
        func current(_ id: Int) -> Flow? {
            if let seen = latest[id] { return seen }
            return change.cleared ? nil : previous(id)
        }
        for id in change.removed {
            if let old = current(id) { count(old, by: -1) }
            latest[id] = .some(nil)
        }
        for flow in change.upserted {
            if let old = current(flow.id) { count(old, by: -1) }
            count(flow, by: 1)
            latest[flow.id] = .some(flow)
        }
    }

    public static func recount(_ flows: [Flow]) -> SourceBarTally {
        var tally = SourceBarTally()
        for flow in flows { tally.count(flow, by: 1) }
        return tally
    }

    private mutating func count(_ flow: Flow, by delta: Int) {
        if flow.isHidden {
            hiddenCount += delta
            return
        }
        allCount += delta
        if flow.displayMark != nil { markedCount += delta }
        if flow.method == "CONNECT" {
            undecryptedCount += delta
            let value = (undecryptedByHost[flow.host] ?? 0) + delta
            undecryptedByHost[flow.host] = value > 0 ? value : nil
        }
    }
}
