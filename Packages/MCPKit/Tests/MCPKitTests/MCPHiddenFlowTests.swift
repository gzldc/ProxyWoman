import FlowStore
import Foundation
import MCPWire
import Testing

@testable import MCPKit

private let reference = Date(timeIntervalSince1970: 1_800_000_000)

private func context() -> MCPToolContext {
    let settings = enabledSettings()
    return MCPToolContext(settings: settings, redactor: MCPRedactor(settings.redaction), now: reference)
}

private func ids(_ result: JSONValue) -> [Int] {
    (result["flows"]?.arrayValue ?? []).compactMap { $0["id"]?.intValue }
}

private func notFound(_ work: () async throws -> JSONValue) async -> MCPToolError? {
    do {
        _ = try await work()
        return nil
    } catch let error as MCPToolError {
        return error
    } catch {
        return nil
    }
}

/// Three flows, the second hidden by a rule.
private struct Rig {
    let fixture = DetailFixture()
    let first: Int
    let hidden: Int
    let third: Int

    init() {
        let fixture = self.fixture
        func add(_ path: String, _ age: TimeInterval) -> Int {
            fixture.add(path: path, age: age) {
                $0.responseHeaders = [HeaderField(name: "Content-Type", value: "text/plain")]
                $0.responseBody = fixture.body("needle")
            }
        }
        first = add("/one", 30)
        hidden = add("/two", 20)
        third = add("/three", 10)
        let id = hidden
        fixture.store.update(id) { $0.isHidden = true }
    }

    var store: FlowStore { fixture.store }
    var app: MCPAppInfo { MCPAppInfo(name: "ProxyWoman", version: "9.9.9") }
}

@Suite struct MCPHiddenFlowTests {
    @Test func listFlowsOmitsHiddenFlows() async throws {
        let rig = Rig()
        let result = try await ListFlowsTool(store: rig.store).call([:], context: context())
        #expect(ids(result) == [rig.third, rig.first])
    }

    @Test func searchFlowsOmitsHiddenFlows() async throws {
        let rig = Rig()
        let result = try await SearchFlowsTool(store: rig.store).call(["body_contains": .string("needle")], context: context())
        #expect(ids(result) == [rig.third, rig.first])
    }

    @Test func getFlowOfAHiddenFlowIsNotFoundWithTheMessageOfAnUnknownId() async throws {
        let rig = Rig()
        let tool = GetFlowTool(store: rig.store)
        let hidden = try #require(await notFound { try await tool.call(["id": .int(rig.hidden)], context: context()) })
        let unknown = try #require(await notFound { try await tool.call(["id": .int(99)], context: context()) })
        #expect(hidden.code == unknown.code)
        #expect(hidden.code == "not_found")
        #expect(hidden.message == "No flow with id \(rig.hidden).")
        #expect(unknown.message == "No flow with id 99.")
    }

    @Test func exportFlowCurlOfAHiddenFlowIsNotFound() async throws {
        let rig = Rig()
        let tool = ExportFlowCurlTool(store: rig.store)
        let error = try #require(await notFound { try await tool.call(["id": .int(rig.hidden)], context: context()) })
        #expect(error.code == "not_found")
        #expect(error.message == "No flow with id \(rig.hidden).")
    }

    @Test func exportHarByIdsRejectsAHiddenFlow() async throws {
        let rig = Rig()
        let tool = ExportHARTool(store: rig.store, app: rig.app)
        let error = try #require(
            await notFound {
                try await tool.call(["ids": .array([.int(rig.first), .int(rig.hidden)])], context: context())
            })
        #expect(error.code == "not_found")
        #expect(error.message == "No flow with id \(rig.hidden).")
    }

    @Test func exportHarByFilterSkipsHiddenFlows() async throws {
        let rig = Rig()
        let har = try await ExportHARTool(store: rig.store, app: rig.app).call([:], context: context())
        let output = (try? har.encoded()).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        #expect(output.contains("/one"))
        #expect(output.contains("/three"))
        #expect(!output.contains("/two"))
    }

    @Test func getStatusCountsOnlyVisibleFlows() async throws {
        let rig = Rig()
        let source = StubStatus(
            value: MCPAppStatus(recording: true, listeningPort: 1, rulesCount: 0, enabledRulesCount: 0, globalRulesSwitchOn: true))
        let result = try await GetStatusTool(app: rig.app, flows: rig.store, status: source).call([:], context: context())
        #expect(result["flowCount"]?.intValue == 2)
    }

    @Test func mcpKitNeverReadsTheStoreDirectly() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let enumerator = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var scanned = 0
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            scanned += 1
            let source = try String(contentsOf: url, encoding: .utf8)
            for banned in ["allFlows()", "store.flow(", "flows.flow("] {
                #expect(!source.contains(banned), "\(url.lastPathComponent) contains \(banned)")
            }
        }
        #expect(scanned > 5)
    }
}
