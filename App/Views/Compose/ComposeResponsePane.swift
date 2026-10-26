import AppCore
import AppKit
import FlowStore
import Localization
import SwiftUI
import Viewers

/// The result of the last send: status, time and size, a link to the recorded flow, then the
/// headers and body in the same viewers the flow detail uses. A response that ended early is
/// labelled as partial above its content and is never shown as a complete one.
struct ComposeResponsePane: View {
    let model: ComposeViewModel
    let appModel: AppModel
    let flowList: FlowListModel
    @Environment(\.openWindow) private var openWindow
    @State private var tab = Tab.body

    private enum Tab: String, CaseIterable, Identifiable {
        case headers, body
        var id: Self { self }
        var localizationKey: String {
            switch self {
            case .headers: "compose.response.headers"
            case .body: "compose.response.body"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text(L10n.string("compose.response.title")).font(.headline)
                if model.isSending {
                    ProgressView().controlSize(.small)
                    Text(L10n.string("compose.state.sending")).foregroundStyle(.secondary)
                }
                Spacer()
                if let result = model.result { flowLink(result) }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            if let result = model.result {
                resultView(result)
            } else {
                Text(L10n.string("compose.response.placeholder"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    @ViewBuilder private func resultView(_ result: ComposeResultPresentation) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let response = result.response {
                HStack(spacing: 10) {
                    Text(verbatim: "\(response.status) \(response.reason)")
                        .font(.body.monospaced().weight(.semibold))
                        .foregroundStyle(response.status < 400 ? Palette.successColor : Palette.failureColor)
                    Text(L10n.format("compose.response.summary", elapsed(result), Formatting.size(Int(clamping: response.bodyBytes))))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            if let partial = result.partialNotice {
                notice(partial, systemImage: "exclamationmark.triangle.fill", color: Palette.pendingColor)
            }
            if let message = result.failureMessage {
                notice(message, systemImage: "xmark.octagon.fill", color: Palette.failureColor)
            }
            if let delivery = result.deliveryNotice {
                notice(delivery, systemImage: "questionmark.circle.fill", color: Palette.pendingColor)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        if let response = result.response {
            Picker(L10n.string("compose.response.title"), selection: $tab) {
                ForEach(Tab.allCases) { Text(L10n.string($0.localizationKey)).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
            Divider()
            let style = appModel.settings.preferences.viewerStyle
            switch tab {
            case .headers:
                NameValueTable(rows: (response.headers + response.trailers).map { NameValue(name: $0.name, value: $0.value) },
                               style: style)
            case .body:
                VStack(alignment: .leading, spacing: 0) {
                    if response.truncated {
                        ComposeResponseNote(text: L10n.format(
                            "compose.response.truncated", Formatting.size(response.body.count),
                            Formatting.size(Int(clamping: response.bodyBytes))))
                    }
                    BodyView(
                        data: response.body, contentType: response.headers.value(for: "Content-Type"),
                        contentEncoding: response.headers.value(for: "Content-Encoding"),
                        isCaptureTruncated: response.truncated || result.isPartial, style: style)
                        .equatable()
                        .id(result.id)
                }
            }
        }
    }

    @ViewBuilder private func flowLink(_ result: ComposeResultPresentation) -> some View {
        if let flowID = result.flowID {
            if flowList.shownFlow(id: flowID) != nil {
                Button(L10n.string("compose.flowLink")) { showInFlowList(flowID) }
                    .buttonStyle(.link)
            } else {
                Text(L10n.string("compose.flowLink.cleared")).foregroundStyle(.secondary)
            }
        }
    }

    private func notice(_ text: String, systemImage: String, color: Color) -> some View {
        Label(text, systemImage: systemImage)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func elapsed(_ result: ComposeResultPresentation) -> String {
        let seconds = result.elapsed.map { Double($0.components.seconds) + Double($0.components.attoseconds) / 1e18 }
        return Formatting.duration(seconds)
    }

    /// Selects the recorded flow in the main window, showing it even if the current filter hid it.
    private func showInFlowList(_ id: Int) {
        appModel.shell.page = .traffic
        flowList.autoSelectsLatest = false
        if !flowList.visible.contains(where: { $0.id == id }) { flowList.filter = FlowFilter() }
        flowList.selectedID = id
        MainWindowLocator.bringToFront(openWindow: openWindow)
    }
}

private struct ComposeResponseNote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
    }
}
