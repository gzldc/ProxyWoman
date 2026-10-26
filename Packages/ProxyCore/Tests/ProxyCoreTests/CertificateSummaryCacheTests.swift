import FlowStore
import Foundation
import Testing
@testable import ProxyCore

/// One parsed summary per certificate, shared by the flows that saw it (final review: per-flow memory).
@Suite(.productionChinese) struct CertificateSummaryCacheTests {
    private func summary(_ serial: String) -> CertificateSummary {
        CertificateSummary(
            subject: "CN=a", issuer: "CN=b", serialNumber: serial, sha256Fingerprint: "AA", notBefore: .distantPast,
            notAfter: .distantFuture, publicKey: "RSA 2048 3082", signature: "sha256WithRSAEncryption 00", isTrusted: true)
    }

    @Test func aStoredSummaryIsFoundByFingerprintOnly() {
        let cache = CertificateSummaryCache()
        #expect(cache.summary(for: [1, 2, 3]) == nil)
        cache.store(summary("01"), for: [1, 2, 3])
        #expect(cache.summary(for: [1, 2, 3]) == summary("01"))
        #expect(cache.summary(for: [1, 2, 4]) == nil)
    }

    @Test func theCacheIsBoundedAndStartsOverWhenFull() {
        let cache = CertificateSummaryCache()
        for index in 0..<CertificateSummaryCache.capacity {
            cache.store(summary("\(index)"), for: [UInt8(index & 0xFF), UInt8(index >> 8)])
        }
        #expect(cache.count == CertificateSummaryCache.capacity)
        cache.store(summary("new"), for: [9, 9, 9])
        #expect(cache.count == 1)
        #expect(cache.summary(for: [9, 9, 9]) == summary("new"))
    }
}
