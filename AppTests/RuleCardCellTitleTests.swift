import AppKit
import Testing
@testable import ProxyWoman

/// A group's title is editable in place, and an editable NSTextField has no intrinsic width: without its own width the
/// row's stack collapsed it to nothing, so group names were invisible in the rules list.
@MainActor @Suite(.productionChinese) struct RuleCardCellTitleTests {
    private func content(title: String, isGroup: Bool) -> RuleCardContent {
        RuleCardContent(
            depth: 0, isGroup: isGroup, hasChildren: isGroup, title: title, summary: "4 / 28 enabled", help: nil,
            isEnabled: true, canToggle: true, isExpanded: true, canRun: true, canEditTitle: isGroup, canShowMenu: true,
            toggleLabel: "", runLabel: "", moreLabel: "", collapseLabel: "", expandLabel: "", hitsAccessibility: nil,
            warning: nil)
    }

    private final class Delegate: NSObject, NSTextFieldDelegate {}

    private func laidOut(_ content: RuleCardContent, width: CGFloat) -> RuleCardCell {
        let cell = RuleCardCell(frame: NSRect(x: 0, y: 0, width: width, height: 30))
        let delegate = Delegate()
        cell.show(content, target: delegate, delegate: delegate, actions: (#selector(NSObject.copy), #selector(NSObject.copy), #selector(NSObject.copy), #selector(NSObject.copy)))
        cell.layoutSubtreeIfNeeded()
        return cell
    }

    @Test(arguments: [true, false])
    func titleGetsTheRoomItsTextNeeds(isGroup: Bool) {
        let name = "Allow and Block Lists"
        let cell = laidOut(content(title: name, isGroup: isGroup), width: 900)
        let needed = cell.titleField.attributedStringValue.size().width
        #expect(cell.titleField.frame.width >= needed.rounded(.down))
    }

    /// The outline makes its cells before the inspector has a width, then widens them.
    @Test func aCellMadeNarrowThenWidenedShowsTheGroupName() {
        let cell = laidOut(content(title: "Allow and Block Lists", isGroup: true), width: 0)
        cell.setFrameSize(NSSize(width: 900, height: 30))
        cell.layoutSubtreeIfNeeded()
        #expect(cell.titleField.frame.width >= cell.titleField.attributedStringValue.size().width.rounded(.down))
    }

    @Test func aNarrowRowStillShrinksTheTitleBeforeTheControls() {
        let cell = laidOut(content(title: String(repeating: "Long group name ", count: 20), isGroup: true), width: 320)
        #expect(cell.titleField.frame.width < 320)
        #expect(cell.titleField.frame.width > 20)
    }
}
