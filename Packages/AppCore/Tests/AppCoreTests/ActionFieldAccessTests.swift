import Foundation
import RulesEngine
import Testing

@testable import AppCore

@Suite(.productionChinese) struct ActionFieldAccessTests {
    @Test func theKeyBoxWritesTheFirstEditOfATableCard() {
        for type in [ActionType.editRequestHeaders, .editResponseCookies, .modifyQuery] {
            var card = ActionDraft(type: type)
            card.keyText = "X-Test"
            #expect(card.keyText == "X-Test", "\(type)")
        }
        var url = ActionDraft(type: .modifyURL)
        url.keyText = "ignored"
        #expect(url.keyText == "")
    }

    @Test func theValueBoxIsTheReplacementOnlyWhileTheFindBoxShows() {
        var card = ActionDraft(type: .editRequestHeaders)
        card.valueText = "a"
        #expect(card.headerRows[0].value == "a" && !card.usesFindBox)
        card.setMode("findReplace")
        #expect(card.usesFindBox)
        card.findText = "needle"
        card.valueText = "hay"
        #expect(card.headerRows[0].value == "needle" && card.headerRows[0].replacement == "hay")
        #expect(card.findText == "needle" && card.valueText == "hay")
        card.setMode("remove")
        #expect(!card.usesFindBox)
    }

    @Test func urlBodyAndCommentCardsMapTheirBoxes() {
        var url = ActionDraft(type: .modifyURL)
        url.setMode("findReplace")
        url.findText = "f"
        url.valueText = "r"
        url.matchCase = true
        #expect(url.url.find == "f" && url.url.replacement == "r" && url.url.caseSensitive)

        var body = ActionDraft(type: .rewriteResponseBody)
        body.setMode("regex")
        body.findText = "a+"
        body.valueText = "b"
        #expect(body.body.find == "a+" && body.body.replacement == "b" && body.usesFindBox)
        body.setMode("setValue")
        #expect(!body.usesFindBox && body.valueText == "b")

        var comment = ActionDraft(type: .comment)
        comment.setMode("set")
        comment.valueText = "note"
        #expect(comment.comment.text == "note")
        comment.setMode("findReplace")
        comment.findText = "x"
        comment.valueText = "y"
        #expect(comment.comment.text == "x" && comment.comment.replacement == "y")
    }

    @Test func statusDelayAndMagicStringBindTheirOnlyBox() {
        var status = ActionDraft(type: .rewriteStatus)
        status.valueText = "404 Not Found"
        #expect(status.status.status == "404 Not Found")
        var delay = ActionDraft(type: .delay)
        delay.valueText = "250"
        #expect(delay.delayText == "250")
        var magic = ActionDraft(type: .magicString)
        magic.valueText = "*drop"
        #expect(magic.magicText == "*drop")
    }

    @Test func editFieldsNameTheInputsErrorsBelongTo() {
        let header = ActionDraft(type: .editRequestHeaders)
        let row = ActionField.headerRow(header.headerRows[0].id)
        #expect(header.editFields.key == row && header.editFields.value == row && header.editFields.list == .headerRow(header.id))
        #expect(ActionDraft(type: .modifyURL).editFields.find == .urlFind)
        #expect(ActionDraft(type: .rewriteStatus).editFields.value == .status)
        #expect(ActionDraft(type: .hide).editFields.value == nil)
    }
}

@Suite(.productionChinese) struct ActionFieldClampTests {
    @Test func theStatusBoxKeepsAtMostTheLongestText() {
        var status = ActionDraft(type: .rewriteStatus)
        let limit = RewriteStatusAction.maxTextCharacters
        status.valueText = String(repeating: "x", count: limit + 40)
        #expect(status.status.status.count == limit)
        #expect(status.valueText.count == limit)
        status.valueText = "404"
        #expect(status.valueText == "404")
    }

    @Test func keyCaseFlipsEveryEditOfTheCardAndIgnoresOtherTypes() {
        for type in [ActionType.editRequestHeaders, .editResponseCookies, .modifyQuery] {
            var card = ActionDraft(type: type)
            card.setKeyCase(true)
            #expect(card.keyCaseOn == true, "\(type)")
            card.setKeyCase(false)
            #expect(card.keyCaseOn == false, "\(type)")
        }
        var url = ActionDraft(type: .modifyURL)
        url.setKeyCase(true)
        #expect(url.keyCaseOn == nil)
    }

    @Test func theKeyBoxIsAskedForWithoutADescriptor() {
        #expect(ActionEditorDescriptor.hasKey(.editRequestHeaders))
        #expect(ActionEditorDescriptor.hasKey(.modifyQuery))
        #expect(!ActionEditorDescriptor.hasKey(.modifyURL))
        #expect(!ActionEditorDescriptor.hasKey(.mark))
    }

    @Test func aMarkColourPaintsWithItsOwnOpacity() {
        #expect(MarkColorCatalog.opacity(of: .entry("yellow")) == 1)
        let transparent = MarkColorCatalog.opacity(of: .entry("yellowTransparent"))
        #expect(transparent > 0.29 && transparent < 0.31)
        #expect(MarkColorCatalog.opacity(of: .entry("grayTransparent")) > 0.7)
        #expect(MarkColorCatalog.opacity(of: .custom("#112233")) == 1)
        #expect(MarkColorCatalog.opacity(of: .custom("#11223380")) == 128.0 / 255)
        #expect(MarkColorCatalog.opacity(of: .unchanged) == 1)
    }

    @Test func theLiveReportBuildsEveryCardOnce() {
        var document = RuleDocument(startingIn: nil)
        document.addAction(.hide)
        let report = document.liveCardReport()
        #expect(report.analysis.states.count == document.actions.count)
        #expect(report.buildWarnings.count == document.actions.count)
    }
}
