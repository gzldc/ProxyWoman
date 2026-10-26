import NIOCore
import RulesEngine

/// The transport side of the R4 rule actions that end a request themselves (spec 5.5.8, 6.9).
extension HTTPExchange {
    /// Answers with a rule's handwritten or preset response (D17). It goes through the Return File
    /// pipeline: the response side is claimed (upload, replay copy and any acquisition abandoned, so no
    /// upstream connection is opened), the head is framed for the client (HEAD / 204 / 304 carry no body,
    /// an HTTP/1.0 client gets an HTTP/1.0 head), the unread upload is disposed of, and the response point
    /// runs on it as a local response. It is recorded as a generated response without an asset.
    func startGeneratedResponse(_ response: GeneratedResponse) {
        guard claimLocalResponse() else { return }
        startOwnedLocalResponse(LocalResponseSource(generated: response, hooks: connection.environment.localResponseHooks))
    }

    /// Closes the connection for a rule (D15). Only reached before any response head was written (the request
    /// point decides it). The response side is claimed (upload, replay copy and any acquisition abandoned, so
    /// no upstream connection is opened), the flow fails naming the rule (the completion point still runs
    /// through `FlowRecorder.fail`), and the writer closes without a byte: HTTP/1 with FIN or RST, HTTP/2 only
    /// this stream. The response point never runs (spec 5.5.4-4). The close route itself sends no interim
    /// 100 Continue; only a body peek or a full-body request breakpoint that ran before it may have sent one.
    func closeByRule(_ mode: RulesEngine.CloseMode, ruleName: String) {
        guard claimLocalResponse() else { return }
        cancel(reason: HTTPLocalFailureText.ruleClosed(ruleName: ruleName), closing: mode)
    }
}
