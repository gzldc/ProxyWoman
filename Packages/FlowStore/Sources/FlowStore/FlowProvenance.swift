import Foundation

/// A stable machine code: ASCII letters and digits, starting with a letter, at most 64 characters.
/// Anything else (sentences, paths, empty text) is not representable, so it cannot leak into
/// provenance or exports. Decoding validates too.
public struct RuleOutcomeCode: Sendable, Equatable, Hashable, Codable, RawRepresentable {
    public let rawValue: String

    public init?(rawValue: String) {
        guard let first = rawValue.unicodeScalars.first, rawValue.unicodeScalars.count <= 64,
            first.isASCII, CharacterSet.letters.contains(first),
            rawValue.unicodeScalars.allSatisfy({ $0.isASCII && CharacterSet.alphanumerics.contains($0) })
        else { return nil }
        self.rawValue = rawValue
    }

    private init(unchecked value: String) { rawValue = value }

    public static let breakpointLengthCorrected = RuleOutcomeCode(unchecked: "breakpointLengthCorrected")
    public static let breakpointTrailersDropped = RuleOutcomeCode(unchecked: "breakpointTrailersDropped")
    public static let breakpointBodyIgnored = RuleOutcomeCode(unchecked: "breakpointBodyIgnored")
    public static let applied = RuleOutcomeCode(unchecked: "applied")
    /// The rule's edit failed validation; the exchange ended with a local `rule.rejected` failure.
    public static let rejected = RuleOutcomeCode(unchecked: "rejected")
    public static let unsupportedUpgradeAction = RuleOutcomeCode(unchecked: "unsupportedUpgradeAction")
    /// A CONNECT action that the block list, allow list or SSL decryption list had already decided.
    public static let skippedByTool = RuleOutcomeCode(unchecked: "skippedByTool")
    /// The delay actions added up to more than the limit and were cut to it.
    public static let delayCapped = RuleOutcomeCode(unchecked: "delayCapped")
    /// A header edit that looks fields up (append to value, find and replace, regex) found nothing to change.
    public static let editNoMatch = RuleOutcomeCode(unchecked: "editNoMatch")

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        guard let code = RuleOutcomeCode(rawValue: value) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "invalid outcome code"))
        }
        self = code
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Why a message looks the way it does. Bounded, and free of file paths and free-form text.
public struct RuleOutcome: Sendable, Equatable, Hashable, Codable {
    public var ruleID: UUID
    public var code: RuleOutcomeCode
    /// Which of the rule's actions the outcome is about (0-based). Set only for a rule with several
    /// actions and for the outcomes that always name an action; nil otherwise, so a single-action
    /// rule's outcome encodes exactly as before. Not encoded when nil; older records decode as nil.
    public var actionIndex: Int?

    public init(ruleID: UUID, code: RuleOutcomeCode, actionIndex: Int? = nil) {
        self.ruleID = ruleID
        self.code = code
        self.actionIndex = actionIndex
    }
}

public struct RuleMatchSummary: Sendable, Equatable, Hashable, Codable {
    public static let maxRecords = 256

    public var revision: UInt64
    public var ruleIDs: [UUID]
    /// Matches evaluated, including those that no longer fit in `ruleIDs` / `outcomes`.
    public var total: Int
    public var omitted: Int
    public var outcomes: [RuleOutcome]

    /// Keeps the first `maxRecords` entries of each list; the larger number of records cut from
    /// either list is added to `omitted` (rule ids and outcomes usually describe the same rules).
    public init(revision: UInt64, ruleIDs: [UUID], total: Int, omitted: Int = 0, outcomes: [RuleOutcome] = []) {
        self.revision = revision
        self.ruleIDs = Array(ruleIDs.prefix(Self.maxRecords))
        self.total = max(0, total)
        self.omitted = max(0, omitted) + max(0, max(ruleIDs.count, outcomes.count) - Self.maxRecords)
        self.outcomes = Array(outcomes.prefix(Self.maxRecords))
    }
}

extension RuleMatchSummary {
    /// Something to record: rules matched, or a rule left an outcome without matching (for example
    /// a regular expression that timed out).
    public var hasRecords: Bool { total > 0 || !outcomes.isEmpty }
}

/// A locally generated response is described by its managed asset (if any) and size only.
public struct GeneratedResponseSource: Sendable, Equatable, Hashable, Codable {
    public var assetID: UUID?
    public var size: UInt64?

    public init(assetID: UUID? = nil, size: UInt64? = nil) {
        self.assetID = assetID
        self.size = size
    }
}

/// Identifies one run of a repeat-send batch. `index` starts at 1 and counts up to `total`.
public struct RepeatRunTag: Sendable, Equatable, Hashable, Codable {
    public var runID: UUID
    public var index: Int
    public var total: Int

    public init(runID: UUID, index: Int, total: Int) {
        self.runID = runID
        self.index = index
        self.total = total
    }
}

/// Machine-readable marks left by traffic tools (blocklist, no-cache, network condition, repeat).
/// By convention `networkCondition` holds a machine tag such as `preset.threeG` or `custom`, never display text.
public struct TrafficToolsProvenance: Sendable, Equatable, Hashable, Codable {
    public var blockedByEntry: UUID?
    public var noCaching: Bool
    public var networkCondition: String?
    public var repeatRun: RepeatRunTag?

    public init(blockedByEntry: UUID? = nil, noCaching: Bool = false, networkCondition: String? = nil, repeatRun: RepeatRunTag? = nil) {
        self.blockedByEntry = blockedByEntry
        self.noCaching = noCaching
        self.networkCondition = networkCondition
        self.repeatRun = repeatRun
    }

    /// True when no traffic tool marked the flow.
    public var isEmpty: Bool {
        blockedByEntry == nil && !noCaching && networkCondition == nil && repeatRun == nil
    }

    /// Fields that are set (non-nil, or `true`) in `newer` replace ours; the rest of ours is kept.
    public func merging(_ newer: TrafficToolsProvenance) -> TrafficToolsProvenance {
        TrafficToolsProvenance(
            blockedByEntry: newer.blockedByEntry ?? blockedByEntry,
            noCaching: newer.noCaching || noCaching,
            networkCondition: newer.networkCondition ?? networkCondition,
            repeatRun: newer.repeatRun ?? repeatRun)
    }
}

public struct FlowProvenance: Sendable, Equatable {
    public enum Source: Sendable, Equatable {
        case passive
        case compose(sendID: UUID, sourceFlowID: Int?, sourceBoundary: HTTPMessageBoundary?)
    }

    public var source: Source
    /// False for flows recorded before boundary snapshots existed: nothing is claimed about them.
    public var isKnown: Bool
    public var ruleMatches: RuleMatchSummary?
    public var generatedResponse: GeneratedResponseSource?
    /// The published rules were deliberately not applied to this flow (a Compose send that did not
    /// switch them on), so no rule could have matched it.
    public var rulesDisabled: Bool
    /// Marks left by traffic tools; merged (not replaced) when recorded.
    public var tools: TrafficToolsProvenance
    /// A rule changed the exchange: a header, status, body, route or returned response was applied.
    /// Breakpoints do not count. Kept as a flag because `ruleMatches.outcomes` is bounded.
    public var rulesModified: Bool

    public init(
        source: Source = .passive, isKnown: Bool = true, ruleMatches: RuleMatchSummary? = nil,
        generatedResponse: GeneratedResponseSource? = nil, rulesDisabled: Bool = false,
        tools: TrafficToolsProvenance = .init(), rulesModified: Bool = false
    ) {
        self.source = source
        self.isKnown = isKnown
        self.ruleMatches = ruleMatches
        self.generatedResponse = generatedResponse
        self.rulesDisabled = rulesDisabled
        self.tools = tools
        self.rulesModified = rulesModified
    }

    /// Legacy flows and flows nobody described.
    public static let unknown = FlowProvenance(isKnown: false)
    public static let passive = FlowProvenance()

    public var isCompose: Bool {
        if case .compose = source { true } else { false }
    }

    public var isRepeat: Bool { tools.repeatRun != nil }
}
