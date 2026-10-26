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

/// Task 2: the mark source line for an Execute mark.
private let r6Task2Keys: [String] = ["flowAnnotation.mark.sourceExecute"]

/// Every key rules 2.0 phase R6 adds. Later R6 tasks append their keys here.
/// Task 10: the Execute detail view, banner, compare window and run summary text.
private let r6Task10Keys: [String] = [
    "ruleOutcome.notApplicableOffline",
    "rules.execute.summary.title",
    "rules.execute.summary.cancelled",
    "rules.execute.summary.rule",
    "rules.execute.summary.modified",
    "rules.execute.summary.hidden",
    "rules.execute.summary.annotated",
    "rules.execute.summary.skippedInProgress",
    "rules.execute.summary.notApplicable",
    "rules.execute.summary.vanished",
    "flowDetail.execute.banner",
    "flowDetail.execute.bannerRecordOnly",
    "flowDetail.execute.viewOriginal",
    "flowDetail.execute.viewModified",
    "flowDetail.execute.compare",
    "flowDetail.execute.undo",
    "flowDetail.execute.showingOriginal",
    "flowDetail.execute.showingModified",
    "flowDetail.execute.results.title",
    "executeDiff.title",
    "executeDiff.request",
    "executeDiff.response",
    "executeDiff.noChanges",
    "executeDiff.target",
    "executeDiff.status",
    "executeDiff.header.added",
    "executeDiff.header.removed",
    "executeDiff.header.changed",
    "executeDiff.body.changed",
    "executeDiff.response.replaced",
]

/// Task 11: the Execute window and the rules window's run button and undo entry.
private let r6Task11Keys: [String] = [
    "rules.execute.run",
    "rules.execute.help",
    "rules.execute.window.title",
    "rules.execute.rules.all",
    "rules.execute.rules.selected",
    "rules.execute.scope.title",
    "rules.execute.scope.selected",
    "rules.execute.scope.filtered",
    "rules.execute.scope.all",
    "rules.execute.start",
    "rules.execute.cancel",
    "rules.execute.close",
    "rules.execute.running",
    "rules.execute.noRules",
    "rules.execute.noFlows",
    "rules.execute.undoRun",
    "rules.execute.undoLast",
    "rules.execute.undone",
]

/// Task 12: the outline's run column and the flow list's menu entry.
private let r6Task12Keys: [String] = [
    "rules.outline.column.run",
    "rules.outline.run.rule",
    "rules.outline.run.group",
    "flowMenu.execute",
]

private let r6Keys: [String] = r6Task2Keys + r6Task10Keys + r6Task11Keys + r6Task12Keys

/// The arguments each sentence takes, by position: text is `@`, a number is `d`. A key not listed takes none.
private let r6Arguments: [String: [String]] = [
    "flowAnnotation.mark.sourceExecute": ["1:@"],
    "ruleOutcome.notApplicableOffline": ["1:@"],
    "rules.execute.summary.rule": ["1:@", "2:d"],
    "rules.execute.summary.modified": ["1:d"],
    "rules.execute.summary.hidden": ["1:d"],
    "rules.execute.summary.annotated": ["1:d"],
    "rules.execute.summary.skippedInProgress": ["1:d"],
    "rules.execute.summary.notApplicable": ["1:d"],
    "rules.execute.summary.vanished": ["1:d"],
    "executeDiff.target": ["1:@", "2:@"],
    "executeDiff.status": ["1:d", "2:d"],
    "executeDiff.header.added": ["1:@", "2:@"],
    "executeDiff.header.removed": ["1:@", "2:@"],
    "executeDiff.header.changed": ["1:@", "2:@", "3:@"],
    "executeDiff.body.changed": ["1:d", "2:d"],
    "rules.execute.rules.all": ["1:d"],
    "rules.execute.rules.selected": ["1:d"],
    "rules.execute.scope.selected": ["1:d"],
    "rules.execute.scope.filtered": ["1:d"],
    "rules.execute.scope.all": ["1:d"],
    "rules.execute.running": ["1:d", "2:d"],
    "rules.execute.undone": ["1:d"],
]

@Suite(.productionChinese) struct Rules2R6LocalizationTests {
    @Test func everyR6KeyExistsAndIsTranslatedInEveryLanguageWithTheSameArguments() throws {
        #expect(r6Keys.count == Set(r6Keys).count)
        let production = try strings(L10n.bundle, "zh-Hans")
        let fixtures = try fixtureBundle()
        let en = try strings(fixtures, "en")
        let fr = try strings(fixtures, "fr")
        let zh = try strings(fixtures, "zh-Hans")
        for key in r6Keys {
            let chinese = try #require(production[key], "\(key) missing in production")
            #expect(!chinese.isEmpty && chinese != key, "\(key)")
            #expect(zh[key] == chinese, "\(key): production and its fixture copy agree")
            let english = try #require(en[key], "\(key) missing in en")
            let french = try #require(fr[key], "\(key) missing in fr")
            #expect(!english.isEmpty && !french.isEmpty, "\(key)")
            #expect(english != key && french != key, "\(key) is translated")
            #expect(specifiers(english) == specifiers(chinese) && specifiers(french) == specifiers(chinese), "\(key) arguments")
            #expect(specifiers(chinese) == (r6Arguments[key] ?? []), "\(key) argument table")
        }
    }

    @Test func task2Keys() {
        #expect(r6Task2Keys.count == 1)
        let zh = Localizer(bundle: L10n.bundle, preferredLanguages: ["zh-Hans"])
        #expect(zh.format("flowAnnotation.mark.sourceExecute", arguments: ["R"]) == "Execute · R")
    }

    @Test func task10Keys() {
        #expect(r6Task10Keys.count == 30)
        let zh = Localizer(bundle: L10n.bundle, preferredLanguages: ["zh-Hans"])
        #expect(zh.format("ruleOutcome.notApplicableOffline", arguments: ["R"]) == "「R」的动作不适用于已抓到的会话，已跳过")
        #expect(zh.format("executeDiff.body.changed", arguments: [1, 2]) == "正文：1 字节 → 2 字节")
    }

    @Test func task11Keys() {
        #expect(r6Task11Keys.count == 18)
        let zh = Localizer(bundle: L10n.bundle, preferredLanguages: ["zh-Hans"])
        #expect(zh.format("rules.execute.running", arguments: [3, 10]) == "正在执行… 3 / 10")
        #expect(zh.string("rules.execute.undoLast") == "撤销上次执行")
    }

    @Test func task12Keys() {
        #expect(r6Task12Keys.count == 4)
        let zh = Localizer(bundle: L10n.bundle, preferredLanguages: ["zh-Hans"])
        #expect(zh.string("flowMenu.execute") == "对此会话执行规则…")
        #expect(zh.string("rules.outline.run.group") == "执行这个分组")
    }

    /// Task 14: the audit. Every key in the plan's localization table (docs/superpowers/plans/2026-10-24-rules2-R6.md,
    /// shorthand expanded) is covered by `r6Keys`, so the test above asserts it in production and in all three
    /// fixtures with identical arguments. All table keys were added; none is excluded.
    @Test func auditCoversTheWholePlanTable() {
        let table: [String] = [
            "ruleOutcome.notApplicableOffline", "flowAnnotation.mark.sourceExecute",
            "rules.execute.run", "rules.execute.help", "rules.execute.window.title",
            "rules.execute.rules.all", "rules.execute.rules.selected",
            "rules.execute.scope.title", "rules.execute.scope.selected", "rules.execute.scope.filtered", "rules.execute.scope.all",
            "rules.execute.start", "rules.execute.cancel", "rules.execute.close", "rules.execute.running",
            "rules.execute.noRules", "rules.execute.noFlows",
            "rules.execute.summary.title", "rules.execute.summary.cancelled", "rules.execute.summary.rule",
            "rules.execute.summary.modified", "rules.execute.summary.hidden", "rules.execute.summary.annotated",
            "rules.execute.summary.skippedInProgress", "rules.execute.summary.notApplicable", "rules.execute.summary.vanished",
            "rules.execute.undoRun", "rules.execute.undoLast", "rules.execute.undone",
            "rules.outline.column.run", "rules.outline.run.rule", "rules.outline.run.group",
            "flowMenu.execute", "flowDetail.execute.banner", "flowDetail.execute.bannerRecordOnly",
            "flowDetail.execute.viewOriginal", "flowDetail.execute.viewModified", "flowDetail.execute.compare",
            "flowDetail.execute.undo", "flowDetail.execute.showingOriginal", "flowDetail.execute.showingModified",
            "flowDetail.execute.results.title",
            "executeDiff.title", "executeDiff.request", "executeDiff.response", "executeDiff.noChanges", "executeDiff.target",
            "executeDiff.status", "executeDiff.header.added", "executeDiff.header.removed", "executeDiff.header.changed",
            "executeDiff.body.changed", "executeDiff.response.replaced",
        ]
        #expect(table.count == Set(table).count)
        #expect(Set(table) == Set(r6Keys))
    }
}
