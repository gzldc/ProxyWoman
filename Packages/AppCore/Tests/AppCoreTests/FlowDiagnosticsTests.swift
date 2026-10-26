import FlowStore
import Testing

@testable import AppCore

@Suite(.productionChinese) struct FlowDiagnosticsTests {
    private func flow(state: FlowState, status: Int? = nil, note: String? = nil) -> Flow {
        var flow = Flow(id: 1, scheme: "https", method: "CONNECT", host: "example.com", port: 443, path: "")
        flow.state = state
        flow.statusCode = status
        flow.note = note
        return flow
    }

    @Test func failureWithoutStatusOrNoteKeepsReason() {
        let diagnostics = FlowDiagnostics(flow: flow(state: .failed("TLS 握手超时")))
        #expect(diagnostics.failure == "TLS 握手超时")
        #expect(diagnostics.note == nil)
    }

    @Test func failureAfterResponseHeadKeepsReasonAndDistinctNote() {
        let diagnostics = FlowDiagnostics(flow: flow(state: .failed("传输中断"), status: 200, note: "仅记录部分内容"))
        #expect(diagnostics.failure == "传输中断")
        #expect(diagnostics.note == "仅记录部分内容")
    }

    @Test func noteOnlyKeepsCaptureExplanation() {
        let diagnostics = FlowDiagnostics(flow: flow(state: .completed, status: 101, note: "Upgrade 后按原始字节转发"))
        #expect(diagnostics.failure == nil)
        #expect(diagnostics.note == "Upgrade 后按原始字节转发")
    }

    @Test func duplicateNoteIsShownOnlyAsFailure() {
        let diagnostics = FlowDiagnostics(flow: flow(state: .failed("连接失败"), note: " 连接失败\n"))
        #expect(diagnostics.failure == "连接失败")
        #expect(diagnostics.note == nil)
    }
}
