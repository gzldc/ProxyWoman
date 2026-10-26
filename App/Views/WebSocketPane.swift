import AppCore
import AppKit
import FlowStore
import Localization
import SwiftUI
import UniformTypeIdentifiers
import Viewers

struct WebSocketPane: View {
    @Bindable var model: WebSocketViewModel
    @State private var mode: WebSocketPayloadDisplayMode = .hex
    @State private var result: String?
    @State private var action: Task<Void, Never>?
    @State private var busy = false
    @State private var showsSummary = false

    var body: some View {
        VStack(spacing: 0) {
            Button { showsSummary.toggle() } label: {
                HStack {
                    Image(systemName: "info.circle")
                    Text(L10n.format("webSocket.pageCount", Self.count(UInt64(model.page.count)), Self.count(200), model.page.count))
                    Spacer()
                }.font(.caption).foregroundStyle(.secondary)
            }.buttonStyle(.plain).padding(.horizontal, 6).padding(.top, 3)
                .popover(isPresented: $showsSummary) { summary.frame(width: 580).padding(6) }
            HStack {
                Menu(L10n.string("webSocket.filters")) {
                    ForEach([WebSocketDirection.clientToServer, .serverToClient], id: \.self) { direction in
                        Toggle(L10n.string(direction.localizationKey), isOn: Binding(get: { model.directions.contains(direction) }, set: { enabled in
                            var values = model.directions
                            if enabled { values.insert(direction) } else { values.remove(direction) }
                            model.setFilters(directions: values, kinds: model.kinds); reload()
                        }))
                    }
                    Divider()
                    ForEach([WebSocketEventKind.text, .binary, .ping, .pong, .close, .opaqueFrame, .diagnostic], id: \.self) { kind in
                        Toggle(L10n.string(kind.localizationKey), isOn: Binding(get: { model.kinds.contains(kind) }, set: { enabled in
                            var values = model.kinds
                            if enabled { values.insert(kind) } else { values.remove(kind) }
                            model.setFilters(directions: model.directions, kinds: values); reload()
                        }))
                    }
                }.fixedSize()
                Toggle(L10n.string("webSocket.follow"), isOn: $model.autoFollow).onChange(of: model.autoFollow) { _, on in if on { reload() } }
                Button(L10n.string("webSocket.firstPage")) { model.autoFollow = false; reload() }
                Button(L10n.string("webSocket.nextPage")) {
                    model.autoFollow = false
                    Task { await model.load(after: model.nextCursor) }
                }.disabled(model.page.isEmpty)
                Spacer()
                Button(L10n.string("webSocket.exportJSONL")) { save(jsonl: true) }.disabled(busy || model.summary == nil)
            }.padding(6)
            GeometryReader { geometry in
                let tableHeight = max(65, min(140, geometry.size.height * 0.38))
                VStack(spacing: 0) {
                    WebSocketMessageTable(model: model)
                        .frame(height: tableHeight)
                    Divider()
                    // The outer scroll view keeps controls reachable at small splits.
                    // Its unbounded vertical proposal must not reach the nested viewers.
                    ScrollView { details(payloadHeight: max(80, geometry.size.height - tableHeight - 105)) }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }.clipped()
            }
            if let result { Text(result).font(.caption).textSelection(.enabled).padding(6) }
            if busy { HStack { ProgressView().controlSize(.small); Text(L10n.string("webSocket.saving")); Button(L10n.string("webSocket.cancelSave")) { action?.cancel() } }.padding(6) }
        }
        .task { await model.load(after: nil) }
        .onChange(of: model.selectedID) { _, _ in mode = model.selectedEvent?.kind == .text && model.payloadKind == .application ? .text : .hex }
        .onDisappear { action?.cancel() }
    }
    private var summary: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let summary = model.summary {
                Text(L10n.string(summary.lifecycle.localizationKey))
                ForEach([WebSocketDirection.clientToServer, .serverToClient], id: \.self) { direction in
                    Text(L10n.format("webSocket.stateForDirection", L10n.string(direction.localizationKey), L10n.string((direction == .clientToServer ? summary.clientToServer.capture : summary.serverToClient.capture).localizationKey)))
                }
                Text(L10n.format("webSocket.interval", summary.openedAt.map(Self.time) ?? L10n.string("webSocket.unknown"), summary.closedAt.map(Self.time) ?? L10n.string("webSocket.ongoing")))
                Text(L10n.format("webSocket.counts", Self.bytes(saturating(summary.clientToServer.wireBytes, summary.serverToClient.wireBytes)), Self.bytes(saturating(summary.clientToServer.applicationBytes, summary.serverToClient.applicationBytes)), Self.count(saturating(summary.clientToServer.droppedEvents, summary.serverToClient.droppedEvents)), Self.number(saturating(summary.clientToServer.droppedEvents, summary.serverToClient.droppedEvents))))
                Text(L10n.format("webSocket.limits", Self.bytes(UInt64(max(0, model.store.webSocketLimits.decodedPrefixBytes))), Self.bytes(UInt64(max(0, model.store.webSocketLimits.wirePrefixBytes))), Self.bytes(UInt64(max(0, min(262_144, model.store.webSocketLimits.readerPayloadBytes))))))
                Text(summary.handshake.selectedExtensions.isEmpty ? L10n.string("webSocket.noExtensions") : L10n.format("webSocket.extensions", summary.handshake.selectedExtensions.joined(separator: ", ")))
                if summary.lowerBound { Text(L10n.string("webSocket.lowerBound")) }
            }
            Text(L10n.format("webSocket.pageCount", Self.count(UInt64(model.page.count)), Self.count(200), model.page.count))
        }.font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(6)
    }
    private func details(payloadHeight: CGFloat) -> some View {
        VStack(spacing: 4) {
            HStack {
                Picker("", selection: Binding(get: { model.payloadKind }, set: { model.setPayload(kind: $0, attemptBinaryUTF8: false); mode = .hex })) {
                    Text(L10n.string("webSocket.payload.application")).tag(WebSocketPayloadKind.application)
                    Text(L10n.string("webSocket.payload.wirePayload")).tag(WebSocketPayloadKind.wirePayload)
                }.frame(width: 190)
                Toggle(L10n.string("webSocket.binaryUTF8"), isOn: Binding(get: { model.attemptBinaryUTF8 }, set: { model.setPayload(kind: model.payloadKind, attemptBinaryUTF8: $0) }))
                Picker("", selection: $mode) {
                    ForEach(WebSocketPayloadDisplayMode.allCases, id: \.self) { value in Text(L10n.string(value.localizationKey)).tag(value) }
                }.pickerStyle(.segmented).frame(width: 170)
                Spacer()
            }
            if let row = model.selectedEvent {
                HStack {
                    Text(L10n.format("webSocket.fragments", Self.count(row.fragmentCount), Self.count(UInt64(row.fragments.count)), Self.number(row.fragmentCount), row.fragments.count))
                    if row.compressed { Text(L10n.string("webSocket.compressed")) }
                    if row.descriptorTruncated { Text(L10n.string("webSocket.fragmentOverflow")) }
                    if row.captureAbandoned { Text(L10n.string("webSocket.abandoned")) }
                }.font(.caption).foregroundStyle(.secondary)
                DisclosureGroup(L10n.string("webSocket.fragmentDetails")) {
                    ScrollView {
                        VStack(alignment: .leading) {
                            ForEach(row.fragments.indices, id: \.self) { index in
                                let fragment = row.fragments[index]
                                Text(L10n.format("webSocket.fragment", Self.count(UInt64(fragment.opcode)), Self.count(UInt64(fragment.rsv)), fragment.fin ? "1" : "0", fragment.masked ? "1" : "0", Self.bytes(fragment.length), Self.time(fragment.observedAt)))
                            }
                            if let code = row.closeCode { Text(L10n.format("webSocket.closeCode", Self.count(UInt64(code)))) }
                            ForEach(row.diagnostics.indices, id: \.self) { index in Text(L10n.format("webSocket.diagnostic", row.diagnostics[index].code)) }
                            if row.lowerBound { Text(L10n.string("webSocket.lowerBound")) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(height: 90)
                }.font(.caption)
            }
            HStack {
                Button(L10n.string("webSocket.copyTextPreview")) { copy(hex: false) }.disabled(model.prepared?.text == nil)
                Button(L10n.string("webSocket.copyHexPreview")) { copy(hex: true) }.disabled(model.prepared == nil)
                Button(L10n.string("webSocket.savePayload")) { save(jsonl: false) }.disabled(model.prepared == nil || busy)
                Spacer()
                if let prepared = model.prepared { Text(L10n.string(prepared.status.localizationKey)).font(.caption) }
            }
            Group {
                if model.unavailable { empty("webSocket.unavailable") }
                else if model.pending { empty("webSocket.pending") }
                else if let prepared = model.prepared {
                    WebSocketPayloadView(prepared: prepared, mode: mode).accessibilityLabel(L10n.string("webSocket.detailAccessibility"))
                } else { empty("webSocket.selectMessage") }
            }.frame(height: payloadHeight)
        }.padding(6)
    }
    private func empty(_ key: String) -> some View { Text(L10n.string(key)).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity) }
    private func reload() { Task { await model.load(after: nil) } }
    private func copy(hex: Bool) {
        guard let preview = model.validatedPreview() else { result = L10n.string("webSocket.unavailable"); return }
        let value = hex ? preview.bytes.map { String(format: "%02X", $0) }.joined(separator: " ") : preview.text
        guard let value else { result = L10n.string("webSocket.noText"); return }
        guard model.validatedPreview() != nil else { result = L10n.string("webSocket.unavailable"); return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string)
        result = L10n.string("webSocket.copied")
    }
    private func save(jsonl: Bool) {
        let token = model.token, row = model.selectedEvent, kind = model.payloadKind, store = model.store
        let panel = NSSavePanel(); panel.canCreateDirectories = true
        panel.allowedContentTypes = jsonl ? [UTType(filenameExtension: "jsonl") ?? .data] : [.data]
        panel.nameFieldStringValue = L10n.string(jsonl ? "webSocket.defaultFileName.jsonl" : "webSocket.defaultFileName.payload")
        guard panel.runModal() == .OK, let url = panel.url else { result = L10n.string("webSocket.cancelled"); return }
        busy = true
        action = Task {
            defer { busy = false; action = nil }
            do {
                if jsonl {
                    let value = try await WebSocketJSONLExporter.export(store: store, token: token, to: url)
                    result = L10n.format(value.status.localizationKey, Self.count(value.exported), Self.count(value.omittedAtCutoff), Self.count(value.missing), Self.number(value.exported))
                } else if let row {
                    let value = try await WebSocketPayloadExporter.save(store: store, token: token, eventID: row.id, kind: kind, expectedRevision: row.revision, to: url)
                    result = L10n.format(value.complete ? "webSocket.saveComplete" : "webSocket.savePrefix", Self.bytes(UInt64(value.retainedBytes)))
                } else { result = L10n.string("webSocket.unavailable") }
            } catch let failure as WebSocketExportFailure { result = L10n.string(failure.reason.localizationKey) }
            catch { result = L10n.string("webSocket.error.io") }
        }
    }
    static func time(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.locale = L10n.locale
        formatter.setLocalizedDateFormatFromTemplate("yMMMdHHmmssSSSz")
        return formatter.string(from: date)
    }
    static func count(_ value: UInt64) -> String { value.formatted(.number.locale(L10n.locale)) }
    /// The grouped text first, then the number that picks the singular or plural noun.
    static func bytes(_ value: UInt64) -> String { L10n.format("webSocket.byteCount", count(value), number(value)) }
    static func number(_ value: UInt64) -> Int { Int(clamping: value) }
    private func saturating(_ a: UInt64, _ b: UInt64) -> UInt64 { let sum = a.addingReportingOverflow(b); return sum.overflow ? .max : sum.partialValue }
}
