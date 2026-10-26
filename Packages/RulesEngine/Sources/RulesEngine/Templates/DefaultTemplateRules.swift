import Foundation

/// The rule definitions of `DefaultTemplateCatalog`: for every template rule its group, priority,
/// enabled flag, conditions and ordered actions. Where the reference identified a value by a name
/// (a process, a protocol, a colour) the stored form of this app is used.
enum DefaultTemplateRules {
    struct Spec {
        var group: DefaultTemplateGroupKey
        /// 1-based, shared with the sibling groups.
        var priority: Int
        var enabled = false
        var conditions: ConditionGroup
        var actions: [RuleAction]
    }

    // MARK: building blocks

    private static let processPattern = #"com\.apple\.webkit|chrome|msedge"#
    private static let hostPattern = #"google\.com|example\.com"#

    private static func row(
        _ field: ConditionField, _ op: ConditionOperator = .contains, _ value: String = "", name: String? = nil,
        caseSensitive: Bool = false
    ) -> ConditionRow {
        ConditionRow(
            field: field, name: name, op: op, value: value, caseSensitive: caseSensitive,
            nameCaseSensitive: field.hasKeyCaseOption ? false : nil)
    }

    private static func all(_ rows: ConditionRow...) -> ConditionGroup { ConditionGroup(mode: .all, rows: rows) }
    private static func any(_ rows: ConditionRow...) -> ConditionGroup { ConditionGroup(mode: .any, rows: rows) }
    private static func none(_ rows: ConditionRow...) -> ConditionGroup { ConditionGroup(mode: .none, rows: rows) }
    private static let everySession = ConditionGroup(mode: .all, rows: [ConditionRow(field: .allSessions, op: .equals)])

    private static func act(_ kind: ActionKind) -> RuleAction { RuleAction(kind) }
    private static func setRequestHeader(_ name: String, _ value: String) -> RuleAction {
        act(.editHeaders(direction: .request, operations: [.set(name: name, value: value, nameCaseSensitive: false)]))
    }
    private static func removeRequestHeader(_ name: String) -> RuleAction {
        act(.editHeaders(direction: .request, operations: [.remove(name: name, nameCaseSensitive: false)]))
    }
    private static func setResponseHeader(_ name: String, _ value: String) -> RuleAction {
        act(.editHeaders(direction: .response, operations: [.set(name: name, value: value, nameCaseSensitive: false)]))
    }
    private static func removeResponseHeader(_ name: String) -> RuleAction {
        act(.editHeaders(direction: .response, operations: [.remove(name: name, nameCaseSensitive: false)]))
    }
    private static func mark(_ background: String) -> RuleAction { act(.mark(MarkAction(background: background))) }

    // MARK: neutral content

    /// A small inline picture standing in for a logo (percent-encoded, so it holds no markup characters).
    static let logoDataURI =
        "data:image/svg+xml,%3Csvg%20xmlns%3D%27http%3A%2F%2Fwww.w3.org%2F2000%2Fsvg%27%20width%3D%2748%27%20height%3D%2748%27%3E"
        + "%3Crect%20width%3D%2748%27%20height%3D%2748%27%20rx%3D%278%27%20fill%3D%27%23336cdc%27%2F%3E%3C%2Fsvg%3E"

    static let exampleFileText = "Example file body served by a template rule.\n"

    private static let examplePageBody = """
        <!doctype html>
        <html>
        <head>
            <meta charset="utf-8" />
            <title>Example Page</title>
            <style type="text/css">
            body { font-family: -apple-system, system-ui, sans-serif; margin: 15vh auto; max-width: 36em; padding: 0 1em; }
            </style>
        </head>
        <body>
            <h1>Example Page</h1>
            <p>This response was written by a rule instead of coming from the server.</p>
        </body>
        </html>

        """

    /// A complete response for the "return response" template: status line, headers, blank line, body.
    static var exampleResponse: HandwrittenResponse {
        let body = examplePageBody.replacingOccurrences(of: "\n", with: "\r\n")
        let head = [
            "HTTP/1.1 200 OK", "Content-Type: text/html; charset=UTF-8", "Cache-Control: no-store",
            "Content-Length: \(body.utf8.count)",
        ]
        return HandwrittenResponse(text: head.joined(separator: "\r\n") + "\r\n\r\n" + body)
    }

    /// The browser identity two templates set on the request and, for pages, in the script environment.
    private static func userAgentActions(userAgent: String, platform: String) -> [RuleAction] {
        let script =
            #"$1!function e(t,r){if(navigator.__defineGetter__?navigator.__defineGetter__("userAgent",function(){return r}):Object.defineProperty&&Object.defineProperty(navigator,"userAgent",{get:function(){return r}}),t.navigator.userAgent!==r){var n={get:function(){return r}};try{Object.defineProperty(t.navigator,"userAgent",n)}catch(i){t.navigator=Object.create(navigator,{userAgent:n})}}}(window,""#
            + userAgent + #"");"#
        return [
            setRequestHeader("user-agent", userAgent),
            setRequestHeader("sec-ch-ua-platform", "\"\(platform)\""),
            act(.rewriteBody(
                direction: .response,
                BodyRewriteAction(
                    find: #"(<script(?:(?!src).)*?>)"#, replacement: script, syntax: .regex, caseSensitive: false,
                    editorLanguage: "html"))),
        ]
    }

    // MARK: the table

    // The two "return CONNECT tunnel" rules carry no "method contains CONNECT" row: a rule with that action is
    // judged only at the CONNECT line, where this app accepts connection facts only (validation refuses a method
    // row), and the action itself already runs nowhere else.

    // swiftlint:disable:next function_body_length
    static func spec(_ key: DefaultTemplateRuleKey) -> Spec {
        switch key {
        case .allowOnlyProcesses:
            Spec(group: .allowBlock, priority: 1, conditions: none(row(.clientApp, .regex, processPattern)),
                 actions: [act(.closeConnection(.reset))])
        case .allowOnlyHosts:
            Spec(group: .allowBlock, priority: 2, conditions: none(row(.url, .regex, hostPattern)),
                 actions: [act(.closeConnection(.reset))])
        case .blockProcesses:
            Spec(group: .allowBlock, priority: 3, conditions: all(row(.clientApp, .regex, processPattern)),
                 actions: [act(.closeConnection(.reset))])
        case .blockHosts:
            Spec(group: .allowBlock, priority: 4, conditions: all(row(.url, .regex, hostPattern)),
                 actions: [act(.closeConnection(.reset))])
        case .hideConnectTunnels:
            Spec(group: .filters, priority: 1, conditions: all(row(.method, .contains, "CONNECT")), actions: [act(.hide)])
        case .hideProcesses:
            Spec(group: .filters, priority: 2, conditions: all(row(.clientApp, .regex, processPattern)), actions: [act(.hide)])
        case .showOnlyProcesses:
            Spec(group: .filters, priority: 3, conditions: none(row(.clientApp, .regex, processPattern)), actions: [act(.hide)])
        case .showOnlyHosts:
            Spec(group: .filters, priority: 4, conditions: none(row(.url, .regex, hostPattern)), actions: [act(.hide)])
        case .hideHosts:
            Spec(group: .filters, priority: 5, conditions: all(row(.url, .regex, hostPattern)), actions: [act(.hide)])
        case .hideConnectsOfBlockedProcesses:
            Spec(group: .filters, priority: 6,
                 conditions: all(
                    row(.clientApp, .regex, "teams|ms teams|msteams|microsoftteams|microsoft teams"),
                    row(.method, .contains, "CONNECT")),
                 actions: [act(.hide)])
        case .showOnlyLocalhost:
            Spec(group: .filters, priority: 7,
                 conditions: none(row(.host, .contains, "localhost"), row(.host, .contains, "127.0.0.1")),
                 actions: [act(.hide)])
        case .mapRemoteLocalhost:
            Spec(group: .mapTraffic, priority: 3, conditions: all(row(.url, .contains, "example.com")),
                 actions: [act(.modifyURL(URLEditAction(
                    mode: .regex, find: "(.*example.com/)(.*)", replacement: "http://localhost:4000/$2")))])
        case .mapRemoteURL:
            Spec(group: .mapTraffic, priority: 4, conditions: all(row(.url, .contains, "example.com")),
                 actions: [act(.modifyURL(URLEditAction(mode: .set, replacement: "https://www.google.com")))])
        case .redirect307:
            Spec(group: .mapTraffic, priority: 5,
                 conditions: all(
                    row(.method, .equals, "GET"),
                    row(
                        .url, .regex,
                        #"^(example\.com|www\.example\.com|http:\/\/example.com|https:\/\/example.com|http:\/\/www.example\.com)"#)),
                 actions: [
                    act(.rewriteStatus(RewriteStatusAction(status: 307, reason: "Internal Redirect"))),
                    setResponseHeader("Location", "https://www.example.com"),
                 ])
        case .manualReturnConnect:
            Spec(group: .mapLocalManual, priority: 1, enabled: true,
                 conditions: all(row(.url, .contains, "example.com")),
                 actions: [act(.returnConnectTunnel)])
        case .manualReturnResponse:
            Spec(group: .mapLocalManual, priority: 2, enabled: true,
                 conditions: all(row(.url, .contains, "example.com"), row(.method, .notContains, "CONNECT")),
                 actions: [act(.returnHandwritten(exampleResponse))])
        case .fileReturnConnect:
            Spec(group: .mapLocalFile, priority: 1, enabled: true,
                 conditions: all(row(.url, .contains, "example.com", caseSensitive: true)),
                 actions: [act(.returnConnectTunnel)])
        case .fileReturnResponse:
            Spec(group: .mapLocalFile, priority: 2, enabled: true,
                 conditions: all(
                    row(.url, .contains, "example.com", caseSensitive: true), row(.method, .notContains, "CONNECT")),
                 actions: [act(.returnFile(MapLocalAction(assetID: DefaultTemplateCatalog.exampleFilePlaceholderID, headers: [])))])
        case .insertHTMLRegex:
            Spec(group: .modifyTraffic, priority: 1, conditions: all(row(.url, .contains, "example.com")),
                 actions: [act(.rewriteBody(
                    direction: .response,
                    BodyRewriteAction(
                        find: #"<div[\n\r\s\S]*?<h1>"#, replacement: "<div><img src=\"\(logoDataURI)\"><h1>",
                        syntax: .regex, caseSensitive: false, editorLanguage: nil)))])
        case .insertHTML:
            Spec(group: .modifyTraffic, priority: 2, conditions: all(row(.url, .contains, "example.com")),
                 actions: [act(.rewriteBody(
                    direction: .response,
                    BodyRewriteAction(
                        find: "<h1>Example Domain</h1>",
                        replacement: "<img src=\"\(logoDataURI)\">\n<h1>Example Domain</h1>",
                        syntax: .text, caseSensitive: false, editorLanguage: "html")))])
        case .modifyImageEndpoint:
            Spec(group: .modifyTraffic, priority: 3,
                 conditions: all(row(.url, .contains, "googlelogo", caseSensitive: true), row(.method, .equals, "GET")),
                 actions: [act(.modifyURL(URLEditAction(mode: .set, replacement: "https://www.gstatic.com/ac/cb/youtube_logo_v2.svg")))])
        case .userAgentChromeMac:
            Spec(group: .tooling, priority: 4, conditions: everySession,
                 actions: userAgentActions(
                    userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_14_6) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/123.0.0.0 Safari/537.36",
                    platform: "Mac"))
        case .userAgentChromeWindows:
            Spec(group: .tooling, priority: 5, conditions: everySession,
                 actions: userAgentActions(
                    userAgent: "Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/123.0.0.0 Safari/537.36",
                    platform: "Windows"))
        case .bypassCORS:
            Spec(group: .tooling, priority: 2, conditions: everySession,
                 actions: [
                    setResponseHeader("Access-Control-Allow-Origin", "*"),
                    setResponseHeader("Access-Control-Allow-Methods", "*"),
                    setResponseHeader("Access-Control-Allow-Credentials", "true"),
                    setResponseHeader("Access-Control-Allow-Headers", "*"),
                 ])
        case .noCaching:
            Spec(group: .tooling, priority: 1, conditions: everySession,
                 actions: [
                    removeRequestHeader("if-modified-since"),
                    removeRequestHeader("if-none-match"),
                    setRequestHeader("pragma", "no-cache"),
                    setRequestHeader("cache-control", "no-cache"),
                    setResponseHeader("expires", "0"),
                    removeResponseHeader("last-modified"),
                    removeResponseHeader("etag"),
                    setResponseHeader("cache-control", "no-cache"),
                 ])
        case .blockCookies:
            Spec(group: .tooling, priority: 3, conditions: everySession,
                 actions: [removeRequestHeader("Cookie"), removeResponseHeader("Set-Cookie")])
        case .markLongLivingSessions:
            Spec(group: .uiMarks, priority: 1,
                 conditions: any(
                    row(.appProtocol, .equals, "websocket"), row(.appProtocol, .equals, "rpc"),
                    row(.appProtocol, .equals, "grpc"), row(.appProtocol, .equals, "sse"),
                    row(.appProtocol, .equals, "socketio")),
                 actions: [mark("#FF19FFFF")])
        case .markScriptsAndJSON:
            Spec(group: .uiMarks, priority: 2,
                 conditions: any(
                    row(.responseHeader, .regex, "javascript|json", name: "Content-Type"),
                    row(.method, .contains, "GET")),
                 actions: [mark("#03FFFFFF")])
        }
    }
}
