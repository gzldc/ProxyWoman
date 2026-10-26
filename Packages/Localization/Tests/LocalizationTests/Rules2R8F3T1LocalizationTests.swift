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

/// Keys added by R8F3 task 1 (the built-in template tree: nine groups, 28 rules).
private let r8f3Task1Keys: [String] = [
    "root", "allowBlock", "filters", "mapTraffic", "mapLocalManual", "mapLocalFile", "modifyTraffic", "tooling", "uiMarks",
].map { "rules.defaultTemplate.group.\($0)" } + [
    "allowOnlyProcesses", "allowOnlyHosts", "blockProcesses", "blockHosts", "hideConnectTunnels", "hideProcesses",
    "hideHosts", "showOnlyProcesses", "showOnlyHosts", "showOnlyLocalhost", "hideConnectsOfBlockedProcesses",
    "mapRemoteLocalhost", "mapRemoteURL", "redirect307", "manualReturnConnect", "manualReturnResponse",
    "fileReturnConnect", "fileReturnResponse", "insertHTMLRegex", "insertHTML", "modifyImageEndpoint",
    "userAgentChromeMac", "userAgentChromeWindows", "bypassCORS", "noCaching", "blockCookies",
    "markLongLivingSessions", "markScriptsAndJSON",
].map { "rules.defaultTemplate.rule.\($0)" }

@Suite(.productionChinese) struct Rules2R8F3T1LocalizationTests {
    @Test func thirtySevenKeys() {
        #expect(r8f3Task1Keys.count == 37 && Set(r8f3Task1Keys).count == 37)
    }

    @Test func everyKeyIsInProductionAndFixtures() throws {
        let production = try strings(L10n.bundle, "zh-Hans")
        let fixtures = try fixtureBundle()
        let en = try strings(fixtures, "en")
        let fr = try strings(fixtures, "fr")
        let zh = try strings(fixtures, "zh-Hans")
        for key in r8f3Task1Keys {
            let chinese = try #require(production[key], "\(key) missing in production")
            #expect(!chinese.isEmpty && chinese != key, "\(key)")
            #expect(zh[key] == chinese, "\(key): production and its fixture copy agree")
            #expect(!(en[key] ?? "").isEmpty && !(fr[key] ?? "").isEmpty, "\(key)")
            #expect(!chinese.contains("%"), "\(key): a plain name takes no argument")
        }
    }

    @Test func theGroupNamesReadAsSpecified() throws {
        let production = Localizer(bundle: L10n.bundle, preferredLanguages: ["zh-Hans"])
        let expected = [
            "root": "默认模板", "allowBlock": "允许与拦截列表", "filters": "过滤", "mapTraffic": "映射流量",
            "mapLocalManual": "本地映射（手动）", "mapLocalFile": "本地映射（文件）", "modifyTraffic": "修改流量",
            "tooling": "工具", "uiMarks": "界面标记",
        ]
        for (key, text) in expected { #expect(production.string("rules.defaultTemplate.group.\(key)") == text, "\(key)") }
        #expect(production.string("rules.defaultTemplate.rule.redirect307") == "以 307 重定向到 URL")
    }

    @Test func noNameCarriesTheReferenceBrand() throws {
        let fixtures = try fixtureBundle()
        for table in [try strings(L10n.bundle, "zh-Hans"), try strings(fixtures, "en"), try strings(fixtures, "fr")] {
            for key in r8f3Task1Keys {
                let text = table[key] ?? ""
                #expect(!text.contains("Fiddler") && !text.contains("Telerik") && !text.contains("Progress"), "\(key)")
            }
        }
    }
}
