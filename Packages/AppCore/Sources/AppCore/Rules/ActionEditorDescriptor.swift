import Foundation
import Localization
import RulesEngine

/// One entry of a card's "how" dropdown.
public struct ActionModeItem: Equatable, Sendable {
    /// The raw value of the method of the card's type (`HeaderMethod`, `QueryMethod`, `CookieMethod`,
    /// `CommentModeChoice`, `BodyMode` or `URLEditAction.Mode`).
    public var id: String
    public var title: String
    /// Only offered to a saved card that carries it, marked "old style".
    public var isLegacy: Bool
}

/// The find box of an edit: shown for find-and-replace and regular expression.
public enum ActionFindControl: Equatable, Sendable {
    case none
    /// One line; typing offers the values recent traffic had.
    case singleLine(suggestions: Bool)
    /// Several lines (a regular expression or a body).
    case multiLine
}

/// The value box of an edit.
public enum ActionValueControl: Equatable, Sendable {
    case none
    case line(placeholder: String)
    /// The big editor of a body (set value, find and replace) with its language dropdown.
    case bigEditor
    /// A free multi-line box (the magic string).
    case multiLine
}

public struct BodyEditorLanguage: Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String

    /// The ids stored in `BodyRewriteAction.editorLanguage`. `typescript` stands for JavaScript/TypeScript; a
    /// stored `javascript` reads as the same entry.
    public static let ids = ["plaintext", "json", "css", "xml", "html", "typescript"]

    public static func all(localizer: Localizer = L10n.localizer) -> [BodyEditorLanguage] {
        [
            BodyEditorLanguage(id: "plaintext", title: localizer.string("rules.action.language.plaintext")),
            BodyEditorLanguage(id: "json", title: localizer.string("rules.action.language.json")),
            BodyEditorLanguage(id: "css", title: localizer.string("rules.action.language.css")),
            BodyEditorLanguage(id: "xml", title: localizer.string("rules.action.language.xml")),
            BodyEditorLanguage(id: "html", title: localizer.string("rules.action.language.html")),
            BodyEditorLanguage(id: "typescript", title: localizer.string("rules.action.language.typescript")),
        ]
    }

    /// The entry a stored language is shown as (nothing stored: plain text).
    public static func entryID(forStored stored: String?) -> String {
        guard let stored, !stored.isEmpty else { return "plaintext" }
        if stored == "javascript" { return "typescript" }
        return ids.contains(stored) ? stored : "plaintext"
    }
}

/// One entry of the predefined-response dropdown.
public struct PredefinedResponseItem: Equatable, Sendable, Identifiable {
    public var preset: PresetResponse.Preset
    public var title: String
    public var isLegacy: Bool
    public var id: String { preset.rawValue }
}

/// The predefined responses of the reference (14), in its order and grouped by the first character of the name, and
/// the older presets a saved rule can still hold.
public enum PredefinedResponseCatalog {
    public static let presets: [PresetResponse.Preset] = [
        .emptyHTML200, .gif200, .transparentPixel200, .noContent204,
        .found302, .seeOther303, .notModified304, .temporaryRedirect307,
        .unauthorized401, .digestAuth401, .forbidden403, .notFound404, .proxyAuthRequired407,
        .unreachable502,
    ]

    public static func isLegacy(_ preset: PresetResponse.Preset) -> Bool { !presets.contains(preset) }

    /// The location a redirect starts with (R8F2-7).
    public static let defaultLocation = MagicStringAction.defaultRedirectLocation

    /// The dropdown's groups: the list grouped by the first character of the title, and `current` last as an
    /// old-style entry when it is not one of the 14.
    public static func groups(including current: PresetResponse.Preset? = nil, localizer: Localizer = L10n.localizer)
        -> [[PredefinedResponseItem]]
    {
        var groups: [[PredefinedResponseItem]] = []
        var lastCharacter: Character?
        for preset in presets {
            let title = localizer.string(preset.titleKey)
            let item = PredefinedResponseItem(preset: preset, title: title, isLegacy: false)
            if title.first == lastCharacter, !groups.isEmpty {
                groups[groups.count - 1].append(item)
            } else {
                groups.append([item])
                lastCharacter = title.first
            }
        }
        if let current, isLegacy(current) {
            let title = localizer.format("rules.editor3.legacyOption", arguments: [localizer.string(current.titleKey)])
            groups.append([PredefinedResponseItem(preset: current, title: title, isLegacy: true)])
        }
        return groups
    }
}

/// The key box of header, cookie and query cards.
public enum ActionKeyControl: Equatable, Sendable {
    case none
    /// A text box with the names recent traffic had; empty means every key (`placeholder` says so).
    case autocomplete(placeholder: String)
}

/// Everything the editor of one action card draws, decided by the type and the card's current method (spec 12.7).
/// Pure values; every word is localized here.
public struct ActionEditorDescriptor: Equatable, Sendable {
    public var type: ActionType
    public var keyControl: ActionKeyControl
    /// The key's "Aa": header, cookie and query cards (their names can be compared with or without case).
    public var showsKeyCase: Bool
    /// What the key's "Aa" shows now: on when names must match in exact case. A card opened from a saved rule shows the
    /// original behaviour (header names ignore case, query and cookie names do not) until the switch is flipped.
    public var keyCaseOn: Bool
    /// The method dropdown; empty for a type without one.
    public var modes: [ActionModeItem]
    public var selectedMode: String?
    public var find: ActionFindControl
    /// The value's "Aa": with the find box.
    public var showsValueCase: Bool
    public var value: ActionValueControl
    /// The languages of the big editor's dropdown (body cards with the big editor); the selected one.
    public var languages: [BodyEditorLanguage]
    public var selectedLanguage: String?
    /// The status box's longest text.
    public var maxValueCharacters: Int?
    /// The predefined-response dropdown; empty for other types.
    public var presetGroups: [[PredefinedResponseItem]]
    /// A "Location" input under the dropdown (the redirects).
    public var showsPresetLocation: Bool
    /// Challenge and body inputs of an old preset that carries them.
    public var showsPresetChallenge: Bool
    public var showsPresetBody: Bool
    /// The mark's two colour dropdowns: choices, in order, with a custom colour of an old rule added last.
    public var backgroundChoices: [MarkColorChoice]
    public var foregroundChoices: [MarkColorChoice]
    /// An old rule's label.
    public var showsMarkText: Bool
    /// The sentence that tells an old breakpoint with a non-default pause mode what it still does.
    public var legacyNoteKey: String?
    /// Old-style inputs a saved card still carries.
    public var showsBodyScope: Bool
    public var showsIncludeLocalResponses: Bool
    public var showsURLPreserveCredentials: Bool
    /// The path a magic string names when its text is a local file path (nothing is looked up to know that).
    private let magicStringPath: String?
    /// The magic string is a local file path of a file that exists: offer Return File. Read on demand, so building the
    /// descriptor never touches the file system.
    public var offersReturnFile: Bool { magicStringPath.map { ActionDraft.isExistingRegularFile(atPath: $0) } ?? false }
    public var hint: String

    public var showsKey: Bool { keyControl != .none }
    public var showsFind: Bool { find != .none }
    public var showsValue: Bool { value != .none }

    public init(draft: ActionDraft, localizer: Localizer = L10n.localizer) {
        let type = draft.type
        self.type = type
        hint = localizer.string(type.hintKey)
        showsKeyCase = Self.hasKey(type)
        keyCaseOn = draft.keyCaseOn ?? false
        let mode = Self.currentMode(of: draft)
        selectedMode = mode?.id
        modes = Self.modes(type: type, current: mode, localizer: localizer)
        keyControl = Self.hasKey(type) ? .autocomplete(placeholder: localizer.string("rules.action.key.all")) : .none

        let kind = mode?.kind
        find = Self.find(type: type, kind: kind)
        showsValueCase = find != .none
        value = Self.value(type: type, kind: kind, localizer: localizer)
        let bigEditor = value == .bigEditor
        languages = bigEditor ? BodyEditorLanguage.all(localizer: localizer) : []
        selectedLanguage = bigEditor ? BodyEditorLanguage.entryID(forStored: draft.body.editorLanguage) : nil
        maxValueCharacters = type == .rewriteStatus ? RewriteStatusAction.maxTextCharacters : nil

        presetGroups = type == .returnPreset ? PredefinedResponseCatalog.groups(including: draft.preset, localizer: localizer) : []
        let shape = PresetResponse(preset: draft.preset)
        showsPresetLocation = type == .returnPreset && shape.requiresLocation
        showsPresetChallenge = type == .returnPreset && !draft.presetChallenge.isEmpty
        showsPresetBody = type == .returnPreset && !draft.presetBody.isEmpty

        let isMark = type == .mark
        backgroundChoices = isMark ? MarkColorCatalog.choices(including: draft.mark.backgroundChoice) : []
        foregroundChoices = isMark ? MarkColorCatalog.choices(including: draft.mark.foregroundChoice) : []
        showsMarkText = isMark && !draft.mark.text.isEmpty

        let pausedFully = draft.breakpointMode != .headers
        legacyNoteKey = (type == .requestBreakpoint || type == .responseBreakpoint) && pausedFully ? "rules.action.legacy.fullBody" : nil
        showsBodyScope = value != .none && (type == .rewriteRequestBody || type == .rewriteResponseBody) && draft.body.scope != .all
        showsIncludeLocalResponses = type == .rewriteStatus && draft.status.includeLocalResponses
        showsURLPreserveCredentials = type == .modifyURL && draft.url.preserveCredentials
        magicStringPath = draft.isLocalFilePathText ? draft.magicStringExpandedPath : nil
    }

    // MARK: pieces

    private enum ModeKind { case set, findReplace, regex, addIfMissing, appendToValue, remove, legacy }

    private struct CurrentMode {
        var id: String
        var kind: ModeKind
    }

    /// Whether the type has a key box (header, cookie and query cards); cheap, so a view can ask without a descriptor.
    public static func hasKey(_ type: ActionType) -> Bool {
        switch type {
        case .editRequestHeaders, .editResponseHeaders, .editRequestCookies, .editResponseCookies, .modifyQuery: true
        default: false
        }
    }

    private static func currentMode(of draft: ActionDraft) -> CurrentMode? {
        switch draft.type {
        case .modifyURL:
            let mode = draft.url.mode
            let kind: ModeKind =
                switch mode {
                case .set: .set
                case .findReplace: .findReplace
                case .regex: .regex
                case .append: .appendToValue
                }
            return CurrentMode(id: mode.rawValue, kind: kind)
        case .modifyQuery:
            let method = (draft.queryRows.first ?? QueryEditRow()).method
            return CurrentMode(id: method.rawValue, kind: kind(of: method))
        case .editRequestHeaders, .editResponseHeaders:
            let method = (draft.headerRows.first ?? HeaderEditRow()).method
            return CurrentMode(id: method.rawValue, kind: kind(of: method))
        case .editRequestCookies, .editResponseCookies:
            let method = (draft.cookieRows.first ?? CookieEditRow()).method
            return CurrentMode(id: method.rawValue, kind: kind(of: method))
        case .rewriteRequestBody, .rewriteResponseBody:
            let mode = draft.body.mode
            let kind: ModeKind =
                switch mode {
                case .setValue: .set
                case .findReplace: .findReplace
                case .regex: .regex
                case .remove: .remove
                }
            return CurrentMode(id: mode.rawValue, kind: kind)
        case .comment:
            let mode = draft.comment.mode
            let kind: ModeKind =
                switch mode {
                case .set: .set
                case .findReplace: .findReplace
                case .regex: .regex
                case .addIfMissing: .addIfMissing
                case .append: .appendToValue
                case .clear: .remove
                }
            return CurrentMode(id: mode.rawValue, kind: kind)
        default:
            return nil
        }
    }

    private static func kind(of method: HeaderMethod) -> ModeKind {
        switch method {
        case .set: .set
        case .findReplace: .findReplace
        case .regex: .regex
        case .addIfMissing: .addIfMissing
        case .appendToValue: .appendToValue
        case .remove: .remove
        case .append: .legacy
        }
    }

    private static func kind(of method: QueryMethod) -> ModeKind {
        switch method {
        case .set: .set
        case .findReplace: .findReplace
        case .regex: .regex
        case .addIfMissing: .addIfMissing
        case .appendToValue: .appendToValue
        case .remove: .remove
        case .add: .legacy
        }
    }

    private static func kind(of method: CookieMethod) -> ModeKind {
        switch method {
        case .set: .set
        case .findReplace: .findReplace
        case .regex: .regex
        case .addIfMissing: .addIfMissing
        case .appendToValue: .appendToValue
        case .remove: .remove
        }
    }

    // MARK: modes

    private static func modes(type: ActionType, current: CurrentMode?, localizer: Localizer) -> [ActionModeItem] {
        func item(_ id: String, _ key: String, legacy: Bool = false) -> ActionModeItem {
            let title = localizer.string(key)
            return ActionModeItem(id: id, title: legacy ? localizer.format("rules.editor3.legacyOption", arguments: [title]) : title, isLegacy: legacy)
        }
        var items: [ActionModeItem]
        switch type {
        case .modifyQuery:
            items = [
                item("set", QueryMethod.set.titleKey), item("findReplace", QueryMethod.findReplace.titleKey),
                item("regex", QueryMethod.regex.titleKey), item("addIfMissing", QueryMethod.addIfMissing.titleKey),
                item("appendToValue", QueryMethod.appendToValue.titleKey), item("remove", QueryMethod.remove.titleKey),
            ]
            if current?.id == QueryMethod.add.rawValue { items.append(item("add", QueryMethod.add.titleKey, legacy: true)) }
        case .editRequestHeaders, .editResponseHeaders:
            items = [
                item("set", HeaderMethod.set.titleKey), item("findReplace", HeaderMethod.findReplace.titleKey),
                item("regex", HeaderMethod.regex.titleKey), item("addIfMissing", HeaderMethod.addIfMissing.titleKey),
                item("appendToValue", HeaderMethod.appendToValue.titleKey), item("remove", HeaderMethod.remove.titleKey),
            ]
            if current?.id == HeaderMethod.append.rawValue { items.append(item("append", HeaderMethod.append.titleKey, legacy: true)) }
        case .editRequestCookies, .editResponseCookies:
            items = [
                item("set", CookieMethod.set.titleKey), item("findReplace", CookieMethod.findReplace.titleKey),
                item("regex", CookieMethod.regex.titleKey), item("addIfMissing", CookieMethod.addIfMissing.titleKey),
                item("appendToValue", CookieMethod.appendToValue.titleKey), item("remove", CookieMethod.remove.titleKey),
            ]
        case .comment:
            items = [
                item("set", CommentModeChoice.set.localizationKey), item("findReplace", CommentModeChoice.findReplace.localizationKey),
                item("regex", CommentModeChoice.regex.localizationKey),
                item("addIfMissing", CommentModeChoice.addIfMissing.localizationKey),
                item("append", CommentModeChoice.append.localizationKey), item("clear", CommentModeChoice.clear.localizationKey),
            ]
        case .rewriteRequestBody, .rewriteResponseBody:
            items = [
                item("setValue", BodyMode.setValue.titleKey), item("findReplace", BodyMode.findReplace.titleKey),
                item("regex", BodyMode.regex.titleKey), item("remove", BodyMode.remove.titleKey),
            ]
        case .modifyURL:
            items = [
                item("set", URLEditAction.Mode.set.titleKey), item("findReplace", URLEditAction.Mode.findReplace.titleKey),
                item("regex", URLEditAction.Mode.regex.titleKey), item("append", URLEditAction.Mode.append.titleKey),
            ]
        default:
            items = []
        }
        return items
    }

    // MARK: find and value

    private static func find(type: ActionType, kind: ModeKind?) -> ActionFindControl {
        guard kind == .findReplace || kind == .regex else { return .none }
        let isBody = type == .rewriteRequestBody || type == .rewriteResponseBody
        if kind == .regex || isBody { return .multiLine }
        return .singleLine(suggestions: true)
    }

    private static func value(type: ActionType, kind: ModeKind?, localizer: Localizer) -> ActionValueControl {
        switch type {
        case .rewriteStatus: return .line(placeholder: localizer.string("rules.action.placeholder.status"))
        case .delay: return .line(placeholder: localizer.string("rules.action.placeholder.milliseconds"))
        case .magicString: return .multiLine
        case .modifyURL, .modifyQuery, .editRequestHeaders, .editResponseHeaders, .editRequestCookies, .editResponseCookies,
            .comment, .rewriteRequestBody, .rewriteResponseBody:
            break
        default: return .none
        }
        guard let kind, kind != .remove else { return .none }
        let isBody = type == .rewriteRequestBody || type == .rewriteResponseBody
        if isBody, kind == .set || kind == .findReplace { return .bigEditor }
        switch kind {
        case .findReplace, .regex: return .line(placeholder: localizer.string("rules.action.placeholder.replaceWith"))
        case .appendToValue: return .line(placeholder: localizer.string("rules.action.placeholder.append"))
        default: return .line(placeholder: localizer.string("rules.action.placeholder.set"))
        }
    }
}

extension ActionDraft {
    /// The card's method as the dropdown's id (nil for a type without a method dropdown).
    public var modeID: String? {
        switch type {
        case .modifyURL: url.mode.rawValue
        case .modifyQuery: (queryRows.first ?? QueryEditRow()).method.rawValue
        case .editRequestHeaders, .editResponseHeaders: (headerRows.first ?? HeaderEditRow()).method.rawValue
        case .editRequestCookies, .editResponseCookies: (cookieRows.first ?? CookieEditRow()).method.rawValue
        case .rewriteRequestBody, .rewriteResponseBody: body.mode.rawValue
        case .comment: comment.mode.rawValue
        default: nil
        }
    }

    /// Picks the method with the dropdown's id; an id of another type is ignored.
    public mutating func setMode(_ id: String) {
        switch type {
        case .modifyURL:
            if let mode = URLEditAction.Mode(rawValue: id) { url.mode = mode }
        case .modifyQuery:
            if let method = QueryMethod(rawValue: id) { mutateFirst(&queryRows, QueryEditRow()) { $0.method = method } }
        case .editRequestHeaders, .editResponseHeaders:
            if let method = HeaderMethod(rawValue: id) { mutateFirst(&headerRows, HeaderEditRow()) { $0.method = method } }
        case .editRequestCookies, .editResponseCookies:
            if let method = CookieMethod(rawValue: id) { mutateFirst(&cookieRows, CookieEditRow()) { $0.method = method } }
        case .rewriteRequestBody, .rewriteResponseBody:
            if let mode = BodyMode(rawValue: id) { body.mode = mode }
        case .comment:
            if let mode = CommentModeChoice(rawValue: id) { comment.mode = mode }
        default:
            break
        }
    }

    private func mutateFirst<Row>(_ rows: inout [Row], _ empty: Row, _ change: (inout Row) -> Void) {
        if rows.isEmpty { rows = [empty] }
        change(&rows[0])
    }

    /// The action ends the rules after it by nature; a magic string by what it stands for (`*drop`, `*exit`, ...).
    public var isIntrinsicallyFinal: Bool {
        guard type == .magicString else { return type.isIntrinsicallyFinal }
        if MagicStringAction.isExit(magicText) { return true }
        if case .success(let kind) = MagicStringAction.resolve(magicText) { return kind.isIntrinsicallyFinal }
        return false
    }

    /// The editor language of a body card as the dropdown's id.
    public mutating func setEditorLanguage(_ id: String) {
        body.editorLanguage = id == "plaintext" ? nil : id
    }

    /// The magic string is the text of a local path (what the build refuses with the "local file" issue); no file is looked up.
    var isLocalFilePathText: Bool {
        guard type == .magicString else { return false }
        if case .failure(.localFilePath) = MagicStringAction.resolve(magicText.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return true
        }
        return false
    }

    /// The local file a magic string names: a path to an existing regular file (a leading `~` is the home folder).
    public func magicStringFileURL(fileManager: FileManager = .default) -> URL? {
        guard isLocalFilePathText, let path = magicStringExpandedPath,
            Self.isExistingRegularFile(atPath: path, fileManager: fileManager)
        else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// The text of a magic string with a leading `~` expanded.
    var magicStringExpandedPath: String? {
        type == .magicString ? (magicText.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath : nil
    }

    static func isExistingRegularFile(atPath path: String, fileManager: FileManager = .default) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }
}
