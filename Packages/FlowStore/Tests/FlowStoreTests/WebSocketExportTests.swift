import Foundation
import Testing
import os
@testable import FlowStore

// Held synchronous sink calls intentionally block executor threads; serialize these fixtures.
@Suite(.serialized) struct WebSocketExportTests {
    @Test func sparseCutoffCountsRetainedRowsNotIDGaps() throws {
        let store = wsStore(); let token = try wsSession(store)
        #expect(try wsPublish(store, token, id: 1) == .accepted)
        #expect(try wsPublish(store, token, id: 10, complete: false) == .accepted)
        #expect(try wsPublish(store, token, id: 100) == .accepted)
        let cutoff = try #require(store.webSocketExportCutoff(token: token))
        #expect(cutoff.retainedAtCutoff == 3 && cutoff.eligibleAtCutoff == 2)
        #expect(cutoff.omittedAtCutoff == 1 && !cutoff.priorEvictionObserved)
        store.endWebSocket(token: token, transport: .init(direction: .clientToServer, at: Date(), monotonic: 1))
        let page = try #require(store.webSocketExportPage(cutoff: cutoff, after: nil, limit: 500))
        #expect(page.rows.map(\.id) == [1, 10, 100])
        #expect(page.rows.map(\.qualification) == [.eligible, .activeAtCutoff, .eligible])
        #expect(page.nextCursor == 100 && page.finished)
    }
    @Test func emptyPayloadIsAvailableAndOmittedRowsDoNotBecomeEvents() async throws {
        let store = wsStore(); let token = try wsSession(store)
        #expect(try wsPublish(store, token, id: 1) == .accepted)
        #expect(try wsPublish(store, token, id: 2, complete: false) == .accepted)
        let url = exportURL(); defer { try? FileManager.default.removeItem(at: url) }
        let result = try await WebSocketJSONLExporter.export(store: store, token: token, to: url)
        #expect(result.exported == 1 && result.omittedAtCutoff == 1 && result.missing == 0)
        #expect(result.status == .partial && result.trailerWritten)
        let lines = try exportLines(url)
        try #require(lines.count == 3)
        #expect(lines[1]["id"] as? Int == 1)
        #expect((lines[1]["application"] as? [String: Any])?["data"] as? String == "")
        #expect((lines[1]["wirePayload"] as? [String: Any])?["unavailableReason"] as? String == "notCaptured")
        #expect((lines[1]["wirePayload"] as? [String: Any])?["data"] == nil)
    }
    @Test func consumerCapSurvivesClearAndFinishReturnsCharges() throws {
        let store = wsStore(); let token = try wsSession(store, content: false)
        var leases: [WebSocketExportLease] = []
        for _ in 0..<8 { leases.append(try store.beginWebSocketExport(token: token)) }
        #expect(throws: WebSocketExportFailure.self) { try store.beginWebSocketExport(token: token) }
        store.clear()
        let fresh = try wsSession(store, content: false)
        #expect(throws: WebSocketExportFailure.self) { try store.beginWebSocketExport(token: fresh) }
        leases.removeLast().finish()
        let next = try store.beginWebSocketExport(token: fresh); next.finish(); next.finish()
        leases.removeAll(); store.clear()
        #expect(store.webSocketBudget.usedBytes(category: .metadata) == 0)
    }
}
func exportURL() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl") }
func exportLines(_ url: URL) throws -> [[String: Any]] {
    try Data(contentsOf: url).split(separator: 10).map { try #require(JSONSerialization.jsonObject(with: Data($0)) as? [String: Any]) }
}

private enum ExportFault: Error, Sendable, Equatable { case write, truncate, seek, close }
private final class ExportTestSink: WebSocketExportSink, Sendable {
    struct State { var writes = 0; var maximum = 0; var closes = 0 }
    let file: WebSocketFileSink
    let state = OSAllocatedUnfairLock(initialState: State())
    let fault: ExportFault?
    let cleanupFault: ExportFault?
    let failWrite: Int
    let onWrite: (@Sendable (Int, Int) -> Void)?
    let onClose: (@Sendable () -> Void)?
    init(_ url: URL, fault: ExportFault? = nil, failWrite: Int = 3, cleanupFault: ExportFault? = nil, onClose: (@Sendable () -> Void)? = nil, onWrite: (@Sendable (Int, Int) -> Void)? = nil) throws {
        file = try WebSocketFileSink(url: url); self.fault = fault; self.cleanupFault = cleanupFault; self.failWrite = failWrite; self.onWrite = onWrite; self.onClose = onClose
    }
    func write(_ bytes: Data) throws {
        let index = state.withLock { s in s.writes += 1; s.maximum = max(s.maximum, bytes.count); return s.writes }
        onWrite?(index, bytes.count)
        if fault == .write && index == failWrite {
            try file.write(Data(bytes.prefix(7))); throw ExportFault.write
        }
        try file.write(bytes)
    }
    func truncate(at offset: UInt64) throws { if fault == .truncate || cleanupFault == .truncate { throw ExportFault.truncate }; try file.truncate(at: offset) }
    func seek(to offset: UInt64) throws { if fault == .seek || cleanupFault == .seek { throw ExportFault.seek }; try file.seek(to: offset) }
    func close() throws { state.withLock { $0.closes += 1 }; onClose?(); try file.close(); if fault == .close || cleanupFault == .close { throw ExportFault.close } }
}
private func exportPublish(_ store: FlowStore, _ token: WebSocketSessionToken, id: UInt64,
                           application: Data? = nil, wire: Data? = nil,
                           edit: (inout WebSocketEventMetadata) -> Void = { _ in }) throws {
    let stamp = try #require(store.webSocketCaptureStamp(token: token))
    var metadata = WebSocketEventMetadata(id: id, order: .init(ingressSequence: stamp.ingressSequence, offset: 7), direction: .clientToServer, kind: .text)
    metadata.firstObservedAt = Date(timeIntervalSince1970: 1_700_000_000.125)
    metadata.lastObservedAt = Date(timeIntervalSince1970: 1_700_000_000.250)
    metadata.completedAt = Date(timeIntervalSince1970: 1_700_000_000.375)
    metadata.utf8 = .valid; metadata.decodedBytes = UInt64(application?.count ?? 0); metadata.wirePayloadBytes = UInt64(wire?.count ?? 0)
    edit(&metadata)
    func payload(_ bytes: Data?, kind: WebSocketPayloadKind) throws -> WebSocketOwnedPayload? {
        guard let bytes else { return nil }
        let accumulator = try #require(store.makeWebSocketAccumulator(token: token, eventID: id, epoch: stamp.epoch, kind: kind))
        #expect(accumulator.append(bytes, expectedEpoch: stamp.epoch))
        return accumulator.take(kind: kind, complete: metadata.completedAt != nil, truncated: metadata.integrity == .captureTruncated)
    }
    let app = try payload(application, kind: .application), raw = try payload(wire, kind: .wirePayload)
    #expect(store.publishWebSocket(.init(metadata: metadata, stamp: stamp, application: app, wirePayload: raw), token: token, captureEpoch: stamp.epoch) == .accepted)
}
private func assertScalarEnd(_ line: [String: Any]) {
    #expect(Set(line.keys) == Set(["schemaVersion", "type", "status", "reason", "exported", "omittedAtCutoff", "missing", "lowerBound", "rangesUnavailable"]))
    #expect(line["type"] as? String == "end" && line["rangesUnavailable"] as? Bool == true)
}

extension WebSocketExportTests {
    @Test(arguments: [1, 2, 3, 7, 262_144])
    func binaryAndCompressedPrefixesRoundTripAcrossReaderBoundaries(chunk: Int) async throws {
        var limits = WebSocketLimits(); limits.readerPayloadBytes = chunk
        let store = wsStore(limits); let token = try wsSession(store)
        let application = Data((0..<1003).map { UInt8($0 % 256) }), wire = Data([255, 0, 1, 7, 19])
        try exportPublish(store, token, id: 1, application: application, wire: wire) { $0.compressed = true; $0.kind = .binary }
        let url = exportURL(); defer { try? FileManager.default.removeItem(at: url) }
        let maximumRead = OSAllocatedUnfairLock(initialState: 0)
        let sink = try ExportTestSink(url)
        let result = try await WebSocketJSONLExporter.export(store: store, token: token, sink: sink) { stage in
            if case .read(let count) = stage { maximumRead.withLock { $0 = max($0, count) } }
        }
        #expect(result.status == .complete && result.exported == 1)
        let row = try #require(try exportLines(url).first { $0["type"] as? String == "event" })
        let app = try #require(row["application"] as? [String: Any]), raw = try #require(row["wirePayload"] as? [String: Any])
        #expect(Data(base64Encoded: try #require(app["data"] as? String)) == application)
        #expect(Data(base64Encoded: try #require(raw["data"] as? String)) == wire)
        #expect(row["text"] == nil)
        #expect(row["firstObservedAt"] as? String == "2023-11-14T22:13:20.125Z")
        #expect(row["completedAt"] as? String == "2023-11-14T22:13:20.375Z")
        #expect(maximumRead.withLock { $0 } <= min(chunk, 262_144))
        #expect(sink.state.withLock { $0.maximum <= 32_768 && $0.closes == 1 })
    }
    @Test(arguments: ["valid", "large", "truncated", "invalid", "opaque", "abandoned", "lowerBound", "malformed"])
    func optionalTextRequiresEveryCompletenessFact(mode: String) async throws {
        let store = wsStore(); let token = try wsSession(store)
        var bytes = Data(String(repeating: "😀", count: 65_536).utf8)
        if mode == "large" { bytes.append(65) }
        if mode == "malformed" { bytes[0] = 255 }
        try exportPublish(store, token, id: 1, application: bytes) { row in
            switch mode {
            case "truncated": row.integrity = .captureTruncated
            case "invalid": row.utf8 = .invalid
            case "opaque": row.integrity = .opaque
            case "abandoned": row.completedAt = nil; row.captureAbandoned = true
            case "lowerBound": row.lowerBound = true
            default: break
            }
        }
        let url = exportURL(); defer { try? FileManager.default.removeItem(at: url) }
        let result = try await WebSocketJSONLExporter.export(store: store, token: token, to: url)
        #expect(result.exported == 1)
        let row = try #require(try exportLines(url).first { $0["type"] as? String == "event" })
        if mode == "valid" { #expect((row["text"] as? String)?.utf8.count == 262_144) }
        else { #expect(row["text"] == nil) }
        if mode == "abandoned" { #expect(row["completedAt"] is NSNull && row["captureAbandoned"] as? Bool == true) }
    }
    @Test func activeAtAdmissionFinishesAfterManifestButStaysOmitted() async throws {
        let store = wsStore(); let token = try wsSession(store)
        try exportPublish(store, token, id: 1, application: Data())
        try exportPublish(store, token, id: 10) { $0.completedAt = nil }
        let url = exportURL(); defer { try? FileManager.default.removeItem(at: url) }
        let sink = try ExportTestSink(url)
        let result = try await WebSocketJSONLExporter.export(store: store, token: token, sink: sink) { stage in
            if case .page = stage { store.endWebSocket(token: token, transport: .init(direction: .clientToServer, at: Date(), monotonic: 7)) }
        }
        #expect(result.omittedAtCutoff == 1 && result.exported == 1 && result.missing == 0)
        #expect(try exportLines(url).compactMap { $0["id"] as? Int } == [1])
    }
    @Test(arguments: ["manifest", "metadata", "application", "wirePayload", "text", "newline", "end"])
    func clearAtEverySerializerBoundaryRollsBackAndWritesOnlyScalarEnd(at: String) async throws {
        let store = wsStore(); let token = try wsSession(store)
        try exportPublish(store, token, id: 1, application: Data("hello".utf8), wire: Data([9]))
        let once = OSAllocatedUnfairLock(initialState: false)
        let url = exportURL(); defer { try? FileManager.default.removeItem(at: url) }
        let sink = try ExportTestSink(url)
        let result = try await WebSocketJSONLExporter.export(store: store, token: token, sink: sink) { stage in
            let name: String
            switch stage {
            case .manifest: name = "manifest"
            case .metadata: name = "metadata"
            case .application: name = "application"
            case .wirePayload: name = "wirePayload"
            case .text: name = "text"
            case .newline: name = "newline"
            case .end: name = "end"
            default: name = ""
            }
            if name == at && once.withLock({ value in let old = value; value = true; return !old }) { store.clear() }
        }
        #expect(result.status == .cancelled && result.trailerWritten)
        let lines = try exportLines(url); assertScalarEnd(try #require(lines.last))
        #expect(result.exported == (at == "end" ? 1 : 0))
        #expect(result.missing == (at == "end" ? 0 : 1))
        #expect(sink.state.withLock { $0.closes == 1 })
        #expect(store.webSocketBudget.usedBytes(category: .metadata) == 0)
    }
    @Test(arguments: [ExportFault.write, .truncate, .seek, .close])
    private func throwingSinkPreservesPrimaryErrorAndCloses(fault: ExportFault) async throws {
        let store = wsStore(); let token = try wsSession(store)
        try exportPublish(store, token, id: 1, application: Data(repeating: 65, count: 100_000))
        let url = exportURL(); defer { try? FileManager.default.removeItem(at: url) }
        let sink = try ExportTestSink(url, fault: fault)
        do {
            _ = try await WebSocketJSONLExporter.export(store: store, token: token, sink: sink) { stage in
                if fault == .truncate || fault == .seek, case .application = stage { store.clear() }
            }
            Issue.record("Expected typed sink failure")
        } catch let failure as WebSocketExportFailure {
            #expect(failure.reason == .io && failure.underlying as? ExportFault == fault)
            let progress = try #require(failure.progress)
            #expect(progress.evidence.count <= 32)
            if fault == .write { #expect(progress.exported == 0 && progress.missing == 1 && progress.trailerWritten) }
            if fault == .truncate || fault == .seek { #expect(!progress.trailerWritten && progress.status == .cancelled) }
            if fault == .close { #expect(progress.status == .partial && progress.exported == 1 && progress.trailerWritten) }
        }
        #expect(sink.state.withLock { $0.closes == 1 })
        store.clear(); #expect(store.webSocketBudget.usedBytes(category: .metadata) == 0)
    }
    @Test func largeCanonicalMetadataAndPageOwnersKeepTheirExactChargesAcrossClear() throws {
        let store = wsStore(); let id = store.begin { Flow(id: $0, scheme: "https", method: "GET", host: "test", port: 443, path: "/") }
        let token = try #require(store.beginWebSocket(flowID: id, handshake: .init(requestHeaders: [.init(name: "X", value: String(repeating: "中", count: 30_000))], requestURI: "/original")))
        try exportPublish(store, token, id: 1, application: Data([1]))
        var lease: WebSocketExportLease? = try store.beginWebSocketExport(token: token)
        let cutoff = try #require(store.webSocketExportCutoff(token: token))
        var page: WebSocketExportPage? = try #require(store.webSocketExportPage(cutoff: cutoff, after: nil, limit: 1))
        var descriptor = page?.rows.first; page = nil
        let rowCharge = store.state.withLock { $0.webSockets.session(token)!.events[1]!.charge.bytes }
        let shared = store.state.withLock { $0.webSockets.session(token)!.handshakeCharge.bytes + 512 }
        store.clear()
        #expect(store.webSocketBudget.usedBytes(category: .retained) == 0)
        #expect(store.webSocketBudget.usedBytes(category: .metadata) == 8192 + shared + rowCharge + 128)
        lease?.finish(); lease = nil
        #expect(store.webSocketBudget.usedBytes(category: .metadata) == rowCharge + 128)
        #expect(descriptor?.id == 1); descriptor = nil
        #expect(store.webSocketBudget.usedBytes(category: .metadata) == 0)
        #expect(cutoff.retainedAtCutoff == 1)
    }
    @Test func largeUnicodeManifestRepeatedHeadersAndFragmentPagesStreamWithinWriteCap() async throws {
        var limits = WebSocketLimits(); limits.pageRows = 17
        let store = wsStore(limits)
        let id = store.begin { Flow(id: $0, scheme: "https", method: "GET", host: "test", port: 443, path: "/") }
        let uri = "/" + String(repeating: "中😀\"\n", count: 10_000)
        let headers = [HeaderField(name: "X", value: uri), HeaderField(name: "X", value: "second")]
        let token = try #require(store.beginWebSocket(flowID: id, handshake: .init(requestHeaders: headers, requestURI: uri)))
        for id in 1...201 { try exportPublish(store, token, id: UInt64(id)) { row in
            row.fragmentCount = 64
            row.fragments = (0..<64).map { .init(opcode: UInt8($0 % 2), fin: $0 == 63, rsv: 0, masked: true, length: 3, observedAt: row.firstObservedAt) }
        } }
        let url = exportURL(); defer { try? FileManager.default.removeItem(at: url) }
        let sink = try ExportTestSink(url), maxPage = OSAllocatedUnfairLock(initialState: 0)
        let result = try await WebSocketJSONLExporter.export(store: store, token: token, sink: sink) { if case .page(let count) = $0 { maxPage.withLock { $0 = max($0, count) } } }
        #expect(result.status == .complete && result.exported == 201)
        let manifest = try #require(try exportLines(url).first), handshake = try #require(manifest["handshake"] as? [String: Any])
        #expect(handshake["requestURI"] as? String == uri)
        #expect(handshake["requestHeaders"] as? [[String: String]] == [["name": "X", "value": uri], ["name": "X", "value": "second"]])
        #expect(sink.state.withLock { $0.maximum } == 32_768 && maxPage.withLock { $0 } == 17)
    }
    @Test func ordinalExhaustionLatchesAcrossClearAndExistingConsumer() throws {
        let store = wsStore(); let token = try wsSession(store)
        try exportPublish(store, token, id: 1)
        let lease = try store.beginWebSocketExport(token: token)
        store.state.withLock { $0.webSockets.revision = .max - 1 }
        store.recordWebSocketState(.observedBytes(direction: .clientToServer, wire: 1, application: 0, lowerBound: false), token: token)
        #expect(store.webSocketExportCutoff(token: token) == nil)
        #expect(store.webSocketExportProgress(lease.core, trailer: false).status == .cancelled)
        lease.finish(); store.clear()
        let next = try wsSession(store)
        #expect(throws: WebSocketExportFailure.self) { try store.beginWebSocketExport(token: next) }
        #expect(store.webSocketExportCutoff(token: next) == nil)
    }
    @Test func unrelatedSummaryChangesDoNotInvalidateEligibleEvent() async throws {
        let store = wsStore(); let token = try wsSession(store)
        try exportPublish(store, token, id: 1, application: Data([65]))
        let url = exportURL(); defer { try? FileManager.default.removeItem(at: url) }
        let result = try await WebSocketJSONLExporter.export(store: store, token: token, sink: ExportTestSink(url)) { stage in
            if case .metadata = stage { store.recordWebSocketState(.observedBytes(direction: .serverToClient, wire: 8, application: 4, lowerBound: false), token: token) }
        }
        #expect(result.status == .complete && result.exported == 1)
    }
    @Test func priorEvictionIsUncertaintyNotSparseInventedRange() async throws {
        var limits = WebSocketLimits(); limits.sessionEvents = 2
        let store = wsStore(limits); let token = try wsSession(store)
        for id in [UInt64(1), 10, 100] { try exportPublish(store, token, id: id, application: Data()) }
        let url = exportURL(); defer { try? FileManager.default.removeItem(at: url) }
        let result = try await WebSocketJSONLExporter.export(store: store, token: token, to: url)
        #expect(result.status == .partial && result.exported == 2 && result.missing == 0)
        #expect(result.cutoff.priorEvictionObserved && result.evidence.isEmpty && result.unknown.isEmpty)
        #expect(try exportLines(url).compactMap { $0["id"] as? Int } == [10, 100])
    }
    @Test func tenThousandEventsEightMiBHasBoundedActualReadsPagesWrites() async throws {
        let store = wsStore(); let token = try wsSession(store)
        // 9,999*838 + 9,446 = exactly 8 MiB, retained concurrently.
        for id in 1...10_000 { try exportPublish(store, token, id: UInt64(id), application: Data(repeating: 65, count: id == 10_000 ? 9_446 : 838)) { $0.kind = .binary } }
        #expect(store.webSocketBudget.usedBytes(category: .retained) == 8_388_608)
        let url = exportURL(); defer { try? FileManager.default.removeItem(at: url) }
        let metrics = OSAllocatedUnfairLock(initialState: (page: 0, read: 0)), sink = try ExportTestSink(url)
        let result = try await WebSocketJSONLExporter.export(store: store, token: token, sink: sink) { stage in
            metrics.withLock { value in
                if case .page(let count) = stage { value.page = max(value.page, count) }
                if case .read(let count) = stage { value.read = max(value.read, count) }
            }
        }
        #expect(result.exported == 10_000 && result.status == .complete)
        #expect(metrics.withLock { $0.page == 200 && $0.read <= 262_144 })
        #expect(sink.state.withLock { $0.maximum <= 32_768 })
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var pending = Data(), count = 0
        while let bytes = try handle.read(upToCount: 16_384), !bytes.isEmpty {
            pending.append(bytes)
            while let newline = pending.firstIndex(of: 10) {
                let line = pending.prefix(upTo: newline)
                let object = try #require(JSONSerialization.jsonObject(with: Data(line)) as? [String: Any])
                if object["type"] as? String == "event" { count += 1; #expect(object["id"] as? Int == count) }
                pending.removeSubrange(...newline)
            }
        }
        #expect(count == 10_000 && pending.isEmpty)
        print("Task5 measured 10000 events; retained=8388608; page=\(metrics.withLock { $0.page }); read=\(metrics.withLock { $0.read }); write=\(sink.state.withLock { $0.maximum })")
    }
}

extension WebSocketExportTests {
    @Test(arguments: ["clear", "flowEviction", "eventEviction", "closedPause", "newline"])
    func actualWriterBarrierWaitsExecutingWriteAndRejectsNextWrite(mutation: String) async throws {
        var limits = WebSocketLimits(); limits.sessionEvents = mutation == "eventEviction" ? 1 : 10_000
        let store = wsStore(limits, maxFlows: mutation == "flowEviction" ? 1 : 1000), token = try wsSession(store)
        try exportPublish(store, token, id: 1, application: Data(repeating: 65, count: mutation == "newline" ? 1 : 100_000)) { row in
            if mutation == "closedPause" { row.completedAt = nil; row.captureAbandoned = true; row.integrity = .incompleteTransport }
        }
        if mutation == "closedPause" {
            for direction in [WebSocketDirection.clientToServer, .serverToClient] {
                store.endWebSocket(token: token, transport: .init(direction: direction, at: Date(), monotonic: 1))
            }
        }
        let inWrite = DispatchSemaphore(value: 0), releaseWrite = DispatchSemaphore(value: 0)
        let logicalInvalidation = DispatchSemaphore(value: 0), mutationDone = DispatchSemaphore(value: 0)
        let completed = OSAllocatedUnfairLock(initialState: false)
        store.state.withLock { $0.webSockets.exportDrainProbe = { logicalInvalidation.signal() } }
        let url = exportURL(); defer { try? FileManager.default.removeItem(at: url) }
        let sink = try ExportTestSink(url, onWrite: { index, _ in
            if index == (mutation == "newline" ? 4 : 3) { inWrite.signal(); releaseWrite.wait() }
        })
        let exporter = Task.detached { try await WebSocketJSONLExporter.export(store: store, token: token, sink: sink) }
        #expect(await exportWait(inWrite))
        DispatchQueue.global().async {
            switch mutation {
            case "flowEviction": _ = store.begin { Flow(id: $0, scheme: "http", method: "GET", host: "next", port: 80, path: "/") }
            case "eventEviction": do { try exportPublish(store, token, id: 2) } catch { Issue.record(error) }
            case "closedPause": store.setWebSocketRecording(enabled: false, revision: 1)
            default: store.clear()
            }
            completed.withLock { $0 = true }; mutationDone.signal()
        }
        #expect(await exportWait(logicalInvalidation))
        #expect(completed.withLock { !$0 })
        releaseWrite.signal()
        #expect(await exportWait(mutationDone))
        let result = try await exporter.value
        #expect(result.exported == 0 && result.missing == 1 && result.trailerWritten)
        #expect(result.status == (mutation == "eventEviction" || mutation == "closedPause" ? .partial : .cancelled))
        let lines = try exportLines(url); #expect(lines.count == 2); assertScalarEnd(try #require(lines.last))
        store.state.withLock { $0.webSockets.exportDrainProbe = nil }
        store.clear(); #expect(store.webSocketBudget.usedBytes(category: .metadata) == 0)
    }
    @Test func logicalInvalidationStopsWriteBeforeDrainCallbackAcquiresGate() async throws {
        let store = wsStore(), token = try wsSession(store)
        try exportPublish(store, token, id: 1, application: Data([1]))
        let beforeRead = DispatchSemaphore(value: 0), resumeRead = DispatchSemaphore(value: 0)
        let beforeDrain = DispatchSemaphore(value: 0), resumeDrain = DispatchSemaphore(value: 0), cleared = DispatchSemaphore(value: 0)
        store.state.withLock { $0.webSockets.exportDrainProbe = { beforeDrain.signal(); resumeDrain.wait() } }
        let url = exportURL(); defer { try? FileManager.default.removeItem(at: url) }
        let exporter = Task.detached {
            try await WebSocketJSONLExporter.export(store: store, token: token, sink: ExportTestSink(url)) { stage in
                if case .application = stage { beforeRead.signal(); resumeRead.wait() }
            }
        }
        #expect(await exportWait(beforeRead))
        DispatchQueue.global().async { store.clear(); cleared.signal() }
        #expect(await exportWait(beforeDrain))
        resumeRead.signal()
        let result = try await exporter.value
        #expect(result.status == .cancelled && result.exported == 0)
        assertScalarEnd(try #require(try exportLines(url).last))
        resumeDrain.signal(); #expect(await exportWait(cleared))
        store.state.withLock { $0.webSockets.exportDrainProbe = nil }
        #expect(store.webSocketBudget.usedBytes(category: .metadata) == 0)
    }
    @Test(arguments: ["manifest", "metadata", "application", "wirePayload", "text", "newline", "end"])
    func taskCancellationAtEveryBoundaryUsesExistingCoreAndCloses(at: String) async throws {
        let store = wsStore(), token = try wsSession(store)
        try exportPublish(store, token, id: 1, application: Data("😀".utf8), wire: Data([1, 2]))
        let entered = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0), once = OSAllocatedUnfairLock(initialState: false)
        let url = exportURL(); defer { try? FileManager.default.removeItem(at: url) }
        let sink = try ExportTestSink(url)
        let exporter = Task.detached {
            try await WebSocketJSONLExporter.export(store: store, token: token, sink: sink) { stage in
                let name: String
                switch stage {
                case .manifest: name = "manifest"
                case .metadata: name = "metadata"
                case .application: name = "application"
                case .wirePayload: name = "wirePayload"
                case .text: name = "text"
                case .newline: name = "newline"
                case .end: name = "end"
                default: name = ""
                }
                if name == at && once.withLock({ value in let old = value; value = true; return !old }) { entered.signal(); resume.wait() }
            }
        }
        #expect(await exportWait(entered))
        exporter.cancel(); resume.signal()
        let result = try await exporter.value
        #expect(result.status == .cancelled && result.trailerWritten)
        #expect(result.exported == (at == "end" ? 1 : 0))
        assertScalarEnd(try #require(try exportLines(url).last))
        #expect(sink.state.withLock { $0.closes == 1 })
        store.clear(); #expect(store.webSocketBudget.usedBytes(category: .metadata) == 0)
    }
    @Test func initialAndFinalEvidenceReductionIsBoundedIndependentAndExact() async throws {
        var limits = WebSocketLimits(); limits.sessionEvents = 128
        let store = wsStore(limits), token = try wsSession(store)
        for id in 1...128 { try exportPublish(store, token, id: UInt64(id * 10)) { if id % 2 == 0 { $0.completedAt = nil } } }
        let url = exportURL(); defer { try? FileManager.default.removeItem(at: url) }
        let result = try await WebSocketJSONLExporter.export(store: store, token: token, sink: ExportTestSink(url)) { stage in
            if case .page = stage {
                for id in 1...64 { do { try exportPublish(store, token, id: UInt64(2000 + id)) } catch { Issue.record(error) } }
            }
        }
        #expect(result.status == .partial && result.exported == 0 && result.omittedAtCutoff == 64 && result.missing == 64)
        #expect(result.evidence.count + result.unknown.count <= 32)
        #expect(!result.rangesComplete)
        #expect(result.evidence.reduce(UInt64(0)) { $0 + $1.count } + result.unknown.reduce(UInt64(0)) { $0 + $1.unknownIDCount } == 128)
        let ids = result.evidence.flatMap { Array($0.firstID...$0.lastID) }
        #expect(ids.count == Set(ids).count)
        store.clear(); #expect(store.webSocketBudget.usedBytes(category: .metadata) == 0)
        #expect(result.cutoff.retainedAtCutoff == 128 && result.evidence.first?.firstID == 20)
    }
    @Test func openingDestinationFailureIsTypedAndReleasesConsumer() async throws {
        let store = wsStore(), token = try wsSession(store)
        let bad = exportURL().appendingPathComponent("missing.jsonl")
        do { _ = try await WebSocketJSONLExporter.export(store: store, token: token, to: bad); Issue.record("Expected I/O failure") }
        catch let error as WebSocketExportFailure { #expect(error.reason == .io && error.progress?.trailerWritten == false) }
        store.clear(); #expect(store.webSocketBudget.usedBytes(category: .metadata) == 0)
    }
}

private func exportWait(_ semaphore: DispatchSemaphore) async -> Bool {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async { continuation.resume(returning: semaphore.wait(timeout: .now() + 10) == .success) }
    }
}

extension WebSocketExportTests {
    @Test func firstEvictedRowDoesNotLabelUnprocessedSuffixAsEvicted() async throws {
        var limits = WebSocketLimits(); limits.sessionEvents = 3
        let store = wsStore(limits), token = try wsSession(store)
        for id in 1...3 { try exportPublish(store, token, id: UInt64(id)) }
        let url = exportURL(); defer { try? FileManager.default.removeItem(at: url) }
        let result = try await WebSocketJSONLExporter.export(store: store, token: token, sink: ExportTestSink(url)) { stage in
            if case .page = stage { do { try exportPublish(store, token, id: 4) } catch { Issue.record(error) } }
        }
        #expect(result.exported == 0 && result.missing == 3)
        #expect(result.evidence == [.init(cause: .evicted, firstID: 1, lastID: 1, count: 1)])
        #expect(result.unknown == [.init(cause: .unprocessed, unknownIDCount: 2)])
    }
    @Test(arguments: ["manifest", "application", "wirePayload", "text", "end"])
    func cancellationAfterPartialDiskWriteRollsBackWholeLine(at: String) async throws {
        var limits = WebSocketLimits(); limits.wirePrefixBytes = 100_000
        let store = wsStore(limits)
        let flow = store.begin { Flow(id: $0, scheme: "https", method: "GET", host: "x", port: 443, path: "/") }
        let token = try #require(store.beginWebSocket(flowID: flow, handshake: .init(requestURI: String(repeating: "中", count: 40_000))))
        try exportPublish(store, token, id: 1, application: Data(repeating: 65, count: 100_000), wire: Data(repeating: 66, count: 100_000))
        let entered = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0)
        let state = OSAllocatedUnfairLock(initialState: (phase: "", held: false))
        let url = exportURL(); defer { try? FileManager.default.removeItem(at: url) }
        let exporter = Task.detached {
            try await WebSocketJSONLExporter.export(store: store, token: token, sink: ExportTestSink(url)) { stage in
                let hold = state.withLock { state in
                    switch stage {
                    case .manifest: state.phase = "manifest"
                    case .application: state.phase = "application"
                    case .wirePayload: state.phase = "wirePayload"
                    case .text: state.phase = "text"
                    case .end: state.phase = "end"
                    case .written:
                        if state.phase == at && !state.held { state.held = true; return true }
                    default: break
                    }
                    return false
                }
                if hold { entered.signal(); resume.wait() }
            }
        }
        #expect(await exportWait(entered)); exporter.cancel(); resume.signal()
        let result = try await exporter.value
        #expect(result.status == .cancelled && result.trailerWritten && result.exported == (at == "end" ? 1 : 0))
        let lines = try exportLines(url); assertScalarEnd(try #require(lines.last))
        #expect(lines.count == (at == "manifest" ? 1 : (at == "end" ? 3 : 2)))
        store.clear(); #expect(store.webSocketBudget.usedBytes(category: .metadata) == 0)
    }
}

extension WebSocketExportTests {
    @Test(arguments: ["publish", "pause", "stop", "release", "EOF"])
    func everyTerminalMutationUsesPrivateOrdinalAndNeverPromotesOldCutoff(mode: String) throws {
        let store = wsStore(), token = try wsSession(store)
        let stamp = try #require(store.webSocketCaptureStamp(token: token))
        var row = WebSocketEventMetadata(id: 10, order: .init(ingressSequence: stamp.ingressSequence, offset: 0), direction: .clientToServer, kind: .binary)
        #expect(store.publishWebSocket(.init(metadata: row, stamp: stamp), token: token, captureEpoch: stamp.epoch) == .accepted)
        let cutoff = try #require(store.webSocketExportCutoff(token: token))
        switch mode {
        case "publish": row.completedAt = Date(); #expect(store.publishWebSocket(.init(metadata: row, stamp: stamp), token: token, captureEpoch: stamp.epoch) == .accepted)
        case "pause": store.setWebSocketRecording(enabled: false, revision: 1)
        case "stop": store.recordWebSocketState(.capture(direction: .clientToServer, state: .contentStoppedUntilReconnect, diagnostic: nil), token: token)
        case "release": store.releaseWebSocketObservation(token: token)
        default: store.endWebSocket(token: token, transport: .init(direction: .clientToServer, at: Date(), monotonic: 9))
        }
        let old = try #require(store.webSocketExportPage(cutoff: cutoff, after: nil, limit: 1))
        #expect(old.rows.first?.qualification == .activeAtCutoff)
        let current = try #require(store.webSocketExportCutoff(token: token))
        #expect(cutoff.omittedAtCutoff == 1 && current.eligibleAtCutoff == 1 && current.omittedAtCutoff == 0)
        let ordinals = try #require(store.state.withLock { state in state.webSockets.session(token)?.events[10].map { ($0.lastChangeOrdinal, $0.firstCaptureTerminalOrdinal) } })
        #expect(ordinals.0 > cutoff.revision && ordinals.1 == ordinals.0 && ordinals.0 <= current.revision)
    }
    @Test(arguments: ["closed", "joined", "paused", "stopped", "metadataOnly"])
    func consumerAdmissionIsIndependentOfProducerWorker(mode: String) throws {
        let store = wsStore(), token = try wsSession(store, content: mode != "metadataOnly")
        let calls = OSAllocatedUnfairLock(initialState: 0)
        if mode != "metadataOnly" { #expect(store.registerWebSocketCancellation(token: token) { calls.withLock { $0 += 1 } }) }
        switch mode {
        case "closed":
            for direction in [WebSocketDirection.clientToServer, .serverToClient] { store.endWebSocket(token: token, transport: .init(direction: direction, at: Date(), monotonic: 1)) }
        case "joined": store.releaseWebSocketObservation(token: token)
        case "paused": store.setWebSocketRecording(enabled: false, revision: 1)
        case "stopped": store.recordWebSocketState(.capture(direction: .clientToServer, state: .contentStoppedUntilReconnect, diagnostic: nil), token: token)
        default: break
        }
        let before = calls.withLock { $0 }, metadataBefore = store.webSocketBudget.usedBytes(category: .metadata)
        let lease = try store.beginWebSocketExport(token: token)
        #expect(store.webSocketBudget.usedBytes(category: .metadata) == metadataBefore + 8192)
        lease.finish(); lease.finish()
        #expect(calls.withLock { $0 } == before)
        #expect(store.webSocketBudget.usedBytes(category: .metadata) == metadataBefore)
        store.clear()
        #expect(calls.withLock { $0 } == before + ((mode == "paused" || mode == "stopped") ? 1 : 0))
    }
    @Test func concurrentFinishAndRepeatedClearDoNotFreeSlotsBeforeFinish() async throws {
        let store = wsStore(), token = try wsSession(store)
        let leases = try (0..<8).map { _ in try store.beginWebSocketExport(token: token) }
        store.clear(); store.clear()
        let fresh = try wsSession(store)
        #expect(throws: WebSocketExportFailure.self) { try store.beginWebSocketExport(token: fresh) }
        await withCheckedContinuation { continuation in
            let group = DispatchGroup()
            for lease in leases {
                for _ in 0..<2 { group.enter(); DispatchQueue.global().async { lease.finish(); group.leave() } }
            }
            group.enter(); DispatchQueue.global().async { store.clear(); group.leave() }
            group.notify(queue: .global()) { continuation.resume() }
        }
        #expect(store.webSocketBudget.usedBytes(category: .metadata) == 0)
        let current = try wsSession(store), replacement = try store.beginWebSocketExport(token: current)
        replacement.finish(); store.clear()
        #expect(store.webSocketBudget.usedBytes(category: .metadata) == 0)
    }
    @Test(arguments: [false, true])
    func manifestPreservesUnknownAndActualEmptyURI(empty: Bool) async throws {
        let store = wsStore(); let id = store.begin { Flow(id: $0, scheme: "http", method: "GET", host: "x", port: 80, path: "/") }
        let token = try #require(store.beginWebSocket(flowID: id, handshake: .init(requestURI: empty ? "" : nil)))
        let url = exportURL(); defer { try? FileManager.default.removeItem(at: url) }
        _ = try await WebSocketJSONLExporter.export(store: store, token: token, to: url)
        let handshake = try #require(try exportLines(url).first?["handshake"] as? [String: Any])
        if empty { #expect(handshake["requestURI"] as? String == "") }
        else { #expect(handshake["requestURI"] is NSNull) }
    }
    @Test func fullPrefixUsesActual256KiBReadsAndIndependentWireBase64() async throws {
        let store = wsStore(), token = try wsSession(store)
        let bytes = Data(repeating: 255, count: 1_048_576), wire = Data(repeating: 127, count: 65_536)
        try exportPublish(store, token, id: 1, application: bytes, wire: wire) { $0.kind = .binary; $0.compressed = true }
        let url = exportURL(); defer { try? FileManager.default.removeItem(at: url) }
        let reads = OSAllocatedUnfairLock(initialState: 0), sink = try ExportTestSink(url)
        let result = try await WebSocketJSONLExporter.export(store: store, token: token, sink: sink) {
            if case .read(let count) = $0 { reads.withLock { $0 = max($0, count) } }
        }
        #expect(result.status == .complete && reads.withLock { $0 } == 262_144)
        let event = try #require(try exportLines(url).first { $0["type"] as? String == "event" })
        let app = try #require(event["application"] as? [String: Any]), raw = try #require(event["wirePayload"] as? [String: Any])
        #expect(Data(base64Encoded: try #require(app["data"] as? String)) == bytes)
        #expect(Data(base64Encoded: try #require(raw["data"] as? String)) == wire)
        #expect(sink.state.withLock { $0.maximum } == 32_768)
        print("Task5 full prefix measured read=262144/write=32768; application=1048576/wire=65536")
    }
    @Test func cancellationAndTruncateFailureRetainsIndependentProgress() async throws {
        let store = wsStore(), token = try wsSession(store)
        try exportPublish(store, token, id: 1, application: Data([65]))
        let entered = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0)
        let url = exportURL(); defer { try? FileManager.default.removeItem(at: url) }
        let sink = try ExportTestSink(url, fault: .truncate)
        let exporter = Task.detached {
            try await WebSocketJSONLExporter.export(store: store, token: token, sink: sink) { stage in
                if case .application = stage { entered.signal(); resume.wait() }
            }
        }
        #expect(await exportWait(entered)); exporter.cancel(); resume.signal()
        var progress: WebSocketExportResult?
        do { _ = try await exporter.value; Issue.record("Expected cancellation plus I/O error") }
        catch let failure as WebSocketExportFailure {
            #expect(failure.underlying as? ExportFault == .truncate); progress = failure.progress
        }
        #expect(progress?.status == .cancelled && progress?.trailerWritten == false && progress?.missing == 1)
        store.clear(); #expect(store.webSocketBudget.usedBytes(category: .metadata) == 0)
        #expect(progress?.cutoff.eligibleAtCutoff == 1 && sink.state.withLock { $0.closes == 1 })
    }
    @Test(arguments: ["page", "reader", "metadata"])
    func invalidPolicyOrConsumerChargeRefusesWithoutDegradingCapture(policy: String) throws {
        var limits = WebSocketLimits()
        if policy == "page" { limits.pageRows = 0 }
        if policy == "reader" { limits.readerPayloadBytes = -1 }
        if policy == "metadata" { limits.metadataBytes = 5000 }
        let store = wsStore(limits), token = try wsSession(store)
        let before = store.webSocketSummary(token: token)
        #expect(throws: WebSocketExportFailure.self) { try store.beginWebSocketExport(token: token) }
        #expect(store.webSocketSummary(token: token) == before)
        store.clear(); #expect(store.webSocketBudget.usedBytes(category: .metadata) == 0)
    }
}

extension WebSocketExportTests {
    @Test func alreadyRevokedClosedPrefixExportsUnavailableAtBindingNotEmpty() async throws {
        let store = wsStore(), token = try wsSession(store)
        try exportPublish(store, token, id: 1, application: Data([65])) { $0.completedAt = nil; $0.captureAbandoned = true; $0.integrity = .incompleteTransport }
        for direction in [WebSocketDirection.clientToServer, .serverToClient] { store.endWebSocket(token: token, transport: .init(direction: direction, at: Date(), monotonic: 1)) }
        let beforePause = try #require(store.webSocketExportCutoff(token: token))
        store.setWebSocketRecording(enabled: false, revision: 1)
        #expect(store.webSocketPayload(token: token, eventID: 1, kind: .application, maxBytes: 1) == nil)
        let changed = try #require(store.webSocketExportPage(cutoff: beforePause, after: nil, limit: 1))
        #expect(changed.rows.first?.qualification == .changedAfterCutoff)
        let url = exportURL(); defer { try? FileManager.default.removeItem(at: url) }
        let result = try await WebSocketJSONLExporter.export(store: store, token: token, to: url)
        #expect(result.status == .complete && result.exported == 1 && result.missing == 0)
        let event = try #require(try exportLines(url).first { $0["type"] as? String == "event" })
        let app = try #require(event["application"] as? [String: Any])
        #expect(app["available"] as? Bool == false && app["unavailableReason"] as? String == "unavailableAtBinding")
        #expect(app["data"] == nil && event["text"] == nil)
    }
}

extension WebSocketExportTests {
    @Test func newConsumerCannotBindInsidePendingPhysicalPauseRevocation() async throws {
        let store = wsStore(), token = try wsSession(store)
        try exportPublish(store, token, id: 1, application: Data([65])) { $0.completedAt = nil; $0.captureAbandoned = true }
        for direction in [WebSocketDirection.clientToServer, .serverToClient] { store.endWebSocket(token: token, transport: .init(direction: direction, at: Date(), monotonic: 1)) }
        let old = try store.beginWebSocketExport(token: token)
        let marked = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0), paused = DispatchSemaphore(value: 0)
        store.state.withLock { $0.webSockets.exportDrainProbe = { marked.signal(); resume.wait() } }
        DispatchQueue.global().async { store.setWebSocketRecording(enabled: false, revision: 1); paused.signal() }
        #expect(await exportWait(marked))
        #expect(store.webSocketPayload(token: token, eventID: 1, kind: .application, maxBytes: 1)?.bytes == Data([65]))
        #expect(throws: WebSocketExportFailure.self) { try store.beginWebSocketExport(token: token) }
        #expect(throws: WebSocketExportFailure.self) { try old.core.gate.withLock { try store.validateWebSocketExport(old.core) } }
        let pendingRow = try #require(store.webSocketPage(token: token, after: nil, limit: 1)?.rows.first)
        do {
            _ = try store.beginWebSocketExport(token: token, dependency: .selectedPayload(eventID: 1, expectedRevision: pendingRow.revision, kind: .application))
            Issue.record("Raw admission must reject physically pending revocation")
        } catch let failure as WebSocketExportFailure { #expect(failure.reason == .payloadUnavailable) }
        let cutoff = try #require(store.webSocketExportCutoff(token: token))
        #expect(store.webSocketExportPage(cutoff: cutoff, after: nil, limit: 1)?.rows.count == 1)
        resume.signal(); #expect(await exportWait(paused))
        store.state.withLock { $0.webSockets.exportDrainProbe = nil }; old.finish()
        let url = exportURL(); defer { try? FileManager.default.removeItem(at: url) }
        let result = try await WebSocketJSONLExporter.export(store: store, token: token, to: url)
        #expect(result.status == .complete && result.exported == 1)
        let event = try #require(try exportLines(url).first { $0["type"] as? String == "event" })
        #expect((event["application"] as? [String: Any])?["unavailableReason"] as? String == "unavailableAtBinding")
    }
    @Test func oldPhysicalCleanupCannotRevokeNewGenerationReplacement() async throws {
        let store = wsStore(), token = try wsSession(store)
        try exportPublish(store, token, id: 1, application: Data([65])) { $0.completedAt = nil; $0.captureAbandoned = true }
        for direction in [WebSocketDirection.clientToServer, .serverToClient] { store.endWebSocket(token: token, transport: .init(direction: direction, at: Date(), monotonic: 1)) }
        let old = try store.beginWebSocketExport(token: token)
        let marked = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
        let once = OSAllocatedUnfairLock(initialState: false)
        store.state.withLock { $0.webSockets.exportDrainProbe = {
            if once.withLock({ value in let old = value; value = true; return !old }) { marked.signal(); resume.wait() }
        } }
        DispatchQueue.global().async { store.setWebSocketRecording(enabled: false, revision: 1); done.signal() }
        #expect(await exportWait(marked))
        store.clear(); store.setWebSocketRecording(enabled: true, revision: 2)
        let fresh = try wsSession(store); try exportPublish(store, fresh, id: 1, application: Data([66]))
        let freshLease = try store.beginWebSocketExport(token: fresh)
        resume.signal(); #expect(await exportWait(done))
        #expect(store.webSocketPayload(token: fresh, eventID: 1, kind: .application, maxBytes: 1)?.bytes == Data([66]))
        #expect(store.webSocketExportProgress(freshLease.core, trailer: false).status == .partial)
        try freshLease.core.gate.withLock { try store.validateWebSocketExport(freshLease.core) }
        store.state.withLock { $0.webSockets.exportDrainProbe = nil }
        old.finish(); freshLease.finish(); store.clear()
        #expect(store.webSocketBudget.usedBytes(category: .metadata) == 0)
    }
}

extension WebSocketExportTests {
    @Test func repeatedPauseOfAlreadyUnavailableClosedCellDoesNotInventRowChange() async throws {
        let store = wsStore(), token = try wsSession(store)
        try exportPublish(store, token, id: 1, application: Data([65])) { $0.completedAt = nil; $0.captureAbandoned = true }
        for direction in [WebSocketDirection.clientToServer, .serverToClient] { store.endWebSocket(token: token, transport: .init(direction: direction, at: Date(), monotonic: 1)) }
        store.setWebSocketRecording(enabled: false, revision: 1)
        let url = exportURL(); defer { try? FileManager.default.removeItem(at: url) }
        let result = try await WebSocketJSONLExporter.export(store: store, token: token, sink: ExportTestSink(url)) { stage in
            if case .page = stage {
                store.setWebSocketRecording(enabled: true, revision: 2)
                store.setWebSocketRecording(enabled: false, revision: 3)
            }
        }
        #expect(result.status == .complete && result.exported == 1)
    }
    @Test func overlappingCleanupOfSameRevokedCellCanReopenAdmissionAfterActualRevoke() async throws {
        let store = wsStore(), token = try wsSession(store)
        try exportPublish(store, token, id: 1, application: Data([65])) { $0.completedAt = nil; $0.captureAbandoned = true }
        for direction in [WebSocketDirection.clientToServer, .serverToClient] { store.endWebSocket(token: token, transport: .init(direction: direction, at: Date(), monotonic: 1)) }
        let old = try store.beginWebSocketExport(token: token)
        let marked = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
        let once = OSAllocatedUnfairLock(initialState: false)
        store.state.withLock { $0.webSockets.exportDrainProbe = {
            if once.withLock({ value in let old = value; value = true; return !old }) { marked.signal(); resume.wait() }
        } }
        DispatchQueue.global().async { store.setWebSocketRecording(enabled: false, revision: 1); done.signal() }
        #expect(await exportWait(marked))
        store.setWebSocketRecording(enabled: true, revision: 2)
        store.setWebSocketRecording(enabled: false, revision: 3)
        let fresh = try store.beginWebSocketExport(token: token)
        resume.signal(); #expect(await exportWait(done))
        try fresh.core.gate.withLock { try store.validateWebSocketExport(fresh.core) }
        #expect(store.webSocketPayload(token: token, eventID: 1, kind: .application, maxBytes: 1) == nil)
        store.state.withLock { $0.webSockets.exportDrainProbe = nil }
        old.finish(); fresh.finish(); store.clear()
        #expect(store.webSocketBudget.usedBytes(category: .metadata) == 0)
    }
}

extension WebSocketExportTests {
    @Test func alreadyCommittedEvictionAndPostCutoffRowsDoNotCancelRemainingEvents() async throws {
        var limits = WebSocketLimits(); limits.sessionEvents = 2
        let store = wsStore(limits), token = try wsSession(store)
        try exportPublish(store, token, id: 1, application: Data([65]))
        try exportPublish(store, token, id: 2, application: Data([66]))
        let visited = OSAllocatedUnfairLock(initialState: 0)
        let url = exportURL(); defer { try? FileManager.default.removeItem(at: url) }
        let result = try await WebSocketJSONLExporter.export(store: store, token: token, sink: ExportTestSink(url)) { stage in
            if case .metadata = stage, visited.withLock({ $0 += 1; return $0 == 2 }) {
                do { try exportPublish(store, token, id: 3, application: Data([67])) } catch { Issue.record(error) }
            }
        }
        #expect(result.status == .complete && result.exported == 2 && result.missing == 0)
        #expect(try exportLines(url).compactMap { $0["id"] as? Int } == [1, 2])
    }
    @Test func taskCancellationImmediatelyBeforeEventNewlineDoesNotCommitEvent() async throws {
        let store = wsStore(), token = try wsSession(store)
        try exportPublish(store, token, id: 1, application: Data([65]))
        let entered = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0), newlines = OSAllocatedUnfairLock(initialState: 0)
        let url = exportURL(); defer { try? FileManager.default.removeItem(at: url) }
        let exporter = Task.detached {
            try await WebSocketJSONLExporter.export(store: store, token: token, sink: ExportTestSink(url)) { stage in
                if case .newline = stage, newlines.withLock({ $0 += 1; return $0 == 2 }) { entered.signal(); resume.wait() }
            }
        }
        #expect(await exportWait(entered)); exporter.cancel(); resume.signal()
        let result = try await exporter.value
        #expect(result.status == .cancelled && result.exported == 0 && result.missing == 1)
        let lines = try exportLines(url); #expect(lines.count == 2); assertScalarEnd(try #require(lines.last))
    }
    @Test(arguments: [ExportFault.truncate, .seek, .close])
    private func primaryPartialWriteErrorSurvivesSecondaryCleanupFailure(secondary: ExportFault) async throws {
        let store = wsStore(), token = try wsSession(store)
        try exportPublish(store, token, id: 1, application: Data(repeating: 65, count: 100_000))
        let url = exportURL(); defer { try? FileManager.default.removeItem(at: url) }
        let sink = try ExportTestSink(url, fault: .write, cleanupFault: secondary)
        var progress: WebSocketExportResult?
        do { _ = try await WebSocketJSONLExporter.export(store: store, token: token, sink: sink); Issue.record("Expected write failure") }
        catch let error as WebSocketExportFailure { #expect(error.underlying as? ExportFault == .write); progress = error.progress }
        #expect(progress?.exported == 0 && progress?.missing == 1 && progress?.trailerWritten == (secondary == .close))
        #expect(sink.state.withLock { $0.closes == 1 })
        store.clear(); #expect(store.webSocketBudget.usedBytes(category: .metadata) == 0)
        #expect(progress?.cutoff.eligibleAtCutoff == 1)
    }
}

extension WebSocketExportTests {
    @Test func adjacentActualOmissionsCoalesceWithoutInventingSparseHistory() async throws {
        let store = wsStore(), token = try wsSession(store)
        for id in [UInt64(1), 2, 3, 10, 11, 100] { try exportPublish(store, token, id: id) { $0.completedAt = nil } }
        let url = exportURL(); defer { try? FileManager.default.removeItem(at: url) }
        let result = try await WebSocketJSONLExporter.export(store: store, token: token, to: url)
        #expect(result.status == .partial && result.omittedAtCutoff == 6 && result.missing == 0)
        #expect(result.evidence == [.init(cause: .activeAtCutoff, firstID: 1, lastID: 3, count: 3), .init(cause: .activeAtCutoff, firstID: 10, lastID: 11, count: 2), .init(cause: .activeAtCutoff, firstID: 100, lastID: 100, count: 1)])
        #expect(result.unknown.isEmpty && !result.cutoff.priorEvictionObserved)
        let manifest = try #require(try exportLines(url).first)
        #expect((manifest["initialOmissions"] as? [[String: Any]])?.count == 3)
    }
}


extension WebSocketExportTests {
    @Test(arguments: [1, 200])
    func pageConstructionPeakNeverExceedsReservedSlots(cap: Int) throws {
        let store = wsStore(), token = try wsSession(store)
        for id in 1...(cap + 1) { try exportPublish(store, token, id: UInt64(id)) }
        let cutoff = try #require(store.webSocketExportCutoff(token: token))
        let probe = WebSocketExportPageProbe(firstCandidateIDs: (UInt64(cap + 1), 1))
        let before = store.webSocketBudget.usedBytes(category: .metadata)
        var page = store.webSocketExportPage(cutoff: cutoff, after: nil, limit: cap, probe: probe)
        #expect(page?.rows.count == cap && page?.rows.first?.id == 1)
        #expect(probe.snapshot.peak == cap && probe.snapshot.live == cap && probe.snapshot.reserved == cap && probe.snapshot.constructed == cap + 1)
        #expect(store.webSocketBudget.usedBytes(category: .metadata) == before + cap * 128)
        page = nil
        #expect(probe.snapshot.live == 0)
        #expect(store.webSocketBudget.usedBytes(category: .metadata) == before)
        print("Task5 fix1 construction cap=\(cap); peak=\(probe.snapshot.peak); reserved=\(probe.snapshot.reserved); constructed=\(probe.snapshot.constructed)")
    }

    @Test(arguments: [false, true])
    func liveMetadataUTF8IteratorRetainsExactChargesAcrossClear(header: Bool) async throws {
        let store = wsStore()
        let flowID = store.begin { Flow(id: $0, scheme: "https", method: "GET", host: "test", port: 443, path: "/") }
        let large = String(repeating: "中😀\"\n", count: 20_000)
        let token = try #require(store.beginWebSocket(flowID: flowID,
            handshake: .init(requestHeaders: [.init(name: "X", value: header ? large : "short"), .init(name: "X", value: "second")], requestURI: header ? "/short" : large)))
        try exportPublish(store, token, id: 1, application: Data(repeating: 65, count: 64))
        #expect(store.webSocketBudget.usedBytes(category: .retained) == 64)
        let canonical = try store.state.withLock { state in
            let session = try #require(state.webSockets.session(token))
            return session.handshakeCharge.bytes + session.terminalCharge.bytes + session.diagnosticCharges.values.reduce(0) { $0 + $1.bytes }
        }
        // Manifest iteration precedes page creation: retained row/page fees are exactly zero.
        let expected = 8192 + canonical
        let entered = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0), cleared = DispatchSemaphore(value: 0)
        let once = OSAllocatedUnfairLock(initialState: false)
        let url = exportURL(); defer { try? FileManager.default.removeItem(at: url) }
        let sink = try ExportTestSink(url)
        let exporter = Task.detached {
            try await WebSocketJSONLExporter.export(store: store, token: token, sink: sink) { stage in
                if case .metadataStringChunk = stage, once.withLock({ value in let old = value; value = true; return !old }) {
                    entered.signal(); resume.wait()
                }
            }
        }
        #expect(await exportWait(entered))
        DispatchQueue.global().async { store.clear(); cleared.signal() }
        #expect(await exportWait(cleared))
        #expect(store.webSocketBudget.usedBytes(category: .retained) == 0)
        #expect(store.webSocketBudget.usedBytes(category: .metadata) == expected)
        let writesAtClear = sink.state.withLock { $0.writes }
        resume.signal()
        let result = try await exporter.value
        #expect(result.status == .cancelled && result.exported == 0 && result.trailerWritten)
        #expect(sink.state.withLock { $0.writes } == writesAtClear + 1)
        let lines = try exportLines(url)
        #expect(lines.count == 1)
        assertScalarEnd(try #require(lines.last))
        #expect(store.webSocketBudget.usedBytes(category: .metadata) == 0)
        #expect(sink.state.withLock { $0.closes } == 1)
        print("Task5 fix1 live UTF8 iterator header=\(header); row/page fees=0; held metadata=\(expected); retained after Clear=0; final metadata=0; post-Clear writes=1 scalar end")
    }
}


extension WebSocketExportTests {
    @Test func selectedPayloadStreamsExactPrefixAndEmptyWithoutJSON() async throws {
        let store = wsStore(); let token = try wsSession(store)
        let bytes = Data(repeating: 0xA7, count: 400_000)
        try exportPublish(store, token, id: 1, application: bytes) { $0.integrity = .captureTruncated }
        try exportPublish(store, token, id: 2, application: Data())
        let row = try #require(store.webSocketPage(token: token, after: nil, limit: 2)?.rows.first)
        let url = exportURL(); defer { try? FileManager.default.removeItem(at: url) }
        let sink = try ExportTestSink(url)
        let result = try await WebSocketPayloadExporter.save(store: store, token: token, eventID: 1, kind: .application, expectedRevision: row.revision, sink: sink)
        #expect(try Data(contentsOf: url) == bytes)
        #expect(result.retainedBytes == bytes.count && result.truncated && !result.complete)
        #expect(sink.state.withLock { $0.maximum } <= 32_768)
        let empty = try #require(store.webSocketPage(token: token, after: 1, limit: 1)?.rows.first)
        let saved = try await WebSocketPayloadExporter.save(store: store, token: token, eventID: 2, kind: .application, expectedRevision: empty.revision, to: url)
        #expect(saved.retainedBytes == 0 && saved.complete)
        #expect(try Data(contentsOf: url).isEmpty)
    }
    @Test func selectedSaveIgnoresUnrelatedChangesButClearRollsBackZero() async throws {
        for clear in [false, true] {
            var limits = WebSocketLimits(); limits.sessionEvents = 2
            let store = wsStore(limits); let token = try wsSession(store)
            try exportPublish(store, token, id: 1, application: Data([1]))
            let bytes = Data(repeating: 0x42, count: 80_000)
            try exportPublish(store, token, id: 2, application: bytes)
            let row = try #require(store.webSocketPage(token: token, after: 1, limit: 1)?.rows.first)
            let url = exportURL(); defer { try? FileManager.default.removeItem(at: url) }
            let once = OSAllocatedUnfairLock(initialState: false)
            let probe: WebSocketExportProbe = { stage in
                guard case .written = stage else { return }
                guard once.withLock({ value in if value { return false }; value = true; return true }) else { return }
                if clear { store.clear() }
                else { try! exportPublish(store, token, id: 3, application: Data([3])) }
            }
            do {
                _ = try await WebSocketPayloadExporter.save(store: store, token: token, eventID: 2, kind: .application, expectedRevision: row.revision, sink: WebSocketFileSink(url: url), probe: probe)
                #expect(!clear)
                #expect(try Data(contentsOf: url) == bytes)
            } catch let failure as WebSocketExportFailure {
                #expect(clear && failure.reason == .tokenInvalidated)
                #expect(try Data(contentsOf: url).isEmpty)
            }
            #expect(store.state.withLock { $0.webSockets.exportConsumers.count } == 0)
        }
    }
    @Test func selectedSaveIOFailureRollsBackAndReleasesCore() async throws {
        let store = wsStore(); let token = try wsSession(store)
        try exportPublish(store, token, id: 1, application: Data(repeating: 7, count: 70_000))
        let row = try #require(store.webSocketPage(token: token, after: nil, limit: 1)?.rows.first)
        let url = exportURL(); defer { try? FileManager.default.removeItem(at: url) }
        let sink = try ExportTestSink(url, fault: .write, failWrite: 2)
        do {
            _ = try await WebSocketPayloadExporter.save(store: store, token: token, eventID: 1, kind: .application, expectedRevision: row.revision, sink: sink)
            Issue.record("Expected typed IO failure")
        } catch let failure as WebSocketExportFailure { #expect(failure.reason == .io) }
        #expect(try Data(contentsOf: url).isEmpty)
        #expect(sink.state.withLock { $0.closes } == 1)
        #expect(store.state.withLock { $0.webSockets.exportConsumers.count } == 0)
    }
}


extension WebSocketExportTests {
    @Test(arguments: [false, true])
    func selectedSavePausePreservesCompleteButRevokesAbandoned(abandoned: Bool) async throws {
        let store = wsStore(); let token = try wsSession(store)
        let bytes = Data(repeating: 65, count: 80_000)
        try exportPublish(store, token, id: 1, application: bytes) {
            if abandoned { $0.completedAt = nil; $0.captureAbandoned = true; $0.integrity = .incompleteTransport }
        }
        let row = try #require(store.webSocketPage(token: token, after: nil, limit: 1)?.rows.first)
        let url = exportURL(); defer { try? FileManager.default.removeItem(at: url) }
        let once = OSAllocatedUnfairLock(initialState: false)
        let probe: WebSocketExportProbe = { stage in
            guard case .written = stage, once.withLock({ value in if value { return false }; value = true; return true }) else { return }
            store.setWebSocketRecording(enabled: false, revision: 1)
        }
        do {
            _ = try await WebSocketPayloadExporter.save(store: store, token: token, eventID: 1, kind: .application, expectedRevision: row.revision, sink: WebSocketFileSink(url: url), probe: probe)
            #expect(!abandoned)
            #expect(try Data(contentsOf: url) == bytes)
        } catch let error as WebSocketExportFailure {
            #expect(abandoned && [.payloadUnavailable, .changedAfterCutoff].contains(error.reason))
            #expect(try Data(contentsOf: url).isEmpty)
        }
    }
    @Test func selectedSaveCancellationRollsBackZero() async throws {
        let store = wsStore(); let token = try wsSession(store)
        try exportPublish(store, token, id: 1, application: Data(repeating: 65, count: 80_000))
        let row = try #require(store.webSocketPage(token: token, after: nil, limit: 1)?.rows.first)
        let url = exportURL(); defer { try? FileManager.default.removeItem(at: url) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await WebSocketPayloadExporter.save(store: store, token: token, eventID: 1, kind: .application, expectedRevision: row.revision, to: url)
        }
        do { _ = try await task.value; Issue.record("Expected cancellation") }
        catch let failure as WebSocketExportFailure { #expect(failure.reason == .cancelled) }
        #expect(try Data(contentsOf: url).isEmpty)
        #expect(store.state.withLock { $0.webSockets.exportConsumers.count } == 0)
    }
}


extension WebSocketExportTests {
    @Test(arguments: ["close", "truncate", "seek"])
    func rawPhysicalCleanupFailuresAreTypedAndNeverJSON(faultName: String) async throws {
        let fault: ExportFault = faultName == "close" ? .close : faultName == "truncate" ? .truncate : .seek
        let store = wsStore(); let token = try wsSession(store)
        let bytes = Data(repeating: 65, count: 80_000)
        try exportPublish(store, token, id: 1, application: bytes)
        let row = try #require(store.webSocketPage(token: token, after: nil, limit: 1)?.rows.first)
        let url = exportURL(); defer { try? FileManager.default.removeItem(at: url) }
        let sink = try ExportTestSink(url, fault: fault == .close ? .close : .write, failWrite: 2, cleanupFault: fault == .close ? nil : fault)
        do {
            _ = try await WebSocketPayloadExporter.save(store: store, token: token, eventID: 1, kind: .application, expectedRevision: row.revision, sink: sink)
            Issue.record("Physical failure must not report successful save")
        } catch let error as WebSocketExportFailure {
            #expect(error.reason == .io)
            #expect(error.underlying as? ExportFault == (fault == .close ? .close : .write))
        }
        let remaining = try Data(contentsOf: url)
        #expect(remaining.allSatisfy { $0 == 65 })
        if fault == .seek { #expect(remaining.isEmpty) }
        else { #expect(!remaining.isEmpty) }
        print("Task6 raw cleanup failure=\(fault), actualRemaining=\(remaining.count), JSON trailer absent")
        #expect(store.state.withLock { $0.webSockets.exportConsumers.count } == 0)
    }
    @Test func selectedEvictionCancelsAndRollsBackZero() async throws {
        var limits = WebSocketLimits(); limits.sessionEvents = 1
        let store = wsStore(limits); let token = try wsSession(store)
        try exportPublish(store, token, id: 1, application: Data(repeating: 65, count: 80_000))
        let row = try #require(store.webSocketPage(token: token, after: nil, limit: 1)?.rows.first)
        let url = exportURL(); defer { try? FileManager.default.removeItem(at: url) }
        let once = OSAllocatedUnfairLock(initialState: false)
        let probe: WebSocketExportProbe = { stage in
            guard case .written = stage, once.withLock({ value in if value { return false }; value = true; return true }) else { return }
            try! exportPublish(store, token, id: 2, application: Data([66]))
        }
        do {
            _ = try await WebSocketPayloadExporter.save(store: store, token: token, eventID: 1, kind: .application, expectedRevision: row.revision, sink: WebSocketFileSink(url: url), probe: probe)
            Issue.record("Selected eviction must cancel raw save")
        } catch let failure as WebSocketExportFailure { #expect(failure.reason == .evicted) }
        #expect(try Data(contentsOf: url).isEmpty)
    }
}


extension WebSocketExportTests {
    @Test(arguments: [false, true], [false, true])
    func rawSuccessfulCloseLinearizesAgainstClearAndCancellation(cancel: Bool, beforeCommit: Bool) async throws {
        let store = wsStore(), token = try wsSession(store)
        let bytes = Data(repeating: 0x42, count: 80_000)
        try exportPublish(store, token, id: 1, application: bytes)
        let row = try #require(store.webSocketPage(token: token, after: nil, limit: 1)?.rows.first)
        let url = exportURL(); defer { try? FileManager.default.removeItem(at: url) }
        let closing = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), mutationDone = DispatchSemaphore(value: 0)
        let sink = try ExportTestSink(url, onClose: {
            if !beforeCommit { closing.signal(); release.wait() }
        }, onWrite: { index, _ in
            if beforeCommit && index == 1 { closing.signal(); release.wait() }
        })
        let task = Task.detached { try await WebSocketPayloadExporter.save(store: store, token: token, eventID: 1, kind: .application, expectedRevision: row.revision, sink: sink) }
        #expect(await exportWait(closing))
        let core = try #require(store.state.withLock { $0.webSockets.exportConsumers.values.first })
        DispatchQueue.global().async {
            if cancel { task.cancel() } else { store.clear() }
            mutationDone.signal()
        }
        // Observe the actual S-owned logical step; the queue is blocked draining G.
        // The deadline is only a deadlock guard, never the trigger for the race.
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while store.state.withLock({ _ in core.reason == nil }) && ContinuousClock.now < deadline { await Task.yield() }
        let observed = store.state.withLock { _ in (core.reason, core.exported) }
        #expect(observed.0 == (cancel ? .cancelled : .tokenInvalidated))
        release.signal()
        #expect(await exportWait(mutationDone))
        do {
            let result = try await task.value
            #expect(!beforeCommit && observed.1 == 1 && result.retainedBytes == bytes.count && result.complete)
            #expect(try Data(contentsOf: url) == bytes)
            print("Task6 fix1 close race cancel=\(cancel): committed success before invalidation; bytes=\(bytes.count)")
        } catch let failure as WebSocketExportFailure {
            #expect(beforeCommit && observed.1 == 0 && failure.reason == (cancel ? .cancelled : .tokenInvalidated))
            #expect(try Data(contentsOf: url).isEmpty)
            print("Task6 fix1 close race cancel=\(cancel): failed reason=\(failure.reason), bytes=\(try Data(contentsOf: url).count)")
        }
        #expect(sink.state.withLock { $0.closes } == 1)
        #expect(store.state.withLock { $0.webSockets.exportConsumers.count } == 0)
    }
    @Test(arguments: ["open", "write", "close", "truncate", "seek"])
    func rawIOFailurePreservesBoundedIndependentProgress(faultName: String) async throws {
        let store = wsStore(), token = try wsSession(store)
        try exportPublish(store, token, id: 1, application: Data(repeating: 65, count: 80_000))
        let row = try #require(store.webSocketPage(token: token, after: nil, limit: 1)?.rows.first)
        let url = exportURL(); defer { try? FileManager.default.removeItem(at: url) }
        do {
            if faultName == "open" {
                _ = try await WebSocketPayloadExporter.save(store: store, token: token, eventID: 1, kind: .application, expectedRevision: row.revision, to: url.appendingPathComponent("missing.bin"))
            } else {
                let cleanup: ExportFault? = faultName == "truncate" ? .truncate : faultName == "seek" ? .seek : nil
                let sink = try ExportTestSink(url, fault: faultName == "close" ? .close : .write, failWrite: 2, cleanupFault: cleanup)
                _ = try await WebSocketPayloadExporter.save(store: store, token: token, eventID: 1, kind: .application, expectedRevision: row.revision, sink: sink)
            }
            Issue.record("Expected actual sink I/O failure")
        } catch let failure as WebSocketExportFailure {
            #expect(failure.reason == .io)
            if faultName != "open" { #expect(failure.underlying as? ExportFault == (faultName == "close" ? .close : .write)) }
            let progress = try #require(failure.progress)
            #expect(progress.cutoff.token == token && progress.cutoff.eligibleAtCutoff == 1)
            #expect(progress.status != .complete && !progress.trailerWritten)
            #expect(progress.exported + progress.missing == 1 && progress.evidence.count + progress.unknown.count <= 32)
            let oldEvidence = progress.evidence, oldUnknown = progress.unknown
            store.clear()
            #expect(progress.evidence == oldEvidence && progress.unknown == oldUnknown)
            let remaining = FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : Data()
            #expect(remaining.allSatisfy { $0 == 65 })
            #expect(remaining.count == (faultName == "close" ? 80_000 : faultName == "truncate" ? 32_775 : 0))
            print("Task6 fix1 bounded raw progress fault=\(faultName), exported=\(progress.exported), missing=\(progress.missing), residual=\(remaining.count), no JSON trailer")
        }
        #expect(store.state.withLock { $0.webSockets.exportConsumers.count } == 0)
    }
}

extension WebSocketExportTests {
    /// Phase fix 1: network-path Store mutations that invalidate no export never wait on a held writer gate.
    @Test(arguments: [false, true])
    func networkPathMutationsDoNotWaitOnBlockedSink(cancelFirst: Bool) async throws {
        let store = wsStore(), token = try wsSession(store), other = try wsSession(store)
        try exportPublish(store, token, id: 1, application: Data(repeating: 65, count: 100_000))
        let inWrite = DispatchSemaphore(value: 0), releaseWrite = DispatchSemaphore(value: 0), mutationsDone = DispatchSemaphore(value: 0)
        let drains = OSAllocatedUnfairLock(initialState: 0)
        store.state.withLock { $0.webSockets.exportDrainProbe = { drains.withLock { $0 += 1 } } }
        let url = exportURL(); defer { try? FileManager.default.removeItem(at: url) }
        let sink = try ExportTestSink(url, onWrite: { index, _ in
            if index == 3 { inWrite.signal(); releaseWrite.wait() }
        })
        let exporter = Task.detached { try await WebSocketJSONLExporter.export(store: store, token: token, sink: sink) }
        #expect(await exportWait(inWrite))
        if cancelFirst {
            // A user cancel marks the core invalid, then its handler waits on the held gate.
            DispatchQueue.global().async { exporter.cancel() }
            while !store.state.withLock({ $0.webSockets.exportConsumers.values.contains { $0.reason != nil } }) { await Task.yield() }
        }
        DispatchQueue.global().async {
            for _ in 0..<100 {
                store.recordWebSocketState(.observedBytes(direction: .serverToClient, wire: 10, application: 8, lowerBound: false), token: token)
                store.recordWebSocketState(.observedBytes(direction: .clientToServer, wire: 10, application: 8, lowerBound: false), token: other)
            }
            store.recordWebSocketState(.closeCode(direction: .serverToClient, code: 1000), token: token)
            let id = store.begin { Flow(id: $0, scheme: "http", method: "GET", host: "plain.test", port: 80, path: "/") }
            store.update(id) { $0.state = .completed }
            do {
                // A post-cutoff publication on the exported session and one on another session.
                try exportPublish(store, token, id: 2, application: Data([1]))
                try exportPublish(store, other, id: 1, application: Data([2]))
            } catch { Issue.record(error) }
            store.endWebSocket(token: other, transport: .init(direction: .clientToServer, at: Date(), monotonic: 1))
            mutationsDone.signal()
        }
        // Bounded: the writer is still held inside its sink write while every mutation returns.
        #expect(await exportWait(mutationsDone))
        #expect(drains.withLock { $0 } == 0)
        releaseWrite.signal()
        let result = try await exporter.value
        let lines = try exportLines(url)
        if cancelFirst {
            #expect(result.status == .cancelled && result.exported == 0 && result.trailerWritten)
            #expect(lines.count == 2); assertScalarEnd(try #require(lines.last))
        } else {
            #expect(result.status == .complete && result.exported == 1 && result.missing == 0 && result.trailerWritten)
            #expect(lines.count == 3 && lines[1]["id"] as? Int == 1 && lines[2]["status"] as? String == "complete")
        }
        store.state.withLock { $0.webSockets.exportDrainProbe = nil }
        store.clear(); #expect(store.webSocketBudget.usedBytes(category: .metadata) == 0)
    }
}

extension WebSocketExportTests {
    @Test func flowRemovalRevokesBeforeBlockedExportDrain() async throws {
        let store = wsStore(), token = try wsSession(store)
        try exportPublish(store, token, id: 1, application: Data(repeating: 65, count: 100_000))
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let revoked = DispatchSemaphore(value: 0), cleared = DispatchSemaphore(value: 0)
        let url = exportURL(); defer { try? FileManager.default.removeItem(at: url) }
        let sink = try ExportTestSink(url, onWrite: { index, _ in
            if index == 3 { entered.signal(); #expect(release.wait(timeout: .now() + 10) == .success) }
        })
        let registered = store.registerFlowRemoval(flowID: token.flowID) {
            #expect(store.flow(token.flowID) == nil) // reentry proves S is not held
            revoked.signal()
        }
        #expect(registered)
        let exporter = Task.detached { try await WebSocketJSONLExporter.export(store: store, token: token, sink: sink) }
        let started = await exportWait(entered)
        #expect(started)
        DispatchQueue.global().async { store.clear(); cleared.signal() }
        // The token revocation must finish while the sink is still holding G.
        #expect(await exportWait(revoked))
        release.signal()
        #expect(await exportWait(cleared))
        let result = try await exporter.value
        #expect(result.status == .cancelled)
        store.clear()
    }
}
