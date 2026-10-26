import Foundation

/// `manifest.json` of a `.pwrules` pack. `schema` is the pack format, `rulesSchema` the rule model inside
/// `rules.json`.
public struct RulePackManifest: Codable, Sendable, Equatable {
    public static let format = "proxywoman-rules"
    public static let currentSchema = 1
    /// The rule model inside `rules.json` (equals `RuleStorage.currentSchema`, which is not public).
    public static let currentRulesSchema = 4

    public var format: String
    public var schema: Int
    public var rulesSchema: Int
    public var app: String
    public var appVersion: String
    public var exportedAt: String
    public var groupCount: Int
    public var ruleCount: Int
    public var assetCount: Int

    public init(
        format: String = RulePackManifest.format, schema: Int = RulePackManifest.currentSchema,
        rulesSchema: Int = RulePackManifest.currentRulesSchema, app: String = "ProxyWoman", appVersion: String,
        exportedAt: String, groupCount: Int, ruleCount: Int, assetCount: Int
    ) {
        self.format = format
        self.schema = schema
        self.rulesSchema = rulesSchema
        self.app = app
        self.appVersion = appVersion
        self.exportedAt = exportedAt
        self.groupCount = groupCount
        self.ruleCount = ruleCount
        self.assetCount = assetCount
    }
}

/// `rules.json` of a pack: only what the exported rules reference.
struct RulePackContent: Codable, Equatable {
    struct AssetRecord: Codable, Equatable {
        var id: UUID
        var displayName: String
        var size: Int64
    }

    var groups: [RuleGroup]
    var rules: [Rule]
    var assets: [AssetRecord]
}
