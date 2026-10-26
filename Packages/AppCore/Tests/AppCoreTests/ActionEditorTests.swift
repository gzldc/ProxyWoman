import FlowStore
import Foundation
import RulesEngine
import Testing

@testable import AppCore
@testable import Localization

private func titles(_ items: [ActionModeItem]) -> [String] { items.map(\.title) }

private func descriptor(_ type: ActionType, _ configure: (inout ActionDraft) -> Void = { _ in }) -> ActionEditorDescriptor {
    var draft = ActionDraft(type: type)
    configure(&draft)
    return ActionEditorDescriptor(draft: draft)
}

private let sixModes = ["设置值", "查找并替换", "正则表达式", "若不存在则添加", "追加到值", "移除"]

// MARK: descriptor

@Suite(.productionChinese) struct ActionEditorDescriptorTests {
    @Test func headerCookieAndQueryCardsHaveAKeyAndTheSixModesInOrder() {
        for type in [ActionType.editRequestHeaders, .editResponseHeaders, .editRequestCookies, .editResponseCookies, .modifyQuery] {
            let d = descriptor(type)
            #expect(d.keyControl == .autocomplete(placeholder: "所有键"), "\(type)")
            #expect(d.showsKeyCase, "header, cookie and query names can be compared with or without case")
            #expect(titles(d.modes) == sixModes, "\(type)")
            #expect(d.modes.allSatisfy { !$0.isLegacy })
            #expect(d.selectedMode == "set")
            #expect(d.find == .none && !d.showsValueCase)
            #expect(d.value == .line(placeholder: "要设置的值"))
            #expect(d.languages.isEmpty && d.maxValueCharacters == nil)
        }
    }

    @Test func theCommentHasTheSixModesButNoKey() {
        let d = descriptor(.comment) { $0.comment.mode = .set }
        #expect(d.keyControl == .none)
        #expect(titles(d.modes) == sixModes)
        #expect(d.modes.map(\.id) == ["set", "findReplace", "regex", "addIfMissing", "append", "clear"])
        #expect(d.value == .line(placeholder: "要设置的值"))
        #expect(descriptor(.comment) { $0.comment.mode = .append }.value == .line(placeholder: "要追加的值"))
        #expect(descriptor(.comment) { $0.comment.mode = .clear }.value == .none)
    }

    @Test func findShowsForFindReplaceAndRegexAndTheValueSaysReplaceWith() {
        for type in [ActionType.editRequestHeaders, .editRequestCookies, .modifyQuery, .comment] {
            let replace = descriptor(type) { $0.setMode("findReplace") }
            #expect(replace.find == .singleLine(suggestions: true), "\(type)")
            #expect(replace.showsValueCase)
            #expect(replace.value == .line(placeholder: "替换为"))
            let regex = descriptor(type) { $0.setMode("regex") }
            #expect(regex.find == .multiLine, "\(type)")
            #expect(regex.showsValueCase)
            #expect(regex.value == .line(placeholder: "替换为"))
        }
    }

    @Test func removeHasNoValueAndAppendSaysAppend() {
        for type in [ActionType.editRequestHeaders, .editRequestCookies, .modifyQuery] {
            let remove = descriptor(type) { $0.setMode("remove") }
            #expect(remove.value == .none && remove.find == .none && remove.showsKey, "\(type)")
            #expect(descriptor(type) { $0.setMode("appendToValue") }.value == .line(placeholder: "要追加的值"))
            #expect(descriptor(type) { $0.setMode("addIfMissing") }.value == .line(placeholder: "要设置的值"))
        }
    }

    @Test func aSavedOldStyleMethodIsListedLastAndMarked() {
        let header = descriptor(.editRequestHeaders) { $0.setMode("append") }
        #expect(header.modes.count == 7 && header.modes[6].isLegacy && header.modes[6].title == "添加字段（旧式）")
        #expect(header.selectedMode == "append")
        let query = descriptor(.modifyQuery) { $0.setMode("add") }
        #expect(query.modes.count == 7 && query.modes[6].isLegacy && query.modes[6].title == "添加参数（旧式）")
        // A card that does not carry it does not offer it.
        #expect(descriptor(.editRequestHeaders).modes.count == 6)
    }

    @Test func bodyHasFourModesAndTheBigEditorForSetAndReplace() {
        for type in [ActionType.rewriteRequestBody, .rewriteResponseBody] {
            #expect(titles(descriptor(type).modes) == ["设置值", "查找并替换", "正则表达式", "移除"])
            #expect(descriptor(type).keyControl == .none)
            let set = descriptor(type) { $0.body.mode = .setValue }
            #expect(set.value == .bigEditor && set.find == .none && !set.showsValueCase)
            #expect(set.languages.map(\.title) == ["纯文本", "JSON", "CSS", "XML", "HTML", "JavaScript/TypeScript"])
            #expect(set.selectedLanguage == "plaintext")
            let replace = descriptor(type) { $0.body.mode = .findReplace }
            #expect(replace.value == .bigEditor && replace.find == .multiLine && replace.showsValueCase)
            let regex = descriptor(type) { $0.body.mode = .regex }
            #expect(regex.value == .line(placeholder: "替换为") && regex.find == .multiLine)
            #expect(regex.languages.isEmpty)
            let remove = descriptor(type) { $0.body.mode = .remove }
            #expect(remove.value == .none && remove.find == .none)
        }
    }

    @Test func theLanguageIsStoredInTheActionAndNothingElseChanges() {
        var draft = ActionDraft(type: .rewriteResponseBody)
        draft.body.mode = .setValue
        draft.body.replacement = "{}"
        let plain = draft.build().action
        draft.setEditorLanguage("json")
        #expect(ActionEditorDescriptor(draft: draft).selectedLanguage == "json")
        guard case .rewriteBody(_, let rewrite)? = draft.build().action?.kind else {
            Issue.record("expected a body rewrite")
            return
        }
        #expect(rewrite.editorLanguage == "json" && rewrite.replacement == "{}" && rewrite.operation == .setValue)
        draft.setEditorLanguage("plaintext")
        #expect(draft.build().action == plain, "plain text stores nothing")
        // A stored JavaScript reads as the JavaScript/TypeScript entry.
        draft.body.editorLanguage = "javascript"
        #expect(ActionEditorDescriptor(draft: draft).selectedLanguage == "typescript")
    }

    @Test func urlHasFourModes() {
        #expect(titles(descriptor(.modifyURL).modes) == ["设置值", "查找并替换", "正则表达式", "追加到值"])
        #expect(descriptor(.modifyURL).keyControl == .none)
        #expect(descriptor(.modifyURL).value == .line(placeholder: "要设置的值"))
        #expect(descriptor(.modifyURL) { $0.url.mode = .append }.value == .line(placeholder: "要追加的值"))
        let replace = descriptor(.modifyURL) { $0.url.mode = .findReplace }
        #expect(replace.find == .singleLine(suggestions: true) && replace.showsValueCase)
        #expect(descriptor(.modifyURL) { $0.url.mode = .regex }.find == .multiLine)
    }

    @Test func statusDelayAndTheRestOfTheSimpleTypes() {
        let status = descriptor(.rewriteStatus)
        #expect(status.value == .line(placeholder: "设置状态码和原因短语") && status.maxValueCharacters == 200)
        #expect(status.modes.isEmpty && !status.showsKey && !status.showsIncludeLocalResponses)
        #expect(descriptor(.rewriteStatus) { $0.status.includeLocalResponses = true }.showsIncludeLocalResponses)
        #expect(descriptor(.delay).value == .line(placeholder: "毫秒"))
        for type in [
            ActionType.requestBreakpoint, .responseBreakpoint, .returnConnectTunnel, .hide, .noDecrypt, .closeConnectionGraceful,
            .closeConnectionReset,
        ] {
            let d = descriptor(type)
            #expect(d.modes.isEmpty && d.value == .none && d.find == .none && !d.showsKey && d.legacyNoteKey == nil, "\(type)")
        }
        #expect(descriptor(.magicString).value == .multiLine)
    }

    @Test func anOldBreakpointWithAFullBodyPauseSaysSo() {
        #expect(descriptor(.requestBreakpoint) { $0.breakpointMode = .fullBody }.legacyNoteKey == "rules.action.legacy.fullBody")
        #expect(descriptor(.responseBreakpoint) { $0.breakpointMode = .headers }.legacyNoteKey == nil)
    }

    @Test func eachTypeHasAHintAndOldStyleInputsOnlyWhenTheyCarryThem() {
        for type in ActionType.allCases {
            let d = descriptor(type)
            #expect(!d.hint.isEmpty && d.hint != type.hintKey, "\(type)")
            #expect(!d.hint.contains("Fiddler") && !d.hint.contains("Telerik"))
        }
        #expect(!descriptor(.rewriteRequestBody).showsBodyScope)
        #expect(descriptor(.rewriteRequestBody) { $0.body.scope = .first }.showsBodyScope)
        #expect(!descriptor(.modifyURL).showsURLPreserveCredentials)
        #expect(descriptor(.modifyURL) { $0.url.preserveCredentials = true }.showsURLPreserveCredentials)
    }

    @Test func theHintsAreTheReferenceRewrittenInChinese() {
        let text = L10n.string(ActionType.magicString.hintKey)
        #expect(text == "用于兼容旧版自动响应器规则，新规则不应使用")
    }
}

// MARK: predefined responses and mark colours

@Suite(.productionChinese) struct PredefinedResponseCatalogTests {
    @Test func theFourteenEntriesAreGroupedByTheirFirstCharacter() {
        let groups = PredefinedResponseCatalog.groups()
        #expect(groups.map { $0.map(\.title) } == [
            ["200 OK（HTML）", "200 OK（GIF 图片）", "200 OK（像素）", "204 No Content"],
            ["302 重定向", "303 重定向（改用 GET）", "304 Not Modified", "307 重定向（保持方法）"],
            ["401 Basic 认证", "401 摘要认证", "403 拒绝访问", "404 Not Found", "407 需要代理认证"],
            ["502 无法访问服务器"],
        ])
        #expect(groups.flatMap { $0.map(\.preset) } == PredefinedResponseCatalog.presets)
        #expect(groups.joined().allSatisfy { !$0.isLegacy })
        #expect(Set(PredefinedResponseCatalog.presets).count == 14)
    }

    @Test func theOlderPresetsAreAppendedAsOldStyleOnlyWhenACardHoldsOne() {
        for preset in [PresetResponse.Preset.movedPermanently301, .permanentRedirect308, .badRequest400, .tooManyRequests429, .internalError500, .serviceUnavailable503] {
            #expect(PredefinedResponseCatalog.isLegacy(preset))
            let groups = PredefinedResponseCatalog.groups(including: preset)
            #expect(groups.count == 5 && groups[4].count == 1 && groups[4][0].isLegacy && groups[4][0].preset == preset)
            #expect(groups[4][0].title.hasSuffix("（旧式）"), "\(preset)")
        }
        #expect(PredefinedResponseCatalog.groups(including: .notFound404).count == 4)
        #expect(PredefinedResponseCatalog.groups(including: nil).count == 4)
    }

    @Test func redirectsGetALocationInputWithTheDefaultAddress() {
        var draft = ActionDraft(type: .returnPreset)
        #expect(!ActionEditorDescriptor(draft: draft).showsPresetLocation)
        draft.preset = .temporaryRedirect307
        let d = ActionEditorDescriptor(draft: draft)
        #expect(d.showsPresetLocation && d.presetGroups.count == 4)
        #expect(PredefinedResponseCatalog.defaultLocation == "http://www.example.com/" && draft.presetLocation == "http://www.example.com/")
        #expect(
            draft.build().action
                == RuleAction(.returnPreset(PresetResponse(preset: .temporaryRedirect307, location: "http://www.example.com/"))))
        // A challenge or body shows only for an old preset that has one.
        #expect(!d.showsPresetChallenge && !d.showsPresetBody)
        draft.preset = .unauthorized401
        draft.presetChallenge = "Basic realm=x"
        draft.presetBody = "no"
        let old = ActionEditorDescriptor(draft: draft)
        #expect(old.showsPresetChallenge && old.showsPresetBody && !old.showsPresetLocation)
    }

    @Test func everyListedPresetBuilds() {
        for preset in PredefinedResponseCatalog.presets {
            var draft = ActionDraft(type: .returnPreset)
            draft.preset = preset
            let built = draft.build()
            #expect(built.issues.isEmpty && built.action != nil, "\(preset)")
        }
    }
}

@Suite(.productionChinese) struct MarkColorCatalogTests {
    @Test func theTwentyEightColoursAreInTheReferenceOrderWithTheirValues() {
        let expected: [(String, String)] = [
            ("yellowTransparent", "#FFEC1A4D"), ("fuchsiaTransparent", "#FF19FF4D"), ("redTransparent", "#F985904D"),
            ("oliveTransparent", "#A7C7054D"), ("purpleTransparent", "#9F80FF4D"), ("maroonTransparent", "#C982824D"),
            ("aquaTransparent", "#55E9F64D"), ("limeTransparent", "#86F9864D"), ("greenTransparent", "#2F9E2F33"),
            ("tealTransparent", "#40BFAA4D"), ("blueTransparent", "#478CD133"), ("navyTransparent", "#00158033"),
            ("yellow", "#FFEC1AFF"), ("fuchsia", "#FF19FFFF"), ("red", "#DB3B4BFF"), ("olive", "#808000FF"),
            ("purple", "#800080FF"), ("maroon", "#800000FF"), ("aqua", "#03FFFFFF"), ("lime", "#03FF00FF"),
            ("green", "#008000FF"), ("teal", "#008080FF"), ("blue", "#336CDCFF"), ("navy", "#0404ABFF"),
            ("white", "#FFFFFFFF"), ("silverTransparent", "#99999960"), ("grayTransparent", "#999999C0"), ("black", "#000000FF"),
        ]
        #expect(MarkColorCatalog.entries.map(\.id) == expected.map(\.0))
        #expect(MarkColorCatalog.entries.map(\.rgba) == expected.map(\.1))
        #expect(Set(MarkColorCatalog.entries.map(\.titleKey)).count == 28)
        #expect(MarkColorCatalog.entries.allSatisfy { FlowMark.normalizedHex($0.stored) == $0.stored })
        #expect(MarkColorCatalog.entry(id: "yellowTransparent")?.opacity == 77.0 / 255)
        #expect(MarkColorCatalog.entry(id: "black")?.opacity == 1)
    }

    @Test func theDropdownListsUnchangedAndDefaultFirst() {
        let choices = MarkColorCatalog.choices()
        #expect(choices.count == 30 && choices[0] == .unchanged && choices[1] == .themeDefault)
        #expect(choices[2] == .entry("yellowTransparent") && choices[29] == .entry("black"))
        let titles = choices.map { MarkColorCatalog.title(of: $0) }
        #expect(Array(titles.prefix(3)) == ["不变", "默认", "半透明黄"] && titles.last == "黑")
        #expect(MarkColorCatalog.choices(including: .custom("#123456")).last == .custom("#123456"))
    }

    @Test func storedColoursReadBackAsTheirChoice() {
        #expect(MarkColorCatalog.choice(forStored: nil) == .unchanged && MarkColorCatalog.choice(forStored: "") == .unchanged)
        #expect(MarkColorCatalog.choice(forStored: "default") == .themeDefault)
        #expect(MarkColorCatalog.choice(forStored: "#db3b4b") == .entry("red"))
        #expect(MarkColorCatalog.choice(forStored: "#FF3B30") == .custom("#FF3B30"))
        // A solid and a translucent entry of one colour store different text (the entry's exact 8 digits), so a reload shows
        // the entry that was picked; an older 6-digit rule reads as the first entry of that colour.
        #expect(MarkColorCatalog.stored(for: .entry("yellow")) == "#FFEC1AFF")
        #expect(MarkColorCatalog.stored(for: .entry("yellowTransparent")) == "#FFEC1A4D")
        #expect(MarkColorCatalog.choice(forStored: "#FFEC1A") == .entry("yellowTransparent"))
        #expect(MarkColorCatalog.choice(forStored: "#ffec1aff") == .entry("yellow"))
        #expect(MarkColorCatalog.choice(forStored: "#99999960") == .entry("silverTransparent"))
        #expect(MarkColorCatalog.choice(forStored: "#999999C0") == .entry("grayTransparent"))
        #expect(MarkColorCatalog.choice(forStored: "#FF19FFFF") == .entry("fuchsia"))
        for choice in MarkColorCatalog.choices() {
            #expect(MarkColorCatalog.choice(forStored: MarkColorCatalog.stored(for: choice)) == choice || choice == .themeDefault || choice == .unchanged)
        }
        // Every entry survives a round trip through what a rule stores, and no two entries store the same text.
        for entry in MarkColorCatalog.entries {
            #expect(MarkColorCatalog.choice(forStored: entry.stored) == .entry(entry.id), "\(entry.id)")
        }
        #expect(Set(MarkColorCatalog.entries.map(\.stored)).count == 28)
    }

    @Test func aMarkDraftKeepsThePickedEntryWithinTheSession() {
        var mark = MarkDraft()
        #expect(mark.background == "" && mark.foreground == nil)
        mark.setBackground(.entry("yellow"))
        #expect(mark.background == "#FFEC1AFF" && mark.backgroundChoice == .entry("yellow"))
        mark.setForeground(.entry("white"))
        #expect(mark.foreground == "#FFFFFFFF" && mark.foregroundChoice == .entry("white"))
        mark.setForeground(.themeDefault)
        #expect(mark.foreground == "default" && mark.foregroundChoice == .themeDefault)
        mark.setForeground(.unchanged)
        #expect(mark.foreground == nil)
        mark.setBackground(.unchanged)
        #expect(mark.background == "" && mark.backgroundChoice == .unchanged)
        // The stored text alone decides after a reload.
        #expect(MarkDraft(background: "#FFEC1A").backgroundChoice == .entry("yellowTransparent"))
        #expect(MarkDraft(background: "#FFEC1AFF").backgroundChoice == .entry("yellow"))
        // A reload shows the entry the user picked, solid or not.
        for entry in MarkColorCatalog.entries {
            var picked = MarkDraft()
            picked.setBackground(.entry(entry.id))
            #expect(MarkDraft(background: picked.background).backgroundChoice == .entry(entry.id), "\(entry.id)")
        }
    }

    @Test func markCardsBuildTheStoredColourChoices() {
        var draft = ActionDraft(type: .mark)
        #expect(draft.build().action == RuleAction(.mark(MarkAction(background: ""))))
        draft.mark.setBackground(.entry("red"))
        draft.mark.setForeground(.entry("white"))
        #expect(draft.build().action == RuleAction(.mark(MarkAction(background: "#DB3B4BFF", foreground: "#FFFFFFFF"))))
        draft.mark.setBackground(.themeDefault)
        #expect(draft.build().action == RuleAction(.mark(MarkAction(background: "default", foreground: "#FFFFFFFF"))))
        // A text colour with no background of its own has nothing to sit on.
        let alone = draft.build()
        #expect(alone.warnings == [.markTextColorNeedsBackground])
        draft.mark.setBackground(.entry("blue"))
        #expect(draft.build().warnings.isEmpty)
        // The label of an old rule shows only while it holds text.
        #expect(!ActionEditorDescriptor(draft: draft).showsMarkText)
        draft.mark.text = "old"
        let d = ActionEditorDescriptor(draft: draft)
        #expect(d.showsMarkText && d.backgroundChoices.count == 30)
        // An older rule's own colour is added to its dropdown.
        draft.mark = MarkDraft(background: "#FF3B30")
        #expect(ActionEditorDescriptor(draft: draft).backgroundChoices.last == .custom("#FF3B30"))
    }
}

// MARK: status, magic string

@Suite(.productionChinese) struct ActionStatusAndMagicStringTests {
    private func status(_ text: String) -> ActionBuildResult {
        var draft = ActionDraft(type: .rewriteStatus)
        draft.status.status = text
        return draft.build()
    }

    @Test func theOneStatusFieldTakesACodeAndAnOptionalPhrase() {
        #expect(status("404").action == RuleAction(.rewriteStatus(RewriteStatusAction(status: 404))))
        #expect(status("404 Not Found").action == RuleAction(.rewriteStatus(RewriteStatusAction(status: 404, reason: "Not Found"))))
        #expect(status("  503   Try later ").action == RuleAction(.rewriteStatus(RewriteStatusAction(status: 503, reason: "Try later"))))
        #expect(status("").issues[.status] == .required)
        #expect(status("abc").issues[.status] == .notANumber)
        #expect(status("199").issues[.status] == .invalidStatus)
        #expect(status("404Not").issues[.status] == .invalidStatus)
        #expect(status("404 " + String(repeating: "x", count: 200)).issues[.status] == .invalidStatus)
        #expect(status("404 " + String(repeating: "x", count: 196)).action != nil)
    }

    @Test func aSavedReasonOpensInTheFieldAndKeepsTheLocalSwitch() {
        let stored = RuleAction(.rewriteStatus(RewriteStatusAction(status: 418, includeLocalResponses: true, reason: "Teapot")))
        let draft = ActionDraft(action: stored)
        #expect(draft.status.status == "418 Teapot" && draft.status.includeLocalResponses)
        #expect(draft.buildForm(limits: RulesLimits()).action == stored)
        #expect(draft.build().action == stored)
    }

    @Test func aLocalFileMagicStringOffersReturnFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("t8-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("page.html")
        try Data("<p>x</p>".utf8).write(to: file)

        var draft = ActionDraft(type: .magicString)
        draft.magicText = file.path
        #expect(draft.build().issues[.magicString] == .magicStringLocalFile)
        #expect(draft.magicStringFileURL()?.path == file.path)
        #expect(ActionEditorDescriptor(draft: draft).offersReturnFile)
        // A path that is no file, a folder, and the other strings do not.
        draft.magicText = file.path + ".missing"
        #expect(draft.build().issues[.magicString] == .magicStringLocalFile)
        #expect(draft.magicStringFileURL() == nil && !ActionEditorDescriptor(draft: draft).offersReturnFile)
        draft.magicText = directory.path
        #expect(draft.magicStringFileURL() == nil)
        draft.magicText = "*delay:5"
        #expect(draft.build().issues.isEmpty && draft.magicStringFileURL() == nil)
        draft.magicText = "*nonsense"
        #expect(draft.build().issues[.magicString] == .invalidMagicString)
        draft.magicText = ""
        #expect(draft.build().issues[.magicString] == .required)
    }

    @Test func aMagicStringThatStandsForAFinalActionLocksTheTick() {
        var draft = ActionDraft(type: .magicString)
        draft.magicText = "*drop"
        #expect(RuleBuilderPresentation.stopProcessing(for: draft) == .init(isOn: true, isLocked: true, reasonKey: "rules.builder.stop.lockedReason"))
        draft.magicText = "*delay:5"
        #expect(!RuleBuilderPresentation.stopProcessing(for: draft).isLocked)
        #expect(RuleBuilderPresentation.stopProcessingHintKey(for: draft) == "rules.builder.stop.help")
        draft.magicText = "*exit"
        #expect(RuleBuilderPresentation.stopProcessing(for: draft).isLocked)
    }

    @Test func theStopHintsSayWhatTheTickDoes() {
        let final = L10n.string(RuleBuilderPresentation.stopProcessingHintKey(for: ActionDraft(type: .hide)))
        let ordinary = L10n.string(RuleBuilderPresentation.stopProcessingHintKey(for: ActionDraft(type: .modifyURL)))
        #expect(final == "这是终止动作：在它之后的动作和优先级更低的规则都不会再执行。")
        #expect(ordinary == "勾选后，此动作成为终止动作：在它之后的动作和优先级更低的规则都不会再执行。")
    }
}

// MARK: lossless round trips

@Suite(.productionChinese) struct ActionRoundTripTests {
    private static let asset = UUID()

    /// One action for every kind, every mode of every edit, and the legacy shapes.
    static let actions: [RuleAction] = {
        var result: [ActionKind] = [
            .returnFile(MapLocalAction(assetID: asset, status: 201, headers: [HeaderField(name: "X-A", value: "1")])),
            .returnDirectory(
                MapLocalDirectoryAction(bookmark: Data([1, 2]), displayName: "d", servesIndex: true, missing: .network, headers: []),
                pathPrefix: "/a/"),
            .mapRemote(MapRemoteAction(targetScheme: "http", targetHost: "b.test", targetPort: 8080, path: .replace("/x"), preserveCredentials: true)),
            .breakpoint(direction: .request, mode: .headers), .breakpoint(direction: .response, mode: .fullBody),
            .rewriteStatus(RewriteStatusAction(status: 404)),
            .rewriteStatus(RewriteStatusAction(status: 404, includeLocalResponses: true, reason: "Not Found")),
            .mark(MarkAction(background: "#FF3B30", foreground: "#FFFFFF", text: "label")),
            .mark(MarkAction(background: "")), .mark(MarkAction(background: "default", foreground: "default")),
            .mark(MarkAction(background: "#DB3B4B", foreground: nil)),
            .hide, .delay(milliseconds: 250), .returnHandwritten(HandwrittenResponse(text: "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n")),
            .closeConnection(.graceful), .closeConnection(.reset), .returnConnectTunnel, .noDecrypt,
            .magicString("*delay:5"), .magicString("*drop"),
        ]
        // Bodies: every mode, both directions, with and without a language.
        for direction in [HTTPMessageDirection.request, .response] {
            result += [
                .rewriteBody(direction: direction, BodyRewriteAction(find: "", replacement: "{}", operation: .setValue)),
                .rewriteBody(direction: direction, BodyRewriteAction(find: "", replacement: "{}", operation: .setValue, editorLanguage: "json")),
                .rewriteBody(direction: direction, BodyRewriteAction(find: "a", replacement: "b", caseSensitive: false, editorLanguage: "html")),
                .rewriteBody(direction: direction, BodyRewriteAction(find: "a+", replacement: "$0", syntax: .regex, caseSensitive: true, scope: .first)),
                .rewriteBody(direction: direction, BodyRewriteAction(find: "", replacement: "", operation: .clear)),
            ]
        }
        // URL.
        for mode in URLEditAction.Mode.allCases {
            let find = mode == .findReplace || mode == .regex ? "a" : ""
            result.append(.modifyURL(URLEditAction(mode: mode, find: find, replacement: "https://b.test/", caseSensitive: mode == .regex, preserveCredentials: mode == .set)))
        }
        // Query, header and cookie: every edit, with a name and with every name.
        for name in ["k", ""] {
            result += [
                .modifyQuery(QueryEditAction(operations: [.set(name: name, value: "v")])),
                .modifyQuery(QueryEditAction(operations: [.remove(name: name)])),
                .modifyQuery(QueryEditAction(operations: [.appendToValue(name: name, text: "t")])),
                .modifyQuery(QueryEditAction(operations: [.findReplace(name: name.isEmpty ? nil : name, find: "a", replacement: "b", caseSensitive: true)])),
                .modifyQuery(QueryEditAction(operations: [.regex(name: name.isEmpty ? nil : name, pattern: "a(.)", replacement: "$1", caseSensitive: false)])),
            ]
            for direction in [HTTPMessageDirection.request, .response] {
                result += [
                    .editHeaders(direction: direction, operations: [.set(name: name, value: "v")]),
                    .editHeaders(direction: direction, operations: [.append(name: "k", value: "v")]),
                    .editHeaders(direction: direction, operations: [.remove(name: name)]),
                    .editHeaders(direction: direction, operations: [.appendToValue(name: name, text: "t")]),
                    .editHeaders(direction: direction, operations: [.findReplace(name: name, find: "a", replacement: "b", caseSensitive: true)]),
                    .editHeaders(direction: direction, operations: [.regex(name: name, pattern: "a(.)", replacement: "$1", caseSensitive: false)]),
                    .editCookies(direction: direction, operations: [.set(name: name, value: "v")]),
                    .editCookies(direction: direction, operations: [.remove(name: name)]),
                    .editCookies(direction: direction, operations: [.appendToValue(name: name, text: "t")]),
                    .editCookies(direction: direction, operations: [.findReplace(name: name.isEmpty ? nil : name, find: "a", replacement: "b", caseSensitive: true)]),
                    .editCookies(direction: direction, operations: [.regex(name: name.isEmpty ? nil : name, pattern: "a(.)", replacement: "$1", caseSensitive: false)]),
                ]
            }
        }
        result += [
            .modifyQuery(QueryEditAction(operations: [.add(name: "k", value: "v")])),
            .modifyQuery(QueryEditAction(operations: [.addIfMissing(name: "k", value: "v")])),
            .editHeaders(direction: .request, operations: [.addIfMissing(name: "X-K", value: "v")]),
            .editCookies(direction: .response, operations: [.addIfMissing(name: "k", value: "v")]),
        ]
        // Comment: every mode, both case flags.
        for caseSensitive in [true, false] {
            result += [
                .comment(CommentAction(mode: .findReplace, text: "a", replacement: "b", caseSensitive: caseSensitive)),
                .comment(CommentAction(mode: .regex, text: "a(.)", replacement: "$1", caseSensitive: caseSensitive)),
            ]
        }
        result += [
            .comment(CommentAction(mode: .set, text: "t")), .comment(CommentAction(mode: .append, text: "t")),
            .comment(CommentAction(mode: .addIfMissing, text: "t")), .comment(CommentAction(mode: .clear)),
        ]
        // Presets: every one, redirects with their address, the 401 with a challenge.
        for preset in PresetResponse.Preset.allCases {
            let shape = PresetResponse(preset: preset)
            result.append(.returnPreset(PresetResponse(preset: preset, location: shape.requiresLocation ? "http://b.test/" : nil)))
        }
        result.append(.returnPreset(PresetResponse(preset: .unauthorized401, body: "no", challenge: "Basic realm=\"x\"")))
        return result.map { RuleAction($0) } + [
            RuleAction(.modifyURL(URLEditAction(mode: .append, replacement: "?x=1")), isFinal: true),
            RuleAction(.editHeaders(direction: .response, operations: [.remove(name: "Server")]), isFinal: true),
        ]
    }()

    @Test func theListCoversEveryKindAndMode() {
        let types = Set(Self.actions.compactMap { ActionType($0.kind) })
        #expect(types == Set(ActionType.allCases))
        let presets = Set(Self.actions.compactMap { action -> PresetResponse.Preset? in
            if case .returnPreset(let preset) = action.kind { return preset.preset }
            return nil
        })
        #expect(presets == Set(PresetResponse.Preset.allCases))
    }

    @Test func openingEveryActionAndSavingGivesTheSameAction() {
        for action in Self.actions {
            let draft = ActionDraft(action: action)
            let result = draft.build()
            #expect(result.issues.isEmpty, "\(action.kind): \(result.issues)")
            #expect(result.action == action, "\(action.kind)")
        }
    }

    @Test func theFormAloneBuildsTheSameActionToo() {
        // Without the stored action to fall back on: the form shows everything these actions hold.
        for action in Self.actions {
            let result = ActionDraft(action: action).buildForm(limits: RulesLimits())
            #expect(result.issues.isEmpty, "\(action.kind): \(result.issues)")
            #expect(result.action == action, "\(action.kind)")
        }
    }

    @Test func aFormThatCannotShowAnActionExactlyStillHandsItBackUntouched() {
        // A name stored as an empty text where the form writes "no name"; and a text-mode comment that kept a flag.
        let odd: [RuleAction] = [
            RuleAction(.modifyQuery(QueryEditAction(operations: [.findReplace(name: "", find: "a", replacement: "b", caseSensitive: true)]))),
            RuleAction(.editCookies(direction: .request, operations: [.regex(name: "", pattern: "a", replacement: "b", caseSensitive: false)])),
            RuleAction(.comment(CommentAction(mode: .set, text: "t", caseSensitive: false))),
        ]
        for action in odd {
            var draft = ActionDraft(action: action)
            #expect(draft.buildForm(limits: RulesLimits()).action != action, "\(action.kind) is not canonical")
            #expect(draft.build().action == action, "\(action.kind)")
            // The stop tick is still the user's to change.
            draft.isFinal = true
            #expect(draft.build().action == RuleAction(action.kind, isFinal: true))
        }
    }

    @Test func anEditedCardWritesWhatTheFormSays() {
        var draft = ActionDraft(action: RuleAction(.modifyQuery(QueryEditAction(operations: [.findReplace(name: "", find: "a", replacement: "b", caseSensitive: true)]))))
        draft.queryRows[0].replacement = "c"
        #expect(draft.build().action == RuleAction(.modifyQuery(QueryEditAction(operations: [.findReplace(name: nil, find: "a", replacement: "c", caseSensitive: true)]))))
        // Back to what it was: the stored action again.
        draft.queryRows[0].replacement = "b"
        #expect(draft.build().action == RuleAction(.modifyQuery(QueryEditAction(operations: [.findReplace(name: "", find: "a", replacement: "b", caseSensitive: true)]))))
    }

    @Test func changingTheTypeAndBackIsNotAnEdit() {
        var draft = ActionDraft(action: RuleAction(.editHeaders(direction: .request, operations: [.set(name: "A", value: "1")])))
        let before = draft.build().action
        draft.setType(.editResponseHeaders)
        #expect(draft.build().action == RuleAction(.editHeaders(direction: .response, operations: [.set(name: "A", value: "1")])))
        draft.setType(.editRequestHeaders)
        #expect(draft.build().action == before)
    }

    @Test func aLegacyBodyFlagIsKept() {
        let stored = RuleAction(.rewriteBody(direction: .request, BodyRewriteAction(find: "a", replacement: "b", scope: .first)))
        let draft = ActionDraft(action: stored)
        #expect(draft.body.scope == .first && ActionEditorDescriptor(draft: draft).showsBodyScope)
        #expect(draft.build().action == stored)
    }
}

// MARK: one edit per card (R8F2-9)

@Suite(.productionChinese) struct ActionSplitTests {
    private let header = RuleAction(
        .editHeaders(direction: .request, operations: [.set(name: "A", value: "1"), .remove(name: "B"), .appendToValue(name: "C", text: "x")]),
        isFinal: true)
    private let mark = RuleAction(.mark(MarkAction(background: "#FF0000")))

    private func rule(_ actions: [RuleAction]) -> Rule {
        Rule(
            name: "r", conditions: ConditionGroup(rows: [ConditionRow(field: .method, op: .equals, value: "GET")]),
            actions: actions)
    }

    private func saved(_ document: RuleDocument) -> [RuleAction]? {
        document.validate(limits: RulesLimits()).rule?.actions
    }

    @Test func aMultiEditActionOpensAsOneCardPerEditInOrder() {
        let document = RuleDocument(rule: rule([mark, header]))
        #expect(document.actions.map(\.type) == [.mark] + Array(repeating: .editRequestHeaders, count: 3))
        let cards = Array(document.actions.dropFirst())
        #expect(cards.allSatisfy { $0.headerRows.count == 1 })
        #expect(cards.map { $0.headerRows[0].method } == [.set, .remove, .appendToValue])
        #expect(cards.map { $0.headerRows[0].name } == ["A", "B", "C"])
        // The tick belongs to the last: the whole action stopped after its last edit.
        #expect(cards.map(\.isFinal) == [false, false, true])
        #expect(Set(document.actions.map(\.id)).count == 4)
    }

    @Test func queryAndCookieActionsSplitToo() {
        let query = RuleAction(.modifyQuery(QueryEditAction(operations: [.set(name: "a", value: "1"), .remove(name: "b")])))
        let cookies = RuleAction(.editCookies(direction: .response, operations: [.set(name: "a", value: "1"), .remove(name: "b")]))
        let document = RuleDocument(rule: rule([query, cookies]))
        #expect(document.actions.map(\.type) == [.modifyQuery, .modifyQuery, .editResponseCookies, .editResponseCookies])
        #expect(document.actions.allSatisfy { $0.queryRows.count == 1 && $0.cookieRows.count == 1 })
        #expect(saved(document) == [query, cookies])
    }

    @Test func aSingleEditActionIsOneCard() {
        for action in ActionRoundTripTests.actions {
            #expect(ActionDraft.cards(for: action).count == 1, "\(action.kind)")
        }
        #expect(ActionDraft.cards(for: header).count == 3)
    }

    @Test func openingAndSavingWithoutChangesGivesTheRuleAsItWas() {
        let original = rule([mark, header, RuleAction(.hide)])
        let document = RuleDocument(rule: original)
        let validation = document.validate(limits: RulesLimits())
        #expect(validation.issues.isEmpty)
        #expect(validation.rule?.actions == original.actions)
        #expect(validation.rule == original)
    }

    @Test func anEditedCardSavesEveryEditAsItsOwnAction() throws {
        var document = RuleDocument(rule: rule([mark, header]))
        document.actions[2].headerRows[0].name = "Z"
        let actions = try #require(saved(document))
        #expect(actions == [
            mark,
            RuleAction(.editHeaders(direction: .request, operations: [.set(name: "A", value: "1")])),
            RuleAction(.editHeaders(direction: .request, operations: [.remove(name: "Z")])),
            RuleAction(.editHeaders(direction: .request, operations: [.appendToValue(name: "C", text: "x")]), isFinal: true),
        ])
    }

    @Test func movingDeletingAndTickingBreakTheGroup() throws {
        let singles: [RuleAction] = [
            RuleAction(.editHeaders(direction: .request, operations: [.set(name: "A", value: "1")])),
            RuleAction(.editHeaders(direction: .request, operations: [.remove(name: "B")])),
            RuleAction(.editHeaders(direction: .request, operations: [.appendToValue(name: "C", text: "x")]), isFinal: true),
        ]
        var moved = RuleDocument(rule: rule([header]))
        moved.moveAction(moved.actions[2].id, by: -1)
        // The tick travels with the card it was on.
        #expect(try #require(saved(moved)) == [singles[0], singles[2], singles[1]])

        var deleted = RuleDocument(rule: rule([header]))
        deleted.removeAction(deleted.actions[1].id)
        #expect(try #require(saved(deleted)) == [singles[0], singles[2]])

        var unticked = RuleDocument(rule: rule([header]))
        unticked.actions[2].isFinal = false
        #expect(try #require(saved(unticked)) == singles.map { $0.withFinal(false) })

        var duplicated = RuleDocument(rule: rule([header]))
        duplicated.duplicateAction(duplicated.actions[0].id)
        #expect(duplicated.actions.count == 4)
        #expect(try #require(saved(duplicated)).count == 4)
    }

    @Test func aGroupSeparatedByAnotherCardIsNotMergedBack() throws {
        var document = RuleDocument(rule: rule([header]))
        document.actions.insert(ActionDraft(type: .mark), at: 1)
        let actions = try #require(saved(document))
        #expect(actions.count == 4 && actions[1] == RuleAction(.mark(MarkAction(background: ""))))
    }

    @Test func twoGroupsMergeBackIndependently() {
        let second = RuleAction(.editHeaders(direction: .response, operations: [.set(name: "R", value: "1"), .remove(name: "S")]))
        let original = rule([header, mark, second])
        #expect(saved(RuleDocument(rule: original)) == original.actions)
    }

    @Test func anEngineErrorLandsOnTheCardItBelongsTo() throws {
        // The merged action is one action of the rule; a card index is not an action index.
        var document = RuleDocument(rule: rule([mark, header, RuleAction(.hide)]))
        document.actions[0].setType(.noDecrypt)  // not available at the request point: flagged on that card
        let validation = document.validate(limits: RulesLimits())
        #expect(validation.rule == nil)
        #expect(validation.issues[.action(document.actions[0].id, .type)] != nil)
    }

    @Test func deletingIsOffWhileOneCardIsLeft() {
        var document = RuleDocument(rule: rule([mark, RuleAction(.hide)]))
        #expect(document.canRemoveAction && RuleBuilderPresentation.canDeleteAction(cardCount: 2))
        document.removeAction(document.actions[0].id)
        #expect(!document.canRemoveAction && !RuleBuilderPresentation.canDeleteAction(cardCount: 1))
        document.removeAction(document.actions[0].id)
        #expect(document.actions.count == 1)
    }
}

private extension RuleAction {
    func withFinal(_ isFinal: Bool) -> RuleAction { RuleAction(kind, isFinal: isFinal) }
}

// MARK: warnings

@Suite(.productionChinese) struct ActionNoticeTests {
    private func document(_ cards: [ActionDraft], field: ConditionField = .method) -> RuleDocument {
        var document = RuleDocument(newIn: nil)
        document.conditions.addRow()
        document.conditions.rows[0].setField(field)
        document.actions = cards
        return document
    }

    private func card(_ type: ActionType, _ configure: (inout ActionDraft) -> Void = { _ in }) -> ActionDraft {
        var draft = ActionDraft(type: type)
        configure(&draft)
        return draft
    }

    @Test func warning1ReadsTheRecordedRequestWording() {
        let doc = document([card(.modifyURL), card(.editResponseHeaders), card(.requestBreakpoint)], field: .statusCode)
        let analysis = doc.cardAnalysis()
        #expect(analysis.notices[0].map(\.textKey) == ["rules.card.requestVisibleOnly"])
        #expect(analysis.notices[1].isEmpty)
        #expect(analysis.notices[2].map(\.textKey) == ["rules.card.requestSkippedAtResponse"])
        #expect(analysis.notices.joined().allSatisfy { !$0.isError })
        #expect(analysis.banner == .warnings)
        #expect(L10n.string("rules.card.requestSkippedAtResponse") == "规则在响应阶段匹配，此请求动作不会执行。")
    }

    @Test func warning3AFinalActionAndTheErrorBanner() {
        let doc = document([card(.editResponseHeaders), card(.editRequestHeaders)])
        #expect(doc.cardAnalysis().notices[1].map(\.warning) == [.requestActionAfterResponseAction])
        #expect(doc.cardAnalysis().banner == .warnings)
        let ended = document([card(.hide), card(.mark)])
        let analysis = ended.cardAnalysis()
        #expect(analysis.notices[1].map(\.warning) == [.afterFinalAction] && analysis.notices[1][0].isError)
        #expect(analysis.states == [.final, .unreachable])
        #expect(analysis.banner == .errors)
    }

    @Test func warning4NoDecryptConditionsAndItsPrecedenceOverWarning1() {
        // Not a connect-time condition: warning 4. At the response stage warning 1 would also apply and is left out.
        let atRequest = document([card(.noDecrypt)]).cardAnalysis()
        #expect(atRequest.notices[0].map(\.warning) == [.noDecryptNeedsSimpleConditions])
        let atResponse = document([card(.noDecrypt)], field: .statusCode).cardAnalysis()
        #expect(atResponse.notices[0].map(\.warning) == [.noDecryptNeedsSimpleConditions])
        #expect(atResponse.states == [.blocked(.needsConnectPointConditions)])
        // With conditions it can work on there is no warning.
        let fine = document([card(.noDecrypt)], field: .host).cardAnalysis()
        #expect(fine.notices[0].isEmpty)
    }

    @Test func warning5OnlyOneManualResponse() {
        let doc = document([card(.returnHandwritten), card(.returnHandwritten)])
        let analysis = doc.cardAnalysis()
        #expect(analysis.notices[0].isEmpty)
        // The first one also ends the rule, so the second is flagged for that as well.
        #expect(analysis.notices[1].map(\.warning) == [.multipleManualResponses, .afterFinalAction])
    }

    @Test func aCleanRuleHasNoBannerAndTheNoticesComeWithTheValidation() throws {
        let clean = document([card(.mark), card(.editRequestHeaders)])
        #expect(clean.cardAnalysis().banner == nil)
        #expect(clean.validate(limits: RulesLimits()).banner == nil && clean.validate(limits: RulesLimits()).notices.isEmpty)
        let doc = document([card(.hide), card(.mark)])
        let validation = doc.validate(limits: RulesLimits())
        #expect(validation.banner == .errors)
        #expect(validation.notices[doc.actions[1].id]?.map(\.textKey) == ["rules.card.afterFinal"])
        #expect(validation.cardStates[doc.actions[1].id] == .unreachable)
    }

    @Test func aCardThatCannotBeBuiltYetStillTakesPartInTheChecks() {
        // The first card has no value yet; the hide after it is still judged against the cards before.
        let doc = document([card(.rewriteStatus), card(.hide), card(.mark)])
        let analysis = doc.cardAnalysis()
        #expect(analysis.states == [.active, .final, .unreachable])
        // And a magic string that does not read keeps its place.
        let odd = document([card(.magicString) { $0.magicText = "*nonsense" }, card(.mark)])
        #expect(odd.cardAnalysis().states == [.active, .active])
    }

    @Test func everyWarningHasASentenceAndTheBannerTextsAreTheSpecifiedOnes() {
        for warning in ActionExecutionWarning.allCases {
            let key = ActionCardAnalysis.textKey(warning, resolved: .hide)
            #expect(L10n.string(key) != key, "\(warning)")
        }
        #expect(L10n.string(ActionBanner.warnings.textKey) == "部分动作不会（按预期）执行，请查看各动作的提示。")
        #expect(L10n.string(ActionBanner.errors.textKey) == "部分动作不会执行，请查看各动作的提示。")
        #expect(L10n.string("rules.notice.noDecryptConditions").contains("所有会话"))
    }

    @Test func noWordOfTheNewTextsNamesTheReferenceProduct() {
        let keys = [
            "rules.card.requestVisibleOnly", "rules.card.requestSkippedAtResponse", "rules.notice.matchPointUncertain",
            "rules.notice.requestAfterResponse", "rules.notice.noDecryptConditions", "rules.notice.multipleManualResponses",
            "rules.banner.actionsErrors", "rules.banner.actionsWarnings", "rules.card.afterFinal", "rules.issue.magicStringLocalFile",
        ]
        for key in keys {
            let text = L10n.string(key)
            #expect(!text.contains("Fiddler") && !text.contains("Telerik"), "\(key)")
        }
    }
}
