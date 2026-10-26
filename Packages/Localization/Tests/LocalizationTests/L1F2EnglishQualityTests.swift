import Foundation
import Testing

@testable import Localization

/// Quality rules the production English strings follow (L1 fix wave F2).
@Suite struct L1F2EnglishQualityTests {
    private func english() throws -> [String: String] {
        let url = try #require(L10n.bundle.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: "en"))
        return try #require(NSDictionary(contentsOf: url) as? [String: String])
    }

    private func pluralStrings() throws -> [String] {
        let url = try #require(L10n.bundle.url(forResource: "Localizable", withExtension: "stringsdict", subdirectory: nil, localization: "en"))
        let root = try #require(NSDictionary(contentsOf: url) as? [String: [String: Any]])
        var found: [String] = []
        for entry in root.values {
            for value in entry.values {
                if let text = value as? String { found.append(text) }
                if let variable = value as? [String: Any] { found += variable.values.compactMap { $0 as? String } }
            }
        }
        return found
    }

    private let minorWords: Set<String> = ["a", "an", "and", "as", "at", "by", "for", "in", "of", "on", "or", "the", "to", "with"]

    private func isTitleCase(_ text: String) -> Bool {
        let words = text.split(separator: " ").map(String.init)
        for (index, word) in words.enumerated() {
            let bare = word.trimmingCharacters(in: CharacterSet(charactersIn: "()“”"))
            guard let first = bare.first, first.isLetter else { continue }
            if index > 0, minorWords.contains(bare) { continue }
            if !first.isUppercase { return false }
        }
        return true
    }

    @Test func operatorsAndFieldLabelsAreTitleCase() throws {
        let en = try english()
        let labels = en.filter {
            $0.key.hasPrefix("rules.condition.op.") || $0.key.hasPrefix("rules.condition.field.")
                || $0.key.hasPrefix("rules.condition.certField.") || $0.key.hasPrefix("rules.condition.certificate.")
                || $0.key.hasPrefix("rules.editor3.operator.") || $0.key.hasPrefix("rules.condition.fieldGroup.")
        }
        #expect(labels.count > 60)
        for (key, value) in labels { #expect(isTitleCase(value), "\(key): \(value)") }
        #expect(en["rules.condition.op.exists"] == "Exists")
        #expect(en["rules.condition.op.doesNotExist"] == "Does Not Exist")
        #expect(en["rules.condition.op.afterOrEqual"] == "On or After")
        #expect(en["rules.condition.op.beforeOrEqual"] == "On or Before")
        #expect(en["rules.editor3.operator.is"] == "Is")
    }

    @Test func englishUsesTypographicQuotesOnly() throws {
        for (key, value) in try english() {
            #expect(!value.contains("'") && !value.contains("\""), "\(key): \(value)")
        }
        for value in try pluralStrings() {
            #expect(!value.contains("'") && !value.contains("\""), Comment(rawValue: value))
        }
    }

    @Test func oneTermPerConcept() throws {
        let all = try english().values + (try pluralStrings())
        let banned = [
            "terminating action", "stop action", "Recording is", "recording is", "recording limit", "traffic list", "Traffic List",
            "main list", "SHA1", "SHA256", "Response Size", "Server IP", "Digest Auth ", "From time", "To time",
        ]
        for text in all {
            for phrase in banned { #expect(!text.contains(phrase), "“\(phrase)” in: \(text)") }
            #expect(!text.hasSuffix("Digest Auth"), Comment(rawValue: text))
        }
        let en = try english()
        #expect(en["rules.preset.unauthorized401"] == "401 Basic Authentication")
        #expect(en["rules.preset.digestAuth401"] == "401 Digest Authentication")
        #expect(en["rules.condition.certField.sha1Fingerprint"] == "SHA-1 Fingerprint")
        #expect(en["rules.condition.certField.sha256Fingerprint"] == "SHA-256 Fingerprint")
        #expect(en["overview.remoteIP"] == "Remote IP")
        #expect(en["statusBadge.inProgress"] == "In Progress")
        #expect(en["overview.status.inProgress"] == "In Progress")
        #expect(en["rules.mapLocalDirectory.missing.network"] == "Forward to Network")
    }

    @Test func settingsSearchFindsTheLanguagePicker() throws {
        let keywords = try #require(try english()["settings.page.general.keywords"]).lowercased()
        for word in ["language", "english", "chinese", "restart", "interface"] {
            #expect(keywords.contains(word), Comment(rawValue: word))
        }
    }

    @Test func matchStageSentencesAreOriginalWordingThatNamesTheStage() throws {
        let en = try english()
        #expect(en["rules.builder.matchedAt.request"] == "Matches when the request arrives.")
        #expect(en["rules.builder.matchedAt.response"] == "Matches when the response arrives.")
        #expect(en["rules.builder.matchedAt.either"] == "Matches on the request or the response.")
        let localizer = Localizer(bundle: L10n.bundle, preferredLanguages: ["en"])
        #expect(localizer.format("rules.editor3.groupMatchCount", arguments: [1]) == "1 match in this tab")
        #expect(localizer.format("rules.editor3.groupMatchCount", arguments: [4]) == "4 matches in this tab")
    }
}
