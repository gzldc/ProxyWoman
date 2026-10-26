import Foundation

/// The nine groups of the built-in template tree, in the order of their ids (the top group first).
public enum DefaultTemplateGroupKey: Int, CaseIterable, Sendable {
    case root, allowBlock, filters, mapTraffic, mapLocalManual, mapLocalFile, modifyTraffic, tooling, uiMarks
}

/// The 28 template rules. The raw value is the rule's position in the reference list, which the mapping
/// tests and the deterministic ids both use.
public enum DefaultTemplateRuleKey: Int, CaseIterable, Sendable {
    case allowOnlyProcesses, allowOnlyHosts, blockProcesses, blockHosts
    case hideConnectTunnels, hideProcesses, hideHosts, showOnlyProcesses, showOnlyHosts, showOnlyLocalhost
    case hideConnectsOfBlockedProcesses
    case mapRemoteLocalhost, mapRemoteURL, redirect307
    case manualReturnConnect, manualReturnResponse, fileReturnConnect, fileReturnResponse
    case insertHTMLRegex, insertHTML, modifyImageEndpoint
    case userAgentChromeMac, userAgentChromeWindows, bypassCORS, noCaching, blockCookies
    case markLongLivingSessions, markScriptsAndJSON
}

/// A file the template set ships. Return File actions only point at managed copies, so the installer
/// imports `data` into the asset store and puts the new id where `placeholderID` stands.
public struct DefaultTemplateAsset: Sendable, Equatable {
    public var placeholderID: UUID
    public var displayName: String
    public var data: Data

    public init(placeholderID: UUID, displayName: String, data: Data) {
        self.placeholderID = placeholderID
        self.displayName = displayName
        self.data = data
    }
}

/// The built-in template tree as data: groups and rules ready to be installed, plus the files they use.
public struct DefaultTemplateSet: Sendable, Equatable {
    public var version: Int
    public var rootGroupID: UUID
    /// The top group first, then the others in tree order. Every group carries its final `order`.
    public var groups: [RuleGroup]
    /// Grouped by parent, each rule with its final `order`.
    public var rules: [Rule]
    public var assets: [DefaultTemplateAsset]

    public init(version: Int, rootGroupID: UUID, groups: [RuleGroup], rules: [Rule], assets: [DefaultTemplateAsset]) {
        self.version = version
        self.rootGroupID = rootGroupID
        self.groups = groups
        self.rules = rules
        self.assets = assets
    }
}

/// Builds the built-in template tree: nine groups and 28 rules. Pure and Foundation-only; the caller
/// supplies every display name, so the engine knows no language. Ids are fixed, so the same set is
/// built every time. Every rule uses placeholder `example.com`-style values and neutral content, and
/// the top group is stored disabled, so installing it cannot change any traffic.
public enum DefaultTemplateCatalog {
    /// Bumped when the shipped set changes; an install with an older stored version adds the new set next to what is
    /// there. The installer never removes or updates a tree of an earlier version (R8F3-9), so a new version must use new
    /// group and rule ids, or the old tree stays beside the new one with the same ids and the save is refused.
    public static let currentVersion = 1

    public static func groupID(_ key: DefaultTemplateGroupKey) -> UUID {
        UUID(uuidString: groupIDs[key.rawValue])!
    }

    public static func ruleID(_ key: DefaultTemplateRuleKey) -> UUID {
        UUID(uuidString: String(format: "D7E1A000-0000-4000-8000-%012lX", key.rawValue + 1))!
    }

    /// The placeholder the Return File rule carries until its asset is imported.
    public static let exampleFilePlaceholderID = UUID(uuidString: "D7E1A0FF-0000-4000-8000-000000000001")!

    private static let groupIDs = [
        "E5D57F79-22A5-43CF-810D-B25D57CA71A6", "5B00A932-24C8-4AB5-86B0-B3C56B062CBF",
        "E181ADF1-6110-4C9B-AAA2-D85DE99BB44F", "EF9B63E4-28A5-42C0-8AC9-EEDA8EDF6301",
        "BF383E69-3C96-4825-A426-7D78A9A0DB56", "6DD50549-6F02-4008-9450-032894E3B259",
        "2439D240-8B9D-403F-B767-A081BF4770CB", "904E9D3D-F2B2-4A86-9028-7931DFE1EB0E",
        "5EA2FD52-E731-408A-BF40-4EC57589A942",
    ]

    /// Where a group sits and whether it is on, in the reference's numbering (`priority` is 1-based).
    private static func placement(_ key: DefaultTemplateGroupKey) -> (parent: DefaultTemplateGroupKey?, priority: Int, enabled: Bool) {
        switch key {
        case .root: (nil, 1, false)
        case .allowBlock: (.root, 1, true)
        case .filters: (.root, 2, true)
        case .mapTraffic: (.root, 3, true)
        case .mapLocalManual: (.mapTraffic, 1, false)
        case .mapLocalFile: (.mapTraffic, 2, false)
        case .modifyTraffic: (.root, 4, true)
        case .tooling: (.root, 5, true)
        case .uiMarks: (.root, 6, true)
        }
    }

    public static func build(
        groupName: (DefaultTemplateGroupKey) -> String, ruleName: (DefaultTemplateRuleKey) -> String
    ) -> DefaultTemplateSet {
        let groups = DefaultTemplateGroupKey.allCases.map { key -> RuleGroup in
            let place = placement(key)
            return RuleGroup(
                id: groupID(key), name: groupName(key), enabled: place.enabled,
                parentID: place.parent.map(groupID), order: place.priority - 1)
        }
        let rules = DefaultTemplateRuleKey.allCases
            .map { key -> (group: DefaultTemplateGroupKey, priority: Int, rule: Rule) in
                let spec = DefaultTemplateRules.spec(key)
                let rule = Rule(
                    id: ruleID(key), name: ruleName(key), enabled: spec.enabled, groupID: groupID(spec.group),
                    order: spec.priority - 1, conditions: spec.conditions, actions: spec.actions)
                return (spec.group, spec.priority, rule)
            }
            .sorted { ($0.group.rawValue, $0.priority) < ($1.group.rawValue, $1.priority) }
            .map(\.rule)
        let asset = DefaultTemplateAsset(
            placeholderID: exampleFilePlaceholderID, displayName: "example.dat",
            data: Data(DefaultTemplateRules.exampleFileText.utf8))
        return DefaultTemplateSet(
            version: currentVersion, rootGroupID: groupID(.root), groups: groups, rules: rules, assets: [asset])
    }
}
