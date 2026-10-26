import FlowStore
import Foundation
import Localization
import RulesEngine

/// Text for the traffic tools (Allow list, Block list, No Caching, Network Conditions).
public enum TrafficPresentation {
    /// Every key this file and `TrafficBadge` use; the localization tests check them in all languages.
    public static let messageKeys: [String] =
        NetworkPreset.allCases.map(presetKey)
        + errorCodes.map(errorKey)
        + [
            "traffic.badge.noCaching", "traffic.badge.noCaching.help",
            "traffic.badge.allowList", "traffic.badge.allowList.help",
            "traffic.badge.blockList", "traffic.badge.blockList.help",
            "traffic.badge.conditions", "traffic.badge.conditions.help",
            "traffic.profile.summary", "traffic.profile.summary.downloadUnlimited",
            "traffic.profile.summary.uploadUnlimited", "traffic.profile.summary.bothUnlimited",
            "traffic.conditions.hostRules",
            "traffic.provenance.blocked", "traffic.provenance.noCaching", "traffic.provenance.throttled",
            "traffic.provenance.customProfile",
        ]

    private static let errorCodes: [TrafficPolicyError.Code] = [
        .invalidHostPattern, .invalidPort, .invalidMethod, .invalidPath, .invalidScheme,
        .unsupportedField, .tooManyEntries, .invalidProfile, .duplicateID, .invalidPattern,
    ]

    private static func presetKey(_ preset: NetworkPreset) -> String {
        switch preset {
        case .offline: "traffic.preset.offline"
        case .veryBad: "traffic.preset.veryBad"
        case .slow: "traffic.preset.slow"
        case .medium: "traffic.preset.medium"
        case .edge: "traffic.preset.edge"
        case .threeG: "traffic.preset.threeG"
        case .lte: "traffic.preset.lte"
        case .wifi: "traffic.preset.wifi"
        case .wifiAC: "traffic.preset.wifiAC"
        }
    }
    private static func errorKey(_ code: TrafficPolicyError.Code) -> String {
        switch code {
        case .invalidHostPattern: "traffic.error.invalidHostPattern"
        case .invalidPort: "traffic.error.invalidPort"
        case .invalidMethod: "traffic.error.invalidMethod"
        case .invalidPath: "traffic.error.invalidPath"
        case .invalidScheme: "traffic.error.invalidScheme"
        case .unsupportedField: "traffic.error.unsupportedField"
        case .tooManyEntries: "traffic.error.tooManyEntries"
        case .invalidProfile: "traffic.error.invalidProfile"
        case .duplicateID: "traffic.error.duplicateID"
        case .invalidPattern: "traffic.error.invalidPattern"
        }
    }

    public static func title(of preset: NetworkPreset) -> String { L10n.string(presetKey(preset)) }

    /// For example "下行 780 kbps · 上行 300 kbps · 延迟 100 ms · 丢包 0%". Numbers stay numeric
    /// arguments; an unlimited direction uses its own sentence.
    public static func summary(of profile: NetworkProfile, localizer: Localizer = L10n.localizer) -> String {
        let key =
            switch (profile.downloadKbps, profile.uploadKbps) {
            case (nil, nil): "traffic.profile.summary.bothUnlimited"
            case (nil, _): "traffic.profile.summary.downloadUnlimited"
            case (_, nil): "traffic.profile.summary.uploadUnlimited"
            default: "traffic.profile.summary"
            }
        return localizer.format(
            key, arguments: [profile.downloadKbps ?? 0, profile.uploadKbps ?? 0, profile.latencyMs, profile.lossPercent])
    }

    public static func message(for error: TrafficPolicyError) -> String { L10n.string(errorKey(error.code)) }

    /// An entry's host as list text: the host (`*` when absent), with the syntax in brackets when it
    /// is a wildcard or regular expression.
    public static func hostTitle(of matcher: RuleMatcher, localizer: Localizer = L10n.localizer) -> String {
        tagged(matcher.hostPattern ?? "*", syntax: matcher.hostSyntax, localizer: localizer)
    }

    /// An entry's path as list text: "any", the prefix or exact text, or a pattern with its syntax tag.
    public static func pathTitle(of path: PathMatch, localizer: Localizer = L10n.localizer) -> String {
        switch path {
        case .any: localizer.string("traffic.field.any")
        case .prefix(let text), .exact(let text): text
        case .wildcard(let text): tagged(text, syntax: .wildcard, localizer: localizer)
        case .regex(let text): tagged(text, syntax: .regex, localizer: localizer)
        }
    }

    private static func tagged(_ text: String, syntax: PatternSyntax, localizer: Localizer) -> String {
        switch syntax {
        case .literal: text
        case .wildcard: localizer.format("rules.summary.withSyntax", arguments: [text, localizer.string("rules.summary.syntaxWildcard")])
        case .regex: localizer.format("rules.summary.withSyntax", arguments: [text, localizer.string("rules.summary.syntaxRegex")])
        }
    }

    /// The condition badge's label when only host rules are active.
    public static var hostRulesLabel: String { L10n.string("traffic.conditions.hostRules") }

    /// The flow detail's lines about what the traffic tools did to a flow, in a stable order: blocked by
    /// the list, no-caching applied, throttled (with the profile's name). A repeat run is not repeated
    /// here (the app column shows it). `networkCondition` is the machine tag `preset.<case>` / `custom`;
    /// a tag this version does not know is shown as recorded.
    public static func provenanceLines(for tools: TrafficToolsProvenance) -> [String] {
        var lines: [String] = []
        if tools.blockedByEntry != nil { lines.append(L10n.string("traffic.provenance.blocked")) }
        if tools.noCaching { lines.append(L10n.string("traffic.provenance.noCaching")) }
        if let tag = tools.networkCondition {
            let name: String
            if tag == "custom" {
                name = L10n.string("traffic.provenance.customProfile")
            } else if tag.hasPrefix("preset."), let preset = NetworkPreset(rawValue: String(tag.dropFirst("preset.".count))) {
                name = title(of: preset)
            } else {
                name = tag
            }
            lines.append(L10n.format("traffic.provenance.throttled", name))
        }
        return lines
    }

    /// A selection as short text: a preset's name, or the numbers of a custom profile.
    public static func label(of selection: NetworkSelection) -> String {
        switch selection {
        case .preset(let preset): title(of: preset)
        case .custom(let profile): summary(of: profile)
        }
    }
}

/// A status-bar marker for an active traffic tool.
public enum TrafficBadge: Equatable, Sendable, Identifiable {
    case noCaching
    case allowList(Int)
    case blockList(Int)
    case conditions(String)

    public var id: String {
        switch self {
        case .noCaching: "noCaching"
        case .allowList: "allowList"
        case .blockList: "blockList"
        case .conditions: "conditions"
        }
    }

    public var title: String {
        switch self {
        case .noCaching: L10n.string("traffic.badge.noCaching")
        case .allowList(let count): L10n.format("traffic.badge.allowList", count)
        case .blockList(let count): L10n.format("traffic.badge.blockList", count)
        case .conditions(let label): L10n.format("traffic.badge.conditions", label)
        }
    }

    public var help: String {
        switch self {
        case .noCaching: L10n.string("traffic.badge.noCaching.help")
        case .allowList: L10n.string("traffic.badge.allowList.help")
        case .blockList: L10n.string("traffic.badge.blockList.help")
        case .conditions: L10n.string("traffic.badge.conditions.help")
        }
    }
}
