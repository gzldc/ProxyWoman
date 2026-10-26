import Foundation
import Localization

/// A file the Compose window sends as the request body: a private copy kept by the proxy's managed
/// asset store and streamed from there when the request goes out. Only this description is held;
/// the bytes are never in memory and no user path is kept.
public struct ComposeBodyFile: Sendable, Equatable, Hashable {
    public var assetID: UUID
    public var displayName: String
    public var size: Int64

    public init(assetID: UUID, displayName: String, size: Int64) {
        self.assetID = assetID
        self.displayName = displayName
        self.size = size
    }

    /// "name (size)" as the body editor shows it.
    public var summary: String {
        L10n.format("compose.body.file.summary", displayName, Formatting.size(Int(clamping: size)))
    }
}

/// The Foundation-only facade over the managed copy of a Compose body file. `importFile` runs inside
/// the caller's security scope; `importStream` copies bytes the caller reads in bounded chunks
/// (`read(offset, maxBytes)`, at most 64 KiB each, empty only at the end); `discard` drops copies
/// the window imported and no longer needs.
public protocol ComposeBodyFiles: Sendable {
    func importFile(_ url: URL, displayName: String) async throws -> ComposeBodyFile
    func importStream(
        expectedSize: Int64, displayName: String,
        read: @escaping @Sendable (_ offset: Int64, _ maxBytes: Int) async throws -> Data
    ) async throws -> ComposeBodyFile
    func discard(_ ids: Set<UUID>) async
}
