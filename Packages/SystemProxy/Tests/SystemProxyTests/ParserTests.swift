import Testing

@testable import SystemProxy

@Suite struct ParserTests {
    @Test func parseServices() {
        let output = "An asterisk (*) denotes that a network service is disabled.\nUSB ACM\n*Bluetooth PAN\nWi-Fi\n"
        #expect(NetworkSetupParser.services(output) == ["USB ACM", "Wi-Fi"])
    }

    @Test func parseServicesKeepsNamesWithSpaces() {
        let output = "An asterisk (*) denotes that a network service is disabled.\nUSB ACM 2\nThunderbolt Ethernet Slot 1\n"
        #expect(NetworkSetupParser.services(output) == ["USB ACM 2", "Thunderbolt Ethernet Slot 1"])
    }

    @Test func allServicesIncludesDisabledOnes() {
        let output = "An asterisk (*) denotes that a network service is disabled.\nUSB ACM\n*Bluetooth PAN\nWi-Fi\n"
        #expect(NetworkSetupParser.allServices(output) == ["USB ACM", "Bluetooth PAN", "Wi-Fi"])
    }

    @Test func parseEndpoint() {
        let output = "Enabled: Yes\nServer: 127.0.0.1\nPort: 7897\nAuthenticated Proxy Enabled: 0\n"
        #expect(NetworkSetupParser.endpoint(output) == ProxyEndpoint(enabled: true, host: "127.0.0.1", port: 7897))
    }

    @Test func parseDisabledEmptyEndpoint() {
        let output = "Enabled: No\nServer: \nPort: 0\nAuthenticated Proxy Enabled: 0\n"
        #expect(NetworkSetupParser.endpoint(output) == ProxyEndpoint(enabled: false, host: "", port: 0))
    }

    @Test func parseBypassDomains() {
        let output = "127.0.0.1\n192.168.0.0/16\n*.local\n<local>\n"
        #expect(NetworkSetupParser.bypassDomains(output) == ["127.0.0.1", "192.168.0.0/16", "*.local", "<local>"])
    }

    @Test func parseEmptyBypass() {
        #expect(NetworkSetupParser.bypassDomains("There aren't any bypass domains set on Wi-Fi.\n") == [])
    }
}

@Suite struct CommandRunnerTests {
    @Test func privilegedScriptQuotesEveryArgument() {
        let script = ProcessCommandRunner.privilegedScript(for: [
            ["-setwebproxy", "Wi-Fi", "127.0.0.1", "9090"],
            ["-setsecurewebproxy", "Bob's Mac; rm -rf /", "127.0.0.1", "9090"],
        ])
        #expect(
            script
                == "/usr/sbin/networksetup '-setwebproxy' 'Wi-Fi' '127.0.0.1' '9090'"
                + " && /usr/sbin/networksetup '-setsecurewebproxy' 'Bob'\\''s Mac; rm -rf /' '127.0.0.1' '9090'")
    }

    @Test func appleScriptEscapesBackslashesAndQuotes() {
        #expect(ProcessCommandRunner.appleScriptLiteral(#"a\b"c"#) == #"a\\b\"c"#)
        let source = ProcessCommandRunner.appleScript(forShellScript: #"echo "x" 'y'"#)
        #expect(source == #"do shell script "echo \"x\" 'y'" with administrator privileges"#)
    }

    @Test func privilegedGroupScriptKeepsServicesIndependent() {
        let script = ProcessCommandRunner.privilegedScript(forGroups: [
            [["-setwebproxy", "A", "h", "1"], ["-setwebproxystate", "A", "off"]],
            [["-setwebproxy", "B c", "h", "1"]],
        ])
        #expect(
            script
                == "fail=0; /usr/sbin/networksetup '-setwebproxy' 'A' 'h' '1' && /usr/sbin/networksetup '-setwebproxystate' 'A' 'off' || fail=1"
                + "; /usr/sbin/networksetup '-setwebproxy' 'B c' 'h' '1' || fail=1; exit $fail")
    }

    @Test func classifyOutput() {
        #expect(ProcessCommandRunner.classify(status: 0, stdout: "Enabled: Yes\n", stderr: "") == nil)
        #expect(ProcessCommandRunner.classify(status: 0, stdout: "Enabled: Yes\n", stderr: "networksetup[1]: proxies = nil.\n") == nil)
        #expect(ProcessCommandRunner.classify(status: 14, stdout: "** Error: Something broke\n", stderr: "") == .failed("** Error: Something broke"))
        #expect(ProcessCommandRunner.classify(status: 0, stdout: "** Error: Parameter is wrong\n", stderr: "") == .failed("** Error: Parameter is wrong"))
        #expect(ProcessCommandRunner.classify(status: 1, stdout: "", stderr: "boom\n") == .failed("boom"))
        #expect(ProcessCommandRunner.classify(status: 1, stdout: "out", stderr: "err") == .failed("err\nout"))
    }

    @Test func classifyAdminFailuresAsNeedsAuthorization() {
        #expect(ProcessCommandRunner.classify(status: 1, stdout: "** Error: This operation requires admin privileges.\n", stderr: "") == .needsAuthorization)
        #expect(ProcessCommandRunner.classify(status: 1, stdout: "Requires Admin rights", stderr: "") == .needsAuthorization)
        #expect(ProcessCommandRunner.classify(status: 1, stdout: "", stderr: "You must be an Administrator") == .needsAuthorization)
    }

    @Test func runKeepsStdoutAndStderrSeparate() throws {
        let r = try ProcessCommandRunner.run("/bin/sh", ["-c", "echo out; echo err 1>&2; exit 3"])
        #expect(r.status == 3)
        #expect(r.stdout == "out\n")
        #expect(r.stderr == "err\n")
    }

    @Test func classifyUserCancelledAuthorization() {
        let output = "execution error: User canceled. (-128)\n"
        #expect(ProcessCommandRunner.classifyOsascript(status: 1, output: output) == .userCancelled)
        #expect(ProcessCommandRunner.classifyOsascript(status: 0, output: "") == nil)
        #expect(ProcessCommandRunner.classifyOsascript(status: 1, output: "boom") == .failed("boom"))
        #expect(ProcessCommandRunner.classifyOsascript(status: 1, output: "error code -1280 happened") == .failed("error code -1280 happened"))
    }
}
