import AppCore
import FlowStore
import Foundation
import MCPKit
import MCPWire
import Testing
@testable import ProxyWoman

/// With MCP off the app must behave exactly as before, and with MCP on and a client connected the proxied bytes
/// must still be the same (spec section 2: features off or idle => traffic byte-for-byte identical). The
/// MCP server only ever reads the flow store; it never sits between a client and an origin.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2)), .productionChinese) struct MCPByteIdentityTests {
    private static let body = "mcp-byte-identity-body"

    /// One POST through the proxy to the loopback origin on its own connection; every byte the proxy
    /// sends back until it closes.
    private func exchange(proxyPort: Int, originPort: Int) async throws -> [UInt8] {
        let authority = "127.0.0.1:\(originPort)"
        let connection = try await LoopbackClient.connect(port: proxyPort)
        do {
            try await connection.send(
                "POST http://\(authority)/identity?x=1 HTTP/1.1\r\nHost: \(authority)\r\n"
                    + "Content-Type: text/plain\r\nContent-Length: \(Self.body.utf8.count)\r\nX-Probe: same\r\n"
                    + "Connection: close\r\n\r\n\(Self.body)")
            let bytes = try await connection.bytesUntilClose()
            await connection.close()
            return bytes
        } catch {
            await connection.close()
            throw error
        }
    }

    @Test func proxyBytesAreIdenticalWithMCPOffAndOn() async throws {
        let origin = try await LoopbackOrigin.start()
        let harness: BridgeHarness
        do {
            harness = try await BridgeHarness.start(rules: [])
        } catch {
            await origin.stop()
            throw error
        }
        let rig: Rig
        do {
            rig = try await Rig(store: harness.store)
        } catch {
            await harness.stop()
            await origin.stop()
            throw error
        }

        do {
            // MCP off: the controller exists but has started nothing.
            #expect(rig.controller.status == .off)
            let off = try await exchange(proxyPort: harness.proxyPort, originPort: origin.port)
            #expect(String(decoding: off, as: UTF8.self).hasPrefix("HTTP/1.1 200"))
            #expect(String(decoding: off, as: UTF8.self).hasSuffix("origin-ok"))
            #expect(origin.requests.count == 1 && origin.connections == 1)

            // MCP on, a client connected that has already read the flow list.
            rig.controller.apply(enabled())
            #expect(rig.controller.status == .listening)
            let shake = try handshake(in: rig.directory)
            let probe = try Probe(path: shake.socketPath)
            #expect(await probe.hello(token: shake.token) == #"{"ok":true}"#)
            probe.send(
                #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_flows","arguments":{}}}"#)
            let listed = try decodeToolResult(await probe.readLine())
            #expect(!listed.isError, "\(listed.body)")
            #expect((listed.body["flows"]?.arrayValue?.count ?? 0) >= 1, "the tool reads the proxy's own store")

            let on = try await exchange(proxyPort: harness.proxyPort, originPort: origin.port)
            #expect(on == off, "the client got different bytes with MCP on")

            // The origin saw the same request twice, byte for byte as far as it can tell, and MCP opened
            // no upstream connection of its own: one connection per proxied request, nothing else.
            let requests = origin.requests
            #expect(requests.count == 2)
            #expect(requests[1].method == requests[0].method && requests[1].uri == requests[0].uri)
            #expect(requests[1].headers == requests[0].headers)
            #expect(origin.bodies.count == 2 && origin.bodies[1] == origin.bodies[0])
            #expect(origin.bodies[0] == Array(Self.body.utf8))
            #expect(origin.connections == 2)

            // The client is still served after the exchange.
            probe.send(#"{"jsonrpc":"2.0","id":2,"method":"ping"}"#)
            #expect(await probe.readLine() != nil)
        } catch {
            await rig.finish()
            await harness.stop()
            await origin.stop()
            throw error
        }
        await rig.finish()
        await harness.stop()
        await origin.stop()
    }

    @Test func mcpOffCreatesNoDirectoryNoSocketNoThread() async throws {
        // Threads cannot be enumerated from here. What starts them is `start()`, and that only happens when the
        // status leaves `.off`, so: still off, and neither the MCP directory nor anything in it exists.
        let rig = try await Rig()
        #expect(rig.controller.status == .off)
        #expect(!exists(rig.directory))
        rig.controller.apply(MCPSettings())
        #expect(rig.controller.status == .off)
        #expect(!exists(rig.directory))
        #expect(!lstatExists(MCPPaths.socketURL(in: rig.directory).path))
        #expect(!lstatExists(MCPPaths.handshakeURL(in: rig.directory).path))
        // Writes permissions alone do not switch anything on; only the master switch does.
        var permissionsOnly = MCPSettings()
        permissionsOnly.writeTools = [.createRule]
        rig.controller.apply(permissionsOnly)
        #expect(rig.controller.status == .off && !exists(rig.directory))
        #expect(try FileManager.default.contentsOfDirectory(atPath: rig.scratch.root.path).sorted() == ["work"])
        await rig.finish()
    }
}
