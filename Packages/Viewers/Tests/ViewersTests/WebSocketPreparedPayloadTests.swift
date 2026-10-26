import Foundation
import Testing
import FlowStore
@testable import Viewers

@Suite(.productionChinese) struct WebSocketPreparedPayloadTests {
    @Test func onlyCompleteValidTextMayBecomeJSON() async throws {
        for kind in [WebSocketEventKind.text, .binary, .opaqueFrame] {
            for integrity in [WebSocketIntegrity.transportComplete, .captureTruncated, .incompleteTransport, .invalid, .opaque] {
                let (snapshot, row) = try fixture(Data("{\"a\":1}".utf8), kind: kind, integrity: integrity)
                let prepared = await WebSocketPreparedPayload.prepare(snapshot: snapshot, event: row, attemptBinaryUTF8: false)
                #expect((prepared.json != nil) == (kind == .text && integrity == .transportComplete))
                if kind == .binary { #expect(prepared.text == nil) }
            }
        }
    }
    @Test func cutScalarIsNotInvalidAndBinaryOptInKeepsBytes() async throws {
        let bytes = Data([0x61, 0xE4, 0xB8])
        let (snapshot, row) = try fixture(bytes, integrity: .captureTruncated)
        let prepared = await WebSocketPreparedPayload.prepare(snapshot: snapshot, event: row, attemptBinaryUTF8: false)
        #expect(prepared.text == "a" && prepared.status == .truncated && prepared.json == nil && prepared.bytes == bytes)
        let (binary, metadata) = try fixture(Data("{}".utf8), kind: .binary)
        let attempted = await WebSocketPreparedPayload.prepare(snapshot: binary, event: metadata, attemptBinaryUTF8: true)
        #expect(attempted.text == "{}" && attempted.json == nil && attempted.bytes == binary.bytes)
    }
    @Test func abandonmentDoesNotInventFINAndPreviewStaysBounded() async throws {
        let (snapshot, row) = try fixture(Data(repeating: 97, count: 300_000), abandoned: true)
        let result = await WebSocketPreparedPayload.prepare(snapshot: snapshot, event: row, attemptBinaryUTF8: false)
        #expect(result.bytes.count <= 262_144 && result.displayTruncated && result.json == nil && result.status == .incomplete)
    }
    @Test func wireNeverInheritsApplicationJSONEligibility() async throws {
        let (snapshot, row) = try fixture(Data("{}".utf8), payloadKind: .wirePayload)
        let raw = await WebSocketPreparedPayload.prepare(snapshot: snapshot, event: row, kind: .wirePayload, attemptBinaryUTF8: false)
        #expect(raw.json == nil && raw.text == nil)
        let attempted = await WebSocketPreparedPayload.prepare(snapshot: snapshot, event: row, kind: .wirePayload, attemptBinaryUTF8: true)
        #expect(attempted.text == "{}" && attempted.json == nil)
    }
    @Test func compressedWireBytesNeverBorrowValidApplicationUTF8() async throws {
        let bytes = Data([0xAA, 0xAE, 0x05, 0x00])
        let (snapshot, row) = try fixture(bytes, payloadKind: .wirePayload)
        let raw = await WebSocketPreparedPayload.prepare(snapshot: snapshot, event: row, kind: .wirePayload, attemptBinaryUTF8: true)
        #expect(raw.bytes == bytes && raw.text == nil && raw.json == nil)
        let (application, event) = try fixture(Data("{}".utf8))
        let decoded = await WebSocketPreparedPayload.prepare(snapshot: application, event: event, kind: .application, attemptBinaryUTF8: false)
        #expect(decoded.json != nil)
    }
    private func fixture(_ bytes: Data, kind: WebSocketEventKind = .text, integrity: WebSocketIntegrity = .transportComplete, abandoned: Bool = false, payloadKind: WebSocketPayloadKind = .application) throws -> (WebSocketPayloadSnapshot, WebSocketEventMetadata) {
        let store = FlowStore(bodyDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let flowID = store.begin { Flow(id: $0, scheme: "http", method: "GET", host: "synthetic.test", port: 80, path: "/ws") }
        let token = try #require(store.beginWebSocket(flowID: flowID, handshake: .init()))
        let stamp = try #require(store.webSocketCaptureStamp(token: token))
        var row = WebSocketEventMetadata(id: 1, order: .init(ingressSequence: stamp.ingressSequence, offset: 0), direction: .clientToServer, kind: kind)
        row.completedAt = abandoned ? nil : Date(); row.captureAbandoned = abandoned
        row.integrity = integrity; row.utf8 = .valid; row.decodedBytes = UInt64(bytes.count)
        let cell = try #require(store.makeWebSocketAccumulator(token: token, eventID: 1, epoch: stamp.epoch, kind: payloadKind))
        #expect(cell.append(bytes, expectedEpoch: stamp.epoch))
        if payloadKind == .application {
            #expect(store.publishWebSocket(.init(metadata: row, stamp: stamp, application: cell.take(kind: payloadKind, complete: !abandoned, truncated: integrity == .captureTruncated)), token: token, captureEpoch: stamp.epoch) == .accepted)
        } else {
            #expect(store.publishWebSocket(.init(metadata: row, stamp: stamp, wirePayload: cell.take(kind: payloadKind, complete: !abandoned, truncated: integrity == .captureTruncated)), token: token, captureEpoch: stamp.epoch) == .accepted)
        }
        return (try #require(store.webSocketPayload(token: token, eventID: 1, kind: payloadKind, maxBytes: 262_144)), try #require(store.webSocketPage(token: token, after: nil, limit: 1)?.rows.first))
    }
}
