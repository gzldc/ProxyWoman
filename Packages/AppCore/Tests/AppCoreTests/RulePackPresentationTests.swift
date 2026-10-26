import Foundation
import Localization
import RulesEngine
import Testing

@testable import AppCore

private let zh = Localizer(bundle: L10n.bundle, preferredLanguages: ["zh-Hans"])

private func build(
    rules: Int = 3, groups: Int = 1, files: [Int64] = [], lifted: Int = 0, breakpoints: Int = 0, ignored: Int = 0
) -> RulePackPresentation.Preview {
    RulePackPresentation.build(
        wrapperName: "导入 · X", rules: rules, groups: groups, fileBytes: files, lifted: lifted, breakpoints: breakpoints,
        ignored: ignored, fileName: "X.pwrules", localizer: zh)
}

@Suite(.productionChinese) struct RulePackPresentationTests {
    static let allErrors: [RulePackError] = [
        .exportTooLarge, .nothingToExport, .notAPack, .notThisFormat, .newerVersion(7), .undecodableContent,
        .tooLarge(limit: 134_217_728), .tooManyEntries, .expandedTooLarge, .assetTooLarge(limit: 67_108_864),
        .unsafeEntry, .unexpectedEntry, .duplicateEntry, .encrypted, .unsupportedCompression, .symlink, .corrupt,
        .invalidRule(index: 1), .invalidStructure, .directoryMapping, .missingAsset, .assetMismatch,
        .tooManyRules(have: 501, limit: 500), .saveFailed, .readFailed, .cancelled, .farxUnsupported,
    ]

    @Test func everyPackErrorHasADistinctNonEmptyMessage() {
        let messages = Self.allErrors.map { RulePackPresentation.message($0, localizer: zh) }
        #expect(Set(messages).count == messages.count)
        for (error, message) in zip(Self.allErrors, messages) {
            #expect(!message.isEmpty && !message.contains("%") && !message.contains("rules.pack."), "\(error): \(message)")
        }
        for language in ["en", "fr"] {
            let localizer = Localizer(bundle: L10n.bundle, preferredLanguages: [language])
            #expect(Self.allErrors.allSatisfy { !RulePackPresentation.message($0, localizer: localizer).isEmpty })
        }
    }

    @Test func newerVersionMessageNamesTheNumber() {
        #expect(RulePackPresentation.message(.newerVersion(7), localizer: zh).contains("7"))
    }

    @Test func invalidRuleMessageIsOneBased() {
        #expect(RulePackPresentation.message(.invalidRule(index: 1), localizer: zh) == "第 2 条规则无效，整包未导入")
    }

    @Test func tooManyRulesMessageNamesBothNumbers() {
        #expect(RulePackPresentation.message(.tooManyRules(have: 501, limit: 500), localizer: zh) == "导入后规则数会达到 501，超过上限 500")
    }

    @Test func limitsAreShownAsSizes() {
        let text = RulePackPresentation.message(.tooLarge(limit: 134_217_728), localizer: zh)
        #expect(text.contains(RulePackPresentation.byteCount(134_217_728)))
    }

    @Test func previewLinesCountRulesGroupsAndFiles() {
        #expect(build(files: []).lines == ["3 条规则", "1 个分组"])
        let withFiles = build(files: [1000, 2000])
        #expect(withFiles.lines.count == 3)
        #expect(withFiles.lines[2] == "2 个返回文件（共 \(RulePackPresentation.byteCount(3000))）")
        #expect(withFiles.fileName == "X.pwrules" && withFiles.groupName == "导入 · X")
        #expect(withFiles.note.contains("导入 · X"))
    }

    @Test func warningsAppearOnlyWhenNonZero() {
        #expect(build().warnings.isEmpty)
        #expect(build(lifted: 2).warnings == ["有 2 个分组嵌套过深，已上移一层"])
        #expect(build(breakpoints: 1).warnings.count == 1)
        #expect(build(ignored: 4).warnings == ["忽略了 4 个未被规则使用的文件"])
        #expect(build(lifted: 1, breakpoints: 1, ignored: 1).warnings.count == 3)
    }

    @Test func groupNameStripsExtensionAndTruncates() {
        #expect(RulePackPresentation.groupName(forFile: "Shared.pwrules", localizer: zh) == "导入 · Shared")
        #expect(RulePackPresentation.groupName(forFile: ".pwrules", localizer: zh) == "导入 · .pwrules")
        let long = String(repeating: "规", count: 40) + ".pwrules"  // 120 bytes of 3-byte characters
        let name = RulePackPresentation.groupName(forFile: long, localizer: zh)
        let body = String(name.dropFirst("导入 · ".count))
        #expect(body.utf8.count <= 80 && body.utf8.count == 78)
        #expect(body.allSatisfy { $0 == "规" })
        let emoji = RulePackPresentation.groupName(forFile: String(repeating: "👩‍👩‍👧", count: 10), localizer: zh)
        #expect(String(emoji.dropFirst("导入 · ".count)).utf8.count <= 80)
    }

    @Test func skippedLinesUseOneKeyPerReason() {
        let id = UUID()
        let lines = RulePackPresentation.skippedLines(
            [
                SkippedRule(ruleID: id, name: "a", reason: .directoryMapping),
                SkippedRule(ruleID: id, name: "b", reason: .assetUnavailable),
                SkippedRule(ruleID: id, name: "c", reason: .assetTooLarge),
                SkippedRule(ruleID: id, name: "d", reason: .noteTooLong),
            ], localizer: zh)
        #expect(lines == [
            "「a」：返回目录的规则不能导出（目录授权只在本机有效）", "「b」：它用到的文件已不可用", "「c」：它用到的文件超过 64 MiB",
            "「d」：备注太长",
        ])
        let capped = RulePackPresentation.skippedLines(
            [SkippedRule(ruleID: id, name: String(repeating: "x", count: 500), reason: .assetUnavailable)], localizer: zh)
        #expect(capped[0].utf8.count < 200)
    }

    @Test func finishedAndExportedSummaries() {
        #expect(RulePackPresentation.finished(rules: 3, groups: 2, localizer: zh) == "已导入 3 条规则、2 个分组")
        #expect(RulePackPresentation.exported(rules: 3, groups: 2, localizer: zh) == "已导出 3 条规则、2 个分组")
        #expect(RulePackPresentation.skippedTitle(count: 2, localizer: zh) == "有 2 条规则未导出")
    }
}
