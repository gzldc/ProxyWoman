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

/// Task 8: the import preview text (added with the importer).
private let r7Task8Keys: [String] = [
    "rules.import.groupName",
    "rules.import.summary.rules",
    "rules.import.summary.groups",
    "rules.import.summary.files",
    "rules.import.note.newGroup",
    "rules.import.warning.lifted",
    "rules.import.warning.breakpointsDisabled",
    "rules.import.warning.ignoredFiles",
    "rules.import.defaultAssetName",
]

/// Task 9: menus, template names and notes, import and export text, and one sentence per pack error.
private let r7Task9Keys: [String] = [
    "rules.import.menu",
    "rules.export.selected",
    "rules.export.all",
    "rules.template.menu",
    "rules.template.group",
    "rules.import.title",
    "rules.import.fileName",
    "rules.import.confirm",
    "rules.import.cancel",
    "rules.import.close",
    "rules.import.working",
    "rules.import.done",
    "rules.export.panelTitle",
    "rules.export.done",
    "rules.export.skipped.title",
    "rules.export.skipped.directory",
    "rules.export.skipped.assetUnavailable",
    "rules.export.skipped.assetTooLarge",
    "rules.export.skipped.noteTooLong",
    "rules.pack.error.notAPack",
    "rules.pack.error.notThisFormat",
    "rules.pack.error.newerVersion",
    "rules.pack.error.undecodableContent",
    "rules.pack.error.tooLarge",
    "rules.pack.error.tooManyEntries",
    "rules.pack.error.expandedTooLarge",
    "rules.pack.error.assetTooLarge",
    "rules.pack.error.exportTooLarge",
    "rules.pack.error.nothingToExport",
    "rules.pack.error.unsafeEntry",
    "rules.pack.error.unexpectedEntry",
    "rules.pack.error.duplicateEntry",
    "rules.pack.error.encrypted",
    "rules.pack.error.unsupportedCompression",
    "rules.pack.error.symlink",
    "rules.pack.error.corrupt",
    "rules.pack.error.invalidRule",
    "rules.pack.error.invalidStructure",
    "rules.pack.error.directoryMapping",
    "rules.pack.error.missingAsset",
    "rules.pack.error.assetMismatch",
    "rules.pack.error.tooManyRules",
    "rules.pack.error.saveFailed",
    "rules.pack.error.readFailed",
    "rules.pack.error.cancelled",
    "rules.import.error.farxUnsupported",
    "rules.template.simulate404.name",
    "rules.template.simulate404.note",
    "rules.template.simulate500.name",
    "rules.template.simulate500.note",
    "rules.template.simulate429.name",
    "rules.template.simulate429.note",
    "rules.template.addCORSHeaders.name",
    "rules.template.addCORSHeaders.note",
    "rules.template.disableCaching.name",
    "rules.template.disableCaching.note",
    "rules.template.delay2Seconds.name",
    "rules.template.delay2Seconds.note",
    "rules.template.markDomain.name",
    "rules.template.markDomain.note",
    "rules.template.httpToHttps.name",
    "rules.template.httpToHttps.note",
    "rules.template.recordAllPOST.name",
    "rules.template.recordAllPOST.note",
    "rules.template.blockAnalytics.name",
    "rules.template.blockAnalytics.note",
    "rules.template.breakpointPUT.name",
    "rules.template.breakpointPUT.note",
    "rules.template.stripAuthorization.name",
    "rules.template.stripAuthorization.note",
    "rules.template.forceStatus200.name",
    "rules.template.forceStatus200.note",
    "rules.template.hideNoise.name",
    "rules.template.hideNoise.note",
    "rules.template.closeConnection.name",
    "rules.template.closeConnection.note",
]

private let r7Keys: [String] = r7Task8Keys + r7Task9Keys

/// The arguments each sentence takes, by position: text is `@`, a number is `d`. A key not listed takes none.
private let r7Arguments: [String: [String]] = [
    "rules.import.groupName": ["1:@"],
    "rules.import.summary.rules": ["1:d"],
    "rules.import.summary.groups": ["1:d"],
    "rules.import.summary.files": ["1:d", "2:@"],
    "rules.import.note.newGroup": ["1:@"],
    "rules.import.warning.lifted": ["1:d"],
    "rules.import.warning.breakpointsDisabled": ["1:d"],
    "rules.import.warning.ignoredFiles": ["1:d"],
    "rules.import.fileName": ["1:@"],
    "rules.import.working": ["1:d", "2:d"],
    "rules.import.done": ["1:d", "2:d"],
    "rules.export.done": ["1:d", "2:d"],
    "rules.export.skipped.title": ["1:d"],
    "rules.export.skipped.directory": ["1:@"],
    "rules.export.skipped.assetUnavailable": ["1:@"],
    "rules.export.skipped.assetTooLarge": ["1:@"],
    "rules.export.skipped.noteTooLong": ["1:@"],
    "rules.pack.error.newerVersion": ["1:d"],
    "rules.pack.error.tooLarge": ["1:@"],
    "rules.pack.error.assetTooLarge": ["1:@"],
    "rules.pack.error.invalidRule": ["1:d"],
    "rules.pack.error.tooManyRules": ["1:d", "2:d"],
]


/// The plan's key table (section "本地化键表"), written out independently of `r7Keys` so the audit below is not
/// circular. Template names and notes are covered by `templateKeysCoverAllFifteenIds`.
private let planTableKeys: [String] = [
    "rules.export.all",
    "rules.export.done",
    "rules.export.panelTitle",
    "rules.export.selected",
    "rules.export.skipped.assetTooLarge",
    "rules.export.skipped.noteTooLong",
    "rules.export.skipped.assetUnavailable",
    "rules.export.skipped.directory",
    "rules.export.skipped.title",
    "rules.import.cancel",
    "rules.import.close",
    "rules.import.confirm",
    "rules.import.defaultAssetName",
    "rules.import.done",
    "rules.import.error.farxUnsupported",
    "rules.import.fileName",
    "rules.import.groupName",
    "rules.import.menu",
    "rules.import.note.newGroup",
    "rules.import.summary.files",
    "rules.import.summary.groups",
    "rules.import.summary.rules",
    "rules.import.title",
    "rules.import.warning.breakpointsDisabled",
    "rules.import.warning.ignoredFiles",
    "rules.import.warning.lifted",
    "rules.import.working",
    "rules.pack.error.assetMismatch",
    "rules.pack.error.assetTooLarge",
    "rules.pack.error.cancelled",
    "rules.pack.error.corrupt",
    "rules.pack.error.directoryMapping",
    "rules.pack.error.duplicateEntry",
    "rules.pack.error.encrypted",
    "rules.pack.error.expandedTooLarge",
    "rules.pack.error.exportTooLarge",
    "rules.pack.error.invalidRule",
    "rules.pack.error.invalidStructure",
    "rules.pack.error.missingAsset",
    "rules.pack.error.newerVersion",
    "rules.pack.error.notAPack",
    "rules.pack.error.notThisFormat",
    "rules.pack.error.readFailed",
    "rules.pack.error.saveFailed",
    "rules.pack.error.symlink",
    "rules.pack.error.tooLarge",
    "rules.pack.error.tooManyEntries",
    "rules.pack.error.tooManyRules",
    "rules.pack.error.undecodableContent",
    "rules.pack.error.unexpectedEntry",
    "rules.pack.error.unsafeEntry",
    "rules.pack.error.unsupportedCompression",
    "rules.template.group",
    "rules.template.menu",
] + [
    "simulate404", "simulate500", "simulate429", "addCORSHeaders", "disableCaching", "delay2Seconds", "markDomain",
    "httpToHttps", "recordAllPOST", "blockAnalytics", "breakpointPUT", "stripAuthorization", "forceStatus200",
    "hideNoise", "closeConnection",
].flatMap { ["rules.template.\($0).name", "rules.template.\($0).note"] }

/// Table keys deliberately not added. None: every key of the table exists. (Keys beyond the table, such as
/// `rules.pack.error.nothingToExport`, are fine; they are in `r7Keys` and audited like the rest.)
private let deliberatelyNotAdded: Set<String> = []

@Suite(.productionChinese) struct Rules2R7LocalizationTests {
    @Test func keysExistInProductionAndAllFixtures() throws {
        #expect(r7Keys.count == Set(r7Keys).count)
        let production = try strings(L10n.bundle, "zh-Hans")
        let fixtures = try fixtureBundle()
        let en = try strings(fixtures, "en")
        let fr = try strings(fixtures, "fr")
        let zh = try strings(fixtures, "zh-Hans")
        for key in r7Keys {
            let chinese = try #require(production[key], "\(key) missing in production")
            #expect(!chinese.isEmpty && chinese != key, "\(key)")
            #expect(zh[key] == chinese, "\(key): production and its fixture copy agree")
            let english = try #require(en[key], "\(key) missing in en")
            let french = try #require(fr[key], "\(key) missing in fr")
            #expect(!english.isEmpty && !french.isEmpty, "\(key)")
            #expect(english != key && french != key, "\(key) is translated")
            #expect(specifiers(english) == specifiers(chinese) && specifiers(french) == specifiers(chinese), "\(key) arguments")
            #expect(specifiers(chinese) == (r7Arguments[key] ?? []), "\(key) argument table")
        }
    }

    @Test func everyPlanTableKeyIsAuditedAndPresent() throws {
        #expect(planTableKeys.count == Set(planTableKeys).count)
        let audited = Set(r7Keys)
        let production = try strings(L10n.bundle, "zh-Hans")
        let fixtures = try fixtureBundle()
        let translations = try ["en", "fr", "zh-Hans"].map { try strings(fixtures, $0) }
        for key in planTableKeys where !deliberatelyNotAdded.contains(key) {
            #expect(audited.contains(key), "\(key) is in the plan table but not audited")
            #expect(production[key] != nil, "\(key) missing in production")
            for table in translations { #expect(table[key] != nil, "\(key) missing in a fixture") }
        }
    }

    @Test func templateKeysCoverAllFifteenIds() {
        let ids = ["simulate404", "simulate500", "simulate429", "addCORSHeaders", "disableCaching", "delay2Seconds", "markDomain",
                   "httpToHttps", "recordAllPOST", "blockAnalytics", "breakpointPUT", "stripAuthorization", "forceStatus200",
                   "hideNoise", "closeConnection"]
        for id in ids {
            #expect(r7Keys.contains("rules.template.\(id).name") && r7Keys.contains("rules.template.\(id).note"), "\(id)")
        }
        #expect(r7Task9Keys.count == 76 && r7Task8Keys.count == 9)
    }

    @Test func sampleSentences() {
        let zh = Localizer(bundle: L10n.bundle, preferredLanguages: ["zh-Hans"])
        #expect(zh.format("rules.pack.error.invalidRule", arguments: [2]) == "第 2 条规则无效，整包未导入")
        #expect(zh.format("rules.pack.error.tooManyRules", arguments: [5, 4]) == "导入后规则数会达到 5，超过上限 4")
        #expect(zh.string("rules.template.simulate404.name") == "模拟 404")
    }
}
