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

/// Keys added by R8F2 task 5 (condition model and presentation).
private let r8f2Task5Keys: [String] = [
    "rules.builder.matchedAt.either",
    "rules.editor3.operator.is",
    "rules.editor3.key.anyHeader",
    "rules.editor3.key.anyCookie",
    "rules.editor3.placeholder.url",
    "rules.editor3.placeholder.value",
    "rules.editor3.placeholder.headerValue",
    "rules.editor3.placeholder.date",
    "rules.editor3.scheme.https",
    "rules.editor3.scheme.http",
    "rules.editor3.cert.valid",
    "rules.editor3.cert.invalid",
    "rules.editor3.deprecated.tag",
    "rules.editor3.groupMatchCount",
    "rules.editor3.deprecation.single",
    "rules.editor3.deprecation.multiple",
    "rules.editor3.list.separator",
    "rules.editor3.list.lastJoiner",
    "rules.condition.certField.friendlyName",
    "rules.condition.certField.version",
    "rules.condition.certField.serialNumber",
    "rules.condition.certField.expirationDate",
    "rules.condition.certField.validity",
    "rules.condition.certField.issueDate",
    "rules.condition.certField.signature",
    "rules.condition.certField.publicKey",
    "rules.condition.certField.sha1Fingerprint",
    "rules.condition.certField.sha256Fingerprint",
    "rules.condition.certField.issuerCommonName",
    "rules.condition.certField.issuerCountry",
    "rules.condition.certField.issuerOrganization",
    "rules.condition.certField.subjectCommonName",
    "rules.condition.certField.subjectAlternativeName",
    "rules.condition.certField.subjectCountry",
    "rules.condition.certField.subjectOrganization",
]

@Suite(.productionChinese) struct Rules2R8F2T5LocalizationTests {
    @Test func everyKeyIsInProductionAndFixturesWithTheSameArguments() throws {
        #expect(r8f2Task5Keys.count == Set(r8f2Task5Keys).count)
        let production = try strings(L10n.bundle, "zh-Hans")
        let fixtures = try fixtureBundle()
        let en = try strings(fixtures, "en")
        let fr = try strings(fixtures, "fr")
        let zh = try strings(fixtures, "zh-Hans")
        for key in r8f2Task5Keys {
            let chinese = try #require(production[key], "\(key) missing in production")
            #expect(!chinese.isEmpty && chinese != key, "\(key)")
            #expect(zh[key] == chinese, "\(key): production and its fixture copy agree")
            let english = try #require(en[key], "\(key) missing in en")
            let french = try #require(fr[key], "\(key) missing in fr")
            #expect(!english.isEmpty && !french.isEmpty, "\(key)")
            #expect(specifiers(english) == specifiers(chinese) && specifiers(french) == specifiers(chinese), "\(key) arguments")
        }
    }

    @Test func renamedFieldsAndComparisonsReadAsSpecified() throws {
        let production = try strings(L10n.bundle, "zh-Hans")
        #expect(production["rules.condition.field.scheme"] == "协议方案")
        #expect(production["rules.condition.field.appProtocol"] == "协议")
        #expect(production["rules.condition.field.clientApp"] == "进程")
        #expect(production["rules.condition.field.durationMs"] == "耗时")
        #expect(production["rules.condition.field.upstreamHTTPVersion"] == "远端 HTTP 版本")
        #expect(production["rules.condition.op.regex"] == "正则表达式")
        #expect(production["rules.condition.op.greaterOrEqual"] == "大于或等于")
    }
}
