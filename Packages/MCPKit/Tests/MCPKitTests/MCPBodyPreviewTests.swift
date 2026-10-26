import FlowStore
import Foundation
import MCPWire
import Testing

@testable import MCPKit

/// Fixed gzip streams (Python `gzip.compress(..., mtime=0)`), so no test depends on a compressor.
private enum Gzip {
    /// `{"hello":"world"}`
    static let small = Data(base64Encoded: "H4sIAAAAAAAC/6tWykjNyclXslIqzy/KSVGqBQDRQQnYEQAAAA==")!
    /// 40000 times "a"
    static let big = Data(
        base64Encoded:
            "H4sIAAAAAAAC/+3BMQEAAADCoKzrX8LLFkABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA397jd80CcAAA=")!
    /// 1 MiB + 100 times "a"
    static let huge = Data(base64Encoded: "H4sIAAAAAAAC/+3BMQEAAADCoKzrX8IaHkABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAPwbLm71G2QAEAA=")!
    /// 9 MiB times "a": over the 8 MiB decode limit.
    static let bomb = Data(base64Encoded: "H4sIAAAAAAAC/+zBgQAAAACAINb9JRapCgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgNmDAwEAAAAAIP/XRlBVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVpDw4JAAAAAAT9f+0HMwAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAF/JrFh+AACQAA==")!
    /// `{"password":"hunter2hunter2","ok":1}`
    static let secret = Data(base64Encoded: "H4sIAAAAAAAC/6tWKkgsLi7PL0pRslLKKM0rSS0yglJKOkr52UpWhrUA6ExYPiQAAAA=")!
}

private final class PreviewFixture {
    let directory: URL
    let store: FlowStore

    init() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("preview-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = FlowStore(bodyDirectory: directory)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    func body(_ data: Data) -> BodyRef { store.makeManagedBody(data) }
}

private let on = MCPRedactor(MCPRedactionSettings())
private let off = MCPRedactor(MCPRedactionSettings(enabled: false))

private func headers(_ type: String?, encoding: String? = nil) -> [HeaderField] {
    var result: [HeaderField] = []
    if let type { result.append(HeaderField(name: "Content-Type", value: type)) }
    if let encoding { result.append(HeaderField(name: "Content-Encoding", value: encoding)) }
    return result
}

@Suite struct MCPBodyPreviewTests {
    private func make(
        _ data: Data, type: String? = "text/plain", encoding: String? = nil, captureTruncated: Bool = false,
        max: Int = 16384, redactor: MCPRedactor = on, using fixture: PreviewFixture = PreviewFixture()
    ) async throws -> JSONValue {
        try await MCPBodyPreview.make(
            body: fixture.body(data), store: fixture.store, headers: headers(type, encoding: encoding),
            truncatedAtCapture: captureTruncated, maxBytes: max, redactor: redactor)
    }

    @Test func previewReturnsTextAndMarksTruncation() async throws {
        let whole = try await make(Data("hello world".utf8), max: 100)
        #expect(whole["text"]?.stringValue == "hello world")
        #expect(whole["size"]?.intValue == 11)
        #expect(whole["shown"]?.intValue == 11)
        #expect(whole["truncated"]?.boolValue == false)
        #expect(whole["contentType"]?.stringValue == "text/plain")
        #expect(whole["kind"]?.stringValue == "text")
        #expect(whole["encoding"] == .null)

        let cut = try await make(Data("hello world".utf8), max: 5)
        #expect(cut["text"]?.stringValue == "hello")
        #expect(cut["shown"]?.intValue == 5)
        #expect(cut["size"]?.intValue == 11)
        #expect(cut["truncated"]?.boolValue == true)

        let exact = try await make(Data("hello".utf8), max: 5)
        #expect(exact["text"]?.stringValue == "hello")
        #expect(exact["truncated"]?.boolValue == false)
    }

    @Test func previewDecodesGzipBeforeCapping() async throws {
        let small = try await make(Gzip.small, type: "application/json", encoding: "gzip", redactor: off)
        #expect(small["text"]?.stringValue == #"{"hello":"world"}"#)
        #expect(small["encoding"]?.stringValue == "gzip")
        #expect(small["truncated"]?.boolValue == false)
        #expect(small["size"]?.intValue == Gzip.small.count)

        // 40000 decoded bytes: far more than the compressed input, capped after decoding.
        let big = try await make(Gzip.big, type: "text/plain", encoding: "gzip", max: 100, redactor: off)
        #expect(big["text"]?.stringValue == String(repeating: "a", count: 100))
        #expect(big["shown"]?.intValue == 100)
        #expect(big["truncated"]?.boolValue == true)
        #expect(big["encoding"]?.stringValue == "gzip")

        // With redaction on the decoded bytes follow the same text rules and are shown too.
        let redacted = try await make(Gzip.small, type: "application/json", encoding: "gzip", redactor: on)
        #expect(redacted["text"]?.stringValue == #"{"hello":"world"}"#)
    }

    @Test func previewRedactsDecodedGzipBodies() async throws {
        let result = try await make(Gzip.secret, type: "application/json", encoding: "gzip", redactor: on)
        let text = try #require(result["text"]?.stringValue)
        #expect(!text.contains("hunter2"))
        #expect(text.contains(MCPRedactor.redactedValue))
        let raw = try await make(Gzip.secret, type: "application/json", encoding: "gzip", redactor: off)
        #expect(raw["text"]?.stringValue?.contains("hunter2") == true)
    }

    @Test func previewReportsUndecodableEncodings() async throws {
        let corrupt = try await make(Data("not gzip at all, really not".utf8), type: "text/plain", encoding: "gzip")
        #expect(corrupt["omitted"]?.stringValue == "decode_failed")
        #expect(corrupt["text"] == nil)
        let unknown = try await make(Data("abc".utf8), type: "text/plain", encoding: "zstd")
        #expect(unknown["omitted"]?.stringValue == "decode_failed")
        // A capture that stopped early left a prefix of the compressed stream: it cannot be decoded.
        let prefix = try await make(Gzip.small, type: "text/plain", encoding: "gzip", captureTruncated: true)
        #expect(prefix["omitted"]?.stringValue == "decode_failed")
        #expect(prefix["truncated"]?.boolValue == true)
    }

    @Test func previewDoesNotSplitMultibyteCharacters() async throws {
        // "é" is 2 bytes, "😀" 4 bytes, "中" 3 bytes.
        for (text, cap, expected) in [
            ("ééé", 3, "é"), ("ééé", 4, "éé"), ("a😀b", 4, "a"), ("a😀b", 5, "a😀"), ("中中", 5, "中"), ("中中", 2, ""),
        ] {
            let result = try await make(Data(text.utf8), max: cap)
            #expect(result["text"]?.stringValue == expected, "\(text) cap \(cap)")
            #expect(result["shown"]?.intValue == expected.utf8.count)
            #expect(result["truncated"]?.boolValue == true)
        }
    }

    @Test func previewHandlesLegacyCharsets() async throws {
        // "中文" in GBK is 4 bytes and 6 UTF-8 bytes; the cap counts the UTF-8 bytes of the text.
        let gbk = Data([0xD6, 0xD0, 0xCE, 0xC4])
        let whole = try await make(gbk, type: "text/plain; charset=gbk", max: 100)
        #expect(whole["text"]?.stringValue == "中文")
        let cut = try await make(gbk, type: "text/plain; charset=gbk", max: 3)
        #expect(cut["text"]?.stringValue == "中")
        #expect(cut["truncated"]?.boolValue == true)
    }

    @Test func previewOmitsBinary() async throws {
        let png = try await make(Data([0x89, 0x50, 0x4E, 0x47, 0, 1, 2]), type: "image/png")
        #expect(png["omitted"]?.stringValue == "binary")
        #expect(png["size"]?.intValue == 7)
        #expect(png["kind"]?.stringValue == "image")
        #expect(png["contentType"]?.stringValue == "image/png")
        #expect(png["text"] == nil)
        // No content type at all, and text that is not valid in its charset.
        #expect(try await make(Data("abc".utf8), type: nil)["omitted"]?.stringValue == "binary")
        #expect(try await make(Data([0xFF, 0xFE, 0xFD]), type: "text/plain")["omitted"]?.stringValue == "binary")
        #expect(try await make(Data("abc".utf8), type: "text/plain", redactor: off)["text"]?.stringValue == "abc")
        #expect(try await make(Data("abc".utf8), type: nil, redactor: off)["omitted"]?.stringValue == "binary")
    }

    @Test func previewOmitsUnreadableFile() async throws {
        let fixture = PreviewFixture()
        let url = fixture.directory.appendingPathComponent("gone.bin")
        try Data("secret body".utf8).write(to: url)
        let ref = BodyRef.file(url, size: 11)
        try FileManager.default.removeItem(at: url)
        let result = try await MCPBodyPreview.make(
            body: ref, store: fixture.store, headers: headers("text/plain"), truncatedAtCapture: false, maxBytes: 100,
            redactor: on)
        #expect(result["omitted"]?.stringValue == "unavailable")
        #expect(result["size"]?.intValue == 11)
        #expect(result["text"] == nil)
    }

    @Test func previewRedactsJSONSecrets() async throws {
        let body = #"{"user":"ann","password":"hunter2","nested":{"access_token":"abc.def"}}"#
        let result = try await make(Data(body.utf8), type: "application/json; charset=utf-8")
        let text = try #require(result["text"]?.stringValue)
        #expect(!text.contains("hunter2"))
        #expect(!text.contains("abc.def"))
        #expect(text.contains("ann"))
        #expect(result["kind"]?.stringValue == "json")
        #expect(result["contentType"]?.stringValue == "application/json; charset=utf-8")
        let raw = try await make(Data(body.utf8), type: "application/json", redactor: off)
        #expect(raw["text"]?.stringValue == body)
    }

    @Test func previewHonorsCaptureTruncationFlag() async throws {
        let flagged = try await make(Data("short".utf8), captureTruncated: true, max: 100)
        #expect(flagged["text"]?.stringValue == "short")
        #expect(flagged["truncated"]?.boolValue == true)
        let clean = try await make(Data("short".utf8), captureTruncated: false, max: 100)
        #expect(clean["truncated"]?.boolValue == false)
    }

    @Test func previewNeverExceedsTheCapEvenWhenRedactionLengthensText() async throws {
        // `"pin":"1"` becomes `"pin":"[REDACTED]"`, which is longer; the cap still holds.
        let body = String(repeating: #"{"password":"1"}"#, count: 50)
        for cap in [1, 7, 16, 33, 100] {
            let result = try await make(Data(body.utf8), type: "application/json", max: cap)
            let text = try #require(result["text"]?.stringValue)
            #expect(text.utf8.count <= cap, "cap \(cap)")
            #expect(result["shown"]?.intValue == text.utf8.count)
            #expect(result["truncated"]?.boolValue == true)
        }
    }

    @Test func previewClampsToTheHardMaximum() async throws {
        let big = Data(repeating: 0x61, count: MCPBodyPreview.hardMaxBytes + 1000)
        let result = try await make(big, max: 10_000_000, redactor: off)
        #expect(result["shown"]?.intValue == MCPBodyPreview.hardMaxBytes)
        #expect(result["truncated"]?.boolValue == true)
        #expect(MCPBodyPreview.defaultMaxBytes == 16 * 1024)
    }

    @Test func previewWithholdsWhatRedactionHidesAndShowsItWithoutRedaction() async throws {
        let multipart = Data("--b\r\nContent-Disposition: form-data; name=\"x\"\r\n\r\nv\r\n--b--".utf8)
        let hidden = try await make(multipart, type: "multipart/form-data; boundary=b")
        #expect(hidden["omitted"]?.stringValue == "withheld_by_redaction")
        #expect(hidden["text"] == nil)
        #expect(try await make(multipart, type: "multipart/form-data; boundary=b", redactor: off)["text"] != nil)

        let oversize = Data(repeating: 0x61, count: (1 << 20) + 1)
        let large = try await make(oversize, type: "text/plain", max: 16)
        #expect(large["omitted"]?.stringValue == "withheld_by_redaction")
        #expect(try await make(oversize, type: "text/plain", max: 16, redactor: off)["text"]?.stringValue?.count == 16)

        // Hidden because of the decoded size (a little over 1 MiB), not the compressed one (about 1 KiB).
        #expect(Gzip.huge.count < 2048)
        let decodedLarge = try await make(Gzip.huge, type: "text/plain", encoding: "gzip", max: 16)
        #expect(decodedLarge["omitted"]?.stringValue == "withheld_by_redaction")
        let decodedShown = try await make(Gzip.huge, type: "text/plain", encoding: "gzip", max: 16, redactor: off)
        #expect(decodedShown["text"]?.stringValue == String(repeating: "a", count: 16))
        #expect(decodedShown["truncated"]?.boolValue == true)
    }

    @Test func previewDoesNotLeakAValueCutAtTheReadBoundary() async throws {
        let secret = String(repeating: "x", count: 500)
        let body = #"{"a":1,"password":""# + secret
        let result = try await make(Data(body.utf8), type: "application/json", max: 40)
        let text = try #require(result["text"]?.stringValue)
        #expect(!text.contains("xxxx"))
        let cutInKey = try await make(Data((#"{"pass"# + String(repeating: "w", count: 200)).utf8), type: "application/json", max: 8)
        #expect(cutInKey["text"]?.stringValue?.utf8.count ?? 0 <= 8)
    }

    @Test func previewOfNoBodyIsNullAndOfAnEmptyBodyIsEmpty() async throws {
        let fixture = PreviewFixture()
        let none = try await MCPBodyPreview.make(
            body: nil, store: fixture.store, headers: headers("text/plain"), truncatedAtCapture: false, maxBytes: 10,
            redactor: on)
        #expect(none == .null)
        let empty = try await make(Data(), using: fixture)
        #expect(empty["size"]?.intValue == 0)
        #expect(empty["text"]?.stringValue == "")
        #expect(empty["truncated"]?.boolValue == false)
    }

    @Test func previewSanitisesTheContentTypeItReports() async throws {
        let result = try await make(
            Data("x".utf8), type: "text/plain; charset=utf-8; token=abc123secret; boundary=zzz", redactor: on)
        #expect(result["contentType"]?.stringValue == "text/plain; charset=utf-8")
    }

    @Test func previewTellsATooLargeDecodeFromACorruptOne() async throws {
        #expect(MCPBodyPreview.outputLimitMessage != nil)
        #expect(Gzip.bomb.count < 20_000)
        // Over the decode limit: with redaction on that is "too big to show", with it off a failed decode.
        let hidden = try await make(Gzip.bomb, type: "text/plain", encoding: "gzip", redactor: on)
        #expect(hidden["omitted"]?.stringValue == "withheld_by_redaction")
        let failed = try await make(Gzip.bomb, type: "text/plain", encoding: "gzip", redactor: off)
        #expect(failed["omitted"]?.stringValue == "decode_failed")
        // A corrupt stream stays a decode failure with redaction on.
        let corrupt = try await make(Data("definitely not gzip data here".utf8), type: "text/plain", encoding: "gzip", redactor: on)
        #expect(corrupt["omitted"]?.stringValue == "decode_failed")
    }

    @Test func previewHandlesAFileThatReadsShortOrEmpty() async throws {
        let fixture = PreviewFixture()
        let url = fixture.directory.appendingPathComponent("short.bin")
        func run(_ bytes: Data) async throws -> JSONValue {
            try bytes.write(to: url)
            return try await MCPBodyPreview.make(
                body: .file(url, size: 11), store: fixture.store, headers: headers("text/plain"), truncatedAtCapture: false,
                maxBytes: 100, redactor: on)
        }
        // The file exists but holds nothing although 11 bytes were recorded: unreadable.
        let empty = try await run(Data())
        #expect(empty["omitted"]?.stringValue == "unavailable")
        // Fewer bytes than recorded: the lease's read fails, which is reported as unreadable too.
        let partial = try await run(Data("hello".utf8))
        #expect(partial["omitted"]?.stringValue == "unavailable")
        #expect(partial["text"] == nil)
        #expect(partial["size"]?.intValue == 11)
    }

    @Test func capCountsUnicodeScalarsNotCharacters() {
        // "e" + combining acute is one Character but two scalars.
        let text = String(repeating: "e\u{301}", count: 300)
        let capped = MCPFlowDetail.cap(text, 256)
        #expect(capped.unicodeScalars.count <= 256)
        #expect(capped.hasSuffix("…"))
        #expect(MCPFlowDetail.cap("short", 256) == "short")
    }
}
