import FlowStore
import Foundation
import NIOCore
import NIOHTTP1
import NIOConcurrencyHelpers
import Testing
@testable import ProxyCore
@testable import RulesEngine

/// Delay request (spec 6.9, D16): the exchange is held on an event-loop timer after the request point and
/// before any breakpoint, local response or connection; the timer dies with the exchange. The tests take the
/// timer over with `ruleDelayHook` (or advance the embedded loop's clock), so nothing here sleeps.
@Suite(.serialized, .timeLimit(.minutes(3)), .productionChinese) struct RuleDelayTests {
    @Test func delayHoldsTheRequestUntilTheTimerFires() async throws {
        try await withConnectionFixture { f in
            let probe = DelayProbe()
            f.environment.ruleDelayHook = probe.hook
            let writer = RecordingResponseWriter(channel: f.client)
            let x = f.admit("/held", writer: writer, context: f.context(rules: TestRules.provider([delaying(300)])))
            x.execute(); x.receiveRequest(.end(nil))
            #expect(probe.delays == [.milliseconds(300)])
            #expect(f.connections.isEmpty)
            #expect(writer.heads.isEmpty)
            #expect(try f.flow("/held").state == .inProgress)
            probe.fire(f)
            #expect(f.connections.count == 1)
            let upstream = try f.connect(0)
            #expect(try f.written(upstream).hasPrefix("GET /held HTTP/1.1\r\n"))
            #expect(probe.delays.count == 1)
        }
    }

    @Test func delayAppliesBeforeBreakpoint() async throws {
        try await withConnectionFixture { f in
            let probe = DelayProbe()
            f.environment.ruleDelayHook = probe.hook
            let b = BreakpointCoordinator(clock: EmbeddedBreakpointClock(now: f.loop.now))
            let c = f.context(rules: TestRules.provider([delaying(300), TestRules.breakpoint(.request)]), breakpoints: b)
            let x = f.admit("/bp", writer: RecordingResponseWriter(channel: f.client), context: c)
            x.execute(); x.receiveRequest(.end(nil))
            #expect(b.snapshot().isEmpty)
            #expect(f.connections.isEmpty)
            probe.fire(f)
            #expect(b.snapshot().count == 1)
            #expect(f.connections.isEmpty)
        }
    }

    @Test func delayAppliesBeforeALocalResponse() async throws {
        let probe = DelayProbe()
        let forbidden = Rule(name: "forbidden", conditions: ConditionGroup(rows: []),
                             actions: [RuleAction(.returnPreset(PresetResponse(preset: .forbidden403, body: "no")))])
        try await ProxyFixture.run(rules: TestRules.provider([delaying(200), forbidden]), ruleDelayHook: probe.hook) { fx in
            let client = try await RawClient.connect(port: fx.proxyPort)
            let host = "127.0.0.1:\(fx.origin.port)"
            try await client.send("GET http://\(host)/local HTTP/1.1\r\nHost: \(host)\r\n\r\n")
            try await waitUntil("the delay to be requested") { probe.delays.count == 1 }
            #expect(client.remainingBytes().isEmpty)
            #expect(fx.origin.acceptedConnections == 0)
            probe.fireDirectly()
            let reply = try await client.receive(until: "\r\n\r\n")
            #expect(reply.hasPrefix("HTTP/1.1 403"))
            #expect(fx.origin.acceptedConnections == 0)
            try await client.close()
        }
    }

    @Test func delaysAccumulateToOneTimer() async throws {
        try await withConnectionFixture { f in
            let probe = DelayProbe()
            f.environment.ruleDelayHook = probe.hook
            let x = f.admit("/sum", writer: RecordingResponseWriter(channel: f.client),
                            context: f.context(rules: TestRules.provider([delaying(300), delaying(400)])))
            x.execute(); x.receiveRequest(.end(nil))
            #expect(probe.delays == [.milliseconds(700)])
        }
    }

    @Test func cappedDelayRecordsDelayCapped() async throws {
        try await withConnectionFixture { f in
            let probe = DelayProbe()
            f.environment.ruleDelayHook = probe.hook
            let rules = [delaying(50_000), delaying(50_000)]
            let x = f.admit("/cap", writer: RecordingResponseWriter(channel: f.client), context: f.context(rules: TestRules.provider(rules)))
            x.execute(); x.receiveRequest(.end(nil))
            #expect(probe.delays == [.milliseconds(60_000)])
            let outcomes = try #require(try f.flow("/cap").provenance.ruleMatches?.outcomes)
            #expect(outcomes.contains { $0.code == .delayCapped })
        }
    }

    @Test func cancelledExchangeCancelsTheTimer() async throws {
        try await withConnectionFixture { f in
            let probe = DelayProbe()
            f.environment.ruleDelayHook = probe.hook
            let writer = RecordingResponseWriter(channel: f.client)
            var x: HTTPExchange? = f.admit("/gone", writer: writer, context: f.context(rules: TestRules.provider([delaying(300)])))
            let observed = WeakExchangeRef(value: x)
            x?.execute(); x?.receiveRequest(.end(nil))
            x?.cancel(reason: "client went away")
            x = nil
            probe.fire(f)
            f.loop.run()
            #expect(f.connections.isEmpty)
            let gone = try f.flow("/gone")
            #expect(gone.completedAt != nil)
            #expect(observed.value == nil)
        }
        // The production timer is cancelled with the exchange too: the clock passing the deadline does nothing.
        try await withConnectionFixture { f in
            let x = f.admit("/gone-timer", writer: RecordingResponseWriter(channel: f.client),
                            context: f.context(rules: TestRules.provider([delaying(300)])))
            x.execute(); x.receiveRequest(.end(nil))
            x.cancel(reason: "client went away")
            f.loop.advanceTime(by: .seconds(1))
            #expect(f.connections.isEmpty)
        }
    }

    @Test func closingTheClientConnectionCancelsTheTimer() async throws {
        try await withConnectionFixture { f in
            let probe = DelayProbe()
            f.environment.ruleDelayHook = probe.hook
            let c = f.context(rules: TestRules.provider([delaying(300)]))
            let x = f.admit("/closed", writer: RecordingResponseWriter(channel: f.client), context: c)
            x.execute(); x.receiveRequest(.end(nil))
            c.close(error: nil)
            probe.fire(f)
            f.loop.run()
            #expect(f.connections.isEmpty)
            #expect(x.terminal)
        }
    }

    @Test func delayedExchangeIsNotRetriedOrReplayed() async throws {
        try await withConnectionFixture { f in
            let probe = DelayProbe()
            f.environment.ruleDelayHook = probe.hook
            let writer = RecordingResponseWriter(channel: f.client)
            let x = f.admit("/once", writer: writer, context: f.context(rules: TestRules.provider([delaying(300)])))
            x.execute(); x.receiveRequest(.end(nil))
            probe.fire(f); probe.fire(f)   // a second firing is ignored
            #expect(f.connections.count == 1)
            let upstream = try f.connect(0)
            #expect(try f.written(upstream).hasPrefix("GET /once HTTP/1.1\r\n"))
            try upstream.writeInbound(ByteBuffer(string: "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"))
            f.loop.run()
            #expect(writer.heads.map(\.status.code) == [200])
            #expect(probe.delays.count == 1)
            #expect(f.connections.count == 1)
        }
    }

    @Test func zeroDelayNeverSchedules() async throws {
        try await withConnectionFixture { f in
            let probe = DelayProbe()
            f.environment.ruleDelayHook = probe.hook
            let x = f.admit("/zero", writer: RecordingResponseWriter(channel: f.client),
                            context: f.context(rules: TestRules.provider([delaying(0)])))
            x.execute(); x.receiveRequest(.end(nil))
            #expect(probe.delays.isEmpty)
            #expect(f.connections.count == 1)
        }
    }

    @Test func noDelayRuleStaysByteIdentical() async throws {
        var runs: [Bool: ExchangeRun] = [:]
        for withRule in [false, true] {
            try await withConnectionFixture { f in
                let probe = DelayProbe()
                f.environment.ruleDelayHook = probe.hook
                let never = Rule(name: "never", conditions: ConditionGroup(rows: [ConditionRow(field: .pathAndQuery, op: .startsWith, value: "/never")]),
                                 actions: [RuleAction(.delay(milliseconds: 500))])
                let c = f.context(rules: withRule ? TestRules.provider([never]) : nil)
                let writer = RecordingResponseWriter(channel: f.client)
                let x = f.admit("/same", method: .POST, headers: HTTPHeaders([("Content-Length", "4")]), writer: writer, context: c)
                x.execute(); x.receiveRequest(.body(ByteBuffer(string: "data"))); x.receiveRequest(.end(nil))
                let upstream = try f.connect(0)
                let sent = try f.written(upstream)
                try upstream.writeInbound(ByteBuffer(string: "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"))
                f.loop.run()
                #expect(probe.delays.isEmpty)
                runs[withRule] = ExchangeRun(upstream: sent, client: writer.body, status: writer.heads.map(\.status.code),
                                             flow: try FlowDigest(f.flow("/same")).withoutUserFields)
            }
        }
        let baseline = try #require(runs[false]), observed = try #require(runs[true])
        #expect(observed.upstream == baseline.upstream)
        #expect(observed.client == baseline.client && observed.status == baseline.status)
        #expect(observed.flow == baseline.flow)
    }

    @Test func productionTimerUsesEventLoopSchedule() async throws {
        // No hook: the exchange schedules on its own event loop, which the embedded clock advances.
        try await withConnectionFixture { f in
            let x = f.admit("/timer", writer: RecordingResponseWriter(channel: f.client),
                            context: f.context(rules: TestRules.provider([delaying(5)])))
            x.execute(); x.receiveRequest(.end(nil))
            #expect(f.connections.isEmpty)
            f.loop.advanceTime(by: .milliseconds(4))
            #expect(f.connections.isEmpty)
            f.loop.advanceTime(by: .milliseconds(1))
            #expect(f.connections.count == 1)
        }
        // And on a real server: the response arrives once the 5 ms timer fires.
        try await ProxyFixture.run(rules: TestRules.provider([delaying(5)])) { fx in
            let client = try await RawClient.connect(port: fx.proxyPort)
            let host = "127.0.0.1:\(fx.origin.port)"
            try await client.send("GET http://\(host)/hello HTTP/1.1\r\nHost: \(host)\r\n\r\n")
            let reply = try await client.receive(until: "\r\n\r\n")
            #expect(reply.hasPrefix("HTTP/1.1 200"))
            try await client.close()
        }
    }
}

private struct WeakExchangeRef { weak var value: HTTPExchange? }

private struct ExchangeRun {
    var upstream: String
    var client: String
    var status: [UInt]
    var flow: FlowDigest
}

private func delaying(_ milliseconds: Int) -> Rule {
    Rule(name: "delay \(milliseconds)", conditions: ConditionGroup(rows: []), actions: [RuleAction(.delay(milliseconds: milliseconds))])
}

/// Takes `ruleDelayHook` over: records the requested delays and lets the test fire the timer by hand.
private final class DelayProbe: Sendable {
    private let state = NIOLockedValueBox<(delays: [TimeAmount], callbacks: [@Sendable () -> Void])>(([], []))
    var delays: [TimeAmount] { state.withLockedValue { $0.delays } }
    var hook: RuleDelayHook {
        { [self] delay, callback in
            state.withLockedValue { $0.delays.append(delay); $0.callbacks.append(callback) }
            return true
        }
    }
    func fireDirectly() { state.withLockedValue { $0.callbacks }.forEach { $0() } }
    func fire(_ f: ConnectionFixture) {
        let callbacks = state.withLockedValue { $0.callbacks }
        callbacks.forEach { $0() }
        f.loop.run()
    }
}
