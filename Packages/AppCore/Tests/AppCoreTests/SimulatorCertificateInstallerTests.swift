import Foundation
import os
import Testing

@testable import AppCore

struct SimulatorCertificateInstallerTests {
    static let listing = """
    {"devices":{
      "com.apple.CoreSimulator.SimRuntime.iOS-18-2":[
        {"udid":"AAA","name":"iPhone 16","state":"Booted","isAvailable":true},
        {"udid":"BBB","name":"iPhone SE","state":"Shutdown","isAvailable":true}],
      "com.apple.CoreSimulator.SimRuntime.watchOS-11-0":[]
    }}
    """

    final class Calls: Sendable {
        let log = OSAllocatedUnfairLock<[[String]]>(initialState: [])
        var all: [[String]] { log.withLock { $0 } }
    }

    @Test func installsIntoEveryBootedSimulator() throws {
        let calls = Calls()
        let installer = SimulatorCertificateInstaller { arguments in
            calls.log.withLock { $0.append(arguments) }
            return arguments.contains("list") ? (0, Self.listing, "") : (0, "", "")
        }
        let outcome = try installer.install(certificate: URL(fileURLWithPath: "/tmp/ca.pem"))
        #expect(outcome == .installed([.init(udid: "AAA", name: "iPhone 16", runtime: "iOS 18.2")]))
        #expect(calls.all == [
            ["simctl", "list", "devices", "booted", "--json"],
            ["simctl", "keychain", "AAA", "add-root-cert", "/tmp/ca.pem"],
        ])
    }

    @Test func reportsWhenNoSimulatorIsRunning() throws {
        let installer = SimulatorCertificateInstaller { _ in (0, #"{"devices":{}}"#, "") }
        #expect(try installer.install(certificate: URL(fileURLWithPath: "/tmp/ca.pem")) == .noBootedSimulator)
    }

    @Test func simctlFailureCarriesItsMessage() {
        let installer = SimulatorCertificateInstaller { arguments in
            arguments.contains("list") ? (0, Self.listing, "") : (1, "", "Unable to add root certificate\n")
        }
        #expect(throws: SimulatorCertificateInstaller.Failure(message: "iPhone 16: Unable to add root certificate")) {
            try installer.install(certificate: URL(fileURLWithPath: "/tmp/ca.pem"))
        }
    }

    @Test func missingXcodeToolsAreAFailureNotACrash() {
        let installer = SimulatorCertificateInstaller { _ in (72, "", "xcrun: error: unable to find utility \"simctl\"") }
        #expect(throws: SimulatorCertificateInstaller.Failure.self) {
            try installer.install(certificate: URL(fileURLWithPath: "/tmp/ca.pem"))
        }
    }
}
