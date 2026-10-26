import FlowStore
import Foundation

/// What a certificate sub-item holds, which decides its comparison set and value control.
public enum CertificateFieldKind: String, Sendable, Equatable {
    /// valid / invalid, no value.
    case validity
    /// An integer (the set of number comparisons).
    case number
    /// A calendar date (the set of date comparisons, date picker).
    case date
    case text
}

/// One value read from a certificate. `unknown` means the connection has no such fact (no certificate
/// captured, or the field was not read), which never matches.
public enum CertificateFieldValue: Sendable, Equatable {
    case text(String)
    case number(Int)
    case date(Date)
    case bool(Bool)
    case unknown
}

/// The 17 certificate sub-items of the "Certificate information" condition (spec section 12.4), in menu
/// order. Raw values are stable condition keys and append-only. `group` is the menu section (separator
/// lines fall between groups).
public enum CertificateField: String, CaseIterable, Sendable {
    // Group 0
    case friendlyName, version, serialNumber
    // Group 1
    case expirationDate, validity, issueDate
    // Group 2
    case signature, publicKey, sha1Fingerprint, sha256Fingerprint
    // Group 3
    case issuerCommonName, issuerCountry, issuerOrganization
    // Group 4
    case subjectCommonName, subjectAlternativeName, subjectCountry, subjectOrganization

    /// The default sub-item of a new certificate condition.
    public static let `default`: CertificateField = .friendlyName

    public var group: Int {
        switch self {
        case .friendlyName, .version, .serialNumber: 0
        case .expirationDate, .validity, .issueDate: 1
        case .signature, .publicKey, .sha1Fingerprint, .sha256Fingerprint: 2
        case .issuerCommonName, .issuerCountry, .issuerOrganization: 3
        case .subjectCommonName, .subjectAlternativeName, .subjectCountry, .subjectOrganization: 4
        }
    }

    public var valueKind: CertificateFieldKind {
        switch self {
        case .validity: .validity
        case .version: .number
        case .expirationDate, .issueDate: .date
        default: .text
        }
    }

    /// The field behind a condition key, matching case-insensitively; nil for anything else (including
    /// the legacy keys, see ``LegacyCertificateKey``).
    public init?(conditionKey: String) {
        let lowered = conditionKey.lowercased()
        guard let match = Self.allCases.first(where: { $0.rawValue.lowercased() == lowered }) else { return nil }
        self = match
    }

    /// The value of this item in `certificate`. `now` is only used by ``validity``.
    ///
    /// - friendlyName: always empty text (R8F2-4: macOS server certificates have no friendly name).
    /// - validity: `.bool(true)` when the upstream TLS verification did not fail (`isTrusted != false`)
    ///   and `now` lies within `notBefore...notAfter`.
    /// - Facts the capture did not fill (version, SHA-1, public key, signature) read as `.unknown`;
    ///   an absent name part (for example a certificate without a country) reads as empty text.
    public func value(in certificate: CertificateSummary, now: Date) -> CertificateFieldValue {
        switch self {
        case .friendlyName: return .text("")
        case .version: return certificate.version.map { .number($0) } ?? .unknown
        case .serialNumber: return .text(certificate.serialNumber)
        case .expirationDate: return .date(certificate.notAfter)
        case .validity:
            let inPeriod = certificate.notBefore <= now && now <= certificate.notAfter
            return .bool(certificate.isTrusted != false && inPeriod)
        case .issueDate: return .date(certificate.notBefore)
        case .signature: return Self.captured(certificate.signature)
        case .publicKey: return Self.captured(certificate.publicKey)
        case .sha1Fingerprint: return Self.captured(certificate.sha1Fingerprint)
        case .sha256Fingerprint: return .text(certificate.sha256Fingerprint)
        case .issuerCommonName: return .text(certificate.issuerCommonName)
        case .issuerCountry: return .text(certificate.issuerCountry)
        case .issuerOrganization: return .text(certificate.issuerOrganization)
        case .subjectCommonName: return .text(certificate.subjectCommonName)
        case .subjectAlternativeName: return .text(certificate.subjectAlternativeNames.joined(separator: ", "))
        case .subjectCountry: return .text(certificate.subjectCountry)
        case .subjectOrganization: return .text(certificate.subjectOrganization)
        }
    }

    /// Every text a text comparison may test: one entry, except the alternative names which are tested one
    /// by one (any matching name matches). Empty for non-text items.
    public func textCandidates(in certificate: CertificateSummary) -> [String] {
        guard valueKind == .text else { return [] }
        if self == .subjectAlternativeName { return certificate.subjectAlternativeNames }
        if case .text(let text) = value(in: certificate, now: .distantPast) { return [text] }
        return []
    }

    private static func captured(_ text: String) -> CertificateFieldValue { text.isEmpty ? .unknown : .text(text) }
}

/// The six sub-keys of the original certificate condition, still read as before. Raw values are the
/// stored keys.
public enum LegacyCertificateKey: String, CaseIterable, Sendable {
    case subject, issuer, serialNumber, sha256Fingerprint, notBefore, notAfter

    public init?(conditionKey: String) {
        let lowered = conditionKey.lowercased()
        guard let match = Self.allCases.first(where: { $0.rawValue.lowercased() == lowered }) else { return nil }
        self = match
    }

    /// The new sub-item showing the same fact, nil for subject and issuer (whole distinguished names,
    /// which have no single new item).
    public var field: CertificateField? {
        switch self {
        case .subject, .issuer: nil
        case .serialNumber: .serialNumber
        case .sha256Fingerprint: .sha256Fingerprint
        case .notBefore: .issueDate
        case .notAfter: .expirationDate
        }
    }

    /// The text the original condition compared: the names and hex as stored, dates as UTC
    /// `yyyy-MM-dd'T'HH:mm:ss'Z'` (identical to the evaluator's historic reading).
    public func text(in certificate: CertificateSummary) -> String {
        switch self {
        case .subject: certificate.subject
        case .issuer: certificate.issuer
        case .serialNumber: certificate.serialNumber
        case .sha256Fingerprint: certificate.sha256Fingerprint
        case .notBefore: certificate.notBefore.formatted(.iso8601)
        case .notAfter: certificate.notAfter.formatted(.iso8601)
        }
    }
}
