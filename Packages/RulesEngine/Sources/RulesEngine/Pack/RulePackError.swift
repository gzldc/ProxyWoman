import Foundation

/// Why a rule pack could not be exported or imported. Cases carry data only; the sentence shown to the user
/// is built where it is displayed.
public enum RulePackError: Error, Equatable, Sendable {
    /// The selected rules and their files together exceed what one pack may hold when expanded.
    case exportTooLarge
    /// Nothing is left to put in the pack (empty selection, or every selected rule was skipped).
    case nothingToExport

    // Importing: what the file is.
    /// Not a zip archive at all.
    case notAPack
    /// A zip, but not one this app exported (wrong format string, missing or malformed manifest, missing parts).
    case notThisFormat
    /// Exported by a newer version; the number is the newer schema found.
    case newerVersion(Int)
    /// The manifest is ours but the rules inside cannot be read: most likely a newer version added something.
    case undecodableContent

    // Importing: limits.
    case tooLarge(limit: Int)
    case tooManyEntries
    case expandedTooLarge
    case assetTooLarge(limit: Int)

    // Importing: archive structure.
    case unsafeEntry, unexpectedEntry, duplicateEntry, encrypted, unsupportedCompression, symlink, corrupt

    // Importing: content.
    /// The rule at `index` failed the same checks a saved rule must pass.
    case invalidRule(index: Int)
    /// Duplicate ids, unknown group, cycle, or too many groups.
    case invalidStructure
    /// A Return Directory rule: its bookmark means nothing on another machine.
    case directoryMapping
    /// A returned file has no usable entry in the pack.
    case missingAsset
    /// A returned file's size differs from what the pack declares.
    case assetMismatch
    case tooManyRules(have: Int, limit: Int)

    // Importing: the environment.
    case saveFailed, readFailed, cancelled
    /// `.farx` files from other tools are recognized but not imported.
    case farxUnsupported

    /// Total mapping from the zip layer, one case per `ZipError` family. `limits` supplies the numbers the
    /// messages quote.
    public init(_ zip: ZipError, limits: RulesLimits = RulesLimits()) {
        switch zip {
        case .entryTooLarge: self = .exportTooLarge
        case .invalidName, .unsafeName: self = .unsafeEntry
        case .notAnArchive: self = .notAPack
        case .tooLarge, .zip64: self = .tooLarge(limit: limits.packFileBytes)
        case .tooManyEntries: self = .tooManyEntries
        case .expandedTooLarge: self = .expandedTooLarge
        case .entryTooBig(let name):
            if name == "manifest.json" {
                self = .tooLarge(limit: limits.packManifestBytes)
            } else if name == "rules.json" {
                self = .tooLarge(limit: limits.configBytes)
            } else if RulePackReader.assetEntryID(name) != nil {
                self = .assetTooLarge(limit: limits.packAssetBytes)
            } else {
                self = .unexpectedEntry
            }
        case .duplicateName: self = .duplicateEntry
        case .encrypted: self = .encrypted
        case .unsupportedMethod: self = .unsupportedCompression
        case .symlinkOrSpecial: self = .symlink
        case .corrupt, .crcMismatch, .sizeMismatch, .overlap: self = .corrupt
        }
    }
}
