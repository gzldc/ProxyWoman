import FlowStore
import Foundation

/// Why a magic action string could not be turned into an action.
public enum MagicStringError: Error, Sendable, Equatable {
    case empty
    /// Not one of the keywords, a URL or a predefined response name.
    case unrecognized
    /// A keyword with a missing or unusable argument (`*delay:abc`, `*header:` without a name, a bad URL).
    case invalidArgument
    /// An absolute file path. A rule never holds a user path (it holds a managed copy), so a path cannot be
    /// expanded here: the editor imports the file and writes a Return File action instead (ruling R8F2-T4-2).
    case localFilePath
}

/// The Classic auto-responder action strings (spec section 12.7), turned into the actions this engine
/// already has. A rule stores the text (`ActionKind.magicString`); `RuleSnapshot.evaluationOrder` hands the
/// evaluators the expanded action, so nothing downstream knows about magic strings.
///
/// | string | action |
/// |---|---|
/// | `*drop` | close, graceful |
/// | `*reset` | close, reset |
/// | `*delay:ms` | delay |
/// | `*bpu` | request breakpoint (pause at the head, the default mode) |
/// | `*bpafter` | response breakpoint (same) |
/// | `*redir:URL` | preset 307 with `Location: URL` |
/// | `*header:Name=Value` | set a request header |
/// | `*CORSPreflightAllow` | handwritten 200 with permissive CORS headers (see `corsPreflightResponse`) |
/// | `*ReplyWithTunnel` | return a CONNECT tunnel |
/// | `*exit` | does nothing and ends rule processing |
/// | `http(s)://…` | map remote to that address (its path and query replace the request's) |
/// | `NNN_Name.dat` (a leading `*` is optional) | the predefined response of that name |
///
/// Keywords are matched ignoring case. Anything else is an error.
public enum MagicStringAction {
    /// The `Location` of a predefined redirect (`302_Redirect.dat` and the like); the same default as the
    /// redirect presets of the editor (R8F2-7).
    public static let defaultRedirectLocation = "http://www.example.com/"

    /// The response of `*CORSPreflightAllow`. The origin cannot be echoed (an action's response is fixed text,
    /// it does not see the request), so the answer allows every origin (`*`), every method the web uses, and
    /// any requested header.
    public static let corsPreflightResponse =
        "HTTP/1.1 200 OK\r\nAccess-Control-Allow-Origin: *\r\n"
        + "Access-Control-Allow-Methods: GET, POST, PUT, PATCH, DELETE, HEAD, OPTIONS\r\n"
        + "Access-Control-Allow-Headers: *\r\nAccess-Control-Max-Age: 86400\r\nContent-Length: 0\r\n\r\n"

    /// COMPATIBILITY LITERAL (ruling R8F2-F2-6). This is the file name that Classic auto-responder rule files
    /// (imported rules) use for the 1x1 gif response (the constant below), so imported rules keep resolving. It is a file name
    /// in the imported data, not product text shown to the user; the brand-word scan in
    /// `Rules2R8LocalizationTests.noBrandWordInProductText` allowlists exactly this literal in this file.
    static let classicGifFileName = "200_FiddlerGif"

    /// The predefined response names of the reference auto-responder, without the `.dat`.
    private static let presets: [(name: String, preset: PresetResponse.Preset)] = [
        ("200_SimpleHTML", .emptyHTML200), (classicGifFileName, .gif200), ("200_TransPixel", .transparentPixel200),
        ("204_NoContent", .noContent204), ("302_Redirect", .found302), ("303_RedirectWithGet", .seeOther303),
        ("304_NotModified", .notModified304), ("307_RedirectWithMethod", .temporaryRedirect307),
        ("401_AuthBasic", .unauthorized401), ("401_AuthDigest", .digestAuth401), ("403_AuthDeny", .forbidden403),
        ("404_Plain", .notFound404), ("407_ProxyAuthBasic", .proxyAuthRequired407),
        ("502_Unreachable", .unreachable502),
    ]

    /// The action the string stands for.
    public static func resolve(_ written: String) -> Result<ActionKind, MagicStringError> {
        let text = written.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .failure(.empty) }
        let lowered = text.lowercased()
        switch lowered {
        case "*drop": return .success(.closeConnection(.graceful))
        case "*reset": return .success(.closeConnection(.reset))
        case "*bpu": return .success(.breakpoint(direction: .request, mode: .headers))
        case "*bpafter": return .success(.breakpoint(direction: .response, mode: .headers))
        case "*corspreflightallow": return .success(.returnHandwritten(HandwrittenResponse(text: corsPreflightResponse)))
        case "*replywithtunnel": return .success(.returnConnectTunnel)
        case "*exit": return .success(noOp)
        default: break
        }
        if lowered.hasPrefix("*delay:") {
            guard let milliseconds = ConditionValues.wholeNumber(String(text.dropFirst("*delay:".count))) else {
                return .failure(.invalidArgument)
            }
            return .success(.delay(milliseconds: milliseconds))
        }
        if lowered.hasPrefix("*redir:") {
            let location = String(text.dropFirst("*redir:".count))
            let preset = PresetResponse(preset: .temporaryRedirect307, location: location)
            guard case .success = preset.build() else { return .failure(.invalidArgument) }
            return .success(.returnPreset(preset))
        }
        if lowered.hasPrefix("*header:") {
            let argument = text.dropFirst("*header:".count)
            guard let equals = argument.firstIndex(of: "="), equals != argument.startIndex else {
                return .failure(.invalidArgument)
            }
            let name = String(argument[..<equals])
            let value = String(argument[argument.index(after: equals)...])
            guard HTTPMutationValidator.isValidValue(value), !name.contains(where: { $0 == " " || $0 == ":" }) else {
                return .failure(.invalidArgument)
            }
            return .success(.editHeaders(direction: .request, operations: [.set(name: name, value: value)]))
        }
        if lowered.hasPrefix("http://") || lowered.hasPrefix("https://") {
            return mapRemote(text).map { .mapRemote($0) }
        }
        let bare = lowered.hasPrefix("*") ? String(lowered.dropFirst()) : lowered
        if bare.hasSuffix(".dat"), let match = presets.first(where: { $0.name.lowercased() + ".dat" == bare }) {
            let preset = PresetResponse(
                preset: match.preset, location: PresetResponse(preset: match.preset).requiresLocation ? defaultRedirectLocation : nil)
            return .success(.returnPreset(preset))
        }
        if lowered.hasPrefix("*") { return .failure(.unrecognized) }
        if text.hasPrefix("/") || text.hasPrefix("~") || isDrivePath(text) { return .failure(.localFilePath) }
        return .failure(.unrecognized)
    }

    /// Whether the string is `*exit`: the action does nothing, and the rules below it do not run.
    public static func isExit(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "*exit"
    }

    /// What a rule that only had to stop processing does: a comment edit that changes nothing (it needs no
    /// connection, and works at every judgment point). The evaluators recognise this exact value (a find and
    /// replace of nothing, case-insensitive, which the editor never writes) and neither emit an annotation for it
    /// nor touch the comment: `isInert`.
    static let noOpComment = CommentAction(mode: .findReplace, text: "", replacement: "", caseSensitive: false)
    static let noOp: ActionKind = .comment(noOpComment)

    /// Whether `comment` is the stand-in of `*exit` (or of an unresolvable string): it must leave the flow alone.
    static func isInert(_ comment: CommentAction) -> Bool { comment == noOpComment }

    /// The action the evaluators run for the string: the resolved one, or nothing when it does not resolve
    /// (a hand-edited file; validation refuses such a rule).
    static func effectiveKind(_ text: String) -> ActionKind {
        if case .success(let kind) = resolve(text) { return kind }
        return noOp
    }

    private static func isDrivePath(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        return bytes.count > 2 && bytes[1] == 0x3A && (bytes[2] == 0x5C || bytes[2] == 0x2F)
            && ((0x41...0x5A).contains(bytes[0]) || (0x61...0x7A).contains(bytes[0]))
    }

    private static func mapRemote(_ text: String) -> Result<MapRemoteAction, MagicStringError> {
        guard let components = URLComponents(string: text), let scheme = components.scheme?.lowercased(),
            scheme == "http" || scheme == "https", let written = components.host, !written.isEmpty
        else { return .failure(.invalidArgument) }
        // An IPv6 literal is stored without its brackets.
        let host = written.hasPrefix("[") && written.hasSuffix("]") ? String(written.dropFirst().dropLast()) : written
        let port = components.port ?? (scheme == "https" ? 443 : 80)
        guard (1...65_535).contains(port) else { return .failure(.invalidArgument) }
        var path = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        if let query = components.percentEncodedQuery { path += "?" + query }
        let action = MapRemoteAction(targetScheme: scheme, targetHost: host, targetPort: port, path: .replace(path))
        return .success(action)
    }
}

extension RuleAction {
    /// The action as the evaluators see it: a magic string becomes the action it stands for (`*exit` is final).
    func expandingMagicString() -> RuleAction {
        guard case .magicString(let text) = kind else { return self }
        return RuleAction(MagicStringAction.effectiveKind(text), isFinal: isFinal || MagicStringAction.isExit(text))
    }
}

extension Rule {
    /// The rule with its magic strings expanded; the rule itself when it has none (the common case costs one scan).
    func expandingMagicStrings() -> Rule {
        guard actions.contains(where: { if case .magicString = $0.kind { true } else { false } }) else { return self }
        var expanded = self
        expanded.actions = actions.map { $0.expandingMagicString() }
        return expanded
    }
}
