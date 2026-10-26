import AppCore
import AppKit
import Foundation
import Localization
import Testing
@testable import ProxyWoman

/// The traffic table's header widths: Chinese keeps every drawn width; English grows only the translated headers.
@MainActor @Suite(.productionChinese) struct FlowTableColumnTests {
    private static let chinese = Localizer(bundle: L10n.bundle, preferredLanguages: ["zh-Hans"])
    private static let english = Localizer(bundle: L10n.bundle, preferredLanguages: ["en"])

    @Test(arguments: FlowTableView.Column.allCases)
    func chineseKeepsTheExactDrawnWidth(column: FlowTableView.Column) {
        #expect(column.headerWidth(in: Self.chinese) == column.width, "\(column)")
        #expect(column.makeTableColumn().width == column.width, "\(column)")
    }

    // Their titles ("#", "URL", "SSL", none) are never translated, so no language may widen them.
    @Test(arguments: [FlowTableView.Column.dot, .id, .url, .ssl])
    func untranslatedColumnsKeepTheirWidthInEnglishToo(column: FlowTableView.Column) {
        #expect(!column.widthFollowsTitle)
        #expect(column.headerWidth(in: Self.english) == column.width, "\(column)")
    }

    // Against the real Column.width values: each translated header fits its column (11-12 pt title, about 24 pt of cell margins).
    @Test(arguments: FlowTableView.Column.allCases.filter(\.widthFollowsTitle))
    func trafficTableHeadersFitTheirColumnsInEnglish(column: FlowTableView.Column) {
        let title = column.title(in: Self.english)
        let needed = column.headerWidth(in: Self.english)
        #expect(needed >= column.width, "\(column)")
        #expect(TextMeasure.width(title, size: 12) + 24 <= needed, "\(column) \(title) \(needed)")
        // never narrower than what the column was drawn with, and a header that already fit does not move
        if TextMeasure.width(title, size: 12) + 26 <= column.width { #expect(needed == column.width, "\(column)") }
    }
}
