import Foundation
import RulesEngine

extension ActionDraft {
    /// The action this card stands for while its form cannot be built yet (the warnings of the other cards must still
    /// show): the simplest valid action of its type, final the way the card is. Never saved.
    func standInAction() -> RuleAction {
        if let opaque { return opaque }
        let kind: ActionKind
        switch type {
        case .modifyURL: kind = .modifyURL(URLEditAction(mode: .set, replacement: "https://a.invalid/"))
        case .modifyQuery: kind = .modifyQuery(QueryEditAction(operations: [.remove(name: "a")]))
        case .editRequestHeaders: kind = .editHeaders(direction: .request, operations: [.remove(name: "X-A")])
        case .editResponseHeaders: kind = .editHeaders(direction: .response, operations: [.remove(name: "X-A")])
        case .editRequestCookies: kind = .editCookies(direction: .request, operations: [.remove(name: "a")])
        case .editResponseCookies: kind = .editCookies(direction: .response, operations: [.remove(name: "a")])
        case .rewriteRequestBody:
            kind = .rewriteBody(direction: .request, BodyRewriteAction(find: "", replacement: "", operation: .clear))
        case .rewriteResponseBody:
            kind = .rewriteBody(direction: .response, BodyRewriteAction(find: "", replacement: "", operation: .clear))
        case .mapRemote:
            kind = .mapRemote(MapRemoteAction(targetScheme: "https", targetHost: "a.invalid", targetPort: 443, path: .preserve))
        case .requestBreakpoint: kind = .breakpoint(direction: .request, mode: breakpointMode)
        case .responseBreakpoint: kind = .breakpoint(direction: .response, mode: breakpointMode)
        case .delay: kind = .delay(milliseconds: 0)
        case .rewriteStatus: kind = .rewriteStatus(RewriteStatusAction(status: 200))
        case .returnFile: kind = .returnFile(MapLocalAction(assetID: UUID(), headers: []))
        case .returnDirectory:
            kind = .returnDirectory(MapLocalDirectoryAction(bookmark: Data([0]), displayName: ""), pathPrefix: "/")
        case .returnHandwritten: kind = .returnHandwritten(HandwrittenResponse(text: "HTTP/1.1 200 OK\r\n\r\n"))
        case .returnPreset: kind = .returnPreset(PresetResponse(preset: .notFound404))
        case .closeConnectionGraceful: kind = .closeConnection(.graceful)
        case .closeConnectionReset: kind = .closeConnection(.reset)
        case .returnConnectTunnel: kind = .returnConnectTunnel
        case .noDecrypt: kind = .noDecrypt
        case .hide: kind = .hide
        case .mark: kind = .mark(MarkAction(background: MarkAction.unchangedColor))
        case .comment: kind = .comment(CommentAction(mode: .clear))
        case .magicString: kind = .magicString(magicText)
        }
        return RuleAction(kind, isFinal: isFinal)
    }
}
