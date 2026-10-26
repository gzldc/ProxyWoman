import FlowStore
import Foundation
import Localization
import RulesEngine
import Testing

@testable import AppCore

/// The field menu, the row draft, the group lines and the summaries of the Fiddler-style condition editor (spec 12.1-12.4).
@Suite(.productionChinese) struct ConditionModelTests {
    private let zh = Localizer(bundle: L10n.bundle, preferredLanguages: ["zh-Hans"])

    // MARK: field menu

    @Test func menuHasFifteenGroupsInTheSpecOrder() {
        let groups = ConditionFieldCatalog.menuGroups.map { $0.map(\.field) }
        #expect(groups == [
            [.allSessions],
            [.url, .host, .path, .scheme],
            [.method, .appProtocol, .statusCode, .sessionState],
            [.clientHTTPVersion, .upstreamHTTPVersion],
            [.requestBody, .responseBody],
            [.requestHeader, .responseHeader],
            [.requestCookie, .responseCookie, .cookie],
            [.requestBodySize, .responseBodySize],
            [.requestDate, .requestTime, .durationMs],
            [.clientIP, .remoteIP],
            [.certificate],
            [.clientTLSVersion, .upstreamTLSVersion, .tlsVersion],
            [.clientApp],
            [.comment, .rulesModified],
            [.magicString],
        ])
    }

    @Test func menuListsEveryNewFieldOnceAndNoOldStyleOne() {
        let fields = ConditionFieldCatalog.menuFields
        #expect(Set(fields).count == fields.count)
        let oldStyle: Set<ConditionField> = [.port, .queryString, .queryParam, .pathAndQuery]
        #expect(Set(fields) == Set(ConditionField.allCases).subtracting(oldStyle))
        for field in oldStyle { #expect(ConditionFieldCatalog.isLegacyOnly(field: field, name: nil)) }
    }

    @Test func menuDirectionsFollowTheTable() {
        func direction(_ field: ConditionField) -> ConditionDirection { ConditionFieldCatalog.direction(of: field) }
        for field in [ConditionField.allSessions, .url, .host, .path, .scheme, .method, .clientHTTPVersion, .requestBody, .requestHeader,
            .requestCookie, .requestBodySize, .requestDate, .requestTime, .clientIP, .clientTLSVersion, .clientApp]
        { #expect(direction(field) == .request, "\(field)") }
        for field in [ConditionField.appProtocol, .statusCode, .upstreamHTTPVersion, .responseBody, .responseHeader, .responseCookie,
            .responseBodySize, .durationMs, .remoteIP, .certificate, .upstreamTLSVersion]
        { #expect(direction(field) == .response, "\(field)") }
        for field in [ConditionField.sessionState, .cookie, .tlsVersion, .comment, .rulesModified, .magicString] {
            #expect(direction(field) == .both, "\(field)")
        }
        // Not the engine's side: the engine reads URL on both, the menu shows it as a request field.
        #expect(ConditionField.url.side == .both && direction(.url) == .request)
    }

    @Test func threeDirectionsHaveThreeSymbolsAndTokens() {
        let all: [ConditionDirection] = [.request, .response, .both]
        #expect(Set(all.map(\.symbolName)).count == 3)
        #expect(Set(all.map { "\($0.token)" }).count == 3)
        #expect(all.map { $0.title(localizer: zh) } == ["请求", "响应", "两侧"])
    }

    @Test func sessionStateCookieAndTLSVersionAreGreyedOut() {
        let disabled = ConditionFieldCatalog.menuGroups.flatMap { $0 }.filter(\.isDeprecated).map(\.field)
        #expect(disabled == [.sessionState, .cookie, .tlsVersion])
        let items = ConditionFieldCatalog.menuSections.flatMap(\.entries)
        #expect(items.filter(\.isDeprecated).map(\.field) == [.sessionState, .tlsVersion, .cookie])
    }

    @Test func menuTitlesAreTheChineseNamesOfTheSpec() {
        let titles = ConditionFieldCatalog.menuSections.map { section in
            section.entries.map { ConditionPresentation.fieldTitle($0.field, localizer: zh) }
        }
        #expect(titles[0] == [
            "URL", "主机", "路径", "协议方案", "方法", "请求 Header", "请求 Cookie", "请求正文", "请求正文大小", "客户端 HTTP 版本",
            "客户端 TLS 版本", "客户端 IP", "请求日期", "请求时间", "进程",
        ])
        #expect(titles[1] == [
            "状态码", "协议", "响应 Header", "响应 Cookie", "响应正文", "响应正文大小", "远端 HTTP 版本", "远端 TLS 版本", "远端 IP", "耗时",
            "证书信息",
        ])
        #expect(titles[2] == ["所有会话", "注释", "魔法字符串", "会话状态", "TLS 版本", "Cookie", "已被规则修改"])
    }

    // MARK: draft

    @Test func changingTheFieldResetsTheRowLikeTheReference() {
        var row = ConditionRowDraft(
            row: ConditionRow(field: .requestHeader, name: "X-Test", op: .equals, value: "1", caseSensitive: true, nameCaseSensitive: true))
        row.setField(.responseHeader)
        #expect(row.op == .contains && row.name.isEmpty && row.value.isEmpty)
        #expect(!row.caseSensitive && !row.nameCaseSensitive)
        row = ConditionRowDraft(row: ConditionRow(field: .host, op: .equals, value: "a.com"))
        row.setField(.statusCode)
        #expect(row.op == .equals && row.value.isEmpty)
        row.setField(.requestDate)
        #expect(row.op == .equals && row.value.isEmpty)
        row.setField(.url)
        #expect(row.op == .contains)
        row.setField(.magicString)
        #expect(row.op == .contains && row.value.isEmpty)
        row.setField(.allSessions)
        #expect(!row.showsValue && row.value.isEmpty)
    }

    @Test func fixedIsFieldsStartOnTheirFirstOptionSoTheRowStaysValid() {
        var row = ConditionRowDraft(row: ConditionRow(field: .host, op: .contains, value: "a"))
        row.setField(.scheme)
        #expect(row.op == .equals && row.value == "https")
        row.setField(.appProtocol)
        #expect(row.value == "http")
        row.setField(.sessionState)
        #expect(row.value == "opened")
        row.setField(.rulesModified)
        #expect(row.value == "true")
        #expect(row.row.validationIssue(limits: RulesLimits()) == nil)
    }

    @Test func changingToCertificateStartsOnFriendlyNameWithItsDefaultComparison() {
        var row = ConditionRowDraft(row: ConditionRow(field: .statusCode, op: .greaterThan, value: "400"))
        row.setField(.certificate)
        #expect(row.name == "friendlyName" && row.op == .contains && row.value.isEmpty)
        row.setField(.requestHeader)
        #expect(row.name.isEmpty)
    }

    @Test func switchingTheCertificateItemFollowsItsKind() {
        var row = ConditionRowDraft(row: ConditionRow(field: .certificate, name: "friendlyName", op: .startsWith, value: "abc"))
        row.setName("subjectCommonName")
        #expect(row.op == .startsWith && row.value == "abc")  // same kind: nothing changes
        row.setName("version")
        #expect(row.op == .equals && row.value.isEmpty)
        row.value = "3"
        row.setName("expirationDate")
        #expect(row.op == .equals && row.value.isEmpty)
        row.setName("validity")
        #expect(row.op == .equals && row.value == "valid" && !row.showsValue)
        row.setCertificateValidity(valid: false)
        #expect(row.op == .equals && row.value == "invalid" && !row.showsValue)
        row.setName("issuerCountry")
        #expect(row.op == .contains)
    }

    @Test func settingAComparisonWithoutAValueClearsTheValue() {
        var row = ConditionRowDraft(row: ConditionRow(field: .requestHeader, name: "A", op: .equals, value: "1"))
        for op in [ConditionOperator.isEmpty, .isNotEmpty, .exists, .doesNotExist] {
            row.value = "x"
            row.setOperator(op)
            #expect(row.value.isEmpty && !row.showsValue, "\(op)")
        }
        row.setOperator(.contains)
        #expect(row.showsValue)
    }

    @Test func theKeyCaseSwitchIsPartOfTheDraftAndTheSavedRow() {
        var row = ConditionRowDraft(row: ConditionRow(field: .requestHeader, name: "A", op: .equals, value: "1"))
        #expect(!row.nameCaseSensitive)
        row.nameCaseSensitive = true
        #expect(row.row.nameCaseSensitive == true)
        #expect(ConditionRowDraft(row: row.row).nameCaseSensitive)
    }

    /// Ruling R8F2-T1a: a saved row that never had the setting shows its field's old comparison and saves unchanged.
    @Test func anUntouchedSavedRowKeepsNoKeyCaseSetting() {
        let cookie = ConditionRowDraft(row: ConditionRow(field: .requestCookie, name: "sid", op: .equals, value: "1"))
        #expect(cookie.nameCaseSensitive)  // Cookie names were exact.
        #expect(cookie.row.nameCaseSensitive == nil)
        #expect(cookie.row == ConditionRow(field: .requestCookie, name: "sid", op: .equals, value: "1"))
        let header = ConditionRowDraft(row: ConditionRow(field: .requestHeader, name: "A", op: .equals, value: "1"))
        #expect(!header.nameCaseSensitive && header.row.nameCaseSensitive == nil)
        // Switching it off on a cookie row is a setting: stored, not folded back to the old behaviour.
        var edited = cookie
        edited.nameCaseSensitive = false
        #expect(edited.row.nameCaseSensitive == false)
        // A row the editor starts on a field with a key states it; one on a field without a key stores nothing.
        var fresh = ConditionRowDraft(row: ConditionRow(field: .url, op: .contains))
        #expect(fresh.row.nameCaseSensitive == nil)
        fresh.setField(.requestCookie)
        #expect(fresh.row.nameCaseSensitive == false)
        fresh.setField(.host)
        #expect(fresh.row.nameCaseSensitive == nil)
    }

    @Test func openingASavedRowMigratesTheOldHTTPVersions() {
        for field in [ConditionField.clientHTTPVersion, .upstreamHTTPVersion] {
            let h1 = ConditionRowDraft(row: ConditionRow(field: field, op: .equals, value: "h1"))
            let h2 = ConditionRowDraft(row: ConditionRow(field: field, op: .notEquals, value: "H2"))
            // "h1" covered HTTP/1.0 and HTTP/1.1, so it becomes "starts with HTTP/1." and no match is lost.
            #expect(h1.value == "HTTP/1." && h1.op == .startsWith)
            #expect(h2.value == "HTTP/2" && h2.op == .notEquals)
            #expect(!h1.isLegacy)
            let notH1 = ConditionRowDraft(row: ConditionRow(field: field, op: .notEquals, value: "h1"))
            #expect(notH1.value == "HTTP/1." && notH1.op == .notContains && !notH1.isLegacy)
            let contains = ConditionRowDraft(row: ConditionRow(field: field, op: .contains, value: "H1"))
            #expect(contains.value == "HTTP/1." && contains.op == .contains)
            let starts = ConditionRowDraft(row: ConditionRow(field: field, op: .startsWith, value: "h1"))
            #expect(starts.value == "HTTP/1." && starts.op == .startsWith)
            let notContains = ConditionRowDraft(row: ConditionRow(field: field, op: .notContains, value: "h1"))
            #expect(notContains.value == "HTTP/1." && notContains.op == .notContains)
            let regex = ConditionRowDraft(row: ConditionRow(field: field, op: .regex, value: "h1"))
            #expect(regex.value == #"^HTTP/1\."# && regex.op == .regex)
            // A comparison with no sensible prefix form keeps naming the common version.
            let other = ConditionRowDraft(row: ConditionRow(field: field, op: .endsWith, value: "h1"))
            #expect(other.value == "HTTP/1.1" && other.op == .endsWith)
            let current = ConditionRowDraft(row: ConditionRow(field: field, op: .contains, value: "HTTP/1.0"))
            #expect(current.value == "HTTP/1.0")
        }
    }

    @Test func oldValuesFieldsAndComparisonsAreKeptButFlagged() {
        let state = ConditionRowDraft(row: ConditionRow(field: .sessionState, op: .equals, value: "completed"))
        #expect(state.value == "completed" && state.isLegacyValue && state.isLegacy && state.row.value == "completed")
        let open = ConditionRowDraft(row: ConditionRow(field: .sessionState, op: .equals, value: "opened"))
        #expect(!open.isLegacyValue && !open.isLegacy)
        let port = ConditionRowDraft(row: ConditionRow(field: .port, op: .equals, value: "443"))
        #expect(port.isLegacyField && port.isLegacy && !port.isLegacyOperator)
        let op = ConditionRowDraft(row: ConditionRow(field: .host, op: .wildcard, value: "*.a.com"))
        #expect(op.isLegacyOperator && op.isLegacy && op.row.op == .wildcard)
        let range = ConditionRowDraft(row: ConditionRow(field: .statusCode, op: .inRange, value: "200..299"))
        #expect(range.isLegacyOperator)
        let current = ConditionRowDraft(row: ConditionRow(field: .host, op: .contains, value: "a"))
        #expect(!current.isLegacy)
        #expect(ConditionRowDraft(row: ConditionRow(field: .clientApp, name: "pid", op: .equals, value: "1")).isLegacyField)
        #expect(!ConditionRowDraft(row: ConditionRow(field: .clientApp, op: .contains, value: "Safari:")).isLegacyField)
    }

    // MARK: dates

    @Test func aDateIsStoredAsYearMonthDayInTheLocalZone() throws {
        let shanghai = try #require(TimeZone(identifier: "Asia/Shanghai"))
        let losAngeles = try #require(TimeZone(identifier: "America/Los_Angeles"))
        var row = ConditionRowDraft(row: ConditionRow(field: .requestDate, op: .equals))
        // 2026-03-05 23:30 in Los Angeles is 2026-03-06 in Shanghai.
        let moment = try #require(ISO8601DateFormatter().date(from: "2026-03-06T07:30:00Z"))
        row.setDate(moment, timeZone: losAngeles)
        #expect(row.value == "2026-03-05")
        row.setDate(moment, timeZone: shanghai)
        #expect(row.value == "2026-03-06")
        // Back: the start of that local day, and the same day again.
        let back = try #require(row.date(timeZone: shanghai))
        #expect(ConditionDate.string(from: back, timeZone: shanghai) == "2026-03-06")
        #expect(back == ISO8601DateFormatter().date(from: "2026-03-05T16:00:00Z"))
        #expect(row.row.value == "2026-03-06")
    }

    @Test func onlyARealDayParsesAndItIsShownMonthDayYear() {
        #expect(ConditionDate.date(from: "2026-02-30") == nil)
        #expect(ConditionDate.date(from: "2026-2-3") == nil)
        #expect(ConditionDate.date(from: "03/05/2026") == nil)
        #expect(ConditionDate.date(from: "") == nil)
        #expect(ConditionDate.display("2026-03-05") == "03/05/2026")
        #expect(ConditionDate.display("nope") == nil)
        #expect(ConditionRowDraft(row: ConditionRow(field: .requestDate, op: .equals, value: "2026-03-05")).value == "2026-03-05")
    }

    // MARK: whole group

    @Test func executionLineSaysWhenTheEngineJudgesAndShowsItsDirection() {
        let request = ConditionGroupPresentation.executionLine(point: .request, localizer: zh)
        #expect(request.text == "会话将在请求阶段匹配。" && request.direction == .request)
        let connect = ConditionGroupPresentation.executionLine(point: .connect, localizer: zh)
        #expect(connect.text == "会话将在请求阶段匹配。" && connect.direction == .request)
        let response = ConditionGroupPresentation.executionLine(point: .response, localizer: zh)
        #expect(response.text == "会话将在响应阶段匹配。" && response.direction == .response)
        let completion = ConditionGroupPresentation.executionLine(point: .completion, localizer: zh)
        #expect(completion.text == "会话将在完成时匹配。" && completion.direction == .both)
        let either = ConditionGroupPresentation.eitherPhaseLine(localizer: zh)
        #expect(either.text == "会话可能在请求或响应阶段匹配。" && either.direction == .both)
    }

    @Test func theDraftsExecutionLineFollowsTheRowsDirectionsAndTheMode() {
        func line(_ mode: ConditionGroup.Mode, _ fields: [ConditionField]) -> ConditionExecutionLine {
            ConditionsDraft(group: ConditionGroup(mode: mode, rows: fields.map { ConditionRow(field: $0, op: .contains, value: "a") }))
                .executionLine(localizer: zh)
        }
        let request = ConditionExecutionLine(text: "会话将在请求阶段匹配。", direction: .request)
        let response = ConditionExecutionLine(text: "会话将在响应阶段匹配。", direction: .response)
        let either = ConditionExecutionLine(text: "会话可能在请求或响应阶段匹配。", direction: .both)
        #expect(line(.all, [.url]) == request)
        #expect(line(.all, [.appProtocol]) == response)
        for field in [ConditionField.responseHeader, .responseCookie, .statusCode, .responseBody, .responseBodySize, .durationMs, .remoteIP, .certificate, .upstreamHTTPVersion, .upstreamTLSVersion] {
            #expect(line(.all, [field]) == response)
        }
        for field in [ConditionField.sessionState, .cookie, .tlsVersion, .comment, .rulesModified, .magicString] {
            #expect(line(.all, [.url, field]) == either)
        }
        for mode in [ConditionGroup.Mode.all, .none] {
            #expect(line(mode, [.url, .statusCode]) == response)
        }
        #expect(line(.any, [.url, .statusCode]) == either)
        #expect(line(.any, [.statusCode, .responseBody]) == response)
        // Editing a field or the mode changes the line at once.
        var draft = ConditionsDraft(group: ConditionGroup(mode: .all, rows: [ConditionRow(field: .url, op: .contains, value: "a"), ConditionRow(field: .statusCode, op: .equals, value: "200")]))
        #expect(draft.executionLine(localizer: zh) == response)
        draft.mode = .any
        #expect(draft.executionLine(localizer: zh) == either)
    }

    @Test func theGroupCountLineIsRedAtZeroAndSecondaryOtherwise() throws {
        let none = try #require(ConditionGroupPresentation.matchCountLine(count: 0, localizer: zh))
        #expect(none.text == "当前标签页中有 0 个匹配" && none.tone == .failure && !none.showsViewLink)
        let some = try #require(ConditionGroupPresentation.matchCountLine(count: 12, localizer: zh))
        #expect(some.text == "当前标签页中有 12 个匹配" && some.tone == .secondary && some.showsViewLink)
        // An invalid group matches nothing; an unknown count has no line yet.
        let invalid = try #require(ConditionGroupPresentation.matchCountLine(count: nil, groupIsValid: false, localizer: zh))
        #expect(invalid.tone == .failure && invalid.count == 0)
        #expect(ConditionGroupPresentation.matchCountLine(count: nil, localizer: zh) == nil)
    }

    @Test func deleteIsDisabledForTheLastRow() {
        var draft = ConditionsDraft()
        draft.addRow()
        #expect(!draft.canRemoveRows)
        draft.addRow()
        #expect(draft.canRemoveRows)
        draft.removeRow(draft.rows[0].id)
        #expect(!draft.canRemoveRows)
    }

    @Test func deprecationCardNamesOneOrSeveralFields() {
        #expect(ConditionGroupPresentation.deprecationText(for: [], localizer: zh) == nil)
        #expect(ConditionGroupPresentation.deprecationText(for: [.cookie], localizer: zh) == "Cookie 条件即将弃用，请使用现有的替代条件。")
        #expect(
            ConditionGroupPresentation.deprecationText(for: [.sessionState, .sessionState], localizer: zh)
                == "会话状态 条件即将弃用，请使用现有的替代条件。")
        #expect(
            ConditionGroupPresentation.deprecationText(for: [.sessionState, .cookie], localizer: zh)
                == "会话状态和Cookie 条件即将弃用，请使用现有的替代条件。")
        #expect(
            ConditionGroupPresentation.deprecationText(for: [.sessionState, .cookie, .tlsVersion], localizer: zh)
                == "会话状态、Cookie和TLS 版本 条件即将弃用，请使用现有的替代条件。")
        let en = Localizer(bundle: L10n.bundle, preferredLanguages: ["en"])
        // Production English is bundled.
        #expect(ConditionGroupPresentation.deprecationText(for: [.cookie], localizer: en) != nil)
    }

    @Test func theDraftFindsItsDeprecatedFieldsInRowOrder() {
        let draft = ConditionsDraft(group: ConditionGroup(rows: [
            ConditionRow(field: .tlsVersion, op: .contains, value: "1.3"),
            ConditionRow(field: .url, op: .contains, value: "a"),
            ConditionRow(field: .cookie, op: .contains, value: "a"),
            ConditionRow(field: .tlsVersion, op: .contains, value: "1.2"),
        ]))
        #expect(draft.deprecatedFields == [.tlsVersion, .cookie])
        #expect(draft.deprecationText(localizer: zh) == "TLS 版本和Cookie 条件即将弃用，请使用现有的替代条件。")
        #expect(ConditionsDraft(group: ConditionGroup(rows: [ConditionRow(field: .url, op: .contains)])).deprecationText(localizer: zh) == nil)
    }

    // MARK: row summaries

    @Test func summariesCoverNewFieldsAndComparisons() {
        func summary(_ row: ConditionRow) -> String { ConditionPresentation.rowSummary(row, localizer: zh) }
        #expect(summary(ConditionRow(field: .requestHeader, name: "X-Test", op: .exists)) == "请求 Header（X-Test）存在")
        #expect(summary(ConditionRow(field: .responseHeader, op: .contains, value: "gzip")) == "响应 Header（任意 Header）包含 gzip")
        #expect(summary(ConditionRow(field: .requestCookie, op: .doesNotExist)) == "请求 Cookie（任意 Cookie）不存在")
        #expect(summary(ConditionRow(field: .cookie, name: "sid", op: .startsWith, value: "a")) == "Cookie（sid）开头是 a")
        #expect(summary(ConditionRow(field: .statusCode, op: .greaterOrEqual, value: "500")) == "状态码 大于或等于 500")
        #expect(summary(ConditionRow(field: .durationMs, op: .lessOrEqual, value: "1000")) == "耗时 小于或等于 1000")
        #expect(summary(ConditionRow(field: .url, op: .regex, value: "a.*")) == "URL 正则表达式 a.*")
        #expect(summary(ConditionRow(field: .scheme, op: .equals, value: "https")) == "协议方案 是 HTTPS")
        #expect(summary(ConditionRow(field: .appProtocol, op: .equals, value: "sse")) == "协议 是 Server-sent Events")
        #expect(summary(ConditionRow(field: .sessionState, op: .equals, value: "paused")) == "会话状态 是 已暂停")
        #expect(summary(ConditionRow(field: .clientApp, op: .contains, value: "Safari:")) == "进程 包含 Safari:")
        #expect(summary(ConditionRow(field: .magicString, op: .contains, value: "*bump")) == "魔法字符串 *bump")
        #expect(summary(ConditionRow(field: .allSessions, op: .equals)) == "所有会话")
        #expect(summary(ConditionRow(field: .requestDate, op: .afterOrEqual, value: "2026-03-05")) == "请求日期 晚于或等于 03/05/2026")
        #expect(summary(ConditionRow(field: .upstreamHTTPVersion, op: .equals, value: "HTTP/2")) == "远端 HTTP 版本 等于 HTTP/2")
    }

    @Test func certificateSummariesNameTheItem() {
        func summary(_ row: ConditionRow) -> String { ConditionPresentation.rowSummary(row, localizer: zh) }
        #expect(summary(ConditionRow(field: .certificate, name: "subjectCommonName", op: .contains, value: "example"))
            == "证书信息（使用者通用名称）包含 example")
        #expect(summary(ConditionRow(field: .certificate, name: "validity", op: .equals, value: "valid")) == "证书信息（有效性）有效")
        #expect(summary(ConditionRow(field: .certificate, name: "validity", op: .equals, value: "invalid")) == "证书信息（有效性）无效")
        #expect(summary(ConditionRow(field: .certificate, name: "expirationDate", op: .before, value: "2026-12-31"))
            == "证书信息（到期日期）早于 12/31/2026")
        #expect(summary(ConditionRow(field: .certificate, name: "version", op: .equals, value: "3")) == "证书信息（版本）等于 3")
        #expect(summary(ConditionRow(field: .certificate, name: "subject", op: .contains, value: "x")) == "证书信息（主题）包含 x")
    }

    // MARK: suggestions

    /// The time and size suggestions are the engine's own texts (rounding and the chunked rule included).
    @Test func timeAndSizeSuggestionsReuseTheEnginesFormatting() {
        let started = Date(timeIntervalSince1970: 1_791_000_000.4567)
        var flow = Flow(
            id: 1, scheme: "https", method: "POST", host: "a.com", port: 443, path: "/",
            requestHeaders: [HeaderField(name: "Content-Length", value: " 42 ")])
        flow.startedAt = started
        #expect(ConditionSuggestions.values(field: .requestTime, name: nil, in: [flow], limit: 5) == [ConditionFieldText.requestTime(started)])
        #expect(ConditionSuggestions.values(field: .requestBodySize, name: nil, in: [flow], limit: 5) == ["42"])
        flow.requestHeaders.append(HeaderField(name: "Transfer-Encoding", value: "chunked"))
        #expect(ConditionSuggestions.values(field: .requestBodySize, name: nil, in: [flow], limit: 5).isEmpty)
    }

    @Test func cookieSuggestionsReadTheCookieHeaders() {
        var flow = Flow(
            id: 1, scheme: "https", method: "GET", host: "a.com", port: 443, path: "/",
            requestHeaders: [HeaderField(name: "Cookie", value: "sid=1; theme=dark")])
        flow.responseHeaders = [HeaderField(name: "Set-Cookie", value: "token=abc; Path=/; HttpOnly")]
        #expect(ConditionSuggestions.values(field: .requestCookie, name: nil, in: [flow], limit: 10).sorted() == ["sid", "theme"])
        #expect(ConditionSuggestions.values(field: .responseCookie, name: nil, in: [flow], limit: 10) == ["token"])
        #expect(ConditionSuggestions.values(field: .cookie, name: nil, in: [flow], limit: 10).count == 3)
        #expect(ConditionSuggestions.values(field: .requestCookie, name: "SID", in: [flow], limit: 10) == ["1"])
        #expect(ConditionSuggestions.values(field: .responseCookie, name: "token", in: [flow], limit: 10) == ["abc"])
    }
}

/// The headed sections of the field list (R8F3-7).
@Suite(.productionChinese) struct ConditionFieldSectionTests {
    private let zh = Localizer(bundle: L10n.bundle, preferredLanguages: ["zh-Hans"])

    @Test func threeSectionsInOrderWithTheirMembers() {
        let sections = ConditionFieldCatalog.menuSections
        #expect(sections.map(\.kind) == [.request, .response, .other])
        #expect(sections[0].entries.map(\.field) == [
            .url, .host, .path, .scheme, .method, .requestHeader, .requestCookie, .requestBody, .requestBodySize,
            .clientHTTPVersion, .clientTLSVersion, .clientIP, .requestDate, .requestTime, .clientApp,
        ])
        #expect(sections[1].entries.map(\.field) == [
            .statusCode, .appProtocol, .responseHeader, .responseCookie, .responseBody, .responseBodySize,
            .upstreamHTTPVersion, .upstreamTLSVersion, .remoteIP, .durationMs, .certificate,
        ])
        #expect(sections[2].entries.map(\.field) == [.allSessions, .comment, .magicString, .sessionState, .tlsVersion, .cookie, .rulesModified])
    }

    @Test func everyMenuFieldAppearsExactlyOnceAndLegacyOnesNever() {
        let fields = ConditionFieldCatalog.menuSections.flatMap { $0.entries.map(\.field) }
        #expect(fields.count == Set(fields).count)
        #expect(Set(fields) == Set(ConditionFieldCatalog.menuFields))
        for legacy in [ConditionField.port, .queryString, .queryParam, .pathAndQuery] { #expect(!fields.contains(legacy)) }
    }

    @Test func entriesKeepDirectionAndDeprecation() {
        let entries = ConditionFieldCatalog.menuSections.flatMap(\.entries)
        for entry in entries { #expect(entry.direction == ConditionFieldCatalog.direction(of: entry.field), "\(entry.field)") }
        #expect(entries.filter(\.isDeprecated).map(\.field).sorted { "\($0)" < "\($1)" } == [.cookie, .sessionState, .tlsVersion].sorted { "\($0)" < "\($1)" })
        // Request and response sections hold only fields of their direction.
        #expect(ConditionFieldCatalog.menuSections[0].entries.allSatisfy { $0.direction == .request })
        #expect(ConditionFieldCatalog.menuSections[1].entries.allSatisfy { $0.direction == .response })
    }

    @Test func everyOtherEntryIsDirectionAgnosticExceptAllSessions() {
        let other = ConditionFieldCatalog.menuSections[2].entries
        for entry in other where entry.field != .allSessions { #expect(entry.direction == .both, "\(entry.field)") }
        #expect(other.first { $0.field == .allSessions }?.direction == .request)
    }

    @Test func everyRequestDirectionFieldReadsTheRequestPhaseAndSoDoTheLegacyOnlyOnes() {
        let requestFields = ConditionFieldCatalog.menuSections.flatMap(\.entries).filter { $0.direction == .request }.map(\.field)
        #expect(!requestFields.isEmpty)
        for field in requestFields + [.port, .queryString, .queryParam, .pathAndQuery] {
            #expect(ConditionGroupPresentation.phase(fields: [field], mode: .all) == .request, "\(field)")
        }
    }

    @Test func headersAreLocalized() {
        #expect(ConditionFieldCatalog.menuSections.map { $0.kind.title(localizer: zh) } == ["请求", "响应", "其他"])
    }
}
