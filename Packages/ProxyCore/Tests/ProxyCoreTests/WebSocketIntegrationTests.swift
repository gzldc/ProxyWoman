import Atomics
import CertKit
import FlowStore
import Foundation
import NIOCore
import NIOEmbedded
import NIOHTTP1
import NIOPosix
import NIOSSL
import Testing
import os
@testable import ProxyCore

/// Real ProxyServer pipeline + real loopback peers. Bytes are compared at both sockets and the
/// Store is read independently; ordering comes from the protocol script and named barriers.
@Suite(.productionChinese, .timeLimit(.minutes(2))) struct WebSocketIntegrationTests {
    static let immediateDrain = ProxyDrainDeadline { loop, action in loop.execute(action); return {} }

    static func withServer(store: FlowStore, originCA: CertificateAuthority?, passthrough: PassthroughRegistry = .init(),
                           hooks: WebSocketObservationHooks = .init(),
                           _ body: (ProxyServer, CertificateAuthority) async throws -> Void) async throws {
        let ca = try CertificateAuthority.generate(commonName: "WS integration proxy CA")
        var configuration = ProxyConfiguration(); configuration.port = 0
        if let originCA { configuration.upstreamTrustRoots = try WSProxyPeer.roots(originCA) }
        let server = ProxyServer(configuration: configuration, certificateAuthority: ca, store: store, passthrough: passthrough,
            processLookup: .none, drainDeadline: immediateDrain, webSocketHooks: hooks)
        do {
            try await server.start()
            try await body(server, ca)
            try await server.stop()
        } catch { try? await server.stop(); throw error }
    }
    static func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ws-origin-\(UUID().uuidString)")
    }
    static func session(_ store: FlowStore) async throws -> (Flow, WebSocketSessionToken) {
        let flow = try await waitForFlow(store) { $0.statusCode == 101 }
        return (flow, try #require(store.webSocketToken(flowID: flow.id)))
    }
    static func rows(_ store: FlowStore, _ token: WebSocketSessionToken) -> [WebSocketEventMetadata] {
        store.webSocketPage(token: token, after: nil, limit: 200)?.rows ?? []
    }
    static func payload(_ store: FlowStore, _ token: WebSocketSessionToken, _ row: WebSocketEventMetadata,
                        _ kind: WebSocketPayloadKind = .application) -> [UInt8]? {
        store.webSocketPayload(token: token, eventID: row.id, kind: kind, maxBytes: 262_144).map { Array($0.bytes) }
    }
    static func expectObserverReservationsReleased(_ store: FlowStore) {
        for category in [WebSocketMemoryCategory.working, .native, .mailbox] {
            #expect(store.webSocketBudget.usedBytes(category: category) == 0, "\(category)")
        }
    }
}

// MARK: - Step 1: protocol matrix

extension WebSocketIntegrationTests {
    @Test(arguments: [false, true])
    func uncompressedMatrixPreservesBothPeersAndRecordsEveryEvent(tls: Bool) async throws {
        let text = Array("fragmented-中".utf8) // the split at 12 lands inside the 3-byte scalar
        let server1 = WSWire.frame(1, Array("hello".utf8))
        let clientParts: [[UInt8]] = [
            WSWire.client(1, Array(text[0..<4]), fin: false), WSWire.client(9, Array("p1".utf8)),
            WSWire.client(0, Array(text[4..<12]), fin: false), WSWire.client(0, Array(text[12...])),
            WSWire.client(2, [0x00, 0xff, 0x80, 0x01, 0xfe]), WSWire.client(1, []), WSWire.client(2, [])]
        let client1 = clientParts.flatMap { $0 }
        let serverParts: [[UInt8]] = [
            WSWire.frame(10, Array("p1".utf8)), WSWire.frame(2, [0xde, 0xad, 0xbe, 0xef, 0x00]), WSWire.frame(1, []), WSWire.frame(9, [])]
        let server2 = serverParts.flatMap { $0 }
        let client2 = WSWire.client(10, []) + WSWire.client(8, [0x03, 0xe8] + Array("bye".utf8))
        let server3 = WSWire.frame(8, [0x03, 0xe8])
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let origin = try await WebSocketOrigin.start(tls: tls, script: [
            .send(bytes: Data(server1)), .expect(bytes: Data(client1)), .send(bytes: Data(server2)),
            .expect(bytes: Data(client2)), .send(bytes: Data(server3)), .closeTransport], directory: directory)
        let store = observationStore()
        do {
            try await Self.withServer(store: store, originCA: origin.ca) { server, ca in
                let client = try await WSProxyPeer.connect(proxyPort: try #require(server.boundPort), originPort: origin.port,
                    tls: tls ? try WSProxyPeer.roots(ca) : nil)
                do {
                    let handshakeBody = Array("abc".utf8)
                    try await WSProxyPeer.upgrade(client, originPort: origin.port, absolute: !tls, body: handshakeBody)
                    var clientReceived = try await client.receive(count: server1.count)
                    try await client.send(bytes: client1)
                    clientReceived += try await client.receive(count: server2.count)
                    try await client.send(bytes: client2)
                    clientReceived += try await client.receive(count: server3.count)
                    try await client.waitUntilClosed()
                    try await origin.waitUntilFinished()
                    let clientSent = client1 + client2, originSent = origin.sent
                    #expect(origin.transcript.failures.isEmpty)
                    #expect(originSent == server1 + server2 + server3)
                    #expect(clientReceived == originSent)
                    #expect(client.remainingBytes().isEmpty)
                    #expect(origin.received == clientSent)
                    #expect(origin.transcript.requestBody == handshakeBody)

                    let (flow, token) = try await Self.session(store)
                    try await waitUntil("closed WebSocket lifecycle") { store.webSocketSummary(token: token)?.lifecycle == .transportClosed }
                    #expect(store.flow(flow.id)?.bytesSent == handshakeBody.count)
                    #expect(store.flow(flow.id)?.bytesReceived == 0)
                    let rows = Self.rows(store, token)
                    let expected: [(WebSocketDirection, WebSocketEventKind, [UInt8])] = [
                        (.serverToClient, .text, Array("hello".utf8)), (.clientToServer, .text, text),
                        (.clientToServer, .ping, Array("p1".utf8)), (.clientToServer, .binary, [0x00, 0xff, 0x80, 0x01, 0xfe]),
                        (.clientToServer, .text, []), (.clientToServer, .binary, []),
                        (.serverToClient, .pong, Array("p1".utf8)), (.serverToClient, .binary, [0xde, 0xad, 0xbe, 0xef, 0x00]),
                        (.serverToClient, .text, []), (.serverToClient, .ping, []),
                        (.clientToServer, .pong, []), (.clientToServer, .close, [0x03, 0xe8] + Array("bye".utf8)),
                        (.serverToClient, .close, [0x03, 0xe8])]
                    try #require(rows.count == expected.count)
                    for (row, item) in zip(rows, expected) {
                        #expect(row.direction == item.0 && row.kind == item.1, "row \(row.id)")
                        #expect(Self.payload(store, token, row) == item.2, "row \(row.id)")
                        #expect(Self.payload(store, token, row, .wirePayload) == item.2, "row \(row.id) unmasked wire payload")
                        #expect(row.completedAt != nil && row.integrity == .transportComplete && !row.compressed)
                    }
                    #expect(rows[1].fragmentCount == 3 && rows[1].fragments.map(\.opcode) == [1, 0, 0] && rows[1].utf8 == .valid)
                    #expect(rows[1].fragments.allSatisfy { $0.masked })
                    #expect(rows[11].closeCode == 1000 && rows[12].closeCode == 1000)
                    let summary = try #require(store.webSocketSummary(token: token))
                    #expect(summary.clientToServer.completedClose && summary.serverToClient.completedClose)
                    #expect(summary.clientToServer.wireBytes == UInt64(clientSent.count))
                    #expect(summary.serverToClient.wireBytes == UInt64(originSent.count))
                    #expect(summary.clientToServer.applicationBytes == UInt64(text.count + 5))
                    #expect(summary.serverToClient.applicationBytes == 10)
                    #expect(!summary.lowerBound && summary.handshake.assessment == .verified)
                    try await client.close()
                } catch { try? await client.close(); throw error }
            }
            Self.expectObserverReservationsReleased(store)
            try await origin.stop()
        } catch { try? await origin.stop(); throw error }
    }
}

extension WebSocketIntegrationTests {
    struct CompressionCase: Sendable, CustomTestStringConvertible {
        let name: String
        let tls: Bool
        let offer: String
        let response: String
        var testDescription: String { "\(name)-\(tls ? "tls" : "plain")" }
    }
    static let compressionCases: [CompressionCase] = [false, true].flatMap { tls in [
        CompressionCase(name: "takeover", tls: tls, offer: "permessage-deflate; client_max_window_bits", response: "permessage-deflate"),
        CompressionCase(name: "noContext", tls: tls, offer: "permessage-deflate; client_no_context_takeover; server_no_context_takeover",
                        response: "permessage-deflate; client_no_context_takeover; server_no_context_takeover"),
        CompressionCase(name: "windows", tls: tls, offer: "permessage-deflate; client_max_window_bits; server_max_window_bits=10",
                        response: "permessage-deflate; server_max_window_bits=10; client_max_window_bits=9"),
    ] }

    /// Server messages: wire bytes and decoded plaintext. RFC 7692 literals where they are valid
    /// for the negotiated mode; otherwise an independent system-zlib deflater with that window.
    static func serverMessages(_ name: String) throws -> [([UInt8], String)] {
        let v = WebSocketCompressionVectors.self
        let splitSync = WSWire.frame(1, [0xf2, 0x48, 0xcd], fin: false, rsv1: true) + WSWire.frame(0, [0xc9, 0xc9, 0x07, 0x00])
        switch name {
        case "takeover":
            return [(WSWire.frame(1, Array(v.stored), rsv1: true), "Hello"), (WSWire.frame(1, Array(v.multi), rsv1: true), "Hello"),
                    (splitSync, "Hello"), (WSWire.frame(1, Array(v.bfinal), rsv1: true), "Hello"),
                    (WSWire.frame(1, Array(v.takeover), rsv1: true), "Hello"), (WSWire.frame(1, Array(v.empty), rsv1: true), "")]
        case "noContext":
            return [(WSWire.frame(1, Array(v.sync), rsv1: true), "Hello"), (splitSync, "Hello"),
                    (WSWire.frame(1, Array(v.bfinal), rsv1: true), "Hello")]
        default:
            let deflater = try WebSocketDeflater(windowBits: 10)
            return try (0..<3).map { index in
                let text = String(repeating: "server window \(index) history ", count: 120)
                let bytes = Array(try deflater.message(Data(text.utf8)))
                if index == 1 {
                    return (WSWire.frame(1, Array(bytes.prefix(bytes.count / 2)), fin: false, rsv1: true)
                        + WSWire.frame(0, Array(bytes.dropFirst(bytes.count / 2))), text)
                }
                return (WSWire.frame(1, bytes, rsv1: true), text)
            }
        }
    }
    static func clientMessages(_ name: String) throws -> [([UInt8], String)] {
        let shared = try WebSocketDeflater(windowBits: name == "windows" ? 9 : 15)
        let texts = ["client says hello", "client says hello again, hello hello", String(repeating: "fragmented compressed client text ", count: 40)]
        return try texts.enumerated().map { index, text in
            let deflater = name == "noContext" ? try WebSocketDeflater() : shared
            let bytes = Array(try deflater.message(Data(text.utf8)))
            if index == 2 {
                return (WSWire.client(1, Array(bytes.prefix(bytes.count / 2)), fin: false, rsv1: true)
                    + WSWire.client(0, Array(bytes.dropFirst(bytes.count / 2))), text)
            }
            return (WSWire.client(1, bytes, rsv1: true), text)
        }
    }

    @Test(arguments: compressionCases)
    func compressedVectorsDecodeInBothDirections(_ mode: CompressionCase) async throws {
        let server = try Self.serverMessages(mode.name), client = try Self.clientMessages(mode.name)
        let serverBytes = server.flatMap(\.0), clientBytes = client.flatMap(\.0)
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let origin = try await WebSocketOrigin.start(tls: mode.tls, script: [.send(bytes: Data(serverBytes)), .expect(bytes: Data(clientBytes)), .closeTransport],
            directory: directory, responseExtensions: mode.response)
        let store = observationStore()
        do {
            try await Self.withServer(store: store, originCA: origin.ca) { proxy, ca in
                let peer = try await WSProxyPeer.connect(proxyPort: try #require(proxy.boundPort), originPort: origin.port,
                    tls: mode.tls ? try WSProxyPeer.roots(ca) : nil)
                do {
                    let head = try await WSProxyPeer.upgrade(peer, originPort: origin.port, absolute: !mode.tls, extensions: mode.offer)
                    #expect(head.contains("Sec-WebSocket-Extensions: \(mode.response)\r\n"))
                    #expect(try await peer.receive(count: serverBytes.count) == serverBytes)
                    try await peer.send(bytes: clientBytes)
                    try await peer.waitUntilClosed()
                    try await origin.waitUntilFinished()
                    #expect(origin.sent == serverBytes && origin.received == clientBytes)
                    #expect(origin.transcript.failures.isEmpty && peer.remainingBytes().isEmpty)
                    let (_, token) = try await Self.session(store)
                    try await waitUntil("both transport ends") { store.webSocketSummary(token: token)?.lifecycle == .transportEndedWithoutClose }
                    let rows = Self.rows(store, token)
                    for (direction, messages) in [(WebSocketDirection.serverToClient, server), (.clientToServer, client)] {
                        let recorded = rows.filter { $0.direction == direction }
                        #expect(recorded.count == messages.count, "\(direction)")
                        for (row, message) in zip(recorded, messages) {
                            #expect(row.kind == .text && row.compressed && row.utf8 == .valid, "row \(row.id)")
                            #expect(row.completedAt != nil && row.integrity == .transportComplete, "row \(row.id) \(row.diagnostics)")
                            #expect(Self.payload(store, token, row) == Array(message.1.utf8), "row \(row.id)")
                            #expect(row.decodedBytes == UInt64(message.1.utf8.count))
                        }
                    }
                    let summary = try #require(store.webSocketSummary(token: token))
                    #expect(summary.handshake.selectedExtensions.joined().contains("permessage-deflate"))
                    // Transport end (not a capture failure) moves each direction to stopped-until-reconnect.
                    #expect(summary.serverToClient.diagnostic == nil && summary.clientToServer.diagnostic == nil)
                    #expect(summary.serverToClient.capture == .contentStoppedUntilReconnect && summary.clientToServer.capture == .contentStoppedUntilReconnect)
                    #expect(summary.serverToClient.applicationBytes == UInt64(server.reduce(0) { $0 + $1.1.utf8.count }))
                    #expect(summary.clientToServer.applicationBytes == UInt64(client.reduce(0) { $0 + $1.1.utf8.count }))
                    #expect(!summary.lowerBound)
                    try await peer.close()
                } catch { try? await peer.close(); throw error }
            }
            Self.expectObserverReservationsReleased(store)
            try await origin.stop()
        } catch { try? await origin.stop(); throw error }
    }
}

// MARK: - Routing, stop and passthrough

extension WebSocketIntegrationTests {
    /// Real-server form of the HTTP/2 upgrade gate: the same MITM client connection first uses
    /// an h2 upstream, then its Upgrade opens a dedicated h1-only socket; h2 is used again later.
    /// The same-pool coexistence proof stays in HTTP2UpgradeTests (fixture with pool access).
    @Test func upgradeAfterH2UpstreamUsesDedicatedHTTP1AndH2StaysUsable() async throws {
        var response = HTTP2TestOrigin.Response(); response.supportsUpgrade = true; response.trailers = nil
        let origin = try await HTTP2TestOrigin.start(protocols: ["h2", "http/1.1"], response: response)
        let store = observationStore()
        do {
            try await Self.withServer(store: store, originCA: origin.ca) { server, ca in
                let port = try #require(server.boundPort)
                let first = try await WSProxyPeer.connect(proxyPort: port, originPort: origin.port, tls: try WSProxyPeer.roots(ca))
                let second: RawClient
                do {
                    try await first.send("GET /prime HTTP/1.1\r\nHost: localhost:\(origin.port)\r\n\r\n")
                    #expect(try await first.receive(until: "0\r\n\r\n").hasPrefix("HTTP/1.1 200"))
                    try await first.send(bytes: HTTP2UpgradeWire.request(target: "/ws", port: origin.port))
                    let head = try await first.receive(until: "\r\n\r\n")
                    #expect(head.hasPrefix("HTTP/1.1 101") && head.contains("Sec-WebSocket-Accept: \(HTTP2UpgradeWire.accept)\r\n"))
                    #expect(try await first.receive(count: HTTP2UpgradeWire.greeting.count) == HTTP2UpgradeWire.greeting)
                    try await first.send(bytes: HTTP2UpgradeWire.clientFrame)
                    #expect(try await first.receive(count: HTTP2UpgradeWire.serverFrame.count) == HTTP2UpgradeWire.serverFrame)
                    #expect(origin.counts.upgradeBytes == HTTP2UpgradeWire.clientFrame)
                    second = try await WSProxyPeer.connect(proxyPort: port, originPort: origin.port, tls: try WSProxyPeer.roots(ca))
                } catch { try? await first.close(); throw error }
                do {
                    try await second.send("GET /after HTTP/1.1\r\nHost: localhost:\(origin.port)\r\n\r\n")
                    #expect(try await second.receive(until: "0\r\n\r\n").hasPrefix("HTTP/1.1 200"))
                    #expect(origin.counts.negotiated == [.http2, .http1, .http2])
                    let prime = try await waitForFlow(store) { $0.path == "/prime" && $0.state == .completed }
                    let after = try await waitForFlow(store) { $0.path == "/after" && $0.state == .completed }
                    #expect(prime.transport.upstreamRequest == .http2 && after.transport.upstreamRequest == .http2)
                    let (upgraded, token) = try await Self.session(store)
                    #expect(upgraded.transport.upstreamRequest == .http1_1 && upgraded.transport.upstreamResponse == .http1_1)
                    try await waitUntil("three upgraded rows") { Self.rows(store, token).filter { $0.completedAt != nil }.count == 3 }
                    let rows = Self.rows(store, token)
                    #expect(rows.map(\.direction) == [.serverToClient, .clientToServer, .serverToClient])
                    #expect(rows.map(\.kind) == [.text, .binary, .binary])
                    #expect(rows.map { Self.payload(store, token, $0) } == [Array("Hi".utf8), [0x00, 0xff, 0x80, 0x01], [0x00, 0xff, 0x80, 0x01]])
                    try await first.close(); try await second.close()
                } catch { try? await first.close(); try? await second.close(); throw error }
            }
            Self.expectObserverReservationsReleased(store)
            try await origin.stop()
        } catch { try? await origin.stop(); throw error }
    }

    @Test(arguments: [false, true])
    func stopWithDetachedSocketActiveClosesBothPeersAndReleasesReservations(tls: Bool) async throws {
        let greeting = WSWire.frame(1, Array(WebSocketCompressionVectors.sync), rsv1: true)
        let deflater = try WebSocketDeflater()
        let request = WSWire.client(1, Array(try deflater.message(Data("still open".utf8))), rsv1: true)
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let origin = try await WebSocketOrigin.start(tls: tls, script: [.send(bytes: Data(greeting)), .expect(bytes: Data(request)), .barrier(name: "held")],
            directory: directory, responseExtensions: "permessage-deflate")
        let store = observationStore(), cleanup = WSBarrier()
        let stages = OSAllocatedUnfairLock(initialState: [WebSocketCoordinatorStage]())
        let hooks = WebSocketObservationHooks(beforeCleanup: { await cleanup.enter() }, coordinator: { stage in stages.withLock { $0.append(stage) } })
        let ca = try CertificateAuthority.generate(commonName: "WS stop proxy CA")
        var configuration = ProxyConfiguration(); configuration.port = 0
        if let originCA = origin.ca { configuration.upstreamTrustRoots = try WSProxyPeer.roots(originCA) }
        let server = ProxyServer(configuration: configuration, certificateAuthority: ca, store: store, passthrough: .init(),
            processLookup: .none, drainDeadline: Self.immediateDrain, webSocketHooks: hooks)
        var peer: RawClient?
        do {
            try await server.start()
            let connected = try await WSProxyPeer.connect(proxyPort: try #require(server.boundPort), originPort: origin.port,
                tls: tls ? try WSProxyPeer.roots(ca) : nil); peer = connected
            try await WSProxyPeer.upgrade(connected, originPort: origin.port, absolute: !tls, extensions: "permessage-deflate")
            #expect(try await connected.receive(count: greeting.count) == greeting)
            try await connected.send(bytes: request)
            try await origin.barriers.waitFor("held")
            let (_, token) = try await Self.session(store)
            try await waitUntil("two decoded rows") { Self.rows(store, token).filter { $0.completedAt != nil }.count == 2 }
            #expect(store.webSocketBudget.usedBytes(category: .native) > 0) // both live inflaters own zlib state
            let stopped = OSAllocatedUnfairLock(initialState: false)
            let stopping = Task { try await server.stop(); stopped.withLock { $0 = true } }
            try await cleanup.wait(timeout: .seconds(10), "worker cleanup barrier")
            // Transports are drained, but stop must still await the actual worker cleanup/join.
            #expect(!stopped.withLock { $0 })
            #expect(store.webSocketBudget.usedBytes(category: .working) >= 32_768)
            await cleanup.release()
            try await stopping.value
            try await connected.waitUntilClosed()
            try await origin.waitUntilClosed()
            let detachedChannelsClosed = !connected.isActive && origin.transcript.closed
            #expect(detachedChannelsClosed)
            Self.expectObserverReservationsReleased(store)
            #expect(stages.withLock { $0.filter { $0 == .beforeTaskPublication }.count } == 1)
            #expect(stages.withLock { $0.contains(.beforeWorkerJoin) })
            let summary = try #require(store.webSocketSummary(token: token))
            #expect(summary.lifecycle == .transportEndedWithoutClose)
            let rows = Self.rows(store, token)
            #expect(rows.map { Self.payload(store, token, $0) } == [Array("Hello".utf8), Array("still open".utf8)])
            #expect(origin.received == request && origin.sent == greeting)
            store.clear()
            for category in WebSocketMemoryCategory.allCases { #expect(store.webSocketBudget.usedBytes(category: category) == 0, "\(category)") }
            try await connected.close(); peer = nil
            try await origin.stop()
        } catch {
            await cleanup.release()
            if let peer { try? await peer.close() }
            try? await server.stop(); try? await origin.stop(); throw error
        }
    }

    @Test func tlsPassthroughRelaysButRecordsNoWebSocketContent() async throws {
        let server1 = WSWire.frame(1, Array("secret greeting".utf8)), client1 = WSWire.client(1, Array("secret reply".utf8))
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let origin = try await WebSocketOrigin.start(tls: true, script: [.send(bytes: Data(server1)), .expect(bytes: Data(client1)), .closeTransport],
            directory: directory)
        let store = observationStore()
        do {
            try await Self.withServer(store: store, originCA: nil, passthrough: PassthroughRegistry(hosts: ["localhost"])) { server, _ in
                // The client trusts only the origin CA: it is a genuine end-to-end TLS tunnel.
                let peer = try await WSProxyPeer.connect(proxyPort: try #require(server.boundPort), originPort: origin.port,
                    tls: try WSProxyPeer.roots(try #require(origin.ca)))
                do {
                    try await WSProxyPeer.upgrade(peer, originPort: origin.port, absolute: false)
                    #expect(try await peer.receive(count: server1.count) == server1)
                    try await peer.send(bytes: client1)
                    try await peer.waitUntilClosed()
                    try await origin.waitUntilFinished()
                    #expect(origin.received == client1 && origin.sent == server1)
                    let tunnel = try await waitForFlow(store) { $0.state == .tunnel }
                    #expect(store.allFlows().count == 1 && tunnel.statusCode != 101)
                    #expect(store.allFlows().allSatisfy { store.webSocketToken(flowID: $0.id) == nil })
                    for category in WebSocketMemoryCategory.allCases { #expect(store.webSocketBudget.usedBytes(category: category) == 0) }
                    try await peer.close()
                } catch { try? await peer.close(); throw error }
            }
            try await origin.stop()
        } catch { try? await origin.stop(); throw error }
    }
}

// MARK: - Lifecycle races through the real server

extension WebSocketIntegrationTests {
    /// Stop while the origin holds the 101: the pending original-heads charge is released, no
    /// session is created and both sockets close.
    @Test func stopDuringPendingUpgradeReleasesPendingCaptureAndClosesPeers() async throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let origin = try await WebSocketOrigin.start(tls: false, script: [.send(bytes: Data(WSWire.frame(1, Array("late".utf8))))],
            directory: directory, handshakeBarrier: "pending")
        let store = observationStore()
        do {
            try await Self.withServer(store: store, originCA: nil) { server, _ in
                let peer = try await WSProxyPeer.connect(proxyPort: try #require(server.boundPort), originPort: origin.port, tls: nil)
                do {
                    try await peer.send(bytes: WSWire.upgradeRequest(target: "http://localhost:\(origin.port)/chat", port: origin.port, key: WSWire.randomKey()))
                    try await origin.barriers.waitFor("pending")
                    let flow = try await waitForFlow(store) { $0.path == "/chat" }
                    #expect(store.webSocketBudget.usedBytes(category: .metadata) > 0) // pending original heads own their charge
                    try await server.stop()
                    try await peer.waitUntilClosed()
                    try await origin.waitUntilClosed()
                    origin.barriers.release("pending")
                    #expect(!String(decoding: peer.remainingBytes(), as: UTF8.self).contains("101"))
                    #expect(store.webSocketToken(flowID: flow.id) == nil)
                    for category in WebSocketMemoryCategory.allCases { #expect(store.webSocketBudget.usedBytes(category: category) == 0, "\(category)") }
                    try await peer.close()
                } catch { origin.barriers.release("pending"); try? await peer.close(); throw error }
            }
            try await origin.stop()
        } catch { try? await origin.stop(); throw error }
    }

    /// With one observation slot, a retiring worker (both EOFs delivered, cleanup held) keeps
    /// its slot: a new Upgrade is admitted metadata-only. After the actual join the slot is free.
    @Test func retiringWorkerKeepsItsSlotUntilActualJoin() async throws {
        var limits = WebSocketLimits(); limits.observingSessions = 1
        let store = observationStore(limits), cleanup = WSBarrier()
        let stages = OSAllocatedUnfairLock(initialState: [WebSocketCoordinatorStage]())
        let hooks = WebSocketObservationHooks(beforeCleanup: { await cleanup.enter() }, coordinator: { stage in stages.withLock { $0.append(stage) } })
        let frames = ["one", "two", "three"].map { WSWire.frame(1, Array($0.utf8)) }
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var origins: [WebSocketOrigin] = []
        do {
            origins.append(try await WebSocketOrigin.start(tls: false, script: [.send(bytes: Data(frames[0])), .closeTransport], directory: directory))
            origins.append(try await WebSocketOrigin.start(tls: false, script: [.send(bytes: Data(frames[1])), .barrier(name: "hold"), .closeTransport], directory: directory))
            origins.append(try await WebSocketOrigin.start(tls: false, script: [.send(bytes: Data(frames[2])), .closeTransport], directory: directory))
            try await Self.withServer(store: store, originCA: nil, hooks: hooks) { server, _ in
              do {
                let port = try #require(server.boundPort)
                var seen: Set<Int> = []
                func next(_ index: Int) async throws -> (RawClient, WebSocketSessionToken) {
                    let peer = try await WSProxyPeer.connect(proxyPort: port, originPort: origins[index].port, tls: nil)
                    try await WSProxyPeer.upgrade(peer, originPort: origins[index].port, absolute: true)
                    #expect(try await peer.receive(count: frames[index].count) == frames[index])
                    let known = seen
                    let flow = try await waitForFlow(store) { $0.statusCode == 101 && !known.contains($0.id) }
                    seen.insert(flow.id)
                    return (peer, try #require(store.webSocketToken(flowID: flow.id)))
                }
                let (first, firstToken) = try await next(0)
                try await first.waitUntilClosed()
                try await cleanup.wait(timeout: .seconds(10), "retiring worker cleanup") // both ends delivered; not joined
                let (second, secondToken) = try await next(1)
                #expect(store.webSocketSummary(token: secondToken)?.clientToServer.capture == .metadataOnly)
                origins[1].barriers.release("hold")
                try await second.waitUntilClosed()
                let mark = stages.withLock { $0.count }
                await cleanup.release()
                try await waitUntil("actual worker join then a supervisor pass") {
                    let after = stages.withLock { Array($0.dropFirst(mark)) }
                    guard let join = after.firstIndex(of: .beforeWorkerJoin) else { return false }
                    return after[join...].contains(.afterSupervisorPass)
                }
                let (third, thirdToken) = try await next(2)
                try await third.waitUntilClosed()
                try await waitUntil("third session captured") { Self.rows(store, thirdToken).first?.completedAt != nil }
                #expect(Self.rows(store, thirdToken).map { Self.payload(store, thirdToken, $0) } == [Array("three".utf8)])
                #expect(Self.rows(store, secondToken).isEmpty)
                #expect(Self.rows(store, firstToken).map { Self.payload(store, firstToken, $0) } == [Array("one".utf8)])
                for peer in [first, second, third] { try await peer.close() }
              } catch {
                // Never leave the held cleanup blocking the server stop on a failure path.
                await cleanup.release(); origins.forEach { $0.barriers.release("hold") }; throw error
              }
            }
            Self.expectObserverReservationsReleased(store)
            for origin in origins { try await origin.stop() }
        } catch {
            await cleanup.release(); origins.forEach { $0.barriers.release("hold") }
            for origin in origins { try? await origin.stop() }
            throw error
        }
    }
}

// MARK: - Same read batch: 101 + first frame + EOF

extension WebSocketIntegrationTests {
    /// The origin's 101, its first frame and its EOF are handled before the scheduled decoder
    /// removal runs. The first frame must still reach the client before the relay closes it.
    @Test(arguments: [false, true])
    func samePacketGreetingThenImmediateEOFReachesClient(observe: Bool) async throws {
        let store = observationStore()
        let coordinator = WebSocketCaptureCoordinator(store: store)
        let workers = NIOThreadPool(numberOfThreads: 1); workers.start()
        let greeting = WSWire.frame(8, [0x03, 0xf0] + Array("policy".utf8)) // an immediate Close 1008
        func exercise() throws {
            let loop = EmbeddedEventLoop()
            let origin = EmbeddedChannel(loop: loop), trace = WSWireTrace()
            try origin.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 12346)).wait()
            let environment = ProxyEnvironment(configuration: .init(), recording: FlowRecording(store: store, isEnabled: ManagedAtomic(true)),
                tls: TLSInterception(certificateAuthority: try CertificateAuthority.generate()), passthrough: .init(),
                clientLookup: ClientLookupBatcher(processLookup: .none, threadPool: workers), webSockets: observe ? coordinator : nil)
            let handler = ProxyHandler(mode: .forwardProxy, environment: environment, connectionFactory: { _, _, loop in loop.makeSucceededFuture(origin) })
            let client = EmbeddedChannel(handlers: [trace, HTTPMessageTranslation.responseEncoder(), HTTP1TransferCodingFramer<HTTPResponseHead>(),
                ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes)), handler], loop: loop)
            try client.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 12345)).wait()
            try client.writeInbound(ByteBuffer(bytes: HTTP2UpgradeWire.request(target: "http://localhost:12346/ws", port: 12346)))
            while (try origin.readOutbound(as: IOData.self)) != nil {}
            // One read batch: data then EOF, with no event-loop turn in between.
            origin.pipeline.fireChannelRead(ByteBuffer(bytes: HTTP2UpgradeWire.response + greeting))
            origin.pipeline.fireChannelReadComplete()
            origin.close(promise: nil)
            loop.run()
            #expect(trace.bytes.suffix(greeting.count).elementsEqual(greeting), "client bytes: \(trace.bytes.suffix(16))")
            #expect(!client.isActive && !origin.isActive)
            _ = try? client.finish(); _ = try? origin.finish()
        }
        try exercise()
        await coordinator.shutdown(); try await workers.shutdownGracefully()
        Self.expectObserverReservationsReleased(store)
    }
}

extension WebSocketIntegrationTests {
    /// Production adapter on one EmbeddedEventLoop; `origin` is returned by the existing factory seam.
    static func embeddedProxy(store: FlowStore, workers: NIOThreadPool, passthrough: PassthroughRegistry = .init(),
                              loop: EmbeddedEventLoop, origin: EmbeddedChannel, trace: WSWireTrace) throws -> EmbeddedChannel {
        let environment = ProxyEnvironment(configuration: .init(), recording: FlowRecording(store: store, isEnabled: ManagedAtomic(true)),
            tls: TLSInterception(certificateAuthority: try CertificateAuthority.generate()), passthrough: passthrough,
            clientLookup: ClientLookupBatcher(processLookup: .none, threadPool: workers))
        let handler = ProxyHandler(mode: .forwardProxy, environment: environment, connectionFactory: { _, _, loop in loop.makeSucceededFuture(origin) })
        let client = EmbeddedChannel(handlers: [trace, HTTPMessageTranslation.responseEncoder(), HTTP1TransferCodingFramer<HTTPResponseHead>(),
            ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes)), handler], loop: loop)
        try client.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 12345)).wait()
        return client
    }
    static func outbound(_ channel: EmbeddedChannel) throws -> [UInt8] {
        var bytes: [UInt8] = []
        while let output = try channel.readOutbound(as: IOData.self) { if case .byteBuffer(let buffer) = output { bytes += buffer.readableBytesView } }
        return bytes
    }

    /// Client-side half of the upgrade handoff: bytes the client pipelined behind its Upgrade
    /// request wait in the request decoder. They must reach the origin only after the origin's
    /// write-observing response decoder is gone (else NIO traps), and a client EOF right after
    /// the 101 must not drop them.
    @Test(arguments: [false, true])
    func clientLeftoverAfter101ReachesOrigin(clientEOF: Bool) async throws {
        let store = observationStore(), workers = NIOThreadPool(numberOfThreads: 1); workers.start()
        let early = WSWire.client(1, Array("early".utf8))
        func exercise() throws {
            let loop = EmbeddedEventLoop(), origin = EmbeddedChannel(loop: loop)
            try origin.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 12346)).wait()
            let client = try Self.embeddedProxy(store: store, workers: workers, loop: loop, origin: origin, trace: WSWireTrace())
            client.pipeline.fireChannelRead(ByteBuffer(bytes: HTTP2UpgradeWire.request(target: "http://localhost:12346/ws", port: 12346) + early))
            loop.run()
            #expect(String(decoding: try Self.outbound(origin), as: UTF8.self).hasPrefix("GET /ws HTTP/1.1"))
            // One loop iteration: the 101 starts the handoff, then the client EOF arrives.
            origin.pipeline.fireChannelRead(ByteBuffer(bytes: HTTP2UpgradeWire.response))
            if clientEOF { client.close(promise: nil) }
            loop.run()
            #expect(try Self.outbound(origin) == early)
            #expect(client.isActive == !clientEOF && origin.isActive == !clientEOF)
            _ = try? client.finish(); _ = try? origin.finish()
        }
        try exercise()
        try await workers.shutdownGracefully()
    }

    /// CONNECT tunnel: early tunnel bytes behind the CONNECT head (e.g. a ClientHello) wait in
    /// the request decoder; a client EOF in the iteration that installs the tunnel must not drop them.
    @Test func connectTunnelEarlyBytesThenImmediateEOFReachUpstream() async throws {
        let store = observationStore(), workers = NIOThreadPool(numberOfThreads: 1); workers.start()
        let early = Array("early tunnel bytes".utf8)
        func exercise() throws {
            let loop = EmbeddedEventLoop(), origin = EmbeddedChannel(loop: loop), trace = WSWireTrace()
            try origin.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 443)).wait()
            let client = try Self.embeddedProxy(store: store, workers: workers, passthrough: PassthroughRegistry(hosts: ["localhost"]),
                                                loop: loop, origin: origin, trace: trace)
            // CONNECT head + early bytes in one read; the tunnel is installed and the client EOF
            // arrives before the decoder's scheduled removal runs.
            client.pipeline.fireChannelRead(ByteBuffer(bytes: Array("CONNECT localhost:443 HTTP/1.1\r\nHost: localhost:443\r\n\r\n".utf8) + early))
            client.close(promise: nil)
            loop.run()
            #expect(String(decoding: trace.bytes, as: UTF8.self).hasPrefix("HTTP/1.1 200 Connection Established"))
            #expect(try Self.outbound(origin) == early)
            #expect(!client.isActive && !origin.isActive)
            _ = try? client.finish(); _ = try? origin.finish()
        }
        try exercise()
        #expect(store.allFlows().count == 1 && store.allFlows().first?.state == .tunnel)
        try await workers.shutdownGracefully()
    }
}
