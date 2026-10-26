import Foundation
import Localization
import Testing

private func fixtureBundle() throws -> Bundle {
    let url = try #require(Bundle.module.url(forResource: "Translations", withExtension: "bundle", subdirectory: "Fixtures"))
    return try #require(Bundle(url: url))
}

private func strings(_ bundle: Bundle, _ language: String) throws -> [String: String] {
    let url = try #require(bundle.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: language))
    return try #require(NSDictionary(contentsOf: url) as? [String: String])
}

/// Positional conversion types, so reordered translations compare equal.
private func specifiers(_ format: String) -> [String] {
    let pattern = try! NSRegularExpression(pattern: #"%(?:([0-9]+)\$)?[-+ #0-9.]*(?:hh|h|ll|l|q|L|z|j|t)?([@dDuUxXoOfeEgGcCsSp])"#)
    let text = format.replacingOccurrences(of: "%%", with: "")
    return pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).enumerated().map { index, match in
        let position = Range(match.range(at: 1), in: text).map { String(text[$0]) } ?? String(index + 1)
        return position + ":" + (Range(match.range(at: 2), in: text).map { String(text[$0]) } ?? "")
    }.sorted()
}

private let repositoryRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// Every Swift source file of the app target and of all packages (tests excluded), relative to the repository root.
private func sourceFiles() throws -> [String] {
    var files: [String] = []
    var roots = [repositoryRoot.appendingPathComponent("App")]
    let packages = repositoryRoot.appendingPathComponent("Packages")
    for package in try FileManager.default.contentsOfDirectory(atPath: packages.path) {
        roots.append(packages.appendingPathComponent(package).appendingPathComponent("Sources"))
    }
    for directory in roots {
        guard let enumerator = FileManager.default.enumerator(atPath: directory.path) else { continue }
        for case let name as String in enumerator where name.hasSuffix(".swift") {
            files.append(String(directory.appendingPathComponent(name).path.dropFirst(repositoryRoot.path.count + 1)))
        }
    }
    return files
}

/// Every key rules 2.0 phase R2 adds. Later R2 tasks append their keys here.
private let r2Keys: [String] = [
    // Task 9: mark colours and the annotation sentences.
    "mark.color.red", "mark.color.orange", "mark.color.yellow", "mark.color.green",
    "mark.color.cyan", "mark.color.blue", "mark.color.purple", "mark.color.gray", "mark.color.custom",
    "flowAnnotation.mark.line", "flowAnnotation.mark.sourceRule", "flowAnnotation.mark.sourceManual",
    "flowAnnotation.comment.line",
    // Task 10: the rules editor's mark, comment and hide rules.
    "rules.kind.mark", "rules.kind.comment", "rules.kind.hide",
    "rules.actionSummary.mark", "rules.actionSummary.markText",
    "rules.actionSummary.comment.set", "rules.actionSummary.comment.append",
    "rules.actionSummary.comment.findReplace", "rules.actionSummary.comment.clear", "rules.actionSummary.hide",
    "rules.mark.text",
    "rules.comment.mode.set", "rules.comment.mode.append",
    "rules.comment.mode.findReplace", "rules.comment.mode.clear",
    "rules.warning.hideEverything",
    "rules.issue.invalidMarkColor", "rules.issue.markTextTooLong", "rules.issue.commentTooLong",
    "rules.issue.commentRequired", "rules.issue.commentFindRequired",
    // Task 11: the flow table's comment column.
    "traffic.column.comment",
    // Task 12: the flow context menu's mark and comment entries and the comment prompt.
    "flowMenu.mark", "flowMenu.mark.custom", "flowMenu.mark.clear", "flowMenu.comment.add", "flowMenu.comment.edit",
    "comment.prompt.title", "comment.prompt.message", "comment.prompt.save", "comment.prompt.clear",
    // Task 13: rule results in the detail pane, the annotation filters and the export notice.
    "ruleOutcome.applied", "ruleOutcome.appliedAction", "ruleOutcome.rejected", "ruleOutcome.unsupportedUpgradeAction",
    "flowDetail.rules.title",
    "quickFilterBar.annotations", "quickFilterBar.hasMark", "quickFilterBar.rulesModified",
    "quickFilterBar.commentContains", "quickFilterBar.commentPopoverTitle", "quickFilterBar.clearAnnotations",
    "mainWindow.exportExcludedHidden",
]

/// The arguments each sentence takes, by position: text is `@`, a number is `d`. A key not listed takes none.
private let r2Arguments: [String: [String]] = [
    "flowAnnotation.mark.line": ["1:@"], "flowAnnotation.mark.sourceRule": ["1:@"], "flowAnnotation.comment.line": ["1:@"],
    "rules.actionSummary.mark": ["1:@"], "rules.actionSummary.markText": ["1:@", "2:@"],
    "rules.actionSummary.comment.set": ["1:@"], "rules.actionSummary.comment.append": ["1:@"],
    "rules.actionSummary.comment.findReplace": ["1:@", "2:@"],
    "rules.issue.markTextTooLong": ["1:d"], "rules.issue.commentTooLong": ["1:d"],
    "ruleOutcome.applied": ["1:@"], "ruleOutcome.appliedAction": ["1:@", "2:d"],
    "ruleOutcome.rejected": ["1:@"], "ruleOutcome.unsupportedUpgradeAction": ["1:@"],
    "mainWindow.exportExcludedHidden": ["1:d"],
]

@Suite(.productionChinese) struct Rules2R2LocalizationTests {
    @Test func everyR2KeyExistsAndIsTranslatedInEveryLanguageWithTheSameArguments() throws {
        #expect(r2Keys.count == Set(r2Keys).count)
        let production = try strings(L10n.bundle, "zh-Hans")
        let fixtures = try fixtureBundle()
        let en = try strings(fixtures, "en")
        let fr = try strings(fixtures, "fr")
        let zh = try strings(fixtures, "zh-Hans")
        for key in r2Keys {
            let chinese = try #require(production[key], "\(key) missing in production")
            #expect(!chinese.isEmpty && chinese != key, "\(key)")
            #expect(zh[key] == chinese, "\(key): production and its fixture copy agree")
            let english = try #require(en[key], "\(key) missing in en")
            let french = try #require(fr[key], "\(key) missing in fr")
            #expect(!english.isEmpty && !french.isEmpty, "\(key)")
            #expect(english != chinese && french != chinese && english != key && french != key, "\(key) is translated")
            #expect(specifiers(english) == specifiers(chinese) && specifiers(french) == specifiers(chinese), "\(key) arguments")
            #expect(specifiers(chinese) == (r2Arguments[key] ?? []), "\(key) argument table")
        }
    }

    @Test func task9SentencesReadWellInChinese() {
        let production = Localizer(bundle: L10n.bundle, preferredLanguages: ["zh-Hans"])
        #expect(production.format("flowAnnotation.mark.line", arguments: ["慢"]) == "标记：慢")
        #expect(production.format("flowAnnotation.mark.sourceRule", arguments: ["R"]) == "来源：规则「R」")
        #expect(production.string("flowAnnotation.mark.sourceManual") == "来源：手动标记")
        #expect(production.format("flowAnnotation.comment.line", arguments: ["好"]) == "注释：好")
        #expect(production.string("mark.color.custom") == "自定义颜色")
    }

    @Test func task11ColumnTitleReadsWellInChinese() {
        let production = Localizer(bundle: L10n.bundle, preferredLanguages: ["zh-Hans"])
        #expect(production.string("traffic.column.comment") == "注释")
    }

    @Test func task12MenuReadsWellInChinese() {
        let production = Localizer(bundle: L10n.bundle, preferredLanguages: ["zh-Hans"])
        #expect(production.string("flowMenu.mark") == "标记")
        #expect(production.string("flowMenu.mark.custom") == "自定义颜色…")
        #expect(production.string("flowMenu.mark.clear") == "清除标记")
        #expect(production.string("flowMenu.comment.add") == "添加注释…")
        #expect(production.string("flowMenu.comment.edit") == "编辑注释…")
        #expect(production.string("comment.prompt.clear") == "清除注释")
    }

    @Test func task10SentencesReadWellInChinese() {
        let production = Localizer(bundle: L10n.bundle, preferredLanguages: ["zh-Hans"])
        #expect(production.string("rules.kind.hide") == "不显示")
        #expect(production.format("rules.actionSummary.markText", arguments: ["红色", "慢"]) == "标记为红色：慢")
        #expect(production.format("rules.actionSummary.comment.findReplace", arguments: ["a", "b"]) == "注释中把「a」替换为「b」")
        #expect(production.format("rules.issue.commentTooLong", arguments: [10]) == "注释太长（最多 10 字节）。")
        #expect(production.string("rules.warning.hideEverything") == "没有填任何匹配条件：这条规则会隐藏所有流量。")
    }

    @Test func task13SentencesReadWellInChinese() {
        let production = Localizer(bundle: L10n.bundle, preferredLanguages: ["zh-Hans"])
        #expect(production.format("ruleOutcome.applied", arguments: ["R"]) == "规则「R」已应用。")
        #expect(production.format("ruleOutcome.appliedAction", arguments: ["R", 2]) == "规则「R」的第 2 个动作已应用。")
        #expect(production.string("flowDetail.rules.title") == "规则")
        #expect(production.string("quickFilterBar.hasMark") == "有标记")
        #expect(production.string("quickFilterBar.clearAnnotations") == "清除标记与注释过滤")
        #expect(production.format("mainWindow.exportExcludedHidden", arguments: [3]) == "已排除被规则隐藏的流量：3 条。")
    }

    /// Every annotation-related key literal written in production sources is defined in production zh-Hans.
    @Test func everyAnnotationKeyLiteralInSourcesIsDefined() throws {
        let prefixes = [
            "mark.color.", "flowAnnotation.", "flowMenu.mark", "flowMenu.comment", "comment.prompt.", "rules.mark.",
            "rules.comment.", "rules.hide.", "rules.actionSummary.", "rules.warning.hideEverything", "ruleOutcome.applied",
            "flowDetail.rules.", "quickFilterBar.",
        ]
        let pattern = try NSRegularExpression(
            pattern: "\"((?:" + prefixes.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|") + #")[A-Za-z0-9_.]*)""#)
        var used: Set<String> = []
        for file in try sourceFiles() {
            let text = try String(contentsOf: repositoryRoot.appendingPathComponent(file), encoding: .utf8)
            for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let range = Range(match.range(at: 1), in: text) { used.insert(String(text[range])) }
            }
        }
        #expect(used.count > 30)
        let production = try strings(L10n.bundle, "zh-Hans")
        #expect(used.filter { production[$0] == nil }.sorted() == [])
        // The table the plan lists for this phase is exactly what the scan finds under the annotation prefixes.
        #expect(r2Keys.filter { key in prefixes.contains { key.hasPrefix($0) } }.allSatisfy { used.contains($0) })
    }
}
