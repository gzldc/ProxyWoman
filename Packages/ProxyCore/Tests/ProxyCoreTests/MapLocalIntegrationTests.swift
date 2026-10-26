import Atomics
import CertKit
import Darwin
import FlowStore
import Foundation
import NIOCore
import NIOHTTP1
import NIOHTTP2
import NIOPosix
import NIOHPACK
import Testing
import os
@testable import ProxyCore
@testable import RulesEngine

/// Every reply goes through the real proxy writer, asset lease and rules session.
@Suite(.productionChinese, .serialized, .timeLimit(.minutes(3))) struct MapLocalIntegrationTests {
    @Test func mapLocalServesExactBinaryWithoutUpstream() async throws {
        let bytes = Data((0..<300_000).map { _ in UInt8.random(in: 0...255) })
        try await withLocalAsset(bytes, chunkBytes: 4093) { asset in
            try await ProxyFixture.run(rules: asset.rules(), assets: asset.store) { fx in
                let reply = try await localRaw(fx)
                try #require(reply.head.hasPrefix("HTTP/1.1 200 OK"))
                #expect(reply.body.elementsEqual(bytes))
                #expect(fx.origin.acceptedConnections == 0)
                let flow = try await waitForFlow(fx.store) { $0.state == .completed }
                #expect(flow.messages[.upstreamRequest] == nil)
                #expect(flow.messages[.upstreamResponse] == nil)
                let generatedMatches = try flow.messages[.generatedResponse]?.body?.load().elementsEqual(bytes)
                let deliveredMatches = try flow.messages[.downstreamResponse]?.body?.load().elementsEqual(bytes)
                #expect(generatedMatches == true)
                #expect(deliveredMatches == true)
                #expect(flow.messages[.generatedResponse]?.body?.ref == flow.messages[.downstreamResponse]?.body?.ref)
                #expect(flow.provenance.generatedResponse?.assetID == asset.asset.id)
                #expect(flow.provenance.generatedResponse?.size == UInt64(bytes.count))
            }
        }
    }

    @Test func replacingSourceFileAfterImportDoesNotChangeReply() async throws {
        try await withLocalAsset(Data("original\u{0}binary".utf8)) { asset in
            try Data("replacement".utf8).write(to: asset.source)
            try await ProxyFixture.run(rules: asset.rules(), assets: asset.store) { fx in
                let reply = try await localRaw(fx)
                #expect(reply.body == Data("original\u{0}binary".utf8))
                #expect(fx.origin.acceptedConnections == 0)
            }
        }
    }

    @Test func headAnd204And304HaveNoBodyButLegalFraming() async throws {
        try await withLocalAsset(Data("representation".utf8)) { asset in
            for (method, status, length) in [("HEAD", 200, true), ("GET", 204, false), ("GET", 304, true)] {
                let reads = OSAllocatedUnfairLock(initialState: 0)
                let hooks = LocalResponseSource.Hooks(beforeRead: { _, _ in reads.withLock { $0 += 1 } })
                try await ProxyFixture.run(rules: asset.rules(status: status), assets: asset.store, localResponseHooks: hooks) { fx in
                    let reply = try await localRaw(fx, method: method)
                    #expect(reply.head.hasPrefix("HTTP/1.1 \(status)"))
                    #expect(reply.head.lowercased().contains("content-length: 14") == length)
                    #expect(!reply.head.lowercased().contains("transfer-encoding"))
                    #expect(reply.body.isEmpty)
                    #expect(reads.withLock { $0 } == 0)
                }
            }
        }
    }

    @Test func rangeAndIfHeadersDoNotProduce206Or304() async throws {
        try await withLocalAsset(Data("whole representation".utf8)) { asset in
            try await ProxyFixture.run(rules: asset.rules(), assets: asset.store) { fx in
                let reply = try await localRaw(fx, fields: "Range: bytes=1-3\r\nIf-None-Match: *\r\nIf-Modified-Since: Wed, 21 Oct 2015 07:28:00 GMT\r\n")
                try #require(reply.head.hasPrefix("HTTP/1.1 200 OK"))
                #expect(reply.body == Data("whole representation".utf8))
            }
        }
    }

    @Test func responseHeaderRulesApplyToLocalResponse() async throws {
        try await withLocalAsset(Data("rules".utf8)) { asset in
            let edit = TestRules.headers(.response, [.set(name: "X-Local-Edited", value: "yes")])
            // R1 intentional change class 1: a rule must rank above the Return File rule to act on its exchange.
            let provider = asset.rules(higher: [edit])
            try await ProxyFixture.run(rules: provider, assets: asset.store) { fx in
                let reply = try await localRaw(fx)
                #expect(reply.head.contains("X-Local-Edited: yes"))
                let flow = try await waitForFlow(fx.store) { $0.state == .completed }
                #expect(flow.messages[.generatedResponse]?.headers.contains { $0.name.lowercased() == "x-local-edited" } == false)
                #expect(flow.messages[.downstreamResponse]?.headers.contains { $0.name.lowercased() == "x-local-edited" && $0.value == "yes" } == true)
                #expect(flow.provenance.ruleMatches?.total == 2)
                #expect(flow.provenance.ruleMatches?.revision == 1)
            }
        }
    }

    @Test func http10AndH2ClientsGetValidTerminators() async throws {
        let text = String(repeating: "local", count: 20_000)
        try await withLocalAsset(Data(text.utf8)) { asset in
            try await ProxyFixture.run(rules: asset.rules(), assets: asset.store) { fx in
                let reply = try await localRaw(fx, version: "1.0")
                #expect(reply.head.hasPrefix("HTTP/1.0 200 OK"))
                #expect(reply.body.elementsEqual(Data(text.utf8)))
            }
            try await HTTP2TestOrigin.withOrigin(protocols: ["h2"]) { origin in
                try await HTTP2ProxyFixture.withProxy(origin: origin, downstreamH2: true, rules: asset.rules(), assets: asset.store) { fx, client in
                    let reply = try await client.rawRequest(headers: localH2Headers(origin))
                    #expect(reply.status == 200)
                    #expect(reply.body.elementsEqual(text)) // rawRequest resolves only at END_STREAM
                    #expect(origin.counts.connections == 0)
                    try await waitForCompletedFlows(fx.store, atLeast: 1)
                }
            }
        }
    }

    @Test func missingOrUnreadableAssetGivesSingle502NoFallback() async throws {
        for damage in ["missing", "unreadable", "truncated"] {
            try await withLocalAsset(Data("asset".utf8)) { asset in
                switch damage {
                case "missing": try FileManager.default.removeItem(at: asset.copy)
                case "unreadable": #expect(chmod(asset.copy.path, 0) == 0)
                default: try Data().write(to: asset.copy)
                }
                try await ProxyFixture.run(rules: asset.rules(), assets: asset.store) { fx in
                    let reply = try await localRaw(fx)
                    #expect(reply.head.hasPrefix("HTTP/1.1 502 Bad Gateway"))
                    #expect(reply.head.components(separatedBy: "HTTP/1.1 ").count == 2)
                    #expect(String(decoding: reply.body, as: UTF8.self).contains("本地资源"))
                    // Every byte on the wire, not only the parsed head: no second status line may hide
                    // in the body, and the body is exactly as long as the head says.
                    #expect(reply.body.range(of: Data("HTTP/1.".utf8)) == nil, "second head in body (\(damage))")
                    let declared = reply.head.split(separator: "\r\n")
                        .first { $0.lowercased().hasPrefix("content-length:") }
                        .flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) }
                    #expect(declared == reply.body.count, "framing (\(damage))")
                    #expect(fx.origin.acceptedConnections == 0)
                    _ = try await waitForFlow(fx.store) { if case .failed = $0.state { true } else { false } }
                }
            }
        }
    }

    @Test func midReadErrorResetsH2AndClosesH1WithoutSecondHead() async throws {
        try await withLocalAsset(Data(repeating: 65, count: 150_000)) { asset in
            let hooks = LocalResponseSource.Hooks(beforeRead: { _, offset in
                if offset > 0 { throw OwnedFileError(.ioFailure) }
            })
            try await ProxyFixture.run(rules: asset.rules(), assets: asset.store, localResponseHooks: hooks) { fx in
                let reply = try await localRaw(fx)
                try #require(reply.head.hasPrefix("HTTP/1.1 200 OK"))
                #expect(reply.body.count == 65_536)
                #expect(!String(decoding: reply.body, as: UTF8.self).contains("HTTP/1.1"))
                let flow = try await waitForFlow(fx.store) { if case .failed = $0.state { true } else { false } }
                #expect(flow.messages[.downstreamResponse]?.bodyState == .incomplete)
            }
            try await HTTP2TestOrigin.withOrigin(protocols: ["h2"]) { origin in
                try await HTTP2ProxyFixture.withProxy(origin: origin, downstreamH2: true, rules: asset.rules(matcher: RuleMatcher(path: .exact("/local"))), assets: asset.store,
                                                     localResponseHooks: hooks) { fx, client in
                    let probe = try await LocalH2WireProbe.install(on: client.channel)
                    let pending = try await client.startRawRequest(headers: localH2Headers(origin))
                    let streamID = try await pending.channel.getOption(HTTP2StreamChannelOptions.streamID).boundedGet()
                    try await pending.end()
                    do { _ = try await pending.response.boundedGet(); Issue.record("mid-read response completed") }
                    catch {
                        #expect(error is NIOHTTP2Errors.StreamClosed || (error as? HTTPTransportError) == .closed)
                        #expect(!(error is HTTP2FixtureDeadlineExceeded))
                    }
                    try await pending.channel.closeFuture.boundedGet()
                    try await client.channel.eventLoop.submit {
                        #expect(probe.value.heads[streamID] == ["200"])
                        #expect(probe.value.resets.contains(streamID))
                    }.boundedGet()
                    #expect(client.channel.isActive)
                    let flow = try await waitForFlow(fx.store) { if case .failed = $0.state { true } else { false } }
                    #expect(flow.messages[.downstreamResponse]?.status == 200)
                    #expect(flow.messages[.generatedResponse]?.bodyState == .incomplete)
                    #expect(origin.counts.connections == 0)
                    #expect(try await client.rawRequest(headers: localH2Headers(origin, path: "/sibling")).body == "fixture-body")
                }
            }
        }
    }

    @Test func deletingRuleWhileStreamingCompletesTransferThenReclaims() async throws {
        try await withHTTP2ControlLoop { loop in
            let blocked = loop.makePromise(of: Void.self), release = loop.makePromise(of: Void.self)
            defer { blocked.fail(HTTPTransportError.cancelled); release.succeed(()) }
            let text = String(repeating: "d", count: 150_000)
            try await withLocalAsset(Data(text.utf8)) { asset in
                let token = try await asset.store.prepareReferences([asset.asset.id])
                await asset.store.commitReferences(token)
                let rules = asset.rules()
                let hooks = LocalResponseSource.Hooks(beforeRead: { _, offset in
                    if offset == 65_536 { blocked.succeed(()); try await release.futureResult.boundedGet() }
                })
                try await HTTP2TestOrigin.withOrigin(protocols: ["h2"]) { origin in
                    try await HTTP2ProxyFixture.withProxy(origin: origin, downstreamH2: true, rules: rules, assets: asset.store,
                                                         localResponseHooks: hooks) { fx, client in
                        let pending = try await client.startRawRequest(headers: localH2Headers(origin))
                        try await pending.end()
                        try await blocked.futureResult.boundedGet()
                        TestRules.publish([], revision: 2, to: rules)
                        let empty = try await asset.store.prepareReferences([])
                        await asset.store.commitReferences(empty)
                        #expect(FileManager.default.fileExists(atPath: asset.copy.path))
                        release.succeed(())
                        #expect(try await pending.response.boundedGet().body.elementsEqual(text))
                        let flow = try await waitForFlow(fx.store) { $0.state == .completed }
                        #expect(flow.provenance.ruleMatches?.revision == 1)
                        try await waitUntil("leased asset reclaimed") { asset.budgets.snapshot().reservedBytes == 0 }
                        #expect(!FileManager.default.fileExists(atPath: asset.copy.path))
                        #expect(try Data(contentsOf: asset.source) == Data(text.utf8))
                    }
                }
            }
        }
    }

    @Test func slowReceiverBoundsInflightAndSiblingCompletes() async throws {
        let text = String(repeating: "s", count: 500_000)
        try await withLocalAsset(Data(text.utf8)) { asset in
            let reads = OSAllocatedUnfairLock(initialState: (active: 0, peak: 0, chunks: 0, maxChunk: 0))
            let hooks = LocalResponseSource.Hooks(beforeRead: { _, _ in
                reads.withLock { $0.active += 1; $0.peak = max($0.peak, $0.active) }
            }, afterRead: { _, count in
                reads.withLock { $0.active -= 1; $0.chunks += 1; $0.maxChunk = max($0.maxChunk, count) }
            })
            try await HTTP2TestOrigin.withOrigin(protocols: ["h2"]) { origin in
                try await HTTP2ProxyFixture.withProxy(origin: origin, downstreamH2: true, rules: asset.rules(matcher: RuleMatcher(path: .exact("/local"))),
                                                     assets: asset.store, localResponseHooks: hooks) { fx, client in
                    #expect(try await client.rawRequest(headers: localH2Headers(origin, path: "/prime")).status == 200)
                    let connection = try #require(fx.connections.withLock { $0.first })
                    let parent = try await fx.channel.eventLoop.submit { connection.value.channel }.boundedGet()
                    let gate = try await HTTP2FrameWriteGate.install(on: parent, path: "/local")
                    do {
                        let pending = try await client.startRawRequest(headers: localH2Headers(origin))
                        try await pending.end()
                        let held = try await parent.eventLoop.submit { gate.value.held.futureResult }.boundedGet()
                        try await held.boundedGet()
                        let before = reads.withLock { $0.chunks }
                        #expect(try await client.rawRequest(headers: localH2Headers(origin, path: "/sibling")).body == "fixture-body")
                        #expect(reads.withLock { $0.chunks } == before)
                        #expect(reads.withLock { $0.peak } == 1)
                        #expect(reads.withLock { $0.maxChunk } <= 65_536)
                        try await parent.eventLoop.submit { gate.value.release() }.boundedGet()
                        #expect(try await pending.response.boundedGet().body.elementsEqual(text))
                        try await waitForCompletedFlows(fx.store, atLeast: 3)
                    } catch {
                        try? await parent.eventLoop.submit { gate.value.release() }.boundedGet()
                        throw error
                    }
                }
            }
        }
    }

    @Test func uploadToLocalRuleGetsEarlyResponseOnlyThatChildDisposed() async throws {
        try await withHTTP2ControlLoop { loop in
            let prepared = loop.makePromise(of: Void.self), release = loop.makePromise(of: Void.self)
            defer { prepared.fail(HTTPTransportError.cancelled); release.succeed(()) }
            try await withLocalAsset(Data("early".utf8)) { asset in
                let hooks = LocalResponseSource.Hooks(beforePrepare: { _ in
                    prepared.succeed(()); try await release.futureResult.boundedGet()
                })
                try await HTTP2TestOrigin.withOrigin(protocols: ["h2"]) { origin in
                    var limits = HTTPTransportLimits(); limits.drainTimeout = .milliseconds(100)
                    try await HTTP2ProxyFixture.withProxy(origin: origin, downstreamH2: true, limits: limits,
                        rules: asset.rules(matcher: RuleMatcher(path: .exact("/local"))), assets: asset.store, localResponseHooks: hooks) { fx, client in
                        var headers = localH2Headers(origin, method: "POST")
                        headers.add(name: "content-length", value: "1000000")
                        let pending = try await client.startRawRequest(headers: headers)
                        try await prepared.futureResult.boundedGet()
                        try await pending.body("partial upload")
                        _ = try await waitForFlow(fx.store) { $0.messages[.downstreamRequest]?.observedBytes == 14 }
                        release.succeed(())
                        #expect(try await pending.response.boundedGet().body == "early")
                        try await pending.channel.closeFuture.boundedGet()
                        let flow = try await waitForFlow(fx.store) { $0.path == "/local" && $0.messages[.downstreamRequest]?.bodyState == .incomplete }
                        #expect(flow.messages[.upstreamRequest] == nil)
                        #expect(flow.messages[.downstreamRequest]?.transferState != .finished)
                        #expect(try await client.rawRequest(headers: localH2Headers(origin, path: "/sibling")).body == "fixture-body")
                    }
                }
            }
        }
    }
    @Test func requestEndDuringPrepareAndDelayedWritesNeverCompleteEarly() async throws {
        try await withHTTP2ControlLoop { signalLoop in
            let entered = signalLoop.makePromise(of: Void.self), release = signalLoop.makePromise(of: Void.self)
            defer { entered.fail(HTTPTransportError.cancelled); release.succeed(()) }
            let hooks = LocalResponseSource.Hooks(beforePrepare: { _ in
                entered.succeed(()); try await release.futureResult.boundedGet()
            })
            try await withLocalAsset(Data("controlled".utf8)) { asset in
                try await withLocalControl(asset, holds: [.head, .body, .end], hooks: hooks) { owner, loop, store in
                    try await entered.futureResult.boundedGet()
                    try await loop.submit {
                        owner.value.exchange.receiveRequest(.end(nil))
                        #expect(owner.value.context.registered == 1)
                        #expect(owner.value.writer.parts.isEmpty)
                    }.boundedGet()
                    #expect(store.allFlows().first?.state == .inProgress)
                    release.succeed(())
                    for part in [LocalWritePart.head, .body, .end] {
                        try await waitForLocalPart(owner, loop: loop, part: part)
                        #expect(store.allFlows().first?.state == .inProgress)
                        #expect(store.allFlows().first?.messages[.generatedResponse]?.bodyState == .pending)
                        try await loop.submit {
                            #expect(owner.value.context.registered == 1)
                            owner.value.writer.resolve(succeed: true)
                        }.boundedGet()
                    }
                    let flow = try await waitForFlow(store) { $0.state == .completed }
                    #expect(flow.messages[.generatedResponse]?.bodyState == .complete)
                    #expect(flow.messages[.downstreamResponse]?.bodyState == .complete)
                    #expect(flow.messages[.upstreamRequest] == nil)
                    try await loop.submit { #expect(owner.value.context.registered == 0) }.boundedGet()
                }
            }
        }
    }

    @Test(arguments: [LocalWritePart.head, .body, .end])
    func failedHeadBodyAndEndWritesDoNotReportComplete(part: LocalWritePart) async throws {
        try await withLocalAsset(Data("failed-write".utf8)) { asset in
            try await withLocalControl(asset, holds: [part]) { owner, loop, store in
                try await loop.submit { owner.value.exchange.receiveRequest(.end(nil)) }.boundedGet()
                try await waitForLocalPart(owner, loop: loop, part: part)
                try await loop.submit { owner.value.writer.resolve(succeed: false) }.boundedGet()
                let flow = try await waitForFlow(store) { if case .failed = $0.state { true } else { false } }
                #expect(flow.messages[.generatedResponse]?.bodyState == .incomplete)
                #expect(flow.messages[.downstreamResponse]?.transferState == .partiallySent)
                try await loop.submit {
                    #expect(owner.value.writer.aborts == 1)
                    #expect(owner.value.context.registered == 0)
                }.boundedGet()
            }
        }
    }

    @Test(arguments: [false, true])
    func cancelDuringPrepareOrReadSettlesLeaseAndRejectsConcurrentRead(duringRead: Bool) async throws {
        try await withHTTP2ControlLoop { loop in
            let entered = loop.makePromise(of: Void.self), release = loop.makePromise(of: Void.self)
            defer { entered.fail(HTTPTransportError.cancelled); release.succeed(()) }
            try await withLocalAsset(Data("cancel".utf8)) { asset in
                let barrier: @Sendable () async throws -> Void = {
                    entered.succeed(()); try await release.futureResult.boundedGet()
                }
                let hooks = duringRead ? LocalResponseSource.Hooks(beforeRead: { _, _ in try await barrier() })
                    : LocalResponseSource.Hooks(beforePrepare: { _ in try await barrier() })
                let source = LocalResponseSource(action: MapLocalAction(assetID: asset.asset.id, headers: []), assets: asset.store, hooks: hooks)
                if duringRead { _ = try await source.prepare() }
                let operation = Task {
                    if duringRead { _ = try await source.readNext() }
                    else { _ = try await source.prepare() }
                }
                try await entered.futureResult.boundedGet()
                if duringRead {
                    do { _ = try await source.readNext(); Issue.record("concurrent read accepted") }
                    catch { #expect((error as? OwnedFileError)?.code == .operationInFlight) }
                }
                if duringRead { source.cancel() } else { operation.cancel() }
                release.succeed(())
                do { try await operation.value; Issue.record("cancelled operation succeeded") }
                catch { #expect((error as? OwnedFileError)?.code == .cancelled || error is CancellationError) }
                await asset.store.discardImports([asset.asset.id])
                try await waitUntil("cancelled source lease settled") { asset.budgets.snapshot().reservedBytes == 0 }
            }
        }
    }

    @Test(arguments: [true, false])
    func capacityPressureRetriesThenRecoversOrFailsAtDeadline(recovers: Bool) async throws {
        try await withHTTP2ControlLoop { loop in
            let retried = loop.makePromise(of: Void.self)
            defer { retried.fail(HTTPTransportError.cancelled) }
            let reads = OSAllocatedUnfairLock(initialState: 0)
            try await withLocalAsset(Data("budget".utf8)) { asset in
                let reservation = try asset.budgets.reserve(category: .io, bytes: 4_194_304)
                defer { reservation.release() }
                let hooks = LocalResponseSource.Hooks(beforeRead: { _, _ in
                    let count = reads.withLock { $0 += 1; return $0 }
                    if count == 2 { retried.succeed(()) }
                })
                try await ProxyFixture.run(rules: asset.rules(), assets: asset.store, localResponseHooks: hooks) { fx in
                    let reply = Task { try await localRaw(fx) }
                    try await retried.futureResult.boundedGet()
                    if recovers { reservation.release() }
                    let result = try await reply.value
                    #expect(result.head.hasPrefix("HTTP/1.1 200 OK"))
                    if recovers {
                        #expect(result.body == Data("budget".utf8))
                        _ = try await waitForFlow(fx.store) { $0.state == .completed }
                    } else {
                        #expect(result.body.isEmpty)
                        _ = try await waitForFlow(fx.store) { if case .failed = $0.state { true } else { false } }
                    }
                    #expect(reads.withLock { $0 } >= 2)
                    #expect(fx.origin.acceptedConnections == 0)
                }
            }
        }
    }

    @Test(arguments: ["prepare", "read", "capacity"])
    func cancellingExchangeCannotReviveTheSource(phase: String) async throws {
        try await withHTTP2ControlLoop { signalLoop in
            let entered = signalLoop.makePromise(of: Void.self), release = signalLoop.makePromise(of: Void.self)
            let returned = signalLoop.makePromise(of: Void.self)
            defer { entered.fail(HTTPTransportError.cancelled); release.succeed(()); returned.succeed(()) }
            let reads = OSAllocatedUnfairLock(initialState: 0)
            try await withLocalAsset(Data("cancel exchange".utf8)) { asset in
                let reservation = phase == "capacity" ? try asset.budgets.reserve(category: .io, bytes: 4_194_304) : nil
                defer { reservation?.release() }
                let barrier: @Sendable () async throws -> Void = {
                    entered.succeed(()); try await release.futureResult.boundedGet()
                    #expect(Task.isCancelled)
                    returned.succeed(())
                }
                let hooks = LocalResponseSource.Hooks(beforePrepare: { _ in
                    if phase == "prepare" { try await barrier() }
                }, beforeRead: { _, _ in
                    if phase == "read" { try await barrier() }
                    if phase == "capacity" {
                        let count = reads.withLock { $0 += 1; return $0 }
                        if count == 2 { try await barrier() }
                    }
                })
                try await withLocalControl(asset, holds: [], hooks: hooks) { owner, loop, store in
                    try await entered.futureResult.boundedGet()
                    let before = try await loop.submit {
                        owner.value.exchange.cancel(reason: "test cancelled exchange")
                        #expect(owner.value.context.registered == 0)
                        return owner.value.writer.parts
                    }.boundedGet()
                    release.succeed(())
                    try await returned.futureResult.boundedGet()
                    reservation?.release()
                    await asset.store.discardImports([asset.asset.id])
                    try await waitUntil("cancelled exchange lease released") { asset.budgets.snapshot().reservedBytes == 0 }
                    _ = try await waitForFlow(store) { if case .failed = $0.state { true } else { false } }
                    try await loop.submit {
                        #expect(owner.value.writer.parts == before)
                        #expect(owner.value.writer.aborts == 1)
                    }.boundedGet()
                }
            }
        }
    }

    @Test func responseRulesUseAdmissionRevisionEvenWhenPrepareIsSuspended() async throws {
        try await withHTTP2ControlLoop { loop in
            let entered = loop.makePromise(of: Void.self), release = loop.makePromise(of: Void.self)
            defer { entered.fail(HTTPTransportError.cancelled); release.succeed(()) }
            try await withLocalAsset(Data("revision".utf8)) { asset in
                // R1 intentional change class 1: a rule must rank above the Return File rule to act on its exchange.
                let rules = asset.rules(higher: [TestRules.headers(.response, [.set(name: "X-Revision", value: "old")])])
                let hooks = LocalResponseSource.Hooks(beforePrepare: { _ in entered.succeed(()); try await release.futureResult.boundedGet() })
                try await ProxyFixture.run(rules: rules, assets: asset.store, localResponseHooks: hooks) { fx in
                    let task = Task { try await localRaw(fx) }
                    try await entered.futureResult.boundedGet()
                    TestRules.publish([TestRules.headers(.response, [.set(name: "X-Revision", value: "new")])], revision: 2, to: rules)
                    release.succeed(())
                    let reply = try await task.value
                    #expect(reply.head.contains("X-Revision: old"))
                    #expect(!reply.head.contains("X-Revision: new"))
                    let flow = try await waitForFlow(fx.store) { $0.state == .completed }
                    #expect(flow.provenance.ruleMatches?.revision == 1)
                    #expect(flow.provenance.ruleMatches?.total == 2)
                }
            }
        }
    }

}

@Suite(.productionChinese) struct LocalAsset: Sendable {
    let source: URL
    let copy: URL
    let store: ManagedAssetStore
    let asset: ManagedAsset
    let budgets: OwnedFileBudgets
    /// The Map Local rule below `higher`: a Return File action is final, so only rules ranked above it
    /// still act on its exchange (R1 intentional change class 1).
    func rules(status: Int = 200, higher: [Rule] = [], matcher: RuleMatcher = RuleMatcher()) -> RuleSnapshotProvider {
        TestRules.provider(higher + [Rule(id: UUID(), name: "asset", enabled: true, order: 0, matcher: matcher,
            action: .mapLocal(MapLocalAction(assetID: asset.id, status: status, headers: [HeaderField(name: "Content-Type", value: "application/octet-stream")])))])
    }
}

func withLocalAsset(_ bytes: Data, chunkBytes: Int = 65_536, _ body: (LocalAsset) async throws -> Void) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("map-local-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source.bin"), copies = root.appendingPathComponent("owned")
    try bytes.write(to: source)
    let limits = RulesLimits(ioChunkBytes: chunkBytes, minimumFreeDiskBytes: 0)
    let budgets = OwnedFileBudgets(limits: limits)
    let store = ManagedAssetStore(directory: copies, limits: limits, budgets: budgets)
    let asset = try await store.importFile(source, displayName: "test asset")
    let fixture = LocalAsset(source: source, copy: copies.appendingPathComponent(asset.id.uuidString + ".asset"), store: store, asset: asset, budgets: budgets)
    do { try await body(fixture) }
    catch { await store.discardImports([asset.id]); throw error }
    await store.discardImports([asset.id])
    try await waitUntil("asset and IO reservations released") { budgets.snapshot().reservedBytes == 0 }
}

private func localRaw(_ fixture: ProxyFixture, method: String = "GET", version: String = "1.1", fields: String = "") async throws -> (head: String, body: Data) {
    let client = try await RawClient.connect(port: fixture.proxyPort)
    do {
        try await client.send("\(method) http://127.0.0.1:\(fixture.origin.port)/local HTTP/\(version)\r\nHost: 127.0.0.1:\(fixture.origin.port)\r\n\(fields)Connection: close\r\n\r\n")
        try await client.waitUntilClosed()
        let bytes = Data(client.remainingBytes())
        try await client.close()
        let separator = try #require(bytes.range(of: Data("\r\n\r\n".utf8)))
        return (String(decoding: bytes[..<separator.lowerBound], as: UTF8.self), Data(bytes[separator.upperBound...]))
    } catch { try? await client.close(); throw error }
}

private func localH2Headers(_ origin: HTTP2TestOrigin, method: String = "GET", path: String = "/local") -> HPACKHeaders {
    HPACKHeaders([ (":method", method), (":scheme", "https"), (":authority", "localhost:\(origin.port)"), (":path", path) ])
}

/// Observes actual decoded peer frames before the client multiplexer consumes a reset.
private final class LocalH2WireProbe: ChannelInboundHandler {
    typealias InboundIn = HTTP2Frame
    var heads: [HTTP2StreamID: [String]] = [:]
    var resets: Set<HTTP2StreamID> = []
    static func install(on parent: Channel) async throws -> NIOLoopBound<LocalH2WireProbe> {
        try await parent.eventLoop.submit {
            let probe = LocalH2WireProbe()
            let mux = try parent.pipeline.syncOperations.handler(type: HTTP2StreamMultiplexer.self)
            try parent.pipeline.syncOperations.addHandler(probe, position: .before(mux))
            return NIOLoopBound(probe, eventLoop: parent.eventLoop)
        }.boundedGet()
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        if case .headers(let block) = frame.payload, let status = block.headers.first(name: ":status") {
            heads[frame.streamID, default: []].append(status)
        }
        if case .rstStream = frame.payload { resets.insert(frame.streamID) }
        context.fireChannelRead(data)
    }
}

enum LocalWritePart: String, Sendable, Hashable { case head, body, end }

/// Controlled transport futures, with the real source/rules/recorder and a real owning loop.
private final class LocalControlledWriter: DownstreamResponseWriter {
    let eventLoop: EventLoop
    let version: HTTPWireVersion = .http2
    var isWritable = true
    var isActive = true
    var parts: [LocalWritePart] = []
    var pending: [EventLoopPromise<Void>] = []
    var aborts = 0
    let holds: Set<LocalWritePart>
    init(loop: EventLoop, holds: Set<LocalWritePart>) { eventLoop = loop; self.holds = holds }
    func write(_ part: HTTPServerResponsePart) -> EventLoopFuture<Void> {
        let kind: LocalWritePart
        switch part { case .head: kind = .head; case .body: kind = .body; case .end: kind = .end }
        parts.append(kind)
        if holds.contains(kind) {
            let promise = eventLoop.makePromise(of: Void.self)
            pending.append(promise)
            return promise.futureResult
        }
        return eventLoop.makeSucceededVoidFuture()
    }
    func resolve(succeed: Bool) {
        let promise = pending.removeFirst()
        if succeed { promise.succeed(()) } else { promise.fail(HTTPTransportError.closed) }
    }
    func flush() {}
    func setRequestReading(_ enabled: Bool) {}
    func responseFinished() {}
    func abort(_ error: Error) {
        aborts += 1
        isActive = false
        let writes = pending; pending.removeAll()
        for promise in writes { promise.fail(error) }
    }
}

private final class LocalControlledContext: HTTPOutboundEnvironment {
    let contextID = UUID()
    let environment: ProxyEnvironment
    let limits = HTTPTransportLimits()
    let knownClient: ClientApp? = nil
    let forwardingAllowed = true
    let loop: EventLoop
    var registered = 0
    private(set) lazy var upstreamPool = UpstreamSessionPool(eventLoop: loop, environment: environment, limits: limits,
        connectionFactory: { _, _, loop in
            Issue.record("Map Local unexpectedly connected upstream")
            return loop.makeFailedFuture(HTTPTransportError.closed)
        })
    init(environment: ProxyEnvironment, loop: EventLoop) { self.environment = environment; self.loop = loop }
    func onClient(_ callback: @escaping (ClientApp) -> Void) {}
    func whenForwardingAllowed(_ callback: @escaping () -> Void) { callback() }
    func register(_ exchange: HTTPExchange, streamID: Int?) -> Bool { registered += 1; return true }
    func unregister(_ exchange: HTTPExchange) { registered -= 1 }
    func reservePendingBytes(_ count: Int) -> Bool { true }
    func releasePendingBytes(_ count: Int) {}
}

private struct LocalControl {
    let exchange: HTTPExchange
    let writer: LocalControlledWriter
    let context: LocalControlledContext
}

private func withLocalControl(_ asset: LocalAsset, holds: Set<LocalWritePart>, hooks: LocalResponseSource.Hooks? = nil,
                              _ body: (NIOLoopBound<LocalControl>, EventLoop, FlowStore) async throws -> Void) async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let workers = NIOThreadPool(numberOfThreads: 1)
    workers.start()
    let directory = asset.source.deletingLastPathComponent().appendingPathComponent("capture")
    let store = FlowStore(bodyDirectory: directory)
    let environment = ProxyEnvironment(configuration: .init(), recording: FlowRecording(store: store, isEnabled: ManagedAtomic(true)),
        tls: TLSInterception(certificateAuthority: try CertificateAuthority.generate()), passthrough: PassthroughRegistry(),
        clientLookup: ClientLookupBatcher(processLookup: ProcessLookup(lookup: { _, _ in nil }), threadPool: workers),
        rules: asset.rules(), assets: asset.store, localResponseHooks: hooks)
    let loop = group.next()
    let owner = try await loop.submit {
        let context = LocalControlledContext(environment: environment, loop: loop)
        let writer = LocalControlledWriter(loop: loop, holds: holds)
        let exchange = HTTPExchange(requestHead: .init(version: .http2, method: .GET, uri: "/local"),
            target: RequestTarget(host: "example.test", port: 80, originForm: "/local", defaultPort: 80), scheme: "http",
            downstream: writer, connection: context, transport: .init(downstreamRequest: .http2))
        exchange.execute()
        return NIOLoopBound(LocalControl(exchange: exchange, writer: writer, context: context), eventLoop: loop)
    }.boundedGet()
    do { try await body(owner, loop, store) }
    catch {
        try? await loop.submit { owner.value.exchange.cancel(reason: "test cleanup") }.boundedGet()
        try? await workers.shutdownGracefully(); try? await group.shutdownGracefully()
        throw error
    }
    try await loop.submit { owner.value.exchange.cancel(reason: "test cleanup") }.boundedGet()
    try await workers.shutdownGracefully(); try await group.shutdownGracefully()
}

private func waitForLocalPart(_ owner: NIOLoopBound<LocalControl>, loop: EventLoop, part: LocalWritePart) async throws {
    let observed = OSAllocatedUnfairLock(initialState: false)
    let timer = try await loop.submit {
        loop.scheduleRepeatedTask(initialDelay: .zero, delay: .milliseconds(5)) { task in
            if owner.value.writer.parts.contains(part) { observed.withLock { $0 = true }; task.cancel() }
        }
    }.boundedGet()
    defer { timer.cancel() }
    try await waitUntil("controlled \(part) write") { observed.withLock { $0 } }
}
