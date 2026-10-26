import AppCore
import FlowStore
import Foundation
import Testing

@Suite(.productionChinese) struct ReplayEligibilityTests {
    private func flow(body: BodyRef? = nil, truncated: Bool = false) -> Flow {
        var flow = Flow(id: 1, scheme: "https", method: "POST", host: "test", port: 443, path: "/")
        flow.state = .completed; flow.requestBody = body; flow.requestBodyTruncated = truncated
        flow.bytesSent = body?.size ?? 0
        return flow
    }
    private func reason(_ flow: Flow) -> ReplayBlockReason? {
        switch ReplayEligibility.evaluate(flow: flow) { case .success: nil; case .failure(let reason): reason }
    }
    // Missing metadata checks would allow disk I/O, a truncated prefix, or an oversized allocation.
    @Test func replayEligibilityRejectsSpooledOversizeOrTruncated() {
        #expect(reason(flow(body: .memory(Data([1, 2])))) == nil)
        #expect(reason(flow(body: .file(URL(fileURLWithPath: "/nonexistent/replay.body"), size: 1))) == .bodyOnDisk)
        #expect(reason(flow(body: .memory(Data(repeating: 1, count: 1_048_577)))) == .bodyTooLarge)
        #expect(reason(flow(body: .memory(Data([1])), truncated: true)) == .bodyTruncated)
        #expect(reason(flow(body: .memory(Data(repeating: 1, count: 1_048_576)))) == nil)
        #expect(reason(flow()) == nil)
        var pending = flow(); pending.state = .inProgress
        #expect(reason(pending) == .bodyIncomplete)
        var failed = flow(); failed.state = .failed("interrupted")
        #expect(reason(failed) == .bodyIncomplete)
        var lost = flow(); lost.bytesSent = 1
        #expect(reason(lost) == .bodyIncomplete)
    }
    @Test func originalSnapshotWinsOverLegacyAndActualSend() {
        var f = flow(body: .file(URL(fileURLWithPath: "/not/opened"), size: 2), truncated: true)
        let head = HTTPMessageHead.request(.init(scheme: "https", host: "test", port: 443, method: "POST", pathAndQuery: "/"), headers: [])
        var original = HTTPMessageSnapshot(boundary: .downstreamRequest, head: head, bodyState: .complete, transferState: .finished)
        f.messages[.downstreamRequest] = original
        f.messages[.upstreamRequest] = .init(boundary: .upstreamRequest, head: head, bodyState: .truncated)
        #expect(reason(f) == nil) // Complete empty original request; edited upstream capture is unrelated.
        for state in [HTTPBodyState.pending, .incomplete, .unavailable] {
            original.bodyState = state; f.messages[.downstreamRequest] = original
            #expect(reason(f) == .bodyIncomplete)
        }
        original.bodyState = .truncated; f.messages[.downstreamRequest] = original
        #expect(reason(f) == .bodyTruncated)
        original.bodyState = .complete; original.observedBytes = 1; f.messages[.downstreamRequest] = original
        #expect(reason(f) == .bodyIncomplete)
        original.body = .init(ref: .memory(Data([9, 1, 2])), offset: 1, count: 2)
        original.observedBytes = 2; f.messages[.downstreamRequest] = original
        #expect(reason(f) == nil)
        original.body = .init(ref: .memory(Data([1])), offset: 1, count: 2)
        f.messages[.downstreamRequest] = original
        #expect(reason(f) == .bodyIncomplete)
        original.observedBytes = 1_048_577; f.messages[.downstreamRequest] = original
        #expect(reason(f) == .bodyTooLarge)
    }
    @Test func managedCaptureUsesStorageMetadata() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FlowStore(bodyDirectory: directory)
        for size in [2, 1_048_577] {
            let capture = store.makeBodyCapture(); capture.append(repeatElement(UInt8(1), count: size))
            let body = try #require(capture.finish().body)
            #expect(reason(flow(body: body)) == (size == 2 ? nil : .bodyOnDisk))
            if size > 2 {
                var f = flow()
                let head = HTTPMessageHead.request(.init(scheme: "https", host: "test", port: 443, method: "POST", pathAndQuery: "/"), headers: [])
                f.messages[.downstreamRequest] = .init(boundary: .downstreamRequest, head: head,
                    body: .init(ref: body, offset: 0, count: 1), bodyState: .complete, observedBytes: 1, transferState: .finished)
                #expect(reason(f) == .bodyOnDisk) // Even a small slice of a managed file stays disk-backed.
            }
        }
    }

    // Task 10 added `ComposeImportEligibility`; Replay and Repeat keep their strict rules (spec C4).
    @Test func replayStaysStrictWhereComposeCanImport() {
        let big = flow(body: .memory(Data(repeating: 1, count: 2 * 1_048_576)))
        #expect(reason(big) == .bodyTooLarge)
        if case .importable = ComposeImportEligibility.evaluate(flow: big, boundary: .downstreamRequest) {} else { Issue.record("compose") }
        let disk = flow(body: .file(URL(fileURLWithPath: "/nonexistent/replay.body"), size: 1))
        #expect(reason(disk) == .bodyOnDisk)
        if case .importable = ComposeImportEligibility.evaluate(flow: disk, boundary: .downstreamRequest) {} else { Issue.record("compose") }
        #expect(ComposeEntry.replay(big) == .body(.bodyTooLarge) && ComposeEntry.replay(disk) == .body(.bodyOnDisk))
    }
}
