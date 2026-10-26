import Crypto
import Foundation
import Security
import Testing
import X509

@testable import CertKit

@Suite struct CertificateAuthorityTests {
    // MARK: helpers

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("certkit-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Evaluates `leaf` against an SSL policy for `host`, trusting only `ca`'s root.
    private func evaluates(_ leaf: LeafIdentity, host: String, ca: CertificateAuthority) throws -> Bool {
        let leafCert = try #require(SecCertificateCreateWithData(nil, Data(leaf.certificateDER) as CFData))
        let rootCert = try #require(
            SecCertificateCreateWithData(nil, Data(ca.rootCertificateDER) as CFData))
        var trust: SecTrust?
        let status = SecTrustCreateWithCertificates(
            [leafCert] as CFArray, SecPolicyCreateSSL(true, host as CFString), &trust)
        #expect(status == errSecSuccess)
        let t = try #require(trust)
        #expect(SecTrustSetAnchorCertificates(t, [rootCert] as CFArray) == errSecSuccess)
        SecTrustSetAnchorCertificatesOnly(t, true)
        return SecTrustEvaluateWithError(t, nil)
    }

    private func parse(_ der: [UInt8]) throws -> Certificate {
        try Certificate(derEncoded: der)
    }

    /// Bytes of the single iPAddress SAN entry, or nil if the SAN is anything else.
    private func ipBytes(_ sans: SubjectAlternativeNames) -> [UInt8]? {
        let names = Array(sans)
        guard names.count == 1, case .ipAddress(let octets) = names[0] else { return nil }
        return Array(octets.bytes)
    }

    // MARK: Apple trust evaluation

    @Test func leafValidatesUnderAppleSSLPolicy() throws {
        let ca = try CertificateAuthority.generate()
        let leaf = try ca.leaf(for: "api.example.com")
        #expect(try evaluates(leaf, host: "api.example.com", ca: ca))
    }

    @Test func leafDoesNotValidateForOtherHost() throws {
        let ca = try CertificateAuthority.generate()
        let leaf = try ca.leaf(for: "api.example.com")
        #expect(try !evaluates(leaf, host: "other.example.com", ca: ca))
    }

    @Test func leafDoesNotValidateUnderForeignRoot() throws {
        let ca = try CertificateAuthority.generate()
        let other = try CertificateAuthority.generate()
        let leaf = try ca.leaf(for: "api.example.com")
        #expect(try !evaluates(leaf, host: "api.example.com", ca: other))
    }

    @Test func ipHostGetsIPAddressSAN() throws {
        let ca = try CertificateAuthority.generate()
        let leaf = try ca.leaf(for: "127.0.0.1")
        #expect(try evaluates(leaf, host: "127.0.0.1", ca: ca))
        let sans = try #require(try parse(leaf.certificateDER).extensions.subjectAlternativeNames)
        #expect(ipBytes(sans) == [127, 0, 0, 1])
    }

    @Test func bracketedIPv6HostGetsIPAddressSAN() throws {
        let ca = try CertificateAuthority.generate()
        let leaf = try ca.leaf(for: "[::1]")
        let sans = try #require(try parse(leaf.certificateDER).extensions.subjectAlternativeNames)
        #expect(ipBytes(sans) == [UInt8](repeating: 0, count: 15) + [1])
        #expect(try evaluates(leaf, host: "::1", ca: ca))
    }

    @Test func dnsHostGetsDNSNameSAN() throws {
        let ca = try CertificateAuthority.generate()
        let leaf = try ca.leaf(for: "api.example.com")
        let sans = try #require(try parse(leaf.certificateDER).extensions.subjectAlternativeNames)
        #expect(Array(sans) == [.dnsName("api.example.com")])
    }

    // MARK: leaf contents

    @Test func leafExtensionsAndValidity() throws {
        let ca = try CertificateAuthority.generate()
        let leaf = try ca.leaf(for: "api.example.com")
        let cert = try parse(leaf.certificateDER)

        let eku = try #require(try cert.extensions.extendedKeyUsage)
        #expect(Array(eku) == [.serverAuth])
        let ku = try #require(try cert.extensions.keyUsage)
        #expect(ku == KeyUsage(digitalSignature: true))
        #expect(cert.extensions[oid: .X509ExtensionID.keyUsage]?.critical == true)
        let bc = try #require(try cert.extensions.basicConstraints)
        #expect(bc == .notCertificateAuthority)
        let aki = try #require(try cert.extensions.authorityKeyIdentifier)

        let root = try parse(ca.rootCertificateDER)
        #expect(cert.issuer == root.subject)
        let ski = try #require(try root.extensions.subjectKeyIdentifier)
        #expect(aki.keyIdentifier == ski.keyIdentifier)

        let now = Date()
        #expect(cert.notValidBefore < now)
        #expect(cert.notValidBefore > now - 86400 - 120)
        let span = cert.notValidAfter.timeIntervalSince(cert.notValidBefore)
        #expect(abs(span - 366 * 86400) < 120)
        #expect(span <= 398 * 86400)
    }

    @Test func leafPrivateKeyMatchesCertificateAndIsSharedAcrossHosts() throws {
        let ca = try CertificateAuthority.generate()
        let a = try ca.leaf(for: "a.example.com")
        let b = try ca.leaf(for: "b.example.com")
        #expect(a.privateKeyDER == b.privateKeyDER)
        let key = try P256.Signing.PrivateKey(derRepresentation: a.privateKeyDER)
        #expect(try parse(a.certificateDER).publicKey == Certificate.PublicKey(key.publicKey))
    }

    @Test func leafSubjectCommonNameIsTruncatedTo64() throws {
        let ca = try CertificateAuthority.generate()
        let label = String(repeating: "a", count: 60)
        let host = "\(label).\(label).example.com"
        let cert = try parse(try ca.leaf(for: host).certificateDER)
        let expected = String(host.prefix(64))
        #expect(cert.subject.description == "CN=\(expected)")
        let sans = try #require(try cert.extensions.subjectAlternativeNames)
        #expect(Array(sans) == [.dnsName(host)])
    }

    @Test func emptyHostIsRejected() throws {
        let ca = try CertificateAuthority.generate()
        #expect(throws: CertKitError.self) { try ca.leaf(for: "") }
    }

    // MARK: root

    @Test func rootCertificateProperties() throws {
        let ca = try CertificateAuthority.generate(commonName: "Test CA")
        let root = try parse(ca.rootCertificateDER)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        #expect(root.subject.description == "CN=Test CA (\(formatter.string(from: Date())))")
        #expect(root.issuer == root.subject)

        let bc = try #require(try root.extensions.basicConstraints)
        #expect(bc == .isCertificateAuthority(maxPathLength: 0))
        #expect(root.extensions[oid: .X509ExtensionID.basicConstraints]?.critical == true)
        let ku = try #require(try root.extensions.keyUsage)
        #expect(ku == KeyUsage(keyCertSign: true, cRLSign: true))
        #expect(root.extensions[oid: .X509ExtensionID.keyUsage]?.critical == true)
        #expect(try root.extensions.subjectKeyIdentifier != nil)

        let years = root.notValidAfter.timeIntervalSince(root.notValidBefore) / 86400 / 365
        #expect(years > 10 && years < 10.1)
    }

    @Test func rootPEMsAreWellFormedAndDERMatches() throws {
        let ca = try CertificateAuthority.generate()
        #expect(ca.rootCertificatePEM.hasPrefix("-----BEGIN CERTIFICATE-----"))
        #expect(ca.rootPrivateKeyPEM.contains("PRIVATE KEY"))
        let fromPEM = try Certificate(pemEncoded: ca.rootCertificatePEM)
        #expect(try parse(ca.rootCertificateDER) == fromPEM)
    }

    // MARK: cache

    @Test func leafIsCachedPerHost() throws {
        let ca = try CertificateAuthority.generate()
        let a1 = try ca.leaf(for: "a.example.com")
        let a2 = try ca.leaf(for: "a.example.com")
        let b = try ca.leaf(for: "b.example.com")
        #expect(a1.certificateDER == a2.certificateDER)
        #expect(a1.certificateDER != b.certificateDER)
    }

    @Test func hostCacheKeyIsCaseInsensitive() throws {
        let ca = try CertificateAuthority.generate()
        let a = try ca.leaf(for: "API.Example.com")
        let b = try ca.leaf(for: "api.example.com")
        #expect(a.certificateDER == b.certificateDER)
    }

    @Test func concurrentIssuanceForSameHostConvergesOnOneCachedLeaf() async throws {
        let ca = try CertificateAuthority.generate()
        let ders = try await withThrowingTaskGroup(of: [UInt8].self) { group in
            for _ in 0..<16 {
                group.addTask { try ca.leaf(for: "race.example.com").certificateDER }
            }
            var all = Set<[UInt8]>()
            for try await der in group { all.insert(der) }
            return all
        }
        // Racing callers may issue twice, but a caller that loses the race returns the cached winner.
        #expect(ders.count == 1)
        let cached = try ca.leaf(for: "race.example.com").certificateDER
        #expect(ders.first == cached)
    }

    @Test func cacheEvictsBeyondCapacity() {
        let cache = LeafCache(capacity: 2)
        func identity(_ n: UInt8) -> LeafIdentity {
            LeafIdentity(certificateDER: [n], privateKeyDER: [n])
        }
        _ = cache.insertIfAbsent(identity(1), for: "a")
        _ = cache.insertIfAbsent(identity(2), for: "b")
        #expect(cache.get("a") != nil)  // touch a, so b is least recently used
        _ = cache.insertIfAbsent(identity(3), for: "c")
        #expect(cache.get("b") == nil)
        #expect(cache.get("a")?.certificateDER == [1])
        #expect(cache.get("c")?.certificateDER == [3])
        #expect(cache.count == 2)
    }

    @Test func insertIfAbsentKeepsExistingEntry() {
        let cache = LeafCache(capacity: 2)
        let first = LeafIdentity(certificateDER: [1], privateKeyDER: [1])
        let second = LeafIdentity(certificateDER: [2], privateKeyDER: [2])
        #expect(cache.insertIfAbsent(first, for: "a").certificateDER == [1])
        #expect(cache.insertIfAbsent(second, for: "a").certificateDER == [1])
        #expect(cache.get("a")?.certificateDER == [1])
        #expect(cache.count == 1)
    }

    // MARK: store

    @Test func loadOrCreatePersistsAndReloads() throws {
        let dir = try makeTempDirectory().appendingPathComponent("CA")
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let store = CAStore(directory: dir)

        let first = try CertificateAuthority.loadOrCreate(store: store)
        let second = try CertificateAuthority.loadOrCreate(store: store)
        #expect(first.rootCertificateDER == second.rootCertificateDER)
        #expect(first.rootPrivateKeyPEM == second.rootPrivateKeyPEM)

        let keyAttrs = try FileManager.default.attributesOfItem(
            atPath: dir.appendingPathComponent("root-ca-key.pem").path)
        #expect(keyAttrs[.posixPermissions] as? Int == 0o600)
        let certAttrs = try FileManager.default.attributesOfItem(atPath: store.certificateURL.path)
        #expect(certAttrs[.posixPermissions] as? Int == 0o644)
        #expect(store.certificateURL.lastPathComponent == "root-ca.pem")
        let dirAttrs = try FileManager.default.attributesOfItem(atPath: dir.path)
        #expect(dirAttrs[.posixPermissions] as? Int == 0o700)

        // leaves issued by the reloaded CA chain to the original root
        let leaf = try second.leaf(for: "api.example.com")
        #expect(try evaluates(leaf, host: "api.example.com", ca: first))
    }

    @Test func saveOverwritesExistingFilesKeepingPermissions() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = CAStore(directory: dir)
        try store.save(certificatePEM: "cert-1", privateKeyPEM: "key-1")
        try store.save(certificatePEM: "cert-2", privateKeyPEM: "key-2")
        let loaded = try #require(try store.load())
        #expect(loaded.certificatePEM == "cert-2")
        #expect(loaded.privateKeyPEM == "key-2")
        let keyAttrs = try FileManager.default.attributesOfItem(
            atPath: dir.appendingPathComponent("root-ca-key.pem").path)
        #expect(keyAttrs[.posixPermissions] as? Int == 0o600)
    }

    @Test func loadReturnsNilWhenStoreIsEmpty() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try CAStore(directory: dir).load() == nil)
    }

    @Test func corruptStoreThrowsInsteadOfRegenerating() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = CAStore(directory: dir)
        try store.save(certificatePEM: "garbage", privateKeyPEM: "garbage")
        #expect(throws: (any Error).self) { try CertificateAuthority.loadOrCreate(store: store) }
        // Files must be left untouched.
        #expect(try store.load()?.certificatePEM == "garbage")
    }

    @Test func partialStoreThrowsInsteadOfRegenerating() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ca = try CertificateAuthority.generate()
        try ca.rootCertificatePEM.write(
            to: dir.appendingPathComponent("root-ca.pem"), atomically: true, encoding: .utf8)
        let store = CAStore(directory: dir)
        #expect(throws: (any Error).self) { try store.load() }
        #expect(throws: (any Error).self) { try CertificateAuthority.loadOrCreate(store: store) }
    }

    @Test func mismatchedKeyAndCertificateThrows() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = try CertificateAuthority.generate()
        let b = try CertificateAuthority.generate()
        let store = CAStore(directory: dir)
        try store.save(certificatePEM: a.rootCertificatePEM, privateKeyPEM: b.rootPrivateKeyPEM)
        #expect(throws: (any Error).self) { try CertificateAuthority.loadOrCreate(store: store) }
    }
}
