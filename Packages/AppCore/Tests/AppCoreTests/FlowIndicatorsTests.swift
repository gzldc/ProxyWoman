import FlowStore
import Foundation
import Testing

@testable import AppCore

@Suite(.productionChinese) struct FlowIndicatorsTests {
    private func flow(scheme: String = "https", method: String = "GET", state: FlowState = .completed) -> Flow {
        var f = Flow(id: 1, scheme: scheme, method: method, host: "example.com", port: 443, path: "/")
        f.state = state
        return f
    }

    @Test func dotFollowsTheFlowState() {
        #expect(FlowIndicators.dotTone(of: flow(state: .completed)) == .success)
        #expect(FlowIndicators.dotTone(of: flow(state: .inProgress)) == .pending)
        #expect(FlowIndicators.dotTone(of: flow(state: .failed("x"))) == .failure)
        #expect(FlowIndicators.dotTone(of: flow(method: "CONNECT", state: .tunnel)) == .neutral)
    }

    @Test func completedErrorResponseStillHasAGreenDot() {
        var f = flow()
        f.statusCode = 404
        #expect(FlowIndicators.dotTone(of: f) == .success)
    }

    @Test func decryptedHTTPSShowsAnOpenLock() {
        #expect(FlowIndicators.ssl(of: flow()) == .decrypted)
        #expect(FlowIndicators.ssl(of: flow(method: "POST")) == .decrypted)
        #expect(SSLIndicator.decrypted.symbolName == "lock.open")
    }

    @Test func tunnelShowsAClosedLock() {
        #expect(FlowIndicators.ssl(of: flow(method: "CONNECT", state: .tunnel)) == .tunnel)
        #expect(FlowIndicators.ssl(of: flow(method: "CONNECT", state: .failed("handshake"))) == .tunnel)
        #expect(SSLIndicator.tunnel.symbolName == "lock")
    }

    @Test func plainHTTPShowsNothing() {
        #expect(FlowIndicators.ssl(of: flow(scheme: "http")) == SSLIndicator.none)
        #expect(SSLIndicator.none.symbolName == nil)
    }

    // Phase fix F3: a Compose send has no client process; the table names it instead of a blank.
    @Test func composeFlowsAreLabelledComposeWithTheirOwnSymbol() {
        var compose = flow()
        compose.provenance = FlowProvenance(source: .compose(sendID: UUID(), sourceFlowID: nil, sourceBoundary: nil))
        #expect(FlowIndicators.appName(of: compose) == "Compose")
        #expect(FlowIndicators.appSymbolName(of: compose) == "paperplane")

        var proxied = flow()
        proxied.client = ClientApp(pid: 7, name: "curl", executablePath: "/usr/bin/curl")
        #expect(FlowIndicators.appName(of: proxied) == "curl")
        #expect(FlowIndicators.appSymbolName(of: proxied) == nil)
        #expect(FlowIndicators.appName(of: flow()) == "")
        #expect(FlowIndicators.appSymbolName(of: flow()) == nil)
    }

    // Repeat-send flows are Compose flows with a run tag: the app column names the run index.
    @Test func repeatFlowShowsRepeatAppNameAndSymbol() {
        var repeated = flow()
        repeated.provenance = FlowProvenance(
            source: .compose(sendID: UUID(), sourceFlowID: 3, sourceBoundary: nil),
            tools: TrafficToolsProvenance(repeatRun: RepeatRunTag(runID: UUID(), index: 7, total: 10)))
        #expect(FlowIndicators.appName(of: repeated) == "重复发送 #7")
        #expect(FlowIndicators.appSymbolName(of: repeated) == "repeat")

        // A plain Compose send is unchanged, and so is a flow with a real client process.
        var compose = flow()
        compose.provenance = FlowProvenance(source: .compose(sendID: UUID(), sourceFlowID: nil, sourceBoundary: nil))
        #expect(FlowIndicators.appName(of: compose) == "Compose")
        #expect(FlowIndicators.appSymbolName(of: compose) == "paperplane")

        var proxied = flow()
        proxied.client = ClientApp(pid: 7, name: "curl", executablePath: "/usr/bin/curl")
        proxied.provenance = FlowProvenance(tools: TrafficToolsProvenance(repeatRun: RepeatRunTag(runID: UUID(), index: 1, total: 2)))
        #expect(FlowIndicators.appName(of: proxied) == "curl")
        #expect(FlowIndicators.appSymbolName(of: proxied) == nil)
    }
}
