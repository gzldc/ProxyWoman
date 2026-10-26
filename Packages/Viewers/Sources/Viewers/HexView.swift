import SwiftUI

/// A hex dump of the bytes (the dump itself stops after 1 MB), formatted off the main actor.
struct HexView: View {
    let data: Data
    var style = ViewerStyle()
    @State private var dump: String?

    var body: some View {
        Group {
            if let dump {
                RawTextView(text: dump, wrapsLines: false, style: style)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            let data = self.data
            let dump = await Task.detached(priority: .userInitiated) { HexDump.format(data) }.value
            if !Task.isCancelled { self.dump = dump }
        }
    }
}
