import Crypto
import Foundation
import Testing
import X509

@testable import CertKit

@Suite struct PeerCertificateInfoTests {
    @Test func readsSubjectIssuerSerialFingerprintAndValidity() throws {
        let ca = try CertificateAuthority.generate(commonName: "Peer Info CA")
        let leaf = try ca.leaf(for: "peer.example.test")
        let info = try PeerCertificateInfo(der: leaf.certificateDER)
        let parsed = try Certificate(derEncoded: leaf.certificateDER)

        #expect(info.subject.contains("peer.example.test"))
        #expect(info.issuer.contains("Peer Info CA"))
        let expectedSerial = parsed.serialNumber.bytes.map { String(format: "%02X", $0) }.joined()
        #expect(info.serialNumber == expectedSerial)
        #expect(info.serialNumber == info.serialNumber.uppercased())
        #expect(!info.serialNumber.isEmpty)
        #expect(info.sha256Fingerprint.count == 64)
        #expect(info.sha256Fingerprint == info.sha256Fingerprint.uppercased())
        #expect(info.sha256Fingerprint.allSatisfy { $0.isHexDigit })
        let digest = SHA256.hash(data: Data(leaf.certificateDER)).map { String(format: "%02X", $0) }.joined()
        #expect(info.sha256Fingerprint == digest)
        #expect(info.notBefore == parsed.notValidBefore)
        #expect(info.notAfter == parsed.notValidAfter)
        #expect(info.notBefore < info.notAfter)
    }

    /// Fixed fixture made with `openssl req -x509` (P-256, ecdsa-with-SHA256, serial 0x0A1B2C): Subject and
    /// issuer `C=US, O=Fixture Org, CN=fixture.example.test`, SAN DNS x2 + IP 192.0.2.7 + e-mail.
    static let fixtureDER: [UInt8] = Array(Data(base64Encoded: """
        MIIBzTCCAXSgAwIBAgIDChssMAoGCCqGSM49BAMCMEIxCzAJBgNVBAYTAlVTMRQwEgYDVQQKDAtG
        aXh0dXJlIE9yZzEdMBsGA1UEAwwUZml4dHVyZS5leGFtcGxlLnRlc3QwHhcNMjYxMDI1MTIyMDU3
        WhcNMzYxMDIyMTIyMDU3WjBCMQswCQYDVQQGEwJVUzEUMBIGA1UECgwLRml4dHVyZSBPcmcxHTAb
        BgNVBAMMFGZpeHR1cmUuZXhhbXBsZS50ZXN0MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEe7jP
        vzRLETbFPezL1Z5GsDI84RLw5+P6VuH/djN30DhxAF7B6A1vDYKfwGF4TsotgCj1PtXohNbh6Crx
        2WaVLKNZMFcwVQYDVR0RBE4wTIIUZml4dHVyZS5leGFtcGxlLnRlc3SCFiouZml4dHVyZS5leGFt
        cGxlLnRlc3SHBMAAAgeBFmFAZml4dHVyZS5leGFtcGxlLnRlc3QwCgYIKoZIzj0EAwIDRwAwRAIg
        AfmBtQBV81D/FGHMeWSqpPJ9bb865Q22o8TZQJci7wsCICQVPQJuLfW2ZKLZ9Acb8K1CZ7+m8Zi2
        BASsSGPQVCF+
        """, options: .ignoreUnknownCharacters)!)

    @Test func readsExtendedFactsFromFixedDER() throws {
        let info = try PeerCertificateInfo(der: Self.fixtureDER)
        #expect(info.version == 3)
        #expect(info.serialNumber == "0A1B2C")
        #expect(info.sha1Fingerprint == "402AEB51BE95B8A84767B10296CC61D376D6D63F")
        #expect(info.sha256Fingerprint == "D5D2E1395881A95F1EE46557E550F9AE1114D12F4F192CAC4E9F94EBB5EB9507")
        #expect(info.notBefore == Date(timeIntervalSince1970: 1_792_930_857))
        #expect(info.notAfter == Date(timeIntervalSince1970: 2_108_290_857))
        #expect(info.subjectCommonName == "fixture.example.test")
        #expect(info.subjectOrganization == "Fixture Org")
        #expect(info.subjectCountry == "US")
        #expect(info.issuerCommonName == "fixture.example.test")
        #expect(info.issuerOrganization == "Fixture Org")
        #expect(info.issuerCountry == "US")
        #expect(info.subjectAlternativeNames == [
            "fixture.example.test", "*.fixture.example.test", "192.0.2.7", "a@fixture.example.test",
        ])
        #expect(info.publicKey == "P256 256 047BB8CFBF344B1136C53DECCBD59E46B0323CE112F0E7E3FA56E1FF763377D03871005EC1E80D6F0D829FC061784ECA2D8028F53ED5E884D6E1E82AF1D966952C")
        #expect(info.signature == "ecdsaWithSHA256 3044022001F981B50055F350FF1461CC7964AAA4F27D6DBF3AE50DB6A3C4D9409722EF0B022024153D026E2DF5B664A2D9F4071BF0AD4267BFA6F198B60404AC4863D054217E")
    }

    @Test func missingNamePartsAndExtensionsReadAsEmpty() throws {
        let ca = try CertificateAuthority.generate(commonName: "No Org CA")
        let info = try PeerCertificateInfo(der: try ca.leaf(for: "plain.example.test").certificateDER)
        #expect(info.version == 3)
        #expect(info.subjectCommonName == "plain.example.test")
        #expect(info.subjectOrganization.isEmpty)
        #expect(info.subjectCountry.isEmpty)
        #expect(info.issuerCommonName.hasPrefix("No Org CA"))
        #expect(info.sha1Fingerprint.count == 40)
        #expect(info.subjectAlternativeNames.contains("plain.example.test"))
        #expect(info.publicKey.hasPrefix("P256 256 04"))
        #expect(info.signature.hasPrefix("ecdsaWithSHA256 30"))
    }

    /// Fixed fixture from `openssl req -x509 -newkey rsa:2048 -sha256 -subj /CN=rsa.example.test`: an X.509 v1 certificate, so no extensions at all (no SAN).
    static let rsaFixtureDER: [UInt8] = Array(Data(base64Encoded: """
        MIICsjCCAZoCCQCqyGJbGSVjazANBgkqhkiG9w0BAQsFADAbMRkwFwYDVQQDDBByc2EuZXhhbXBs
        ZS50ZXN0MB4XDTI2MTAyNTEyNTcyN1oXDTM2MTAyMjEyNTcyN1owGzEZMBcGA1UEAwwQcnNhLmV4
        YW1wbGUudGVzdDCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBANEPgW51/2uWSIcpi6V0
        +TzyNGyRPYmlq/Iqdganp5yxtoqGA1LHd8eFhl7JLHPkQuG6iRoByOkQaBeBkyyXjHRWWQiLaiJ7
        lw2cVLQ1dVg8e8fDdOXvOq8eU7Lng9uyEII+XtruB6B0eblANoz2oxXUBLcvJyPHpAuzI90UKZkJ
        FMwg+OWsQi0wDLgyPUKW08iFLzpxw/cAKeKNu6Fh/CncXr6aDTdZ6iZOetzZwidLmlWa4jsftnaV
        88YBjJP0J6bC+vbOr1xjhAWlVaiaE63WEmN4hTx8L0O2XNyOl04M20oTWf5KcHSnnNM6iNyr5xSw
        1wFu0HIX5k3808liu98CAwEAATANBgkqhkiG9w0BAQsFAAOCAQEAxBGyPyWxqv61XfegvKX1lo4H
        Kye3zm9ps2IEM9A3dhVu+hYHGYOiSDP2fy+7+Bj/2RbVfDu8yGDKWel4DFqwdGSytxr+FT30a0k5
        DTaMnHx4t056RSbfQkLgdFLOd7BSpgV1iJ6SOPMIQ14FLPZ8vii41mOyXP0mEuR473VTw6uXcc9w
        LW1dGSqNfGevjxPGWsFN98Ze5dQbGpcvfHIt82VBw2Hg9mJPof4yuS2gAK4RnUZ4jHSjrOZKfRAf
        7NSBc6CT5kJmpHHA/ypOj/m/+q7+1tfCugjrhm1+zFNvBEAdP7fF3emU/sO6vrAfPXBI94kk7n7A
        MXgI5faKSjPbNA==
        """, options: .ignoreUnknownCharacters)!)

    @Test func readsRSACertificateWithoutAlternativeNames() throws {
        let info = try PeerCertificateInfo(der: Self.rsaFixtureDER)
        #expect(info.version == 1)
        #expect(info.publicKey.hasPrefix("RSA 2048 3082"))
        #expect(info.signature.hasPrefix("sha256WithRSAEncryption "))
        #expect(info.signature.count == "sha256WithRSAEncryption ".count + 2 * 256)
        #expect(info.subjectCommonName == "rsa.example.test")
        #expect(info.subjectAlternativeNames.isEmpty)
        #expect(info.subjectOrganization.isEmpty && info.subjectCountry.isEmpty)
    }

    /// The public key text is the subjectPublicKey BIT STRING content, not the whole SubjectPublicKeyInfo (final review).
    @Test func publicKeyIsTheBitStringContentNotTheWholeSubjectPublicKeyInfo() throws {
        let rsa = try PeerCertificateInfo(der: Self.rsaFixtureDER)
        let rsaHex = String(try #require(rsa.publicKey.split(separator: " ").last))
        // RSAPublicKey for 2048 bits: SEQUENCE (4-byte header) + 266 content bytes = 270 bytes; a SubjectPublicKeyInfo
        // would be 294 bytes and carry the rsaEncryption OID.
        #expect(rsaHex.count == 2 * 270)
        #expect(rsaHex.hasPrefix("3082010A02820101"))
        #expect(!rsaHex.contains("06092A864886F70D010101"))
        let ec = try PeerCertificateInfo(der: Self.fixtureDER)
        let ecHex = String(try #require(ec.publicKey.split(separator: " ").last))
        // An uncompressed P-256 point: 0x04 || X || Y, 65 bytes (the SubjectPublicKeyInfo would be 91 and start 3059).
        #expect(ecHex.count == 2 * 65 && ecHex.hasPrefix("04"))
    }

    @Test func unrecognisedKeyOrSignatureNeverYieldsEmptyOrZeroAlgorithm() {
        let bytes: [UInt8] = [0x0A, 0xFF]
        #expect(PeerCertificateInfo.describe(keyDescription: "Mystery.PublicKey", bytes: bytes) == "unknown 0AFF")
        #expect(PeerCertificateInfo.describe(keyDescription: "RSA.PublicKey", bytes: bytes) == "unknown 0AFF")
        #expect(PeerCertificateInfo.describe(keyDescription: "RSA0.PublicKey", bytes: bytes) == "unknown 0AFF")
        #expect(PeerCertificateInfo.describe(keyDescription: "RSA4096.PublicKey", bytes: bytes) == "RSA 4096 0AFF")
        #expect(PeerCertificateInfo.describe(keyDescription: "Ed25519.PublicKey", bytes: bytes) == "Ed25519 256 0AFF")
        #expect(PeerCertificateInfo.describe(signatureAlgorithm: "SignatureAlgorithm(1.2.3)", bytes: bytes) == "unknown 0AFF")
        #expect(PeerCertificateInfo.describe(signatureAlgorithm: "SignatureAlgorithm.", bytes: bytes) == "unknown 0AFF")
        #expect(PeerCertificateInfo.describe(signatureAlgorithm: "SignatureAlgorithm.ed25519", bytes: bytes) == "ed25519 0AFF")
    }

    @Test func hexEncoderIsUppercaseAndZeroPadded() {
        #expect(PeerCertificateInfo.hex([UInt8]()) == "")
        #expect(PeerCertificateInfo.hex([0x00, 0x0F, 0xA0, 0xFF]) == "000FA0FF")
    }

    @Test func rejectsGarbageDER() {
        #expect(throws: (any Error).self) { try PeerCertificateInfo(der: [0x01, 0x02, 0x03]) }
        #expect(throws: (any Error).self) { try PeerCertificateInfo(der: []) }
    }
}
