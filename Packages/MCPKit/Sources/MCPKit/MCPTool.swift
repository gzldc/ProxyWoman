import Foundation
import MCPWire

public struct MCPToolDefinition: Sendable {
    public enum Kind: Sendable, Equatable {
        case read
        case write(MCPWriteTool)
    }

    public var name: String
    public var title: String
    public var description: String
    public var inputSchema: JSONValue
    public var kind: Kind

    public init(name: String, title: String, description: String, inputSchema: JSONValue, kind: Kind) {
        self.name = name
        self.title = title
        self.description = description
        self.inputSchema = inputSchema
        self.kind = kind
    }
}

/// What a tool may look at besides its arguments: the settings snapshot that authorized this very call
/// (never a later one), the redactor built from it, and the clock.
public struct MCPToolContext: Sendable {
    public var settings: MCPSettings
    public var redactor: MCPRedactor
    public var now: Date

    public init(settings: MCPSettings, redactor: MCPRedactor, now: Date) {
        self.settings = settings
        self.redactor = redactor
        self.now = now
    }
}

/// A failure a tool reports to the AI client. `code` is one of: permission_denied, invalid_arguments,
/// not_found, busy, rule_invalid, rule_being_edited, rule_is_enabled, conflict, too_large, internal.
/// `message` and `extra` are shown to the AI client, so they must never carry internals.
public struct MCPToolError: Error, Sendable, Equatable {
    public var code: String
    public var message: String
    /// Extra members merged into the `error` object (for example `issues`).
    public var extra: JSONValue?

    public init(code: String, message: String, extra: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.extra = extra
    }

    public static func invalidArguments(_ message: String) -> Self {
        Self(code: "invalid_arguments", message: message)
    }

    public static func notFound(_ message: String) -> Self {
        Self(code: "not_found", message: message)
    }

    /// For the tool-level gate "AI may enable rules"; the runner has already checked the per-tool grant.
    public static func permissionDenied(_ message: String) -> Self {
        Self(code: "permission_denied", message: message)
    }
}

public protocol MCPTool: Sendable {
    var definition: MCPToolDefinition { get }
    func call(_ arguments: [String: JSONValue], context: MCPToolContext) async throws -> JSONValue
}

public struct MCPAppInfo: Sendable {
    public var name: String
    public var version: String

    public init(name: String, version: String) {
        self.name = name
        self.version = version
    }
}
