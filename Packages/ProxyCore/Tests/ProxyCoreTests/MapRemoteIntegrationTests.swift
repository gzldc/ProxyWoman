import CertKit
import FlowStore
import Foundation
import NIOCore
import NIOHTTP1
import NIOSSL
import Testing
@testable import ProxyCore
@testable import RulesEngine

/// Map Remote changes the whole outbound identity together: connection destination, upstream-proxy
/// bypass and CONNECT target, TLS server name and verification, Host/:authority and the pool key.
@Suite(.productionChinese, .serialized, .timeLimit(.minutes(2))) struct MapRemoteIntegrationTests {
    // MARK: pure target and header policy

    @Test func targetKeepsOrReplacesPathAndNormalizesTheHost() throws {
        let original = HTTPMessageTarget(scheme: "http", host: "a.test", port: 8080, method: "GET", pathAndQuery: "/p?x=1&x=2")
        let keep = try EffectiveRequestRoute.target(original: original, decision: decision(.remote(MapRemoteAction(
            targetScheme: "HTTPS", targetHost: "[::1]", targetPort: 443, path: .preserve))))
        #expect(keep == HTTPMessageTarget(scheme: "https", host: "::1", port: 443, method: "GET", pathAndQuery: "/p?x=1&x=2"))
        #expect(EffectiveRequestRoute.requestTarget(keep).hostHeader == "[::1]")
        let replace = try EffectiveRequestRoute.target(original: original, decision: decision(.remote(MapRemoteAction(
            targetScheme: "http", targetHost: "B.Example", targetPort: 81, path: .replace("/new?y=%2F")))))
        #expect(replace == HTTPMessageTarget(scheme: "http", host: "b.example", port: 81, method: "GET", pathAndQuery: "/new?y=%2F"))
        #expect(EffectiveRequestRoute.requestTarget(replace).hostHeader == "b.example:81")
        #expect(try EffectiveRequestRoute.target(original: original, decision: decision(.original)) == original)
        #expect(throws: HTTPMutationError.self) {
            try EffectiveRequestRoute.target(original: original, decision: decision(.remote(MapRemoteAction(
                targetScheme: "ftp", targetHost: "b.example", targetPort: 21, path: .preserve))))
        }
    }

    @Test(arguments: [false, true])
    func crossOriginRemovesCredentialsUnlessPreservedAndNeverForwardsProxyAuthorization(preserve: Bool) {
        let fields = [
            HeaderField(name: "Host", value: "a.test"), HeaderField(name: "Authorization", value: "Basic a"),
            HeaderField(name: "Cookie", value: "s=1"), HeaderField(name: "Origin", value: "http://a.test"),
            HeaderField(name: "Referer", value: "http://a.test/"), HeaderField(name: "Proxy-Authorization", value: "Basic p"),
            HeaderField(name: "X-Keep", value: "1"),
        ]
        let from = HTTPMessageTarget(scheme: "http", host: "a.test", port: 80, method: "GET", pathAndQuery: "/")
        let other = HTTPMessageTarget(scheme: "http", host: "b.test", port: 80, method: "GET", pathAndQuery: "/")
        let names = EffectiveRequestRoute.sanitizedHeaders(fields, from: from, to: other, preserveCredentials: preserve).map(\.name)
        #expect(names == (preserve ? ["Authorization", "Cookie", "Origin", "Referer", "X-Keep"] : ["X-Keep"]))
        // Same origin, other path: credentials stay, the authority is still generated from the target.
        var samePath = from
        samePath.pathAndQuery = "/other"
        #expect(EffectiveRequestRoute.sanitizedHeaders(fields, from: from, to: samePath, preserveCredentials: false).map(\.name)
            == ["Authorization", "Cookie", "Origin", "Referer", "X-Keep"])
        // Unmapped: untouched.
        #expect(EffectiveRequestRoute.sanitizedHeaders(fields, from: from, to: from, preserveCredentials: false) == fields)
    }

    // MARK: plain HTTP forward proxy

    @Test(arguments: [false, true])
    func onlyTheTargetSeesTheRequestWithItsOwnAuthority(preserveCredentials: Bool) async throws {
        let a = try await HTTP2TestOrigin.start(protocols: [], plaintext: true)
        let b = try await HTTP2TestOrigin.start(protocols: [], plaintext: true)
        do {
            let rules = TestRules.provider([TestRules.mapRemote(host: "127.0.0.1", port: b.port, preserveCredentials: preserveCredentials,
                                                                matcher: RuleMatcher(port: a.port))])
            try await ProxyFixture.run(rules: rules) { fx in
                let client = try await RawClient.connect(port: fx.proxyPort)
                try await client.send("GET http://127.0.0.1:\(a.port)/p?x=1 HTTP/1.1\r\nHost: 127.0.0.1:\(a.port)\r\n"
                    + "Authorization: Basic a\r\nCookie: s=1\r\nOrigin: http://127.0.0.1:\(a.port)\r\nReferer: http://127.0.0.1:\(a.port)/\r\n"
                    + "Proxy-Authorization: Basic p\r\nX-Keep: 1\r\nConnection: close\r\n\r\n")
                #expect(try await client.receive(until: "fixture-body").hasPrefix("HTTP/1.1 200 OK\r\n"))
                try await client.close()
                #expect(a.counts.requests == 0)
                #expect(b.counts.paths == ["/p?x=1"])
                let seen = try #require(b.counts.requestHeaders.first)
                #expect(seen["host"] == ["127.0.0.1:\(b.port)"])
                #expect(seen["x-keep"] == ["1"])
                #expect(seen["proxy-authorization"].isEmpty)
                for name in ["authorization", "cookie", "origin", "referer"] {
                    #expect(seen[name].isEmpty != preserveCredentials, "\(name)")
                }
                let flow = try await waitForFlow(fx.store) { $0.state == .completed }
                #expect(flow.port == a.port)
                #expect(flow.messages[.downstreamRequest]?.target?.port == a.port)
                let sent = try #require(flow.messages[.upstreamRequest]?.target)
                #expect(sent.port == b.port)
                #expect(sent.host == "127.0.0.1")
                #expect(flow.provenance.ruleMatches?.outcomes.map(\.code) == [.applied])
            }
            try await a.stop(); try await b.stop()
        } catch { try? await a.stop(); try? await b.stop(); throw error }
    }

    @Test func replacedPathAndQueryIsSentVerbatim() async throws {
        let b = try await HTTP2TestOrigin.start(protocols: [], plaintext: true)
        do {
            let rules = TestRules.provider([TestRules.mapRemote(host: "127.0.0.1", port: b.port, path: .replace("/new?y=%2F&y="))])
            try await ProxyFixture.run(rules: rules) { fx in
                let client = try await RawClient.connect(port: fx.proxyPort)
                try await client.send("GET http://127.0.0.1:1/old?x=1 HTTP/1.1\r\nHost: 127.0.0.1:1\r\nConnection: close\r\n\r\n")
                _ = try await client.receive(until: "fixture-body")
                try await client.close()
                #expect(b.counts.paths == ["/new?y=%2F&y="])
            }
            try await b.stop()
        } catch { try? await b.stop(); throw error }
    }

    /// http → https: the target's certificate is verified with the connection's trust roots; an
    /// untrusted target fails and nothing is added to passthrough.
    @Test(arguments: [true, false])
    func schemeChangeVerifiesTheTargetCertificate(trusted: Bool) async throws {
        let b = try await HTTP2TestOrigin.start(protocols: ["h2", "http/1.1"], certificateHost: "127.0.0.1")
        do {
            let rules = TestRules.provider([TestRules.mapRemote(scheme: "https", host: "127.0.0.1", port: b.port)])
            let roots: NIOSSLTrustRoots = trusted
                ? .certificates([try NIOSSLCertificate(bytes: b.ca.rootCertificateDER, format: .der)]) : .default
            try await ProxyFixture.run(configure: { $0.upstreamTrustRoots = roots }, rules: rules) { fx in
                let client = try await RawClient.connect(port: fx.proxyPort)
                try await client.send("GET http://localhost:1/tls HTTP/1.1\r\nHost: localhost:1\r\nConnection: close\r\n\r\n")
                try await client.waitUntilClosed()
                let text = String(decoding: client.remainingBytes(), as: UTF8.self)
                try await client.close()
                if trusted {
                    #expect(text.hasPrefix("HTTP/1.1 200 OK\r\n"), "\(text)")
                    #expect(text.contains("fixture-body"))
                    #expect(b.counts.authorities == ["127.0.0.1:\(b.port)"])
                } else {
                    #expect(text.hasPrefix("HTTP/1.1 502 Bad Gateway\r\n"), "\(text)")
                    #expect(text.contains("上游证书校验失败"), "\(text)")
                    #expect(b.counts.requests == 0)
                }
                #expect(!fx.passthrough.contains("127.0.0.1"))
                #expect(!fx.passthrough.contains("localhost"))
            }
            try await b.stop()
        } catch { try? await b.stop(); throw error }
    }

    // MARK: MITM, every leg pair

    @Test func mappedAndUnmappedRoutesUseSeparatePools() async throws {
        try await HTTP2TestOrigin.withOrigin(protocols: ["http/1.1"]) { origin in
            let mapped = TestRules.mapRemote(scheme: "https", host: "localhost", port: origin.port,
                                             path: .replace("/mapped"), matcher: RuleMatcher(path: .exact("/map")))
            try await HTTP2ProxyFixture.withProxy(origin: origin, downstreamH2: false,
                                                 rules: TestRules.provider([mapped])) { fixture, client in
                for path in ["/map", "/plain"] {
                    let reply = try await client.request(headers: HTTPHeaders([("host", "localhost:\(origin.port)")]), path: path)
                    #expect(reply.status == 200)
                }
                #expect(origin.counts.paths == ["/mapped", "/plain"])
                #expect(origin.counts.connections == 2)
                try await waitForCompletedFlows(fixture.store, atLeast: 2)
            }
        }
    }

    @Test(arguments: LegPair.all)
    func interceptedRequestUsesTheTargetsAuthorityTrustAndPool(pair: LegPair) async throws {
        try await HTTP2TestOrigin.withOrigin(protocols: pair.origin) { a in
            let b = try await HTTP2TestOrigin.start(protocols: pair.origin, certificateHost: "127.0.0.1")
            do {
                let rules = TestRules.provider([TestRules.mapRemote(scheme: "https", host: "127.0.0.1", port: b.port)])
                try await HTTP2ProxyFixture.withProxy(origin: a, downstreamH2: pair.downstreamH2, rules: rules,
                                                     trustedOrigins: [a.ca, b.ca]) { fixture, client in
                    for path in ["/one", "/two"] {
                        let reply = try await client.request(headers: HTTPHeaders([("host", "localhost:\(a.port)")]), path: path)
                        #expect(reply.status == 200)
                        #expect(reply.body == "fixture-body")
                    }
                    #expect(a.counts.connections == 0)
                    #expect(b.counts.paths == ["/one", "/two"])
                    if pair.upstreamH2 { #expect(b.counts.authorities == ["127.0.0.1:\(b.port)", "127.0.0.1:\(b.port)"]) }
                    else { #expect(b.counts.requestHeaders.map { $0["host"] } == [["127.0.0.1:\(b.port)"], ["127.0.0.1:\(b.port)"]]) }
                    // Both requests share one pooled upstream connection keyed by the target.
                    #expect(b.counts.connections == 1)
                    #expect(fixture.upstreams.withLock { $0.map { $0.remoteAddress?.port } } == [b.port])
                    try await waitForCompletedFlows(fixture.store, atLeast: 2)
                    for flow in fixture.store.allFlows() {
                        #expect(flow.host == "localhost")
                        #expect(flow.messages[.upstreamRequest]?.target?.port == b.port)
                        #expect(flow.messages[.upstreamRequest]?.target?.scheme == "https")
                    }
                }
                try await b.stop()
            } catch { try? await b.stop(); throw error }
        }
    }

    @Test func interceptedRequestToAnUntrustedTargetFailsWithoutPassthrough() async throws {
        try await HTTP2TestOrigin.withOrigin(protocols: ["h2", "http/1.1"]) { a in
            let b = try await HTTP2TestOrigin.start(protocols: ["h2", "http/1.1"], certificateHost: "127.0.0.1")
            do {
                let rules = TestRules.provider([TestRules.mapRemote(scheme: "https", host: "127.0.0.1", port: b.port)])
                try await HTTP2ProxyFixture.withProxy(origin: a, downstreamH2: true, rules: rules) { fixture, client in
                    let reply = try await client.request(headers: HTTPHeaders([("host", "localhost:\(a.port)")]), path: "/bad")
                    #expect(reply.status == 502)
                    #expect(reply.body.contains("上游证书校验失败"), "\(reply.body)")
                    #expect(a.counts.connections == 0)
                    #expect(b.counts.requests == 0)
                    let owner = try #require(fixture.connections.withLock { $0.first })
                    let passthrough = try await fixture.channel.eventLoop.submit { owner.value.environment.passthrough }.get()
                    #expect(!passthrough.contains("localhost"))
                    #expect(!passthrough.contains("127.0.0.1"))
                }
                try await b.stop()
            } catch { try? await b.stop(); throw error }
        }
    }

    // MARK: upstream proxy

    /// The bypass decision and the CONNECT target follow the mapped host, not the original one.
    @Test(arguments: [[String](), ["localhost"], ["127.0.0.1"]])
    func upstreamProxyBypassAndConnectTargetFollowTheMappedHost(bypass: [String]) async throws {
        try await ProxyFixture.run(configure: { $0.decryption.enabled = false }) { upstream in
            var proxy = UpstreamProxy(host: "127.0.0.1", port: upstream.proxyPort, bypass: bypass)
            proxy.alwaysBypassLoopback = false
            let rules = TestRules.provider([TestRules.mapRemote(host: "localhost", port: upstream.origin.port)])
            try await ProxyFixture.run(configure: { $0.upstreamProxy = proxy }, rules: rules) { fx in
                let client = try await RawClient.connect(port: fx.proxyPort)
                // Port 1 refuses connections: an unmapped request could not succeed.
                try await client.send("GET http://127.0.0.1:1/hello HTTP/1.1\r\nHost: 127.0.0.1:1\r\nConnection: close\r\n\r\n")
                #expect(try await client.receive(until: "hello").hasPrefix("HTTP/1.1 200 OK\r\n"))
                try await client.close()
                if bypass == ["localhost"] {
                    try await Task.sleep(for: .milliseconds(100))
                    #expect(upstream.store.allFlows().isEmpty)
                } else {
                    let tunnel = try await waitForFlow(upstream.store) { $0.state == .tunnel }
                    #expect(tunnel.host == "localhost")
                    #expect(tunnel.port == upstream.origin.port)
                }
            }
        }
    }

    // MARK: listener self-mapping

    @Test(arguments: ["127.0.0.1", "localhost", "127.1"])
    func mappingBackToTheListenerIsRejected(host: String) async throws {
        let rules = TestRules.provider([])
        try await ProxyFixture.run(rules: rules) { fx in
            TestRules.publish([TestRules.mapRemote(host: host, port: fx.proxyPort)], revision: 2, to: rules)
            let client = try await RawClient.connect(port: fx.proxyPort)
            try await client.send("GET http://127.0.0.1:\(fx.origin.port)/hello HTTP/1.1\r\nHost: 127.0.0.1:\(fx.origin.port)\r\nConnection: close\r\n\r\n")
            try await client.waitUntilClosed()
            let text = String(decoding: client.remainingBytes(), as: UTF8.self)
            try await client.close()
            #expect(text.hasPrefix("HTTP/1.1 502 Bad Gateway\r\n"), "\(text)")
            #expect(text.contains("指向本代理"), "\(text)")
            let flow = try await waitForFlow(fx.store) {
                if case .failed = $0.state { return true }; return false
            }
            #expect(flow.path == "/hello")
            // No recursive exchange reached the listener.
            #expect(fx.store.allFlows().count == 1)
        }
    }

    private func decision(_ route: RuleRoute) -> RequestRuleDecision {
        RequestRuleDecision(effectiveHead: .request(HTTPMessageTarget(scheme: "http", host: "a.test", port: 80, method: "GET",
                                                                      pathAndQuery: "/"), headers: []),
                            route: route, breakpoint: nil, matches: RuleMatchSummary(revision: 1, ruleIDs: [], total: 0))
    }
}
