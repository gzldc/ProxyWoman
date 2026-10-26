import Foundation
import Localization
import RulesEngine

/// The text of the import preview. Counts come from the import plan (what will actually be added), never from
/// the manifest, which the file's author wrote. Every sentence is one localization key with positional
/// arguments; nothing is concatenated.
public enum RulePackPresentation {
    public struct Preview: Equatable, Sendable {
        public var fileName: String
        public var groupName: String
        public var lines: [String]
        public var warnings: [String]
        public var note: String
    }

    public static func preview(plan: RulePackImportPlan, fileName: String, localizer: Localizer = L10n.localizer) -> Preview {
        build(
            wrapperName: plan.wrapper.name, rules: plan.importedRuleCount, groups: plan.importedGroupCount,
            fileBytes: plan.assets.map(\.size), lifted: plan.liftedGroupCount, breakpoints: plan.breakpointRuleCount,
            ignored: plan.ignoredAssetCount, fileName: fileName, localizer: localizer)
    }

    static func build(
        wrapperName: String, rules: Int, groups: Int, fileBytes: [Int64], lifted: Int, breakpoints: Int, ignored: Int,
        fileName: String, localizer: Localizer
    ) -> Preview {
        var lines = [
            localizer.format("rules.import.summary.rules", arguments: [rules]),
            localizer.format("rules.import.summary.groups", arguments: [groups]),
        ]
        if !fileBytes.isEmpty {
            lines.append(localizer.format("rules.import.summary.files", arguments: [fileBytes.count, byteCount(fileBytes.reduce(0, +))]))
        }
        var warnings: [String] = []
        if lifted > 0 { warnings.append(localizer.format("rules.import.warning.lifted", arguments: [lifted])) }
        if breakpoints > 0 {
            warnings.append(localizer.format("rules.import.warning.breakpointsDisabled", arguments: [breakpoints]))
        }
        if ignored > 0 { warnings.append(localizer.format("rules.import.warning.ignoredFiles", arguments: [ignored])) }
        return Preview(
            fileName: fileName, groupName: wrapperName, lines: lines, warnings: warnings,
            note: localizer.format("rules.import.note.newGroup", arguments: [wrapperName]))
    }

    /// One sentence per case, each a whole localization key. Numbers are limits and indexes the app computed;
    /// nothing from the file is quoted.
    public static func message(_ error: RulePackError, localizer: Localizer = L10n.localizer) -> String {
        switch error {
        case .exportTooLarge: localizer.string("rules.pack.error.exportTooLarge")
        case .nothingToExport: localizer.string("rules.pack.error.nothingToExport")
        case .notAPack: localizer.string("rules.pack.error.notAPack")
        case .notThisFormat: localizer.string("rules.pack.error.notThisFormat")
        case .newerVersion(let schema): localizer.format("rules.pack.error.newerVersion", arguments: [schema])
        case .undecodableContent: localizer.string("rules.pack.error.undecodableContent")
        case .tooLarge(let limit): localizer.format("rules.pack.error.tooLarge", arguments: [byteCount(Int64(limit))])
        case .tooManyEntries: localizer.string("rules.pack.error.tooManyEntries")
        case .expandedTooLarge: localizer.string("rules.pack.error.expandedTooLarge")
        case .assetTooLarge(let limit): localizer.format("rules.pack.error.assetTooLarge", arguments: [byteCount(Int64(limit))])
        case .unsafeEntry: localizer.string("rules.pack.error.unsafeEntry")
        case .unexpectedEntry: localizer.string("rules.pack.error.unexpectedEntry")
        case .duplicateEntry: localizer.string("rules.pack.error.duplicateEntry")
        case .encrypted: localizer.string("rules.pack.error.encrypted")
        case .unsupportedCompression: localizer.string("rules.pack.error.unsupportedCompression")
        case .symlink: localizer.string("rules.pack.error.symlink")
        case .corrupt: localizer.string("rules.pack.error.corrupt")
        case .invalidRule(let index): localizer.format("rules.pack.error.invalidRule", arguments: [index + 1])
        case .invalidStructure: localizer.string("rules.pack.error.invalidStructure")
        case .directoryMapping: localizer.string("rules.pack.error.directoryMapping")
        case .missingAsset: localizer.string("rules.pack.error.missingAsset")
        case .assetMismatch: localizer.string("rules.pack.error.assetMismatch")
        case .tooManyRules(let have, let limit): localizer.format("rules.pack.error.tooManyRules", arguments: [have, limit])
        case .saveFailed: localizer.string("rules.pack.error.saveFailed")
        case .readFailed: localizer.string("rules.pack.error.readFailed")
        case .cancelled: localizer.string("rules.pack.error.cancelled")
        case .farxUnsupported: localizer.string("rules.import.error.farxUnsupported")
        }
    }

    public static func finished(rules: Int, groups: Int, localizer: Localizer = L10n.localizer) -> String {
        localizer.format("rules.import.done", arguments: [rules, groups])
    }

    /// The export summary line.
    public static func exported(rules: Int, groups: Int, localizer: Localizer = L10n.localizer) -> String {
        localizer.format("rules.export.done", arguments: [rules, groups])
    }

    public static func skippedTitle(count: Int, localizer: Localizer = L10n.localizer) -> String {
        localizer.format("rules.export.skipped.title", arguments: [count])
    }

    /// One line per skipped rule, the reason chosen by key. The name is capped and only ever a `%@` argument.
    public static func skippedLines(_ skipped: [SkippedRule], localizer: Localizer = L10n.localizer) -> [String] {
        skipped.map { rule in
            let name = truncated(rule.name, bytes: 80)
            switch rule.reason {
            case .directoryMapping: return localizer.format("rules.export.skipped.directory", arguments: [name])
            case .assetUnavailable: return localizer.format("rules.export.skipped.assetUnavailable", arguments: [name])
            case .assetTooLarge: return localizer.format("rules.export.skipped.assetTooLarge", arguments: [name])
            case .noteTooLong: return localizer.format("rules.export.skipped.noteTooLong", arguments: [name])
            }
        }
    }

    private static func truncated(_ text: String, bytes limit: Int) -> String {
        var kept = ""
        var bytes = 0
        for character in text {
            let size = String(character).utf8.count
            if bytes + size > limit { break }
            kept.append(character)
            bytes += size
        }
        return kept
    }

    /// "Import · name": the file name without its extension, cut to 80 bytes on a character boundary.
    public static func groupName(forFile fileName: String, localizer: Localizer = L10n.localizer) -> String {
        var base = (fileName as NSString).deletingPathExtension
        if base.isEmpty { base = fileName }
        let kept = truncated(base, bytes: 80)
        return localizer.format("rules.import.groupName", arguments: [kept])
    }

    public static func byteCount(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
