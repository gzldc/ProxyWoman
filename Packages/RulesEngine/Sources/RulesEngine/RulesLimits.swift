import Foundation

/// Engineering capacities for rules, breakpoints and Compose. Injectable so tests can shrink them.
/// The byte and count fields beyond the first group are consumed by later tasks; they live here so
/// every owner reads one table.
public struct RulesLimits: Sendable, Equatable {
    public var configBytes: Int
    /// One configured text field (name, host pattern, path, header name or value), in UTF-8 bytes.
    public var fieldBytes: Int
    public var recordedMatches: Int
    public var ticketCount: Int
    public var ticketsPerContext: Int
    public var ticketSeconds: Int
    public var breakpointBodyBytes: Int
    public var breakpointSpoolBytes: Int
    public var editorBodyBytes: Int
    public var editorMemoryBytes: Int
    public var ioChunkBytes: Int
    public var ioBufferBytes: Int
    public var assetFileBytes: Int
    public var assetStoreBytes: Int
    public var composeBodyBytes: Int
    public var composeSpoolBytes: Int
    public var composeSends: Int
    public var minimumFreeDiskBytes: Int
    /// Header and trailer blocks: name + value + 32 bytes per field, as the transport counts them.
    public var headerBytes: Int
    public var headerFields: Int
    /// Cap on a body collected for automatic rewriting, both on the wire and after decoding.
    public var rewriteBodyBytes: Int
    /// How long collecting a body for rewriting may go without receiving a new chunk before the exchange fails (an idle deadline).
    public var rewriteSeconds: Int
    /// Overall safety cap on collecting one body for rewriting, however steadily bytes keep arriving, so a
    /// trickle of one byte just inside the idle deadline cannot hold the exchange forever.
    public var rewriteTotalSeconds: Int
    /// Actions in one rule.
    public var ruleActions: Int
    /// Condition rows in one rule.
    public var ruleConditionRows: Int
    /// Rules in one configuration; the cap only constrains growth, never an older, larger file.
    public var ruleCount: Int
    /// Levels of nested groups.
    public var groupDepth: Int
    /// Rule pairs one stored upgrade notice lists (about 125 bytes each); the rest are only counted.
    public var migrationNoticePairs: Int
    /// A rule mark's label, in UTF-8 bytes.
    public var markTextBytes: Int
    /// A comment action's text or replacement, in UTF-8 bytes.
    public var commentBytes: Int
    /// How much of a body a condition row reads (request or response), in bytes.
    public var conditionBodyBytes: Int
    /// Overall cap on collecting one body for conditions (the idle deadline is `rewriteSeconds`).
    public var conditionBodyTotalSeconds: Int
    /// A handwritten response's text, in UTF-8 bytes.
    public var handwrittenResponseBytes: Int
    /// All delay actions of one exchange added up, in milliseconds; the rest is cut off.
    public var delayMillisecondsMax: Int
    /// A rule pack file (.pwrules) as a whole, in bytes; checked before it is read.
    public var packFileBytes: Int
    /// All pack entries added up after decompression, in bytes.
    public var packExpandedBytes: Int
    /// One asset inside a pack, in bytes (stricter than `assetFileBytes`: it is held in memory).
    public var packAssetBytes: Int
    /// Entries in one pack archive.
    public var packEntries: Int
    /// The pack's manifest, in bytes.
    public var packManifestBytes: Int
    /// Groups in one pack.
    public var packGroups: Int

    public init(
        configBytes: Int = 8_388_608, fieldBytes: Int = 8_192, recordedMatches: Int = 256,
        ticketCount: Int = 64, ticketsPerContext: Int = 8, ticketSeconds: Int = 120,
        breakpointBodyBytes: Int = 52_428_800, breakpointSpoolBytes: Int = 268_435_456,
        editorBodyBytes: Int = 8_388_608, editorMemoryBytes: Int = 33_554_432,
        ioChunkBytes: Int = 65_536, ioBufferBytes: Int = 4_194_304,
        assetFileBytes: Int = 536_870_912, assetStoreBytes: Int = 2_147_483_648,
        composeBodyBytes: Int = 536_870_912, composeSpoolBytes: Int = 1_073_741_824, composeSends: Int = 10,
        minimumFreeDiskBytes: Int = 268_435_456, headerBytes: Int = 65_536, headerFields: Int = 256,
        rewriteBodyBytes: Int = 8_388_608, rewriteSeconds: Int = 30, rewriteTotalSeconds: Int = 600,
        ruleActions: Int = 16, ruleConditionRows: Int = 32, ruleCount: Int = 500, groupDepth: Int = 3,
        migrationNoticePairs: Int = 2_000, markTextBytes: Int = 256, commentBytes: Int = 4_096,
        conditionBodyBytes: Int = 1_048_576, conditionBodyTotalSeconds: Int = 60,
        handwrittenResponseBytes: Int = 65_536, delayMillisecondsMax: Int = 60_000,
        packFileBytes: Int = 134_217_728, packExpandedBytes: Int = 268_435_456,
        packAssetBytes: Int = 67_108_864, packEntries: Int = 600, packManifestBytes: Int = 65_536,
        packGroups: Int = 500
    ) {
        self.configBytes = configBytes
        self.fieldBytes = fieldBytes
        self.recordedMatches = recordedMatches
        self.ticketCount = ticketCount
        self.ticketsPerContext = ticketsPerContext
        self.ticketSeconds = ticketSeconds
        self.breakpointBodyBytes = breakpointBodyBytes
        self.breakpointSpoolBytes = breakpointSpoolBytes
        self.editorBodyBytes = editorBodyBytes
        self.editorMemoryBytes = editorMemoryBytes
        self.ioChunkBytes = ioChunkBytes
        self.ioBufferBytes = ioBufferBytes
        self.assetFileBytes = assetFileBytes
        self.assetStoreBytes = assetStoreBytes
        self.composeBodyBytes = composeBodyBytes
        self.composeSpoolBytes = composeSpoolBytes
        self.composeSends = composeSends
        self.minimumFreeDiskBytes = minimumFreeDiskBytes
        self.headerBytes = headerBytes
        self.headerFields = headerFields
        self.rewriteBodyBytes = rewriteBodyBytes
        self.rewriteSeconds = rewriteSeconds
        self.rewriteTotalSeconds = rewriteTotalSeconds
        self.ruleActions = ruleActions
        self.ruleConditionRows = ruleConditionRows
        self.ruleCount = ruleCount
        self.groupDepth = groupDepth
        self.migrationNoticePairs = migrationNoticePairs
        self.markTextBytes = markTextBytes
        self.commentBytes = commentBytes
        self.conditionBodyBytes = conditionBodyBytes
        self.conditionBodyTotalSeconds = conditionBodyTotalSeconds
        self.handwrittenResponseBytes = handwrittenResponseBytes
        self.delayMillisecondsMax = delayMillisecondsMax
        self.packFileBytes = packFileBytes
        self.packExpandedBytes = packExpandedBytes
        self.packAssetBytes = packAssetBytes
        self.packEntries = packEntries
        self.packManifestBytes = packManifestBytes
        self.packGroups = packGroups
    }
}
