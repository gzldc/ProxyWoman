import Localization
import SwiftUI

/// The SSL proxying list (decryption switch, exclusions, automatic passthrough) as a settings page.
struct HTTPSPane: View {
    let appModel: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SSLProxyingListView(appModel: appModel)
            Text(L10n.string("settings.https.undecryptedHint"))
                .font(.caption).foregroundStyle(.secondary)
                .padding([.horizontal, .bottom], 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
