import FlowStore
import Foundation
import Testing
@testable import ProxyCore

@Suite(.productionChinese) struct RecordingTests {
    @Test func pausedRecordingStillProxiesAndRecordsNothing() async throws {
        let setup = try HTTPSSetup()
        let plainOrigin = try await TestOriginServer.start()
        do {
            try await pausedTraffic(setup: setup, plainOrigin: plainOrigin)
        } catch {
            try? await plainOrigin.stop()
            throw error
        }
        try await plainOrigin.stop()
    }

    /// Plain HTTP, decrypted HTTPS and a raw CONNECT tunnel, all while recording is paused.
    private func pausedTraffic(setup: HTTPSSetup, plainOrigin: TestOriginServer) async throws {
        try await setup.run { fx in
            fx.server.updateConfiguration { $0.recordingEnabled = false }

            let plain = try curl(["-x", fx.proxyURL, "http://localhost:\(plainOrigin.port)/hello"])
            #expect(plain.exitCode == 0, "\(plain.stderr)")
            #expect(plain.text == "hello")

            let https = try curl([
                "-x", fx.proxyURL, "--cacert", setup.proxyCAFile, "https://localhost:\(fx.origin.port)/json",
            ])
            #expect(https.exitCode == 0, "\(https.stderr)")
            #expect(https.text == #"{"b":1,"a":[true,null]}"#)

            // CONNECT followed by plain HTTP: relayed untouched as a tunnel.
            let tunneled = try curl(["-p", "-x", fx.proxyURL, "http://localhost:\(plainOrigin.port)/hello"])
            #expect(tunneled.exitCode == 0, "\(tunneled.stderr)")
            #expect(tunneled.text == "hello")

            #expect(fx.store.allFlows().isEmpty)
            #expect(fx.server.trafficTotals().bytesDown > 0)
        }
    }

    @Test func pausedRecordingStillLearnsPinnedHosts() async throws {
        let setup = try HTTPSSetup()
        try await setup.run(configure: {
            $0.autoPassthroughOnHandshakeFailure = true
            $0.recordingEnabled = false
        }) { fx in
            let url = "https://localhost:\(fx.origin.port)/hello"
            // The client only trusts B, so it rejects the A-signed interception certificate.
            let first = try curl(["-x", fx.proxyURL, "--cacert", setup.originCAFile, url])
            #expect([35, 60].contains(first.exitCode), "\(first.exitCode) \(first.stderr)")
            try await waitUntil("localhost in the passthrough list") { fx.passthrough.contains("localhost") }

            let second = try curl(["-x", fx.proxyURL, "--cacert", setup.originCAFile, url])
            #expect(second.exitCode == 0, "\(second.stderr)")
            #expect(second.text == "hello")
            #expect(fx.store.allFlows().isEmpty)
        }
    }

    @Test func resumingRecordingRecordsNewExchanges() async throws {
        try await ProxyFixture.run(configure: { $0.recordingEnabled = false }) { fx in
            let url = "http://localhost:\(fx.origin.port)/hello"
            let paused = try curl(["-x", fx.proxyURL, url])
            #expect(paused.exitCode == 0, "\(paused.stderr)")
            #expect(fx.store.allFlows().isEmpty)

            fx.server.updateConfiguration { $0.recordingEnabled = true }
            let resumed = try curl(["-x", fx.proxyURL, url])
            #expect(resumed.exitCode == 0, "\(resumed.stderr)")
            let f = try await waitForFlow(fx.store) { $0.state == .completed }
            #expect(f.path == "/hello")
            #expect(fx.store.allFlows().count == 1)
        }
    }

    @Test func trafficTotalsCountBothDirections() async throws {
        try await ProxyFixture.run { fx in
            #expect(fx.server.trafficTotals() == TrafficTotals(bytesUp: 0, bytesDown: 0))
            let r = try curl(["-x", fx.proxyURL, "http://localhost:\(fx.origin.port)/big?mb=2"])
            #expect(r.exitCode == 0, "\(r.stderr)")
            #expect(r.stdout.count == 2 << 20)
            let totals = fx.server.trafficTotals()
            #expect(totals.bytesDown >= 2 << 20)
            #expect(totals.bytesUp > 0)
        }
    }
}
