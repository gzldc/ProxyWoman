import Darwin
import FlowStore
import Foundation
import NIOCore
import NIOHPACK
import NIOHTTP1
import Testing
import os
@testable import ProxyCore
@testable import RulesEngine

/// Map Local directory routes through the real proxy, rules session, resolver and writer (spec F5-F11).
@Suite(.serialized, .timeLimit(.minutes(3)), .productionChinese) struct MapLocalDirectoryTests {
    @Test func servesFileFromDirectory() async throws {
        try await withMappedDirectory(["a.css": Data("body{color:red}".utf8)]) { dir in
            try await ProxyFixture.run(rules: dir.rules(), assets: dir.store) { fx in
                let reply = try await directoryRaw(fx, path: "/static/a.css")
                try #require(reply.head.hasPrefix("HTTP/1.1 200 OK"))
                #expect(reply.body == Data("body{color:red}".utf8))
                #expect(reply.field("content-type") == ["text/css; charset=utf-8"])
                #expect(reply.field("content-length") == ["15"])
                #expect(reply.field("x-proxywoman-map-local").isEmpty)
                #expect(fx.origin.receivedRequestCount == 0)
                #expect(fx.origin.acceptedConnections == 0)
                let flow = try await waitForFlow(fx.store) { $0.state == .completed }
                #expect(flow.messages[.upstreamRequest] == nil)
            }
        }
    }

    @Test func streamsLargeFileInChunks() async throws {
        let bytes = Data((0..<(5 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 >> 9) })
        try await withMappedDirectory(["big.bin": bytes]) { dir in
            let reads = OSAllocatedUnfairLock(initialState: 0)
            let hooks = LocalResponseSource.Hooks(afterRead: { _, count in
                #expect(count <= 65_536)
                reads.withLock { $0 += 1 }
            })
            try await ProxyFixture.run(rules: dir.rules(), assets: dir.store, localResponseHooks: hooks) { fx in
                let reply = try await directoryRaw(fx, path: "/static/big.bin")
                try #require(reply.head.hasPrefix("HTTP/1.1 200 OK"))
                #expect(reply.field("content-type") == ["application/octet-stream"])
                #expect(reply.field("content-length") == [String(bytes.count)])
                #expect(reply.body == bytes)
                #expect(reads.withLock { $0 } >= bytes.count / 65_536)
                #expect(fx.origin.receivedRequestCount == 0)
                _ = try await waitForFlow(fx.store) { $0.state == .completed }
            }
        }
    }

    @Test func indexServedForDirectoryRequest() async throws {
        let files = ["index.html": Data("<h1>root</h1>".utf8), "docs/index.html": Data("<h1>docs</h1>".utf8)]
        try await withMappedDirectory(files) { dir in
            try await ProxyFixture.run(rules: dir.rules(), assets: dir.store) { fx in
                for (path, expected) in [("/static/", "<h1>root</h1>"), ("/static/docs", "<h1>docs</h1>"),
                                         ("/static/docs/", "<h1>docs</h1>"), ("/static/docs/?v=1", "<h1>docs</h1>")] {
                    let reply = try await directoryRaw(fx, path: path)
                    #expect(reply.head.hasPrefix("HTTP/1.1 200 OK"), "\(path)")
                    #expect(reply.field("content-type") == ["text/html; charset=utf-8"])
                    #expect(String(decoding: reply.body, as: UTF8.self) == expected, "\(path)")
                }
                #expect(fx.origin.receivedRequestCount == 0)
            }
            try await ProxyFixture.run(rules: dir.rules(servesIndex: false), assets: dir.store) { fx in
                let reply = try await directoryRaw(fx, path: "/static/docs/")
                #expect(reply.head.hasPrefix("HTTP/1.1 404"))
                #expect(reply.field("x-proxywoman-map-local") == ["not-found"])
            }
        }
    }

    @Test func missingFileReturns404WithMarkerHeader() async throws {
        try await withMappedDirectory(["a.css": Data("x".utf8)]) { dir in
            try await ProxyFixture.run(rules: dir.rules(), assets: dir.store) { fx in
                let reply = try await directoryRaw(fx, path: "/static/missing.css")
                try #require(reply.head.hasPrefix("HTTP/1.1 404 Not Found"))
                #expect(reply.body.isEmpty)
                #expect(reply.field("x-proxywoman-map-local") == ["not-found"])
                #expect(reply.field("content-length") == ["0"])
                #expect(fx.origin.receivedRequestCount == 0)
                #expect(fx.origin.acceptedConnections == 0)
                let flow = try await waitForFlow(fx.store) { $0.state == .completed }
                #expect(flow.messages[.downstreamResponse]?.status == 404)
            }
        }
    }

    @Test func missingFileFallsBackToNetworkWhenConfigured() async throws {
        try await withMappedDirectory(["a.css": Data("x".utf8)]) { dir in
            try await ProxyFixture.run(rules: dir.rules(dir.rule(host: "127.0.0.1", prefix: "/", missing: .network)), assets: dir.store) { fx in
                let reply = try await directoryRaw(fx, host: "127.0.0.1:\(fx.origin.port)", path: "/hello")
                try #require(reply.head.hasPrefix("HTTP/1.1 200 OK"))
                #expect(String(decoding: reply.body, as: UTF8.self) == "hello")
                #expect(reply.field("x-proxywoman-map-local").isEmpty)
                #expect(fx.origin.receivedRequestCount == 1)
                #expect(fx.origin.receivedRequests.first?.head.uri == "/hello")
                let flow = try await waitForFlow(fx.store) { $0.state == .completed }
                #expect(flow.provenance.generatedResponse == nil)
                // A file that exists is still served locally under the same rule.
                let local = try await directoryRaw(fx, host: "127.0.0.1:\(fx.origin.port)", path: "/a.css")
                #expect(local.head.hasPrefix("HTTP/1.1 200 OK"))
                #expect(local.body == Data("x".utf8))
                #expect(fx.origin.receivedRequestCount == 1)
            }
        }
    }

    @Test func fallbackKeepsHeaderEditRules() async throws {
        try await withMappedDirectory([:]) { dir in
            let edit = TestRules.headers(.request, [.set(name: "X-Edited", value: "yes")], matcher: RuleMatcher(hostPattern: "127.0.0.1"))
            // R1 intentional change class 1: a rule must rank above the Return File rule to act on its exchange.
            let rules = dir.rules(dir.rule(host: "127.0.0.1", prefix: "/", missing: .network), higher: [edit])
            try await ProxyFixture.run(rules: rules, assets: dir.store) { fx in
                let reply = try await directoryRaw(fx, host: "127.0.0.1:\(fx.origin.port)", path: "/hello")
                try #require(reply.head.hasPrefix("HTTP/1.1 200 OK"))
                let head = try #require(fx.origin.receivedRequests.first?.head)
                #expect(head.headers["X-Edited"] == ["yes"])
                #expect(head.uri == "/hello")
            }
        }
    }

    @Test func fallbackIsNotUsedForUnsafePath() async throws {
        try await withMappedDirectory(["a.css": Data("x".utf8)]) { dir in
            let rules = dir.rules(dir.rule(host: "127.0.0.1", prefix: "/static/", missing: .network))
            try await ProxyFixture.run(rules: rules, assets: dir.store) { fx in
                for (method, path) in [("GET", "/static/%2e%2e/secret.txt"), ("GET", "/static/.hidden"),
                                       ("POST", "/static/%2e%2e/secret.txt"), ("GET", "/static/a%2fb")] {
                    let reply = try await directoryRaw(fx, method: method, host: "127.0.0.1:\(fx.origin.port)", path: path,
                                                       body: method == "POST" ? "probe" : nil)
                    #expect(reply.head.hasPrefix("HTTP/1.1 404"), "\(method) \(path)")
                    #expect(reply.field("x-proxywoman-map-local") == ["not-found"])
                    #expect(!String(decoding: reply.body, as: UTF8.self).contains("secret"))
                }
                #expect(fx.origin.receivedRequestCount == 0)
                #expect(fx.origin.acceptedConnections == 0)
            }
        }
    }

    @Test func symlinkEscapeReturns404() async throws {
        try await withMappedDirectory(["a.css": Data("x".utf8)]) { dir in
            try await ProxyFixture.run(rules: dir.rules(), assets: dir.store) { fx in
                for path in ["/static/link.txt", "/static/linkdir/a.css"] {
                    let reply = try await directoryRaw(fx, path: path)
                    #expect(reply.head.hasPrefix("HTTP/1.1 404"), "\(path)")
                    #expect(reply.body.isEmpty)
                }
                #expect(fx.origin.receivedRequestCount == 0)
            }
        }
    }

    @Test func postReturns405WithAllow() async throws {
        try await withMappedDirectory(["a.css": Data("x".utf8)]) { dir in
            try await ProxyFixture.run(rules: dir.rules(), assets: dir.store) { fx in
                let reply = try await directoryRaw(fx, method: "POST", path: "/static/a.css", body: "payload")
                try #require(reply.head.hasPrefix("HTTP/1.1 405 Method Not Allowed"))
                #expect(reply.field("allow") == ["GET, HEAD"])
                #expect(reply.field("x-proxywoman-map-local") == ["method-not-allowed"])
                #expect(reply.field("content-length") == ["0"])
                #expect(reply.body.isEmpty)
                #expect(fx.origin.receivedRequestCount == 0)
                #expect(fx.origin.acceptedConnections == 0)
            }
        }
    }

    @Test func postFallsBackToNetworkWhenConfigured() async throws {
        try await withMappedDirectory(["echo": Data("local echo".utf8)]) { dir in
            let rules = dir.rules(dir.rule(host: "127.0.0.1", prefix: "/", missing: .network))
            try await ProxyFixture.run(rules: rules, assets: dir.store) { fx in
                // Larger than one read: parts arrive while the resolution is pending and stay queued.
                let payload = String(repeating: "0123456789abcdef", count: 3_000)
                let reply = try await directoryRaw(fx, method: "POST", host: "127.0.0.1:\(fx.origin.port)", path: "/echo",
                                                   fields: "Content-Type: text/plain\r\n", body: payload)
                try #require(reply.head.hasPrefix("HTTP/1.1 200 OK"))
                #expect(String(decoding: reply.body, as: UTF8.self) == payload)
                #expect(fx.origin.receivedRequestCount == 1)
                #expect(fx.origin.receivedRequests.first?.body == Array(payload.utf8))
                let flow = try await waitForFlow(fx.store) { $0.state == .completed }
                #expect(flow.provenance.generatedResponse == nil)
            }
        }
    }

    @Test func headRequestHasNoBody() async throws {
        try await withMappedDirectory(["a.css": Data("body{}".utf8)]) { dir in
            let reads = OSAllocatedUnfairLock(initialState: 0)
            let leases = LeaseBox()
            let hooks = LocalResponseSource.Hooks(beforeRead: { _, _ in reads.withLock { $0 += 1 } },
                                                  afterDirectoryResolve: { leases.capture($0) })
            try await ProxyFixture.run(rules: dir.rules(), assets: dir.store, localResponseHooks: hooks) { fx in
                let reply = try await directoryRaw(fx, method: "HEAD", path: "/static/a.css")
                try #require(reply.head.hasPrefix("HTTP/1.1 200 OK"))
                #expect(reply.field("content-length") == ["6"])
                #expect(reply.field("content-type") == ["text/css; charset=utf-8"])
                #expect(reply.body.isEmpty)
                #expect(reads.withLock { $0 } == 0)
                _ = try await waitForFlow(fx.store) { $0.state == .completed }
                try await leases.waitAllReleased()
                #expect(fx.origin.receivedRequestCount == 0)
            }
        }
    }

    @Test func userContentTypeHeaderWins() async throws {
        try await withMappedDirectory(["a.css": Data("x".utf8)]) { dir in
            let rule = dir.rule(headers: [HeaderField(name: "content-type", value: "application/x-custom"),
                                          HeaderField(name: "Cache-Control", value: "no-store")])
            try await ProxyFixture.run(rules: dir.rules(rule), assets: dir.store) { fx in
                let reply = try await directoryRaw(fx, path: "/static/a.css")
                try #require(reply.head.hasPrefix("HTTP/1.1 200 OK"))
                #expect(reply.field("content-type") == ["application/x-custom"])
                #expect(reply.field("cache-control") == ["no-store"])
            }
            try await ProxyFixture.run(rules: dir.rules(dir.rule(headers: [HeaderField(name: "Cache-Control", value: "no-store")])),
                                       assets: dir.store) { fx in
                let reply = try await directoryRaw(fx, path: "/static/a.css")
                #expect(reply.field("content-type") == ["text/css; charset=utf-8"])
                #expect(reply.field("cache-control") == ["no-store"])
            }
        }
    }

    @Test func responseRulesApplyToDirectoryResponses() async throws {
        try await withMappedDirectory(["a.css": Data("x".utf8)]) { dir in
            let edit = TestRules.headers(.response, [.set(name: "X-Dir", value: "edited")], matcher: RuleMatcher(hostPattern: "app.test"))
            // R1 intentional change class 1: a rule must rank above the Return File rule to act on its exchange.
            try await ProxyFixture.run(rules: dir.rules(higher: [edit]), assets: dir.store) { fx in
                for (method, path, status) in [("GET", "/static/a.css", "200"), ("GET", "/static/none.css", "404"),
                                               ("POST", "/static/a.css", "405")] {
                    let reply = try await directoryRaw(fx, method: method, path: path, body: method == "POST" ? "p" : nil)
                    #expect(reply.head.hasPrefix("HTTP/1.1 \(status)"), "\(path)")
                    #expect(reply.field("x-dir") == ["edited"], "\(path)")
                }
                try await waitForCompletedFlows(fx.store, atLeast: 3)
                for flow in fx.store.allFlows() {
                    #expect(flow.provenance.ruleMatches?.total == 2)
                    #expect(flow.messages[.generatedResponse]?.headers.contains { $0.name.lowercased() == "x-dir" } == false)
                }
            }
        }
    }

    @Test func unavailableDirectoryReturns502LocalFailure() async throws {
        try await withMappedDirectory(["a.css": Data("x".utf8)]) { dir in
            for missing in [MissingFilePolicy.notFound, .network] {
                let rule = dir.rule(host: "127.0.0.1", missing: missing, bookmark: Data("not a bookmark".utf8))
                try await ProxyFixture.run(rules: dir.rules(rule), assets: dir.store) { fx in
                    let reply = try await directoryRaw(fx, host: "127.0.0.1:\(fx.origin.port)", path: "/static/a.css")
                    try #require(reply.head.hasPrefix("HTTP/1.1 502 Bad Gateway"))
                    #expect(reply.head.components(separatedBy: "HTTP/1.1 ").count == 2)
                    #expect(String(decoding: reply.body, as: UTF8.self).contains(HTTPLocalFailureText.localAssetUnavailable()))
                    #expect(fx.origin.receivedRequestCount == 0)
                    _ = try await waitForFlow(fx.store) { if case .failed = $0.state { true } else { false } }
                }
            }
        }
    }

    @Test func withoutResolverFailsAsUnsupportedAction() async throws {
        try await withMappedDirectory(["a.css": Data("x".utf8)]) { dir in
            try await ProxyFixture.run(rules: dir.rules()) { fx in
                let reply = try await directoryRaw(fx, path: "/static/a.css")
                try #require(reply.head.hasPrefix("HTTP/1.1 502 Bad Gateway"))
                #expect(String(decoding: reply.body, as: UTF8.self).contains(HTTPLocalFailureText.ruleActionUnsupported(action: "mapLocalDirectory")))
                #expect(fx.origin.acceptedConnections == 0)
            }
        }
    }

    @Test func clientDisconnectReleasesLease() async throws {
        try await withHTTP2ControlLoop { loop in
            let blocked = loop.makePromise(of: Void.self), release = loop.makePromise(of: Void.self)
            defer { blocked.fail(HTTPTransportError.cancelled); release.succeed(()) }
            try await withMappedDirectory(["big.bin": Data(repeating: 0x42, count: 1 << 20)]) { dir in
                let leases = LeaseBox()
                let hooks = LocalResponseSource.Hooks(
                    beforeRead: { _, offset in
                        if offset == 65_536 { blocked.succeed(()); try await release.futureResult.boundedGet() }
                    },
                    afterDirectoryResolve: { leases.capture($0) })
                try await ProxyFixture.run(rules: dir.rules(), assets: dir.store, localResponseHooks: hooks) { fx in
                    let client = try await RawClient.connect(port: fx.proxyPort)
                    try await client.send("GET http://app.test/static/big.bin HTTP/1.1\r\nHost: app.test\r\n\r\n")
                    try await blocked.futureResult.boundedGet()
                    _ = try await client.receive(until: "\r\n\r\n")
                    try await client.close()
                    _ = try await waitForFlow(fx.store) { if case .failed = $0.state { true } else { false } }
                    release.succeed(())
                    #expect(leases.count == 1)
                    try await leases.waitAllReleased()
                    try await waitUntil("I/O reservations released") { dir.budgets.snapshot().reservedBytes == 0 }
                    #expect(fx.origin.receivedRequestCount == 0)
                }
            }
        }
    }

    @Test func cancelDuringPreResolveReleasesLease() async throws {
        try await withHTTP2ControlLoop { loop in
            let resolved = loop.makePromise(of: Void.self), release = loop.makePromise(of: Void.self)
            defer { resolved.fail(HTTPTransportError.cancelled); release.succeed(()) }
            try await withMappedDirectory(["a.css": Data("x".utf8)]) { dir in
                let leases = LeaseBox()
                let reads = OSAllocatedUnfairLock(initialState: 0)
                let hooks = LocalResponseSource.Hooks(
                    beforeRead: { _, _ in reads.withLock { $0 += 1 } },
                    afterDirectoryResolve: { resolution in
                        leases.capture(resolution)
                        resolved.succeed(())
                        _ = try? await release.futureResult.boundedGet()
                    })
                try await ProxyFixture.run(rules: dir.rules(), assets: dir.store, localResponseHooks: hooks) { fx in
                    let client = try await RawClient.connect(port: fx.proxyPort)
                    try await client.send("GET http://app.test/static/a.css HTTP/1.1\r\nHost: app.test\r\n\r\n")
                    try await resolved.futureResult.boundedGet()
                    try await client.close()
                    _ = try await waitForFlow(fx.store) { if case .failed = $0.state { true } else { false } }
                    release.succeed(())
                    #expect(leases.count == 1)
                    try await leases.waitAllReleased()
                    #expect(reads.withLock { $0 } == 0)
                    #expect(fx.origin.receivedRequestCount == 0)
                    let flow = try #require(fx.store.allFlows().first)
                    #expect(flow.messages[.generatedResponse] == nil)
                    #expect(flow.messages[.downstreamResponse] == nil)
                }
            }
        }
    }

    @Test func directoryRuleBeforeBreakpointKeepsRoute() async throws {
        try await withHTTP2ControlLoop { loop in
            try await withMappedDirectory(["a.css": Data("paused file".utf8)]) { dir in
                let b = BreakpointCoordinator()
                // R1 intentional change class 1: a rule must rank above the Return File rule to act on its exchange.
                let rules = dir.rules(higher: [TestRules.breakpoint(.request, matcher: RuleMatcher(hostPattern: "app.test"))])
                try await ProxyFixture.run(rules: rules, assets: dir.store, breakpoints: b) { fx in
                    let pending = Task { try await directoryRaw(fx, path: "/static/a.css") }
                    do {
                        let t = try await RulesComposeBarriers.ticket(b, on: loop)
                        #expect(t.routeKind == .local)
                        guard case .request(var target, let fields) = t.effectiveHead else { throw HTTPTransportError.closed }
                        target.pathAndQuery = "/static/other.css"
                        #expect(await b.perform(.continue(token: t.token, edit: .init(head: .request(target, headers: fields)))) == .invalid)
                        #expect(await b.perform(.continue(token: t.token, edit: .init(head: t.effectiveHead))) == .accepted)
                        let reply = try await pending.value
                        #expect(reply.head.hasPrefix("HTTP/1.1 200 OK"))
                        #expect(reply.body == Data("paused file".utf8))
                        #expect(fx.origin.receivedRequestCount == 0)
                        #expect(fx.origin.acceptedConnections == 0)
                        let flow = try await waitForFlow(fx.store) { $0.state == .completed }
                        #expect(flow.provenance.generatedResponse?.assetID == dir.ruleID)
                    } catch { b.shutdown(); _ = try? await pending.value; throw error }
                }
            }
        }
    }

    @Test func flowRecordsGeneratedResponseWithRuleID() async throws {
        try await withMappedDirectory(["a.css": Data("abc".utf8)]) { dir in
            let earlier = TestRules.headers(.request, [.set(name: "X-Before", value: "1")], matcher: RuleMatcher(hostPattern: "app.test"))
            let rules = TestRules.provider([earlier, dir.rule()])
            try await ProxyFixture.run(rules: rules, assets: dir.store) { fx in
                _ = try await directoryRaw(fx, path: "/static/a.css")
                let flow = try await waitForFlow(fx.store) { $0.state == .completed }
                #expect(flow.provenance.generatedResponse?.assetID == dir.ruleID)
                #expect(flow.provenance.generatedResponse?.size == 3)
                #expect(try flow.messages[.generatedResponse]?.body?.load() == Data("abc".utf8))
                #expect(flow.messages[.upstreamRequest] == nil)
                #expect(flow.provenance.ruleMatches?.ruleIDs.contains(dir.ruleID) == true)
            }
            try await ProxyFixture.run(rules: dir.rules(), assets: dir.store) { fx in
                _ = try await directoryRaw(fx, path: "/static/missing.css")
                let flow = try await waitForFlow(fx.store) { $0.state == .completed }
                #expect(flow.provenance.generatedResponse?.assetID == dir.ruleID)
                #expect(flow.provenance.generatedResponse?.size == 0)
                #expect(flow.messages[.generatedResponse]?.status == 404)
            }
        }
    }

    @Test func http2ServesNotFoundAndFallsBackOnOneConnection() async throws {
        try await withMappedDirectory(["a.css": Data("h2 file".utf8)]) { dir in
            let rules = TestRules.provider([
                dir.rule(host: "localhost", prefix: "/static/"),
                Rule(id: UUID(), name: "fallback", enabled: true, order: 0,
                     matcher: RuleMatcher(hostPattern: "localhost", path: .prefix("/net/")),
                     action: .mapLocalDirectory(MapLocalDirectoryAction(bookmark: dir.bookmark, displayName: "www", missing: .network))),
            ])
            try await HTTP2TestOrigin.withOrigin(protocols: ["h2"]) { origin in
                try await HTTP2ProxyFixture.withProxy(origin: origin, downstreamH2: true, rules: rules, assets: dir.store) { fx, client in
                    func headers(_ method: String, _ path: String) -> HPACKHeaders {
                        HPACKHeaders([(":method", method), (":scheme", "https"), (":authority", "localhost:\(origin.port)"), (":path", path)])
                    }
                    let served = try await client.rawRequest(headers: headers("GET", "/static/a.css"))
                    #expect(served.status == 200)
                    #expect(served.body == "h2 file")
                    #expect(served.headers["content-type"] == ["text/css; charset=utf-8"])
                    let missing = try await client.rawRequest(headers: headers("GET", "/static/none.css"))
                    #expect(missing.status == 404)
                    #expect(missing.body.isEmpty)
                    #expect(missing.headers["x-proxywoman-map-local"] == ["not-found"])
                    #expect(origin.counts.requests == 0)
                    let posted = try await client.rawRequest(headers: headers("POST", "/net/upload"), body: "uploaded body")
                    #expect(posted.status == 200)
                    #expect(posted.body == "fixture-body")
                    #expect(origin.counts.requests == 1)
                    #expect(origin.counts.bodies["/net/upload"] == "uploaded body")
                    try await waitForCompletedFlows(fx.store, atLeast: 3)
                }
            }
        }
    }

    @Test func withoutDirectoryRulesBytesAreIdentical() async throws {
        try await withMappedDirectory(["hello": Data("never".utf8)]) { dir in
            func exchange(assets: ManagedAssetStore?) async throws -> (client: [String], origin: String) {
                let edit = TestRules.headers(.request, [.set(name: "X-Same", value: "1")])
                var replies: [String] = []
                var origin = ""
                try await ProxyFixture.run(rules: TestRules.provider([edit]), assets: assets) { fx in
                    let host = "127.0.0.1:\(fx.origin.port)"
                    for (method, path, body) in [("GET", "/hello", nil), ("POST", "/echo", "abc"), ("GET", "/static/hello", nil)] {
                        let reply = try await directoryRaw(fx, method: method, host: host, path: path, body: body)
                        replies.append(reply.raw.replacingOccurrences(of: String(fx.origin.port), with: "PORT"))
                    }
                    origin = String(decoding: fx.origin.receivedBytes, as: UTF8.self)
                        .replacingOccurrences(of: String(fx.origin.port), with: "PORT")
                    #expect(fx.origin.receivedRequestCount == 3)
                }
                return (replies, origin)
            }
            let without = try await exchange(assets: nil)
            let with = try await exchange(assets: dir.store)
            #expect(with.client == without.client)
            #expect(with.origin == without.origin)
            #expect(with.origin.contains("X-Same: 1"))
        }
    }
}

// MARK: - Fixture

struct MappedDirectoryFixture: Sendable {
    /// The mapped directory itself.
    let root: URL
    let store: ManagedAssetStore
    let budgets: OwnedFileBudgets
    let bookmark: Data
    let ruleID = UUID()

    func rule(host: String = "app.test", prefix: String = "/static/", missing: MissingFilePolicy = .notFound,
              servesIndex: Bool = true, headers: [HeaderField] = [], bookmark: Data? = nil) -> Rule {
        Rule(id: ruleID, name: "directory", enabled: true, order: 0,
             matcher: RuleMatcher(hostPattern: host, path: .prefix(prefix)),
             action: .mapLocalDirectory(MapLocalDirectoryAction(bookmark: bookmark ?? self.bookmark, displayName: "www",
                                                                servesIndex: servesIndex, missing: missing, headers: headers)))
    }

    /// The directory rule below `higher`: a Return File action is final, so only rules ranked above it
    /// still act on its exchange (R1 intentional change class 1).
    func rules(_ directory: Rule? = nil, servesIndex: Bool = true, higher: [Rule] = []) -> RuleSnapshotProvider {
        TestRules.provider(higher + [directory ?? rule(servesIndex: servesIndex)])
    }
}

/// `files` are created below the mapped directory; `secret.txt` lies next to it (outside), and
/// `link.txt` / `linkdir` are symlinks pointing out of it.
func withMappedDirectory(_ files: [String: Data], chunkBytes: Int = 65_536,
                         _ body: (MappedDirectoryFixture) async throws -> Void) async throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("map-dir-\(UUID())")
    let root = base.appendingPathComponent("www")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    for (path, bytes) in files {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url)
    }
    let secret = base.appendingPathComponent("secret.txt")
    try Data("secret".utf8).write(to: secret)
    let outsideDirectory = base.appendingPathComponent("outside")
    try FileManager.default.createDirectory(at: outsideDirectory, withIntermediateDirectories: true)
    try Data("outside".utf8).write(to: outsideDirectory.appendingPathComponent("a.css"))
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link.txt"), withDestinationURL: secret)
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linkdir"), withDestinationURL: outsideDirectory)
    let limits = RulesLimits(ioChunkBytes: chunkBytes, minimumFreeDiskBytes: 0)
    let budgets = OwnedFileBudgets(limits: limits)
    let store = ManagedAssetStore(directory: base.appendingPathComponent("assets"), limits: limits, budgets: budgets)
    let fixture = MappedDirectoryFixture(root: root, store: store, budgets: budgets, bookmark: try DirectoryBookmark.make(for: root))
    try await body(fixture)
    try await waitUntil("I/O reservations released") { budgets.snapshot().reservedBytes == 0 }
}

/// Every lease a resolution handed out, so a test can prove the exchange released it.
private final class LeaseBox: Sendable {
    private let leases = OSAllocatedUnfairLock<[OwnedFileLease]>(initialState: [])
    var count: Int { leases.withLock { $0.count } }

    func capture(_ resolution: DirectoryResolution) {
        if case .file(let lease, _) = resolution { leases.withLock { $0.append(lease) } }
    }

    /// A released lease refuses every read with `cancelled`; a live one would read a byte.
    func waitAllReleased(timeout: Duration = .seconds(5)) async throws {
        let deadline = ContinuousClock.now + timeout
        for lease in leases.withLock({ $0 }) {
            while true {
                do {
                    _ = try await lease.read(offset: 0, maxBytes: 1)
                } catch let error as OwnedFileError where error.code == .cancelled {
                    break
                }
                guard ContinuousClock.now < deadline else { throw WaitTimeout(description: "a directory lease was never released") }
                try await Task.sleep(for: .milliseconds(20))
            }
        }
    }
}

struct DirectoryReply {
    let raw: String
    let head: String
    let body: Data

    /// Values of every field named `name` (case-insensitive), in order.
    func field(_ name: String) -> [String] {
        head.components(separatedBy: "\r\n").dropFirst().compactMap { line in
            guard let colon = line.firstIndex(of: ":"), line[..<colon].lowercased() == name else { return nil }
            return line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
    }
}

/// One proxy-form request on its own `Connection: close` connection; returns everything received.
func directoryRaw(_ fixture: ProxyFixture, method: String = "GET", host: String = "app.test", path: String,
                  fields: String = "", body: String? = nil) async throws -> DirectoryReply {
    let client = try await RawClient.connect(port: fixture.proxyPort)
    do {
        let length = body.map { "Content-Length: \($0.utf8.count)\r\n" } ?? ""
        try await client.send("\(method) http://\(host)\(path) HTTP/1.1\r\nHost: \(host)\r\n\(fields)\(length)Connection: close\r\n\r\n\(body ?? "")")
        try await client.waitUntilClosed()
        let bytes = Data(client.remainingBytes())
        try await client.close()
        let separator = try #require(bytes.range(of: Data("\r\n\r\n".utf8)))
        return DirectoryReply(raw: String(decoding: bytes, as: UTF8.self),
                              head: String(decoding: bytes[..<separator.lowerBound], as: UTF8.self),
                              body: Data(bytes[separator.upperBound...]))
    } catch { try? await client.close(); throw error }
}
