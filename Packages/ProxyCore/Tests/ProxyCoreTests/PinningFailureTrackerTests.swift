import Foundation
import NIOCore
import NIOEmbedded
import NIOSSL
import NIOTLS
import Testing
@testable import ProxyCore

@Suite(.productionChinese) struct PinningFailureTrackerTests {
    @Test func interruptionsRequireTwoNormalizedHostsWithinWindow() {
        let tracker = PinningFailureTracker()
        #expect(!tracker.recordFailure(host: " Example.COM. ", evidence: .interrupted, now: 100))
        #expect(tracker.recordFailure(host: "example.com", evidence: .interrupted, now: 129))
        let expired = PinningFailureTracker()
        #expect(!expired.recordFailure(host: "example.com", evidence: .interrupted, now: 100))
        #expect(!expired.recordFailure(host: "example.com", evidence: .interrupted, now: 131))
    }

    @Test func successAndUnrelatedFailureResetInterruptions() {
        let tracker = PinningFailureTracker()
        #expect(!tracker.recordFailure(host: "example.com", evidence: .interrupted, now: 100))
        tracker.recordSuccess(host: "EXAMPLE.COM.")
        #expect(!tracker.recordFailure(host: "example.com", evidence: .interrupted, now: 101))
        #expect(!tracker.recordFailure(host: "example.com", evidence: .unrelated, now: 102))
        #expect(!tracker.recordFailure(host: "example.com", evidence: .interrupted, now: 103))
        #expect(tracker.recordFailure(host: "example.com", evidence: .interrupted, now: 104))
    }

    @Test func certificateRejectionIsImmediateButUnrelatedNeverAccumulates() {
        let tracker = PinningFailureTracker()
        #expect(tracker.recordFailure(host: "example.com", evidence: .certificateRejected, now: 100))
        #expect(!tracker.recordFailure(host: "other.com", evidence: .unrelated, now: 101))
        #expect(!tracker.recordFailure(host: "other.com", evidence: .unrelated, now: 102))
        #expect(!tracker.recordFailure(host: "other.com", evidence: .interrupted, now: 103))
    }

    @Test func capacityEvictsOldestHost() {
        let tracker = PinningFailureTracker()
        for i in 0..<1025 {
            #expect(!tracker.recordFailure(host: "host\(i).test", evidence: .interrupted, now: 100 + Double(i) / 1000))
        }
        // The first entry has been evicted, while the most recent still qualifies.
        #expect(tracker.recordFailure(host: "host1024.test", evidence: .interrupted, now: 102))
        #expect(!tracker.recordFailure(host: "host0.test", evidence: .interrupted, now: 102))
    }

    @Test func monitorReportsFirstErrorOnly() throws {
        var failures: [Error?] = []
        let channel = EmbeddedChannel(handler: TLSHandshakeMonitor(onCompleted: {}, onFailure: { failures.append($0) }))
        channel.pipeline.fireErrorCaught(TestHandshakeError.original)
        _ = try? channel.finish()
        #expect(failures.count == 1)
        #expect(failures.first as? TestHandshakeError == .original)
    }

    @Test func monitorSuccessSuppressesLaterFailure() throws {
        var completed = 0
        var failed = 0
        let channel = EmbeddedChannel(handler: TLSHandshakeMonitor(onCompleted: { completed += 1 }, onFailure: { _ in failed += 1 }))
        channel.pipeline.fireUserInboundEventTriggered(TLSUserEvent.handshakeCompleted(negotiatedProtocol: nil))
        _ = try channel.finish()
        #expect(completed == 1)
        #expect(failed == 0)
    }

    @Test func monitorInactiveWithoutErrorReportsNilOnce() throws {
        var failures: [Error?] = []
        let channel = EmbeddedChannel(handler: TLSHandshakeMonitor(onCompleted: {}, onFailure: { failures.append($0) }))
        _ = try channel.finish()
        #expect(failures.count == 1)
        #expect(failures[0] == nil)
    }

    @Test func fragmentedHelloAcrossRecordsPreservesBytesAndProvesEvidence() throws {
        let probe = ClientHelloEvidenceProbe()
        let channel = EmbeddedChannel(handler: probe)
        let hello = testClientHelloBytes()
        let split = 13
        let bytes = tlsRecord(Array(hello[..<split])) + tlsRecord(Array(hello[split...]))
        var forwarded: [UInt8] = []
        for byte in bytes {
            try channel.writeInbound(ByteBuffer(bytes: [byte]))
            while let buffer = try channel.readInbound(as: ByteBuffer.self) {
                forwarded.append(contentsOf: buffer.readableBytesView)
            }
        }
        #expect(probe.hasClientHello)
        #expect(forwarded == bytes)
        _ = try channel.finish()
    }

    @Test func malformedTruncatedAndOversizedHelloNeverProveEvidence() throws {
        for bytes in [
            [0x16], [0x16, 0x03, 0x01],
            [0x16, 0x03, 0x03, 0xff, 0xff],
            tlsRecord([0x01, 0xff, 0xff, 0xff]),
            tlsRecord([0x02, 0x00, 0x00, 0x00]),
            tlsRecord([0x01, 0x00, 0x00, 0x01, 0x00]),
            tlsRecord(Array(testClientHelloBytes().dropLast())),
        ] {
            let probe = ClientHelloEvidenceProbe()
            let channel = EmbeddedChannel(handler: probe)
            try channel.writeInbound(ByteBuffer(bytes: bytes))
            #expect(!probe.hasClientHello)
            _ = try channel.finish()
        }
    }

    @Test func onlyHandshakeEOFAndUncleanShutdownAreInterruptions() {
        let eof = NIOSSLError.handshakeFailed(.sslError([.eofDuringHandshake]))
        #expect(TLSInterception.pinningEvidence(for: eof, hasClientHello: true) == .interrupted)
        #expect(TLSInterception.pinningEvidence(for: NIOSSLError.uncleanShutdown, hasClientHello: true) == .interrupted)
        #expect(TLSInterception.pinningEvidence(for: nil, hasClientHello: true) == .interrupted)
        #expect(TLSInterception.pinningEvidence(for: eof, hasClientHello: false) == .unrelated)
        #expect(TLSInterception.pinningEvidence(for: TLSHandshakeTimeout(), hasClientHello: true) == .unrelated)
        #expect(TLSInterception.pinningEvidence(for: NIOSSLError.handshakeFailed(.sslError([])), hasClientHello: true) == .unrelated)
    }
}


private enum TestHandshakeError: Error { case original }
