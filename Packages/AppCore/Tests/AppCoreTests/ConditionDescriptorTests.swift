import Foundation
import Localization
import RulesEngine
import Testing

@testable import AppCore

/// One test per row of the field table (spec 12.3) and per certificate sub-item (12.4).
@Suite(.productionChinese) struct ConditionDescriptorTests {
    private let zh = Localizer(bundle: L10n.bundle, preferredLanguages: ["zh-Hans"])

    private func descriptor(
        _ field: ConditionField, name: String? = nil, op: ConditionOperator? = nil, value: String = ""
    ) -> ConditionRowDescriptor {
        ConditionRowDescriptor(field: field, name: name, op: op, value: value, localizer: zh)
    }

    private func titles(_ control: ConditionOperatorControl) -> [[String]] {
        guard case .menu(let groups) = control else { return [] }
        return groups.map { $0.map(\.title) }
    }

    private let textSet = [["等于", "不等于"], ["包含", "不包含"], ["开头是", "结尾是"], ["为空", "不为空"], ["正则表达式"]]
    private let keyValueSet = [
        ["等于", "不等于"], ["包含", "不包含"], ["开头是", "结尾是"], ["为空", "不为空"], ["存在", "不存在"], ["正则表达式"],
    ]
    private let numberSet = [
        ["等于", "不等于"], ["大于或等于", "大于"], ["小于或等于", "小于"], ["为空", "不为空"], ["正则表达式"],
    ]
    private let dateSet = [["等于", "不等于"], ["晚于或等于", "晚于"], ["早于或等于", "早于"], ["为空", "不为空"]]

    // MARK: rows of the table

    @Test func allSessionsHasNoComparisonKeyOrValue() {
        let d = descriptor(.allSessions)
        #expect(d.operatorControl == .none)
        #expect(d.defaultOperator == nil)
        #expect(d.keyControl == .none)
        #expect(d.valueControl == .none)
        #expect(!d.showsValue && !d.showsValueCase)
        #expect(d.placeholder == nil)
    }

    @Test func urlTakesTheTextSetSuggestionsAndTheCaseSwitch() {
        let d = descriptor(.url)
        #expect(titles(d.operatorControl) == textSet)
        #expect(d.defaultOperator == .contains)
        #expect(d.valueControl == .text(suggestions: true))
        #expect(d.showsValueCase)
        #expect(d.placeholder == "http://www.example.com/")
        #expect(d.keyControl == .none)
    }

    @Test func suggestionsAreOffForARegularExpression() {
        #expect(descriptor(.url, op: .regex).valueControl == .text(suggestions: false))
        #expect(descriptor(.host, op: .regex).valueControl == .text(suggestions: false))
        #expect(descriptor(.url, op: .contains).valueControl == .text(suggestions: true))
    }

    @Test func hostPathMethodAreTextWithSuggestions() {
        for field in [ConditionField.host, .path, .method] {
            let d = descriptor(field)
            #expect(titles(d.operatorControl) == textSet, "\(field)")
            #expect(d.defaultOperator == .contains)
            #expect(d.valueControl == .text(suggestions: true))
            #expect(d.showsValueCase)
            #expect(d.placeholder == "值")
        }
    }

    @Test func schemeIsFixedIsWithHTTPSBeforeHTTP() {
        let d = descriptor(.scheme)
        #expect(d.operatorControl == .fixed("是"))
        guard case .dropdown(let options) = d.valueControl else { Issue.record("dropdown"); return }
        #expect(options.map(\.value) == ["https", "http"])
        #expect(options.map(\.title) == ["HTTPS", "HTTP"])
        #expect(!d.showsValueCase)
        #expect(d.placeholder == nil)
    }

    @Test func protocolIsFixedIsWithAGroupedDropdown() {
        let d = descriptor(.appProtocol)
        #expect(d.operatorControl == .fixed("是"))
        guard case .groupedDropdown(let groups) = d.valueControl else { Issue.record("grouped"); return }
        #expect(groups.map { $0.map(\.title) } == [["HTTP"], ["WebSocket", "RPC", "gRPC", "Server-sent Events", "Socket.IO"]])
        #expect(groups.flatMap { $0 }.map(\.value) == ["http", "websocket", "rpc", "grpc", "sse", "socketio"])
        #expect(!d.showsValueCase)
    }

    @Test func statusCodeTakesTheNumberSetWithoutTheCaseSwitch() {
        let d = descriptor(.statusCode)
        #expect(titles(d.operatorControl) == numberSet)
        #expect(d.defaultOperator == .equals)
        #expect(d.valueControl == .text(suggestions: true))
        #expect(!d.showsValueCase)
        #expect(d.placeholder == "值")
    }

    @Test func sessionStateIsFixedIsWithThreeStatesAndAnOldValueKeptAsOldStyle() {
        let d = descriptor(.sessionState)
        #expect(d.operatorControl == .fixed("是"))
        guard case .dropdown(let options) = d.valueControl else { Issue.record("dropdown"); return }
        #expect(options.map(\.title) == ["已打开", "已关闭", "已暂停"])
        #expect(options.allSatisfy { !$0.isLegacy })
        guard case .dropdown(let withOld) = descriptor(.sessionState, value: "completed").valueControl else { Issue.record("dropdown"); return }
        #expect(withOld.map(\.value) == ["opened", "closed", "paused", "completed"])
        #expect(withOld.last?.isLegacy == true)
        #expect(ConditionFieldCatalog.isDeprecated(.sessionState))
    }

    @Test func httpVersionsAreTextWithSuggestionsAndTheCaseSwitch() {
        for field in [ConditionField.clientHTTPVersion, .upstreamHTTPVersion] {
            let d = descriptor(field)
            #expect(titles(d.operatorControl) == textSet)
            #expect(d.valueControl == .text(suggestions: true))
            #expect(d.showsValueCase)
            #expect(d.placeholder == "值")
        }
    }

    @Test func bodiesAreTextWithoutSuggestions() {
        for field in [ConditionField.requestBody, .responseBody] {
            let d = descriptor(field)
            #expect(titles(d.operatorControl) == textSet)
            #expect(d.defaultOperator == .contains)
            #expect(d.valueControl == .text(suggestions: false))
            #expect(d.showsValueCase)
        }
    }

    @Test func headersTakeTheKeyValueSetAndAnAnyHeaderKey() {
        for field in [ConditionField.requestHeader, .responseHeader] {
            let d = descriptor(field)
            #expect(titles(d.operatorControl) == keyValueSet)
            #expect(d.defaultOperator == .contains)
            #expect(d.keyControl == .autocomplete(placeholder: "任意 Header", showsCase: true))
            #expect(d.showsKeyCase)
            #expect(d.valueControl == .text(suggestions: true))
            #expect(d.showsValueCase)
            #expect(d.placeholder == "Header 值")
        }
    }

    @Test func cookiesTakeTheKeyValueSetAndAnAnyCookieKey() {
        for field in [ConditionField.requestCookie, .responseCookie, .cookie] {
            let d = descriptor(field)
            #expect(titles(d.operatorControl) == keyValueSet)
            #expect(d.keyControl == .autocomplete(placeholder: "任意 Cookie", showsCase: true))
            #expect(d.valueControl == .text(suggestions: true))
            #expect(d.showsValueCase)
            #expect(d.placeholder == "值")
        }
    }

    @Test func sizesAndDurationTakeTheNumberSet() {
        for field in [ConditionField.requestBodySize, .responseBodySize, .durationMs] {
            let d = descriptor(field)
            #expect(titles(d.operatorControl) == numberSet)
            #expect(d.defaultOperator == .equals)
            #expect(d.valueControl == .text(suggestions: true))
            #expect(!d.showsValueCase)
        }
    }

    @Test func requestDateTakesTheDateSetAndADatePicker() {
        let d = descriptor(.requestDate)
        #expect(titles(d.operatorControl) == dateSet)
        #expect(d.defaultOperator == .equals)
        #expect(d.valueControl == .date)
        #expect(!d.showsValueCase)
        #expect(d.placeholder == "MM/DD/YYYY")
    }

    @Test func requestTimeIsTextWithSuggestionsAndNoCaseSwitch() {
        let d = descriptor(.requestTime)
        #expect(titles(d.operatorControl) == textSet)
        #expect(d.valueControl == .text(suggestions: true))
        #expect(!d.showsValueCase)
    }

    @Test func ipAddressesAreTextWithSuggestionsAndNoCaseSwitch() {
        for field in [ConditionField.clientIP, .remoteIP] {
            let d = descriptor(field)
            #expect(titles(d.operatorControl) == textSet)
            #expect(d.valueControl == .text(suggestions: true))
            #expect(!d.showsValueCase)
        }
    }

    @Test func tlsVersionsDifferInTheCaseSwitch() {
        for field in [ConditionField.clientTLSVersion, .upstreamTLSVersion] {
            let d = descriptor(field)
            #expect(titles(d.operatorControl) == textSet)
            #expect(d.showsValueCase)
        }
        let both = descriptor(.tlsVersion)
        #expect(titles(both.operatorControl) == textSet)
        #expect(both.valueControl == .text(suggestions: true))
        #expect(!both.showsValueCase)
        #expect(ConditionFieldCatalog.isDeprecated(.tlsVersion))
    }

    @Test func processIsTextWithSuggestionsAndTheCaseSwitchAndNoKey() {
        let d = descriptor(.clientApp)
        #expect(titles(d.operatorControl) == textSet)
        #expect(d.keyControl == .none)
        #expect(d.valueControl == .text(suggestions: true))
        #expect(d.showsValueCase)
        #expect(!d.isLegacyField)
    }

    @Test func commentIsTextWithSuggestionsAndTheCaseSwitch() {
        let d = descriptor(.comment)
        #expect(titles(d.operatorControl) == textSet)
        #expect(d.valueControl == .text(suggestions: true))
        #expect(d.showsValueCase)
    }

    @Test func rulesModifiedIsFixedIsWithYesAndNo() {
        let d = descriptor(.rulesModified)
        #expect(d.operatorControl == .fixed("是"))
        guard case .dropdown(let options) = d.valueControl else { Issue.record("dropdown"); return }
        #expect(options.map(\.title) == ["是", "否"])
        #expect(options.map(\.value) == ["true", "false"])
    }

    @Test func magicStringHasNoComparisonAndAPlainTextValue() {
        let d = descriptor(.magicString)
        #expect(d.operatorControl == .none)
        #expect(d.defaultOperator == .contains)
        #expect(d.valueControl == .text(suggestions: false))
        #expect(!d.showsValueCase)
        #expect(d.placeholder == "值")
    }

    @Test func comparisonsWithoutAValueHideTheValueBoxAndTheCaseSwitch() {
        for op in [ConditionOperator.isEmpty, .isNotEmpty] {
            let d = descriptor(.host, op: op)
            #expect(!d.showsValue && !d.showsValueCase && d.placeholder == nil)
        }
        for op in [ConditionOperator.exists, .doesNotExist] {
            let d = descriptor(.requestHeader, op: op)
            #expect(!d.showsValue && !d.showsValueCase)
            #expect(d.keyControl != .none)
        }
        #expect(descriptor(.requestDate, op: .isEmpty).valueControl == .none)
    }

    @Test func aComparisonOutsideTheCurrentSetIsAddedAsOldStyle() {
        let d = descriptor(.host, op: .hostPattern, value: "*.a.com")
        let items = d.operatorControl.items
        #expect(items.last?.op == .hostPattern && items.last?.isLegacy == true)
        #expect(items.dropLast().allSatisfy { !$0.isLegacy })
        #expect(titles(descriptor(.host, op: .contains).operatorControl) == textSet)
        // A saved "not equals" on a fixed-is field is kept next to "is".
        let kept = descriptor(.appProtocol, op: .notEquals, value: "websocket").operatorControl.items
        #expect(kept.map(\.op) == [.equals, .notEquals] && kept.last?.isLegacy == true)
    }

    @Test func legacyFieldsStayDisplayable() {
        let port = descriptor(.port)
        #expect(port.isLegacyField)
        #expect(titles(port.operatorControl) == numberSet)
        #expect(descriptor(.queryParam, name: "a").keyControl == .text(placeholder: "名称"))
        let app = descriptor(.clientApp, name: "pid")
        #expect(app.isLegacyField)
        #expect(titles(app.operatorControl) == numberSet)
        guard case .choices(let names) = app.keyControl else { Issue.record("choices"); return }
        #expect(names.map(\.title) == ["应用名称", "可执行文件路径", "进程号"])
        #expect(!descriptor(.queryString).operatorControl.items.isEmpty)
    }

    // MARK: certificate

    @Test func certificateKeyIsAGroupedDropdownInTheSpecOrder() {
        let d = descriptor(.certificate, name: "friendlyName")
        guard case .certificate(let groups, let legacy) = d.keyControl else { Issue.record("certificate"); return }
        #expect(legacy == nil)
        #expect(groups.map(\.count) == [3, 3, 4, 3, 4])
        #expect(groups.map { $0.map(\.title) } == [
            ["友好名称", "版本", "序列号"],
            ["到期日期", "有效性", "签发日期"],
            ["签名", "公钥", "SHA1 指纹", "SHA256 指纹"],
            ["颁发者通用名称", "颁发者国家/地区", "颁发者组织"],
            ["使用者通用名称", "使用者备用名称", "使用者国家/地区", "使用者组织"],
        ])
        #expect(groups.flatMap { $0 }.map(\.value) == CertificateField.allCases.map(\.rawValue))
    }

    @Test func certificateFriendlyNameIsTextWithContainsAndNoSuggestions() {
        for name in [nil, "", "friendlyName"] as [String?] {
            let d = descriptor(.certificate, name: name)
            #expect(titles(d.operatorControl) == textSet)
            #expect(d.defaultOperator == .contains)
            #expect(d.valueControl == .text(suggestions: false))
            #expect(d.showsValueCase)
            #expect(d.placeholder == "值")
        }
    }

    @Test func certificateValidityOffersValidAndInvalidWithNoValue() {
        let d = descriptor(.certificate, name: "validity")
        #expect(titles(d.operatorControl) == [["有效", "无效"]])
        #expect(d.defaultOperator == .equals)
        #expect(d.operatorControl.items.map(\.value) == ["valid", "invalid"])
        #expect(d.valueControl == .none)
        #expect(!d.showsValue && !d.showsValueCase)
        // The encoding sits behind one function.
        let valid = CertificateValidity.encode(valid: true)
        let invalid = CertificateValidity.encode(valid: false)
        #expect(valid.op == .equals && valid.value == "valid")
        #expect(invalid.op == .equals && invalid.value == "invalid")
        #expect(CertificateValidity.decode(op: .equals, value: "valid") == true)
        #expect(CertificateValidity.decode(op: .equals, value: "INVALID") == false)
        #expect(CertificateValidity.decode(op: .equals, value: "maybe") == nil)
        #expect(CertificateValidity.decode(op: .contains, value: "valid") == nil)
        #expect(ConditionFieldCatalog.operatorGroups(field: .certificate, name: "validity") == [[.equals]])
    }

    @Test func certificateVersionTakesTheNumberSet() {
        let d = descriptor(.certificate, name: "version")
        #expect(titles(d.operatorControl) == numberSet)
        #expect(d.defaultOperator == .equals)
        #expect(d.valueControl == .text(suggestions: false))
        #expect(!d.showsValueCase)
    }

    @Test func certificateDatesTakeTheDateSetAndADatePicker() {
        for name in ["expirationDate", "issueDate"] {
            let d = descriptor(.certificate, name: name)
            #expect(titles(d.operatorControl) == dateSet, "\(name)")
            #expect(d.defaultOperator == .equals)
            #expect(d.valueControl == .date)
            #expect(!d.showsValueCase)
            #expect(d.placeholder == "MM/DD/YYYY")
        }
    }

    @Test func everyOtherCertificateItemIsText() {
        let others = CertificateField.allCases.filter { $0.valueKind == .text }
        #expect(others.count == 13)
        for item in others {
            let d = descriptor(.certificate, name: item.rawValue)
            #expect(titles(d.operatorControl) == textSet, "\(item.rawValue)")
            #expect(d.valueControl == .text(suggestions: false))
            #expect(d.showsValueCase)
        }
    }

    @Test func anOldCertificateKeyIsListedAsOldStyleAndKeepsTheTextSet() {
        let d = descriptor(.certificate, name: "subject")
        #expect(d.isLegacyField)
        guard case .certificate(_, let legacy) = d.keyControl else { Issue.record("certificate"); return }
        #expect(legacy?.value == "subject" && legacy?.isLegacy == true)
        #expect(titles(d.operatorControl) == textSet)
        #expect(!descriptor(.certificate, name: "sha256Fingerprint").isLegacyField)
        #expect(!descriptor(.certificate, name: "serialNumber").isLegacyField)
    }
}
