import AppCore
import Foundation
import RulesEngine

/// Compose body files over the proxy's managed asset store: the chosen file is copied once into the
/// private asset directory and the service streams the request body from that copy.
struct ManagedComposeFiles: ComposeBodyFiles {
    let store: ManagedAssetStore

    func importFile(_ url: URL, displayName: String) async throws -> ComposeBodyFile {
        let asset = try await store.importFile(url, displayName: displayName)
        return ComposeBodyFile(assetID: asset.id, displayName: asset.displayName, size: asset.size)
    }

    func importStream(
        expectedSize: Int64, displayName: String,
        read: @escaping @Sendable (Int64, Int) async throws -> Data
    ) async throws -> ComposeBodyFile {
        let asset = try await store.importStream(expectedSize: expectedSize, displayName: displayName, read: read)
        return ComposeBodyFile(assetID: asset.id, displayName: asset.displayName, size: asset.size)
    }

    func discard(_ ids: Set<UUID>) async {
        await store.discardImports(ids)
    }
}
