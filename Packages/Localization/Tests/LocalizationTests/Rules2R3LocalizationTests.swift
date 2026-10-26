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

private let fieldNames = [
    "allSessions", "url", "scheme", "host", "port", "method", "path", "queryString", "pathAndQuery", "queryParam",
    "requestHeader", "responseHeader", "requestCookie", "responseCookie", "requestBody", "responseBody",
    "requestBodySize", "responseBodySize", "statusCode", "sessionState", "durationMs", "requestTime", "requestDate",
    "clientHTTPVersion", "upstreamHTTPVersion", "clientTLSVersion", "upstreamTLSVersion", "certificate", "clientIP",
    "remoteIP", "clientApp", "appProtocol", "rulesModified", "comment",
]
private let operatorNames = [
    "equals", "notEquals", "contains", "notContains", "startsWith", "endsWith", "isEmpty", "isNotEmpty", "regex",
    "greaterThan", "greaterOrEqual", "lessThan", "lessOrEqual", "inRange", "before", "after", "hostPattern",
    "wildcard", "regexWhole",
]

/// Task 2: the condition catalogue and the row errors.
private let task2Keys: [String] = [
    fieldNames.map { "rules.condition.field.\($0)" },
    operatorNames.map { "rules.condition.op.\($0)" },
    ["common", "request", "response", "connection", "afterCompletion", "other"].map { "rules.condition.fieldGroup.\($0)" },
    ["rules.condition.afterCompletion.tag"],
    ["completed", "failed", "tunnel"].map { "rules.condition.state.\($0)" },
    ["http", "websocket", "grpc", "socketio", "sse"].map { "rules.condition.appProtocol.\($0)" },
    ["rules.condition.bool.true", "rules.condition.bool.false"],
    [
        "rules.issue.conditionNameRequired", "rules.issue.unexpectedConditionName", "rules.issue.invalidConditionName",
        "rules.issue.invalidConditionValue", "rules.issue.invalidConditionOperator",
    ],
].flatMap { $0 }

/// Task 5: the completion point's validation error.
private let task5Keys = ["rules.issue.actionNotAllowedAtCompletion"]

/// Task 11: the failure pages of a request body peek that had already taken bytes from the client.
private let task11Keys = ["proxyLocalFailure.peekBodyTimeout", "proxyLocalFailure.peekBodyUnavailable"]
private let task12Keys = ["proxyLocalFailure.peekResponseBodyTimeout", "proxyLocalFailure.peekResponseBodyUnavailable"]

/// Task 13: the live match count under the old rule form, and the list's "rule matches" chip.
private let task13Keys = [
    "rules.liveCount.skippedLargeBodies", "rules.liveCount.view", "quickFilterBar.ruleMatches", "quickFilterBar.clearRuleMatches",
]

/// Task 14: the condition summaries and the sentences for the outcomes the conditions can have.
private let task14Keys = [
    "rules.conditionSummary.row", "rules.conditionSummary.rowNamed", "rules.conditionSummary.rowNoValue",
    "rules.conditionSummary.rowNamedNoValue", "rules.conditionSummary.mode.all", "rules.conditionSummary.mode.any",
    "rules.conditionSummary.mode.none", "rules.conditionSummary.separator", "ruleOutcome.unknownSize",
    "ruleOutcome.appUnknown", "ruleOutcome.bodyTooLarge", "ruleOutcome.bodySkippedOnDisk",
    "ruleOutcome.bodySkippedStreaming", "ruleOutcome.bodySkippedNotText",
]

/// Every key rules 2.0 phase R3 adds. Later R3 tasks append their keys here.
private let r3Keys: [String] = task2Keys + task5Keys + task11Keys + task12Keys + task13Keys + task14Keys

/// The arguments each sentence takes, by position: text is `@`, a number is `d`. A key not listed takes none.
private let r3Arguments: [String: [String]] = [
    "rules.liveCount.skippedLargeBodies": ["1:d"],
    "quickFilterBar.ruleMatches": ["1:d"],
    "rules.conditionSummary.row": ["1:@", "2:@", "3:@"],
    "rules.conditionSummary.rowNamed": ["1:@", "2:@", "3:@", "4:@"],
    "rules.conditionSummary.rowNoValue": ["1:@", "2:@"],
    "rules.conditionSummary.rowNamedNoValue": ["1:@", "2:@", "3:@"],
    "rules.conditionSummary.mode.all": ["1:@"],
    "rules.conditionSummary.mode.any": ["1:@"],
    "rules.conditionSummary.mode.none": ["1:@"],
    "ruleOutcome.unknownSize": ["1:@"],
    "ruleOutcome.appUnknown": ["1:@"],
    "ruleOutcome.bodyTooLarge": ["1:@"],
    "ruleOutcome.bodySkippedOnDisk": ["1:@"],
    "ruleOutcome.bodySkippedStreaming": ["1:@"],
    "ruleOutcome.bodySkippedNotText": ["1:@"],
]

private let sourceRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// Every production Swift source (the app target and all packages' Sources).
private func productionSources() throws -> [URL] {
    var roots = [sourceRoot.appendingPathComponent("App")]
    let packages = sourceRoot.appendingPathComponent("Packages")
    for package in try FileManager.default.contentsOfDirectory(atPath: packages.path) {
        roots.append(packages.appendingPathComponent(package).appendingPathComponent("Sources"))
    }
    var files: [URL] = []
    for directory in roots {
        guard let enumerator = FileManager.default.enumerator(atPath: directory.path) else { continue }
        for case let name as String in enumerator where name.hasSuffix(".swift") {
            files.append(directory.appendingPathComponent(name))
        }
    }
    return files
}

@Suite(.productionChinese) struct Rules2R3LocalizationTests {
    @Test func everyR3KeyExistsAndIsTranslatedInEveryLanguageWithTheSameArguments() throws {
        #expect(r3Keys.count == Set(r3Keys).count)
        let production = try strings(L10n.bundle, "zh-Hans")
        let fixtures = try fixtureBundle()
        let en = try strings(fixtures, "en")
        let fr = try strings(fixtures, "fr")
        let zh = try strings(fixtures, "zh-Hans")
        for key in r3Keys {
            let chinese = try #require(production[key], "\(key) missing in production")
            #expect(!chinese.isEmpty && chinese != key, "\(key)")
            #expect(zh[key] == chinese, "\(key): production and its fixture copy agree")
            let english = try #require(en[key], "\(key) missing in en")
            let french = try #require(fr[key], "\(key) missing in fr")
            #expect(!english.isEmpty && !french.isEmpty, "\(key)")
            #expect(english != key && french != key, "\(key) is translated")
            #expect(specifiers(english) == specifiers(chinese) && specifiers(french) == specifiers(chinese), "\(key) arguments")
            #expect(specifiers(chinese) == (r3Arguments[key] ?? []), "\(key) argument table")
        }
    }

    @Test func task2CatalogueKeysCountAsTheTableSays() {
        #expect(fieldNames.count == 34)
        #expect(operatorNames.count == 19)
        #expect(task2Keys.count == 34 + 19 + 6 + 1 + 3 + 5 + 2 + 5)
    }

    @Test func task2SentencesReadWellInChinese() {
        let production = Localizer(bundle: L10n.bundle, preferredLanguages: ["zh-Hans"])
        #expect(production.string("rules.condition.field.requestHeader") == "请求 Header")
        #expect(production.string("rules.condition.field.durationMs") == "耗时")
        #expect(production.string("rules.condition.field.pathAndQuery") == "路径与查询（旧式）")
        #expect(production.string("rules.condition.op.greaterOrEqual") == "大于或等于")
        #expect(production.string("rules.condition.op.regexWhole") == "整串正则（旧式）")
        #expect(production.string("rules.condition.fieldGroup.afterCompletion") == "完成后")
        #expect(production.string("rules.condition.afterCompletion.tag") == "完成后")
        #expect(production.string("rules.condition.state.tunnel") == "隧道")
        #expect(production.string("rules.condition.appProtocol.socketio") == "Socket.IO")
        #expect(production.string("rules.condition.bool.true") == "是")
        #expect(production.string("rules.issue.conditionNameRequired") == "请填写名称。")
        #expect(production.string("rules.issue.invalidConditionValue") == "值的格式不对。")
        #expect(production.string("rules.issue.invalidConditionOperator") == "这个字段不能用这种比较方式。")
    }

    @Test func task5SentenceReadsWellInChinese() {
        let production = Localizer(bundle: L10n.bundle, preferredLanguages: ["zh-Hans"])
        #expect(
            production.string("rules.issue.actionNotAllowedAtCompletion")
                == "这条规则要等整条流量结束才能判定（因为用了「耗时 / 响应大小 / 会话状态」），那时只能做标记、注释或不显示。")
    }

    @Test func task13SentencesReadWellInChinese() {
        let production = Localizer(bundle: L10n.bundle, preferredLanguages: ["zh-Hans"])
        #expect(production.format("rules.liveCount.skippedLargeBodies", arguments: [2]) == "其中 2 条因正文较大被跳过")
        #expect(production.string("rules.liveCount.view") == "查看")
        #expect(production.format("quickFilterBar.ruleMatches", arguments: [5]) == "规则命中 5 条")
        #expect(production.string("quickFilterBar.clearRuleMatches") == "清除规则命中筛选")
    }

    @Test func task14SentencesReadWellInChinese() {
        let production = Localizer(bundle: L10n.bundle, preferredLanguages: ["zh-Hans"])
        #expect(production.format("rules.conditionSummary.row", arguments: ["状态码", "等于", "404"]) == "状态码 等于 404")
        #expect(
            production.format("rules.conditionSummary.rowNamed", arguments: ["请求 Header", "X-Test", "等于", "1"])
                == "请求 Header（X-Test）等于 1")
        #expect(production.format("rules.conditionSummary.rowNoValue", arguments: ["请求正文", "为空"]) == "请求正文 为空")
        #expect(
            production.format("rules.conditionSummary.rowNamedNoValue", arguments: ["响应 Header", "Location", "不为空"])
                == "响应 Header（Location）不为空")
        #expect(production.format("rules.conditionSummary.mode.all", arguments: ["A"]) == "全部满足：A")
        #expect(production.format("rules.conditionSummary.mode.any", arguments: ["A"]) == "任一满足：A")
        #expect(production.format("rules.conditionSummary.mode.none", arguments: ["A"]) == "都不满足：A")
        #expect(production.string("rules.conditionSummary.separator") == "；")
        #expect(
            production.format("ruleOutcome.bodySkippedNotText", arguments: ["R"]) == "规则「R」没有读取或改写正文：它不是可解码的文本。")
    }

    /// The families of keys this phase adds are always written out in full and are all defined.
    @Test func everyConditionKeyLiteralInSourcesIsDefined() throws {
        let production = try strings(L10n.bundle, "zh-Hans")
        let prefixes = ["rules.condition.", "rules.conditionSummary.", "rules.liveCount.", "rules.issue.condition"]
        let pattern = try NSRegularExpression(
            pattern: "\"((?:" + prefixes.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|") + #")[A-Za-z0-9_.]*)""#)
        var used: Set<String> = []
        for file in try productionSources() {
            let text = try String(contentsOf: file, encoding: .utf8)
            for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                used.insert((text as NSString).substring(with: match.range(at: 1)))
            }
        }
        // The catalogue of fields and the summaries use many of them.
        #expect(used.count > 60, "\(used.count)")
        #expect(used.subtracting(production.keys).sorted() == [])
        // And the other way: every key of the plan's table that has a user is used by a source literal.
        let table = Set(r3Keys.filter { key in prefixes.contains { key.hasPrefix($0) } })
        let unusedByTables = table.subtracting(used).filter {
            // Choice titles and the group headers are the R5 editor's data; R3 defines them with the catalogue.
            !$0.hasPrefix("rules.condition.fieldGroup.") && !$0.hasPrefix("rules.condition.state.")
                && !$0.hasPrefix("rules.condition.appProtocol.") && $0 != "rules.condition.afterCompletion.tag"
                && !$0.hasPrefix("rules.issue.condition")
        }
        #expect(unusedByTables.sorted() == [])
    }

    @Test func conditionKeysOfTheTableExistInProductionAndAllThreeFixtures() throws {
        let production = try strings(L10n.bundle, "zh-Hans")
        let fixtures = try fixtureBundle()
        let tables = [try strings(fixtures, "en"), try strings(fixtures, "fr"), try strings(fixtures, "zh-Hans")]
        for key in r3Keys {
            #expect(production[key] != nil, "\(key)")
            for table in tables { #expect(table[key] != nil, "\(key)") }
        }
    }
}
