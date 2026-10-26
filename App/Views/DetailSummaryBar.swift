import AppCore
import FlowStore
import Localization
import SwiftUI

struct DetailSummaryBar: View {
    let flow: Flow
    var webSocketSummary: WebSocketSummary? = nil
    /// The current name of a rule, nil once the rule was deleted.
    var ruleName: (UUID) -> String? = { _ in nil }
    /// The card an outcome's action is numbered by (the editor's card, not the stored index); nil keeps the stored number.
    var cardIndex: OutcomeCardIndex? = nil
    /// The same commands as the flow's context menu; nil hides the editing entry.
    var annotationEditing: AnnotationEditing? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            summary
            if let webSocketSummary {
                Text(L10n.string(webSocketSummary.handshake.assessment.localizationKey))
                if webSocketSummary.handshake.assessment == .invalid || webSocketSummary.handshake.assessment == .negotiationUnverified { Text(L10n.string("webSocket.attempted")) }
                ForEach(webSocketSummary.handshake.diagnostics.indices, id: \.self) { index in
                    Text(L10n.format("webSocket.diagnostic", webSocketSummary.handshake.diagnostics[index].code))
                }
            }
            Text(HTTPTransportPresentation.summary(flow.transport))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            let diagnostics = FlowDiagnostics(flow: flow)
            if let failure = diagnostics.failure {
                Label(L10n.format("detailSummaryBar.failure", failure), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Palette.failureColor)
                    .textSelection(.enabled)
            }
            ForEach(TrafficPresentation.provenanceLines(for: flow.provenance.tools), id: \.self) { line in
                Label(line, systemImage: "slider.horizontal.3")
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            annotationLines
            let results = RulePresentation.resultLines(flow.provenance.ruleMatches, ruleName: ruleName, cardIndex: cardIndex)
            if !results.isEmpty {
                Text(L10n.string("flowDetail.rules.title"))
                    .fontWeight(.medium)
                ForEach(results.indices, id: \.self) { index in
                    switch results[index].tone {
                    case .applied:
                        Label(results[index].text, systemImage: "checkmark")
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    case .attention:
                        Label(results[index].text, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(Palette.pendingColor)
                            .textSelection(.enabled)
                    }
                }
            }
            if webSocketSummary == nil, let note = diagnostics.note {
                Label(note, systemImage: "info.circle")
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .font(.system(size: 12, design: .monospaced))
        .padding(.horizontal, 10).padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
    }
    /// Mark (swatch, line, source), comment, and the entry to edit both.
    @ViewBuilder private var annotationLines: some View {
        if let mark = flow.displayMark {
            HStack(spacing: 6) {
                Circle().fill(Color(nsColor: MarkPalette.swatch(forHex: mark.background))).frame(width: 10, height: 10)
                Text(FlowAnnotationPresentation.markLine(mark))
                Text(FlowAnnotationPresentation.markSourceLine(mark)).foregroundStyle(.secondary)
            }
            .textSelection(.enabled)
        }
        if let comment = flow.comment {
            Text(FlowAnnotationPresentation.commentLine(comment)).textSelection(.enabled)
        }
        if let editing = annotationEditing {
            HStack(spacing: 10) {
                Menu(L10n.string("flowMenu.mark")) {
                    ForEach(MarkPalette.presets.indices, id: \.self) { index in
                        let preset = MarkPalette.presets[index]
                        Button(L10n.string(preset.localizationKey)) { editing.markPreset(preset) }
                    }
                    Divider()
                    Button(L10n.string("flowMenu.mark.clear"), action: editing.clearMark)
                        .disabled(flow.manualMark == nil)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Button(
                    L10n.string(flow.comment == nil ? "flowMenu.comment.add" : "flowMenu.comment.edit"),
                    action: editing.editComment
                )
                .buttonStyle(.borderless)
            }
        }
    }
    private var summary: some View {
        HStack(spacing: 8) {
            pill(flow.method, tone: .neutral)
            let badge = StatusBadge.of(flow)
            pill(
                flow.statusCode.map { "\($0)" + (flow.statusReason.map { " " + $0 } ?? "") } ?? badge.text,
                tone: badge.tone)
            if let uri = webSocketSummary?.handshake.requestURI {
                Text(uri).foregroundStyle(Color.accentColor)
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            } else {
            (Text(flow.scheme + "://").foregroundColor(.secondary)
                + Text(hostAndPath).foregroundColor(.accentColor)
                + Text(query).foregroundColor(.secondary))
                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
    }
    private var hostAndPath: String {
        let path = flow.path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        let port =
            (flow.scheme == "https" && flow.port == 443) || (flow.scheme == "http" && flow.port == 80)
            ? "" : ":\(flow.port)"
        return flow.host + port + path
    }
    private var query: String { flow.path.firstIndex(of: "?").map { String(flow.path[$0...]) } ?? "" }
    private func pill(_ text: String, tone: BadgeTone) -> some View {
        Text(text).fontWeight(.medium).foregroundStyle(Palette.textColor(for: tone))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Palette.badgeFillColor(for: tone), in: RoundedRectangle(cornerRadius: 4))
    }
}

/// The commands the summary bar's mark and comment entry run.
struct AnnotationEditing {
    var markPreset: (MarkPreset) -> Void
    var clearMark: () -> Void
    var editComment: () -> Void
}
