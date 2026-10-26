import Foundation
import RulesEngine

/// The pack operations the importer and the model use, as closures so tests need no disk. Every closure
/// is free to run off the main actor; the live ones do all file and zip work on a background task and stop
/// when the calling task is cancelled.
public struct RulePackClient: Sendable {
    /// Checks the file size, then inspects the pack (nothing is written anywhere). Throws `RulePackError`.
    public var read: @Sendable (URL) async throws -> RulePackPreview
    public var export: @Sendable (Set<UUID>?, [RuleGroup], [Rule]) async throws -> RulePackExport
    /// Writes atomically: a reader never sees a half-written pack.
    public var write: @Sendable (Data, URL) async throws -> Void

    public init(
        read: @escaping @Sendable (URL) async throws -> RulePackPreview,
        export: @escaping @Sendable (Set<UUID>?, [RuleGroup], [Rule]) async throws -> RulePackExport,
        write: @escaping @Sendable (Data, URL) async throws -> Void
    ) {
        self.read = read
        self.export = export
        self.write = write
    }

    public static func live(assets: ManagedAssetStore, limits: RulesLimits, appVersion: String) -> Self {
        Self(
            read: { url in
                try await background {
                    do {
                        return try RulePackReader.inspect(fileAt: url, limits: limits)
                    } catch let error as RulePackError {
                        throw error
                    } catch {
                        throw RulePackError.readFailed
                    }
                }
            },
            export: { selection, groups, rules in
                try await RulePackExporter.export(
                    groups: groups, rules: rules, selection: selection, assets: assets, limits: limits,
                    appVersion: appVersion, now: Date())
            },
            write: { data, url in
                try await background { try data.write(to: url, options: .atomic) }
            })
    }

    /// Runs `work` on a detached background task that is cancelled with the caller.
    private static func background<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try work()
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}
