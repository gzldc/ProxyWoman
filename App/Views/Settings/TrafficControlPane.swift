import AppCore
import Localization
import SwiftUI

/// The three traffic tables in one resizable page. The tables are the existing tool-window tables;
/// they fill the page and are never placed in a padded ScrollView, which would collapse them.
struct TrafficControlPane: View {
    let model: TrafficToolsModel
    @Bindable var navigation: TrafficToolsNavigation
    let health: PatternHealthMonitor

    var body: some View {
        VStack(spacing: 0) {
            Picker(L10n.string("traffic.window.title"), selection: $navigation.tab) {
                ForEach(TrafficToolsTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(12)
            Divider()
            switch navigation.tab {
            case .allow: AllowListTab(model: model, health: health)
            case .block: BlockListTab(model: model, health: health)
            case .conditions: ConditionsTab(model: model)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
