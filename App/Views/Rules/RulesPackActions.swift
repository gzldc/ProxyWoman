import AppCore
import AppKit
import Localization
import RulesEngine
import UniformTypeIdentifiers

/// What the export tells the user once it ended: one summary line, and the rules that could not be exported.
struct RulesExportReport: Identifiable {
    let id = UUID()
    let title: String
    /// The exported-count line, shown above the skipped list.
    var summary: String?
    let lines: [String]
}

/// The file panels and the export run of the rules window's Import / Export entries. The panels are not modal
/// (`begin`), so the app keeps running while one is open; nothing is read or written before a file is chosen.
@MainActor enum RulesPackActions {
    /// The pack the user picked to import, or nil when the panel was cancelled. A `.farx` file can be chosen; the
    /// importer then explains that it is not supported yet.
    static func chooseImportFile() async -> URL? {
        let panel = NSOpenPanel()
        panel.title = L10n.string("rules.import.title")
        panel.allowedContentTypes = [UTType(filenameExtension: "pwrules"), UTType(filenameExtension: "farx")].compactMap { $0 }
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        return await withCheckedContinuation { continuation in
            panel.begin { response in continuation.resume(returning: response == .OK ? panel.url : nil) }
        }
    }

    /// Where to save the pack, or nil when the panel was cancelled.
    static func chooseExportDestination(defaultName: String) async -> URL? {
        let panel = NSSavePanel()
        panel.title = L10n.string("rules.export.panelTitle")
        panel.allowedContentTypes = [UTType(filenameExtension: "pwrules")].compactMap { $0 }
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = defaultName
        return await withCheckedContinuation { continuation in
            panel.begin { response in continuation.resume(returning: response == .OK ? panel.url : nil) }
        }
    }

    /// `ProxyWoman-Rules-yyyyMMdd.pwrules`, the date formatted like the HAR export's.
    static func defaultExportName(now: Date = .now) -> String {
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyyMMdd"
        return "\(AppInfo.name)-Rules-\(stamp.string(from: now)).pwrules"
    }

    /// Exports `ids` (nil: everything) after asking where to save. Nil when the user cancelled the panel.
    static func export(ids: Set<UUID>?, model: RulesEditorModel, client: RulePackClient) async -> RulesExportReport? {
        guard let url = await chooseExportDestination(defaultName: defaultExportName()) else { return nil }
        do {
            let pack = try await model.exportPack(ids: ids, client: client)
            try await client.write(pack.data, url)
            let summary = RulePackPresentation.exported(rules: pack.ruleCount, groups: pack.groupCount)
            let skipped = RulePackPresentation.skippedLines(pack.skipped)
            return RulesExportReport(
                title: pack.skipped.isEmpty ? summary : RulePackPresentation.skippedTitle(count: pack.skipped.count),
                summary: pack.skipped.isEmpty ? nil : summary, lines: skipped)
        } catch let error as RulePackError {
            return RulesExportReport(title: RulePackPresentation.message(error), lines: [])
        } catch {
            return RulesExportReport(title: RulePackPresentation.message(.saveFailed), lines: [])
        }
    }
}
