import Localization
import ProxyCore
import SwiftUI

struct SSLProxyingListView: View {
    let appModel: AppModel
    @State private var automatic = false
    @State private var filter = ""
    @State private var selection: String?
    @State private var newPattern = ""
    @State private var patternError: String?
    @State private var showsAdd = false
    @State private var showsPlaceholder = false
    @State private var confirmsClear = false
    @FocusState private var filterFocused: Bool
    private var policy: DecryptionPolicy { appModel.settings.decryption }
    private var hosts: [String] {
        let entries = automatic ? appModel.settings.passthroughHosts.sorted() : policy.excludedHosts
        return entries.filter { filter.isEmpty || $0.localizedCaseInsensitiveContains(filter) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(
                L10n.string("flowDetailView.enableDecryption"),
                isOn: Binding(
                    get: { policy.enabled },
                    set: { enabled in
                        var updated = policy
                        updated.enabled = enabled
                        appModel.setDecryptionPolicy(updated)
                    }))
            Text(L10n.string("sslProxyingList.sslListHelp"))
                .font(.caption).foregroundStyle(.secondary)
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Picker(L10n.string("sslProxyingList.list"), selection: $automatic) {
                        Text(L10n.string("sslProxyingList.exclusions")).tag(false)
                        Text(L10n.string("sslProxyingList.automaticPassthrough")).tag(true)
                    }.pickerStyle(.segmented).labelsHidden()
                    Text(
                        automatic
                            ? L10n.string("sslProxyingList.automaticPassthroughHelp")
                            : L10n.string("sslProxyingList.exclusionsHelp")
                    )
                    .font(.caption).foregroundStyle(.secondary)
                    TextField(L10n.string("sslProxyingList.filterShortcut"), text: $filter).textFieldStyle(
                        .roundedBorder
                    ).focused($filterFocused)
                    Text(L10n.string("sslProxyingList.name")).font(.caption.bold()).foregroundStyle(.secondary)
                    List(selection: $selection) {
                        ForEach(hosts, id: \.self) { host in
                            Toggle(host, isOn: Binding(get: { isEnabled(host) }, set: { setEnabled($0, host: host) }))
                                .font(.body.monospaced()).tag(host)
                        }
                    }.listStyle(.inset).frame(minHeight: 210)
                        .overlay {
                            if hosts.isEmpty {
                                Text(L10n.string("sslProxyingList.noHosts")).foregroundStyle(.secondary)
                                    .allowsHitTesting(false)
                            }
                        }
                    HStack {
                        Button {
                            showsAdd = true
                        } label: {
                            Image(systemName: "plus")
                        }.help(L10n.string("sslProxyingList.addExclusion"))
                            .accessibilityLabel(L10n.string("sslProxyingList.addExclusion"))
                            .disabled(automatic)
                        Button {
                            if let selection { remove(selection) }
                        } label: {
                            Image(systemName: "minus")
                        }
                        .disabled(selection == nil || !hosts.contains(selection ?? "")).help(
                            L10n.string("sslProxyingList.removeSelection")
                        )
                        .accessibilityLabel(L10n.string("sslProxyingList.removeSelection"))
                        Spacer()
                        Menu(L10n.string("sslProxyingList.more")) {
                            Button(L10n.string("sslProxyingList.clearAllAction"), role: .destructive) {
                                confirmsClear = true
                            }
                            .disabled(
                                automatic
                                    ? appModel.settings.passthroughHosts.isEmpty : policy.excludedHosts.isEmpty)
                        }.fixedSize()
                    }
                }.padding(6)
            }
            HStack {
                Button(L10n.string("sslProxyingList.bypassSettings")) { showsPlaceholder = true }
                Spacer()
                Button {
                    showsPlaceholder = true
                } label: {
                    Image(systemName: "questionmark.circle")
                }.buttonStyle(.borderless).help(L10n.string("sslProxyingList.sslHelp"))
                    .accessibilityLabel(L10n.string("sslProxyingList.sslHelp"))
            }
        }.padding(20).frame(minWidth: 500, minHeight: 480)
            .onChange(of: automatic) { selection = nil }
            .background {
                Button(L10n.string("appCommands.filter")) { filterFocused = true }.keyboardShortcut("f").hidden()
            }
            .sheet(isPresented: $showsAdd) {
                VStack(alignment: .leading, spacing: 14) {
                    Text(L10n.string("sslProxyingList.addExclusion")).font(.headline)
                    TextField(L10n.string("sslProxyingList.patternPlaceholder"), text: $newPattern).onSubmit(add)
                    if let patternError { Text(patternError).font(.caption).foregroundStyle(.red) }
                    HStack {
                        Spacer()
                        Button(L10n.string("common.cancel")) { showsAdd = false }
                        Button(L10n.string("sslProxyingList.add"), action: add).keyboardShortcut(.defaultAction)
                    }
                }.padding(24).frame(width: 400)
            }
            .alert(L10n.string("sslProxyingList.clearListQuestion"), isPresented: $confirmsClear) {
                Button(L10n.string("common.cancel"), role: .cancel) {}
                Button(L10n.string("sslProxyingList.clearAll"), role: .destructive, action: clear)
            } message: {
                Text(L10n.string("sslProxyingList.clearListHelp"))
            }
            .alert(L10n.string("advancedProxySheet.availableLater"), isPresented: $showsPlaceholder) {
                Button(L10n.string("advancedProxySheet.ok"), role: .cancel) {}
            } message: {
                Text(L10n.string("sslProxyingList.bypassSettingsHelp"))
            }
    }
    private func isEnabled(_ host: String) -> Bool {
        automatic
            || !policy.disabledExcludedHosts.contains {
                HostPattern.normalizedUserPattern($0) == HostPattern.normalizedUserPattern(host)
            }
    }
    private func setEnabled(_ enabled: Bool, host: String) {
        if automatic {
            if !enabled { appModel.passthrough.remove(host) }
            return
        }
        var updated = policy
        updated.disabledExcludedHosts.removeAll {
            HostPattern.normalizedUserPattern($0) == HostPattern.normalizedUserPattern(host)
        }
        if !enabled { updated.disabledExcludedHosts.append(host) }
        appModel.setDecryptionPolicy(updated)
    }
    private func add() {
        guard let host = HostPattern.normalizedUserPattern(newPattern) else {
            patternError = L10n.string("sslProxyingList.invalidPattern")
            return
        }
        var updated = policy
        if !updated.excludedHosts.contains(where: { HostPattern.normalizedUserPattern($0) == host }) {
            updated.excludedHosts.append(host)
        }
        appModel.setDecryptionPolicy(updated)
        newPattern = ""
        patternError = nil
        showsAdd = false
        selection = host
    }
    private func remove(_ host: String) {
        if automatic {
            appModel.passthrough.remove(host)
        } else {
            var updated = policy
            updated.excludedHosts.removeAll { $0 == host }
            updated.disabledExcludedHosts.removeAll {
                HostPattern.normalizedUserPattern($0) == HostPattern.normalizedUserPattern(host)
            }
            appModel.setDecryptionPolicy(updated)
        }
        selection = nil
    }
    private func clear() {
        if automatic {
            for host in appModel.passthrough.hosts { appModel.passthrough.remove(host) }
        } else {
            var updated = policy
            updated.excludedHosts = []
            updated.disabledExcludedHosts = []
            appModel.setDecryptionPolicy(updated)
        }
        selection = nil
    }
}
