import Atomics
import CertKit
import FlowStore
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import Testing
@testable import ProxyCore

/// Deferred T10b fixes: the Compose timeout ignores a stale timer callback (m1), and a cancelled
/// connect attempt fails as cancelled without opening a socket (m2). Loopback only, no sleeps.
@Suite(.serialized, .timeLimit(.minutes(1)), .productionChinese) struct TransportPhaseFixTests {
    /// m1. NIO runs every task due at the same instant in one batch, so a timer already copied
    /// into that batch still runs after an earlier task of the batch cancelled it. Here a
    /// breakpoint pause and the timeout share one deadline and the pause is queued first: the
    /// pause cancels the (already batched) timer, which must then do nothing.
    @Test func timeoutCallbackFromBeforeABreakpointPauseIsIgnored() async throws {
        let silent = try await ComposeSilentServer.start()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let workers = NIOThreadPool(numberOfThreads: 1)
        workers.start()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("timeout-guard-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            let loop = group.next()
            let environment = try Self.environment(store: FlowStore(bodyDirectory: directory), workers: workers)
            let target = RequestTarget(host: "127.0.0.1", port: silent.port, originForm: "/silent", defaultPort: 80)
            let head = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/silent",
                                       headers: HTTPHeaders([("Host", "127.0.0.1:\(silent.port)")]))
            let (context, stillActive) = try await loop.flatSubmit {
                let context = OutboundExecutionContext(contextID: UUID(), eventLoop: loop, environment: environment,
                                                       responseBodyLimit: 1024, body: .none)
                let deadline = NIODeadline.now() + .milliseconds(100)
                let observed = loop.makePromise(of: Bool.self)
                // Same deadline, scheduled before the timeout: runs first in the same batch.
                loop.assumeIsolated().scheduleTask(deadline: deadline) { context.breakpointPauseChanged(true) }
                context.start(head: head, target: target, scheme: "http",
                              policy: HTTPExecutionPolicy(rulesEnabled: false, retry: .never, rejectsListener: true,
                                                          recordsWhilePaused: true, virtualClient: true),
                              provenance: FlowProvenance(source: .compose(sendID: UUID(), sourceFlowID: nil, sourceBoundary: nil),
                                                         rulesDisabled: true),
                              deadline: deadline, timeoutFailure: ComposeFailure(.timeout, argument: "0.1"))
                // Same deadline, scheduled after the timeout: sees what the batch left.
                loop.assumeIsolated().scheduleTask(deadline: deadline) { observed.succeed(context.isActive) }
                let bound = NIOLoopBound(context, eventLoop: loop)
                return observed.futureResult.map { (bound, $0) }
            }.boundedGet()
            #expect(stillActive, "a stale timeout callback ended a send paused at a breakpoint")
            let completion = try await loop.submit {
                context.value.cancel(ComposeFailure(.cancelled))
                return context.value.completion
            }.get().boundedGet()
            #expect(completion.result.failure?.code == (stillActive ? ComposeFailureCode.cancelled : .timeout).rawValue)
            #expect(completion.residualPendingBytes == 0 && completion.residualUpstreamSockets == 0)
            try await workers.shutdownGracefully()
            try await group.shutdownGracefully()
            try await silent.stop()
        } catch {
            try? await workers.shutdownGracefully(); try? await group.shutdownGracefully(); try? await silent.stop()
            throw error
        }
    }

    /// m2. An attempt cancelled before the connect starts, or while the host name is still being
    /// resolved, fails as `cancelled`; the target never sees a connection.
    @Test(arguments: [false, true])
    func cancelledConnectAttemptFailsAsCancelledWithoutConnecting(duringResolution: Bool) async throws {
        let silent = try await ComposeSilentServer.start()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        do {
            let loop = group.next()
            var configuration = ProxyConfiguration()
            configuration.connectTimeout = .seconds(20)
            let connector = UpstreamConnector(configuration: configuration)
            let outcome = try await loop.flatSubmit { () -> EventLoopFuture<Result<Channel, Error>> in
                let attempt = UpstreamConnectAttempt()
                if !duringResolution { attempt.cancel() }
                // A name, not an address: resolution completes on a later loop turn.
                let future = connector.connect(host: duringResolution ? "localhost" : "127.0.0.1", port: silent.port,
                                               on: loop, attempt: attempt)
                if duringResolution { attempt.cancel() }
                return future.map { .success($0) }.recover { .failure($0) }
            }.boundedGet()
            switch outcome {
            case .success(let channel):
                Issue.record("a cancelled attempt connected")
                try? await channel.close().get()
            case .failure(let error):
                #expect(error as? HTTPTransportError == .cancelled, "\(error)")
            }
            // A fresh connection is the first one the server ever accepted.
            let probe = try await ClientBootstrap(group: loop).connect(host: "127.0.0.1", port: silent.port).get()
            try await waitUntil("the probe connection accepted") { silent.state.withLock { $0.connections } >= 1 }
            #expect(silent.state.withLock { $0.connections } == 1)
            try? await probe.close().get()
            try await group.shutdownGracefully()
            try await silent.stop()
        } catch { try? await group.shutdownGracefully(); try? await silent.stop(); throw error }
    }

    private static func environment(store: FlowStore, workers: NIOThreadPool) throws -> ProxyEnvironment {
        var configuration = ProxyConfiguration()
        configuration.connectTimeout = .seconds(20)
        return ProxyEnvironment(configuration: configuration, recording: FlowRecording(store: store, isEnabled: ManagedAtomic(true)),
            tls: TLSInterception(certificateAuthority: try CertificateAuthority.generate(commonName: "timeout guard CA")),
            passthrough: PassthroughRegistry(),
            clientLookup: ClientLookupBatcher(processLookup: .none, threadPool: workers))
    }
}
