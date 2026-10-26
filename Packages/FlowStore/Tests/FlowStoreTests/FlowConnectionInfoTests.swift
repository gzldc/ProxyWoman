import Foundation
import Testing

@testable import FlowStore

@Suite struct FlowConnectionInfoTests {
    @Test func newFieldsDefaultToNil() {
        let flow = Flow(id: 1, scheme: "https", method: "GET", host: "x.com", port: 443, path: "/")
        #expect(flow.clientIP == nil)
        #expect(flow.remoteIP == nil)
        #expect(flow.upstreamCertificate == nil)
        #expect(flow.transport.downstreamTLSVersion == nil)
        #expect(flow.transport.upstreamTLSVersion == nil)
    }

    @Test func transportMetadataKeepsExistingInitCalls() {
        let meta = HTTPTransportMetadata(downstreamRequest: .http2, upstreamStreamID: 3)
        #expect(meta.downstreamRequest == .http2)
        #expect(meta.upstreamStreamID == 3)
        #expect(meta.downstreamTLSVersion == nil)
        let tls = HTTPTransportMetadata(downstreamTLSVersion: "TLS 1.3", upstreamTLSVersion: "TLS 1.2")
        #expect(tls.downstreamTLSVersion == "TLS 1.3")
        #expect(tls.upstreamTLSVersion == "TLS 1.2")
    }

    @Test func certificateSummaryIsValueEqual() {
        let a = Date(timeIntervalSince1970: 1_000), b = Date(timeIntervalSince1970: 2_000)
        func make(_ serial: String = "0A1B") -> CertificateSummary {
            CertificateSummary(
                subject: "CN=x.com", issuer: "CN=CA", serialNumber: serial,
                sha256Fingerprint: String(repeating: "AB", count: 32), notBefore: a, notAfter: b)
        }
        #expect(make() == make())
        #expect(make() != make("FF"))
        #expect(Set([make(), make()]).count == 1)
    }

    @Test func extendedFieldsDefaultAndOldInitStillWorks() {
        let a = Date(timeIntervalSince1970: 1_000), b = Date(timeIntervalSince1970: 2_000)
        let old = CertificateSummary(
            subject: "CN=x", issuer: "CN=CA", serialNumber: "01", sha256Fingerprint: "AB", notBefore: a, notAfter: b)
        #expect(old.version == nil)
        #expect(old.isTrusted == nil)
        #expect(old.sha1Fingerprint.isEmpty && old.publicKey.isEmpty && old.signature.isEmpty)
        #expect(old.subjectAlternativeNames.isEmpty)
        #expect(old.issuerCommonName.isEmpty && old.issuerOrganization.isEmpty && old.issuerCountry.isEmpty)
        #expect(old.subjectCommonName.isEmpty && old.subjectOrganization.isEmpty && old.subjectCountry.isEmpty)
    }

    @Test func extendedFieldsParticipateInEquality() {
        let a = Date(timeIntervalSince1970: 1_000), b = Date(timeIntervalSince1970: 2_000)
        func make(sans: [String] = ["x.com"], trusted: Bool? = true) -> CertificateSummary {
            CertificateSummary(
                subject: "CN=x", issuer: "CN=CA", serialNumber: "01", sha256Fingerprint: "AB", notBefore: a, notAfter: b,
                version: 3, sha1Fingerprint: "CD", subjectAlternativeNames: sans, isTrusted: trusted)
        }
        #expect(make() == make())
        #expect(make() != make(sans: ["y.com"]))
        #expect(make() != make(trusted: false))
    }
}
