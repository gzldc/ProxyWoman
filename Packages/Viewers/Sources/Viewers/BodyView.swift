import Localization
import SwiftUI

/// Shows a message body: decompresses it, then lets the user switch between the JSON tree,
/// the raw text, a hex dump and an image preview. The work runs off the main actor.
///
/// Equality, and so re-preparation, looks only at (size, headers, truncation), never at the
/// bytes: give the view a new identity (`.id`) when it shows a different body.
public struct BodyView: View, Equatable {
    /// Callers load at most this many bytes of a body and pass `isTruncated` when it is longer.
    nonisolated public static let displayLimit = 100 * 1024 * 1024

    private let data: Data
    private let key: Key
    private let style: ViewerStyle
    private let treeOnly: Bool
    private let prepared: PreparedBody?
    @State private var content: BodyContent?
    @State private var mode: BodyMode = .text
    /// Bumped per prepared body, so the mode views start over instead of keeping old state.
    @State private var generation = 0

    /// `isTruncated`: `data` is the first `displayLimit` bytes of a longer body.
    /// `isCaptureTruncated`: the recorded body itself is only a prefix of what was transferred.
    public init(
        data: Data, contentType: String?, contentEncoding: String?, isTruncated: Bool = false,
        isCaptureTruncated: Bool = false, style: ViewerStyle = .init(), treeOnly: Bool = false
    ) {
        self.data = data
        self.prepared = nil
        self.style = style
        self.treeOnly = treeOnly
        key = Key(
            count: data.count, contentType: contentType, contentEncoding: contentEncoding, isTruncated: isTruncated,
            isCaptureTruncated: isCaptureTruncated)
    }

    /// Reuses off-main preparation performed while deciding whether a tree tab is available.
    public init(prepared: PreparedBody, style: ViewerStyle = .init(), treeOnly: Bool = false) {
        self.data = Data()
        self.prepared = prepared
        self.style = style
        self.treeOnly = treeOnly
        key = Key(
            count: prepared.rawCount, contentType: prepared.contentType, contentEncoding: prepared.contentEncoding,
            isTruncated: prepared.isTruncated, isCaptureTruncated: prepared.isCaptureTruncated)
    }

    /// Cheap on purpose: the parent re-creates this view on every update of the flow.
    nonisolated public static func == (lhs: BodyView, rhs: BodyView) -> Bool {
        lhs.key == rhs.key && lhs.style == rhs.style && lhs.treeOnly == rhs.treeOnly
    }

    public var body: some View {
        Group {
            if key.count == 0 {
                placeholder(L10n.string("common.empty"))
            } else if let content = prepared?.content ?? content {
                loaded(content)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: key) {
            content = nil
            if let prepared {
                mode = prepared.content.defaultMode
                return
            }
            guard key.count > 0 else { return }
            let data = self.data
            let key = self.key
            let worker = Task.detached(priority: .userInitiated) {
                BodyContent.make(
                    data: data, contentType: key.contentType, contentEncoding: key.contentEncoding,
                    isTruncated: key.isTruncated || key.isCaptureTruncated)
            }
            let prepared = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            // The selection moved on while this ran.
            guard !Task.isCancelled else { return }
            mode = prepared.defaultMode
            generation &+= 1
            content = prepared
        }
    }

    @ViewBuilder private func loaded(_ content: BodyContent) -> some View {
        VStack(spacing: 0) {
            if let text = BodyContent.truncationNotice(
                displayTruncated: key.isTruncated, captureTruncated: key.isCaptureTruncated,
                recordedBytes: key.count, isEncoded: key.contentEncoding != nil)
            {
                notice(text)
            }
            if let error = content.decodeError {
                notice(error)
            }
            if !treeOnly {
                HStack {
                    Picker(L10n.string("bodyView.mode"), selection: $mode) {
                        ForEach(content.modes) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: Int64(content.data.count), countStyle: .file))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                Divider()
            }
            modeView(content)
                .id(generation)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder private func modeView(_ content: BodyContent) -> some View {
        switch treeOnly ? .json : mode {
        case .json:
            if let roots = content.jsonRoots {
                JSONTreeView(roots: roots, style: style)
            } else {
                placeholder(L10n.string("bodyView.invalidJSON"))
            }
        case .text:
            if let text = content.text {
                RawTextView(text: text, isTruncated: content.isTextTruncated, style: style)
            } else {
                placeholder(L10n.string("bodyView.undecodableText"))
            }
        case .hex:
            HexView(data: content.data, style: style)
        case .image:
            if let image = content.image { ImagePreview(image: image) }
        }
    }

    @ViewBuilder private func notice(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        Divider()
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private struct Key: Equatable, Sendable {
        var count: Int
        var contentType: String?
        var contentEncoding: String?
        var isTruncated: Bool
        var isCaptureTruncated: Bool
    }
}
