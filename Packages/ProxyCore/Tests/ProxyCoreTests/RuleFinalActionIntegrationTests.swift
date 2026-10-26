import FlowStore
import Foundation
import NIOCore
import NIOHTTP1
import Testing
@testable import ProxyCore
@testable import RulesEngine

/// Rules 2.0 in real exchanges (spec 5.5.4, 5.5.5, 5.5.6, 5.6.3): a final action ends the exchange's
/// evaluation, a later rule reads what an earlier one changed, two rewrites of one target run one after
/// the other, and a rule with several actions runs them where each belongs.
@Suite(.serialized, .timeLimit(.minutes(3)), .productionChinese) struct RuleFinalActionIntegrationTests {
    // MARK: final actions

    @Test func mapLocalFileIsFinalLowerPriorityHeaderRuleDoesNotApply() async throws {
        try await withLocalAsset(Data("local-bytes".utf8)) { asset in
            let local = rule("local", [returnFile(asset)])
            let lowerRequest = rule("lower request", [setHeader(.request, "X-Lower-Request")])
            let lowerResponse = rule("lower response", [setHeader(.response, "X-Lower-Response")])
            let rules = TestRules.provider([local, lowerRequest, lowerResponse])
            try await ProxyFixture.run(rules: rules, assets: asset.store) { fx in
                let reply = try await directoryRaw(fx, host: "127.0.0.1:\(fx.origin.port)", path: "/hello")
                try #require(reply.head.hasPrefix("HTTP/1.1 200 OK"))
                #expect(reply.body == Data("local-bytes".utf8))
                #expect(reply.field("x-lower-response").isEmpty)
                #expect(fx.origin.acceptedConnections == 0)
                #expect(fx.origin.receivedRequestCount == 0)
                let flow = try await waitForFlow(fx.store) { $0.state == .completed }
                #expect(flow.messages[.upstreamRequest] == nil)
                #expect(flow.provenance.ruleMatches?.ruleIDs == [local.id])
                #expect(flow.provenance.ruleMatches?.outcomes == [
                    RuleOutcome(ruleID: local.id, code: .applied), RuleOutcome(ruleID: local.id, code: .finalStop, actionIndex: 0),
                ])
            }
        }
    }

    @Test func higherPriorityHeaderRuleStillAppliesToLocalResponse() async throws {
        try await withLocalAsset(Data("local-bytes".utf8)) { asset in
            let higher = rule("higher", [setHeader(.response, "X-Higher")])
            let local = rule("local", [returnFile(asset)])
            try await ProxyFixture.run(rules: TestRules.provider([higher, local]), assets: asset.store) { fx in
                let reply = try await directoryRaw(fx, host: "127.0.0.1:\(fx.origin.port)", path: "/hello")
                try #require(reply.head.hasPrefix("HTTP/1.1 200 OK"))
                #expect(reply.field("x-higher") == ["1"])
                #expect(reply.body == Data("local-bytes".utf8))
                #expect(fx.origin.acceptedConnections == 0)
                let flow = try await waitForFlow(fx.store) { $0.state == .completed }
                #expect(flow.messages[.generatedResponse]?.headers.contains { $0.name.lowercased() == "x-higher" } == false)
                #expect(flow.messages[.downstreamResponse]?.headers.contains { $0.name.lowercased() == "x-higher" } == true)
                #expect(flow.provenance.ruleMatches?.ruleIDs == [local.id, higher.id])
                #expect(flow.provenance.ruleMatches?.outcomes == [
                    RuleOutcome(ruleID: local.id, code: .applied), RuleOutcome(ruleID: higher.id, code: .applied),
                ])
            }
        }
    }

    @Test func lowerPriorityResponseHeaderRuleIsSkippedForLocalResponse() async throws {
        try await withLocalAsset(Data("local-bytes".utf8)) { asset in
            let higher = rule("higher", [setHeader(.response, "X-Higher")])
            let local = rule("local", [returnFile(asset)])
            let lower = rule("lower", [setHeader(.response, "X-Lower")])
            try await ProxyFixture.run(rules: TestRules.provider([higher, local, lower]), assets: asset.store) { fx in
                let reply = try await directoryRaw(fx, host: "127.0.0.1:\(fx.origin.port)", path: "/hello")
                try #require(reply.head.hasPrefix("HTTP/1.1 200 OK"))
                #expect(reply.field("x-higher") == ["1"])
                #expect(reply.field("x-lower").isEmpty)
                let flow = try await waitForFlow(fx.store) { $0.state == .completed }
                #expect(flow.provenance.ruleMatches?.ruleIDs == [local.id, higher.id])
                #expect(flow.provenance.ruleMatches?.total == 2)
                #expect(flow.provenance.ruleMatches?.outcomes == [
                    RuleOutcome(ruleID: local.id, code: .applied), RuleOutcome(ruleID: local.id, code: .finalStop, actionIndex: 0),
                    RuleOutcome(ruleID: higher.id, code: .applied),
                ])
            }
        }
    }

    @Test func finalFlagOnARequestHeaderEditStopsLowerRules() async throws {
        try await withConnectionFixture { fixture in
            let first = rule("final edit", [setHeader(.request, "X-First", final: true)])
            let lowerRequest = rule("lower request", [setHeader(.request, "X-Second")])
            let lowerResponse = rule("lower response", [setHeader(.response, "X-Response")])
            let writer = RecordingResponseWriter(channel: fixture.client)
            let exchange = fixture.admit("/final", writer: writer,
                                         context: fixture.context(rules: TestRules.provider([first, lowerRequest, lowerResponse])))
            exchange.receiveRequest(.end(nil))
            exchange.execute()
            let upstream = try fixture.connect(0)
            let wire = try fixture.written(upstream)
            #expect(wire.contains("\r\nX-First: 1\r\n"))
            #expect(!wire.contains("X-Second"))
            try upstream.writeInbound(ByteBuffer(string: "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"))
            fixture.loop.run()
            #expect(writer.heads.map(\.status.code) == [200])
            #expect(writer.heads.first?.headers["X-Response"] == [])
            let flow = try fixture.flow("/final")
            #expect(flow.provenance.ruleMatches?.ruleIDs == [first.id])
            #expect(flow.provenance.ruleMatches?.outcomes == [
                RuleOutcome(ruleID: first.id, code: .applied), RuleOutcome(ruleID: first.id, code: .finalStop, actionIndex: 0),
            ])
            #expect(flow.provenance.rulesModified)
        }
    }

    /// The directory rule had already cut the lower rules when its missing file sent the request on to
    /// the network (D15).
    @Test func directoryFallbackToNetworkKeepsTruncationOfLowerRules() async throws {
        try await withMappedDirectory([:]) { dir in
            let directory = rule("directory", [returnDirectory(dir, missing: .network)], rows: [host("127.0.0.1")])
            let lowerRequest = rule("lower request", [setHeader(.request, "X-Lower")])
            let lowerResponse = rule("lower response", [setHeader(.response, "X-Lower-Response")])
            let rules = TestRules.provider([directory, lowerRequest, lowerResponse])
            try await ProxyFixture.run(rules: rules, assets: dir.store) { fx in
                let reply = try await directoryRaw(fx, host: "127.0.0.1:\(fx.origin.port)", path: "/hello")
                try #require(reply.head.hasPrefix("HTTP/1.1 200 OK"))
                #expect(String(decoding: reply.body, as: UTF8.self) == "hello")
                #expect(reply.field("x-lower-response").isEmpty)
                #expect(fx.origin.receivedRequestCount == 1)
                let head = try #require(fx.origin.receivedRequests.first?.head)
                #expect(head.uri == "/hello")
                #expect(head.headers["X-Lower"].isEmpty)
                let flow = try await waitForFlow(fx.store) { $0.state == .completed }
                #expect(flow.provenance.generatedResponse == nil)
                #expect(flow.provenance.ruleMatches?.ruleIDs == [directory.id])
                #expect(flow.provenance.ruleMatches?.outcomes == [
                    RuleOutcome(ruleID: directory.id, code: .applied),
                    RuleOutcome(ruleID: directory.id, code: .finalStop, actionIndex: 0),
                ])
            }
        }
    }

    /// A directory rule below a Map Remote reads the mapped request; when it falls back to the
    /// network, the request goes where the Map Remote sent it, not back to the original host.
    @Test func directoryFallbackAfterAMapRemoteGoesWhereTheMapSentTheRequest() async throws {
        try await withMappedDirectory([:]) { dir in
            let provider = TestRules.provider([])
            try await ProxyFixture.run(rules: provider, assets: dir.store) { fx in
                let map = rule("map", [remote(host: "127.0.0.1", port: fx.origin.port)], rows: [host("localhost")])
                let directory = rule("directory", [returnDirectory(dir, missing: .network)], rows: [host("127.0.0.1")])
                TestRules.publish([map, directory], revision: 2, to: provider)
                // Port 1 refuses connections: only the mapped target can answer.
                let reply = try await directoryRaw(fx, host: "localhost:1", path: "/hello")
                try #require(reply.head.hasPrefix("HTTP/1.1 200 OK"), "\(reply.head)")
                #expect(String(decoding: reply.body, as: UTF8.self) == "hello")
                let head = try #require(fx.origin.receivedRequests.first?.head)
                #expect(head.headers["Host"] == ["127.0.0.1:\(fx.origin.port)"])
                let flow = try await waitForFlow(fx.store) { $0.state == .completed }
                #expect(flow.messages[.upstreamRequest]?.target?.port == fx.origin.port)
                #expect(flow.provenance.ruleMatches?.outcomes == [
                    RuleOutcome(ruleID: map.id, code: .applied), RuleOutcome(ruleID: directory.id, code: .applied),
                ])
            }
        }
    }

    @Test func upgradeHandshakeKeepsLowerRulesWhenTheMapIsIgnored() async throws {
        try await withConnectionFixture { fixture in
            let local = rule("local", [RuleAction(.returnFile(MapLocalAction(assetID: UUID(), headers: [])))])
            let lowerRequest = rule("lower request", [setHeader(.request, "X-Ws")])
            let lowerResponse = rule("lower response", [setHeader(.response, "X-Resp101")])
            let writer = RecordingResponseWriter(channel: fixture.client)
            let exchange = fixture.admit("/ws", headers: HTTPHeaders([
                ("Upgrade", "websocket"), ("Connection", "Upgrade"), ("Sec-WebSocket-Key", "k"), ("Sec-WebSocket-Version", "13"),
            ]), writer: writer, context: fixture.context(rules: TestRules.provider([local, lowerRequest, lowerResponse])))
            exchange.receiveRequest(.end(nil))
            exchange.execute()
            let upstream = try fixture.connect(0)
            #expect(try fixture.written(upstream).contains("\r\nX-Ws: 1\r\n"))
            try upstream.writeInbound(ByteBuffer(string:
                "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: a\r\n\r\n"))
            fixture.loop.run()
            let head = try #require(writer.heads.first)
            #expect(head.status == .switchingProtocols)
            #expect(head.headers["X-Resp101"] == ["1"])
            let flow = try fixture.flow("/ws")
            #expect(flow.provenance.ruleMatches?.ruleIDs == [local.id, lowerRequest.id, lowerResponse.id])
            #expect(flow.provenance.ruleMatches?.outcomes.map(\.code) == [.unsupportedUpgradeAction, .applied, .applied])
            #expect(flow.provenance.ruleMatches?.outcomes.allSatisfy { $0.actionIndex == nil } == true)
        }
    }

    // MARK: later rules see earlier changes; one target rewritten twice

    /// Class 2: the lower rule names the host the request had before the Map Remote moved it.
    @Test func mapRemoteMovesTheHostSoALowerOriginalHostRuleNoLongerMatches() async throws {
        let provider = TestRules.provider([])
        try await ProxyFixture.run(rules: provider) { fx in
            let map = rule("map", [remote(host: "127.0.0.1", port: fx.origin.port)], rows: [host("localhost")])
            let originalRequest = rule("original host request", [setHeader(.request, "X-Original")], rows: [host("localhost")])
            let originalResponse = rule("original host response", [setHeader(.response, "X-Original-Response")], rows: [host("localhost")])
            TestRules.publish([map, originalRequest, originalResponse], revision: 2, to: provider)
            // Port 1 refuses connections: only the mapped target can answer.
            let reply = try await directoryRaw(fx, host: "localhost:1", path: "/hello")
            try #require(reply.head.hasPrefix("HTTP/1.1 200 OK"), "\(reply.head)")
            #expect(String(decoding: reply.body, as: UTF8.self) == "hello")
            #expect(reply.field("x-original-response").isEmpty)
            let head = try #require(fx.origin.receivedRequests.first?.head)
            #expect(head.headers["Host"] == ["127.0.0.1:\(fx.origin.port)"])
            #expect(head.headers["X-Original"].isEmpty)
            let flow = try await waitForFlow(fx.store) { $0.state == .completed }
            #expect(flow.provenance.ruleMatches?.ruleIDs == [map.id])
            #expect(flow.provenance.ruleMatches?.outcomes == [RuleOutcome(ruleID: map.id, code: .applied)])
        }
    }

    /// Class 2, the other way: a lower rule naming the Map Remote's target now matches.
    @Test func ruleBelowMatchingTheTargetHostNowMatches() async throws {
        let provider = TestRules.provider([])
        try await ProxyFixture.run(rules: provider) { fx in
            let map = rule("map", [remote(host: "127.0.0.1", port: fx.origin.port)], rows: [host("localhost")])
            let targetRequest = rule("target host request", [setHeader(.request, "X-Target")], rows: [host("127.0.0.1")])
            let targetResponse = rule("target host response", [setHeader(.response, "X-Target-Response")], rows: [host("127.0.0.1")])
            TestRules.publish([map, targetRequest, targetResponse], revision: 2, to: provider)
            let reply = try await directoryRaw(fx, host: "localhost:1", path: "/hello")
            try #require(reply.head.hasPrefix("HTTP/1.1 200 OK"), "\(reply.head)")
            #expect(reply.field("x-target-response") == ["1"])
            let head = try #require(fx.origin.receivedRequests.first?.head)
            #expect(head.headers["X-Target"] == ["1"])
            let flow = try await waitForFlow(fx.store) { $0.state == .completed }
            #expect(flow.provenance.ruleMatches?.ruleIDs == [map.id, targetRequest.id, targetResponse.id])
            #expect(flow.provenance.ruleMatches?.outcomes.map(\.code) == [.applied, .applied, .applied])
        }
    }

    /// Class 3: both status rewrites run; the client sees the second status.
    @Test func secondStatusRewriteWins() async throws {
        let first = rule("first status", [rewriteStatus(201)])
        let second = rule("second status", [rewriteStatus(202)])
        try await ProxyFixture.run(rules: TestRules.provider([first, second])) { fx in
            let reply = try await directoryRaw(fx, host: "127.0.0.1:\(fx.origin.port)", path: "/hello")
            #expect(reply.head.hasPrefix("HTTP/1.1 202 Accepted\r\n"), "\(reply.head)")
            #expect(String(decoding: reply.body, as: UTF8.self) == "hello")
            let flow = try await waitForFlow(fx.store) { $0.state == .completed }
            #expect(flow.messages[.upstreamResponse]?.status == 200)
            #expect(flow.messages[.downstreamResponse]?.status == 202)
            #expect(flow.provenance.ruleMatches?.outcomes == [
                RuleOutcome(ruleID: first.id, code: .applied), RuleOutcome(ruleID: second.id, code: .applied),
            ])
        }
    }

    /// Class 3: the second Map Remote matches the first one's target and continues from it; the
    /// first one's replaced path stays (D16).
    @Test func secondMapRemoteReadsTheFirstUrl() async throws {
        try await withConnectionFixture { fixture in
            fixture.expectedEndpoint = (host: "second.test", port: 82)
            let first = rule("first map", [remote(host: "first.test", port: 81, path: .replace("/one?x=1"))], rows: [host("example.test")])
            let second = rule("second map", [remote(host: "second.test", port: 82)], rows: [host("first.test")])
            let original = rule("original host", [setHeader(.request, "X-Original")], rows: [host("example.test")])
            let writer = RecordingResponseWriter(channel: fixture.client)
            let exchange = fixture.admit("/map", writer: writer,
                                         context: fixture.context(rules: TestRules.provider([first, second, original])))
            exchange.receiveRequest(.end(nil))
            exchange.execute()
            let upstream = try fixture.connect(0)
            let wire = try fixture.written(upstream)
            #expect(wire.hasPrefix("GET /one?x=1 HTTP/1.1\r\n"), "\(wire)")
            #expect(wire.contains("\r\nHost: second.test:82\r\n"))
            #expect(!wire.contains("X-Original"))
            try upstream.writeInbound(ByteBuffer(string: "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"))
            fixture.loop.run()
            #expect(fixture.connectedEndpoints == ["second.test:82"])
            let flow = try fixture.flow("/map")
            #expect(flow.messages[.upstreamRequest]?.target?.host == "second.test")
            #expect(flow.provenance.ruleMatches?.outcomes == [
                RuleOutcome(ruleID: first.id, code: .applied), RuleOutcome(ruleID: second.id, code: .applied),
            ])
        }
    }

    @Test func mapRemoteThenMapLocalAnswersLocally() async throws {
        try await withLocalAsset(Data("local-bytes".utf8)) { asset in
            // The Return File rule names the port the Map Remote sends to, so it can only match after it.
            let map = rule("map", [remote(host: "127.0.0.1", port: 1)], rows: [host("localhost")])
            let local = rule("local", [returnFile(asset)], rows: [port(1)])
            try await ProxyFixture.run(rules: TestRules.provider([map, local]), assets: asset.store) { fx in
                let reply = try await directoryRaw(fx, host: "localhost:\(fx.origin.port)", path: "/hello")
                try #require(reply.head.hasPrefix("HTTP/1.1 200 OK"), "\(reply.head)")
                #expect(reply.body == Data("local-bytes".utf8))
                #expect(fx.origin.acceptedConnections == 0)
                let flow = try await waitForFlow(fx.store) { $0.state == .completed }
                #expect(flow.messages[.upstreamRequest] == nil)
                #expect(flow.provenance.generatedResponse?.assetID == asset.asset.id)
                #expect(flow.provenance.ruleMatches?.outcomes == [
                    RuleOutcome(ruleID: map.id, code: .applied), RuleOutcome(ruleID: local.id, code: .applied),
                ])
            }
        }
    }

    // MARK: rules with several actions

    @Test func multiActionRuleRunsRequestAndResponseActionsInOneExchange() async throws {
        try await withConnectionFixture { fixture in
            let both = rule("both", [setHeader(.request, "X-Multi"), rewriteStatus(203)])
            let writer = RecordingResponseWriter(channel: fixture.client)
            let exchange = fixture.admit("/multi", writer: writer, context: fixture.context(rules: TestRules.provider([both])))
            exchange.receiveRequest(.end(nil))
            exchange.execute()
            let upstream = try fixture.connect(0)
            #expect(try fixture.written(upstream).contains("\r\nX-Multi: 1\r\n"))
            try upstream.writeInbound(ByteBuffer(string: "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"))
            fixture.loop.run()
            #expect(writer.heads.map(\.status.code) == [203])
            let flow = try fixture.flow("/multi")
            #expect(flow.provenance.ruleMatches?.outcomes == [
                RuleOutcome(ruleID: both.id, code: .applied, actionIndex: 0),
                RuleOutcome(ruleID: both.id, code: .applied, actionIndex: 1),
            ])
        }
    }

    @Test func ruleIDsAreUniqueWhenARuleHasRequestAndResponseOutcomes() async throws {
        try await withConnectionFixture { fixture in
            let both = rule("both", [setHeader(.request, "X-A"), setHeader(.response, "X-B")])
            let other = rule("other", [setHeader(.response, "X-C")])
            let writer = RecordingResponseWriter(channel: fixture.client)
            let exchange = fixture.admit("/unique", writer: writer, context: fixture.context(rules: TestRules.provider([both, other])))
            exchange.receiveRequest(.end(nil))
            exchange.execute()
            let upstream = try fixture.connect(0)
            _ = try fixture.written(upstream)
            try upstream.writeInbound(ByteBuffer(string: "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"))
            fixture.loop.run()
            #expect(writer.heads.first?.headers["X-B"] == ["1"])
            #expect(writer.heads.first?.headers["X-C"] == ["1"])
            let flow = try fixture.flow("/unique")
            let matches = try #require(flow.provenance.ruleMatches)
            #expect(matches.ruleIDs == [both.id, other.id])
            #expect(matches.total == 2)
            #expect(matches.outcomes == [
                RuleOutcome(ruleID: both.id, code: .applied, actionIndex: 0),
                RuleOutcome(ruleID: both.id, code: .applied, actionIndex: 1),
                RuleOutcome(ruleID: other.id, code: .applied),
            ])
            #expect(try harRuleOutcomes(flow) == [
                [both.id.uuidString, "applied"], [both.id.uuidString, "applied"], [other.id.uuidString, "applied"],
            ])
        }
    }

    @Test func bodyRewriteOutcomeCarriesActionIndexForMultiActionRules() async throws {
        let bodies = rule("bodies", [rewriteBody(.response, find: "hel", replacement: "HEL"),
                                     rewriteBody(.response, find: "absent", replacement: "x")])
        try await ProxyFixture.run(rules: TestRules.provider([bodies])) { fx in
            let reply = try await directoryRaw(fx, host: "127.0.0.1:\(fx.origin.port)", path: "/hello")
            try #require(reply.head.hasPrefix("HTTP/1.1 200 OK"))
            #expect(String(decoding: reply.body, as: UTF8.self) == "HELlo")
            let flow = try await waitForFlow(fx.store) { $0.state == .completed }
            #expect(flow.provenance.ruleMatches?.outcomes == [
                RuleOutcome(ruleID: bodies.id, code: .applied, actionIndex: 0),
                RuleOutcome(ruleID: bodies.id, code: .bodyNoMatch, actionIndex: 1),
            ])
            #expect(flow.provenance.rulesModified)
        }
    }

    /// The source of a generated directory response is the rule whose Return File (directory) action
    /// chose the route, also when that action is not the rule's first.
    @Test func directoryResponseNamesAMultiActionRuleAsItsSource() async throws {
        try await withMappedDirectory(["a.css": Data("abc".utf8)]) { dir in
            let directory = rule("directory", [setHeader(.request, "X-Before"), returnDirectory(dir, prefix: "/static/")],
                                 rows: [host("app.test")])
            try await ProxyFixture.run(rules: TestRules.provider([directory]), assets: dir.store) { fx in
                let reply = try await directoryRaw(fx, path: "/static/a.css")
                try #require(reply.head.hasPrefix("HTTP/1.1 200 OK"), "\(reply.head)")
                #expect(reply.body == Data("abc".utf8))
                let flow = try await waitForFlow(fx.store) { $0.state == .completed }
                #expect(flow.provenance.generatedResponse?.assetID == directory.id)
                #expect(flow.provenance.ruleMatches?.outcomes == [
                    RuleOutcome(ruleID: directory.id, code: .applied, actionIndex: 0),
                    RuleOutcome(ruleID: directory.id, code: .applied, actionIndex: 1),
                ])
            }
        }
    }

    @Test func failureFlowWithoutAResponseRecordsNoResponseSideOutcomes() async throws {
        try await withConnectionFixture { fixture in
            let both = rule("both", [setHeader(.request, "X-A"), setHeader(.response, "X-B")])
            let statusJudged = rule("status judged", [setHeader(.response, "X-S")], rows: [statusRange("200-599")])
            let writer = RecordingResponseWriter(channel: fixture.client)
            let exchange = fixture.admit("/down", writer: writer,
                                         context: fixture.context(rules: TestRules.provider([both, statusJudged])))
            exchange.receiveRequest(.end(nil))
            exchange.execute()
            fixture.connections[0].fail(ChannelError.ioOnClosedChannel)
            fixture.loop.run()
            #expect(writer.heads.map(\.status.code) == [502])
            let flow = try fixture.flow("/down")
            if case .failed = flow.state {} else { Issue.record("expected a failed flow") }
            #expect(flow.provenance.ruleMatches?.ruleIDs == [both.id])
            #expect(flow.provenance.ruleMatches?.total == 1)
            #expect(flow.provenance.ruleMatches?.outcomes == [RuleOutcome(ruleID: both.id, code: .applied, actionIndex: 0)])
        }
    }

    // MARK: rulesModified

    @Test func rulesModifiedIsSetOnlyByChangingActions() async throws {
        // A breakpoint alone changes nothing.
        let coordinator = BreakpointCoordinator()
        defer { coordinator.shutdown() }
        try await withConnectionFixture { fixture in
            let pause = rule("pause", [RuleAction(.breakpoint(direction: .request, mode: .headers))])
            let writer = RecordingResponseWriter(channel: fixture.client)
            let exchange = fixture.admit("/pause", writer: writer,
                                         context: fixture.context(rules: TestRules.provider([pause]), breakpoints: coordinator))
            defer { exchange.cancel(reason: "cleanup") }
            exchange.receiveRequest(.end(nil))
            exchange.execute()
            #expect(coordinator.snapshot().count == 1)
            let flow = try fixture.flow("/pause")
            #expect(flow.provenance.ruleMatches?.outcomes == [RuleOutcome(ruleID: pause.id, code: .applied)])
            #expect(!flow.provenance.rulesModified)
        }
        // A request header edit, a Map Remote and a status rewrite each change the exchange.
        #expect(try await Self.rulesModified([rule("edit", [setHeader(.request, "X-Edit")])]))
        #expect(try await Self.rulesModified([rule("status", [rewriteStatus(203)])]))
        #expect(try await Self.rulesModified([rule("map", [remote(host: "mapped.test", port: 81)])],
                                              endpoint: (host: "mapped.test", port: 81)))
        #expect(try await Self.rulesModified([rule("unrelated", [setHeader(.request, "X-No")], rows: [host("other.test")])]) == false)
        // A body rewrite counts only once it really rewrote the body.
        for (find, rewritten) in [("absent", false), ("hello", true)] {
            let body = rule("body", [rewriteBody(.response, find: find, replacement: "bye")])
            try await ProxyFixture.run(rules: TestRules.provider([body])) { fx in
                let reply = try await directoryRaw(fx, host: "127.0.0.1:\(fx.origin.port)", path: "/hello")
                #expect(String(decoding: reply.body, as: UTF8.self) == (rewritten ? "bye" : "hello"))
                let flow = try await waitForFlow(fx.store) { $0.state == .completed }
                #expect(flow.provenance.ruleMatches?.outcomes.map(\.code) == [rewritten ? .applied : .bodyNoMatch])
                #expect(flow.provenance.rulesModified == rewritten, "\(find)")
            }
        }
    }

    // MARK: frozen snapshot

    /// The response point runs on the snapshot the request point used, whatever is published meanwhile.
    @Test func inFlightExchangeKeepsItsFrozenSnapshotAcrossAPublish() async throws {
        try await withConnectionFixture { fixture in
            let v1 = rule("v1", [setHeader(.request, "X-Req-Rev", "1"), setHeader(.response, "X-Rev", "1")])
            let provider = TestRules.provider([v1], revision: 1)
            let writer = RecordingResponseWriter(channel: fixture.client)
            let exchange = fixture.admit("/frozen", writer: writer, context: fixture.context(rules: provider))
            exchange.receiveRequest(.end(nil))
            exchange.execute()
            let upstream = try fixture.connect(0)
            #expect(try fixture.written(upstream).contains("\r\nX-Req-Rev: 1\r\n"))
            // Another rule now sits where v1 was; the response must still be judged on revision 1.
            let v2 = rule("v2", [setHeader(.response, "X-Rev", "2")])
            TestRules.publish([v2, v1], revision: 2, to: provider)
            try upstream.writeInbound(ByteBuffer(string: "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"))
            fixture.loop.run()
            #expect(writer.heads.first?.headers["X-Rev"] == ["1"])
            let flow = try fixture.flow("/frozen")
            #expect(flow.provenance.ruleMatches?.revision == 1)
            #expect(flow.provenance.ruleMatches?.outcomes == [
                RuleOutcome(ruleID: v1.id, code: .applied, actionIndex: 0),
                RuleOutcome(ruleID: v1.id, code: .applied, actionIndex: 1),
            ])
        }
    }

    /// Runs one plain exchange on `rules` to completion and reports the flow's `rulesModified`.
    private static func rulesModified(
        _ rules: [Rule], endpoint: (host: String, port: Int) = (host: "example.test", port: 80)
    ) async throws -> Bool {
        var modified = false
        try await withConnectionFixture { fixture in
            fixture.expectedEndpoint = endpoint
            let writer = RecordingResponseWriter(channel: fixture.client)
            let exchange = fixture.admit("/modified", writer: writer, context: fixture.context(rules: TestRules.provider(rules)))
            exchange.receiveRequest(.end(nil))
            exchange.execute()
            let upstream = try fixture.connect(0)
            _ = try fixture.written(upstream)
            try upstream.writeInbound(ByteBuffer(string: "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"))
            fixture.loop.run()
            let flow = try fixture.flow("/modified")
            #expect(flow.state == .completed)
            modified = flow.provenance.rulesModified
        }
        return modified
    }
}

// MARK: rule building

private func rule(_ name: String, _ actions: [RuleAction], rows: [ConditionRow] = []) -> Rule {
    Rule(name: name, conditions: ConditionGroup(rows: rows), actions: actions)
}

private func host(_ pattern: String) -> ConditionRow { ConditionRow(field: .host, op: .hostPattern, value: pattern) }

private func port(_ value: Int) -> ConditionRow { ConditionRow(field: .port, op: .equals, value: String(value)) }

private func statusRange(_ range: String) -> ConditionRow { ConditionRow(field: .statusCode, op: .inRange, value: range) }

private func setHeader(
    _ direction: HTTPMessageDirection, _ name: String, _ value: String = "1", final: Bool = false
) -> RuleAction {
    RuleAction(.editHeaders(direction: direction, operations: [.set(name: name, value: value)]), isFinal: final)
}

private func remote(host: String, port: Int, path: RemotePathPolicy = .preserve) -> RuleAction {
    RuleAction(.mapRemote(MapRemoteAction(targetScheme: "http", targetHost: host, targetPort: port, path: path)))
}

private func rewriteStatus(_ status: Int) -> RuleAction {
    RuleAction(.rewriteStatus(RewriteStatusAction(status: status)))
}

private func rewriteBody(_ direction: HTTPMessageDirection, find: String, replacement: String) -> RuleAction {
    RuleAction(.rewriteBody(direction: direction, BodyRewriteAction(find: find, replacement: replacement)))
}

private func returnFile(_ asset: LocalAsset) -> RuleAction {
    RuleAction(.returnFile(MapLocalAction(
        assetID: asset.asset.id, headers: [HeaderField(name: "Content-Type", value: "application/octet-stream")])))
}

private func returnDirectory(
    _ fixture: MappedDirectoryFixture, prefix: String = "/", missing: MissingFilePolicy = .notFound
) -> RuleAction {
    RuleAction(.returnDirectory(
        MapLocalDirectoryAction(bookmark: fixture.bookmark, displayName: "www", missing: missing), pathPrefix: prefix))
}
