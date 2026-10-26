/// Independent policy accounting; these limits are not an RSS bound.
public struct WebSocketLimits: Sendable, Equatable {
    public var decodedPrefixBytes = 1_048_576
    public var wirePrefixBytes = 65_536
    public var messageWireBytes = 16_777_216
    public var messageExpandedBytes = 4_194_304
    public var messageFrames = 4_096
    public var fragmentDescriptors = 64
    public var sessionEvents = 10_000
    public var sessionPayloadBytes = 8_388_608
    public var storeEvents = 100_000
    public var retainedBytes = 33_554_432
    public var observingSessions = 128
    public var sessionMailboxBytes = 262_144
    public var mailboxBytes = 8_388_608
    public var workingBytes = 8_388_608
    public var nativeBytes = 16_777_216
    public var metadataBytes = 16_777_216
    public var quantumBytes = 32_768
    public var quantumFrames = 64
    public var quantumNativeOperations = 64
    public var sessionFramesPerSecond = 4_096
    public var sessionExpandedPerSecond = 16_777_216
    public var storeExpandedPerSecond = 67_108_864
    public var sessionNativePerSecond = 4_096
    public var storeNativePerSecond = 16_384
    public var pageRows = 200
    public var readerPayloadBytes = 262_144
    public init() {}
}
