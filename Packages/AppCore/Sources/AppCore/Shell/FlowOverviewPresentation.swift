import FlowStore
import Foundation
import Localization

public struct OverviewRow: Equatable, Sendable {
    public var title: String
    public var value: String
    public var tone: BadgeTone?

    public init(title: String, value: String, tone: BadgeTone? = nil) {
        self.title = title
        self.value = value
        self.tone = tone
    }
}

public struct OverviewSection: Equatable, Sendable, Identifiable {
    public enum Kind: Sendable { case summary, timing, sizes, connection, rules }

    public var kind: Kind
    public var title: String
    public var rows: [OverviewRow]
    public var id: Kind { kind }

    public init(kind: Kind, title: String, rows: [OverviewRow]) {
        self.kind = kind
        self.title = title
        self.rows = rows
    }
}

/// What the inspector's overview tab shows for one flow, as plain rows (no view code).
public enum FlowOverviewPresentation {
    public static func sections(
        for flow: Flow, ruleName: (UUID) -> String?, use24Hour: Bool = true, localizer: Localizer = L10n.localizer,
        cardIndex: OutcomeCardIndex? = nil
    ) -> [OverviewSection] {
        let none = localizer.string("overview.none")
        func row(_ key: String, _ value: String?, _ tone: BadgeTone? = nil) -> OverviewRow {
            let text = value.flatMap { $0.isEmpty ? nil : $0 } ?? none
            return OverviewRow(title: localizer.string(key), value: text, tone: tone)
        }

        let status: OverviewRow
        switch flow.state {
        case .failed(let reason): status = row("overview.status", reason, .failure)
        case .inProgress: status = row("overview.status", localizer.string("overview.status.inProgress"), .pending)
        case .completed, .tunnel:
            status = row("overview.status", flow.statusCode.map(String.init))
        }

        var result = [
            OverviewSection(kind: .summary, title: localizer.string("overview.section.summary"), rows: [
                row("overview.url", flow.url),
                row("overview.method", flow.method),
                status,
                row("overview.app", flow.client?.name),
            ]),
            OverviewSection(kind: .timing, title: localizer.string("overview.section.timing"), rows: [
                row("overview.started", time(flow.startedAt, use24Hour: use24Hour)),
                row("overview.completed", flow.completedAt.map { time($0, use24Hour: use24Hour) }),
                row("overview.duration", flow.completedAt.map {
                    Formatting.duration($0.timeIntervalSince(flow.startedAt), locale: localizer.locale)
                }),
            ]),
            OverviewSection(kind: .sizes, title: localizer.string("overview.section.sizes"), rows: [
                row("overview.sent", Formatting.size(flow.bytesSent)),
                row("overview.received", Formatting.size(flow.bytesReceived)),
            ]),
            OverviewSection(kind: .connection, title: localizer.string("overview.section.connection"), rows: [
                row("overview.clientIP", flow.clientIP),
                row("overview.remoteIP", flow.remoteIP),
                row("overview.protocol", HTTPTransportPresentation.summary(flow.transport, localizer: localizer)),
                row("overview.tls", tls(flow, localizer: localizer)),
            ]),
        ]

        if let matches = flow.provenance.ruleMatches {
            let lines = RulePresentation.resultLines(matches, ruleName: ruleName, localizer: localizer, cardIndex: cardIndex)
            result.append(OverviewSection(
                kind: .rules, title: localizer.string("overview.section.rules"),
                rows: lines.map { OverviewRow(title: "", value: $0.text, tone: $0.tone == .attention ? .pending : .success) }))
        }
        return result
    }

    private static func time(_ date: Date, use24Hour: Bool) -> String {
        Formatting.time(date, use24Hour: use24Hour, full: true)
    }

    private static func tls(_ flow: Flow, localizer: Localizer) -> String? {
        if flow.method == "CONNECT" { return localizer.string("overview.tls.tunnel") }
        return flow.scheme == "https" ? localizer.string("overview.tls.decrypted") : nil
    }
}
