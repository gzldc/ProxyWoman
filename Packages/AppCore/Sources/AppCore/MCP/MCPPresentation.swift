import Foundation
import Localization
import MCPKit

/// The sentences the MCP settings page shows for what the server reports: why it did not start, and how a
/// recorded call ended. Every case has its own key, written out in full (no key is built from a case name).
/// The switches have no `default`, so a new case does not compile until it has a sentence.
public enum MCPPresentation {
    public static func failureText(
        _ failure: MCPSocketServer.StartFailure, appName: String, localizer: Localizer = L10n.localizer
    ) -> String {
        switch failure {
        case .pathTooLong: localizer.string("mcpPane.failure.pathTooLong")
        case .directoryUnsafe: localizer.string("mcpPane.failure.directoryUnsafe")
        case .directoryFailed(let code): localizer.format("mcpPane.failure.directoryFailed", arguments: [code])
        case .bindFailed(let code): localizer.format("mcpPane.failure.bindFailed", arguments: [code])
        case .tokenFailed: localizer.string("mcpPane.failure.tokenFailed")
        case .alreadyRunning: localizer.format("mcpPane.failure.alreadyRunning", arguments: [appName])
        case .handshakeFailed(let code): localizer.format("mcpPane.failure.handshakeFailed", arguments: [code])
        }
    }

    public static func outcomeText(_ outcome: MCPCallOutcome, localizer: Localizer = L10n.localizer) -> String {
        switch outcome {
        case .ok: localizer.string("mcp.outcome.ok")
        case .denied(let denial):
            switch denial {
            case .disabled: localizer.string("mcp.outcome.deniedDisabled")
            case .permission(let tool): localizer.format("mcp.outcome.deniedPermission", arguments: [tool])
            case .enablingNotAllowed: localizer.string("mcp.outcome.deniedEnabling")
            }
        case .invalidArguments: localizer.string("mcp.outcome.invalidArguments")
        case .failed(let code): localizer.format("mcp.outcome.failed", arguments: [code])
        }
    }
}
