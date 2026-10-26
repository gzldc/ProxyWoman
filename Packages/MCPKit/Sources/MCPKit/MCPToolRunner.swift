import Foundation
import MCPWire

/// The single choke point for tool calls (spec S3). Every call re-reads the current settings snapshot
/// and checks it before any tool handler runs; nothing is cached between calls.
public final class MCPToolRunner: Sendable {
    public static let maxResultBytes = 256 * 1024
    static let auditArgumentLimit = 160
    static let auditToolNameLimit = 64
    static let disabledWritePrefix = "[Write tool — currently disabled in ProxyWoman Settings] "

    /// A tool together with the definition read from it exactly once, at init. Listing and enforcement
    /// both use this copy, so a tool can never be listed as one thing and checked as another.
    private struct Entry: Sendable {
        let tool: any MCPTool
        let definition: MCPToolDefinition
    }

    static let maxErrorMessageScalars = 512
    static let maxErrorExtraBytes = 8 * 1024
    static let maxErrorCodeScalars = 64

    private let tools: [String: Entry]
    private let order: [String]
    private let policy: MCPPolicyProvider
    private let audit: MCPAuditLog
    private let now: @Sendable () -> Date

    public init(
        tools: [any MCPTool], policy: MCPPolicyProvider, audit: MCPAuditLog,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        let entries = tools.map { Entry(tool: $0, definition: $0.definition) }
        // A wrong name/kind pairing would let a write tool run on the strength of another permission (or
        // none). The tool set is fixed at build time, so this is a programming error, not a runtime state.
        let problems = Self.definitionProblems(entries.map(\.definition))
        precondition(problems.isEmpty, "MCP tool set is inconsistent: \(problems.joined(separator: "; "))")
        var byName: [String: Entry] = [:]
        var order: [String] = []
        for entry in entries {
            byName[entry.definition.name] = entry
            order.append(entry.definition.name)
        }
        self.tools = byName
        self.order = order
        self.policy = policy
        self.audit = audit
        self.now = now
    }

    /// What is wrong with a set of tool definitions: a `.write(p)` tool whose name is not `p.rawValue`, a
    /// `.read` tool named like a write tool, or a repeated name. Empty means consistent.
    static func definitionProblems(_ definitions: [MCPToolDefinition]) -> [String] {
        var problems: [String] = []
        var seen = Set<String>()
        for definition in definitions {
            let name = definition.name
            if !seen.insert(name).inserted { problems.append("duplicate tool name \(name)") }
            switch definition.kind {
            case .write(let permission):
                if name != permission.rawValue {
                    problems.append("write tool \(name) must be named \(permission.rawValue)")
                }
            case .read:
                if MCPWriteTool(rawValue: name) != nil { problems.append("read tool \(name) is named like a write tool") }
            }
        }
        return problems
    }

    // MARK: tools/list

    public func listTools() -> [JSONValue] {
        let settings = policy.current
        return order.compactMap { name in
            tools[name].map { Self.toolObject($0.definition, settings: settings) }
        }
    }

    private static func toolObject(_ definition: MCPToolDefinition, settings: MCPSettings) -> JSONValue {
        var description = definition.description
        let annotations: JSONValue
        switch definition.kind {
        case .read:
            annotations = .object(["readOnlyHint": .bool(true), "openWorldHint": .bool(false)])
        case .write(let permission):
            if !settings.writeTools.contains(permission) { description = disabledWritePrefix + description }
            annotations = .object([
                "readOnlyHint": .bool(false), "destructiveHint": .bool(false), "openWorldHint": .bool(false),
            ])
        }
        return .object([
            "name": .string(definition.name),
            "title": .string(definition.title),
            "description": .string(description),
            "inputSchema": definition.inputSchema,
            "annotations": annotations,
        ])
    }

    // MARK: tools/call

    /// Returns the MCP CallToolResult: `{content:[{type:"text",text}], isError}`.
    public func call(name: String, arguments: JSONValue?, client: String?) async -> JSONValue {
        let started = ContinuousClock.now
        // One snapshot per call: it authorizes the call and is what the tool sees.
        let settings = policy.current
        let redactor = MCPRedactor(settings.redaction)
        let callTime = now()

        let argumentObject: [String: JSONValue]?
        switch arguments {
        case nil, .some(.null): argumentObject = [:]
        case .some(.object(let members)): argumentObject = members
        default: argumentObject = nil
        }

        let result: JSONValue
        let outcome: MCPCallOutcome
        if !settings.enabled {
            (result, outcome) = (
                Self.errorResult(code: "permission_denied", message: "MCP is switched off in ProxyWoman Settings."),
                .denied(.disabled)
            )
        } else if let entry = tools[name] {
            let tool = entry.tool
            let permitted: Bool
            switch entry.definition.kind {
            case .read: permitted = true
            case .write(let permission): permitted = settings.writeTools.contains(permission)
            }
            if !permitted {
                (result, outcome) = (
                    Self.errorResult(
                        code: "permission_denied",
                        message:
                            "The tool \(name) is a write tool and the user has not allowed it. They can turn it on in ProxyWoman Settings > MCP."
                    ),
                    .denied(.permission(tool: name))
                )
            } else if let argumentObject {
                let context = MCPToolContext(settings: settings, redactor: redactor, now: callTime)
                (result, outcome) = await run(tool, argumentObject, context)
            } else {
                (result, outcome) = (
                    Self.errorResult(code: "invalid_arguments", message: "arguments must be an object."),
                    .invalidArguments
                )
            }
        } else {
            (result, outcome) = (
                Self.errorResult(code: "not_found", message: "Unknown tool."), .failed(code: "not_found")
            )
        }

        let elapsed = started.duration(to: .now)
        let milliseconds = Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
        audit.record(
            MCPAuditEntry(
                at: callTime, client: client, tool: String(name.prefix(Self.auditToolNameLimit)),
                arguments: redactor.summary(Self.argumentText(arguments), limit: Self.auditArgumentLimit),
                outcome: outcome, durationMs: max(0, milliseconds)))
        return result
    }

    private func run(
        _ tool: any MCPTool, _ arguments: [String: JSONValue], _ context: MCPToolContext
    ) async -> (JSONValue, MCPCallOutcome) {
        do {
            let value = try await tool.call(arguments, context: context)
            guard let data = try? value.encoded(), let text = String(data: data, encoding: .utf8) else {
                return (Self.errorResult(code: "internal", message: "Internal error"), .failed(code: "internal"))
            }
            if data.count > Self.maxResultBytes {
                return (
                    Self.errorResult(
                        code: "too_large",
                        message:
                            "The result is larger than \(Self.maxResultBytes / 1024) KiB. Narrow the request (smaller limit, fewer ids, or exclude bodies)."
                    ),
                    .failed(code: "too_large")
                )
            }
            return (Self.result(text: text, isError: false), .ok)
        } catch let error as MCPToolError {
            let outcome: MCPCallOutcome
            switch error.code {
            case "permission_denied": outcome = .denied(.enablingNotAllowed)
            case "invalid_arguments": outcome = .invalidArguments
            default: outcome = .failed(code: error.code)
            }
            return (Self.errorResult(code: error.code, message: error.message, extra: error.extra), outcome)
        } catch {
            // Never leak the underlying error to the AI client.
            return (Self.errorResult(code: "internal", message: "Internal error"), .failed(code: "internal"))
        }
    }

    // MARK: Result encoding

    private static func result(text: String, isError: Bool) -> JSONValue {
        .object([
            "content": .array([.object(["type": .string("text"), "text": .string(text)])]),
            "isError": .bool(isError),
        ])
    }

    /// Everything in an error is capped here, whichever tool produced it: the code, the message (by
    /// Unicode scalars, so one huge grapheme cluster cannot slip through) and the serialized `extra`.
    /// An `extra` over the cap is dropped and `extraDropped: true` says so.
    private static func errorResult(code: String, message: String, extra: JSONValue? = nil) -> JSONValue {
        var body: [String: JSONValue] = [:]
        var extraDropped = false
        if let extra {
            if let encoded = try? extra.encoded(), encoded.count <= maxErrorExtraBytes {
                if case .object(let members) = extra { body = members } else { body["extra"] = extra }
            } else {
                extraDropped = true
            }
        }
        if extraDropped { body["extraDropped"] = .bool(true) }
        body["code"] = .string(capScalars(code, maxErrorCodeScalars))
        body["message"] = .string(capScalars(message, maxErrorMessageScalars))
        let text =
            (try? JSONValue.object(["error": .object(body)]).encoded()).flatMap { String(data: $0, encoding: .utf8) }
            ?? #"{"error":{"code":"internal","message":"Internal error"}}"#
        return result(text: text, isError: true)
    }

    private static func capScalars(_ text: String, _ limit: Int) -> String {
        let scalars = text.unicodeScalars
        guard scalars.count > limit else { return text }
        return String(String.UnicodeScalarView(scalars.prefix(limit - 1))) + "…"
    }

    private static func argumentText(_ arguments: JSONValue?) -> String {
        guard let arguments, let data = try? arguments.encoded(), let text = String(data: data, encoding: .utf8)
        else { return "{}" }
        return text
    }
}
