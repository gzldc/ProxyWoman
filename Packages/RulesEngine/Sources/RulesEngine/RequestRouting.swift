import FlowStore

/// The request a rule-decided target sends (shared by the proxy and Execute, so an Execute overlay shows the
/// request the wire would carry).
public enum RequestRouting {
    /// The target a decided request goes to: the (composed) Map Remote target, else the original. Checked as the
    /// proxy checks it before sending (`ExchangeRuleSession.continuation`): a preserved `*` path cannot be
    /// remapped, and the target must be a valid request target.
    static func target(original: HTTPMessageTarget, decision: RequestRuleDecision) throws -> HTTPMessageTarget {
        guard case .remote(let remote) = decision.route else { return original }
        if case .preserve = remote.path, original.pathAndQuery == "*" {
            throw HTTPMutationError(code: .invalidPath, field: .path)
        }
        let target = remote.target(applyingTo: original)
        try HTTPMutationValidator.validate(
            head: .request(target, headers: []), body: HTTPBodyDescriptor(length: nil, complete: true, changed: false))
        return target
    }

    public static func sanitizedHeaders(
        _ headers: [HeaderField], from original: HTTPMessageTarget, to target: HTTPMessageTarget, preserveCredentials: Bool,
        explicitCredentialFields: [HeaderField] = []
    ) -> [HeaderField] {
        guard normalized(original) != normalized(target) else { return headers }
        var removed: Set<String> = ["host", "proxy-authorization"]
        if !sameOrigin(original, target), !preserveCredentials {
            removed.formUnion(["authorization", "cookie", "origin", "referer"])
        }
        return headers.filter { field in
            let name = field.name.lowercased()
            guard removed.contains(name) else { return true }
            // Host and proxy credentials always follow the changed-target policy. An explicit
            // new end-origin credential may survive, but never an unchanged sibling value.
            guard ["authorization", "cookie", "origin", "referer"].contains(name) else { return false }
            return explicitCredentialFields.contains { $0.name.lowercased() == name && $0.value == field.value }
        }
    }
    public static func sameOrigin(_ a: HTTPMessageTarget, _ b: HTTPMessageTarget) -> Bool {
        let a = normalized(a), b = normalized(b)
        return a.scheme == b.scheme && a.host == b.host && a.port == b.port
    }
    static func normalized(_ target: HTTPMessageTarget) -> HTTPMessageTarget {
        var host = Substring(target.host)
        if host.hasPrefix("["), host.hasSuffix("]") { host = host.dropFirst().dropLast() }
        return HTTPMessageTarget(scheme: target.scheme.lowercased(), host: host.lowercased(), port: target.port,
                                 method: target.method, pathAndQuery: target.pathAndQuery)
    }
}
