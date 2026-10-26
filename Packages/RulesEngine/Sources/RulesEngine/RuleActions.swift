import FlowStore
import Foundation

/// What a rule does, with its parameters. The case names are stored in `rules.json`.
public enum ActionKind: Codable, Sendable, Equatable, Hashable {
    case returnFile(MapLocalAction)
    /// `pathPrefix` is the part of the request path the directory is served under (`/…/`).
    case returnDirectory(MapLocalDirectoryAction, pathPrefix: String)
    case mapRemote(MapRemoteAction)
    case editHeaders(direction: HTTPMessageDirection, operations: [HeaderEdit])
    case breakpoint(direction: HTTPMessageDirection, mode: BreakpointPauseMode)
    case rewriteBody(direction: HTTPMessageDirection, BodyRewriteAction)
    case rewriteStatus(RewriteStatusAction)
    case mark(MarkAction)
    case comment(CommentAction)
    case hide
    // Rules 2.0 phase R4; appended so the stored shape of every earlier case stays as it was.
    case modifyURL(URLEditAction)
    case modifyQuery(QueryEditAction)
    case editCookies(direction: HTTPMessageDirection, operations: [CookieEdit])
    case delay(milliseconds: Int)
    case returnHandwritten(HandwrittenResponse)
    case returnPreset(PresetResponse)
    case closeConnection(CloseMode)
    case returnConnectTunnel
    case noDecrypt
    // Rules 2.0 R8F2; appended so the stored shape of every earlier case stays as it was. A Classic
    // auto-responder action string (`*drop`, `*delay:100`, `http://…`, ...); `MagicStringAction` expands it.
    case magicString(String)

    /// Which message the action runs on. Mapping actions choose the route, so they run on requests; a
    /// status rewrite only exists on responses. Nil for the annotation actions and for the ones that
    /// work at either point (Return File, manual and predefined responses, closing the connection,
    /// delay): they run wherever the rule is judged, so a rule judged at the response answers, closes
    /// or delays there (spec 12.7, R8F2 final review).
    public var direction: HTTPMessageDirection? {
        switch self {
        case .magicString(let text): MagicStringAction.effectiveKind(text).direction
        case .returnDirectory, .mapRemote: .request
        case .modifyURL, .modifyQuery, .returnConnectTunnel, .noDecrypt: .request
        case .rewriteStatus: .response
        case .mark, .comment, .hide, .returnFile, .delay, .returnHandwritten, .returnPreset, .closeConnection: nil
        case .editHeaders(let direction, _), .breakpoint(let direction, _), .rewriteBody(let direction, _),
            .editCookies(let direction, _): direction
        }
    }

    /// Whether the action ends rule evaluation for the exchange whatever the user ticked.
    public var isIntrinsicallyFinal: Bool {
        switch self {
        case .magicString(let text): MagicStringAction.isExit(text) || MagicStringAction.effectiveKind(text).isIntrinsicallyFinal
        case .returnFile, .returnDirectory, .hide, .returnHandwritten, .returnPreset, .closeConnection,
            .returnConnectTunnel, .noDecrypt: true
        case .mapRemote, .editHeaders, .breakpoint, .rewriteBody, .rewriteStatus, .mark, .comment, .modifyURL,
            .modifyQuery, .editCookies, .delay: false
        }
    }

    /// Marks, comments and hiding change the flow's record, not the traffic.
    public var isAnnotation: Bool {
        switch self {
        case .magicString(let text): MagicStringAction.effectiveKind(text).isAnnotation
        case .mark, .comment, .hide: true
        case .returnFile, .returnDirectory, .mapRemote, .editHeaders, .breakpoint, .rewriteBody, .rewriteStatus,
            .modifyURL, .modifyQuery, .editCookies, .delay, .returnHandwritten, .returnPreset, .closeConnection,
            .returnConnectTunnel, .noDecrypt: false
        }
    }

    /// Whether a rule judged at the response runs the action there in place of the request (it answers
    /// instead of the origin, closes the client connection, or holds the response head).
    public var runsAtResponsePoint: Bool {
        switch self {
        case .magicString(let text): MagicStringAction.effectiveKind(text).runsAtResponsePoint
        case .returnFile, .returnHandwritten, .returnPreset, .closeConnection, .delay: true
        case .returnDirectory, .mapRemote, .editHeaders, .breakpoint, .rewriteBody, .rewriteStatus, .mark, .comment,
            .hide, .modifyURL, .modifyQuery, .editCookies, .returnConnectTunnel, .noDecrypt: false
        }
    }

    /// Only the CONNECT point (P0) runs these; once the tunnel is open they have nothing to act on.
    public var isConnectOnly: Bool {
        switch self {
        case .magicString(let text): MagicStringAction.effectiveKind(text).isConnectOnly
        case .noDecrypt, .returnConnectTunnel: true
        case .returnFile, .returnDirectory, .mapRemote, .editHeaders, .breakpoint, .rewriteBody, .rewriteStatus, .mark,
            .comment, .hide, .modifyURL, .modifyQuery, .editCookies, .delay, .returnHandwritten, .returnPreset,
            .closeConnection: false
        }
    }

    /// Whether the action can run on a CONNECT line.
    public var canRunAtConnect: Bool {
        switch self {
        case .magicString(let text): MagicStringAction.effectiveKind(text).canRunAtConnect
        case .closeConnection, .mark, .comment, .hide, .noDecrypt, .returnConnectTunnel: true
        case .returnFile, .returnDirectory, .mapRemote, .editHeaders, .breakpoint, .rewriteBody, .rewriteStatus,
            .modifyURL, .modifyQuery, .editCookies, .delay, .returnHandwritten, .returnPreset: false
        }
    }
}

/// An action as a rule holds it: what it does, and whether the user made it final.
public struct RuleAction: Codable, Sendable, Equatable, Hashable {
    public var kind: ActionKind
    /// The user ticked "make this the final action".
    public var isFinal: Bool

    public init(_ kind: ActionKind, isFinal: Bool = false) {
        self.kind = kind
        self.isFinal = isFinal
    }

    /// Whether the action stops lower-priority rules: ticked, or final by nature.
    public var isFinalEffective: Bool { isFinal || kind.isIntrinsicallyFinal }
}
