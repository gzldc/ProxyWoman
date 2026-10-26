import AppCore
import FlowStore
import Localization
import SwiftUI

/// Which version of an Execute-modified session the detail pane shows.
enum ExecuteViewMode: Hashable {
    case original, modified
}

/// The strip under the detail pane's summary bar for a session Execute wrote to: what was done, which version is
/// shown, compare and undo. Nothing for a session Execute never touched.
struct ExecuteBanner: View {
    let flow: Flow
    @Binding var mode: ExecuteViewMode
    let undo: () -> Void
    let compare: () -> Void
    /// False while a run is going (the runner refuses single undo then).
    var canUndo = true

    var body: some View {
        if let banner = ExecuteDetailBanner.of(flow) {
            HStack(spacing: 10) {
                Image(systemName: "play.circle.fill").foregroundStyle(Color.accentColor)
                switch banner.kind {
                case .modified:
                    Text(L10n.string("flowDetail.execute.banner")).font(.callout)
                    Picker("", selection: $mode) {
                        Text(L10n.string("flowDetail.execute.viewOriginal")).tag(ExecuteViewMode.original)
                        Text(L10n.string("flowDetail.execute.viewModified")).tag(ExecuteViewMode.modified)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    .accessibilityLabel(
                        L10n.string(
                            mode == .original ? "flowDetail.execute.showingOriginal" : "flowDetail.execute.showingModified"))
                    if banner.canCompare {
                        Button(L10n.string("flowDetail.execute.compare"), action: compare)
                            .accessibilityLabel(L10n.string("flowDetail.execute.compare"))
                    }
                case .recordOnly:
                    Text(L10n.string("flowDetail.execute.bannerRecordOnly")).font(.callout)
                }
                Spacer(minLength: 0)
                Button(L10n.string("flowDetail.execute.undo"), action: undo)
                    .disabled(!canUndo)
                    .accessibilityLabel(L10n.string("flowDetail.execute.undo"))
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.1))
        }
    }
}
