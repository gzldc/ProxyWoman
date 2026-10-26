import Crypto
import Foundation
import SwiftASN1
import X509

/// Public facts of a peer's certificate, read from its DER encoding. Display and rule matching only:
/// nothing here validates the certificate (the TLS handshake already did).
public struct PeerCertificateInfo: Sendable, Equatable {
    public var subject: String
    public var issuer: String
    /// Uppercase hexadecimal, no separators.
    public var serialNumber: String
    /// SHA-256 of the DER bytes: 64 uppercase hexadecimal digits, no colons.
    public var sha256Fingerprint: String
    public var notBefore: Date
    public var notAfter: Date
    /// X.509 version number: 1 or 3 (nil for a version this reader does not know).
    public var version: Int?
    /// SHA-1 of the DER bytes: 40 uppercase hexadecimal digits, no colons.
    public var sha1Fingerprint: String
    public var issuerCommonName: String
    public var issuerOrganization: String
    public var issuerCountry: String
    public var subjectCommonName: String
    public var subjectOrganization: String
    public var subjectCountry: String
    /// DNS names, e-mail addresses, URIs and IP addresses of the subjectAltName extension, in order.
    public var subjectAlternativeNames: [String]
    /// `"<algorithm> <bits> <HEX>"`: algorithm `RSA`/`P256`/`P384`/`P521`/`Ed25519`, key size in bits,
    /// then the key bytes (the subjectPublicKey BIT STRING content) in uppercase hexadecimal.
    public var publicKey: String
    /// `"<algorithm> <HEX>"`: algorithm name such as `ecdsaWithSHA256`, then the signature bytes in uppercase hexadecimal.
    public var signature: String

    public init(der: [UInt8]) throws {
        let certificate = try Certificate(derEncoded: der)
        subject = String(describing: certificate.subject)
        issuer = String(describing: certificate.issuer)
        serialNumber = Self.hex(certificate.serialNumber.bytes)
        sha256Fingerprint = Self.hex(SHA256.hash(data: der))
        notBefore = certificate.notValidBefore
        notAfter = certificate.notValidAfter
        version = certificate.version == .v1 ? 1 : (certificate.version == .v3 ? 3 : nil)
        sha1Fingerprint = Self.hex(Insecure.SHA1.hash(data: der))
        issuerCommonName = Self.attribute(ASN1ObjectIdentifier.RDNAttributeType.commonName, in: certificate.issuer)
        issuerOrganization = Self.attribute(ASN1ObjectIdentifier.RDNAttributeType.organizationName, in: certificate.issuer)
        issuerCountry = Self.attribute(ASN1ObjectIdentifier.RDNAttributeType.countryName, in: certificate.issuer)
        subjectCommonName = Self.attribute(ASN1ObjectIdentifier.RDNAttributeType.commonName, in: certificate.subject)
        subjectOrganization = Self.attribute(ASN1ObjectIdentifier.RDNAttributeType.organizationName, in: certificate.subject)
        subjectCountry = Self.attribute(ASN1ObjectIdentifier.RDNAttributeType.countryName, in: certificate.subject)
        subjectAlternativeNames = Self.alternativeNames(of: certificate)
        publicKey = Self.describe(certificate.publicKey)
        signature = Self.describe(
            signatureAlgorithm: String(describing: certificate.signatureAlgorithm),
            bytes: certificate.signature.rawRepresentation)
    }

    private static let hexDigits = Array("0123456789ABCDEF".utf8)

    /// Uppercase hexadecimal through a lookup table (runs once per upstream connection, on its event loop).
    static func hex<Bytes: Sequence>(_ bytes: Bytes) -> String where Bytes.Element == UInt8 {
        var out = [UInt8]()
        out.reserveCapacity(bytes.underestimatedCount * 2)
        for byte in bytes {
            out.append(hexDigits[Int(byte >> 4)])
            out.append(hexDigits[Int(byte & 0x0F)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// `"<name> <HEX>"`; a description without the `SignatureAlgorithm.` prefix (an algorithm this reader
    /// has no name for) reads as `"unknown <HEX>"`.
    static func describe(signatureAlgorithm description: String, bytes: [UInt8]) -> String {
        let prefix = "SignatureAlgorithm."
        let name = description.hasPrefix(prefix) && description.count > prefix.count
            ? String(description.dropFirst(prefix.count)) : "unknown"
        return name + " " + hex(bytes)
    }

    /// First value of attribute `type` in `name`, or "" when absent or not a text string.
    private static func attribute(_ type: ASN1ObjectIdentifier, in name: DistinguishedName) -> String {
        for rdn in name {
            for attribute in rdn where attribute.type == type {
                if let text = String(attribute.value) { return text }
            }
        }
        return ""
    }

    private static func alternativeNames(of certificate: Certificate) -> [String] {
        guard let names = (try? certificate.extensions.subjectAlternativeNames) ?? nil else { return [] }
        return names.compactMap { name -> String? in
            switch name {
            case .dnsName(let value), .rfc822Name(let value), .uniformResourceIdentifier(let value): value
            case .ipAddress(let octets): ipText(Array(octets.bytes))
            default: nil
            }
        }
    }

    private static func ipText(_ bytes: [UInt8]) -> String? {
        switch bytes.count {
        case 4: return bytes.map(String.init).joined(separator: ".")
        case 16:
            return stride(from: 0, to: 16, by: 2).map { String(format: "%x", Int(bytes[$0]) << 8 | Int(bytes[$0 + 1])) }
                .joined(separator: ":")
        default: return nil
        }
    }

    /// swift-certificates names the `subjectPublicKey` BIT STRING content `subjectPublicKeyInfoBytes` (not the whole
    /// SubjectPublicKeyInfo): an EC point `04 || X || Y`, or the RSA key's `SEQUENCE { modulus, exponent }`. That is the
    /// public key a certificate viewer shows; the algorithm and size are already in the text before it.
    private static func describe(_ key: Certificate.PublicKey) -> String {
        describe(keyDescription: String(describing: key), bytes: key.subjectPublicKeyInfoBytes)
    }

    /// `"<ALGO> <bits> <HEX>"` from the key's description (`P256.PublicKey`, `RSA2048.PublicKey`,
    /// `Ed25519.PublicKey`); a description that names no known algorithm or size reads as `"unknown <HEX>"`.
    static func describe<Bytes: Sequence>(keyDescription name: String, bytes: Bytes) -> String
    where Bytes.Element == UInt8 {
        let base = name.hasSuffix(".PublicKey") ? String(name.dropLast(".PublicKey".count)) : name
        var algorithm: String?, bits: Int?
        if base.hasPrefix("RSA"), let size = Int(base.dropFirst(3)), size > 0 {
            (algorithm, bits) = ("RSA", size)
        } else {
            switch base {
            case "P256": (algorithm, bits) = ("P256", 256)
            case "P384": (algorithm, bits) = ("P384", 384)
            case "P521": (algorithm, bits) = ("P521", 521)
            case "Ed25519": (algorithm, bits) = ("Ed25519", 256)
            default: break
            }
        }
        guard let algorithm, let bits else { return "unknown " + hex(bytes) }
        return [algorithm, String(bits), hex(bytes)].joined(separator: " ")
    }
}
