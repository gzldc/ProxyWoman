import Localization

/// Stable machine identifiers for a final response the proxy generates instead of forwarding an
/// upstream one. The HTTP status is chosen separately: several codes share 502.
enum HTTPLocalFailureCode: String, Sendable, CaseIterable {
    case breakpointBodyTooLarge = "breakpoint.bodyTooLarge"
    case breakpointBodyUnavailable = "breakpoint.bodyUnavailable"
    case breakpointCapacity = "breakpoint.capacity"
    case breakpointTimeout = "breakpoint.timeout"
    case breakpointCancelled = "breakpoint.cancelled"
    /// The upstream could not be reached or closed before any response head (502).
    case upstreamUnreachable = "upstream.unreachable"
    /// The upstream TLS handshake timed out or its certificate was rejected (502).
    case upstreamTLSFailed = "upstream.tlsFailed"
    /// The request could not be held while waiting for an upstream (502).
    case pendingBytesExceeded = "request.pendingBytesExceeded"
    /// The request head or trailers cannot be expressed on the upstream hop (502).
    case requestUntranslatable = "request.untranslatable"
    /// The final response head was rejected or cannot be expressed downstream (502).
    case responseUntranslatable = "response.untranslatable"
    /// The proxy cannot take this request on right now, for example a full reservation (503).
    case serviceUnavailable = "proxy.serviceUnavailable"
    /// The proxy gave up waiting on its own deadline (504).
    case gatewayTimeout = "proxy.gatewayTimeout"
    /// A rule edit made the message invalid when it was applied (502).
    case ruleRejected = "rule.rejected"
    /// A Map Remote target is one of this proxy's own listener endpoints (502).
    case ruleSelfTarget = "rule.selfTarget"
    /// A matched rule action this build cannot execute yet (502).
    case ruleActionUnsupported = "rule.actionUnsupported"
    /// The private local representation could not be opened or prepared (502).
    case ruleLocalAssetUnavailable = "rule.localAssetUnavailable"
    /// A rule closed the connection (or, over HTTP/2, reset the stream); no response was written.
    case ruleClosed = "rule.closed"
    /// The target matched an enabled Block list entry; nothing was sent to the origin (403).
    case blockedByList = "traffic.blocked"
    /// A body collected for a body rewrite grew past the rewrite cap (response 502, request 413).
    case rewriteBodyTooLarge = "rewrite.bodyTooLarge"
    /// Collecting a body for a body rewrite took longer than allowed (504).
    case rewriteBodyTimeout = "rewrite.bodyTimeout"
    /// A body for a body rewrite could not be collected completely (502).
    case rewriteBodyUnavailable = "rewrite.bodyUnavailable"
    /// A request body peeked for rule conditions stopped arriving, or took too long in all, after part of
    /// it was taken from the client (504).
    case peekBodyTimeout = "peek.bodyTimeout"
    /// A request body peeked for rule conditions could not be collected completely after part of it was
    /// taken from the client (502).
    case peekBodyUnavailable = "peek.bodyUnavailable"
    /// The same for a response body (504 / 502 by the proxy to the client).
    case peekResponseBodyTimeout = "peek.responseBodyTimeout"
    case peekResponseBodyUnavailable = "peek.responseBodyUnavailable"
}

/// Localized text of locally generated failure pages. The zh-Hans production strings of the
/// legacy 502 page are unchanged byte for byte.
enum HTTPLocalFailureText {
    static func breakpoint(_ code: HTTPLocalFailureCode, localizer: Localizer = L10n.localizer) -> String {
        let key: String
        switch code {
        case .breakpointBodyTooLarge: key = "proxyLocalFailure.breakpointBodyTooLarge"
        case .breakpointBodyUnavailable: key = "proxyLocalFailure.breakpointBodyUnavailable"
        case .breakpointCapacity: key = "proxyLocalFailure.breakpointCapacity"
        case .breakpointTimeout: key = "proxyLocalFailure.breakpointTimeout"
        case .breakpointCancelled: key = "proxyLocalFailure.breakpointCancelled"
        default: preconditionFailure("not a breakpoint failure")
        }
        return localizer.string(key)
    }
    /// `limitMiB` is the rewrite cap in MiB, used by the too-large page only.
    static func rewrite(_ code: HTTPLocalFailureCode, limitMiB: Int, localizer: Localizer = L10n.localizer) -> String {
        switch code {
        case .rewriteBodyTooLarge: return localizer.format("proxyLocalFailure.rewriteBodyTooLarge", arguments: [limitMiB])
        case .rewriteBodyTimeout: return localizer.string("proxyLocalFailure.rewriteBodyTimeout")
        case .rewriteBodyUnavailable: return localizer.string("proxyLocalFailure.rewriteBodyUnavailable")
        default: preconditionFailure("not a body rewrite failure")
        }
    }
    static func peek(_ code: HTTPLocalFailureCode, localizer: Localizer = L10n.localizer) -> String {
        switch code {
        case .peekBodyTimeout: return localizer.string("proxyLocalFailure.peekBodyTimeout")
        case .peekBodyUnavailable: return localizer.string("proxyLocalFailure.peekBodyUnavailable")
        case .peekResponseBodyTimeout: return localizer.string("proxyLocalFailure.peekResponseBodyTimeout")
        case .peekResponseBodyUnavailable: return localizer.string("proxyLocalFailure.peekResponseBodyUnavailable")
        default: preconditionFailure("not a body peek failure")
        }
    }
    /// The complete plain-text body: product name and message.
    static func page(productName: String, message: String, localizer: Localizer = L10n.localizer) -> String {
        localizer.format("proxyLocalFailure.page", arguments: [productName, message])
    }
    static func unreachable(authority: String, reason: String, localizer: Localizer = L10n.localizer) -> String {
        localizer.format("proxyLocalFailure.unreachable", arguments: [authority, reason])
    }
    static func serviceUnavailable(reason: String, localizer: Localizer = L10n.localizer) -> String {
        localizer.format("proxyLocalFailure.serviceUnavailable", arguments: [reason])
    }
    static func gatewayTimeout(reason: String, localizer: Localizer = L10n.localizer) -> String {
        localizer.format("proxyLocalFailure.gatewayTimeout", arguments: [reason])
    }
    /// `code` is the validator's stable machine code; never user content.
    static func ruleRejected(code: String, localizer: Localizer = L10n.localizer) -> String {
        localizer.format("proxyLocalFailure.ruleRejected", arguments: [code])
    }
    static func ruleSelfTarget(authority: String, localizer: Localizer = L10n.localizer) -> String {
        localizer.format("proxyLocalFailure.ruleSelfTarget", arguments: [authority])
    }
    static func localAssetUnavailable(localizer: Localizer = L10n.localizer) -> String {
        localizer.string("proxyLocalFailure.localAssetUnavailable")
    }
    static func blocked(authority: String, localizer: Localizer = L10n.localizer) -> String {
        localizer.format("proxyLocalFailure.blocked", arguments: [authority])
    }
    static func ruleActionUnsupported(action: String, localizer: Localizer = L10n.localizer) -> String {
        localizer.format("proxyLocalFailure.ruleActionUnsupported", arguments: [action])
    }
    /// The recorded failure of an exchange a rule closed; `ruleName` is the user's rule name.
    static func ruleClosed(ruleName: String, localizer: Localizer = L10n.localizer) -> String {
        localizer.format("proxyLocalFailure.ruleClosed", arguments: [ruleName])
    }
}
