import Foundation
import Localization
import Testing
@testable import ProxyCore

@Suite(.productionChinese) struct LocalFailureLocalizationTests {
    @Test func productionPagesKeepTheLegacyBadGatewayTextByteForByte() {
        #expect(HTTPLocalFailureText.page(productName: "ProxyWoman", message: "上游提前关闭了连接")
            == "ProxyWoman：上游提前关闭了连接")
        #expect(HTTPLocalFailureText.unreachable(authority: "example.test:8443", reason: "连接已关闭")
            == "无法连接 example.test:8443（连接已关闭）")
    }

    @Test func productionServiceUnavailableAndTimeoutTextIsChinese() {
        #expect(HTTPLocalFailureText.serviceUnavailable(reason: "断点已满") == "代理暂时无法处理此请求（断点已满）")
        #expect(HTTPLocalFailureText.gatewayTimeout(reason: "等待 120 秒") == "等待处理此请求超时（等待 120 秒）")
    }

    @Test func productionRuleFailureTextIsChinese() {
        #expect(HTTPLocalFailureText.localAssetUnavailable().contains("本地资源"))
        #expect(HTTPLocalFailureText.ruleRejected(code: "protectedHeader") == "规则修改后的消息无效（protectedHeader）")
        #expect(HTTPLocalFailureText.ruleSelfTarget(authority: "127.0.0.1:9090")
            == "映射目标 127.0.0.1:9090 指向本代理，已拒绝以避免循环转发")
        #expect(HTTPLocalFailureText.ruleActionUnsupported(action: "mapLocal") == "此版本尚不能执行该规则动作（mapLocal）")
    }

    @Test func injectedEnglishUsesTheSameKeysAndPositionalArguments() throws {
        let url = try #require(Bundle.module.url(forResource: "Translations", withExtension: "bundle", subdirectory: "Fixtures"))
        let english = Localizer(bundle: try #require(Bundle(url: url)), preferredLanguages: ["en"])
        #expect(HTTPLocalFailureText.localAssetUnavailable(localizer: english) == "The local asset is unavailable, so the response could not be generated.")
        #expect(HTTPLocalFailureText.page(productName: "ProxyWoman", message: "m", localizer: english) == "ProxyWoman: m")
        #expect(HTTPLocalFailureText.unreachable(authority: "a:1", reason: "r", localizer: english) == "Cannot connect to a:1 (r)")
        #expect(HTTPLocalFailureText.serviceUnavailable(reason: "r", localizer: english)
            == "The proxy cannot handle this request right now (r)")
        #expect(HTTPLocalFailureText.gatewayTimeout(reason: "r", localizer: english) == "Timed out handling this request (r)")
        #expect(HTTPLocalFailureText.ruleRejected(code: "c", localizer: english) == "A rule produced an invalid message (c)")
        #expect(HTTPLocalFailureText.ruleSelfTarget(authority: "a:1", localizer: english)
            == "The mapped target a:1 is this proxy; refused to avoid a forwarding loop")
        #expect(HTTPLocalFailureText.ruleActionUnsupported(action: "x", localizer: english)
            == "This version cannot run that rule action yet (x)")
    }

    @Test func breakpointFailuresUseChineseAndEnglishMessages() throws {
        let url = try #require(Bundle.module.url(forResource: "Translations", withExtension: "bundle", subdirectory: "Fixtures"))
        let english = Localizer(bundle: try #require(Bundle(url: url)), preferredLanguages: ["en"])
        for (code, zh, en) in [
            (HTTPLocalFailureCode.breakpointBodyTooLarge, "断点正文超出了收集上限。", "The breakpoint body exceeds the collection limit."),
            (.breakpointBodyUnavailable, "无法完整收集断点正文。", "The complete breakpoint body could not be collected."),
            (.breakpointCapacity, "断点工单已满，无法暂停此请求。", "Breakpoint capacity is full."),
            (.breakpointTimeout, "请求断点等待超时。", "The request breakpoint timed out."),
            (.breakpointCancelled, "请求已在断点处取消。", "The request was cancelled at a breakpoint.")
        ] {
            #expect(HTTPLocalFailureText.breakpoint(code) == zh)
            #expect(HTTPLocalFailureText.breakpoint(code, localizer: english) == en)
        }
    }

    @Test func blockedPageTextIsLocalized() throws {
        let url = try #require(Bundle.module.url(forResource: "Translations", withExtension: "bundle", subdirectory: "Fixtures"))
        let bundle = try #require(Bundle(url: url))
        #expect(HTTPLocalFailureText.blocked(authority: "example.test:443") == "example.test:443 已被屏蔽列表拦截，请求没有发送到原站。")
        #expect(HTTPLocalFailureText.blocked(authority: "example.test:443", localizer: Localizer(bundle: bundle, preferredLanguages: ["en"]))
            == "example.test:443 is on the block list; the request was not sent to the origin.")
        #expect(HTTPLocalFailureText.blocked(authority: "example.test:443", localizer: Localizer(bundle: bundle, preferredLanguages: ["fr"]))
            == "example.test:443 figure dans la liste de blocage ; la requête n’a pas été envoyée à l’origine.")
        #expect(HTTPLocalFailureText.blocked(authority: "example.test:443", localizer: Localizer(bundle: bundle, preferredLanguages: ["zh-Hans"]))
            == "example.test:443 已被屏蔽列表拦截，请求没有发送到原站。")
    }

    @Test func offlineConditionTextIsLocalized() throws {
        let url = try #require(Bundle.module.url(forResource: "Translations", withExtension: "bundle", subdirectory: "Fixtures"))
        let english = Localizer(bundle: try #require(Bundle(url: url)), preferredLanguages: ["en"])
        #expect(UpstreamConnector.describe(NetworkConditionError.offline) == "已按网络条件模拟断网，没有发起连接。")
        #expect(UpstreamConnector.describe(NetworkConditionError.offline, localizer: english)
            == "Offline was simulated by the network conditions; no connection was made.")
    }

    @Test func machineCodesAreStableIdentifiers() {
        #expect(HTTPLocalFailureCode.allCases.map(\.rawValue) == [
            "breakpoint.bodyTooLarge", "breakpoint.bodyUnavailable",
            "breakpoint.capacity", "breakpoint.timeout", "breakpoint.cancelled",
            "upstream.unreachable", "upstream.tlsFailed", "request.pendingBytesExceeded", "request.untranslatable",
            "response.untranslatable", "proxy.serviceUnavailable", "proxy.gatewayTimeout",
            "rule.rejected", "rule.selfTarget", "rule.actionUnsupported", "rule.localAssetUnavailable", "rule.closed",
            "traffic.blocked", "rewrite.bodyTooLarge", "rewrite.bodyTimeout", "rewrite.bodyUnavailable",
            "peek.bodyTimeout", "peek.bodyUnavailable", "peek.responseBodyTimeout", "peek.responseBodyUnavailable",
        ])
    }

    @Test func ruleClosedTextNamesTheRule() throws {
        let url = try #require(Bundle.module.url(forResource: "Translations", withExtension: "bundle", subdirectory: "Fixtures"))
        let bundle = try #require(Bundle(url: url))
        #expect(HTTPLocalFailureText.ruleClosed(ruleName: "R") == "连接已被规则「R」关闭。")
        #expect(HTTPLocalFailureText.ruleClosed(ruleName: "R", localizer: Localizer(bundle: bundle, preferredLanguages: ["en"]))
            == "The connection was closed by the rule “R”.")
        #expect(HTTPLocalFailureText.ruleClosed(ruleName: "R", localizer: Localizer(bundle: bundle, preferredLanguages: ["fr"]))
            == "La connexion a été fermée par la règle « R ».")
    }

    @Test func peekFailurePagesAreLocalized() throws {
        let url = try #require(Bundle.module.url(forResource: "Translations", withExtension: "bundle", subdirectory: "Fixtures"))
        let bundle = try #require(Bundle(url: url))
        let english = Localizer(bundle: bundle, preferredLanguages: ["en"])
        let french = Localizer(bundle: bundle, preferredLanguages: ["fr"])
        let chinese = Localizer(bundle: bundle, preferredLanguages: ["zh-Hans"])
        #expect(HTTPLocalFailureText.peek(.peekBodyTimeout) == "收集请求正文以判断规则条件超时，已中止。")
        #expect(HTTPLocalFailureText.peek(.peekBodyUnavailable) == "无法完整收集请求正文以判断规则条件，已中止。")
        #expect(HTTPLocalFailureText.peek(.peekBodyTimeout, localizer: chinese) == HTTPLocalFailureText.peek(.peekBodyTimeout))
        #expect(HTTPLocalFailureText.peek(.peekBodyUnavailable, localizer: chinese) == HTTPLocalFailureText.peek(.peekBodyUnavailable))
        #expect(HTTPLocalFailureText.peek(.peekBodyTimeout, localizer: english)
            == "Collecting the request body for a rule condition timed out; the exchange was stopped.")
        #expect(HTTPLocalFailureText.peek(.peekBodyUnavailable, localizer: english)
            == "The request body could not be collected completely for a rule condition; the exchange was stopped.")
        #expect(HTTPLocalFailureText.peek(.peekBodyTimeout, localizer: french)
            == "La collecte du corps de la requête pour une condition de règle a expiré ; l’échange a été interrompu.")
        #expect(HTTPLocalFailureText.peek(.peekBodyUnavailable, localizer: french)
            == "Le corps de la requête n’a pas pu être collecté entièrement pour une condition de règle ; l’échange a été interrompu.")
    }

    @Test func responsePeekFailurePagesAreLocalized() throws {
        let url = try #require(Bundle.module.url(forResource: "Translations", withExtension: "bundle", subdirectory: "Fixtures"))
        let bundle = try #require(Bundle(url: url))
        let english = Localizer(bundle: bundle, preferredLanguages: ["en"])
        let french = Localizer(bundle: bundle, preferredLanguages: ["fr"])
        #expect(HTTPLocalFailureText.peek(.peekResponseBodyTimeout) == "收集响应正文以判断规则条件超时，已中止。")
        #expect(HTTPLocalFailureText.peek(.peekResponseBodyUnavailable) == "无法完整收集响应正文以判断规则条件，已中止。")
        #expect(HTTPLocalFailureText.peek(.peekResponseBodyTimeout, localizer: english)
            == "Collecting the response body for a rule condition timed out; the exchange was stopped.")
        #expect(HTTPLocalFailureText.peek(.peekResponseBodyUnavailable, localizer: english)
            == "The response body could not be collected completely for a rule condition; the exchange was stopped.")
        #expect(HTTPLocalFailureText.peek(.peekResponseBodyTimeout, localizer: french)
            == "La collecte du corps de la réponse pour une condition de règle a expiré ; l’échange a été interrompu.")
        #expect(HTTPLocalFailureText.peek(.peekResponseBodyUnavailable, localizer: french)
            == "Le corps de la réponse n’a pas pu être collecté entièrement pour une condition de règle ; l’échange a été interrompu.")
    }

    @Test func rewriteFailurePagesAreLocalized() throws {
        let url = try #require(Bundle.module.url(forResource: "Translations", withExtension: "bundle", subdirectory: "Fixtures"))
        let bundle = try #require(Bundle(url: url))
        let english = Localizer(bundle: bundle, preferredLanguages: ["en"])
        let french = Localizer(bundle: bundle, preferredLanguages: ["fr"])
        let chinese = Localizer(bundle: bundle, preferredLanguages: ["zh-Hans"])
        #expect(HTTPLocalFailureText.rewrite(.rewriteBodyTooLarge, limitMiB: 8) == "正文超过正文替换上限 8 MB，已中止。")
        #expect(HTTPLocalFailureText.rewrite(.rewriteBodyTimeout, limitMiB: 8) == "收集正文以执行正文替换超时，已中止。")
        #expect(HTTPLocalFailureText.rewrite(.rewriteBodyUnavailable, limitMiB: 8) == "无法完整收集正文以执行正文替换，已中止。")
        #expect(HTTPLocalFailureText.rewrite(.rewriteBodyTooLarge, limitMiB: 8, localizer: english)
            == "The body exceeds the body rewrite limit of 8 MB; the exchange was stopped.")
        #expect(HTTPLocalFailureText.rewrite(.rewriteBodyTimeout, limitMiB: 8, localizer: english)
            == "Collecting the body for a body rewrite timed out; the exchange was stopped.")
        #expect(HTTPLocalFailureText.rewrite(.rewriteBodyUnavailable, limitMiB: 8, localizer: english)
            == "The body could not be collected completely for a body rewrite; the exchange was stopped.")
        #expect(HTTPLocalFailureText.rewrite(.rewriteBodyTooLarge, limitMiB: 8, localizer: french)
            == "Le corps dépasse la limite de réécriture de 8 Mo ; l’échange a été interrompu.")
        #expect(HTTPLocalFailureText.rewrite(.rewriteBodyTimeout, limitMiB: 8, localizer: french)
            == "La collecte du corps pour la réécriture a expiré ; l’échange a été interrompu.")
        #expect(HTTPLocalFailureText.rewrite(.rewriteBodyUnavailable, limitMiB: 8, localizer: french)
            == "Le corps n’a pas pu être collecté entièrement pour la réécriture ; l’échange a été interrompu.")
        #expect(HTTPLocalFailureText.rewrite(.rewriteBodyTooLarge, limitMiB: 8, localizer: chinese)
            == "正文超过正文替换上限 8 MB，已中止。")
        #expect(HTTPLocalFailureText.rewrite(.rewriteBodyUnavailable, limitMiB: 8, localizer: chinese)
            == "无法完整收集正文以执行正文替换，已中止。")
    }
}
