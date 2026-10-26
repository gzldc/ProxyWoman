import CertKit
import FlowStore
import Foundation
import Localization
import NIOCore
import NIOPosix
import ProxyCore
import RulesEngine
import Testing
import os
@testable import AppCore

/// "Save this response as a mock" end to end: a real proxy captures a real loopback response, the
/// editor model turns the captured flow into a Map Local draft (copying the body through a bounded
/// read lease), the rule is saved through the real repository, and the same request is answered
/// locally with the very bytes the client got the first time, without touching the origin.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .productionChinese) struct ResponseMockRoundTripTests {
    @Test func capturedGzipResponseBecomesMockServingIdenticalBytes() async throws {
        try await withRig { rig in
            let first = try await rig.fetch("GET", "/gzip?v=1")
            #expect(first.status == 200)
            #expect(first.body == gzipBytes)
            #expect(first.values("content-encoding") == ["gzip"])
            #expect(rig.origin.requests == ["GET /gzip?v=1"])

            // The captured body is what travelled on the wire: still compressed, not decoded.
            let flow = try await rig.completedFlow("/gzip?v=1")
            let captured = try #require(flow.messages[.downstreamResponse])
            #expect(try captured.body?.load() == Data(gzipBytes))
            #expect(captured.headers.contains { $0.name.lowercased() == "content-encoding" && $0.value == "gzip" })
            #expect(try flow.messages[.upstreamResponse]?.body?.load() == Data(gzipBytes))

            let model = try await rig.loadedModel()
            #expect(await model.beginMockDraft(from: flow, acquireBody: rig.acquire) == nil)
            #expect(model.error == nil)
            let draft = try #require(model.draft)
            let asset = try #require(draft.mapLocal.asset)
            #expect(asset.size == Int64(gzipBytes.count))
            // Content-Encoding is kept with the raw bytes (decoding them would break the pair).
            #expect(draft.mapLocal.headers.contains { $0.name == "Content-Encoding" && $0.value == "gzip" })
            #expect(await model.save())
            #expect(try Data(contentsOf: rig.assetFile(asset.id)) == Data(gzipBytes))
            #expect(rig.repository.provider.current().rules.count == 1)

            let second = try await rig.fetch("GET", "/gzip?v=1")
            #expect(rig.origin.requests == ["GET /gzip?v=1"], "the mock answered; the origin saw nothing new")
            #expect(rig.origin.connections == 1)
            #expect(second.status == first.status)
            #expect(second.reason == first.reason)
            #expect(second.body == first.body)
            #expect(second.comparableFields == first.comparableFields, "\(second.fields) vs \(first.fields)")
            #expect(second.values("content-length") == [String(gzipBytes.count)])
            #expect(second.values("x-multi") == ["a", "b"] && second.values("set-cookie") == ["a=1", "b=2"])

            let served = try await rig.waitForFlow { $0.path == "/gzip?v=1" && $0.id != flow.id && $0.state == .completed }
            #expect(served.provenance.generatedResponse?.assetID == asset.id)
            #expect(served.messages[.upstreamRequest] == nil)
            #expect(try served.messages[.downstreamResponse]?.body?.load() == Data(gzipBytes))
        }
    }

    @Test func spooledLargeBodyBecomesMockWithoutLoadingWhole() async throws {
        try await withRig { rig in
            let first = try await rig.fetch("GET", "/big")
            #expect(first.body.count == bigBytes.count && first.body == bigBytes)
            let flow = try await rig.completedFlow("/big")
            let ref = try #require(flow.messages[.downstreamResponse]?.body?.ref)
            // Over the memory limit: the capture lives in a file, not in memory.
            guard case .managed(let handle) = ref else { Issue.record("expected a managed body, got \(ref)"); return }
            #expect(handle.isOnDisk, "the \(bigBytes.count) byte capture was spilled")

            let model = try await rig.loadedModel()
            #expect(await model.beginMockDraft(from: flow, acquireBody: rig.acquire) == nil)
            #expect(model.error == nil)
            let asset = try #require(model.draft?.mapLocal.asset)
            #expect(asset.size == Int64(bigBytes.count))

            // Copied piece by piece: every read the editor answered was at most 64 KiB, however much
            // the probe asked for, and together they are exactly the body.
            let reads = rig.probe.returnedSizes.filter { $0 > 0 }
            #expect(reads.allSatisfy { $0 <= 65_536 }, "largest read \(reads.max() ?? 0)")
            #expect(reads.count == bigBytes.count / 65_536, "\(reads.count) reads")
            #expect(reads.reduce(0, +) == bigBytes.count)
            #expect(rig.probe.askedSizes.allSatisfy { $0 > 0 })

            #expect(await model.save())
            #expect(try Data(contentsOf: rig.assetFile(asset.id)) == Data(bigBytes))
            let second = try await rig.fetch("GET", "/big")
            #expect(rig.origin.requests == ["GET /big"])
            #expect(second.status == first.status && second.body == bigBytes)
            #expect(second.comparableFields == first.comparableFields)
            #expect(second.values("content-length") == [String(bigBytes.count)])
        }
    }

    @Test func truncatedCaptureIsRefusedWithLocalizedReason() async throws {
        try await withRig(maxCapturedBodyBytes: 65_536) { rig in
            let reply = try await rig.fetch("GET", "/trunc")
            #expect(reply.body == truncBytes, "the client still got the whole body")
            let flow = try await rig.completedFlow("/trunc")
            let message = try #require(flow.messages[.downstreamResponse])
            #expect(message.body?.count == 65_536, "only a prefix was kept")

            let model = try await rig.loadedModel()
            let reason = await model.beginMockDraft(from: flow, acquireBody: rig.acquire)
            #expect(reason == .bodyTruncated)
            let text = try #require(reason).localizedDescription
            #expect(text == L10n.string("rules.mock.blocked.bodyTruncated"))
            #expect(!text.isEmpty && !text.hasPrefix("rules."), "a sentence, not a key: \(text)")
            // Nothing was started, copied or saved.
            #expect(model.draft == nil && model.error == nil && model.importState == .idle && model.mockImportProgress == nil)
            #expect(rig.assetFiles().isEmpty)
            #expect(rig.repository.provider.current().rules.isEmpty)
            #expect(rig.probe.returnedSizes.isEmpty)
            _ = try await rig.fetch("GET", "/trunc")
            #expect(rig.origin.requests == ["GET /trunc", "GET /trunc"], "no mock exists, so the origin is asked again")
        }
    }

    @Test func mockOfMapLocalFlowWorks() async throws {
        try await withRig { rig in
            // A first Map Local rule answers /local from its own asset.
            let source = rig.root.appendingPathComponent("local-source.txt")
            try Data("local source body".utf8).write(to: source)
            let original = try await rig.assets.importFile(source, displayName: "local-source.txt")
            let headers = [HeaderField(name: "Content-Type", value: "text/plain"), HeaderField(name: "X-Source", value: "map-local"),
                           HeaderField(name: "Set-Cookie", value: "a=1"), HeaderField(name: "Set-Cookie", value: "b=2")]
            let rule = Rule(id: UUID(), name: "local", enabled: true, order: 0,
                            matcher: RuleMatcher(method: "GET", path: .exact("/local?q=1")),
                            action: .mapLocal(MapLocalAction(assetID: original.id, status: 203, headers: headers)))
            _ = try await rig.repository.save(groups: [], rules: [rule], expectedRevision: 0)

            let first = try await rig.fetch("GET", "/local?q=1")
            #expect(first.status == 203 && first.body == Array("local source body".utf8))
            #expect(rig.origin.requests.isEmpty)
            let flow = try await rig.completedFlow("/local?q=1")
            #expect(flow.provenance.generatedResponse?.assetID == original.id)

            // Mock what the client received, then remove the source rule: only the mock answers.
            let model = try await rig.loadedModel()
            #expect(model.rules.map(\.id) == [rule.id])
            #expect(await model.beginMockDraft(from: flow, acquireBody: rig.acquire) == nil)
            let draft = try #require(model.draft)
            let copy = try #require(draft.mapLocal.asset)
            #expect(copy.id != original.id && copy.size == Int64("local source body".utf8.count))
            #expect(draft.mapLocal.status == "203")
            #expect(await model.delete(id: rule.id))
            #expect(model.draft?.mapLocal.asset?.id == copy.id, "the draft survives deleting the source rule")
            #expect(await model.save())
            #expect(model.rules.count == 1 && model.rules.first?.id != rule.id)

            let second = try await rig.fetch("GET", "/local?q=1")
            #expect(rig.origin.requests.isEmpty, "never reached the network")
            #expect(second.status == 203 && second.body == first.body)
            #expect(second.comparableFields == first.comparableFields, "\(second.fields) vs \(first.fields)")
            let served = try await rig.waitForFlow { $0.path == "/local?q=1" && $0.id != flow.id && $0.state == .completed }
            #expect(served.provenance.generatedResponse?.assetID == copy.id)
        }
    }

    @Test func mockRuleMatchesOnlyOriginalMethodAndFullURL() async throws {
        try await withRig { rig in
            let first = try await rig.fetch("GET", "/item?a=1&b=2")
            #expect(first.text == "origin-1")
            let flow = try await rig.completedFlow("/item?a=1&b=2")
            let model = try await rig.loadedModel()
            #expect(await model.beginMockDraft(from: flow, acquireBody: rig.acquire) == nil)
            let draft = try #require(model.draft)
            #expect(draft.match.method == "GET" && draft.match.pathMode == .exact && draft.match.path == "/item?a=1&b=2")
            #expect(await model.save())

            // The same method and URL: the mock answers with the first response, not a new origin one.
            var originRequests = rig.origin.requests
            #expect(originRequests == ["GET /item?a=1&b=2"])
            let again = try await rig.fetch("GET", "/item?a=1&b=2")
            #expect(again.text == "origin-1")
            #expect(rig.origin.requests == originRequests)

            // Anything else goes to the origin: other method, other query, other order, other case, other path.
            let others: [(method: String, target: String)] = [
                ("POST", "/item?a=1&b=2"), ("HEAD", "/item?a=1&b=2"), ("GET", "/item?a=1"), ("GET", "/item?b=2&a=1"),
                ("GET", "/item"), ("GET", "/Item?a=1&b=2"), ("GET", "/item?a=1&b=2&c=3"), ("GET", "/item/?a=1&b=2"),
            ]
            for other in others {
                let reply = try await rig.fetch(other.method, other.target)
                originRequests.append("\(other.method) \(other.target)")
                #expect(rig.origin.requests == originRequests, "\(other.method) \(other.target) must reach the origin")
                if other.method != "HEAD" { #expect(reply.text == "origin-\(originRequests.count)", "\(other.method) \(other.target)") }
            }
        }
    }
}

// MARK: - Rig

/// A real proxy (rules from a real repository, managed assets, a flow store) in front of a scripted
/// origin, plus the editor model's repository client with a probe on the body copy.
private final class MockRig: Sendable {
    let root: URL
    let store: FlowStore
    let assets: ManagedAssetStore
    let repository: RuleRepository
    let server: ProxyServer
    let origin: MockOrigin
    let proxyPort: Int
    let probe = CopyProbe()
    let limits: RulesLimits

    private init(root: URL, store: FlowStore, assets: ManagedAssetStore, repository: RuleRepository, server: ProxyServer,
                 origin: MockOrigin, proxyPort: Int, limits: RulesLimits) {
        self.root = root; self.store = store; self.assets = assets; self.repository = repository; self.server = server
        self.origin = origin; self.proxyPort = proxyPort; self.limits = limits
    }

    static func start(maxCapturedBodyBytes: Int) async throws -> MockRig {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pw-mock-roundtrip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("config"), withIntermediateDirectories: true)
        let limits = RulesLimits(minimumFreeDiskBytes: 0)
        let store = FlowStore(bodyDirectory: root.appendingPathComponent("Bodies"), maxCapturedBodyBytes: maxCapturedBodyBytes)
        let assets = ManagedAssetStore(directory: root.appendingPathComponent("assets"), limits: limits,
                                       budgets: OwnedFileBudgets(limits: limits))
        let repository = RuleRepository(directory: root.appendingPathComponent("config"), assets: assets, limits: limits)
        _ = try await repository.load()
        var configuration = ProxyConfiguration()
        configuration.port = 0
        configuration.portFallbackCount = 0
        let server = ProxyServer(
            configuration: configuration, certificateAuthority: try CertificateAuthority.generate(), store: store,
            passthrough: PassthroughRegistry(), processLookup: .none, rules: repository.provider, assets: assets)
        let origin = try await MockOrigin.start()
        do {
            try await server.start()
            guard let port = server.boundPort else { throw FixtureTimeout(what: "the proxy port") }
            return MockRig(root: root, store: store, assets: assets, repository: repository, server: server, origin: origin,
                           proxyPort: port, limits: limits)
        } catch {
            try? await server.stop()
            await origin.stop()
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    func stop() async {
        try? await server.stop()
        await origin.stop()
        try? FileManager.default.removeItem(at: root)
    }

    var acquire: BodyLeaseAcquirer { { [store] ref in try store.acquireBody(ref) } }

    func assetFile(_ id: UUID) -> URL { root.appendingPathComponent("assets/\(id.uuidString).asset") }

    func assetFiles() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("assets").path)) ?? [])
            .filter { $0.hasSuffix(".asset") }
    }

    /// A loaded editor model whose body copies go through the probe, which over-asks on purpose so
    /// that only the editor's own bound limits a chunk.
    @MainActor func loadedModel() async throws -> RulesEditorModel {
        var client = RulesRepositoryClient.live(repository: repository, assets: assets)
        let real = client.importStream, probe = self.probe
        client.importStream = { size, name, read in
            try await real(size, name) { offset, maxBytes in
                probe.asked(maxBytes)
                let data = try await read(offset, 4 * 1_048_576)
                probe.returned(data.count)
                return data
            }
        }
        let model = RulesEditorModel(client: client, limits: limits)
        await model.load()
        guard model.loadState == .loaded else { throw FixtureTimeout(what: "the rules to load") }
        return model
    }

    /// One request through the proxy on its own connection.
    func fetch(_ method: String, _ target: String) async throws -> Reply {
        let authority = "127.0.0.1:\(origin.port)"
        let client = try await LoopbackClient.connect(port: proxyPort)
        do {
            try await client.send("\(method) http://\(authority)\(target) HTTP/1.1\r\nHost: \(authority)\r\n"
                                  + (method == "POST" ? "Content-Length: 0\r\n" : "") + "Connection: close\r\n\r\n")
            let bytes = try await client.bytesUntilClose()
            await client.close()
            return try Reply.parse(bytes)
        } catch { await client.close(); throw error }
    }

    func waitForFlow(timeout: Duration = .seconds(10), where predicate: @Sendable (Flow) -> Bool) async throws -> Flow {
        let deadline = ContinuousClock.now + timeout
        while true {
            if let match = store.allFlows().first(where: predicate) { return match }
            guard ContinuousClock.now < deadline else { throw FixtureTimeout(what: "a matching flow in \(store.allFlows())") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func completedFlow(_ path: String) async throws -> Flow {
        try await waitForFlow { $0.path == path && $0.state == .completed }
    }
}

@MainActor
private func withRig(maxCapturedBodyBytes: Int = BodyCapture.defaultMaxCapturedBytes,
                     _ body: (MockRig) async throws -> Void) async throws {
    let rig = try await MockRig.start(maxCapturedBodyBytes: maxCapturedBodyBytes)
    do { try await body(rig) } catch { await rig.stop(); throw error }
    await rig.stop()
}

/// What the editor's body copy asked for and got, per read.
private final class CopyProbe: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: (asked: [Int](), returned: [Int]()))
    var askedSizes: [Int] { state.withLock { $0.asked } }
    var returnedSizes: [Int] { state.withLock { $0.returned } }
    func asked(_ size: Int) { state.withLock { $0.asked.append(size) } }
    func returned(_ size: Int) { state.withLock { $0.returned.append(size) } }
}

// MARK: - Client side

/// A response as the client received it.
private struct Reply {
    var status: Int
    var reason: String
    /// `name: value`, names lower-cased, in arrival order.
    var fields: [String]
    var body: [UInt8]

    var text: String { String(decoding: body, as: UTF8.self) }
    func values(_ name: String) -> [String] {
        let prefix = name.lowercased() + ": "
        return fields.compactMap { $0.hasPrefix(prefix) ? String($0.dropFirst(prefix.count)) : nil }
    }
    /// The fields a local answer must reproduce: connection-level framing is generated per response.
    var comparableFields: [String] {
        fields.filter { field in
            !["connection", "keep-alive", "content-length", "transfer-encoding", "proxy-connection"].contains { field.hasPrefix($0 + ":") }
        }
    }

    static func parse(_ bytes: [UInt8]) throws -> Reply {
        let separator = Array("\r\n\r\n".utf8)
        guard let end = bytes.indices.first(where: { bytes[$0...].starts(with: separator) }) else {
            throw FixtureTimeout(what: "a complete response head in \(bytes.count) bytes")
        }
        let head = String(decoding: bytes[..<end], as: UTF8.self).components(separatedBy: "\r\n")
        let status = head[0].split(separator: " ", maxSplits: 2)
        let fields = head.dropFirst().compactMap { line -> String? in
            guard let colon = line.firstIndex(of: ":") else { return nil }
            return line[..<colon].lowercased() + ": " + line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        var reply = Reply(status: Int(status[1]) ?? 0, reason: status.count > 2 ? String(status[2]) : "", fields: fields,
                          body: Array(bytes[(end + separator.count)...]))
        if reply.values("transfer-encoding").contains("chunked") { reply.body = try dechunk(reply.body) }
        return reply
    }

    private static func dechunk(_ bytes: [UInt8]) throws -> [UInt8] {
        let crlf = Array("\r\n".utf8)
        var index = 0, out: [UInt8] = []
        while true {
            guard let lineEnd = bytes[index...].indices.first(where: { bytes[$0...].starts(with: crlf) }),
                  let size = Int(String(decoding: bytes[index..<lineEnd], as: UTF8.self), radix: 16) else {
                throw FixtureTimeout(what: "a well-formed chunk")
            }
            index = lineEnd + 2
            if size == 0 { return out }
            out += bytes[index..<index + size]
            index += size + 2
        }
    }
}

// MARK: - Origin

private let gzipBytes: [UInt8] = [
    31, 139, 8, 0, 0, 0, 0, 0, 2, 255, 203, 72, 205, 201, 201, 87, 40, 207, 47, 202, 73, 209, 81, 200, 0, 115, 10, 138, 242,
    43, 42, 129, 66, 185, 137, 121, 122, 80, 161, 81, 249, 81, 249, 81, 249, 81, 249, 225, 39, 15, 0, 19, 48, 193, 185, 0, 5, 0, 0,
]
/// 3 MiB: well over the 1 MiB the capture keeps in memory.
private let bigBytes: [UInt8] = (0..<3 * 1_048_576).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ ($0 >> 8)) }
/// 200 KiB: over the 64 KiB capture limit of the truncation test.
private let truncBytes: [UInt8] = (0..<200 * 1_024).map { UInt8(truncatingIfNeeded: $0 &* 7) }

/// A loopback HTTP/1.1 origin: gzip, large and plain answers, `Connection: close`, with the request
/// lines and the accepted connections recorded.
private final class MockOrigin: Sendable {
    private struct State {
        var requests: [String] = []
        var connections = 0
    }
    let port: Int
    private let group: MultiThreadedEventLoopGroup
    private let channel: Channel
    private let state: OSAllocatedUnfairLock<State>

    private init(port: Int, group: MultiThreadedEventLoopGroup, channel: Channel, state: OSAllocatedUnfairLock<State>) {
        self.port = port; self.group = group; self.channel = channel; self.state = state
    }

    /// `METHOD target` of every request, in arrival order.
    var requests: [String] { state.withLock { $0.requests } }
    var connections: Int { state.withLock { $0.connections } }

    static func start() async throws -> MockOrigin {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let state = OSAllocatedUnfairLock(initialState: State())
        do {
            let channel = try await ServerBootstrap(group: group).childChannelInitializer { channel in
                state.withLock { $0.connections += 1 }
                return channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(Handler(state: state))
                }
            }.bind(host: "127.0.0.1", port: 0).get()
            guard let port = channel.localAddress?.port else { throw FixtureTimeout(what: "the origin port") }
            return MockOrigin(port: port, group: group, channel: channel, state: state)
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
    }

    func stop() async {
        try? await channel.close().get()
        try? await group.shutdownGracefully()
    }

    private static func answer(method: String, target: String, sequence: Int) -> [UInt8] {
        func message(_ fields: [(String, String)], _ body: [UInt8]) -> [UInt8] {
            var head = "HTTP/1.1 200 OK\r\n"
            for (name, value) in fields { head += "\(name): \(value)\r\n" }
            head += "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            return Array(head.utf8) + (method == "HEAD" ? [] : body)
        }
        let path = target.prefix { $0 != "?" }
        switch path {
        case "/gzip":
            return message([("Content-Type", "application/json"), ("Content-Encoding", "gzip"), ("ETag", "\"v1\""),
                            ("Cache-Control", "max-age=60"), ("X-Multi", "a"), ("X-Multi", "b"),
                            ("Set-Cookie", "a=1"), ("Set-Cookie", "b=2")], gzipBytes)
        case "/big": return message([("Content-Type", "application/octet-stream")], bigBytes)
        case "/trunc": return message([("Content-Type", "application/octet-stream")], truncBytes)
        default: return message([("Content-Type", "text/plain"), ("X-Origin", "yes")], Array("origin-\(sequence)".utf8))
        }
    }

    private final class Handler: ChannelInboundHandler {
        typealias InboundIn = ByteBuffer
        typealias OutboundOut = ByteBuffer
        let state: OSAllocatedUnfairLock<State>
        var buffer: [UInt8] = []
        var answered = false
        init(state: OSAllocatedUnfairLock<State>) { self.state = state }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            guard !answered else { return }
            buffer += Array(unwrapInboundIn(data).readableBytesView)
            let separator = Array("\r\n\r\n".utf8)
            guard let end = buffer.indices.first(where: { buffer[$0...].starts(with: separator) }) else { return }
            answered = true
            let line = String(decoding: buffer[..<end], as: UTF8.self).components(separatedBy: "\r\n")[0].split(separator: " ")
            let method = String(line[0]), target = String(line[1])
            let sequence = state.withLock { state -> Int in
                state.requests.append("\(method) \(target)")
                return state.requests.count
            }
            let bytes = MockOrigin.answer(method: method, target: target, sequence: sequence)
            let bound = NIOLoopBound(context, eventLoop: context.eventLoop)
            context.writeAndFlush(wrapOutboundOut(ByteBuffer(bytes: bytes))).whenComplete { _ in bound.value.close(promise: nil) }
        }

        func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
    }
}
