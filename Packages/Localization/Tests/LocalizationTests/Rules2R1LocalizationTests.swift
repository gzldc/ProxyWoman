import AppCore
import Foundation
import Localization
import RulesEngine
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

/// Every key rules 2.0 phase R1 adds. Later R1 tasks append their keys here.
private let r1Keys: [String] = [
    "rules.issue.unsupportedStructure",
    "rules.error.unavailable.migrationFailed",
    // Task 10: the old editor and the detail pane read the 2.0 model.
    "rules.error.migrationFailed.retry",
    "ruleOutcome.finalStop", "ruleOutcome.skippedAfterFinal", "ruleOutcome.occurrenceSkipped",
    "rules.summary.modeAny", "rules.summary.modeNone", "rules.summary.conditionsCount", "rules.summary.multiAction",
    "rules.kind.multiple",
    // Task 11: the one-time upgrade notice and its banner.
    "rules.upgrade.title", "rules.upgrade.intro", "rules.upgrade.introUnlisted",
    "rules.upgrade.class1.title", "rules.upgrade.class1.body", "rules.upgrade.class2.title", "rules.upgrade.class2.body",
    "rules.upgrade.class3.title", "rules.upgrade.class3.body",
    "rules.upgrade.pair", "rules.upgrade.omitted", "rules.upgrade.advice",
    "rules.upgrade.acknowledge", "rules.upgrade.reopen",
    "rules.upgrade.banner", "rules.upgrade.banner.open", "rules.upgrade.banner.dismiss",
]

/// The arguments the sentences of Task 10 take, by position: a rule name is `@`, a number is `d`.
private let task10Arguments: [String: [String]] = [
    "ruleOutcome.finalStop": ["1:@", "2:d"], "ruleOutcome.skippedAfterFinal": ["1:@", "2:d"],
    "ruleOutcome.occurrenceSkipped": ["1:@"], "rules.summary.modeAny": ["1:@"], "rules.summary.modeNone": ["1:@"],
    "rules.summary.conditionsCount": ["1:d"], "rules.summary.multiAction": ["1:d"],
    "rules.error.migrationFailed.retry": [], "rules.kind.multiple": [],
]

/// The arguments the sentences of Task 11 take, by position: a rule name is `@`, a count is `d`.
private let task11Arguments: [String: [String]] = [
    "rules.upgrade.pair": ["1:@", "2:@"], "rules.upgrade.omitted": ["1:d"], "rules.upgrade.introUnlisted": ["1:d"],
    "rules.upgrade.title": [], "rules.upgrade.intro": [], "rules.upgrade.advice": [],
    "rules.upgrade.class1.title": [], "rules.upgrade.class1.body": [], "rules.upgrade.class2.title": [],
    "rules.upgrade.class2.body": [], "rules.upgrade.class3.title": [], "rules.upgrade.class3.body": [],
    "rules.upgrade.acknowledge": [], "rules.upgrade.reopen": [], "rules.upgrade.banner": [],
    "rules.upgrade.banner.open": [], "rules.upgrade.banner.dismiss": [],
]

@Suite(.productionChinese) struct Rules2R1LocalizationTests {
    @Test func everyR1KeyExistsAndIsTranslatedInEveryLanguageWithTheSameArguments() throws {
        #expect(r1Keys.count == Set(r1Keys).count)
        let production = try strings(L10n.bundle, "zh-Hans")
        let fixtures = try fixtureBundle()
        let en = try strings(fixtures, "en")
        let fr = try strings(fixtures, "fr")
        let zh = try strings(fixtures, "zh-Hans")
        for key in r1Keys {
            let chinese = try #require(production[key], "\(key) missing in production")
            #expect(!chinese.isEmpty && chinese != key, "\(key)")
            #expect(zh[key] == chinese, "\(key): production and its fixture copy agree")
            let english = try #require(en[key], "\(key) missing in en")
            let french = try #require(fr[key], "\(key) missing in fr")
            // "key" itself is what an unresolved lookup would return.
            #expect(!english.isEmpty && !french.isEmpty, "\(key)")
            #expect(english != chinese && french != chinese && english != key && french != key, "\(key) is translated")
            #expect(specifiers(english) == specifiers(chinese) && specifiers(french) == specifiers(chinese), "\(key) arguments")
        }
    }

    @Test func unsupportedStructureIssueHasItsKeyAndASentenceInEveryLanguage() throws {
        #expect(RuleDraftIssue.unsupportedStructure.localizationKey == "rules.issue.unsupportedStructure")
        let fixtures = try fixtureBundle()
        let production = Localizer(bundle: L10n.bundle, preferredLanguages: ["zh-Hans"])
        let en = Localizer(bundle: fixtures, preferredLanguages: ["en"])
        let fr = Localizer(bundle: fixtures, preferredLanguages: ["fr"])
        let limits = RulesLimits()
        #expect(
            RuleDraftIssue.unsupportedStructure.message(limits: limits, localizer: production)
                == "这条规则的结构超出了当前编辑器能处理的范围。")
        let chinese = RuleDraftIssue.unsupportedStructure.message(limits: limits, localizer: production)
        #expect(RuleDraftIssue.unsupportedStructure.message(limits: limits, localizer: en) != chinese)
        #expect(RuleDraftIssue.unsupportedStructure.message(limits: limits, localizer: fr) != chinese)
    }

    @Test func task10SentencesTakeTheirArgumentsInEveryLanguage() throws {
        let production = try strings(L10n.bundle, "zh-Hans")
        let fixtures = try fixtureBundle()
        for language in ["en", "fr", "zh-Hans"] {
            let table = try strings(fixtures, language)
            for (key, expected) in task10Arguments {
                #expect(specifiers(try #require(table[key], "\(key) in \(language)")) == expected, "\(language) \(key)")
            }
        }
        for (key, expected) in task10Arguments {
            #expect(specifiers(try #require(production[key])) == expected, "production \(key)")
        }
    }

    @Test func task11SentencesTakeTheirArgumentsInEveryLanguage() throws {
        #expect(Set(task11Arguments.keys).isSubset(of: r1Keys) && task11Arguments.count == 17)
        let production = try strings(L10n.bundle, "zh-Hans")
        let fixtures = try fixtureBundle()
        for language in ["en", "fr", "zh-Hans"] {
            let table = try strings(fixtures, language)
            for (key, expected) in task11Arguments {
                #expect(specifiers(try #require(table[key], "\(key) in \(language)")) == expected, "\(language) \(key)")
            }
        }
        for (key, expected) in task11Arguments {
            #expect(specifiers(try #require(production[key])) == expected, "production \(key)")
        }
    }

    @Test func upgradeNoticeSentencesReadWellInChinese() throws {
        let production = Localizer(bundle: L10n.bundle, preferredLanguages: ["zh-Hans"])
        #expect(production.string("rules.upgrade.title") == "规则 2.0 改变了这几处行为")
        #expect(production.string("rules.upgrade.class1.title") == "返回文件（本地映射）和本地目录映射现在是最终动作")
        #expect(production.string("rules.upgrade.class3.title") == "同一目标被多条规则改写或映射（含本地目录映射）时依次执行")
        #expect(production.format("rules.upgrade.pair", arguments: ["甲", "乙"]) == "「甲」→「乙」")
        #expect(production.format("rules.upgrade.omitted", arguments: [12]) == "另有 12 对受影响的规则没有在这里列出。")
        #expect(production.string("rules.upgrade.acknowledge") == "知道了")
        #expect(production.string("rules.upgrade.reopen") == "查看升级说明")
        #expect(production.string("rules.upgrade.banner") == "规则 2.0 改变了部分规则的执行行为。")
        #expect(production.string("rules.upgrade.banner.open") == "查看")
        #expect(production.string("rules.upgrade.banner.dismiss") == "关闭")
    }

    /// The description under the Rules window's title states how the 2.0 evaluator treats the list: top to
    /// bottom on a current message, Map Local final, Map Remotes and status rewrites in sequence. The sentence
    /// of the first release ("the first matching map rule wins, the others stack") is gone in every language.
    @Test func theRulesWindowOrderSentenceDescribesTheRules2Evaluation() throws {
        let production = Localizer(bundle: L10n.bundle, preferredLanguages: ["zh-Hans"])
        let order = production.string("rules.window.order")
        #expect(
            order == "每个请求会按从上到下的顺序对照已启用的规则，每条规则的条件看到的是前面规则改过的内容。本地映射（文件或目录）是最终动作：命中后，排在它下面的规则不再对这条流量生效，排在它上面的规则仍然生效。远程映射和状态码改写会依次执行。")
        #expect(!order.contains("第一条命中") && !order.contains("叠加"))
        #expect(specifiers(order).isEmpty)

        let fixtures = try fixtureBundle()
        let expected: [String: [String]] = [
            "zh-Hans": ["从上到下", "最终动作", "下面的规则不再", "上面的规则仍然生效", "依次执行"],
            "en": ["top to bottom", "is final", "below it no longer apply", "above it still do", "in sequence"],
            "fr": ["de haut en bas", "est final", "en dessous ne s’appliquent plus", "au-dessus s’appliquent toujours", "l’un après l’autre"],
        ]
        let stale = ["en": "first matching map rule wins", "fr": "la première règle de redirection"]
        for language in ["zh-Hans", "en", "fr"] {
            let text = try #require(try strings(fixtures, language)["rules.window.order"], "\(language)")
            for phrase in try #require(expected[language]) { #expect(text.contains(phrase), "\(language) lacks “\(phrase)”: \(text)") }
            if let stale = stale[language] { #expect(!text.contains(stale), "\(language) still has the first-release rule") }
            #expect(specifiers(text).isEmpty, "\(language) takes no argument")
        }
        #expect(try strings(fixtures, "zh-Hans")["rules.window.order"] == order, "production and its fixture copy agree")
    }

    @Test func retryAndReadOnlySentencesNameTheirWayOut() throws {
        let production = Localizer(bundle: L10n.bundle, preferredLanguages: ["zh-Hans"])
        #expect(production.string("rules.error.migrationFailed.retry") == "重试迁移")
        #expect(production.string("rules.kind.multiple") == "多个动作")
        #expect(production.format("rules.summary.multiAction", arguments: [3]) == "3 个动作")
        #expect(production.format("rules.summary.conditionsCount", arguments: [2]) == "2 个条件")
        #expect(production.format("rules.summary.modeAny", arguments: ["GET *://a.test/*"]) == "GET *://a.test/*（任一满足）")
        #expect(production.format("rules.summary.modeNone", arguments: ["a"]) == "a（都不满足）")
        #expect(
            production.format("ruleOutcome.finalStop", arguments: ["甲", 2])
                == "规则「甲」的第 2 个动作是最终动作：本规则之后的动作和优先级更低的规则不再对这条流量生效。")
        #expect(
            production.format("ruleOutcome.skippedAfterFinal", arguments: ["甲", 3])
                == "规则「甲」的第 3 个动作没有执行：前面的最终动作已终止后续处理。")
        #expect(
            production.format("ruleOutcome.occurrenceSkipped", arguments: ["甲"])
                == "规则「甲」的条件已满足，但这次命中已超过指定次数，本次未执行。")
    }

    /// Every rules 2.0 key written out in production code is defined in production zh-Hans. The families are the
    /// ones this phase added; keys are always whole literals (see `LiteralKeyScanTests`), so a scan sees all of
    /// them, and a key that was renamed in the table but not in the code, or the other way round, fails here.
    @Test func everyRules2KeyLiteralInSourcesIsDefined() throws {
        let prefixes = [
            "rules.upgrade.", "rules.summary.", "rules.kind.multiple", "ruleOutcome.",
        ]
        let pattern = try NSRegularExpression(
            pattern: "\"((?:" + prefixes.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|") + #")[A-Za-z0-9_.]*)""#)
        let production = try strings(L10n.bundle, "zh-Hans")
        var used: Set<String> = []
        for file in try sourceFiles() {
            let text = try String(contentsOf: repositoryRoot.appendingPathComponent(file), encoding: .utf8)
            for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                used.insert((text as NSString).substring(with: match.range(at: 1)))
            }
        }
        // The scan is not vacuous: it sees the keys of every family, and everything it sees is defined.
        #expect(used.count >= 20)
        for prefix in prefixes { #expect(used.contains { $0.hasPrefix(prefix) }, "no literal of \(prefix) found in the sources") }
        #expect(used.subtracting(production.keys).sorted() == [])
        // And every key of this phase in those families is written out somewhere (none is only defined).
        let ofTheFamilies = r1Keys.filter { key in prefixes.contains { key.hasPrefix($0) } }
        #expect(ofTheFamilies.count == 25)
        #expect(ofTheFamilies.filter { !used.contains($0) } == [], "defined but never written out in the sources")
    }
}
