import Foundation

/// Where a phone or another device downloads the root certificate: either straight from the proxy
/// (`http://<mac-ip>:<port>/cert`) or, with the device's proxy already set, from the reserved host
/// `http://proxywoman.cert/`. Both are answered by the proxy itself and never forwarded.
public enum CertificateDownload {
    public static let host = "proxywoman.cert"
    public static let path = "/cert"
    public static let fileName = "ProxyWoman-CA.pem"
    static let contentType = "application/x-x509-ca-cert"

    /// The request target as the client wrote it: origin form (`/cert`) or absolute form (`http://proxywoman.cert/…`).
    static func matches(_ uri: String) -> Bool {
        if uri.hasPrefix("/") {
            let path = uri.split(separator: "?", maxSplits: 1).first.map(String.init) ?? uri
            return ["/cert", "/cert.pem", "/ssl"].contains(path.lowercased())
        }
        guard let components = URLComponents(string: uri), components.scheme?.lowercased() == "http" else { return false }
        return components.host?.lowercased() == host
    }
}
