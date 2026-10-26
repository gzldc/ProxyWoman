import Testing

@testable import SystemProxy

@Suite struct TerminalProxyCommandTests {
    @Test func exportLineSetsAllFourVariables() {
        #expect(
            TerminalProxyCommand.exportLine(host: "127.0.0.1", port: 9091)
                == "export http_proxy=http://127.0.0.1:9091 https_proxy=http://127.0.0.1:9091 "
                + "HTTP_PROXY=http://127.0.0.1:9091 HTTPS_PROXY=http://127.0.0.1:9091")
    }

    @Test func ipv6HostIsBracketed() {
        #expect(
            TerminalProxyCommand.exportLine(host: "::1", port: 9090)
                == "export http_proxy=http://[::1]:9090 https_proxy=http://[::1]:9090 "
                + "HTTP_PROXY=http://[::1]:9090 HTTPS_PROXY=http://[::1]:9090")
    }
}

@Suite struct ShellQuotingTests {
    @Test(arguments: [
        ("/Users/me/Library/Application Support/X/CA/root-ca.pem",
         "'/Users/me/Library/Application Support/X/CA/root-ca.pem'"),
        ("/tmp/it's here.pem", #"'/tmp/it'\''s here.pem'"#),
        ("", "''"),
        ("$HOME/`x`/\"q\"", #"'$HOME/`x`/"q"'"#),
    ])
    func singleQuotes(_ input: String, _ expected: String) {
        #expect(TerminalProxyCommand.shellQuoted(input) == expected)
    }
}
