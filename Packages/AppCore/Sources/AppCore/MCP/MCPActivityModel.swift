import Foundation
import MCPKit
import Observation

/// The recent MCP calls for the settings page, following the in-memory audit log (spec D16).
@MainActor @Observable public final class MCPActivityModel {
    /// Newest first.
    public private(set) var entries: [MCPAuditEntry]
    @ObservationIgnored private let log: MCPAuditLog

    public init(log: MCPAuditLog) {
        self.log = log
        entries = log.snapshot()
    }

    /// Follows the log until the calling task is cancelled (run it from the page's `.task`). The subscription
    /// is made before the first read, so a call recorded in between is never missed.
    public func start() async {
        let changes = log.changes()
        entries = log.snapshot()
        for await _ in changes {
            entries = log.snapshot()
        }
    }

    /// Empties the log (and so every model following it).
    public func clear() {
        log.clear()
        entries = log.snapshot()
    }
}
