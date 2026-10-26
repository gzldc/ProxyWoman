import CertKit
import Crypto
import FlowStore
import Foundation
import NIOCore
import NIOSSL
import os

/// What the proxy learns about the two connections of one exchange. Every field is optional and
/// `FlowRecorder.setConnectionInfo` writes only the ones that are set.
struct FlowConnectionInfo {
    var clientIP: String?
    var remoteIP: String?
    var downstreamTLSVersion: String?
    var upstreamTLSVersion: String?
    var upstreamCertificate: CertificateSummary?

    var isEmpty: Bool {
        clientIP == nil && remoteIP == nil && downstreamTLSVersion == nil && upstreamTLSVersion == nil
            && upstreamCertificate == nil
    }
}

enum TLSVersionText {
    /// `nil` for a version this build does not know.
    static func text(for version: TLSVersion) -> String? {
        switch version {
        case .tlsv1: "TLS 1.0"
        case .tlsv11: "TLS 1.1"
        case .tlsv12: "TLS 1.2"
        case .tlsv13: "TLS 1.3"
        @unknown default: nil
        }
    }
}

/// Read-only lookups of what a channel already knows: its peer address and, once a TLS handshake
/// is done, the negotiated version and the peer's certificate. They add no round trip and fail
/// quietly: anything that cannot be read is nil.
enum ConnectionInfoReader {
    static func peerIP(of channel: Channel) -> String? {
        channel.remoteAddress?.ipAddress
    }

    /// The TLS version negotiated on `channel` (the handler must sit on this very channel).
    static func tlsVersion(of channel: Channel) -> String? {
        guard channel.eventLoop.inEventLoop,
              let version = (try? channel.pipeline.syncOperations.nioSSL_tlsVersion()) ?? nil else { return nil }
        return TLSVersionText.text(for: version)
    }

    /// The origin side of an exchange: address, TLS version and certificate of the connection under
    /// `lease`. An HTTP/2 stream channel has no TLS handler of its own, its parent connection does.
    /// The TLS version and the certificate summary (DER parse, SHA-256, hex) do not change over the life of a
    /// connection, so they are read once and remembered on the connection's own pipeline; every later exchange
    /// on it (a kept-alive HTTP/1 connection, every stream of an HTTP/2 one) reuses them. `readCertificate` is
    /// the seam for tests.
    static func upstream(
        of lease: UpstreamLease, readCertificate: (Channel) -> CertificateSummary? = Self.peerCertificateSummary
    ) -> FlowConnectionInfo {
        let connection = lease.channel.parent ?? lease.channel
        var info = FlowConnectionInfo(remoteIP: peerIP(of: connection))
        guard connection.eventLoop.inEventLoop else { return info }
        let operations = connection.pipeline.syncOperations
        if let memo = try? operations.handler(type: UpstreamConnectionMemo.self) {
            info.upstreamTLSVersion = memo.tlsVersion
            info.upstreamCertificate = memo.certificate
            return info
        }
        info.upstreamTLSVersion = tlsVersion(of: connection)
        info.upstreamCertificate = readCertificate(connection)
        try? operations.addHandler(UpstreamConnectionMemo(tlsVersion: info.upstreamTLSVersion, certificate: info.upstreamCertificate))
        return info
    }

    static func peerCertificateSummary(of connection: Channel) -> CertificateSummary? {
        guard let certificate = (try? connection.pipeline.syncOperations.nioSSL_peerCertificate()) ?? nil,
              let der = try? certificate.toDERBytes() else { return nil }
        // One summary per certificate: the key and signature texts (about a kilobyte for RSA 2048) are shared by every
        // flow and connection that saw it, not copied per connection.
        let fingerprint = Array(SHA256.hash(data: der))
        if let known = CertificateSummaryCache.shared.summary(for: fingerprint) { return known }
        guard let parsed = try? PeerCertificateInfo(der: der) else { return nil }
        let summary = CertificateSummary(
            subject: parsed.subject, issuer: parsed.issuer, serialNumber: parsed.serialNumber,
            sha256Fingerprint: parsed.sha256Fingerprint, notBefore: parsed.notBefore, notAfter: parsed.notAfter,
            version: parsed.version, sha1Fingerprint: parsed.sha1Fingerprint,
            issuerCommonName: parsed.issuerCommonName, issuerOrganization: parsed.issuerOrganization,
            issuerCountry: parsed.issuerCountry, subjectCommonName: parsed.subjectCommonName,
            subjectOrganization: parsed.subjectOrganization, subjectCountry: parsed.subjectCountry,
            subjectAlternativeNames: parsed.subjectAlternativeNames, publicKey: parsed.publicKey,
            signature: parsed.signature,
            // NOTE: any future "ignore upstream certificate errors" option must set this to nil or false
            // (an unverified handshake is not trusted).
            // Upstream contexts always verify the chain (and, for names, the host); a certificate read here
            // belongs to a handshake that already succeeded, so it was trusted by the configured roots.
            isTrusted: true)
        CertificateSummaryCache.shared.store(summary, for: fingerprint)
        return summary
    }
}

/// The parsed upstream certificates seen lately, by the SHA-256 of their DER bytes. Bounded: when full it starts over
/// (certificates come back quickly if they are still in use). Trust is part of the entry because every upstream handshake
/// is fully verified before a certificate is read, so the same bytes always carry the same answer.
final class CertificateSummaryCache: Sendable {
    static let shared = CertificateSummaryCache()
    static let capacity = 256
    private let entries = OSAllocatedUnfairLock(initialState: [[UInt8]: CertificateSummary]())

    func summary(for fingerprint: [UInt8]) -> CertificateSummary? { entries.withLock { $0[fingerprint] } }

    func store(_ summary: CertificateSummary, for fingerprint: [UInt8]) {
        entries.withLock { entries in
            if entries.count >= Self.capacity { entries.removeAll(keepingCapacity: true) }
            entries[fingerprint] = summary
        }
    }

    var count: Int { entries.withLock { $0.count } }
}

/// What was read from one upstream connection, kept on its pipeline so it lives and dies with the connection.
/// It handles no events itself (the inbound defaults pass everything on).
final class UpstreamConnectionMemo: ChannelInboundHandler {
    typealias InboundIn = NIOAny
    let tlsVersion: String?
    let certificate: CertificateSummary?

    init(tlsVersion: String?, certificate: CertificateSummary?) {
        self.tlsVersion = tlsVersion
        self.certificate = certificate
    }
}
