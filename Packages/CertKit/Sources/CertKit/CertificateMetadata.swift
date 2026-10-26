import Foundation
import Security
import X509

/// Public certificate information only; parsing never needs a CA private key.
public struct CertificateMetadata: Sendable {
    public let commonName: String
    public let serialNumberPrefix: String
    public let validFrom: Date
    public let validUntil: Date

    public init(pemEncoded: String) throws {
        let certificate = try Certificate(pemEncoded: pemEncoded)
        let der = try certificate.serializeAsPEM().derBytes
        guard let sec = SecCertificateCreateWithData(nil, Data(der) as CFData) else {
            throw TrustError.invalidCertificate
        }
        commonName = SecCertificateCopySubjectSummary(sec) as String? ?? String(describing: certificate.subject)
        serialNumberPrefix = String(
            certificate.serialNumber.bytes.map { String(format: "%02X", $0) }.joined().prefix(8))
        validFrom = certificate.notValidBefore
        validUntil = certificate.notValidAfter
    }
}
