import Crypto
import Foundation
import Testing
import X509

@testable import CertKit

@Suite struct CertificateMetadataTests {
    @Test func readsPublicMetadataWithoutPrivateKey() throws {
        let key = P256.Signing.PrivateKey()
        let name = try DistinguishedName { CommonName("Fixture CA (2026-10-15)") }
        let cert = try Certificate(
            version: .v3, serialNumber: Certificate.SerialNumber(bytes: [0x12, 0x34, 0x56, 0x78, 0x90]),
            publicKey: Certificate.PublicKey(key.publicKey), notValidBefore: Date(timeIntervalSince1970: 1_700_000_000),
            notValidAfter: Date(timeIntervalSince1970: 1_800_000_000), issuer: name, subject: name,
            signatureAlgorithm: .ecdsaWithSHA256, extensions: Certificate.Extensions(),
            issuerPrivateKey: Certificate.PrivateKey(key))
        let metadata = try CertificateMetadata(pemEncoded: cert.serializeAsPEM().pemString)
        #expect(metadata.commonName == "Fixture CA (2026-10-15)")
        #expect(metadata.serialNumberPrefix == "12345678")
        #expect(metadata.validFrom == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(metadata.validUntil == Date(timeIntervalSince1970: 1_800_000_000))
    }

    @Test func rejectsInvalidPEM() {
        #expect(throws: (any Error).self) { try CertificateMetadata(pemEncoded: "invalid") }
    }
}
