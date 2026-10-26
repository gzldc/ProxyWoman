import FlowStore
import Foundation
import NIOCore
import NIOConcurrencyHelpers
import NIOHTTP1
import NIOPosix
import Testing
@testable import ProxyCore
@testable import RulesEngine

@Suite(.productionChinese) struct BreakpointLifecycleTests {
    @Test func timeoutGives504AndReleasesEverything() async throws {
        try await withConnectionFixture { f in
            let (c, x, w, b) = breakpointExchange(f)
            x.receiveRequest(.end(nil))
            #expect(x.snapshot.breakpointTimers == 1)
            breakpointAdvance(f, b, by: .seconds(120))
            #expect(w.heads.map(\.status.code) == [504])
            #expect(x.localFailure == .breakpointTimeout)
            #expect(b.snapshot().isEmpty)
            #expect(x.snapshot.breakpointTimers == 0)
            #expect(c.snapshot.pendingBytes == 0)
            #expect(c.snapshot.exchanges.isEmpty)
            #expect(f.connections.isEmpty)
        }
    }

    @Test func capacity65thTicketOr9thPerContextGets503() async throws {
        #expect(RulesLimits().ticketCount == 64)
        #expect(RulesLimits().ticketsPerContext == 8)
        try await withConnectionFixture { f in
            var limits = RulesLimits(); limits.ticketCount = 2; limits.ticketsPerContext = 1
            let b = BreakpointCoordinator(clock: EmbeddedBreakpointClock(now: f.loop.now), limits: limits)
            let (c, x, _, _) = breakpointExchange(f, coordinator: b)
            let (_, rejected, w, _) = breakpointExchange(f, coordinator: b, context: c)
            rejected.receiveRequest(.end(nil))
            #expect(w.heads.map(\.status.code) == [503])
            #expect(rejected.localFailure == .breakpointCapacity)
            let (_, second, _, _) = breakpointExchange(f, coordinator: b)
            let (_, third, thirdWriter, _) = breakpointExchange(f, coordinator: b)
            third.receiveRequest(.end(nil))
            #expect(thirdWriter.heads.map(\.status.code) == [503])
            #expect(b.snapshot().count == 2)
            #expect(f.connections.isEmpty)
            x.cancel(reason: "cleanup"); second.cancel(reason: "cleanup")
            #expect(b.snapshot().isEmpty)
        }
    }

    @Test func staleOrDuplicateTokenCannotContinueTwice() async throws {
        try await withConnectionFixture { f in
            let (_, x, _, b) = breakpointExchange(f)
            let t = try #require(b.snapshot().first)
            let stale = BreakpointCommandToken(ticketID: t.token.ticketID, generation: t.token.generation + 1, revision: t.token.revision)
            #expect(try breakpointPerform(b, .continue(token: stale, edit: .init(head: t.effectiveHead)), f) == .invalid)
            let command = BreakpointCommand.continue(token: t.token, edit: .init(head: t.effectiveHead))
            #expect(try breakpointPerform(b, command, f) == .accepted)
            #expect(try breakpointPerform(b, command, f) != .accepted)
            #expect(f.connections.count == 1)
            _ = try f.connect(0)
            x.cancel(reason: "cleanup")
        }
    }

    @Test func continueVsTimeoutVsClientClose() async throws {
        for order in 0..<6 {
            try await withConnectionFixture { f in
                let (c, x, w, b) = breakpointExchange(f)
                x.receiveRequest(.end(nil))
                let t = try #require(b.snapshot().first)
                let result = NIOLockedValueBox<BreakpointCommandResult?>(nil)
                // Enqueue the command without running its owner-loop callback: a real dispatch barrier.
                if order < 4 {
                    b.perform(.continue(token: t.token, edit: .init(head: t.effectiveHead))) { r in result.withLockedValue { $0 = r } }
                }
                switch order {
                case 0: f.loop.run(); breakpointAdvance(f, b, by: .seconds(120))
                case 1: breakpointAdvance(f, b, by: .seconds(120))
                case 2: f.loop.run(); c.close(error: nil)
                case 3: c.close(error: nil); f.loop.run()
                case 4: breakpointAdvance(f, b, by: .seconds(120)); c.close(error: nil)
                default: c.close(error: nil); breakpointAdvance(f, b, by: .seconds(120))
                }
                if !f.connections.isEmpty { _ = try f.connect(0) }
                x.cancel(reason: "cleanup")
                f.loop.run()
                #expect(b.snapshot().isEmpty)
                #expect(x.snapshot.breakpointTimers == 0)
                #expect(c.snapshot.pendingBytes == 0)
                #expect(c.snapshot.exchanges.isEmpty)
                #expect(w.heads.count <= 1)
                #expect(w.aborts + w.finishes == 1)
                if order < 4 { #expect(result.withLockedValue { $0 } != nil) }
            }
        }
    }

    @Test func cancelGives502WithoutOriginRequest() async throws {
        try await withConnectionFixture { f in
            let (c, x, w, b) = breakpointExchange(f)
            x.receiveRequest(.end(nil))
            let t = try #require(b.snapshot().first)
            #expect(try breakpointPerform(b, .cancel(token: t.token), f) == .accepted)
            #expect(w.heads.map(\.status.code) == [502])
            #expect(x.localFailure == .breakpointCancelled)
            #expect(b.snapshot().isEmpty)
            #expect(x.snapshot.breakpointTimers == 0)
            #expect(c.snapshot.pendingBytes == 0)
            #expect(f.connections.isEmpty)
        }
    }
}

extension BreakpointLifecycleTests {
    @Test func queuedContinueCannotCrossAbsoluteDeadline() async throws {
        try await withConnectionFixture { f in
            let (_, x, w, b) = breakpointExchange(f)
            x.receiveRequest(.end(nil))
            let t = try #require(b.snapshot().first)
            let result = NIOLockedValueBox<BreakpointCommandResult?>(nil)
            b.perform(.continue(token: t.token, edit: .init(head: t.effectiveHead))) { r in result.withLockedValue { $0 = r } }
            breakpointAdvance(f, b, by: .seconds(120))
            #expect(result.withLockedValue { $0 } == .expired)
            #expect(w.heads.map(\.status.code) == [504])
            #expect(b.snapshot().isEmpty)
            #expect(f.connections.isEmpty)
            // Settle every incorrectly created connection even on a failing implementation.
            if !f.connections.isEmpty { _ = try f.connect(0); x.cancel(reason: "cleanup") }
        }
    }

    @Test func recordingOffAdmissionKeepAndShutdownRevokePendingCommands() async throws {
        try await withConnectionFixture { f in
            f.environment.recording.isEnabled.store(false, ordering: .relaxed)
            let (c, x, w, b) = breakpointExchange(f)
            x.receiveRequest(.end(nil))
            let t = try #require(b.snapshot().first)
            #expect(t.flowID == nil)
            #expect(t.contextID == c.contextID)
            #expect(t.source == .passive)
            b.setAdmissionEnabled(false, existing: .keep)
            #expect(b.snapshot().first?.token == t.token)
            let (_, rejected, rw, _) = breakpointExchange(f, coordinator: b)
            rejected.receiveRequest(.end(nil))
            #expect(rw.heads.isEmpty)
            try #require(f.connections.count == 1)
            let forwarded = try f.connect(0)
            #expect(try f.written(forwarded).contains("GET /paused HTTP/1.1"))
            try forwarded.writeInbound(ByteBuffer(string: "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"))
            #expect(rw.heads.map(\.status.code) == [200] && rw.body == "ok")
            let result = NIOLockedValueBox<BreakpointCommandResult?>(nil)
            b.perform(.continue(token: t.token, edit: .init(head: t.effectiveHead))) { r in result.withLockedValue { $0 = r } }
            b.shutdown()
            f.loop.run()
            #expect(result.withLockedValue { $0 } == .invalid)
            #expect(w.heads.map(\.status.code) == [502])
            #expect(b.snapshot().isEmpty)
            #expect(f.connections.count == 1)
            #expect(f.store.allFlows().isEmpty)
            breakpointAdvance(f, b, by: .seconds(120))
            #expect(w.heads.count == 1)
        }
    }

    @Test func invalidEditDoesNotRenewDeadlineAndLateCollectIsExpired() async throws {
        try await withConnectionFixture { f in
            let (_, x, w, b) = breakpointExchange(f)
            x.receiveRequest(.end(nil))
            let t = try #require(b.snapshot().first)
            breakpointAdvance(f, b, by: .seconds(119))
            guard case .request(let target, let fields) = t.effectiveHead else { return }
            #expect(try breakpointPerform(b, .continue(token: t.token, edit: .init(head: .request(target,
                headers: fields + [.init(name: "bad name", value: "x")]))), f) == .invalid)
            #expect(x.snapshot.breakpointTimers == 1)
            #expect(b.snapshot().first?.deadline == t.deadline)
            // Advance the absolute clock before dispatching the expired command; timer is still queued.
            (b.clock as? EmbeddedBreakpointClock)?.advance(by: .seconds(1))
            #expect(try breakpointPerform(b, .collectBody(token: t.token), f) == .expired)
            f.loop.advanceTime(by: .seconds(1))
            #expect(w.heads.map(\.status.code) == [504])
            #expect(b.snapshot().isEmpty)
        }
    }
}

extension BreakpointLifecycleTests {
    @Test func revokeAndAdmissionCancelRejectQueuedCommandsAndReleaseOneOutcome() async throws {
        for revoke in [false, true] {
            try await withConnectionFixture { f in
                let (c, x, w, b) = breakpointExchange(f)
                x.receiveRequest(.end(nil))
                let t = try #require(b.snapshot().first)
                let flowID = try #require(t.flowID)
                let result = NIOLockedValueBox<BreakpointCommandResult?>(nil)
                b.perform(.continue(token: t.token, edit: .init(head: t.effectiveHead))) { r in result.withLockedValue { $0 = r } }
                if revoke { b.revoke(flowIDs: [flowID], reason: .cancelled) }
                else { b.setAdmissionEnabled(false, existing: .cancel) }
                #expect(b.snapshot().isEmpty)
                #expect(result.withLockedValue { $0 } == .invalid)
                f.loop.run()
                #expect(w.heads.map(\.status.code) == [502])
                #expect(x.snapshot.breakpointTimers == 0)
                #expect(c.snapshot.pendingBytes == 0)
                #expect(c.snapshot.exchanges.isEmpty)
                #expect(f.connections.isEmpty)
                breakpointAdvance(f, b, by: .seconds(120))
                #expect(w.finishes == 1)
                #expect(w.heads.count == 1)
            }
        }
    }
}

extension BreakpointLifecycleTests {
    @Test func clearRevokesPausedTicketsForClearedFlows() async throws {
        try await withConnectionFixture { f in
            let (c, x, w, b) = breakpointExchange(f)
            x.receiveRequest(.end(nil))
            let (other, y, v, _) = breakpointExchange(f, coordinator: b)
            y.receiveRequest(.end(nil))
            #expect(b.snapshot().count == 2)
            let ticket = try #require(b.snapshot().first)
            let result = NIOLockedValueBox<BreakpointCommandResult?>(nil)
            b.perform(.continue(token: ticket.token, edit: .init(head: ticket.effectiveHead))) { r in result.withLockedValue { $0 = r } }
            f.store.clear()
            #expect(b.snapshot().isEmpty) // before owner-loop cleanup
            #expect(result.withLockedValue { $0 } == .invalid)
            f.loop.run()
            #expect(w.heads.map(\.status.code) == [502])
            #expect(v.heads.map(\.status.code) == [502])
            #expect(w.ends == 1 && v.ends == 1)
            #expect(c.snapshot.pendingBytes == 0 && other.snapshot.pendingBytes == 0)
            #expect(x.snapshot.breakpointTimers == 0 && y.snapshot.breakpointTimers == 0)
            breakpointAdvance(f, b, by: .seconds(120))
            #expect(w.heads.count == 1 && v.heads.count == 1)
            // Settle a wrongly continued acquisition on the preimplementation RED path.
            for i in f.channels.count..<f.connections.count { _ = try f.connect(i) }
        }
    }

    @Test func alreadyClearedFlowCannotPublishLaterResponseTicket() async throws {
        try await withConnectionFixture { f in
            let (_, x, w, b) = responseBreakpointExchange(f)
            let upstream = try f.connect(0)
            f.store.clear()
            try upstream.writeInbound(ByteBuffer(string: "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"))
            #expect(b.snapshot().isEmpty)
            f.loop.run()
            #expect(w.heads.map(\.status.code) == [502])
            #expect(x.localFailure == .breakpointCancelled)
            #expect(x.snapshot.breakpointTimers == 0)
        }
    }

    @Test func recordingPausedTicketHasNilFlowAndStillWorks() async throws {
        try await withConnectionFixture { f in
            f.environment.recording.isEnabled.store(false, ordering: .relaxed)
            let (_, x, w, b) = responseBreakpointExchange(f)
            defer { x.cancel(reason: "cleanup") }
            let upstream = try f.connect(0)
            try upstream.writeInbound(ByteBuffer(string: "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"))
            let t = try #require(b.snapshot().first)
            #expect(t.flowID == nil)
            f.store.clear()
            #expect(b.snapshot().count == 1)
            #expect(try breakpointPerform(b, .continue(token: t.token, edit: .init(head: t.effectiveHead)), f) == .accepted)
            #expect(w.body == "ok" && w.finishes == 1)
        }
    }

    @Test func admissionDisableKeepVsCancel() async throws {
        try await withConnectionFixture { f in
            let (_, x, w, b) = responseBreakpointExchange(f)
            defer { x.cancel(reason: "cleanup") }
            let upstream = try f.connect(0)
            try upstream.writeInbound(ByteBuffer(string: "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"))
            let t = try #require(b.snapshot().first)
            b.setAdmissionEnabled(false, existing: .keep)
            #expect(b.snapshot().first?.token == t.token)
            let (_, y, v, _) = responseBreakpointExchange(f, coordinator: b)
            defer { y.cancel(reason: "cleanup") }
            let second = try f.connect(1)
            try second.writeInbound(ByteBuffer(string: "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nhi"))
            #expect(v.heads.map(\.status.code) == [200] && v.body == "hi")
            #expect(b.snapshot().count == 1)
            b.setAdmissionEnabled(false, existing: .cancel)
            #expect(b.snapshot().isEmpty)
            f.loop.run()
            #expect(w.heads.map(\.status.code) == [502])
            #expect(w.ends == 1 && w.finishes == 1)
        }
    }

    @Test func responseTimeoutAndCancelReleaseQueuedBytesExactlyOnce() async throws {
        for timeout in [false, true] {
            try await withConnectionFixture { f in
                let (c, x, w, b) = responseBreakpointExchange(f)
                let upstream = try f.connect(0)
                try upstream.writeInbound(ByteBuffer(string: "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello"))
                let t = try #require(b.snapshot().first)
                if timeout { breakpointAdvance(f, b, by: .seconds(120)) }
                else { #expect(try breakpointPerform(b, .cancel(token: t.token), f) == .accepted) }
                #expect(w.heads.map(\.status.code) == [timeout ? 504 : 502])
                #expect(c.snapshot.pendingBytes == 0 && c.snapshot.exchanges.isEmpty)
                #expect(x.snapshot.breakpointTimers == 0 && b.snapshot().isEmpty)
                breakpointAdvance(f, b, by: .seconds(120))
                #expect(w.finishes == 1 && w.ends == 1)
            }
        }
    }
}

extension BreakpointLifecycleTests {
    @Test func shutdownEndsAllTicketsExactlyOnce() async throws {
        let b = BreakpointCoordinator()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        do {
            try await ProxyFixture.run(processLookup: .init(lookup: { _, _ in nil }),
                rules: TestRules.provider([TestRules.breakpoint(.response)]), breakpoints: b,
                drainDeadline: .init(schedule: { loop, expire in loop.execute(expire); return {} })) { f in
                let client = try await RawClient.connect(port: f.proxyPort)
                do {
                    try await client.send("GET http://127.0.0.1:\(f.origin.port)/hello HTTP/1.1\r\nHost: 127.0.0.1:\(f.origin.port)\r\n\r\n")
                    let t = try await breakpointTicket(b, on: group.next())
                    try await f.server.stop(); try await f.server.stop()
                    try await client.waitUntilClosed()
                    #expect(b.snapshot().isEmpty)
                    #expect(await b.perform(.continue(token: t.token, edit: .init(head: t.effectiveHead))) == .invalid)
                    var rejected = false
                    do { try b.reserve(t) { _ in } } catch { rejected = true }
                    #expect(rejected)
                    b.shutdown()
                    // The user's admission policy survives reopening a server run.
                    b.setAdmissionEnabled(false, existing: .keep)
                    try await f.server.start()
                    let next = try await RawClient.connect(port: try #require(f.server.boundPort))
                    do {
                        try await next.send("GET http://127.0.0.1:\(f.origin.port)/hello HTTP/1.1\r\nHost: 127.0.0.1:\(f.origin.port)\r\nConnection: close\r\n\r\n")
                        try await next.waitUntilClosed()
                        let wire = String(decoding: next.remainingBytes(), as: UTF8.self)
                        #expect(wire.contains("200 OK") && wire.hasSuffix("hello"))
                        #expect(b.snapshot().isEmpty)
                        try await next.close()
                    } catch { try? await next.close(); throw error }
                    try await client.close()
                } catch { b.shutdown(); try? await client.close(); throw error }
            }
            try await group.shutdownGracefully()
        } catch { try? await group.shutdownGracefully(); throw error }
    }
}

extension BreakpointLifecycleTests {
    @Test func clearWinsQueuedResponseContinueAndShutdownReleasesTheSameBudget() async throws {
        for shutdown in [false, true] {
            try await withConnectionFixture { f in
                let (c, x, w, b) = responseBreakpointExchange(f)
                let upstream = try f.connect(0)
                try upstream.writeInbound(ByteBuffer(string: "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello"))
                let t = try #require(b.snapshot().first)
                let result = NIOLockedValueBox<BreakpointCommandResult?>(nil)
                b.perform(.continue(token: t.token, edit: .init(head: t.effectiveHead))) { value in result.withLockedValue { $0 = value } }
                if shutdown { b.shutdown(); b.shutdown() } else { f.store.clear() }
                #expect(b.snapshot().isEmpty && result.withLockedValue { $0 } == .invalid)
                f.loop.run()
                #expect(w.heads.map(\.status.code) == [502])
                #expect(!w.body.contains("hello"))
                #expect(x.snapshot.breakpointTimers == 0 && c.snapshot.pendingBytes == 0)
                breakpointAdvance(f, b, by: .seconds(120))
                #expect(w.ends == 1 && w.finishes == 1)
            }
        }
    }
}
