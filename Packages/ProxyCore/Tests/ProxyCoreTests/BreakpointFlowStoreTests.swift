import FlowStore
import Foundation
import NIOCore
import Testing
@testable import ProxyCore
@testable import RulesEngine

/// The store's pause flag follows the real breakpoint path, so the live count can tell "paused" from "opened".
@Suite(.productionChinese) struct BreakpointFlowStoreTests {
    @Test func pauseFlagIsSetWhileHeldAndClearedOnContinue() async throws {
        try await withConnectionFixture { f in
            let (_, x, _, b) = breakpointExchange(f)
            x.receiveRequest(.end(nil))
            let id = try #require(x.flowID)
            #expect(f.store.flow(id)?.isPausedAtBreakpoint == true)
            let t = try #require(b.snapshot().first)
            #expect(try breakpointPerform(b, .continue(token: t.token, edit: .init(head: t.effectiveHead)), f) == .accepted)
            #expect(f.store.flow(id)?.isPausedAtBreakpoint == false)
            #expect(f.store.flow(id)?.state == .inProgress)
        }
    }

    @Test func pauseFlagIsClearedWhenTheTicketExpires() async throws {
        try await withConnectionFixture { f in
            let (_, x, _, b) = breakpointExchange(f)
            x.receiveRequest(.end(nil))
            let id = try #require(x.flowID)
            #expect(f.store.flow(id)?.isPausedAtBreakpoint == true)
            breakpointAdvance(f, b, by: .seconds(120))
            #expect(f.store.flow(id)?.isPausedAtBreakpoint == false)
        }
    }

    @Test func pauseFlagIsClearedWhenTheExchangeIsCancelled() async throws {
        try await withConnectionFixture { f in
            let (_, x, _, _) = breakpointExchange(f)
            x.receiveRequest(.end(nil))
            let id = try #require(x.flowID)
            x.cancel(reason: "cleanup")
            #expect(f.store.flow(id)?.isPausedAtBreakpoint == false)
        }
    }

    @Test func flowsWithoutABreakpointNeverGetTheFlag() async throws {
        try await withConnectionFixture { f in
            let c = f.context()
            let w = RecordingResponseWriter(channel: f.client, version: .http1_1)
            let x = f.admit("/plain", method: .GET, headers: .init(), writer: w, context: c)
            x.execute()
            x.receiveRequest(.end(nil))
            let id = try #require(x.flowID)
            #expect(f.store.flow(id)?.isPausedAtBreakpoint == false)
        }
    }

    @Test func responseBreakpointSetsAndClearsTheFlag() async throws {
        try await withConnectionFixture { f in
            let (_, x, w, b) = responseBreakpointExchange(f)
            let id = try #require(x.flowID)
            #expect(f.store.flow(id)?.isPausedAtBreakpoint == false)
            let upstream = try f.connect(0)
            try upstream.writeInbound(ByteBuffer(string: "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"))
            let t = try #require(b.snapshot().first)
            #expect(f.store.flow(id)?.isPausedAtBreakpoint == true)
            #expect(f.store.flow(id)?.state == .inProgress)
            #expect(try breakpointPerform(b, .continue(token: t.token, edit: .init(head: t.effectiveHead)), f) == .accepted)
            #expect(f.store.flow(id)?.isPausedAtBreakpoint == false)
            #expect(w.body == "ok")
        }
    }

    @Test func responseBreakpointCancelLeavesNoStaleFlag() async throws {
        try await withConnectionFixture { f in
            let (_, x, _, b) = responseBreakpointExchange(f)
            let id = try #require(x.flowID)
            let upstream = try f.connect(0)
            try upstream.writeInbound(ByteBuffer(string: "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"))
            let t = try #require(b.snapshot().first)
            #expect(f.store.flow(id)?.isPausedAtBreakpoint == true)
            #expect(try breakpointPerform(b, .cancel(token: t.token), f) == .accepted)
            f.loop.run()
            #expect(f.store.flow(id)?.isPausedAtBreakpoint == false)
            #expect(f.store.flow(id)?.state != .inProgress)
        }
    }

    @Test func requestBreakpointCancelFailsTheFlowWithoutAStaleFlag() async throws {
        try await withConnectionFixture { f in
            let (_, x, _, b) = breakpointExchange(f)
            x.receiveRequest(.end(nil))
            let id = try #require(x.flowID)
            let t = try #require(b.snapshot().first)
            #expect(try breakpointPerform(b, .cancel(token: t.token), f) == .accepted)
            f.loop.run()
            #expect(f.store.flow(id)?.isPausedAtBreakpoint == false)
            #expect(f.store.flow(id)?.state != .inProgress)
        }
    }
}
