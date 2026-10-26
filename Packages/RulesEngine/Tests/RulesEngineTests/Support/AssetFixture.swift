import Foundation

@testable import RulesEngine

/// A managed asset store in a temporary directory holding one imported asset.
struct AssetFixture {
    var root: URL
    var store: ManagedAssetStore
    var budgets: OwnedFileBudgets
    var id: UUID

    static func make(_ data: Data, limits: RulesLimits = RulesLimits()) async throws -> AssetFixture {
        let root = makeTempDirectory()
        let budgets = OwnedFileBudgets(limits: limits, freeDiskBytes: ample)
        let store = ManagedAssetStore(directory: root.appendingPathComponent("assets"), limits: limits, budgets: budgets)
        let source = writeFile(root.appendingPathComponent("source.bin"), data)
        let asset = try await store.importFile(source, displayName: "source.bin")
        return AssetFixture(root: root, store: store, budgets: budgets, id: asset.id)
    }

    func remove() { removeTree(root) }
}
