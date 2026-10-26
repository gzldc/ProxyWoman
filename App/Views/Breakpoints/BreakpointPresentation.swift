import AppCore
import SwiftUI

/// How the breakpoint pages describe a paused ticket.
enum BreakpointPresentation {
    /// The request method, or the response status.
    static func verb(of ticket: BreakpointTicketSnapshot) -> String {
        if let target = ticket.requestTarget { return target.method }
        return ticket.status.map(String.init) ?? ""
    }

    /// A request's own URL; for a response, the URL of its recorded flow (nil when unrecorded).
    @MainActor static func url(of ticket: BreakpointTicketSnapshot, flowList: FlowListModel) -> String? {
        if let target = ticket.requestTarget { return BreakpointURL.display(target) }
        return ticket.flowID.flatMap { flowList.collection.flow(id: $0)?.url }
    }
}
