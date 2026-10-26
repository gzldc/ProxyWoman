import CertKit
import FlowStore
import Foundation
import NIOCore
import NIOSSL
import Testing
@testable import ProxyCore
@testable import RulesEngine

/// A real `ProxyServer` (listener, client connections, Compose service, breakpoint coordinator,
/// managed assets) on a random loopback port with a known interception CA, so HTTP/1 forward
/// clients, MITM HTTP/2 clients and Compose sends can share one run. Everything lives in one
/// temporary directory that is removed afterwards; only `trusted` origin roots are trusted
/// upstream, and the system keychain is never consulted.
struct RulesComposeServer {
    let server: ProxyServer
    let store: FlowStore
    let ca: CertificateAuthority
    let assets: ManagedAssetStore
    let budgets: OwnedFileBudgets
    let lifetimes: ComposeLifetimeProbe
    let breakpoints: BreakpointCoordinator?
    let directory: URL
    var spool: URL { directory.appendingPathComponent("spool") }
    var compose: ComposeService { server.compose }
    var port: Int { get throws { try #require(server.boundPort) } }

    static func run(rules: RuleSnapshotProvider? = nil, breakpoints: BreakpointCoordinator? = nil,
                    traffic: TrafficPolicyProvider? = nil,
                    trusted: [CertificateAuthority] = [], composeLimits: ComposeService.Limits = .init(),
                    drainImmediately: Bool = false, configure: (inout ProxyConfiguration) -> Void = { _ in },
                    _ body: (RulesComposeServer) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rules-compose-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var configuration = ProxyConfiguration()
        configuration.port = 0
        configuration.portFallbackCount = 0
        if !trusted.isEmpty {
            configuration.upstreamTrustRoots = .certificates(try trusted.map { try NIOSSLCertificate(bytes: $0.rootCertificateDER, format: .der) })
        }
        configure(&configuration)
        let limits = breakpoints?.limits ?? RulesLimits()
        let budgets = OwnedFileBudgets(limits: limits)
        let assets = ManagedAssetStore(directory: directory.appendingPathComponent("assets"), limits: limits, budgets: budgets)
        let ca = try CertificateAuthority.generate(commonName: "Rules/Compose fixture CA")
        let store = FlowStore(bodyDirectory: directory.appendingPathComponent("capture"))
        let lifetimes = ComposeLifetimeProbe()
        let deadline: ProxyDrainDeadline = drainImmediately ? .init(schedule: { loop, expire in loop.execute(expire); return {} }) : .standard
        let server = ProxyServer(configuration: configuration, certificateAuthority: ca, store: store, passthrough: PassthroughRegistry(),
                                 processLookup: .none, drainDeadline: deadline, rules: rules, assets: assets, breakpoints: breakpoints,
                                 breakpointSpoolDirectory: directory.appendingPathComponent("spool"), composeLimits: composeLimits,
                                 composeLifetimes: lifetimes, traffic: traffic)
        let fixture = RulesComposeServer(server: server, store: store, ca: ca, assets: assets, budgets: budgets, lifetimes: lifetimes,
                                         breakpoints: breakpoints, directory: directory)
        do {
            try await server.start()
            try await body(fixture)
        } catch {
            breakpoints?.shutdown()
            try? await server.stop()
            throw error
        }
        try await server.stop()
    }

    func importAsset(_ bytes: Data) async throws -> ManagedAsset {
        let source = directory.appendingPathComponent(UUID().uuidString)
        try bytes.write(to: source)
        return try await assets.importFile(source, displayName: "rules-compose")
    }

    /// An HTTP/2-capable MITM client of this server for `origin` (CONNECT, then TLS with this
    /// server's CA).
    func h2Client(_ origin: HTTP2TestOrigin, h2: Bool = true) async throws -> HTTP2TestClient {
        try await HTTP2TestClient.connect(origin: origin,
            tls: TLSInterception(certificateAuthority: ca, applicationProtocols: h2 ? ["h2", "http/1.1"] : ["http/1.1"]),
            roots: .certificates([try NIOSSLCertificate(bytes: ca.rootCertificateDER, format: .der)]), proxyPort: try port)
    }

    /// Every Compose send ended and returned its slot, queue entry, file lease, pending bytes and
    /// upstream sockets; no ticket is held and no transient file budget is charged.
    ///
    /// Those resources are released asynchronously, a moment after the client already read the
    /// response, so this first waits (bounded by `timeout`) for the idle state. If it is still not
    /// idle at the deadline, the expectations below fail and report what is still held.
    func expectComposeIdle(timeout: Duration = .seconds(5), sourceLocation: SourceLocation = #_sourceLocation) async {
        try? await waitUntil(timeout: timeout, "Compose to become idle") { isComposeIdle }
        #expect(compose.resources == ComposeResources(), sourceLocation: sourceLocation)
        #expect(breakpoints?.snapshot().isEmpty ?? true, sourceLocation: sourceLocation)
        let bytes = budgets.snapshot().bytes
        #expect([OwnedFileBudgetCategory.io, .breakpoint, .editor, .compose].allSatisfy { bytes[$0, default: 0] == 0 },
                "\(bytes)", sourceLocation: sourceLocation)
    }

    private var isComposeIdle: Bool {
        compose.resources == ComposeResources()
            && (breakpoints?.snapshot().isEmpty ?? true)
            && [OwnedFileBudgetCategory.io, .breakpoint, .editor, .compose].allSatisfy { budgets.snapshot().bytes[$0, default: 0] == 0 }
    }

    /// The send's virtual client and exchange were created and are deallocated (weak references).
    func expectReleased(_ id: UUID, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let created = lifetimes.alive(id)
        #expect(created.tracked && created.exchangeCreated, sourceLocation: sourceLocation)
        try await waitUntil("context and exchange of send \(id) deallocated") {
            let alive = lifetimes.alive(id)
            return !alive.context && !alive.exchange
        }
    }
}
