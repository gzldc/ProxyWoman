/// The shell command that points command-line tools in one terminal session at the proxy.
public enum TerminalProxyCommand {
    /// `export http_proxy=… https_proxy=… HTTP_PROXY=… HTTPS_PROXY=…`, all set to `http://host:port`
    /// (tools differ in which spelling they read).
    public static func exportLine(host: String, port: Int) -> String {
        let authority = host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
        let url = "http://\(authority)"
        let assignments = ["http_proxy", "https_proxy", "HTTP_PROXY", "HTTPS_PROXY"].map { "\($0)=\(url)" }
        return "export " + assignments.joined(separator: " ")
    }

    /// `text` as one POSIX shell word: single-quoted, each `'` written as `'\''`.
    public static func shellQuoted(_ text: String) -> String {
        "'" + text.replacing("'", with: #"'\''"#) + "'"
    }
}
