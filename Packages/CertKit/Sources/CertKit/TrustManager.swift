import Foundation
import Security

public enum TrustError: Error, Equatable, Sendable, LocalizedError {
    case keychainAdd(OSStatus)
    case trustSettings(OSStatus)
    case invalidCertificate

    /// The system's own message for the OSStatus (untranslated), when it has one.
    public var systemDetail: String? {
        switch self {
        case .keychainAdd(let status), .trustSettings(let status):
            guard let text = SecCopyErrorMessageString(status, nil) as String?, !text.isEmpty else { return nil }
            return text
        case .invalidCertificate:
            return nil
        }
    }

    /// An English diagnostic for logs and `localizedDescription`. The app shows localized text
    /// built from the case, the OSStatus and `systemDetail`.
    public var message: String {
        let detail = systemDetail.map { ": \($0)" } ?? ""
        switch self {
        case .keychainAdd(let status):
            return "Couldn't add the certificate to the keychain (OSStatus \(status))" + detail
        case .trustSettings(let status):
            return "Couldn't set certificate trust (OSStatus \(status)); authorization may have been cancelled" + detail
        case .invalidCertificate:
            return "The certificate data is invalid"
        }
    }

    public var errorDescription: String? { message }
}

/// Root certificate trust: query, install and remove. Only `isTrusted` is cheap and silent.
public enum TrustManager {
    /// The host of the leaf `isTrusted` evaluates; `.invalid` never resolves.
    static let trustCheckHost = "trust-check.invalid"

    /// Whether browsers would accept certificates `ca` issues: evaluates a leaf for
    /// `trustCheckHost`, chained to the root, under the SSL server policy for that host with the
    /// system's anchors and trust settings (any domain), no custom anchors and no network fetches.
    /// Safe to call from any thread; never shows UI.
    public static func isTrusted(ca: CertificateAuthority) -> Bool {
        evaluate(ca: ca, anchors: nil)
    }

    /// `anchors`, when given, replace the system's anchors (for tests).
    static func evaluate(ca: CertificateAuthority, anchors: [SecCertificate]?) -> Bool {
        guard let leaf = try? ca.leaf(for: trustCheckHost),
            let leafCertificate = makeCertificate(leaf.certificateDER),
            let root = makeCertificate(ca.rootCertificateDER)
        else { return false }
        var trust: SecTrust?
        let status = SecTrustCreateWithCertificates(
            [leafCertificate, root] as CFArray, SecPolicyCreateSSL(true, trustCheckHost as CFString), &trust)
        guard status == errSecSuccess, let trust else { return false }
        SecTrustSetNetworkFetchAllowed(trust, false)
        if let anchors {
            SecTrustSetAnchorCertificates(trust, anchors as CFArray)
            SecTrustSetAnchorCertificatesOnly(trust, true)
        }
        return SecTrustEvaluateWithError(trust, nil)
    }

    /// Trust as a root for the SSL policy only, not for code signing, S/MIME and the rest.
    static func sslTrustSettings() -> CFArray {
        let settings: [[String: Any]] = [
            [
                kSecTrustSettingsPolicy: SecPolicyCreateSSL(true, nil),
                kSecTrustSettingsResult: NSNumber(value: SecTrustSettingsResult.trustRoot.rawValue),
            ]
        ]
        return settings as CFArray
    }

    /// Adds the root to the login keychain (an existing copy counts as success) and marks it
    /// trusted as a root for SSL in the user trust domain.
    ///
    /// This call is synchronous and blocks while macOS shows its own password dialog, so callers
    /// must not invoke it on the main thread.
    public static func installAndTrust(rootDER: [UInt8]) throws {
        guard let certificate = makeCertificate(rootDER) else { throw TrustError.invalidCertificate }

        let addStatus = SecItemAdd(
            [kSecClass: kSecClassCertificate, kSecValueRef: certificate] as CFDictionary, nil)
        guard addStatus == errSecSuccess || addStatus == errSecDuplicateItem else {
            throw TrustError.keychainAdd(addStatus)
        }

        let trustStatus = SecTrustSettingsSetTrustSettings(certificate, .user, sslTrustSettings())
        guard trustStatus == errSecSuccess else { throw TrustError.trustSettings(trustStatus) }
    }

    /// Removes the user-domain trust settings for the root. The keychain item is left in place;
    /// a certificate that has no trust settings counts as success.
    ///
    /// Like `installAndTrust`, this may block on a system authorization dialog; call it off the
    /// main thread.
    public static func removeTrust(rootDER: [UInt8]) throws {
        guard let certificate = makeCertificate(rootDER) else { throw TrustError.invalidCertificate }
        let status = SecTrustSettingsRemoveTrustSettings(certificate, .user)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw TrustError.trustSettings(status)
        }
    }

    private static func makeCertificate(_ der: [UInt8]) -> SecCertificate? {
        SecCertificateCreateWithData(nil, Data(der) as CFData)
    }
}
