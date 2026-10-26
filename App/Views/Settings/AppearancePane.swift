import AppCore
import Localization
import SwiftUI

struct AppearancePane: View {
    @Bindable var settings: AppSettings
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            GroupBox(L10n.string("appearancePane.interface")) {
                VStack(spacing: 12) {
                    SettingsRow(title: L10n.string("appearancePane.fontSizeLabel")) {
                        Picker(L10n.string("appearancePane.fontSize"), selection: $settings.preferences.fontSize) {
                            ForEach(Array(Preferences.fontSizeRange), id: \.self) { Text(String($0)).tag($0) }
                        }.labelsHidden().frame(width: 90)
                    }
                    SettingsRow(title: "") {
                        Toggle(L10n.string("appearancePane.monospaced"), isOn: $settings.preferences.monospaced)
                        Text(L10n.string("appearancePane.fontHelp")).font(.caption).foregroundStyle(.secondary)
                    }
                    SettingsRow(title: L10n.string("appearancePane.bodyTabsLabel")) {
                        Toggle(L10n.string("appearancePane.wordWrap"), isOn: $settings.preferences.wordWrap)
                        Toggle(L10n.string("appearancePane.showInvisibles"), isOn: $settings.preferences.showInvisibles)
                    }
                    SettingsRow(title: L10n.string("appearancePane.otherLabel")) {
                        Toggle(L10n.string("appearancePane.zebraRows"), isOn: $settings.preferences.zebraRows)
                        Toggle(
                            L10n.string("appearancePane.showResourceUsage"),
                            isOn: $settings.preferences.showResourceUsage)
                        Text(L10n.string("appearancePane.resourceUsageHelp")).font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(12)
            }
            GroupBox(L10n.string("appearancePane.timeFormat")) {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle(L10n.string("appearancePane.use24Hour"), isOn: $settings.preferences.use24HourTime)
                    Toggle(L10n.string("appearancePane.fullTime"), isOn: $settings.preferences.fullTimeFormat)
                    Text(L10n.string("appearancePane.fullTimeHelp")).font(.caption).foregroundStyle(.secondary)
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox(L10n.string("appearancePane.theme")) {
                HStack(spacing: 12) {
                    themeCard(.system, L10n.string("appearancePane.systemTheme"))
                    themeCard(.light, L10n.string("appearancePane.lightTheme"))
                    themeCard(.dark, L10n.string("appearancePane.darkTheme"))
                }.padding(10)
            }
            Button(L10n.string("advancedProxySheet.resetDefaults"), action: resetAppearance)
        }
    }

    private func themeCard(_ theme: ThemeMode, _ name: String) -> some View {
        Button {
            settings.preferences.theme = theme
        } label: {
            VStack(spacing: 8) {
                ZStack {
                    HStack(spacing: 0) {
                        Rectangle().fill(theme == .dark ? Color(nsColor: .darkGray) : Color(nsColor: .white))
                        Rectangle().fill(theme == .light ? Color(nsColor: .white) : Color(nsColor: .darkGray))
                    }
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 3).fill(Color.accentColor.opacity(0.4)).frame(width: 24)
                        VStack(spacing: 5) {
                            ForEach(0..<4) { _ in Capsule().fill(Color.accentColor.opacity(0.5)).frame(height: 3) }
                        }
                    }.padding(10)
                }.frame(height: 62).clipShape(RoundedRectangle(cornerRadius: 5))
                HStack {
                    Text(name)
                    Spacer(minLength: 0)
                    if settings.preferences.theme == theme {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
                    }
                }.font(.callout)
            }
            .padding(8)
            .background(settings.preferences.theme == theme ? Color.accentColor.opacity(0.1) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8).stroke(
                    settings.preferences.theme == theme ? Color.accentColor : Color.secondary.opacity(0.3)))
        }.buttonStyle(.plain).accessibilityLabel(name).accessibilityAddTraits(
            settings.preferences.theme == theme ? .isSelected : [])
    }

    private func resetAppearance() {
        let defaults = Preferences()
        settings.preferences.theme = defaults.theme
        settings.preferences.fontSize = defaults.fontSize
        settings.preferences.monospaced = defaults.monospaced
        settings.preferences.wordWrap = defaults.wordWrap
        settings.preferences.showInvisibles = defaults.showInvisibles
        settings.preferences.zebraRows = defaults.zebraRows
        settings.preferences.showResourceUsage = defaults.showResourceUsage
        settings.preferences.use24HourTime = defaults.use24HourTime
        settings.preferences.fullTimeFormat = defaults.fullTimeFormat
    }
}
