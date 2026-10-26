import CertKit
import Darwin
import FlowStore
import Foundation
import Localization
import NIOCore
import NIOHTTP1
import NIOSSL
import NIOTLS
import os
import Security

/// The TLS contexts used to intercept HTTPS: per-host server contexts presenting a leaf issued by
/// our CA (towards the client), and client contexts verifying the origin (towards upstream).
/// Building a context parses keys and certificates, so both kinds are cached.
final class TLSInterception: Sendable {
    static let alpn = ["h2", "http/1.1"]
    static let upgradeALPN = ["http/1.1"]
    let pinningFailures = PinningFailureTracker()

    private struct ServerEntry {
        var context: NIOSSLContext
        var lastUsed: UInt64
    }

    private struct ServerCache {
        var entries: [String: ServerEntry] = [:]
        var tick: UInt64 = 0
    }

    private let certificateAuthority: CertificateAuthority
    private let capacity: Int
    private let applicationProtocols: [String]
    private let serverContexts = OSAllocatedUnfairLock(initialState: ServerCache())
    /// Upstream client contexts for the most recent trust roots, keyed by verification mode and route policy.
    private struct UpstreamContextKey: Hashable {
        let verifyHostname: Bool
        let policy: UpstreamProtocolPolicy
    }
    private struct UpstreamContexts {
        var roots: NIOSSLTrustRoots
        var contexts: [UpstreamContextKey: NIOSSLContext] = [:]
    }

    /// Only the contexts for the most recent trust roots are kept; they change only with the settings.
    private let upstreamContextCache = OSAllocatedUnfairLock<UpstreamContexts?>(initialState: nil)

    init(certificateAuthority: CertificateAuthority, capacity: Int = 1000,
         applicationProtocols: [String] = TLSInterception.alpn) {
        self.certificateAuthority = certificateAuthority
        self.capacity = max(1, capacity)
        self.applicationProtocols = applicationProtocols
    }

    /// The context presenting our leaf for `host` (lowercase, no IPv6 brackets) to the client.
    func serverContext(for host: String) throws -> NIOSSLContext {
        let cached: NIOSSLContext? = serverContexts.withLock { cache in
            guard var entry = cache.entries[host] else { return nil }
            cache.tick += 1
            entry.lastUsed = cache.tick
            cache.entries[host] = entry
            return entry.context
        }
        if let cached { return cached }

        let leaf = try certificateAuthority.leaf(for: host)
        var configuration = TLSConfiguration.makeServerConfiguration(
            certificateChain: [.certificate(try NIOSSLCertificate(bytes: leaf.certificateDER, format: .der))],
            privateKey: .privateKey(try NIOSSLPrivateKey(bytes: leaf.privateKeyDER, format: .der)))
        configuration.applicationProtocols = applicationProtocols
        let context = try NIOSSLContext(configuration: configuration)

        return serverContexts.withLock { cache in
            cache.tick += 1
            if let existing = cache.entries[host] {  // another connection raced us; keep one
                cache.entries[host]?.lastUsed = cache.tick
                return existing.context
            }
            cache.entries[host] = ServerEntry(context: context, lastUsed: cache.tick)
            if cache.entries.count > capacity,
                let oldest = cache.entries.min(by: { $0.value.lastUsed < $1.value.lastUsed })?.key
            {
                cache.entries.removeValue(forKey: oldest)
            }
            return context
        }
    }

    /// The handler that starts TLS towards the origin `host` (lowercase, no IPv6 brackets), verified
    /// against `trustRoots`. `tunneled`: the connection runs through the upstream proxy.
    func upstreamHandler(host: String, trustRoots: NIOSSLTrustRoots, tunneled: Bool,
                         policy: UpstreamProtocolPolicy = .automatic) throws -> NIOSSLClientHandler {
        guard Self.isIPLiteral(host) else {
            return try NIOSSLClientHandler(
                context: upstreamContext(trustRoots: trustRoots, verifyHostname: true, policy: policy), serverHostname: host)
        }
        guard tunneled else {
            // NIOSSL rejects IP literals as SNI; without a server name it verifies the
            // certificate's IP SANs against the connected socket's address, which is the origin's.
            return try NIOSSLClientHandler(
                context: upstreamContext(trustRoots: trustRoots, verifyHostname: true, policy: policy), serverHostname: nil)
        }
        // Through a tunnel the socket address is the upstream proxy's, so NIOSSL's own check would
        // compare against the wrong IP: it is switched off and the callback checks the target IP.
        return try NIOSSLClientHandler(
            context: upstreamContext(trustRoots: trustRoots, verifyHostname: false, policy: policy), serverHostname: nil,
            customVerificationCallbackWithMetadata: Self.verifier(forIP: host, trustRoots: trustRoots))
    }

    /// A client context with policy-specific ALPN, `.fullVerification` or `.noHostnameVerification`.
    private func upstreamContext(trustRoots: NIOSSLTrustRoots, verifyHostname: Bool,
                                 policy: UpstreamProtocolPolicy) throws -> NIOSSLContext {
        let key = UpstreamContextKey(verifyHostname: verifyHostname, policy: policy)
        let cached = upstreamContextCache.withLock { cache -> NIOSSLContext? in
            guard let cache, cache.roots == trustRoots else { return nil }
            return cache.contexts[key]
        }
        if let cached { return cached }

        var configuration = TLSConfiguration.makeClientConfiguration()
        configuration.trustRoots = trustRoots
        configuration.certificateVerification = verifyHostname ? .fullVerification : .noHostnameVerification
        configuration.applicationProtocols = policy == .automatic ? applicationProtocols : Self.upgradeALPN
        let context = try NIOSSLContext(configuration: configuration)
        upstreamContextCache.withLock { cache in
            if cache?.roots != trustRoots { cache = UpstreamContexts(roots: trustRoots) }
            cache?.contexts[key] = context
        }
        return context
    }

    /// Verifies an origin reached by the IP literal `ip`, like NIOSSL does for the system roots
    /// (Security.framework, SSL policy): the chain against `trustRoots`, and `ip` against the
    /// leaf's IP SANs. Evaluation may touch the network, so it runs off the event loop.
    /// A `.file` trust root must be a PEM file; anything unreadable fails verification.
    static func verifier(forIP ip: String, trustRoots: NIOSSLTrustRoots) -> NIOSSLCustomVerificationCallbackWithMetadata {
        { certificates, promise in
            let chain: [[UInt8]]
            let anchors: [[UInt8]]?
            do {
                chain = try certificates.map { try $0.toDERBytes() }
                switch trustRoots {
                case .default:
                    anchors = nil
                case .certificates(let roots):
                    anchors = try roots.map { try $0.toDERBytes() }
                case .file(let path):
                    anchors = try NIOSSLCertificate.fromPEMFile(path).map { try $0.toDERBytes() }
                }
            } catch {
                promise.succeed(.failed)
                return
            }
            DispatchQueue.global(qos: .userInitiated).async {
                let trusted = evaluate(chain: chain, anchors: anchors, ip: ip)
                promise.succeed(trusted ? .certificateVerified(VerificationMetadata(nil)) : .failed)
            }
        }
    }

    private static func evaluate(chain: [[UInt8]], anchors: [[UInt8]]?, ip: String) -> Bool {
        func secCertificates(_ ders: [[UInt8]]) -> [SecCertificate]? {
            let certificates = ders.compactMap { SecCertificateCreateWithData(nil, Data($0) as CFData) }
            return certificates.count == ders.count ? certificates : nil
        }
        guard !chain.isEmpty, let peer = secCertificates(chain) else { return false }
        var trust: SecTrust?
        let policy = SecPolicyCreateSSL(true, ip as CFString)
        guard SecTrustCreateWithCertificates(peer as CFArray, policy, &trust) == errSecSuccess, let trust else {
            return false
        }
        if let anchors {
            guard let roots = secCertificates(anchors),
                  SecTrustSetAnchorCertificates(trust, roots as CFArray) == errSecSuccess,
                  SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess
            else { return false }
        }
        return SecTrustEvaluateWithError(trust, nil)
    }

    static func isIPLiteral(_ host: String) -> Bool {
        var v4 = in_addr()
        var v6 = in6_addr()
        return inet_pton(AF_INET, host, &v4) == 1 || inet_pton(AF_INET6, host, &v6) == 1
    }

    /// Only peer certificate-rejection alerts qualify immediately. NIOSSL exposes BoringSSL's
    /// reason names through descriptions, so match complete allowlisted tokens, not substrings
    /// such as CERTIFICATE (which would also match local verification and generic errors).
    static func pinningEvidence(for error: Error?, hasClientHello: Bool) -> PinningFailureEvidence {
        guard hasClientHello else { return .unrelated }
        guard let error else { return .interrupted }
        switch error {
        case NIOSSLError.uncleanShutdown, ChannelError.eof:
            return .interrupted
        case NIOSSLError.handshakeFailed(.sslError(let stack)):
            if stack == [.eofDuringHandshake] { return .interrupted }
            let reasons = Set(stack.flatMap { item in
                item.description.split { !$0.isLetter && !$0.isNumber && $0 != "_" }.map(String.init)
            })
            guard !reasons.contains("CERTIFICATE_VERIFY_FAILED") else { return .unrelated }
            let peerAlerts: Set<String> = [
                "TLSV1_ALERT_UNKNOWN_CA", "SSLV3_ALERT_BAD_CERTIFICATE",
                "SSLV3_ALERT_CERTIFICATE_UNKNOWN", "SSLV3_ALERT_CERTIFICATE_EXPIRED",
                "SSLV3_ALERT_CERTIFICATE_REVOKED", "SSLV3_ALERT_UNSUPPORTED_CERTIFICATE",
            ]
            return reasons.isDisjoint(with: peerAlerts) ? .unrelated : .certificateRejected
        default:
            return .unrelated
        }
    }

    /// A short, localized reason if `error` means the origin's certificate failed verification.
    static func certificateFailureReason(_ error: Error) -> String? {
        switch error {
        case let error as NIOSSLExtraError where error == .failedToValidateHostname:
            return L10n.string("proxyFailure.certHostMismatch")
        case NIOSSLError.handshakeFailed(.sslError(let stack))
        where stack.contains(where: { "\($0)".contains("CERTIFICATE_VERIFY_FAILED") }):
            return L10n.string("proxyFailure.certUntrusted")
        default:
            return nil
        }
    }
}

/// A TLS handshake did not complete within `ProxyConfiguration.connectTimeout`.
struct TLSHandshakeTimeout: Error {}

/// Sits right behind an `NIOSSLHandler` and reports, once, whether the handshake completed or
/// broke off first (an alert, an error, or the connection closing).
final class TLSHandshakeMonitor: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer

    private var onCompleted: (() -> Void)?
    private var onFailure: ((Error?) -> Void)?

    init(onCompleted: @escaping () -> Void, onFailure: @escaping (Error?) -> Void) {
        self.onCompleted = onCompleted
        self.onFailure = onFailure
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if case TLSUserEvent.handshakeCompleted = event {
            let onCompleted = self.onCompleted
            settle()
            onCompleted?()
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        reportFailure(error)
        context.fireErrorCaught(error)
    }

    func channelInactive(context: ChannelHandlerContext) {
        reportFailure(nil)
        context.fireChannelInactive()
    }

    private func reportFailure(_ error: Error?) {
        let onFailure = self.onFailure
        settle()
        onFailure?(error)
    }

    private func settle() {
        onCompleted = nil
        onFailure = nil
    }
}

/// Observes the initial ClientHello while forwarding every original buffer immediately.
/// The handshake body is capped at 64 KiB, each plaintext record at 16 KiB, and total observed
/// framing at 128 KiB. Exceeding a bound only disables evidence; SSL still receives all bytes.
/// State is confined to the connection's event loop.
final class ClientHelloEvidenceProbe: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer

    private(set) var hasClientHello = false
    private var invalid = false
    private var observed = 0
    private var header: [UInt8] = []
    private var recordRemaining = 0
    private var handshake: [UInt8] = []
    private var handshakeLength: Int?

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        observe(unwrapInboundIn(data))
        context.fireChannelRead(data)
    }

    private func observe(_ buffer: ByteBuffer) {
        guard !invalid, !hasClientHello else { return }
        for byte in buffer.readableBytesView {
            observed += 1
            guard observed <= 128 * 1024 else { discard(); return }
            if recordRemaining == 0 {
                header.append(byte)
                if header.count == 5 {
                    let length = Int(header[3]) << 8 | Int(header[4])
                    guard header[0] == 0x16, header[1] == 0x03,
                          (1...3).contains(header[2]), (1...16384).contains(length)
                    else { discard(); return }
                    recordRemaining = length
                    header.removeAll(keepingCapacity: true)
                }
            } else {
                if handshake.count < (handshakeLength ?? 4) {
                    handshake.append(byte)
                    if handshake.count == 4 {
                        let length = Int(handshake[1]) << 16 | Int(handshake[2]) << 8 | Int(handshake[3])
                        guard handshake[0] == 0x01, (41...65536).contains(length)
                        else { discard(); return }
                        handshakeLength = length + 4
                    }
                }
                recordRemaining -= 1
                // A truncated record cannot prove framing, even if its prefix contains a hello.
                if recordRemaining == 0, handshake.count == handshakeLength {
                    hasClientHello = validClientHello()
                    discard()
                    return
                }
            }
        }
    }

    private func discard() {
        invalid = true
        header.removeAll(keepingCapacity: false)
        handshake.removeAll(keepingCapacity: false)
    }

    /// Check the ClientHello's vectors as well as its outer handshake/record lengths. Unknown
    /// extension contents are left to SSL, but their framing must stay within the hello.
    private func validClientHello() -> Bool {
        guard handshake.count >= 45, handshake[4] == 0x03, (1...3).contains(handshake[5]) else { return false }
        let sessionLength = Int(handshake[38])
        guard sessionLength <= 32 else { return false }
        var index = 39 + sessionLength
        guard index + 2 <= handshake.count else { return false }
        let cipherLength = Int(handshake[index]) << 8 | Int(handshake[index + 1])
        guard cipherLength >= 2, cipherLength.isMultiple(of: 2) else { return false }
        index += 2 + cipherLength
        guard index < handshake.count else { return false }
        let compressionLength = Int(handshake[index])
        guard compressionLength > 0 else { return false }
        index += 1 + compressionLength
        if index == handshake.count { return true } // TLS 1.2 permits no extensions.
        guard index + 2 <= handshake.count else { return false }
        let extensionLength = Int(handshake[index]) << 8 | Int(handshake[index + 1])
        index += 2
        guard index + extensionLength == handshake.count else { return false }
        while index < handshake.count {
            guard index + 4 <= handshake.count else { return false }
            let length = Int(handshake[index + 2]) << 8 | Int(handshake[index + 3])
            index += 4 + length
            guard index <= handshake.count else { return false }
        }
        return true
    }
}

/// First handler after a CONNECT's 200 on an intercepted connection. Buffers what the client
/// sends until its owner decided what to do with it, then hands it to the handlers installed in
/// its place (`handOver`) and leaves the pipeline.
final class ClientHelloSniffer: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer

    /// The first byte of a TLS handshake record (a ClientHello starts with one).
    static let handshakeRecordType: UInt8 = 0x16

    /// Called once with the client's first bytes: whether they start a TLS handshake.
    var onFirstBytes: ((_ isTLSHandshake: Bool) -> Void)?
    /// Called if the connection closes while the sniffer is still in the pipeline.
    var onClose: (() -> Void)?

    private var context: ChannelHandlerContext?
    private var buffered: ByteBuffer?

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
        onFirstBytes = nil
        onClose = nil
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var bytes = unwrapInboundIn(data)
        guard buffered == nil else {
            buffered!.writeBuffer(&bytes)
            return
        }
        guard let first = bytes.readableBytesView.first else { return }
        buffered = bytes
        let onFirstBytes = self.onFirstBytes
        self.onFirstBytes = nil
        onFirstBytes?(first == Self.handshakeRecordType)
    }

    func channelInactive(context: ChannelHandlerContext) {
        let onClose = self.onClose
        self.onClose = nil
        onClose?()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }

    /// Installs `handlers` right after the sniffer, passes them the buffered bytes and removes
    /// the sniffer.
    func handOver(to handlers: [ChannelHandler]) throws {
        guard let context else { throw ChannelError.ioOnClosedChannel }
        let pipeline = context.pipeline.syncOperations
        try pipeline.addHandlers(handlers, position: .after(self))
        if let buffered {
            self.buffered = nil
            context.fireChannelRead(wrapInboundOut(buffered))
            context.fireChannelReadComplete()
        }
        pipeline.removeHandler(context: context, promise: nil)
    }
}

/// A CONNECT that is to be intercepted, from its 200 on. The client's first bytes decide:
/// a TLS handshake record starts interception (`NIOSSLServerHandler` → `TLSHandshakeMonitor` →
/// HTTP codec → `ProxyHandler(mode: .mitm)`); anything else (e.g. ws:// through a proxy, which is
/// CONNECT followed by plain HTTP) is relayed untouched as a tunnel.
///
/// Attempted TLS failures are recorded even for incomplete framing. Automatic passthrough needs
/// evidence from a complete ClientHello; a client closing without bytes leaves no trace.
/// A handshake that doesn't complete within `connectTimeout` closes the connection; that is
/// recorded as a timeout (if TLS was attempted) but never taken for pinning.
///
/// Confined to the client connection's event loop; kept alive by the closures of the handlers it
/// installs and by its timeout task.
final class InterceptedConnect {
    static var handshakeFailedReason: String { L10n.string("proxyFailure.tlsHandshakeFailed") }
    static var handshakeTimeoutReason: String { L10n.string("proxyFailure.tlsHandshakeTimeout") }
    static var autoPassthroughNote: String { L10n.string("proxyFailure.autoPassthroughNote") }

    private let host: String
    private let port: Int
    private let environment: ProxyEnvironment
    private let connector: UpstreamConnector
    private let tlsContext: NIOSSLContext
    private let clientLookup: EventLoopFuture<ClientApp?>
    private let inheritedConnection: ClientConnectionContext?
    private let connectionFactory: UpstreamConnectionFactory?
    private let sniffer = ClientHelloSniffer()
    private var channel: Channel?
    private var timeout: Scheduled<Void>?
    private var tlsAttempted = false
    private let evidenceProbe = ClientHelloEvidenceProbe()
    /// Set once the outcome is known (handshake completed or failed, timed out, relayed raw, or
    /// closed before any byte); later events are ignored.
    private var settled = false

    /// `host` is lowercase without IPv6 brackets.
    init(
        host: String, port: Int, environment: ProxyEnvironment, connector: UpstreamConnector,
        tlsContext: NIOSSLContext, clientLookup: EventLoopFuture<ClientApp?>,
        inheritedConnection: ClientConnectionContext? = nil, connectionFactory: UpstreamConnectionFactory? = nil
    ) {
        self.host = host
        self.port = port
        self.environment = environment
        self.connector = connector
        self.tlsContext = tlsContext
        self.clientLookup = clientLookup
        self.inheritedConnection = inheritedConnection
        self.connectionFactory = connectionFactory
    }

    /// The handler to install in the client pipeline right after the 200.
    var firstHandler: ChannelHandler { sniffer }

    /// Call once `firstHandler` is installed and the 200 was written.
    func start(on channel: Channel) {
        self.channel = channel
        sniffer.onFirstBytes = { [self] isTLSHandshake in
            if isTLSHandshake { startInterception() } else { relayUntouched() }
        }
        sniffer.onClose = { [self] in
            environment.tls.pinningFailures.recordSuccess(host: host)
            settle()
        }  // closed before sending anything
        timeout = channel.eventLoop.assumeIsolated().scheduleTask(in: environment.configuration.connectTimeout) {
            [self] in handshakeTimedOut()
        }
    }

    private func settle() {
        settled = true
        timeout?.cancel()
        timeout = nil
    }

    private func startInterception() {
        tlsAttempted = true
        guard let channel else { return }
        let connection = inheritedConnection ?? ClientConnectionContext(channel: channel, environment: environment, clientLookup: clientLookup)
        let monitor = TLSHandshakeMonitor(
            onCompleted: { [self] in
                guard !settled else { return }
                connection.setDownstreamTLSVersion(ConnectionInfoReader.tlsVersion(of: channel))
                environment.tls.pinningFailures.recordSuccess(host: host)
                settle()
            },
            onFailure: { [self] error in handshakeFailed(error) })
        let owner = NIOLoopBound(connection, eventLoop: channel.eventLoop)
        let target = RequestTarget(host: host, port: port, originForm: "", defaultPort: 443)
        HTTP2Pipeline.installNegotiation(on: channel) { selected, channel in
            if selected == .http2 {
                return HTTP2Pipeline.installServer(on: channel, connection: owner.value, authority: target)
            }
            return channel.eventLoop.makeCompletedFuture {
                let connection = owner.value
                try channel.pipeline.syncOperations.addHandlers([
                    HTTPMessageTranslation.responseEncoder(), HTTP1TransferCodingFramer<HTTPResponseHead>(),
                    ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes)),
                    ProxyHandler(mode: .mitm(host: target.host, port: target.port), environment: connection.environment,
                                 inheritedClientLookup: connection.clientLookup, inheritedConnection: connection),
                ])
            }
        }.assumeIsolated().whenComplete { [self] installed in
            do {
                _ = try installed.get()
                // Negotiation must see replayed TLS events: put SSL before it, before replay.
                try channel.pipeline.syncOperations.addHandlers([
                    evidenceProbe, NIOSSLServerHandler(context: tlsContext), monitor,
                ], position: .after(sniffer))
                try sniffer.handOver(to: [])
            } catch {
                settle()
                channel.close(promise: nil)
            }
        }
    }

    /// Evaluate the accepted connection's configuration snapshot, without losing the failed flow
    /// when evidence is insufficient. Only a real registry insertion receives the automatic note.
    private func handshakeFailed(_ error: Error?) {
        guard !settled else { return }
        settle()
        let configuration = environment.configuration
        let note: String?
        if configuration.autoPassthroughOnHandshakeFailure {
            let evidence = TLSInterception.pinningEvidence(for: error, hasClientHello: evidenceProbe.hasClientHello)
            let qualifies = environment.tls.pinningFailures.recordFailure(
                host: host, evidence: evidence, now: ProcessInfo.processInfo.systemUptime)
            if qualifies { environment.passthrough.insert(host) }
            note = qualifies ? Self.autoPassthroughNote : nil
        } else {
            environment.tls.pinningFailures.recordSuccess(host: host)
            note = L10n.format("proxyFailure.rootNotTrusted", configuration.productName)
        }
        recordFailure(reason: Self.handshakeFailedReason, note: note)
    }

    private func handshakeTimedOut() {
        timeout = nil
        guard !settled else { return }
        settle()
        environment.tls.pinningFailures.recordSuccess(host: host)
        if tlsAttempted { recordFailure(reason: Self.handshakeTimeoutReason, note: nil) }
        channel?.close(promise: nil)
    }

    private func recordFailure(reason: String, note: String?) {
        guard let store = environment.recording.activeStore else { return }
        let id = TunnelRecorder.recordFailure(
            store: store, host: host, port: port, client: nil, reason: reason, note: note)
        clientLookup.assumeIsolated().whenSuccess { app in
            if let app { store.update(id) { $0.client = app } }
        }
    }

    /// Not TLS: open the target and relay the bytes as they are, recorded as a tunnel.
    private func relayUntouched() {
        environment.tls.pinningFailures.recordSuccess(host: host)
        settle()
        guard let channel else { return }
        channel.setAutoRead(false)
        let recorder = environment.recording.activeStore.map { store in
            TunnelRecorder(store: store, host: host, port: port, client: nil, eventLoop: channel.eventLoop)
        }
        if let recorder {
            clientLookup.assumeIsolated().whenSuccess { app in
                if let app { recorder.setClient(app) }
            }
        }
        let connecting = connectionFactory?(host, port, channel.eventLoop)
            ?? connector.connect(host: host, port: port, on: channel.eventLoop)
        // The original CONNECT owner must join both pending setup and the actual
        // transport close, including a success arriving after the client closed.
        let connection = inheritedConnection ?? ClientConnectionContext(
            channel: channel, environment: environment, clientLookup: clientLookup)
        connection.retainTransportWork(connecting).assumeIsolated()
            .whenComplete { [self] result in
                switch result {
                case .failure(let error):
                    recorder?.fail(UpstreamConnector.describe(error))
                    channel.close(promise: nil)
                case .success(let upstream):
                    guard channel.isActive else {
                        upstream.close(promise: nil)
                        recorder?.fail(L10n.string("proxyFailure.clientDisconnected"))
                        return
                    }
                    do {
                        try GlueHandler.joinTunnel(client: channel, upstream: upstream, recorder: recorder) {
                            try sniffer.handOver(to: [$0])
                        }
                    } catch {
                        recorder?.fail(UpstreamConnector.describe(error))
                        upstream.close(promise: nil)
                        channel.close(promise: nil)
                    }
                }
            }
    }
}
