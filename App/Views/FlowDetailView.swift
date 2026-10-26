import AppCore
import FlowStore
import Localization
import ProxyCore
import SwiftUI

struct FlowDetailView: View {
    let flow: Flow?
    let appModel: AppModel
    var body: some View {
        if let flow {
            // A new session starts on the original record again (the mode lives in the keyed child).
            FlowDetailContent(flow: flow, appModel: appModel).id(flow.id)
        } else {
            Text(L10n.string("flowDetailView.selectRequest")).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct FlowDetailContent: View {
    let flow: Flow
    let appModel: AppModel
    @State private var mode = ExecuteViewMode.original
    @State private var comparing: Flow?

    var body: some View {
        // The panes show the stored original or the modification layer; both come from one copy per body.
        let displayFlow = mode == .modified ? flow.viewingExecuteOverlay() : flow
        let running: Bool = { if case .running = appModel.executeRunner.phase { true } else { false } }()
        VStack(spacing: 0) {
                // Only WebSocket candidates re-render on the 10 Hz invalidation revision.
                let _ = WebSocketDetailModelSlot.observesInvalidations(flow) ? appModel.webSocketHub.revision : 0
                let token = appModel.store.webSocketToken(flowID: flow.id)
                let summary = token.flatMap { appModel.store.webSocketSummary(token: $0) }
                DetailSummaryBar(flow: flow, webSocketSummary: summary,
                                 ruleName: { id in appModel.rulesEditor.rules.first { $0.id == id }?.name },
                                 cardIndex: { appModel.rulesEditor.outcomeCardIndex(rule: $0, stored: $1, code: $2) },
                                 annotationEditing: annotationEditing(for: flow))
                ExecuteBanner(
                    flow: flow, mode: $mode,
                    undo: { _ = appModel.executeRunner.undoFlow(flow.id) },
                    compare: { comparing = flow }, canUndo: !running)
                Divider()
                if let token, let summary, FlowProtocol.of(displayFlow, webSocketSummary: summary) == .websocket {
                    WebSocketSessionDetail(flow: displayFlow, appModel: appModel, token: token, summary: summary).id(token)
                } else if displayFlow.method == "CONNECT" {
                    TunnelInfo(flow: displayFlow, appModel: appModel)
                } else {
                    GeometryReader { geometry in
                        if geometry.size.width >= 680 {
                            HSplitView { messagePanes(for: displayFlow) }
                        } else {
                            VSplitView { messagePanes(for: displayFlow) }
                        }
                    }
                }
            }
            .sheet(isPresented: Binding(get: { comparing != nil }, set: { if !$0 { comparing = nil } })) {
                if let comparing { ExecuteDiffSheet(flow: comparing) }
            }
    }

    private func annotationEditing(for flow: Flow) -> AnnotationEditing {
        let commands = appModel.flowAnnotations
        let flowID = flow.id
        let current = flow.comment
        return AnnotationEditing(
            markPreset: { commands.mark($0, flowID: flowID) },
            clearMark: { commands.clearMark(flowID: flowID) },
            editComment: {
                switch CommentPrompt.run(current: current) {
                case .save(let text): commands.setComment(text, flowID: flowID)
                case .clear: commands.setComment(nil, flowID: flowID)
                case .cancel: break
                }
            })
    }

    @ViewBuilder private func messagePanes(for flow: Flow) -> some View {
        MessagePane(flow: flow, side: .request, preferences: appModel.settings.preferences)
            .frame(minWidth: 280, minHeight: 130)
        MessagePane(flow: flow, side: .response, preferences: appModel.settings.preferences)
            .frame(minWidth: 280, minHeight: 130)
    }
}

private struct TunnelInfo: View {
    let flow: Flow
    let appModel: AppModel
    @State private var confirmsWildcard = false
    private var excluded: Bool { !appModel.settings.decryption.shouldDecrypt(flow.host) }
    private var matchingPatterns: [String] {
        appModel.settings.decryption.excludedHosts.filter { HostPattern.matches($0, host: flow.host) }
    }
    private var matchingRuleList: String {
        let formatter = ListFormatter()
        formatter.locale = L10n.locale
        return formatter.string(from: matchingPatterns) ?? ""
    }
    private var failed: Bool {
        if case .failed = flow.state { return true }
        return false
    }
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: failed ? "exclamationmark.triangle.fill" : "lock.fill")
                .font(.largeTitle)
                .foregroundStyle(failed ? Palette.failureColor : .secondary)
            Text(failed ? L10n.string("flowDetailView.httpsFailed") : L10n.string("flowDetailView.httpsEncrypted"))
                .font(.headline)
            Text(reason).foregroundStyle(.secondary)
            if excluded {
                Button(
                    appModel.settings.decryption.enabled
                        ? L10n.string("flowDetailView.enableDecryptionForHost")
                        : L10n.string("flowDetailView.enableDecryption")
                ) {
                    if matchingPatterns.contains(where: { $0.contains("*") }) {
                        confirmsWildcard = true
                    } else {
                        enableDecryption()
                    }
                }
            } else if appModel.passthrough.contains(flow.host) {
                Button(L10n.string("flowDetailView.removePassthrough")) { appModel.passthrough.remove(flow.host) }
            }
            Text(
                failed
                    ? L10n.string("flowDetailView.retryAfterChange") : L10n.string("flowDetailView.tunnelCannotDecrypt")
            )
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
        .confirmationDialog(L10n.string("flowDetailView.removeRulesQuestion"), isPresented: $confirmsWildcard) {
            Button(L10n.string("flowDetailView.removeAndDecrypt"), action: enableDecryption)
        } message: {
            Text(
                L10n.format("flowDetailView.matchingRules", matchingRuleList)
            )
        }
    }
    private var reason: String {
        if failed { return L10n.string("flowDetailView.connectionFailed") }
        if !appModel.settings.decryption.enabled { return L10n.string("flowDetailView.decryptionDisabled") }
        if excluded { return L10n.string("flowDetailView.excludedHost") }
        if appModel.passthrough.contains(flow.host) { return L10n.string("flowDetailView.certificatePinning") }
        return L10n.string("flowDetailView.tunnelNoContent")
    }
    private func enableDecryption() {
        var policy = appModel.settings.decryption
        policy.enableDecryption(for: flow.host, passthrough: appModel.passthrough)
        appModel.setDecryptionPolicy(policy)
    }
}


private struct WebSocketSessionDetail: View {
    let flow: Flow
    let appModel: AppModel
    let token: WebSocketSessionToken
    // Cheap holder: the model is created on appear, not on every view-value init.
    @State private var slot = WebSocketDetailModelSlot()
    @State private var messages: Bool
    init(flow: Flow, appModel: AppModel, token: WebSocketSessionToken, summary: WebSocketSummary) {
        self.flow = flow; self.appModel = appModel; self.token = token
        _messages = State(initialValue: [.verified, .opaqueExtension].contains(summary.handshake.assessment))
    }
    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $messages) {
                Text(L10n.string("webSocket.handshake")).tag(false)
                Text(L10n.string("webSocket.messages")).tag(true)
            }.pickerStyle(.segmented).padding(6)
            if messages {
                if let model = slot.model { WebSocketPane(model: model).id(ObjectIdentifier(model)) } else { Spacer() }
            }
            else {
                GeometryReader { geometry in
                    if geometry.size.width >= 680 { HSplitView { panes } }
                    else { VSplitView { panes } }
                }
            }
        }
        .onAppear { slot.activate(store: appModel.store, hub: appModel.webSocketHub, token: token) }
        .onDisappear { slot.deactivate() }
    }
    @ViewBuilder private var panes: some View {
        MessagePane(flow: flow, side: .request, preferences: appModel.settings.preferences).frame(minWidth: 280, minHeight: 130)
        MessagePane(flow: flow, side: .response, preferences: appModel.settings.preferences).frame(minWidth: 280, minHeight: 130)
    }
}
