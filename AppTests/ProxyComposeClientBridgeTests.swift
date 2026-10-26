import FlowStore
import Foundation
import ProxyCore
import Testing
@testable import AppCore
@testable import ProxyWoman

/// The App bridge over the real `ProxyServer.compose`: an AppCore draft goes through
/// `ProxyComposeClient` and the server's upstream path to a loopback origin.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)), .productionChinese) struct ProxyComposeClientBridgeTests {
    @Test func theOriginReceivesTheDraftsQueryBytes() async throws {
        let origin = try await LoopbackOrigin.start()
        let harness = try await BridgeHarness.start(rules: [])
        do {
            let client = ProxyComposeClient(service: harness.server.compose)
            let model = ComposeViewModel(
                draft: ComposeDraft(method: "GET", url: "http://127.0.0.1:\(origin.port)/p/%2F?a=1&a=2&b=%2F&c=+&flag&e=&x=%2f&#frag"),
                client: client)
            #expect(model.canSend)
            await model.send()

            let request = try await origin.awaitRequest()
            #expect(request.method == "GET")
            #expect(request.uri == "/p/%2F?a=1&a=2&b=%2F&c=+&flag&e=&x=%2f&")
            #expect(model.phase == .done)
            let result = try #require(model.result)
            #expect(result.response?.status == 200 && result.response?.body == Data("origin-ok".utf8))
            #expect(!result.isPartial && result.failureMessage == nil)
            let flowID = try #require(result.flowID)
            let flow = try #require(harness.store.allFlows().first { $0.id == flowID })
            #expect(flow.provenance.isCompose)

            // Bytes a URL cannot carry are encoded one by one; an edited row is encoded, the rest kept.
            model.draft.setURL("http://127.0.0.1:\(origin.port)/q?n=é&keep=%2f+x&edit=1")
            let edit = try #require(model.draft.query.rows.last)
            model.draft.setQueryValue(edit.id, "a b")
            await model.send()
            let second = try await origin.awaitRequest()
            #expect(second.uri == "/q?n=%C3%A9&keep=%2f+x&edit=a%20b")
            #expect(model.phase == .done && model.result?.flowID != flowID)
            #expect(origin.requests.count == 2)
        } catch {
            await harness.stop(); await origin.stop()
            throw error
        }
        await harness.stop(); await origin.stop()
    }

    @Test func theRepeatTagAndApplyRulesReachTheServicesFlowProvenance() async throws {
        let origin = try await LoopbackOrigin.start()
        let harness = try await BridgeHarness.start(rules: [])
        do {
            let client = ProxyComposeClient(service: harness.server.compose)
            let tag = RepeatRunTag(runID: UUID(), index: 4, total: 6)
            func request(applyRules: Bool, tag: RepeatRunTag?) -> ComposeOutgoingRequest {
                ComposeOutgoingRequest(
                    id: UUID(), method: "GET", url: "http://127.0.0.1:\(origin.port)/r", headers: [], body: Data(),
                    sourceFlowID: nil, applyRules: applyRules, timeoutSeconds: 30, http1Only: false, repeatTag: tag)
            }
            let tagged = await client.send(request(applyRules: false, tag: tag))
            let rules = await client.send(request(applyRules: true, tag: nil))
            #expect(tagged.failure == nil && rules.failure == nil)
            let taggedFlow = try #require(harness.store.allFlows().first { $0.id == tagged.flowID })
            let rulesFlow = try #require(harness.store.allFlows().first { $0.id == rules.flowID })
            #expect(taggedFlow.provenance.tools.repeatRun == tag)
            #expect(taggedFlow.provenance.rulesDisabled)
            #expect(rulesFlow.provenance.tools.repeatRun == nil)
            #expect(!rulesFlow.provenance.rulesDisabled)
            // The default leaves every existing caller untagged.
            #expect(ComposeOutgoingRequest(id: UUID(), method: "GET", url: "http://h/", headers: [], body: Data(),
                                           sourceFlowID: nil, applyRules: false, timeoutSeconds: 1, http1Only: false).repeatTag == nil)
        } catch {
            await harness.stop(); await origin.stop()
            throw error
        }
        await harness.stop(); await origin.stop()
    }

    @Test func aCancelledSendIsMarkedAsACancellationAndOtherFailuresAreNot() async throws {
        let origin = try await LoopbackOrigin.start()
        let harness = try await BridgeHarness.start(rules: [])
        let client = ProxyComposeClient(service: harness.server.compose)
        func request(_ url: String) -> ComposeOutgoingRequest {
            ComposeOutgoingRequest(id: UUID(), method: "GET", url: url, headers: [], body: Data(), sourceFlowID: nil,
                                   applyRules: false, timeoutSeconds: 30, http1Only: false)
        }
        // A send whose calling task is already cancelled is refused by the service as `compose.cancelled`.
        let cancelledRequest = request("http://127.0.0.1:\(origin.port)/c")
        let cancelled = await Task { () -> ComposeOutcome in
            withUnsafeCurrentTask { $0?.cancel() }
            return await client.send(cancelledRequest)
        }.value
        #expect(cancelled.failure?.isCancellation == true)
        #expect(cancelled.failure?.code == ComposeFailureCode.cancelled.rawValue)
        #expect(origin.requests.isEmpty)

        let invalid = await client.send(request("http://[bad"))
        #expect(invalid.failure != nil && invalid.failure?.isCancellation == false)
        let sent = await client.send(request("http://127.0.0.1:\(origin.port)/ok"))
        #expect(sent.failure == nil)
        await harness.stop(); await origin.stop()
    }

    @Test func aStoppedServerFailsWithALocalizedReasonAndNoRequest() async throws {
        let origin = try await LoopbackOrigin.start()
        let harness = try await BridgeHarness.start(rules: [])
        await harness.stop()
        let model = ComposeViewModel(draft: ComposeDraft(method: "GET", url: "http://127.0.0.1:\(origin.port)/x"),
                                     client: ProxyComposeClient(service: harness.server.compose))
        await model.send()
        #expect(model.phase == .failed)
        let result = try #require(model.result)
        #expect(result.flowID == nil && result.response == nil)
        #expect(result.failureMessage?.isEmpty == false && result.deliveryNotice == nil)
        #expect(origin.requests.isEmpty)
        await origin.stop()
    }
}
