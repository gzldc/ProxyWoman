import AppCore
import CoreGraphics
import FlowStore
import Foundation
import Localization
import Testing

@testable import Viewers

/// Exercises the functions used by the real UI and viewers, with private translated resources.
@Suite(.productionChinese) struct QuantityIntegrationTests {
    private func english() throws -> Localizer {
        let url = try #require(
            Bundle.module.url(
                forResource: "Translations", withExtension: "bundle", subdirectory: "Fixtures"))
        return Localizer(bundle: try #require(Bundle(url: url)), preferredLanguages: ["en"])
    }

    // Replacing either count with a string, or swapping arguments, breaks the plural branches.
    @Test(arguments: [(1, 2, "2 rows; 1 selected item"), (2, 1, "1 row; 2 selected items")])
    func selectedRowsRetainsBothCounts(selected: Int, total: Int, expected: String) throws {
        #expect(Formatting.selectedRows(selected: selected, total: total, localizer: try english()) == expected)
    }

    @Test(arguments: [(1, "1 extra filter"), (2, "2 extra filters")])
    func extraFiltersSelectPluralBranch(count: Int, expected: String) throws {
        #expect(Formatting.moreFilters(count, localizer: try english()) == expected)
    }

    @Test(arguments: [(1, "1 byte"), (2, "2 bytes")])
    func rawMessagesSelectBytePluralWithoutChangingHTTP(count: Int, expected: String) throws {
        var flow = Flow(id: 1, scheme: "https", method: "POST", host: "example.com", port: 443, path: "/raw%20中文")
        flow.transport = .init(downstreamRequest: .http1_1, upstreamResponse: .http1_1)
        flow.requestBody = .memory(Data(repeating: 0, count: count))
        flow.responseBody = flow.requestBody
        flow.statusCode = 200
        flow.statusReason = "OK"
        #expect(
            RawMessage.request(flow, localizer: try english()) == "POST /raw%20中文 HTTP/1.1\r\n\r\n<\(expected) binary>")
        #expect(RawMessage.response(flow, localizer: try english()) == "HTTP/1.1 200 OK\r\n\r\n<\(expected) binary>")
    }

    @Test(arguments: [(1, "truncated: 1 byte"), (2, "truncated: 2 bytes")])
    func hexTruncationSelectsBytePlural(count: Int, expected: String) throws {
        #expect(HexDump.format(Data(repeating: 0x41, count: count), maxBytes: 0, localizer: try english()) == expected)
    }

    @Test(arguments: [false, true])
    func bodyDisplayLimitRetainsNumericMegabytes(encoded: Bool) throws {
        let notice = BodyContent.truncationNotice(
            displayTruncated: true, captureTruncated: false, recordedBytes: 1, isEncoded: encoded,
            localizer: try english())
        #expect(notice == (encoded ? "encoded display: 100 megabytes" : "display: 100 megabytes"))
    }

    @Test(arguments: [(1, "1 byte"), (2, "2 bytes"), (1536, "1,536 bytes")], [false, true])
    func captureLimitKeepsSelectorAndFormattedDisplay(value: (Int, String), encoded: Bool) throws {
        let (count, plural) = value
        let notice = try #require(
            BodyContent.truncationNotice(
                displayTruncated: false, captureTruncated: true, recordedBytes: count, isEncoded: encoded,
                localizer: try english()))
        let display = ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
        #expect(notice == "\(encoded ? "encoded " : "")\(display) captured (\(plural))")
    }

    @Test(arguments: [(1, 2, "2 pixels high × 1 pixel wide"), (2, 1, "1 pixel high × 2 pixels wide")])
    func imageDimensionsKeepBothNumericArguments(width: Int, height: Int, expected: String) throws {
        let context = try #require(
            CGContext(
                data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = PreviewImage(cgImage: try #require(context.makeImage()), pixelWidth: width, pixelHeight: height)
        #expect(image.dimensionsDescription(localizer: try english()) == expected)
    }

    @Test(arguments: [
        (1, 2, "1 flow", "2 bytes"), (2, 1, "2 flows", "1 byte"),
        (10_000, 1536, "10,000 flows", "1,536 bytes"),
    ])
    func deletionLimitsKeepSelectorsAndFormattedDisplays(flows: Int, bytes: Int, flowPlural: String, bytePlural: String)
        throws
    {
        let text = Formatting.deletionLimits(maxFlows: flows, maxSpilledBytes: bytes, localizer: try english())
        let display = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .binary)
        let flowDisplay = flows == 10_000 ? "10,000" : String(flows)
        #expect(text == "\(display) cache (\(bytePlural)); \(flowDisplay) requests (\(flowPlural))")
    }

    @Test func chineseQuantityPresentationAndLargeIntegerPrecision() {
        #expect(Formatting.selectedRows(selected: 1, total: 2) == "已选 1 / 2 行")
        #expect(Formatting.moreFilters(2) == "更多过滤（2）")
        #expect(HexDump.format(Data(repeating: 0x41, count: 2), maxBytes: 0) == "…（已截断，共 2 字节）")
        // A 64-bit count must never be narrowed to a 32-bit plural/display argument.
        #expect(Formatting.selectedRows(selected: 1, total: 4_294_967_297) == "已选 1 / 4,294,967,297 行")
    }
}
