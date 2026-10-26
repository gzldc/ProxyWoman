import Foundation
import Testing

@testable import Localization

/// The two production languages must stay interchangeable: same keys, same arguments, no leftovers.
@Suite(.productionChinese) struct ProductionLanguageParityTests {
    private func resource(_ language: String, _ ext: String) throws -> URL {
        try #require(L10n.bundle.url(forResource: "Localizable", withExtension: ext, subdirectory: nil, localization: language))
    }

    private func strings(_ language: String) throws -> [String: String] {
        try #require(NSDictionary(contentsOf: try resource(language, "strings")) as? [String: String])
    }

    private func dictionary(_ language: String) throws -> [String: [String: Any]] {
        try #require(NSDictionary(contentsOf: try resource(language, "stringsdict")) as? [String: [String: Any]])
    }

    /// "position:conversion" for every specifier; unnumbered specifiers take their order. `ld`, `lld` and `d` all count as `d`.
    private func specifiers(_ format: String) -> [String] {
        let pattern = try! NSRegularExpression(pattern: #"%(?:([0-9]+)\$)?[-+ #0-9.]*(?:hh|h|ll|l|q|L|z|j|t)?([@dDuUxXoOfeEgGcCsSp])"#)
        let text = format.replacingOccurrences(of: "%%", with: "")
        return pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).enumerated().map { index, match in
            let position = Range(match.range(at: 1), in: text).map { String(text[$0]) } ?? String(index + 1)
            let kind = Range(match.range(at: 2), in: text).map { String(text[$0]) } ?? ""
            return position + ":" + (kind == "D" ? "d" : kind)
        }.sorted()
    }

    /// The arguments a plural entry consumes: plain specifiers plus `%N$#@variable@` typed by the variable's value type.
    private func pluralArguments(_ entry: [String: Any]) throws -> [String] {
        let format = try #require(entry["NSStringLocalizedFormatKey"] as? String)
        var result = specifiers(format.replacingOccurrences(of: #"%(?:[0-9]+\$)?#@[A-Za-z0-9_]+@"#, with: "", options: .regularExpression))
        let pattern = try! NSRegularExpression(pattern: #"%(?:([0-9]+)\$)?#@([A-Za-z0-9_]+)@"#)
        var next = 1
        for match in pattern.matches(in: format, range: NSRange(format.startIndex..., in: format)) {
            let position = Range(match.range(at: 1), in: format).map { String(format[$0]) } ?? String(next)
            next += 1
            let name = String(format[try #require(Range(match.range(at: 2), in: format))])
            let variable = try #require(entry[name] as? [String: Any], "variable \(name)")
            #expect(variable["NSStringFormatSpecTypeKey"] as? String == "NSStringPluralRuleType")
            #expect(variable["other"] is String, "\(name) has an other form")
            let type = try #require(variable["NSStringFormatValueTypeKey"] as? String)
            result.append(position + ":" + (type == "ld" || type == "lld" || type == "d" ? "d" : type))
        }
        return result
    }

    @Test func bothLanguagesHaveTheSameKeysAndArguments() throws {
        let zh = try strings("zh-Hans")
        let en = try strings("en")
        #expect(Set(zh.keys) == Set(en.keys))
        #expect(zh.count > 1900)
        for (key, chinese) in zh {
            guard let english = en[key] else { continue }
            #expect(specifiers(chinese) == specifiers(english), "\(key): \(chinese) | \(english)")
        }
    }

    @Test func englishHasNoEmptyValuesChineseCharactersOrBrandWords() throws {
        let en = try strings("en")
        for (key, value) in en {
            #expect(!value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(key) is empty")
            #expect(value.range(of: #"\p{Han}"#, options: .regularExpression) == nil, "\(key) has Chinese: \(value)")
            // "In Progress" is ordinary English; only the vendor names are brand words.
            for brand in ["Fiddler", "Progress Software", "Progress Telerik", "Telerik", "Proxyman", "Charles"] {
                #expect(!value.localizedCaseInsensitiveContains(brand), "\(key) mentions \(brand)")
            }
        }
    }

    @Test func bothResourceFilesPassPropertyListLint() throws {
        for url in [try resource("en", "strings"), try resource("zh-Hans", "strings"), try resource("en", "stringsdict")] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/plutil")
            process.arguments = ["-lint", url.path]
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0, "\(url.path)")
        }
    }

    @Test func everyPluralEntryConsumesTheArgumentsTheChineseStringConsumes() throws {
        let zh = try strings("zh-Hans")
        let plurals = try dictionary("en")
        #expect(plurals.count >= 13)
        for (key, entry) in plurals {
            let chinese = try #require(zh[key], "\(key) has no Chinese string")
            let english = Dictionary(grouping: try pluralArguments(entry)) { String($0.split(separator: ":")[0]) }
            // Every argument Chinese reads is read, with the same type; English may also read more of the contract.
            for spec in specifiers(chinese) {
                let parts = spec.split(separator: ":")
                #expect(english[String(parts[0])]?.contains(spec) == true, "\(key): Chinese reads \(spec)")
            }
            for (position, kinds) in english {
                #expect(Set(kinds).count == 1, "\(key): argument \(position) is read with several types")
            }
        }
        // The documented argument contract for the plural keys.
        let contract: [String: [String]] = [
            "statusBar.selectedRows": ["1:d", "2:d"],
            "quickFilterBar.moreFiltersCount": ["1:d"],
            "rawMessage.binaryBody": ["1:d"],
            "hexDump.truncated": ["1:d"],
            "imagePreview.pixelDimensions": ["1:d", "2:d"],
            "bodyContent.displayLimit": ["1:d"],
            "bodyContent.encodedDisplayLimit": ["1:d"],
            "bodyContent.captureLimit": ["1:d", "2:@"],
            "bodyContent.encodedCaptureLimit": ["1:d", "2:@"],
            // English reads the limits only as text; the numeric argument 3 stays in the call for other languages.
            "advancedPane.deletionLimits": ["1:d", "2:@", "4:@"],
            // The grouped text first (as the Chinese string reads it), then the number that picks the noun.
            "webSocket.export.complete": ["1:@", "2:@", "3:@", "4:d"],
            "webSocket.export.partial": ["1:@", "2:@", "3:@", "4:d"],
            "webSocket.export.cancelled": ["1:@", "2:@", "3:@", "4:d"],
            "webSocket.pageCount": ["1:@", "2:@", "3:d"],
            "webSocket.byteCount": ["1:@", "2:d"],
            "webSocket.counts": ["1:@", "2:@", "3:@", "4:d"],
            "webSocket.fragments": ["1:@", "2:@", "3:d", "4:d"],
            "compose.failure.timeout": ["1:@", "2:d"],
        ]
        for (key, expected) in contract {
            let entry = try #require(plurals[key], Comment(rawValue: key))
            let consumed = try pluralArguments(entry).sorted()
            #expect(consumed == expected.sorted(), Comment(rawValue: key))
        }
    }

    @Test func englishPluralsResolveThroughTheRealBundle() throws {
        let en = Localizer(bundle: L10n.bundle, preferredLanguages: ["en"])
        #expect(en.format("statusBar.selectedRows", arguments: [1, 1]) == "1 of 1 row selected")
        #expect(en.format("statusBar.selectedRows", arguments: [3, 12]) == "3 of 12 rows selected")
        #expect(en.format("rawMessage.binaryBody", arguments: [1]) == "<Binary body, 1 byte>")
        #expect(en.format("rawMessage.binaryBody", arguments: [2048]) == "<Binary body, 2,048 bytes>")
        #expect(en.format("imagePreview.pixelDimensions", arguments: [1, 1]) == "1 × 1 pixel")
        #expect(en.format("imagePreview.pixelDimensions", arguments: [640, 480]) == "640 × 480 pixels")
        #expect(en.format("hexDump.truncated", arguments: [1]) == "… (truncated, 1 byte total)")
        #expect(en.format("bodyContent.captureLimit", arguments: [1, "1 byte"]) == "Body too large; only the first 1 byte (1 byte) was captured")
        #expect(en.format("rules.list.count", arguments: [1]) == "1 rule")
        #expect(en.format("rules.list.count", arguments: [0]) == "0 rules")
        // The plural variables print only the noun; the sizes come from the preformatted text.
        let limits = en.format("advancedPane.deletionLimits", arguments: [10_000, "10,000", 1_073_741_824, "1 GB"])
        #expect(limits == "When there are more than 10,000 sessions or cached bodies exceed 1 GB, the oldest sessions are deleted. Deleted sessions can no longer be viewed or exported.")
        #expect(en.format("advancedPane.deletionLimits", arguments: [1, "1", 1, "1 byte"]).contains("more than 1 session or"))
        #expect(en.format("webSocket.export.complete", arguments: ["1", "0", "2", 1]) == "JSONL export complete: 1 message exported, 0 omitted at cutoff, 2 missing.")
        #expect(en.format("webSocket.export.partial", arguments: ["2,048", "1", "0", 2_048]).contains("2,048 messages exported"))
        #expect(en.format("webSocket.pageCount", arguments: ["1", "200", 1]) == "Showing 1 message on this page, up to 200.")
        #expect(en.format("webSocket.byteCount", arguments: ["1", 1]) == "1 byte")
        #expect(en.format("webSocket.byteCount", arguments: ["1,024", 1_024]) == "1,024 bytes")
        #expect(en.format("webSocket.counts", arguments: ["1 byte", "0 bytes", "1", 1]) == "Observed wire data: 1 byte; application data: 0 bytes; 1 message omitted.")
        #expect(en.format("webSocket.fragments", arguments: ["1", "1", 1, 1]) == "1 fragment in total; 1 fragment description retained.")
        #expect(en.format("webSocket.fragments", arguments: ["3", "2", 3, 2]) == "3 fragments in total; 2 fragment descriptions retained.")
        #expect(en.format("compose.failure.timeout", arguments: ["1", 1]) == "The Compose request didn’t finish within 1 second and was cancelled as timed out.")
        #expect(en.format("compose.failure.timeout", arguments: ["1.5", 2]).contains("within 1.5 seconds"))
        #expect(en.format("rules.actionSummary.editHeaders.request", arguments: [1]) == "Edit request headers (1 item)")
        #expect(en.format("rules.actionSummary.editHeaders.response", arguments: [2]) == "Edit response headers (2 items)")
        let chinese = Localizer(bundle: L10n.bundle, preferredLanguages: ["zh-Hans"])
        #expect(chinese.format("statusBar.selectedRows", arguments: [3, 12]) == "已选 3 / 12 行")
        // Chinese reads the same text arguments as before, so its output is unchanged.
        #expect(chinese.format("webSocket.export.complete", arguments: ["1", "0", "2", 1]) == "JSONL 导出完成：已导出 1 条消息，截止时省略 0 条，缺失 2 条。")
        #expect(chinese.format("webSocket.byteCount", arguments: ["1,024", 1_024]) == "1,024 字节")
        #expect(chinese.format("webSocket.fragments", arguments: ["3", "2", 3, 2]) == "共 3 个片段，已保留 2 个片段描述。")
        #expect(chinese.format("compose.failure.timeout", arguments: ["60", 2]) == "Compose 请求在 60 秒内没有完成，已超时取消。")
        #expect(chinese.format("rules.actionSummary.editHeaders.request", arguments: [2]) == "修改请求 Header，共 2 项")
    }

    @Test func everyPluralEntryFormatsCleanlyForOneAndMany() throws {
        let en = Localizer(bundle: L10n.bundle, preferredLanguages: ["en"])
        for (key, entry) in try dictionary("en") {
            for count in [0, 1, 2, 1_000_000] {
                let arguments: [CVarArg] = try pluralArguments(entry).sorted {
                    Int($0.split(separator: ":")[0])! < Int($1.split(separator: ":")[0])!
                }.map { $0.hasSuffix(":@") ? "sample" : count as CVarArg }
                let text = en.format(key, arguments: arguments)
                #expect(!text.isEmpty && !text.contains("%") && !text.contains("#@"), "\(key) \(count): \(text)")
            }
        }
    }
}
