import Foundation

/// Display-only summary of an X.509 certificate, captured when the upstream handshake completes.
public struct CertificateSummary: Sendable, Equatable, Hashable {
    public var subject: String
    public var issuer: String
    /// Uppercase hexadecimal, no separators.
    public var serialNumber: String
    /// 64 uppercase hexadecimal digits, no colons.
    public var sha256Fingerprint: String
    public var notBefore: Date
    public var notAfter: Date
    /// X.509 version number (1 or 3); nil when unknown.
    public var version: Int?
    /// 40 uppercase hexadecimal digits, no colons; empty when unknown.
    public var sha1Fingerprint: String
    public var issuerCommonName: String
    public var issuerOrganization: String
    public var issuerCountry: String
    public var subjectCommonName: String
    public var subjectOrganization: String
    public var subjectCountry: String
    public var subjectAlternativeNames: [String]
    /// `"<algorithm> <bits> <HEX>"`, for example `"RSA 2048 3082..."`; empty when unknown.
    public var publicKey: String
    /// `"<algorithm> <HEX>"`, for example `"ecdsaWithSHA256 3045..."`; empty when unknown.
    public var signature: String
    /// Result of ProxyWoman's upstream TLS verification: true when the handshake that presented this
    /// certificate was verified against the trust roots (the proxy never completes an unverified upstream
    /// handshake); nil when unknown, in which case only the validity period decides.
    public var isTrusted: Bool?

    public init(
        subject: String, issuer: String, serialNumber: String, sha256Fingerprint: String,
        notBefore: Date, notAfter: Date, version: Int? = nil, sha1Fingerprint: String = "",
        issuerCommonName: String = "", issuerOrganization: String = "", issuerCountry: String = "",
        subjectCommonName: String = "", subjectOrganization: String = "", subjectCountry: String = "",
        subjectAlternativeNames: [String] = [], publicKey: String = "", signature: String = "",
        isTrusted: Bool? = nil
    ) {
        self.version = version
        self.sha1Fingerprint = sha1Fingerprint
        self.issuerCommonName = issuerCommonName
        self.issuerOrganization = issuerOrganization
        self.issuerCountry = issuerCountry
        self.subjectCommonName = subjectCommonName
        self.subjectOrganization = subjectOrganization
        self.subjectCountry = subjectCountry
        self.subjectAlternativeNames = subjectAlternativeNames
        self.publicKey = publicKey
        self.signature = signature
        self.isTrusted = isTrusted
        self.subject = subject
        self.issuer = issuer
        self.serialNumber = serialNumber
        self.sha256Fingerprint = sha256Fingerprint
        self.notBefore = notBefore
        self.notAfter = notAfter
    }
}
