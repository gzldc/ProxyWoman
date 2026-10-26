import AppCore
import Localization
import SwiftUI

struct ToolsPane: View {
    @Bindable var settings: AppSettings
    var body: some View {
        GroupBox(L10n.string("messagePane.copy")) {
            VStack(alignment: .leading, spacing: 14) {
                SettingsRow(title: L10n.string("toolsPane.copyFormatLabel")) {
                    Picker(L10n.string("toolsPane.copyFormat"), selection: $settings.preferences.copyFormat) {
                        Text("cURL").tag(CopyFormat.curl)
                    }.labelsHidden().frame(width: 110)
                }
                Toggle(L10n.format("toolsPane.copyProxy", AppInfo.name), isOn: $settings.preferences.copyAddsProxy)
                Toggle(
                    L10n.string("toolsPane.preserveHeaders"), isOn: $settings.preferences.copyPreservesOriginalHeaders)
                Text(L10n.string("toolsPane.preserveHeadersHelp"))
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
