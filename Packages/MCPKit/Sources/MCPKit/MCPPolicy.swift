import Foundation
import os

/// Lock-protected snapshot of the current MCP settings, shared by the socket server, the tools and the
/// settings UI. Readers always see a complete `MCPSettings` value.
public final class MCPPolicyProvider: Sendable {
    private let state: OSAllocatedUnfairLock<MCPSettings>

    public init(_ initial: MCPSettings = MCPSettings()) {
        state = OSAllocatedUnfairLock(initialState: initial)
    }

    public var current: MCPSettings { state.withLock { $0 } }

    public func update(_ settings: MCPSettings) {
        state.withLock { $0 = settings }
    }
}
