import Foundation
import MCPWire
import Testing

@testable import MCPKit

// MARK: - Helpers

private let status = StubStatus(
    value: MCPAppStatus(recording: true, listeningPort: 8899, rulesCount: 0, enabledRulesCount: 0, globalRulesSwitchOn: true))

/// The real tool set over empty in-memory backends.
private struct ToolSetRig {
    let rules = FakeRules()
    let recording = FakeRecording()
    let store = DetailFixture()
    let policy: MCPPolicyProvider
    let audit = MCPAuditLog()
    let tools: [any MCPTool]
    let runner: MCPToolRunner

    init(_ settings: MCPSettings = enabledSettings()) {
        policy = MCPPolicyProvider(settings)
        tools = MCPToolSet.make(
            app: MCPAppInfo(name: "ProxyWoman", version: "9.9"), store: store.store, status: status, rules: rules,
            recording: recording)
        runner = MCPToolRunner(tools: tools, policy: policy, audit: audit)
    }

    func call(_ name: String, _ arguments: [String: JSONValue]) async throws -> (isError: Bool, body: JSONValue) {
        let result = await runner.call(name: name, arguments: .object(arguments), client: "security-tests")
        return (result["isError"] == .bool(true), try payload(result))
    }

    /// Every call that reached a backend.
    var backendCalls: Int {
        get async { await rules.totalCalls + recording.requests.count }
    }
}

private let writeToolNames = ["create_rule", "update_rule", "set_rule_enabled", "set_recording"]
private let someRuleID = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"

/// Valid arguments for each write tool, so a call that is permitted succeeds and a refusal can only be the
/// permission check.
private let validWriteCalls: [String: [String: JSONValue]] = [
    "create_rule": createRuleArguments,
    "update_rule": ["id": .string(someRuleID), "name": .string("Renamed")],
    "set_rule_enabled": ["id": .string(someRuleID), "enabled": .bool(false)],
    "set_recording": ["enabled": .bool(true)],
]

// MARK: - Source scan

private enum Sources {
    /// The repository root, from this file: Packages/MCPKit/Tests/MCPKitTests/<file>.
    static let root: URL = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url
    }()

    struct File {
        var path: String
        var text: String
        var name: String { (path as NSString).lastPathComponent }
    }

    static func swiftFiles(under relative: String) throws -> [File] {
        let directory = root.appendingPathComponent(relative, isDirectory: true)
        let enumerator = try #require(
            FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil),
            "cannot read \(relative)")
        var files: [File] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            files.append(File(path: url.path, text: try String(contentsOf: url, encoding: .utf8)))
        }
        return files
    }

    /// Module names imported by a file (`import X`, `@testable import X`, `import struct X.Y`, `import X.Y`).
    static func imports(of file: File) -> [String] {
        var modules: [String] = []
        for rawLine in file.text.split(separator: "\n", omittingEmptySubsequences: true) {
            var words = rawLine.trimmingCharacters(in: .whitespaces).split(separator: " ").map(String.init)
            while let first = words.first, first.hasPrefix("@") || first == "public" || first == "internal" {
                words.removeFirst()
            }
            guard words.first == "import", words.count >= 2 else { continue }
            var module = words[1]
            if ["struct", "class", "enum", "protocol", "func", "var", "let", "typealias"].contains(module), words.count >= 3 {
                module = words[2]
            }
            modules.append(String(module.split(separator: ".").first ?? ""))
        }
        return modules
    }
}

private func isForbiddenImport(_ module: String) -> Bool {
    ["ProxyCore", "SystemProxy", "CertKit"].contains(module) || module.hasPrefix("NIO")
}

@Suite struct MCPSecurityTests {
    // MARK: The tool set

    @Test func toolNamesMatchClosedAllowlist() {
        let rig = ToolSetRig()
        let names = rig.tools.map(\.definition.name)
        #expect(names.count == 11)
        #expect(Set(names) == Set(expectedToolNames))
        #expect(names == expectedToolNames, "the order of tools/list is part of the contract")
        #expect(
            Set(names)
                == [
                    "get_status", "list_flows", "search_flows", "get_flow", "list_rules", "export_flow_curl",
                    "export_har", "create_rule", "update_rule", "set_rule_enabled", "set_recording",
                ])
        #expect(Set(rig.runner.listTools().compactMap { $0["name"]?.stringValue }) == Set(expectedToolNames))
    }

    /// Rules 2.0 R7: import, export and templates are user actions in the app only; no MCP tool can reach them.
    @Test func noPackOrTemplateToolsAreExposed() throws {
        let rig = ToolSetRig()
        let names = rig.tools.map(\.definition.name)
        let ruleTools = names.filter { $0.contains("rule") }
        // The rule tools are exactly these; none of them is a pack, import, export or template tool.
        #expect(ruleTools == ["list_rules", "create_rule", "update_rule", "set_rule_enabled"])
        let forbidden = try NSRegularExpression(pattern: "pack|import|template|(^|_)export(_|$)", options: .caseInsensitive)
        for name in names where name != "export_flow_curl" && name != "export_har" {
            #expect(forbidden.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) == nil, "\(name)")
        }
        #expect(Set(names).isDisjoint(with: ["export_rules", "import_rules", "export_pack", "import_pack", "install_templates"]))
    }

    @Test func toolNameAndWritePermissionArePaired() {
        let rig = ToolSetRig()
        let expectedPairs: [String: MCPWriteTool] = [
            "create_rule": .createRule, "update_rule": .updateRule, "set_rule_enabled": .setRuleEnabled,
            "set_recording": .setRecording,
        ]
        #expect(Set(MCPWriteTool.allCases) == Set(expectedPairs.values), "a write tool without a test pairing")
        var writes: [String: MCPWriteTool] = [:]
        for definition in rig.tools.map(\.definition) {
            switch definition.kind {
            case .write(let permission):
                writes[definition.name] = permission
                #expect(definition.name == permission.rawValue)
            case .read:
                #expect(MCPWriteTool(rawValue: definition.name) == nil, "\(definition.name) is a read tool named like a write tool")
            }
        }
        #expect(writes == expectedPairs)
    }

    @Test func writeToolsAreExactlyTheFourAndAnnotatedNotReadOnly() throws {
        let rig = ToolSetRig()
        let listed = rig.runner.listTools()
        let writes = listed.filter { $0["annotations"]?["readOnlyHint"] == .bool(false) }
        #expect(writes.compactMap { $0["name"]?.stringValue } == writeToolNames)
        #expect(rig.tools.map(\.definition).filter { $0.kind != .read }.map(\.name) == writeToolNames)
        for tool in writes {
            let annotations = try #require(tool["annotations"])
            #expect(annotations["destructiveHint"] == .bool(false))
            #expect(annotations["openWorldHint"] == .bool(false))
            // With nothing allowed, each one says so in its description.
            #expect(tool["description"]?.stringValue?.hasPrefix(MCPToolRunner.disabledWritePrefix) == true)
        }
    }

    @Test func everyReadToolIsReadOnlyHinted() throws {
        let rig = ToolSetRig()
        let reads = rig.tools.map(\.definition).filter { $0.kind == .read }.map(\.name)
        #expect(reads.count == 7)
        for tool in rig.runner.listTools() {
            let name = try #require(tool["name"]?.stringValue)
            guard reads.contains(name) else { continue }
            #expect(tool["annotations"]?["readOnlyHint"] == .bool(true), "\(name)")
            #expect(tool["annotations"]?["destructiveHint"] == nil, "\(name)")
            #expect(tool["annotations"]?["openWorldHint"] == .bool(false), "\(name)")
            #expect(tool["description"]?.stringValue?.hasPrefix(MCPToolRunner.disabledWritePrefix) == false, "\(name)")
        }
    }

    @Test func noToolAcceptsPathOrURLParameter() throws {
        let forbidden: Set<String> = ["path", "file", "url", "command", "script"]
        // Rule specs describe the URL path component a rule matches (and the path a Map Remote action
        // rewrites to); they are not file system paths and sit below `match` / `action` / `actions`, not at the top.
        let allowedBelow: Set<String> = ["match.path", "action.path", "actions.path"]
        let rig = ToolSetRig()
        var found: [String] = []
        for definition in rig.tools.map(\.definition) {
            func walk(_ schema: JSONValue, _ trail: String) {
                guard let properties = schema["properties"]?.objectValue else { return }
                for (name, child) in properties {
                    let here = trail.isEmpty ? name : trail + "." + name
                    if forbidden.contains(name.lowercased()), !(trail != "" && allowedBelow.contains(here)) {
                        found.append("\(definition.name): \(here)")
                    }
                    walk(child, here)
                    if let items = child["items"] { walk(items, here) }
                }
            }
            walk(definition.inputSchema, "")
            // And the top level is checked on its own, whatever the exceptions say.
            let top = definition.inputSchema["properties"]?.objectValue ?? [:]
            #expect(Set(top.keys).isDisjoint(with: forbidden), "\(definition.name) has a forbidden top-level parameter")
        }
        #expect(found.isEmpty, "\(found)")
    }

    // MARK: What a listing may tell the AI client

    @Test func securityRedactionAppliesToActionSummaries() async throws {
        let rig = ToolSetRig()
        let secret = "SECRETVALUE"
        let hostile = MCPRuleActionSummary(
            type: "edit_headers?access_token=\(secret)" + String(repeating: "t", count: 500),
            direction: "request?token=\(secret)" + String(repeating: "d", count: 500), isFinal: true)
        let rule = MCPRuleSummary(
            id: UUID(), name: "r", enabled: false, order: 0, type: "multiple", direction: nil, match: .null, summary: "s",
            mode: "any?token=\(secret)" + String(repeating: "m", count: 500), actions: [hostile, hostile], groupID: UUID())
        await rig.rules.script(listing: MCPRuleListing(revision: 1, globalSwitchOn: true, rules: [rule]))
        let reply = try await rig.call("list_rules", [:])
        #expect(!reply.isError)
        let text = String(decoding: try reply.body.encoded(), as: UTF8.self)
        #expect(!text.contains(secret), "a secret in an action summary reached the AI client")
        let item = try #require(reply.body["rules"]?.arrayValue?.first)
        #expect((item["mode"]?.stringValue?.unicodeScalars.count ?? .max) <= 32)
        let actions = try #require(item["actions"]?.arrayValue)
        #expect(actions.count == 2)
        for action in actions {
            #expect((action["type"]?.stringValue?.unicodeScalars.count ?? .max) <= 64)
            #expect((action["direction"]?.stringValue?.unicodeScalars.count ?? .max) <= 32)
            #expect(action["final"] == .bool(true))
        }
        // With redaction switched off the secret is the user's own choice to show, but the caps still hold.
        var open = enabledSettings()
        open.redaction.enabled = false
        let unredacted = ToolSetRig(open)
        await unredacted.rules.script(listing: MCPRuleListing(revision: 1, globalSwitchOn: true, rules: [rule]))
        let plain = try await unredacted.call("list_rules", [:])
        let first = try #require(plain.body["rules"]?.arrayValue?.first?["actions"]?.arrayValue?.first)
        #expect((first["type"]?.stringValue?.unicodeScalars.count ?? .max) <= 64)
    }

    // MARK: Cross-permission denial through the runner

    @Test func onlyCreateRuleGrantedDeniesTheOtherWriteToolsWithoutTouchingTheBackend() async throws {
        let rig = ToolSetRig(enabledSettings([.createRule]))
        for name in ["set_rule_enabled", "update_rule", "set_recording"] {
            let reply = try await rig.call(name, try #require(validWriteCalls[name]))
            #expect(reply.isError, "\(name)")
            #expect(reply.body["error"]?["code"]?.stringValue == "permission_denied", "\(name)")
        }
        #expect(await rig.backendCalls == 0, "a denied call must not reach a backend")
        #expect(
            rig.audit.snapshot().map(\.outcome).reversed()
                == [
                    .denied(.permission(tool: "set_rule_enabled")), .denied(.permission(tool: "update_rule")),
                    .denied(.permission(tool: "set_recording")),
                ])

        // The one that was granted works.
        let created = try await rig.call("create_rule", createRuleArguments)
        #expect(!created.isError, "\(created.body)")
        #expect(await rig.rules.creates.count == 1)
        #expect(await rig.backendCalls == 1)
    }

    @Test func eachGrantOpensExactlyItsOwnTool() async throws {
        for granted in MCPWriteTool.allCases {
            let rig = ToolSetRig(enabledSettings([granted]))
            for name in writeToolNames {
                let reply = try await rig.call(name, try #require(validWriteCalls[name]))
                if name == granted.rawValue {
                    #expect(!reply.isError, "\(name) with its own grant: \(reply.body)")
                } else {
                    #expect(reply.body["error"]?["code"]?.stringValue == "permission_denied", "\(name) with only \(granted)")
                }
            }
            #expect(await rig.backendCalls == 1, "only \(granted) may reach a backend")
        }
        // With nothing granted, nothing reaches a backend at all.
        let none = ToolSetRig()
        for name in writeToolNames { _ = try await none.call(name, try #require(validWriteCalls[name])) }
        #expect(await none.backendCalls == 0)
    }

    @Test func masterSwitchOffDeniesEvenGrantedWriteTools() async throws {
        var settings = enabledSettings(Set(MCPWriteTool.allCases))
        settings.enabled = false
        let rig = ToolSetRig(settings)
        for name in writeToolNames {
            let reply = try await rig.call(name, try #require(validWriteCalls[name]))
            #expect(reply.body["error"]?["code"]?.stringValue == "permission_denied", "\(name)")
        }
        #expect(await rig.backendCalls == 0)
    }

    // MARK: What the MCP code may import and call

    @Test func mcpSourcesImportNothingForbidden() throws {
        let forbiddenText = [
            "AF_INET", "INADDR", "Process(", "posix_spawn", "NSTask", "networksetup", "SecTrust",
        ]
        var scanned = 0
        for target in ["Packages/MCPWire/Sources", "Packages/MCPHelper/Sources", "Packages/MCPKit/Sources"] {
            let files = try Sources.swiftFiles(under: target)
            #expect(!files.isEmpty, "\(target) has no Swift files")
            for file in files {
                scanned += 1
                for module in Sources.imports(of: file) {
                    #expect(!isForbiddenImport(module), "\(file.path) imports \(module)")
                }
                for word in forbiddenText {
                    #expect(!file.text.contains(word), "\(file.path) contains \(word)")
                }
            }
        }
        #expect(scanned >= 20, "the scan found only \(scanned) files; did the layout change?")
    }

    @Test func wireAndHelperImportOnlyTheSmallAllowlist() throws {
        let allowed: Set<String> = ["Foundation", "Darwin", "MCPWire", "os", "Security"]
        for target in ["Packages/MCPWire/Sources", "Packages/MCPHelper/Sources"] {
            let files = try Sources.swiftFiles(under: target)
            #expect(!files.isEmpty)
            for file in files {
                for module in Sources.imports(of: file) {
                    #expect(allowed.contains(module), "\(file.path) imports \(module)")
                    if module == "Security" {
                        #expect(file.name == "MCPToken.swift", "\(file.path): Security is only for the token generator")
                    }
                }
            }
        }
        // The helper reaches the app only through MCPWire.
        let helper = try Sources.swiftFiles(under: "Packages/MCPHelper/Sources")
        #expect(helper.contains { Sources.imports(of: $0).contains("MCPWire") })
        // And the one permitted use of Security does exist, so the rule above is not vacuous.
        let wire = try Sources.swiftFiles(under: "Packages/MCPWire/Sources")
        #expect(wire.contains { $0.name == "MCPToken.swift" && Sources.imports(of: $0).contains("Security") })
    }

    @Test func appCoreStillImportsNoProxyCoreOrNIO() throws {
        let files = try Sources.swiftFiles(under: "Packages/AppCore/Sources")
        #expect(files.count > 10, "the scan found \(files.count) files")
        for file in files {
            for module in Sources.imports(of: file) {
                #expect(!isForbiddenImport(module), "\(file.path) imports \(module)")
            }
        }
    }

    @Test func importScannerRecognisesTheShapesItGuards() {
        func modules(_ text: String) -> [String] { Sources.imports(of: Sources.File(path: "x.swift", text: text)) }
        #expect(modules("import NIOCore\n@testable import ProxyCore\npublic import CertKit\nimport struct NIOCore.ByteBuffer\n  import   Foundation")
            == ["NIOCore", "ProxyCore", "CertKit", "NIOCore", "Foundation"])
        #expect(modules("// import NIO\nlet important = 1\n") == [])
    }
}
