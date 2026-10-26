import AppCore
import FlowStore
import Foundation
import Testing
@testable import ProxyWoman

/// `AppModel.beginRepeat`: the flow-table entry opens the repeat sheet only for a flow Replay could
/// send, and the sheet's run repeats that flow's own request. No server is started and nothing is
/// sent here; the model is the isolated one (its files live under a temporary root).
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)), .productionChinese) struct RepeatLaunchTests {
    private func withModel(_ body: (AppModel) throws -> Void) throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("repeat-launch-\(UUID().uuidString)", isDirectory: true)
        let root = base.appendingPathComponent("root", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        defer { try? FileManager.default.removeItem(at: base) }
        let runtime = try AppRuntime.resolve(
            arguments: ["/app", IsolatedLaunch.rootArgument, root.path], environment: ["CFFIXED_USER_HOME": home.path],
            bundleIdentifier: "dev.pwapp.mac.t12a-copy", temporaryDirectories: [base], home: home,
            commandRunner: RecordingCommandRunner(), trust: TrustRecorder().operations)
        let model = AppModel(runtime: runtime)
        do { try body(model) } catch { model.shutdown(); throw error }
        model.shutdown()
    }

    private func withModelAsync(_ body: (AppModel) async throws -> Void) async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("repeat-launch-\(UUID().uuidString)", isDirectory: true)
        let root = base.appendingPathComponent("root", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        defer { try? FileManager.default.removeItem(at: base) }
        let runtime = try AppRuntime.resolve(
            arguments: ["/app", IsolatedLaunch.rootArgument, root.path], environment: ["CFFIXED_USER_HOME": home.path],
            bundleIdentifier: "dev.pwapp.mac.t12a-copy", temporaryDirectories: [base], home: home,
            commandRunner: RecordingCommandRunner(), trust: TrustRecorder().operations)
        let model = AppModel(runtime: runtime)
        do { try await body(model) } catch { model.shutdown(); throw error }
        model.shutdown()
    }

    private func flow(method: String, path: String = "/items?a=1") -> Flow {
        var flow = Flow(id: 11, scheme: "https", method: method, host: "api.test", port: 8443, path: path,
                        requestHeaders: [HeaderField(name: "Accept", value: "*/*")])
        flow.state = .completed
        return flow
    }

    @Test func aReplayableFlowOpensTheSheetWithItsOwnRequest() throws {
        try withModel { model in
            #expect(model.pendingRepeat == nil)
            let source = flow(method: "POST")
            #expect(ComposeEntry.replay(source) == nil)
            model.beginRepeat(flow: source)
            let request = try #require(model.pendingRepeat)
            let draft = request.model.draft
            #expect(draft.method == "POST")
            #expect(draft.url == "https://api.test:8443/items?a=1")
            #expect(draft.sourceFlowID == 11)
            #expect(draft.headers.map { HeaderField(name: $0.name, value: $0.value) } == source.requestHeaders)
            #expect(draft.body == ComposeDraftBody.none)
            // Defaults of a fresh run, and a side-effecting method needs the confirmation first.
            #expect(request.model.phase == .ready)
            #expect(request.model.options == RepeatOptions())
            #expect(request.model.requiresConfirmation && !request.model.canStart)
        }
    }

    @Test func aReadMethodNeedsNoConfirmation() throws {
        try withModel { model in
            model.beginRepeat(flow: flow(method: "GET"))
            let request = try #require(model.pendingRepeat)
            #expect(request.model.draft.method == "GET")
            #expect(!request.model.requiresConfirmation && request.model.canStart)
        }
    }

    @Test func aFlowReplayWouldRefuseNeverOpensTheSheet() throws {
        try withModel { model in
            let tunnel = flow(method: "CONNECT", path: "")
            let truncated = { var f = flow(method: "POST"); f.requestBodyTruncated = true; return f }()
            let unfinished = { var f = flow(method: "GET"); f.state = .inProgress; return f }()
            for refused in [tunnel, truncated, unfinished] {
                #expect(ComposeEntry.replay(refused) != nil)
                model.beginRepeat(flow: refused)
                #expect(model.pendingRepeat == nil)
            }
        }
    }

    @Test func menuBarRepeatIsEnabledForExactlyTheFlowsTheSheetAccepts() throws {
        try withModel { model in
            // No selection: nothing to repeat.
            #expect(!model.canRepeat(flow: nil))
            let tunnel = flow(method: "CONNECT", path: "")
            let truncated = { var f = flow(method: "POST"); f.requestBodyTruncated = true; return f }()
            let unfinished = { var f = flow(method: "GET"); f.state = .inProgress; return f }()
            for refused in [tunnel, truncated, unfinished] {
                #expect(!model.canRepeat(flow: refused))
                model.beginRepeat(flow: refused)
                #expect(model.pendingRepeat == nil)
            }
            for accepted in [flow(method: "GET"), flow(method: "POST")] {
                #expect(model.canRepeat(flow: accepted))
                model.pendingRepeat = nil
                model.beginRepeat(flow: accepted)
                #expect(model.pendingRepeat != nil)
            }
        }
    }

    @Test func menuBarSaveResponseAsMockNeedsACapturedResponseAndAnEditorThatCanTakeADraft() async throws {
        try await withModelAsync { model in
            var withResponse = flow(method: "GET")
            let target = HTTPMessageTarget(scheme: "https", host: "api.test", port: 8443, method: "GET", pathAndQuery: "/items?a=1")
            withResponse.messages = [
                .downstreamRequest: HTTPMessageSnapshot(
                    boundary: .downstreamRequest, head: .request(target, headers: []), bodyState: .complete, transferState: .finished),
                .downstreamResponse: HTTPMessageSnapshot(
                    boundary: .downstreamResponse, head: .response(status: 200, reason: nil, headers: []),
                    bodyState: .complete, transferState: .finished),
            ]
            let tunnel = flow(method: "CONNECT", path: "")
            await model.rulesEditor.load()
            #expect(model.rulesEditor.canMutate)
            #expect(!model.canSaveResponseAsMock(flow: nil))
            // No captured response (this flow has only its request headers), and a tunnel has none.
            #expect(!model.canSaveResponseAsMock(flow: flow(method: "GET")))
            #expect(!model.canSaveResponseAsMock(flow: tunnel))
            #expect(model.canSaveResponseAsMock(flow: withResponse))
            // The context menu's tooltip comes from the same judgement.
            #expect(model.responseMockBlockReason(flow: withResponse) == nil)
            #expect(model.responseMockBlockReason(flow: tunnel) != nil)
        }
    }

    @Test func eachBeginMakesANewRunWithItsOwnIdentity() throws {
        try withModel { model in
            model.beginRepeat(flow: flow(method: "GET"))
            let first = try #require(model.pendingRepeat)
            model.beginRepeat(flow: flow(method: "GET"))
            let second = try #require(model.pendingRepeat)
            #expect(first.id != second.id && first.model.runID != second.model.runID)
        }
    }
}
