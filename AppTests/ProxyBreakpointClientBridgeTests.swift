import FlowStore
import Foundation
import ProxyCore
import RulesEngine
import Testing
@testable import AppCore
@testable import ProxyWoman

/// The App bridge over the real coordinator: a real ProxyServer pauses a real loopback request,
/// the AppCore queue/editor models edit and continue it through `ProxyBreakpointClient`, and the
/// loopback origin receives exactly the edited request.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)), .productionChinese) struct ProxyBreakpointClientBridgeTests {
    private static let breakpoint = Rule(
        id: UUID(), name: "pause", enabled: true, order: 0, matcher: RuleMatcher(),
        action: .breakpoint(direction: .request, mode: .headers))

    @Test func editedRequestReachesTheOriginThroughTheClient() async throws {
        let origin = try await LoopbackOrigin.start()
        let harness = try await BridgeHarness.start(rules: [Self.breakpoint])
        let client = ProxyBreakpointClient(coordinator: harness.coordinator)
        let model = BreakpointQueueModel(client: client)
        let connection = try await LoopbackClient.connect(port: harness.proxyPort)
        do {
            model.start()
            let authority = "127.0.0.1:\(origin.port)"
            try await connection.send(
                "GET http://\(authority)/x?a=1 HTTP/1.1\r\nHost: \(authority)\r\nX-Probe: original\r\nConnection: close\r\n\r\n")
            try await waitUntil(model, "the paused request") { model.pendingCount == 1 }
            #expect(origin.requests.isEmpty)

            let ticket = try #require(model.tickets.first)
            #expect(ticket.direction == .request && ticket.phase == .pausedHeaders && ticket.flowID != nil)
            let remaining = BreakpointCountdown.remainingSeconds(until: ticket.deadline, now: Date())
            #expect((110...120).contains(remaining))

            model.select(ticket.id)
            let editor = try #require(model.selectedEditor)
            #expect(editor.method == "GET" && editor.url == "http://\(authority)/x?a=1")
            editor.url = "http://\(authority)/y?a=1&a=1"
            let probe = try #require(editor.headers.firstIndex { $0.name == "X-Probe" })
            editor.headers[probe].value = "edited"
            await model.continueSelected()
            #expect(model.notice == nil && model.selectedEditor == nil)

            let request = try await origin.awaitRequest()
            #expect(request.method == "GET" && request.uri == "/y?a=1&a=1")
            #expect(request.headers.filter { $0.name.lowercased() == "x-probe" }.map(\.value) == ["edited"])
            let response = try await connection.responseUntilClose()
            #expect(response.hasPrefix("HTTP/1.1 200") && response.hasSuffix("origin-ok"))
            try await waitUntil(model, "the ticket to end") { model.pendingCount == 0 }
            #expect(await client.tickets().isEmpty)
            #expect(origin.requests.count == 1)
        } catch {
            await connection.close(); await harness.stop(); await origin.stop()
            throw error
        }
        await connection.close(); await harness.stop(); await origin.stop()
    }

    @Test func clearCancelsPausedTicketsThroughTheCoordinatorOnce() async throws {
        let origin = try await LoopbackOrigin.start()
        let harness = try await BridgeHarness.start(rules: [Self.breakpoint])
        let client = ProxyBreakpointClient(coordinator: harness.coordinator)
        let model = BreakpointQueueModel(client: client)
        let connection = try await LoopbackClient.connect(port: harness.proxyPort)
        do {
            model.start()
            let authority = "127.0.0.1:\(origin.port)"
            try await connection.send("GET http://\(authority)/clear HTTP/1.1\r\nHost: \(authority)\r\nConnection: close\r\n\r\n")
            try await waitUntil(model, "the paused request") { model.pendingCount == 1 }

            var clears = 0
            let confirmation = FlowClearConfirmation(client: client) {
                clears += 1
                harness.store.clear()
            }
            await confirmation.request()
            #expect(confirmation.pausedTicketCount == 1 && clears == 0)
            await confirmation.confirm()
            #expect(clears == 1)
            #expect(await client.tickets().isEmpty)

            let response = try await connection.responseUntilClose()
            #expect(response.hasPrefix("HTTP/1.1 502"))
            #expect(response.components(separatedBy: "HTTP/1.1 ").count == 2)
            #expect(origin.requests.isEmpty)
            try await waitUntil(model, "the queue to empty") { model.pendingCount == 0 }
        } catch {
            await connection.close(); await harness.stop(); await origin.stop()
            throw error
        }
        await connection.close(); await harness.stop(); await origin.stop()
    }

    /// Phase fix I2c: a collected body is replaced by a picked file the proxy copies itself; the
    /// origin receives exactly the file's bytes with the matching length.
    @Test func collectedBodyIsReplacedFromAFileThroughTheClient() async throws {
        let fullBody = Rule(id: UUID(), name: "pause body", enabled: true, order: 0, matcher: RuleMatcher(),
                            action: .breakpoint(direction: .request, mode: .fullBody))
        let origin = try await LoopbackOrigin.start()
        let harness = try await BridgeHarness.start(rules: [fullBody])
        let client = ProxyBreakpointClient(coordinator: harness.coordinator)
        let model = BreakpointQueueModel(client: client)
        let connection = try await LoopbackClient.connect(port: harness.proxyPort)
        let file = harness.root.appendingPathComponent("replacement.bin")
        let replacement = Array("replaced from a file".utf8)
        do {
            try Data(replacement).write(to: file)
            model.start()
            let authority = "127.0.0.1:\(origin.port)"
            try await connection.send(
                "POST http://\(authority)/upload HTTP/1.1\r\nHost: \(authority)\r\nContent-Length: 8\r\nConnection: close\r\n\r\noriginal")
            try await waitUntil(model, "the collected body") { model.tickets.first?.phase == .pausedBody }
            let ticket = try #require(model.tickets.first)
            model.select(ticket.id)
            let editor = try #require(model.selectedEditor)
            #expect(editor.canReplaceBodyFromFile)
            await editor.replaceBody(from: file)
            let imported = try #require(editor.replacementFile)
            #expect(imported.size == Int64(replacement.count) && imported.fileName == "replacement.bin")
            await model.continueSelected()
            #expect(model.notice == nil && model.selectedEditor == nil)

            let request = try await origin.awaitRequest()
            #expect(request.method == "POST" && request.uri == "/upload")
            #expect(request.headers.filter { $0.name.lowercased() == "content-length" }.map(\.value) == ["\(replacement.count)"])
            let response = try await connection.responseUntilClose()
            #expect(response.hasPrefix("HTTP/1.1 200"))
            #expect(origin.bodies == [replacement])
            try await waitUntil(model, "the ticket to end") { model.pendingCount == 0 }
        } catch {
            await connection.close(); await harness.stop(); await origin.stop()
            throw error
        }
        await connection.close(); await harness.stop(); await origin.stop()
    }

    @Test func theAppEnablesLiveBreakpointRules() {
        #expect(AppModel.breakpointsAreLive)
    }
}
