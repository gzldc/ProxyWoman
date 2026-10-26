import FlowStore
import Foundation
import Testing
@testable import ProxyCore
@testable import RulesEngine

/// The Allow list and Block list at CONNECT: a host-level block answers 403 before any tunnel is
/// opened, an Allow miss tunnels untouched and unrecorded, and an empty or absent policy leaves
/// the CONNECT response and the relayed bytes exactly as before.
@Suite(.serialized, .timeLimit(.minutes(2)), .productionChinese) struct ConnectTrafficPolicyTests {
    private static func provider(
        allow: [String]? = nil, block: [RuleMatcher]? = nil, mode: BlockDisplayMode = .show
    ) -> (provider: TrafficPolicyProvider, blockID: UUID?) {
        var policy = TrafficPolicy()
        if let allow {
            policy.allowEnabled = true
            policy.allowEntries = allow.map { TrafficFilterEntry(matcher: RuleMatcher(hostPattern: $0)) }
        }
        var blockID: UUID?
        if let block {
            policy.blockEnabled = true
            policy.blockMode = mode
            policy.blockEntries = block.map { TrafficFilterEntry(matcher: $0) }
            blockID = policy.blockEntries.first?.id
        }
        return (TrafficPolicyProvider(policy), blockID)
    }

    private static let established = "HTTP/1.1 200 Connection Established\r\n\r\n"

    private static func withOrigin(_ body: (TestOriginServer) async throws -> Void) async throws {
        let origin = try await TestOriginServer.start()
        do { try await body(origin) } catch { try? await origin.stop(); throw error }
        try await origin.stop()
    }

    private static func connect(_ fx: RulesComposeServer, to port: Int) async throws -> RawClient {
        let client = try await RawClient.connect(port: try fx.port)
        do {
            try await client.send("CONNECT 127.0.0.1:\(port) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n\r\n")
        } catch { try? await client.close(); throw error }
        return client
    }

    @Test func blockedConnectGets403BeforeAnyTunnel() async throws {
        try await Self.withOrigin { origin in
            let (traffic, blockID) = Self.provider(block: [RuleMatcher(hostPattern: "127.0.0.1")])
            try await RulesComposeServer.run(traffic: traffic) { fx in
                let client = try await Self.connect(fx, to: origin.port)
                do {
                    try await client.waitUntilClosed()
                    let text = String(decoding: client.remainingBytes(), as: UTF8.self)
                    try await client.close()
                    #expect(text.hasPrefix("HTTP/1.1 403"), "\(text)")
                    #expect(text.contains("127.0.0.1"))
                } catch { try? await client.close(); throw error }
                #expect(origin.acceptedConnections == 0)
                let flow = try await waitForFlow(fx.store) { $0.method == "CONNECT" && $0.state != .inProgress }
                if case .failed = flow.state {} else { Issue.record("expected a failed CONNECT flow, got \(flow.state)") }
                #expect(flow.provenance.tools.blockedByEntry == blockID)
                #expect(flow.host == "127.0.0.1")
            }
        }
    }

    @Test func blockedConnectInHideModeRecordsNothing() async throws {
        try await Self.withOrigin { origin in
            let (traffic, _) = Self.provider(block: [RuleMatcher(hostPattern: "127.0.0.1")], mode: .hide)
            try await RulesComposeServer.run(traffic: traffic) { fx in
                let client = try await Self.connect(fx, to: origin.port)
                do {
                    try await client.waitUntilClosed()
                    let text = String(decoding: client.remainingBytes(), as: UTF8.self)
                    try await client.close()
                    #expect(text.hasPrefix("HTTP/1.1 403"), "\(text)")
                } catch { try? await client.close(); throw error }
                // The record is made before the response is written, so nothing can appear later.
                #expect(fx.store.allFlows().isEmpty)
                #expect(origin.acceptedConnections == 0)
            }
        }
    }

    @Test func pathLevelBlockEntryDoesNotBlockConnect() async throws {
        try await Self.withOrigin { origin in
            let (traffic, _) = Self.provider(block: [RuleMatcher(hostPattern: "127.0.0.1", path: .prefix("/private"))])
            try await RulesComposeServer.run(traffic: traffic) { fx in
                let client = try await Self.connect(fx, to: origin.port)
                do {
                    let head = try await client.receive(until: "\r\n\r\n")
                    try await client.close()
                    #expect(head == Self.established)
                } catch { try? await client.close(); throw error }
            }
        }
    }

    @Test func allowMissTunnelsUntouchedAndUnrecorded() async throws {
        try await Self.withOrigin { origin in
            let (traffic, _) = Self.provider(allow: ["elsewhere.test"])
            try await RulesComposeServer.run(traffic: traffic) { fx in
                let client = try await Self.connect(fx, to: origin.port)
                do {
                    #expect(try await client.receive(until: "\r\n\r\n") == Self.established)
                    try await client.send("GET /hello HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
                    let response = try await client.receive(until: "hello")
                    #expect(response.hasPrefix("HTTP/1.1 200 OK\r\n"), "\(response)")
                    try await client.close()
                } catch { try? await client.close(); throw error }
                #expect(origin.acceptedConnections == 1)
                #expect(fx.store.allFlows().isEmpty)
            }
        }
    }

    @Test func allowHitKeepsExistingTunnelBehaviour() async throws {
        try await Self.withOrigin { origin in
            let (traffic, _) = Self.provider(allow: ["127.0.0.1"])
            try await RulesComposeServer.run(traffic: traffic, configure: { $0.decryption.enabled = false }) { fx in
                let client = try await Self.connect(fx, to: origin.port)
                do {
                    #expect(try await client.receive(until: "\r\n\r\n") == Self.established)
                    try await client.send("GET /hello HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
                    _ = try await client.receive(until: "hello")
                    try await client.close()
                } catch { try? await client.close(); throw error }
                let flow = try await waitForFlow(fx.store) { $0.method == "CONNECT" }
                #expect(flow.host == "127.0.0.1")
                #expect(flow.provenance.tools.isEmpty)
                try await waitUntil("the tunnel flow to complete") {
                    fx.store.allFlows().first { $0.method == "CONNECT" }?.completedAt != nil
                }
                #expect(fx.store.allFlows().count == 1)
                #expect(fx.store.allFlows()[0].state == .tunnel)
            }
        }
    }

    @Test func emptyPolicyConnectResponseIsByteIdentical() async throws {
        func exchange(traffic: TrafficPolicyProvider?) async throws -> (established: String, tunnelled: String) {
            var captured: (String, String) = ("", "")
            try await Self.withOrigin { origin in
                try await RulesComposeServer.run(traffic: traffic) { fx in
                    let client = try await Self.connect(fx, to: origin.port)
                    do {
                        let head = try await client.receive(until: "\r\n\r\n")
                        try await client.send("GET /hello HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
                        let body = try await client.receive(until: "hello")
                        try await client.close()
                        captured = (head, body)
                    } catch { try? await client.close(); throw error }
                }
            }
            return captured
        }
        let without = try await exchange(traffic: nil)
        let empty = try await exchange(traffic: TrafficPolicyProvider(TrafficPolicy()))
        #expect(without.established == Self.established)
        #expect(empty.established == without.established)
        #expect(empty.tunnelled == without.tunnelled)
    }
}
