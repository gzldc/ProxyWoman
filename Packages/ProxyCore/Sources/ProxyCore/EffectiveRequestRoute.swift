import FlowStore
import RulesEngine

/// Where a rule-decided request actually goes. The resulting target is the only input of the
/// upstream route, so the destination, upstream-proxy bypass and CONNECT target, TLS server name
/// and verification, ALPN and pool key all follow it together; Host/:authority is generated from it.
enum EffectiveRequestRoute {
    /// The original target, or the (composed) Map Remote target: lowercase scheme and host (no IPv6
    /// brackets), the target port, and the original or replaced origin-form path and query.
    static func target(original: HTTPMessageTarget, decision: RequestRuleDecision) throws -> HTTPMessageTarget {
        let remote: MapRemoteAction
        switch decision.route {
        case .remote(let action): remote = action
        // Local and generated routes never reach the network; a close route ends the exchange (D8).
        case .original, .local, .localDirectory, .generated, .close: return original
        }
        let target = remote.target(applyingTo: original)
        // A rule file is validated on save, and again here at execution.
        try HTTPMutationValidator.validate(head: .request(target, headers: []),
                                           body: HTTPBodyDescriptor(length: nil, complete: true, changed: false))
        return target
    }

    /// Request fields for `target`. Unchanged when the target is the original. Otherwise Host is
    /// removed (the writer generates it, and h2 `:authority`, from the target) together with
    /// Proxy-Authorization; when the origin (scheme, host or port) changes, Authorization, Cookie,
    /// Origin and Referer are removed too unless `preserveCredentials`.
    static func sanitizedHeaders(
        _ headers: [HeaderField], from original: HTTPMessageTarget, to target: HTTPMessageTarget, preserveCredentials: Bool,
        explicitCredentialFields: [HeaderField] = []
    ) -> [HeaderField] {
        RequestRouting.sanitizedHeaders(headers, from: original, to: target, preserveCredentials: preserveCredentials,
                                        explicitCredentialFields: explicitCredentialFields)
    }

    static func sameOrigin(_ a: HTTPMessageTarget, _ b: HTTPMessageTarget) -> Bool {
        RequestRouting.sameOrigin(a, b)
    }

    /// The transport target of `target` (default port by scheme, for the generated Host).
    static func requestTarget(_ target: HTTPMessageTarget) -> RequestTarget {
        RequestTarget(host: target.host, port: target.port, originForm: target.pathAndQuery,
                      defaultPort: target.scheme.lowercased() == "https" ? 443 : 80)
    }

    /// The upstream route for a decided target. A remapped target must not name one of this
    /// proxy's listener endpoints; the pool repeats the check on the connected socket.
    /// `http1Only` offers only http/1.1 and keys the pool apart from automatic routes.
    static func resolve(
        _ target: RequestTarget, scheme: String, upgrade: Bool, remapped: Bool, listeners: ProxyListenerEndpoints?,
        http1Only: Bool = false
    ) throws -> UpstreamRoute {
        if remapped, listeners?.containsLiteral(host: target.host, port: target.port) == true {
            throw ProxySelfTargetError(authority: target.authority)
        }
        let policy: UpstreamProtocolPolicy = upgrade ? .http1OnlyUpgrade : (http1Only ? .http1Only : .automatic)
        return UpstreamRoute(scheme: scheme, host: target.host, port: target.port, policy: policy, rejectsListener: remapped)
    }
}
