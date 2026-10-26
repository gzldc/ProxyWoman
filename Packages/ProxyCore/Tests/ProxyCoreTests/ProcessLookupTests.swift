import FlowStore
import Foundation
import NIOCore
import NIOPosix
import Testing
@testable import ProxyCore

private struct PathCase: Sendable, CustomTestStringConvertible {
    let path: String
    let name: String
    var testDescription: String { name }
}

private let pathCases: [PathCase] = [
    PathCase(
        path: "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/1/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper",
        name: "Google Chrome"),
    PathCase(path: "/Applications/Safari.app/Contents/MacOS/Safari", name: "Safari"),
    PathCase(path: "/usr/bin/curl", name: "curl"),
    PathCase(
        path: "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.Networking.xpc/Contents/MacOS/com.apple.WebKit.Networking",
        name: "com.apple.WebKit.Networking"),
]

@Test(.productionChinese, arguments: pathCases)
private func appNameFromPath(testCase: PathCase) {
    #expect(ProcessLookup.appName(fromExecutablePath: testCase.path) == testCase.name)
}

@Test(.productionChinese) func noneLookupReturnsNil() {
    #expect(ProcessLookup.none.lookup(12345, 9090) == nil)
}

@Test(.productionChinese) func liveLookupFindsOwnProcess() async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    do {
        let server = try await ServerBootstrap(group: group)
            .childChannelInitializer { $0.eventLoop.makeSucceededFuture(()) }
            .bind(host: "127.0.0.1", port: 0).get()
        let listenPort = try #require(server.localAddress?.port)
        let client = try await ClientBootstrap(group: group)
            .connect(host: "127.0.0.1", port: listenPort).get()
        let clientPort = try #require(client.localAddress?.port)

        let app = try #require(ProcessLookup.live.lookup(clientPort, listenPort))
        #expect(app.pid == getpid())
        #expect(!app.name.isEmpty)
        #expect(app.executablePath != nil)

        try await client.close()
        try await server.close()
    } catch {
        try? await group.shutdownGracefully()
        throw error
    }
    try await group.shutdownGracefully()
}

@Test(.productionChinese) func liveLookupReturnsNilForUnknownPorts() {
    // Port 1 is never used as a client port on loopback in tests.
    #expect(ProcessLookup.live.lookup(1, 2) == nil)
}

@Test(.productionChinese) func liveLookupAllResolvesSeveralClientsInOneScan() async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    do {
        let server = try await ServerBootstrap(group: group)
            .childChannelInitializer { $0.eventLoop.makeSucceededFuture(()) }
            .bind(host: "127.0.0.1", port: 0).get()
        let listenPort = try #require(server.localAddress?.port)
        var clients: [Channel] = []
        for _ in 0..<3 {
            clients.append(try await ClientBootstrap(group: group).connect(host: "127.0.0.1", port: listenPort).get())
        }
        let ports = Set(clients.compactMap { $0.localAddress?.port })

        let owners = ProcessLookup.live.lookupAll(ports.union([1]), listenPort)
        #expect(Set(owners.keys) == ports)
        let expectedPID = getpid()
        for (port, owner) in owners {
            let actualPID = owner.pid
            #expect(actualPID == expectedPID, "clientPort=\(port), listenPort=\(listenPort)")
        }

        for client in clients { try await client.close() }
        try await server.close()
    } catch {
        try? await group.shutdownGracefully()
        throw error
    }
    try await group.shutdownGracefully()
}

@Test(.productionChinese) func singleLookupInitDerivesLookupAll() {
    let lookup = ProcessLookup { clientPort, _ in
        clientPort == 7 ? ClientApp(pid: 7, name: "seven") : nil
    }
    #expect(lookup.lookupAll([7, 8], 9090) == [7: ClientApp(pid: 7, name: "seven")])
    #expect(ProcessLookup.none.lookupAll([7], 9090).isEmpty)
}
