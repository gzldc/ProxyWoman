import Foundation

/// The write tools the user can authorize one by one (spec D10). Raw values are the MCP tool names.
public enum MCPWriteTool: String, CaseIterable, Codable, Sendable {
    case createRule = "create_rule"
    case updateRule = "update_rule"
    case setRuleEnabled = "set_rule_enabled"
    case setRecording = "set_recording"
}

public struct MCPRedactionSettings: Codable, Equatable, Sendable {
    public static let maxExtraNames = 32
    public static let maxNameLength = 64

    /// Master switch; on by default (spec D13).
    public var enabled: Bool
    /// User-supplied names that are redacted in headers, query strings and JSON/form body fields.
    /// Always read through `normalizedExtraNames()`.
    public var extraNames: [String]

    public init(enabled: Bool = true, extraNames: [String] = []) {
        self.enabled = enabled
        self.extraNames = extraNames
    }

    private enum CodingKeys: String, CodingKey { case enabled, extraNames }

    public init(from decoder: Decoder) throws {
        self.init()
        guard let container = try? decoder.container(keyedBy: CodingKeys.self) else { return }
        if let value = try? container.decodeIfPresent(Bool.self, forKey: .enabled) { enabled = value }
        if let value = try? container.decodeIfPresent([String].self, forKey: .extraNames) { extraNames = value }
    }

    /// Trimmed, lowercased; empty, over-length and duplicate names dropped (first occurrence wins);
    /// at most `maxExtraNames` names.
    public func normalizedExtraNames() -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in extraNames {
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !name.isEmpty, name.count <= Self.maxNameLength, seen.insert(name).inserted else { continue }
            result.append(name)
            if result.count == Self.maxExtraNames { break }
        }
        return result
    }
}

public struct MCPSettings: Codable, Equatable, Sendable {
    public var enabled = false
    public var writeTools: Set<MCPWriteTool> = []
    public var allowEnablingRules = false
    public var redaction = MCPRedactionSettings()

    public init() {}

    private enum CodingKeys: String, CodingKey { case enabled, writeTools, allowEnablingRules, redaction }

    /// Decoding never fails: every key is optional, unknown write-tool strings are ignored and a value
    /// of the wrong type falls back to that key's default (spec D17).
    public init(from decoder: Decoder) throws {
        self.init()
        guard let container = try? decoder.container(keyedBy: CodingKeys.self) else { return }
        if let value = try? container.decodeIfPresent(Bool.self, forKey: .enabled) { enabled = value }
        if let value = try? container.decodeIfPresent(Bool.self, forKey: .allowEnablingRules) {
            allowEnablingRules = value
        }
        if let names = try? container.decodeIfPresent([LossyString].self, forKey: .writeTools) {
            writeTools = Set(names.compactMap { $0.value.flatMap(MCPWriteTool.init(rawValue:)) })
        }
        if let value = try? container.decodeIfPresent(MCPRedactionSettings.self, forKey: .redaction) {
            redaction = value
        }
    }

    /// Stable output (sorted tool names) so the stored value does not churn.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(writeTools.map(\.rawValue).sorted(), forKey: .writeTools)
        try container.encode(allowEnablingRules, forKey: .allowEnablingRules)
        try container.encode(redaction, forKey: .redaction)
    }
}

/// Decodes any element without throwing; non-strings become nil.
private struct LossyString: Decodable {
    let value: String?
    init(from decoder: Decoder) throws {
        value = try? decoder.singleValueContainer().decode(String.self)
    }
}
