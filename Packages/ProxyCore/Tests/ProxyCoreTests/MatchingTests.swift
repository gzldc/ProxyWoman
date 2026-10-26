import Foundation
import Testing
import NIOCore
@testable import ProxyCore

private struct PatternCase: Sendable, CustomTestStringConvertible {
    let pattern: String
    let host: String
    let expected: Bool
    var testDescription: String { "\(pattern) ~ \(host) = \(expected)" }
}

private struct HostCase: Sendable, CustomTestStringConvertible {
    let host: String
    let expected: Bool
    var testDescription: String { "\(host) = \(expected)" }
}

private let macOSBypassList = [
    "127.0.0.1", "192.168.0.0/16", "10.0.0.0/8", "172.16.0.0/12",
    "localhost", "*.local", "*.crashlytics.com", "<local>",
]

@Suite("HostPattern", .productionChinese) struct HostPatternTests {
    @Test(arguments: [
        PatternCase(pattern: "*.a.com", host: "x.a.com", expected: true),
        PatternCase(pattern: "*.a.com", host: "a.com", expected: false),
        PatternCase(pattern: "A.com", host: "a.COM", expected: true),
        PatternCase(pattern: "*", host: "z", expected: true),
        PatternCase(pattern: "*.a.com", host: "x.y.a.com", expected: true),
        PatternCase(pattern: "*.a.com", host: "xa.com", expected: false),
        PatternCase(pattern: "a.com", host: "x.a.com", expected: false),
        PatternCase(pattern: "a.com", host: "a.com.", expected: true),
        PatternCase(pattern: "a.com.", host: "a.com", expected: true),
        PatternCase(pattern: "  a.com ", host: "a.com", expected: true),
        PatternCase(pattern: "[::1]", host: "::1", expected: true),
        PatternCase(pattern: "::1", host: "[::1]", expected: true),
        PatternCase(pattern: "", host: "a.com", expected: false),
        PatternCase(pattern: "   ", host: "", expected: false),
        PatternCase(pattern: "*.a.com", host: "X.A.COM", expected: true),
    ])
    fileprivate func matches(_ c: PatternCase) {
        #expect(HostPattern.matches(c.pattern, host: c.host) == c.expected)
    }
}

@Suite("UpstreamProxy.shouldBypass", .productionChinese) struct UpstreamBypassTests {
    private func proxy(_ bypass: [String] = macOSBypassList, loopback: Bool = true) -> UpstreamProxy {
        var p = UpstreamProxy(host: "127.0.0.1", port: 7897, bypass: bypass)
        p.alwaysBypassLoopback = loopback
        return p
    }

    @Test(arguments: [
        HostCase(host: "192.168.3.4", expected: true),
        HostCase(host: "10.1.1.1", expected: true),
        HostCase(host: "172.16.5.5", expected: true),
        HostCase(host: "172.31.255.255", expected: true),
        HostCase(host: "172.32.0.1", expected: false),
        HostCase(host: "192.169.0.1", expected: false),
        HostCase(host: "printer.local", expected: true),
        HostCase(host: "local", expected: true),  // no dot -> <local>
        HostCase(host: "intranet", expected: true),
        HostCase(host: "api.github.com", expected: false),
        HostCase(host: "x.crashlytics.com", expected: true),
        HostCase(host: "crashlytics.com", expected: false),
        HostCase(host: "X.Crashlytics.COM", expected: true),
        HostCase(host: "x.crashlytics.com.", expected: true),
        HostCase(host: "8.8.8.8", expected: false),
        HostCase(host: "2001:db8::1", expected: false),
        HostCase(host: "[2001:db8::1]", expected: false),
    ])
    fileprivate func macOSList(_ c: HostCase) {
        #expect(proxy().shouldBypass(c.host) == c.expected)
    }

    @Test(arguments: ["localhost", "LOCALHOST", "127.0.0.1", "127.5.6.7", "::1", "[::1]", "0:0:0:0:0:0:0:1"])
    func loopbackAlwaysBypasses(_ host: String) {
        #expect(proxy([]).shouldBypass(host))
    }

    @Test(arguments: ["localhost", "127.0.0.1", "127.5.6.7", "::1", "[::1]"])
    func loopbackNotBypassedWhenDisabled(_ host: String) {
        #expect(!proxy([], loopback: false).shouldBypass(host))
    }

    @Test func defaultAlwaysBypassLoopbackIsTrue() {
        #expect(UpstreamProxy(host: "h", port: 1, bypass: []).alwaysBypassLoopback)
    }

    @Test func explicitEntriesStillApplyWhenLoopbackDisabled() {
        #expect(proxy(["localhost"], loopback: false).shouldBypass("localhost"))
        #expect(proxy(["127.0.0.1"], loopback: false).shouldBypass("127.0.0.1"))
    }

    @Test func cidrOnlyAppliesToIPv4Literals() {
        let p = proxy(["10.0.0.0/8"], loopback: false)
        #expect(p.shouldBypass("10.2.3.4"))
        #expect(!p.shouldBypass("10.example.com"))
        #expect(!p.shouldBypass("::ffff:10.2.3.4"))
    }

    @Test func cidrPrefixBoundaries() {
        #expect(proxy(["0.0.0.0/0"], loopback: false).shouldBypass("8.8.8.8"))
        #expect(proxy(["1.2.3.4/32"], loopback: false).shouldBypass("1.2.3.4"))
        #expect(!proxy(["1.2.3.4/32"], loopback: false).shouldBypass("1.2.3.5"))
        #expect(proxy(["192.168.1.0/24"], loopback: false).shouldBypass("192.168.1.255"))
        #expect(!proxy(["192.168.1.0/24"], loopback: false).shouldBypass("192.168.2.0"))
    }

    @Test(arguments: ["1.2.3.4/33", "1.2.3.4/-1", "1.2.3.4/x", "1.2.3/8", "/8", "a.com/8", "1.2.3.4/"])
    func malformedCIDRMatchesNothing(_ entry: String) {
        let p = proxy([entry], loopback: false)
        #expect(!p.shouldBypass("1.2.3.4"))
        #expect(!p.shouldBypass("a.com"))
    }

    @Test func bareIPExactMatch() {
        let p = proxy(["8.8.8.8", "2001:db8::1"], loopback: false)
        #expect(p.shouldBypass("8.8.8.8"))
        #expect(!p.shouldBypass("8.8.8.9"))
        #expect(p.shouldBypass("[2001:db8::1]"))
        #expect(p.shouldBypass("2001:DB8:0:0:0:0:0:1"))
        #expect(!p.shouldBypass("2001:db8::2"))
    }

    @Test func plainDomainIsExactOnly() {
        let p = proxy(["apple.com"], loopback: false)
        #expect(p.shouldBypass("apple.com"))
        #expect(p.shouldBypass("APPLE.com"))
        #expect(!p.shouldBypass("www.apple.com"))
    }

    @Test func localTokenIsNotIPLiteralAndHasNoDot() {
        let p = proxy(["<local>"], loopback: false)
        #expect(p.shouldBypass("intranet"))
        #expect(!p.shouldBypass("a.com"))
        #expect(!p.shouldBypass("::2"))
        #expect(!p.shouldBypass("1.2.3.4"))
        #expect(!p.shouldBypass(""))
    }

    @Test func entriesAreTrimmedAndBlankEntriesIgnored() {
        let p = proxy(["  *.local  ", "", "   "], loopback: false)
        #expect(p.shouldBypass("a.local"))
        #expect(!p.shouldBypass("a.com"))
        #expect(!p.shouldBypass(""))
    }

    @Test func equatable() {
        #expect(proxy() == proxy())
        #expect(proxy() != proxy(loopback: false))
        #expect(proxy() != proxy(["x"]))
    }
}

@Suite("DecryptionPolicy", .productionChinese) struct DecryptionPolicyTests {
    @Test func defaults() {
        let p = DecryptionPolicy()
        #expect(p.enabled)
        #expect(p.excludedHosts.isEmpty)
        #expect(p.shouldDecrypt("anything.com"))
        #expect(p == DecryptionPolicy(enabled: true, excludedHosts: []))
    }

    @Test func excludedHostsAreNotDecrypted() {
        let p = DecryptionPolicy(excludedHosts: ["*.apple.com"])
        #expect(!p.shouldDecrypt("gs.apple.com"))
        #expect(!p.shouldDecrypt("GS.Apple.com"))
        #expect(p.shouldDecrypt("a.com"))
        #expect(p.shouldDecrypt("apple.com"))
    }

    @Test(arguments: ["a.com", "gs.apple.com", "[::1]", "localhost"])
    func disabledNeverDecrypts(_ host: String) {
        #expect(!DecryptionPolicy(enabled: false, excludedHosts: []).shouldDecrypt(host))
    }

    @Test func codableRoundTrip() throws {
        let p = DecryptionPolicy(enabled: false, excludedHosts: ["a.com", "*.b.com"])
        let data = try JSONEncoder().encode(p)
        #expect(try JSONDecoder().decode(DecryptionPolicy.self, from: data) == p)
    }
}

@Suite("PassthroughRegistry", .productionChinese) struct PassthroughRegistryTests {
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [Set<String>] = []
        func record(_ s: Set<String>) { lock.lock(); _calls.append(s); lock.unlock() }
        var calls: [Set<String>] { lock.lock(); defer { lock.unlock() }; return _calls }
    }

    @Test func insertFiresOnChangeAndDuplicateReturnsFalse() {
        let registry = PassthroughRegistry()
        let rec = Recorder()
        registry.onChange { rec.record($0) }

        #expect(registry.insert("a.com") == true)
        #expect(registry.insert("a.com") == false)
        #expect(registry.contains("a.com"))
        #expect(registry.hosts == ["a.com"])
        #expect(rec.calls == [["a.com"]])
    }

    @Test func hostsAreNormalized() {
        let registry = PassthroughRegistry(hosts: ["Seed.COM", "[::1]"])
        #expect(registry.hosts == ["seed.com", "::1"])
        #expect(registry.insert("A.Com") == true)
        #expect(registry.insert("a.com") == false)
        #expect(registry.contains("A.COM"))
        #expect(registry.contains("[::1]"))
        #expect(registry.contains("::1"))
        #expect(registry.contains("a.com."))
        #expect(!registry.contains("b.com"))
        registry.remove("[::1]")
        #expect(!registry.contains("::1"))
    }

    @Test func removeFiresOnChangeOnlyWhenRemoved() {
        let registry = PassthroughRegistry(hosts: ["a.com"])
        let rec = Recorder()
        registry.onChange { rec.record($0) }

        registry.remove("nope.com")
        #expect(rec.calls.isEmpty)
        registry.remove("A.com")
        #expect(rec.calls == [[]])
        #expect(registry.hosts.isEmpty)
    }

    @Test func initDoesNotFireAndLatestHandlerWins() {
        let registry = PassthroughRegistry(hosts: ["a.com"])
        let first = Recorder()
        let second = Recorder()
        registry.onChange { first.record($0) }
        registry.onChange { second.record($0) }
        registry.insert("b.com")
        #expect(first.calls.isEmpty)
        #expect(second.calls == [["a.com", "b.com"]])
    }

    @Test func handlerRunsOutsideTheLock() {
        let registry = PassthroughRegistry()
        let rec = Recorder()
        // Re-entering the registry from the handler would deadlock if the lock were held.
        registry.onChange { hosts in
            rec.record(hosts)
            _ = registry.contains("a.com")
            _ = registry.hosts
        }
        registry.insert("a.com")
        #expect(rec.calls == [["a.com"]])
    }

    @Test func concurrentInsertsAreSafe() async {
        let registry = PassthroughRegistry()
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<200 {
                group.addTask { registry.insert("host\(i % 50).com") }
            }
        }
        #expect(registry.hosts.count == 50)
    }
}

@Suite("ProxyConfiguration", .productionChinese) struct ProxyConfigurationTests {
    @Test func defaults() {
        let c = ProxyConfiguration()
        #expect(c.listenHost == "127.0.0.1")
        #expect(c.port == 9090)
        #expect(c.portFallbackCount == 9)
        #expect(c.upstreamProxy == nil)
        #expect(c.decryption == DecryptionPolicy())
        #expect(c.autoPassthroughOnHandshakeFailure == false)
        #expect(c.connectTimeout == .seconds(15))
    }
}

private struct UserPatternCase: Sendable, CustomTestStringConvertible {
    let input: String
    let expected: String?
    var testDescription: String { "\"\(input)\" -> \(expected.map { "\"\($0)\"" } ?? "nil")" }
}

@Suite("HostPattern.normalizedUserPattern", .productionChinese) struct UserPatternTests {
    @Test(arguments: [
        UserPatternCase(input: "a.com", expected: "a.com"),
        UserPatternCase(input: "  A.Com \n", expected: "a.com"),
        UserPatternCase(input: "a.com.", expected: "a.com"),
        UserPatternCase(input: "*.Apple.com", expected: "*.apple.com"),
        UserPatternCase(input: "*", expected: "*"),
        UserPatternCase(input: " * ", expected: "*"),
        UserPatternCase(input: "localhost", expected: "localhost"),
        UserPatternCase(input: "my-host_1.example.org", expected: "my-host_1.example.org"),
        UserPatternCase(input: "192.168.1.10", expected: "192.168.1.10"),
        UserPatternCase(input: "[::1]", expected: "::1"),
        UserPatternCase(input: "2001:DB8::1", expected: "2001:db8::1"),
    ])
    fileprivate func accepts(_ c: UserPatternCase) {
        #expect(HostPattern.normalizedUserPattern(c.input) == c.expected)
    }

    @Test(arguments: [
        "", "   ", "*.", " *. ", "*..", ".", "..", "**", "*.*.a.com", "a*.com", "*a.com", "a.*.com",
        ".a.com", "a..com", "a b.com", "http://a.com", "a.com/path", "a.com:443", "user@a.com",
        "*.::1", "a.com,b.com",
    ])
    func rejects(_ input: String) {
        #expect(HostPattern.normalizedUserPattern(input) == nil)
    }

    @Test func acceptedPatternsMatchWhatTheyLookLike() throws {
        let wildcard = try #require(HostPattern.normalizedUserPattern(" *.Example.com "))
        #expect(HostPattern.matches(wildcard, host: "api.example.com"))
        #expect(!HostPattern.matches(wildcard, host: "example.com"))
        let all = try #require(HostPattern.normalizedUserPattern("*"))
        #expect(HostPattern.matches(all, host: "anything.test"))
    }
}
