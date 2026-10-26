import Foundation
import RulesEngine
import Testing

@testable import AppCore

@Suite(.productionChinese) struct RuleKindTests {
    @Test func everyKindHasTitleIconAndLocalizationKey() {
        for kind in RuleKind.allCases {
            #expect(kind.localizationKey == "rules.kind." + kind.rawValue)
            #expect(!kind.title.isEmpty && kind.title != kind.localizationKey, "\(kind)")
            #expect(!kind.systemImage.isEmpty, "\(kind)")
        }
        #expect(RuleKind.rewriteBody.systemImage == "text.magnifyingglass")
        #expect(RuleKind.rewriteStatus.systemImage == "number.circle")
    }

    @Test func newKindsAppendedAfterBreakpointKeepingOrder() {
        #expect(RuleKind.allCases.prefix(7) == [.mapLocal, .mapLocalDirectory, .mapRemote, .editHeaders, .breakpoint, .rewriteBody, .rewriteStatus])
        #expect(RuleKind.allCases.map(\.rawValue).dropLast(3).suffix(2) == ["rewriteBody", "rewriteStatus"])
    }

    @Test func directionFlags() {
        #expect(RuleKind.rewriteBody.hasDirection)
        #expect(!RuleKind.rewriteStatus.hasDirection)
        #expect(RuleKind.editHeaders.hasDirection && RuleKind.breakpoint.hasDirection)
        #expect(!RuleKind.mapLocal.hasDirection && !RuleKind.mapRemote.hasDirection && !RuleKind.mapLocalDirectory.hasDirection)
    }

    @Test func allCasesEndWithTheThreeAnnotationKinds() {
        #expect(RuleKind.allCases.count == 10)
        #expect(Array(RuleKind.allCases.suffix(3)) == [.mark, .comment, .hide])
        #expect(RuleKind.mark.systemImage == "paintpalette" && RuleKind.comment.systemImage == "text.bubble")
        #expect(RuleKind.hide.systemImage == "eye.slash")
    }

    @Test func annotationKindsHaveNoDirection() {
        for kind in [RuleKind.mark, .comment, .hide] { #expect(!kind.hasDirection) }
    }

    @Test func kindOfAnAnnotationRule() {
        func rule(_ kind: ActionKind) -> Rule {
            Rule(id: UUID(), name: "r", enabled: true, order: 0, matcher: RuleMatcher(hostPattern: "a.test"), annotation: kind)
        }
        #expect(RuleKind(rule(.mark(MarkAction(background: "#FF3B30")))) == .mark)
        #expect(RuleKind(rule(.comment(CommentAction(text: "x")))) == .comment)
        #expect(RuleKind(rule(.hide)) == .hide)
        #expect(RuleKind(ActionKind.hide) == .hide)
        #expect(RuleKind(ActionKind.mark(MarkAction(background: "#FF3B30"))) == .mark)
        #expect(RuleKind(ActionKind.comment(CommentAction())) == .comment)
    }
}
