import FlowStore
import Foundation
import Testing

@testable import RulesEngine

@Suite struct CertificateFieldsTests {
    static let before = Date(timeIntervalSince1970: 1_000_000)
    static let after = Date(timeIntervalSince1970: 2_000_000)

    static func summary(trusted: Bool? = true) -> CertificateSummary {
        CertificateSummary(
            subject: "CN=a.test, O=Acme, C=US", issuer: "CN=Root, O=Rootco, C=DE", serialNumber: "0A1B",
            sha256Fingerprint: "AB", notBefore: before, notAfter: after, version: 3, sha1Fingerprint: "CD",
            issuerCommonName: "Root", issuerOrganization: "Rootco", issuerCountry: "DE",
            subjectCommonName: "a.test", subjectOrganization: "Acme", subjectCountry: "US",
            subjectAlternativeNames: ["a.test", "b.test"], publicKey: "RSA 2048 00", signature: "sha256WithRSAEncryption 11",
            isTrusted: trusted)
    }

    @Test func seventeenItemsInMenuOrderWithStableRawValues() {
        #expect(CertificateField.allCases.map(\.rawValue) == [
            "friendlyName", "version", "serialNumber", "expirationDate", "validity", "issueDate", "signature",
            "publicKey", "sha1Fingerprint", "sha256Fingerprint", "issuerCommonName", "issuerCountry",
            "issuerOrganization", "subjectCommonName", "subjectAlternativeName", "subjectCountry",
            "subjectOrganization",
        ])
        #expect(CertificateField.default == .friendlyName)
    }

    @Test func groupsAndKinds() {
        let groups = CertificateField.allCases.map(\.group)
        #expect(groups == [0, 0, 0, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 4, 4, 4, 4])
        #expect(groups == groups.sorted())
        #expect(CertificateField.validity.valueKind == .validity)
        #expect(CertificateField.version.valueKind == .number)
        #expect(CertificateField.expirationDate.valueKind == .date)
        #expect(CertificateField.issueDate.valueKind == .date)
        for field in CertificateField.allCases where ![.validity, .version, .expirationDate, .issueDate].contains(field) {
            #expect(field.valueKind == .text, "\(field)")
        }
    }

    @Test func readsEveryValue() {
        let c = Self.summary(), now = Date(timeIntervalSince1970: 1_500_000)
        func v(_ f: CertificateField) -> CertificateFieldValue { f.value(in: c, now: now) }
        #expect(v(.friendlyName) == .text(""))
        #expect(v(.version) == .number(3))
        #expect(v(.serialNumber) == .text("0A1B"))
        #expect(v(.expirationDate) == .date(Self.after))
        #expect(v(.issueDate) == .date(Self.before))
        #expect(v(.validity) == .bool(true))
        #expect(v(.signature) == .text("sha256WithRSAEncryption 11"))
        #expect(v(.publicKey) == .text("RSA 2048 00"))
        #expect(v(.sha1Fingerprint) == .text("CD"))
        #expect(v(.sha256Fingerprint) == .text("AB"))
        #expect(v(.issuerCommonName) == .text("Root"))
        #expect(v(.issuerCountry) == .text("DE"))
        #expect(v(.issuerOrganization) == .text("Rootco"))
        #expect(v(.subjectCommonName) == .text("a.test"))
        #expect(v(.subjectAlternativeName) == .text("a.test, b.test"))
        #expect(v(.subjectCountry) == .text("US"))
        #expect(v(.subjectOrganization) == .text("Acme"))
    }

    @Test func validityNeedsPeriodAndTrust() {
        let inside = Date(timeIntervalSince1970: 1_500_000)
        #expect(CertificateField.validity.value(in: Self.summary(), now: Self.before) == .bool(true))
        #expect(CertificateField.validity.value(in: Self.summary(), now: Self.after) == .bool(true))
        #expect(CertificateField.validity.value(in: Self.summary(), now: Self.before - 1) == .bool(false))
        #expect(CertificateField.validity.value(in: Self.summary(), now: Self.after + 1) == .bool(false))
        #expect(CertificateField.validity.value(in: Self.summary(trusted: false), now: inside) == .bool(false))
        #expect(CertificateField.validity.value(in: Self.summary(trusted: nil), now: inside) == .bool(true))
    }

    @Test func uncapturedFactsAreUnknown() {
        let bare = CertificateSummary(
            subject: "s", issuer: "i", serialNumber: "01", sha256Fingerprint: "FF", notBefore: Self.before, notAfter: Self.after)
        let now = Date(timeIntervalSince1970: 1_500_000)
        for f in [CertificateField.version, .signature, .publicKey, .sha1Fingerprint] {
            #expect(f.value(in: bare, now: now) == .unknown, "\(f)")
        }
        #expect(CertificateField.issuerCountry.value(in: bare, now: now) == .text(""))
        #expect(CertificateField.subjectAlternativeName.value(in: bare, now: now) == .text(""))
    }

    @Test func textCandidatesTestAlternativeNamesOneByOne() {
        let c = Self.summary()
        #expect(CertificateField.subjectAlternativeName.textCandidates(in: c) == ["a.test", "b.test"])
        #expect(CertificateField.issuerCommonName.textCandidates(in: c) == ["Root"])
        #expect(CertificateField.validity.textCandidates(in: c) == [])
        #expect(CertificateField.expirationDate.textCandidates(in: c) == [])
    }

    @Test func conditionKeyLookupIgnoresCase() {
        #expect(CertificateField(conditionKey: "SHA1FINGERPRINT") == .sha1Fingerprint)
        #expect(CertificateField(conditionKey: "subject") == nil)
        #expect(LegacyCertificateKey(conditionKey: "NotAfter") == .notAfter)
        #expect(LegacyCertificateKey(conditionKey: "validity") == nil)
    }

    @Test func legacyKeysMapAndReadAsBefore() {
        let c = Self.summary()
        #expect(LegacyCertificateKey.allCases.map(\.rawValue) == [
            "subject", "issuer", "serialNumber", "sha256Fingerprint", "notBefore", "notAfter",
        ])
        #expect(LegacyCertificateKey.subject.field == nil)
        #expect(LegacyCertificateKey.issuer.field == nil)
        #expect(LegacyCertificateKey.serialNumber.field == .serialNumber)
        #expect(LegacyCertificateKey.sha256Fingerprint.field == .sha256Fingerprint)
        #expect(LegacyCertificateKey.notBefore.field == .issueDate)
        #expect(LegacyCertificateKey.notAfter.field == .expirationDate)
        #expect(LegacyCertificateKey.subject.text(in: c) == "CN=a.test, O=Acme, C=US")
        #expect(LegacyCertificateKey.issuer.text(in: c) == "CN=Root, O=Rootco, C=DE")
        #expect(LegacyCertificateKey.serialNumber.text(in: c) == "0A1B")
        #expect(LegacyCertificateKey.sha256Fingerprint.text(in: c) == "AB")
        #expect(LegacyCertificateKey.notBefore.text(in: c) == Self.before.formatted(.iso8601))
        #expect(LegacyCertificateKey.notAfter.text(in: c) == Self.after.formatted(.iso8601))
    }
}
