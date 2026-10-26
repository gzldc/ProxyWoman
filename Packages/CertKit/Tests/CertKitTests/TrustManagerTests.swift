import Foundation
import Security
import Testing

@testable import CertKit

// installAndTrust / removeTrust are deliberately not exercised here: they change the real
// keychain trust settings and show a system password dialog. They are verified by hand (Task 19).
@Suite struct TrustManagerTests {
    @Test func freshCAIsNotTrusted() throws {
        let ca = try CertificateAuthority.generate()
        #expect(TrustManager.isTrusted(ca: ca) == false)
    }

    /// The check is what a browser does: a leaf issued by the root, under the SSL policy for its
    /// host. With the root as the only anchor (instead of the user's trust settings) it passes.
    @Test func issuedLeafPassesTheSSLPolicyWhenTheRootIsAnchored() throws {
        let ca = try CertificateAuthority.generate()
        let root = try #require(SecCertificateCreateWithData(nil, Data(ca.rootCertificateDER) as CFData))
        #expect(TrustManager.evaluate(ca: ca, anchors: [root]))

        let other = try CertificateAuthority.generate()
        let otherRoot = try #require(SecCertificateCreateWithData(nil, Data(other.rootCertificateDER) as CFData))
        #expect(!TrustManager.evaluate(ca: ca, anchors: [otherRoot]))
    }

    @Test func trustSettingsAreLimitedToSSL() throws {
        let settings = try #require(TrustManager.sslTrustSettings() as? [[String: Any]])
        #expect(settings.count == 1)
        let entry = try #require(settings.first)
        let policy = try #require(entry[kSecTrustSettingsPolicy])
        let properties = try #require(SecPolicyCopyProperties(policy as! SecPolicy) as? [String: Any])
        #expect(properties[kSecPolicyOid as String] as? String == kSecPolicyAppleSSL as String)
        #expect(
            (entry[kSecTrustSettingsResult] as? NSNumber)?.uint32Value
                == SecTrustSettingsResult.trustRoot.rawValue)
    }

    @Test func errorMessagesAreEnglishAndCarryStatus() {
        #expect(TrustError.invalidCertificate.message == "The certificate data is invalid")
        #expect(TrustError.keychainAdd(-25299).message.hasPrefix("Couldn't add the certificate to the keychain (OSStatus -25299)"))
        #expect(TrustError.trustSettings(-60007).message.hasPrefix("Couldn't set certificate trust (OSStatus -60007)"))
        #expect(TrustError.trustSettings(-128).localizedDescription == TrustError.trustSettings(-128).message)
    }
}
