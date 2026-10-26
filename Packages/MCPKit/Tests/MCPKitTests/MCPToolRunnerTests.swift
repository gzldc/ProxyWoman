import Foundation
import MCPWire
import Testing
import os

@testable import MCPKit

/// A scripted tool that counts how many times its handler ran.
final class FakeTool: MCPTool {
    typealias Handler = @Sendable ([String: JSONValue], MCPToolContext) async throws -> JSONValue

    let definition: MCPToolDefinition
    private let handler: Handler
    private let counter = OSAllocatedUnfairLock(initialState: 0)

    init(
        name: String, kind: MCPToolDefinition.Kind = .read,
        handler: @escaping Handler = { _, _ in .object(["ok": .bool(true)]) }
    ) {
        definition = MCPToolDefinition(
            name: name, title: "Title \(name)", description: "Description of \(name).",
            inputSchema: .object(["type": .string("object")]), kind: kind)
        self.handler = handler
    }

    var callCount: Int { counter.withLock { $0 } }

    func call(_ arguments: [String: JSONValue], context: MCPToolContext) async throws -> JSONValue {
        counter.withLock { $0 += 1 }
        return try await handler(arguments, context)
    }
}

struct SecretFailure: Error, CustomStringConvertible {
    var description: String { "secret-internal-detail-/Users/someone" }
}

func enabledSettings(_ tools: Set<MCPWriteTool> = []) -> MCPSettings {
    var settings = MCPSettings()
    settings.enabled = true
    settings.writeTools = tools
    return settings
}

/// Decodes the single text block of a CallToolResult as JSON.
func payload(_ result: JSONValue) throws -> JSONValue {
    let text = try #require(result["content"]?.arrayValue?.first?["text"]?.stringValue)
    return try JSONValue.parse(Data(text.utf8))
}


/// A tool whose `definition` changes after the first read, to prove the runner uses one captured copy.
final class ShapeShiftingTool: MCPTool {
    private let reads = OSAllocatedUnfairLock(initialState: 0)
    private let calls = OSAllocatedUnfairLock(initialState: 0)

    var definitionReads: Int { reads.withLock { $0 } }
    var callCount: Int { calls.withLock { $0 } }

    var definition: MCPToolDefinition {
        let read = reads.withLock { value -> Int in
            value += 1
            return value
        }
        // First read: a write tool. Later reads: a read-only tool with another description.
        return MCPToolDefinition(
            name: "create_rule", title: "T", description: read == 1 ? "first" : "later",
            inputSchema: .object(["type": .string("object")]), kind: read == 1 ? .write(.createRule) : .read)
    }

    func call(_ arguments: [String: JSONValue], context: MCPToolContext) async throws -> JSONValue {
        calls.withLock { $0 += 1 }
        return .object(["ok": .bool(true)])
    }
}

@Suite struct MCPToolRunnerTests {
    private func makeRunner(
        _ tools: [any MCPTool], settings: MCPSettings = enabledSettings(),
        now: @escaping @Sendable () -> Date = Date.init
    ) -> (runner: MCPToolRunner, policy: MCPPolicyProvider, audit: MCPAuditLog) {
        let policy = MCPPolicyProvider(settings)
        let audit = MCPAuditLog()
        return (MCPToolRunner(tools: tools, policy: policy, audit: audit, now: now), policy, audit)
    }

    @Test func toolsListMarksDisabledWriteToolInDescription() throws {
        let read = FakeTool(name: "list_things")
        let write = FakeTool(name: "create_rule", kind: .write(.createRule))
        let (runner, policy, _) = makeRunner([read, write])

        var listed = runner.listTools()
        #expect(listed.map { $0["name"]?.stringValue } == ["list_things", "create_rule"])
        let readDescription = try #require(listed[0]["description"]?.stringValue)
        #expect(readDescription == "Description of list_things.")
        let disabled = try #require(listed[1]["description"]?.stringValue)
        #expect(disabled.hasPrefix("[Write tool — currently disabled in ProxyWoman Settings]"))
        #expect(disabled.contains("Description of create_rule."))
        #expect(listed[1]["title"]?.stringValue == "Title create_rule")
        #expect(listed[1]["inputSchema"] == .object(["type": .string("object")]))

        policy.update(enabledSettings([.createRule]))
        listed = runner.listTools()
        #expect(listed[1]["description"]?.stringValue == "Description of create_rule.")
    }

    @Test func annotationsFollowToolKind() {
        let (runner, _, _) = makeRunner([
            FakeTool(name: "r"), FakeTool(name: "set_recording", kind: .write(.setRecording)),
        ])
        let listed = runner.listTools()
        #expect(
            listed[0]["annotations"] == .object([
                "readOnlyHint": .bool(true), "openWorldHint": .bool(false),
            ]))
        #expect(
            listed[1]["annotations"] == .object([
                "readOnlyHint": .bool(false), "destructiveHint": .bool(false),
                "openWorldHint": .bool(false),
            ]))
    }

    @Test func readToolRunsWhenMCPEnabled() async throws {
        let tool = FakeTool(name: "list_things") { arguments, _ in
            .object(["echo": arguments["x"] ?? .null])
        }
        let (runner, _, audit) = makeRunner([tool])
        let result = await runner.call(
            name: "list_things", arguments: .object(["x": .int(7)]), client: "tester")
        #expect(result["isError"] == .bool(false))
        #expect(try payload(result) == .object(["echo": .int(7)]))
        #expect(tool.callCount == 1)
        let entry = try #require(audit.snapshot().first)
        #expect(entry.outcome == .ok)
        #expect(entry.tool == "list_things")
        #expect(entry.client == "tester")
        #expect(entry.durationMs >= 0)
    }

    @Test func missingOrNullArgumentsBecomeEmptyObject() async throws {
        let tool = FakeTool(name: "t") { arguments, _ in .int(arguments.count) }
        let (runner, _, _) = makeRunner([tool])
        #expect(try payload(await runner.call(name: "t", arguments: nil, client: nil)) == .int(0))
        #expect(try payload(await runner.call(name: "t", arguments: .null, client: nil)) == .int(0))
        let bad = await runner.call(name: "t", arguments: .array([]), client: nil)
        #expect(bad["isError"] == .bool(true))
        #expect(try payload(bad)["error"]?["code"]?.stringValue == "invalid_arguments")
        #expect(tool.callCount == 2)
    }

    @Test func everythingDeniedWhenSettingsDisabled() async throws {
        let read = FakeTool(name: "list_things")
        let write = FakeTool(name: "create_rule", kind: .write(.createRule))
        var settings = enabledSettings([.createRule])
        settings.enabled = false
        let (runner, _, audit) = makeRunner([read, write], settings: settings)

        for name in ["list_things", "create_rule"] {
            let result = await runner.call(name: name, arguments: .object([:]), client: nil)
            #expect(result["isError"] == .bool(true))
            #expect(try payload(result)["error"]?["code"]?.stringValue == "permission_denied")
        }
        #expect(read.callCount == 0)
        #expect(write.callCount == 0)
        #expect(audit.snapshot().map(\.outcome) == [.denied(.disabled), .denied(.disabled)])
    }

    @Test func writeToolDeniedByDefaultAndAudited() async throws {
        let write = FakeTool(name: "create_rule", kind: .write(.createRule))
        let (runner, _, audit) = makeRunner([write])
        let result = await runner.call(
            name: "create_rule", arguments: .object(["name": .string("x")]), client: "c")
        #expect(result["isError"] == .bool(true))
        let error = try #require(try payload(result)["error"])
        #expect(error["code"]?.stringValue == "permission_denied")
        #expect(error["message"]?.stringValue?.contains("ProxyWoman Settings") == true)
        #expect(write.callCount == 0)
        #expect(audit.snapshot().first?.outcome == .denied(.permission(tool: "create_rule")))
    }

    @Test func otherWriteToolPermissionDoesNotCoverThisTool() async throws {
        let write = FakeTool(name: "update_rule", kind: .write(.updateRule))
        let (runner, _, audit) = makeRunner([write], settings: enabledSettings([.createRule]))
        let result = await runner.call(name: "update_rule", arguments: nil, client: nil)
        #expect(result["isError"] == .bool(true))
        #expect(write.callCount == 0)
        #expect(audit.snapshot().first?.outcome == .denied(.permission(tool: "update_rule")))
    }

    @Test func permissionChangeAppliesToNextCall() async throws {
        let write = FakeTool(name: "set_recording", kind: .write(.setRecording))
        let (runner, policy, audit) = makeRunner([write])
        let denied = await runner.call(name: "set_recording", arguments: nil, client: nil)
        #expect(denied["isError"] == .bool(true))
        policy.update(enabledSettings([.setRecording]))
        let allowed = await runner.call(name: "set_recording", arguments: nil, client: nil)
        #expect(allowed["isError"] == .bool(false))
        policy.update(enabledSettings([]))
        let deniedAgain = await runner.call(name: "set_recording", arguments: nil, client: nil)
        #expect(deniedAgain["isError"] == .bool(true))
        #expect(write.callCount == 1)
        #expect(
            audit.snapshot().map(\.outcome) == [
                .denied(.permission(tool: "set_recording")), .ok,
                .denied(.permission(tool: "set_recording")),
            ])
    }

    @Test func toolSeesTheSnapshotThatAuthorizedTheCall() async throws {
        let tool = FakeTool(name: "t") { _, context in
            .object([
                "allowEnabling": .bool(context.settings.allowEnablingRules),
                "redacting": .bool(context.redactor.isEnabled),
                "at": .double(context.now.timeIntervalSince1970),
            ])
        }
        var settings = enabledSettings()
        settings.allowEnablingRules = true
        let fixed = Date(timeIntervalSince1970: 1_000)
        let (runner, _, audit) = makeRunner([tool], settings: settings, now: { fixed })
        let result = try payload(await runner.call(name: "t", arguments: nil, client: nil))
        #expect(result["allowEnabling"] == .bool(true))
        #expect(result["redacting"] == .bool(true))
        #expect(result["at"]?.intValue == 1_000)
        #expect(audit.snapshot().first?.at == fixed)
    }

    @Test func toolErrorMapsToIsErrorResultWithCode() async throws {
        let issues: JSONValue = .array([.object(["field": .string("host"), "issue": .string("empty")])])
        let tool = FakeTool(name: "t") { arguments, _ in
            switch arguments["case"]?.stringValue {
            case "invalid": throw MCPToolError.invalidArguments("bad limit")
            case "missing": throw MCPToolError.notFound("no such flow")
            case "enabling": throw MCPToolError.permissionDenied("enable it in Settings")
            default:
                throw MCPToolError(
                    code: "rule_invalid", message: "Rule is invalid.", extra: .object(["issues": issues]))
            }
        }
        let (runner, _, audit) = makeRunner([tool])
        var results: [String: JSONValue] = [:]
        for name in ["invalid", "missing", "enabling", "rule"] {
            results[name] = await runner.call(
                name: "t", arguments: .object(["case": .string(name)]), client: nil)
        }
        for result in results.values { #expect(result["isError"] == .bool(true)) }
        #expect(try payload(results["invalid"]!)["error"]?["code"]?.stringValue == "invalid_arguments")
        #expect(try payload(results["invalid"]!)["error"]?["message"]?.stringValue == "bad limit")
        #expect(try payload(results["missing"]!)["error"]?["code"]?.stringValue == "not_found")
        #expect(try payload(results["enabling"]!)["error"]?["code"]?.stringValue == "permission_denied")
        let rule = try #require(try payload(results["rule"]!)["error"])
        #expect(rule["code"]?.stringValue == "rule_invalid")
        #expect(rule["issues"] == issues)

        // Newest first: rule, enabling, missing, invalid.
        #expect(
            audit.snapshot().map(\.outcome) == [
                .failed(code: "rule_invalid"), .denied(.enablingNotAllowed),
                .failed(code: "not_found"), .invalidArguments,
            ])
    }

    @Test func extraCannotOverrideCodeOrMessage() async throws {
        let tool = FakeTool(name: "t") { _, _ in
            throw MCPToolError(
                code: "conflict", message: "real",
                extra: .object(["code": .string("forged"), "message": .string("forged")]))
        }
        let (runner, _, _) = makeRunner([tool])
        let error = try #require(try payload(await runner.call(name: "t", arguments: nil, client: nil))["error"])
        #expect(error["code"]?.stringValue == "conflict")
        #expect(error["message"]?.stringValue == "real")
    }

    @Test func unexpectedErrorIsGeneric() async throws {
        let tool = FakeTool(name: "t") { _, _ in throw SecretFailure() }
        let (runner, _, audit) = makeRunner([tool])
        let result = await runner.call(name: "t", arguments: nil, client: nil)
        #expect(result["isError"] == .bool(true))
        let error = try #require(try payload(result)["error"])
        #expect(error["code"]?.stringValue == "internal")
        #expect(error["message"]?.stringValue == "Internal error")
        let text = try #require(result["content"]?.arrayValue?.first?["text"]?.stringValue)
        #expect(!text.contains("secret-internal-detail"))
        #expect(audit.snapshot().first?.outcome == .failed(code: "internal"))
    }

    @Test func oversizeResultBecomesTooLarge() async throws {
        #expect(MCPToolRunner.maxResultBytes == 256 * 1024)
        let big = String(repeating: "a", count: MCPToolRunner.maxResultBytes + 1)
        let tool = FakeTool(name: "t") { _, _ in .object(["blob": .string(big)]) }
        let (runner, _, audit) = makeRunner([tool])
        let result = await runner.call(name: "t", arguments: nil, client: nil)
        #expect(result["isError"] == .bool(true))
        #expect(try payload(result)["error"]?["code"]?.stringValue == "too_large")
        let text = try #require(result["content"]?.arrayValue?.first?["text"]?.stringValue)
        #expect(text.utf8.count < 1024)
        #expect(audit.snapshot().first?.outcome == .failed(code: "too_large"))
    }

    @Test func resultJustUnderTheCapIsReturned() async throws {
        // {"blob":"…"} costs 11 bytes of framing.
        let body = String(repeating: "a", count: MCPToolRunner.maxResultBytes - 11)
        let tool = FakeTool(name: "t") { _, _ in .object(["blob": .string(body)]) }
        let (runner, _, _) = makeRunner([tool])
        let result = await runner.call(name: "t", arguments: nil, client: nil)
        #expect(result["isError"] == .bool(false))
    }

    @Test func auditRecordsRedactedTruncatedArguments() async throws {
        let tool = FakeTool(name: "t")
        let (runner, _, audit) = makeRunner([tool])
        let long = String(repeating: "x", count: 500)
        _ = await runner.call(
            name: "t", arguments: .object(["token": .string("abc"), "host": .string("example.com")]),
            client: nil)
        _ = await runner.call(
            name: "t", arguments: .object(["token": .string("abc"), "text": .string(long)]), client: nil)
        let entries = audit.snapshot()
        let short = try #require(entries.last)
        #expect(!short.arguments.contains("abc"))
        #expect(short.arguments.contains("example.com"))
        let cut = try #require(entries.first)
        #expect(!cut.arguments.contains("abc"))
        #expect(cut.arguments.count <= 160)
        #expect(cut.arguments.hasSuffix("…"))
    }

    @Test func auditArgumentsRespectRedactionSwitchAndExtraNames() async throws {
        let tool = FakeTool(name: "t")
        var settings = enabledSettings()
        settings.redaction.extraNames = ["customer"]
        let (runner, policy, audit) = makeRunner([tool], settings: settings)
        _ = await runner.call(name: "t", arguments: .object(["customer": .string("zed")]), client: nil)
        #expect(audit.snapshot().first?.arguments.contains("zed") == false)
        settings.redaction.enabled = false
        policy.update(settings)
        _ = await runner.call(name: "t", arguments: .object(["customer": .string("zed")]), client: nil)
        #expect(audit.snapshot().first?.arguments.contains("zed") == true)
    }

    @Test func deniedCallsAreAuditedWithRedactedArguments() async throws {
        let write = FakeTool(name: "create_rule", kind: .write(.createRule))
        let (runner, _, audit) = makeRunner([write])
        _ = await runner.call(
            name: "create_rule", arguments: .object(["password": .string("hunter2")]), client: nil)
        let entry = try #require(audit.snapshot().first)
        #expect(!entry.arguments.contains("hunter2"))
    }

    @Test func unknownToolIsNotFoundAndNamesAreTheClosedAllowlist() async throws {
        let tool = FakeTool(name: "list_things")
        let (runner, _, audit) = makeRunner([tool])
        #expect(runner.listTools().compactMap { $0["name"]?.stringValue } == ["list_things"])
        let result = await runner.call(name: "delete_everything", arguments: nil, client: nil)
        #expect(result["isError"] == .bool(true))
        #expect(try payload(result)["error"]?["code"]?.stringValue == "not_found")
        #expect(tool.callCount == 0)
        #expect(audit.snapshot().first?.outcome == .failed(code: "not_found"))
    }

    @Test func disabledSettingsHideWhetherAToolExists() async throws {
        var settings = enabledSettings()
        settings.enabled = false
        let (runner, _, audit) = makeRunner([FakeTool(name: "list_things")], settings: settings)
        let result = await runner.call(name: "no_such_tool", arguments: nil, client: nil)
        #expect(try payload(result)["error"]?["code"]?.stringValue == "permission_denied")
        #expect(audit.snapshot().first?.outcome == .denied(.disabled))
    }

    @Test func overlongToolNameIsTruncatedInTheAudit() async throws {
        let (runner, _, audit) = makeRunner([FakeTool(name: "t")])
        _ = await runner.call(name: String(repeating: "n", count: 1000), arguments: nil, client: nil)
        #expect((audit.snapshot().first?.tool.count ?? 0) <= 64)
    }

    // MARK: Captured definitions and naming invariants (T4 review, T7 ruling)

    @Test func toolDefinitionsAreCapturedOnceAtInit() async throws {
        let tool = ShapeShiftingTool()
        let (runner, _, _) = makeRunner([tool])
        // The write permission is enforced from the captured definition, not from a later read.
        let denied = await runner.call(name: "create_rule", arguments: .object([:]), client: nil)
        #expect(denied["isError"] == .bool(true))
        #expect(try payload(denied)["error"]?["code"]?.stringValue == "permission_denied")
        #expect(tool.callCount == 0)
        let listed = runner.listTools()
        #expect(listed.first?["description"]?.stringValue?.hasPrefix("[Write tool") == true)
        #expect(listed.first?["description"]?.stringValue?.hasSuffix("first") == true)
        _ = runner.listTools()
        #expect(tool.definitionReads == 1)
    }

    @Test func writeToolMustBeNamedAfterItsPermission() {
        func problems(_ name: String, _ kind: MCPToolDefinition.Kind) -> [String] {
            MCPToolRunner.definitionProblems([
                FakeTool(name: name, kind: kind).definition
            ])
        }
        #expect(problems("create_rule", .write(.createRule)).isEmpty)
        #expect(problems("set_recording", .write(.setRecording)).isEmpty)
        #expect(!problems("update_rule", .write(.createRule)).isEmpty)
        #expect(!problems("anything", .write(.setRuleEnabled)).isEmpty)
    }

    @Test func readToolMustNotBeNamedLikeAWriteTool() {
        for write in MCPWriteTool.allCases {
            #expect(!MCPToolRunner.definitionProblems([FakeTool(name: write.rawValue, kind: .read).definition]).isEmpty)
        }
        #expect(MCPToolRunner.definitionProblems([FakeTool(name: "list_rules", kind: .read).definition]).isEmpty)
    }

    @Test func duplicateToolNamesAreAProblem() {
        let a = FakeTool(name: "list_things").definition
        #expect(MCPToolRunner.definitionProblems([a, a]).count == 1)
        #expect(MCPToolRunner.definitionProblems([a, FakeTool(name: "other").definition]).isEmpty)
    }

    // MARK: Size caps on tool errors (T4 review, T7 ruling)

    @Test func errorMessageIsCappedAt512Characters() async throws {
        let tool = FakeTool(name: "t") { _, _ in
            throw MCPToolError(code: "conflict", message: String(repeating: "m", count: 100_000))
        }
        let (runner, _, _) = makeRunner([tool])
        let error = try #require(try payload(await runner.call(name: "t", arguments: nil, client: nil))["error"])
        let message = try #require(error["message"]?.stringValue)
        #expect(message.count <= 512)
        #expect(message.unicodeScalars.count <= 512)
        #expect(error["code"]?.stringValue == "conflict")
        // A short message is untouched.
        let short = FakeTool(name: "s") { _, _ in throw MCPToolError(code: "conflict", message: "short") }
        let (runner2, _, _) = makeRunner([short])
        let shortError = try #require(try payload(await runner2.call(name: "s", arguments: nil, client: nil))["error"])
        #expect(shortError["message"]?.stringValue == "short")
    }

    @Test func errorMessageCapCountsScalarsNotGraphemeClusters() async throws {
        // One grapheme cluster made of many combining marks must not slip past a Character-based cap.
        let cluster = "e" + String(repeating: "\u{0301}", count: 5000)
        let tool = FakeTool(name: "t") { _, _ in throw MCPToolError(code: "conflict", message: cluster) }
        let (runner, _, _) = makeRunner([tool])
        let result = await runner.call(name: "t", arguments: nil, client: nil)
        let message = try #require(try payload(result)["error"]?["message"]?.stringValue)
        #expect(message.unicodeScalars.count <= 512)
    }

    @Test func errorExtraIsCappedAt8KiBSerialized() async throws {
        let big = (0..<2000).map { JSONValue.string(String(repeating: "x", count: 50) + "\($0)") }
        let tool = FakeTool(name: "t") { _, _ in
            throw MCPToolError(code: "rule_invalid", message: "bad", extra: .object(["issues": .array(big)]))
        }
        let (runner, _, _) = makeRunner([tool])
        let result = await runner.call(name: "t", arguments: nil, client: nil)
        #expect(result["isError"] == .bool(true))
        let text = try #require(result["content"]?.arrayValue?.first?["text"]?.stringValue)
        #expect(text.utf8.count <= 8 * 1024 + 1024)
        let error = try #require(try payload(result)["error"])
        #expect(error["code"]?.stringValue == "rule_invalid")
        #expect(error["message"]?.stringValue == "bad")
        #expect(error["issues"] == nil)
        #expect(error["extraDropped"] == .bool(true))

        // A non-object extra over the cap is dropped too.
        let scalar = FakeTool(name: "u") { _, _ in
            throw MCPToolError(code: "conflict", message: "bad", extra: .string(String(repeating: "y", count: 20_000)))
        }
        let (runner2, _, _) = makeRunner([scalar])
        let scalarResult = await runner2.call(name: "u", arguments: nil, client: nil)
        let scalarText = try #require(scalarResult["content"]?.arrayValue?.first?["text"]?.stringValue)
        #expect(scalarText.utf8.count <= 8 * 1024 + 1024)
    }

    @Test func smallErrorExtraSurvivesTheCap() async throws {
        let tool = FakeTool(name: "t") { _, _ in
            throw MCPToolError(code: "rule_invalid", message: "bad", extra: .object(["issues": .array([.string("a")])]))
        }
        let (runner, _, _) = makeRunner([tool])
        let error = try #require(try payload(await runner.call(name: "t", arguments: nil, client: nil))["error"])
        #expect(error["issues"] == .array([.string("a")]))
        #expect(error["extraDropped"] == nil)
    }

    @Test func errorCodeIsCapped() async throws {
        let tool = FakeTool(name: "t") { _, _ in
            throw MCPToolError(code: String(repeating: "c", count: 5000), message: "bad")
        }
        let (runner, _, _) = makeRunner([tool])
        let error = try #require(try payload(await runner.call(name: "t", arguments: nil, client: nil))["error"])
        #expect((error["code"]?.stringValue?.count ?? .max) <= 64)
    }
}
