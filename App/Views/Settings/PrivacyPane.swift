import Localization
import SwiftUI

struct PrivacyPane: View {
    var body: some View {
        SettingsRow(title: L10n.string("privacyPane.dataCollectionLabel")) {
            Text(L10n.string("privacyPane.noDataCollection")).font(.headline)
            Text(L10n.format("privacyPane.privacyExplanation", AppInfo.name))
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let url = AppInfo.repositoryURL { Link(L10n.string("privacyPane.sourceCode"), destination: url) }
        }
    }
}
