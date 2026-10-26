import Crypto
import Foundation
import SwiftASN1
import X509

/// ProxyWoman's root CA. Signs per-host leaf certificates that the proxy presents when it
/// terminates TLS for a CONNECT tunnel.
public final class CertificateAuthority: Sendable {
    private let caKey: P256.Signing.PrivateKey
    private let issuerName: DistinguishedName
    private let authorityKeyIdentifier: AuthorityKeyIdentifier
    /// One key shared by every leaf of this CA instance.
    private let leafKey: P256.Signing.PrivateKey
    private let leafKeyDER: [UInt8]
    private let cache: LeafCache

    public let rootCertificateDER: [UInt8]
    public let rootCertificatePEM: String
    public let rootPrivateKeyPEM: String

    private init(caKey: P256.Signing.PrivateKey, certificate: Certificate, leafCacheCapacity: Int) throws {
        guard certificate.publicKey == Certificate.PublicKey(caKey.publicKey) else {
            throw CertKitError.corruptStore("root certificate does not match the private key")
        }
        self.caKey = caKey
        self.issuerName = certificate.subject
        let keyIdentifier =
            (try? certificate.extensions.subjectKeyIdentifier)?.keyIdentifier
            ?? SubjectKeyIdentifier(hash: certificate.publicKey).keyIdentifier
        self.authorityKeyIdentifier = AuthorityKeyIdentifier(keyIdentifier: keyIdentifier)
        self.leafKey = P256.Signing.PrivateKey()
        self.leafKeyDER = Array(leafKey.derRepresentation)
        self.cache = LeafCache(capacity: leafCacheCapacity)

        var serializer = DER.Serializer()
        try serializer.serialize(certificate)
        self.rootCertificateDER = serializer.serializedBytes
        self.rootCertificatePEM = try certificate.serializeAsPEM().pemString
        self.rootPrivateKeyPEM = caKey.pemRepresentation
    }

    /// Creates a brand new root CA (P-256, valid for 10 years).
    public static func generate(commonName: String = "ProxyWoman CA") throws -> CertificateAuthority {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let now = Date()
        let name = try DistinguishedName {
            CommonName("\(commonName) (\(formatter.string(from: now)))")
        }
        let key = P256.Signing.PrivateKey()
        let publicKey = Certificate.PublicKey(key.publicKey)
        let certificate = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: publicKey,
            notValidBefore: now - 86400,
            notValidAfter: now + 10 * 365 * 86400,
            issuer: name,
            subject: name,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.isCertificateAuthority(maxPathLength: 0))
                Critical(KeyUsage(keyCertSign: true, cRLSign: true))
                SubjectKeyIdentifier(hash: publicKey)
            },
            issuerPrivateKey: Certificate.PrivateKey(key)
        )
        return try CertificateAuthority(caKey: key, certificate: certificate, leafCacheCapacity: 1000)
    }

    /// Loads the CA from `store`, generating and saving a new one only if the store is empty.
    /// Existing but unusable files make this throw rather than being replaced, because a new root
    /// would no longer be the one the user has trusted.
    public static func loadOrCreate(store: CAStore) throws -> CertificateAuthority {
        guard let stored = try store.load() else {
            let ca = try generate()
            try store.save(certificatePEM: ca.rootCertificatePEM, privateKeyPEM: ca.rootPrivateKeyPEM)
            return ca
        }
        do {
            let key = try P256.Signing.PrivateKey(pemRepresentation: stored.privateKeyPEM)
            let certificate = try Certificate(pemEncoded: stored.certificatePEM)
            return try CertificateAuthority(
                caKey: key, certificate: certificate, leafCacheCapacity: 1000)
        } catch let error as CertKitError {
            throw error
        } catch {
            throw CertKitError.corruptStore("cannot parse stored CA: \(error)")
        }
    }

    /// Returns a leaf certificate for `host` (a DNS name, or an IPv4/IPv6 literal, optionally
    /// bracketed), issuing and caching it on first use.
    public func leaf(for host: String) throws -> LeafIdentity {
        let normalized = Self.normalize(host)
        guard !normalized.isEmpty else { throw CertKitError.invalidHost(host) }
        if let cached = cache.get(normalized) { return cached }
        // Two threads racing on the same host may both issue; the cache keeps the first.
        return cache.insertIfAbsent(try issueLeaf(for: normalized), for: normalized)
    }

    private func issueLeaf(for host: String) throws -> LeafIdentity {
        let san: GeneralName
        if let address = Self.ipAddressBytes(host) {
            san = .ipAddress(ASN1OctetString(contentBytes: address[...]))
        } else {
            san = .dnsName(host)
        }
        // CN is limited to 64 characters (RFC 5280); the SAN carries the full name.
        let subject = try DistinguishedName { CommonName(String(host.prefix(64))) }
        let now = Date()
        let certificate = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: Certificate.PublicKey(leafKey.publicKey),
            notValidBefore: now - 86400,
            notValidAfter: now + 365 * 86400,
            issuer: issuerName,
            subject: subject,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.notCertificateAuthority)
                Critical(KeyUsage(digitalSignature: true))
                try ExtendedKeyUsage([.serverAuth])
                SubjectAlternativeNames([san])
                authorityKeyIdentifier
            },
            issuerPrivateKey: Certificate.PrivateKey(caKey)
        )
        var serializer = DER.Serializer()
        try serializer.serialize(certificate)
        return LeafIdentity(certificateDER: serializer.serializedBytes, privateKeyDER: leafKeyDER)
    }

    /// Strips IPv6 brackets and lowercases, so cache keys and SANs are consistent.
    private static func normalize(_ host: String) -> String {
        var h = host
        if h.hasPrefix("["), h.hasSuffix("]") { h = String(h.dropFirst().dropLast()) }
        return h.lowercased()
    }

    /// 4 bytes for an IPv4 dotted quad, 16 for IPv6, nil if `host` is not an IP literal.
    private static func ipAddressBytes(_ host: String) -> [UInt8]? {
        var v4 = in_addr()
        if inet_pton(AF_INET, host, &v4) == 1 {
            return withUnsafeBytes(of: &v4) { Array($0) }
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, host, &v6) == 1 {
            return withUnsafeBytes(of: &v6) { Array($0) }
        }
        return nil
    }
}
