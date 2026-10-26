import Darwin
import Foundation

/// The outcome of locating one Map Local directory request (spec F4-F9).
public enum DirectoryResolution: Sendable {
    /// A regular file inside the directory; the lease owns its descriptor.
    case file(OwnedFileLease, contentType: String)
    /// Missing, a symlink anywhere below the root, not a regular file, a directory without
    /// `index.html`, or a directory while serving the index is off.
    case notFound
    /// The subpath was rejected (F3). Decided without touching the file system.
    case unsafe
    /// Not `GET` or `HEAD`. Decided without touching the file system.
    case methodNotAllowed
    /// The bookmark does not resolve, the root is gone, the file exceeds `assetFileBytes`, or I/O failed.
    case unavailable(OwnedFileError)
}

/// Serves files from a user directory live, one `openat` component at a time from a descriptor of the
/// root, so a request can never leave the root: every component below it is opened with
/// `O_NOFOLLOW` (any symlink is "not found"), the last one also with `O_NONBLOCK` (a FIFO cannot stall
/// the queue), and only an `fstat`-confirmed regular file is leased. All blocking work (bookmark
/// resolution, opens, `fstat`) runs on this resolver's own serial file queue; nothing is cached.
public final class MappedDirectoryResolver: Sendable {
    private let limits: RulesLimits
    private let budgets: OwnedFileBudgets
    private let runner: OwnedFileRunner

    package init(
        limits: RulesLimits, budgets: OwnedFileBudgets,
        runner: @escaping OwnedFileRunner = OwnedFileRunners.serialQueue(label: "proxywoman.map-directory")
    ) {
        self.limits = limits
        self.budgets = budgets
        self.runner = runner
    }

    public func resolve(_ route: DirectoryRoute) async -> DirectoryResolution {
        let segments: [String]
        switch Self.admit(route.subpath, method: route.method) {
        case .answer(let resolution): return resolution
        case .walk(let admitted): segments = admitted
        }
        let bookmark = route.action.bookmark, servesIndex = route.action.servesIndex
        return await onFileQueue { resolver in
            let root: URL
            do {
                root = try DirectoryBookmark.resolve(bookmark)
            } catch {
                return .unavailable(error as? OwnedFileError ?? OwnedFileError(.assetUnavailable))
            }
            // `false` only means the URL carries no security scope (unsandboxed, plain bookmark).
            let scoped = root.startAccessingSecurityScopedResource()
            defer { if scoped { root.stopAccessingSecurityScopedResource() } }
            return resolver.walk(root: root, segments: segments, servesIndex: servesIndex)
        }
    }

    /// Entry point for an already known root (tests); the same checks and walk as `resolve(_:)`.
    package func resolve(root: URL, subpath: DirectorySubpath, method: String, servesIndex: Bool) async -> DirectoryResolution {
        let segments: [String]
        switch Self.admit(subpath, method: method) {
        case .answer(let resolution): return resolution
        case .walk(let admitted): segments = admitted
        }
        return await onFileQueue { $0.walk(root: root, segments: segments, servesIndex: servesIndex) }
    }

    // MARK: admission (no file system access)

    private enum Admission {
        case walk([String])
        case answer(DirectoryResolution)
    }

    /// Unsafe first: an unsafe path is always a local 404 (F8), even for a method that would otherwise
    /// be sent to the network. Every segment is re-checked here, because `.safe` can be constructed by
    /// anyone and a NUL would silently truncate the C string.
    private static func admit(_ subpath: DirectorySubpath, method: String) -> Admission {
        guard case .safe(let segments) = subpath, segments.allSatisfy(isSafeSegment) else { return .answer(.unsafe) }
        guard method == "GET" || method == "HEAD" else { return .answer(.methodNotAllowed) }
        return .walk(segments)
    }

    private static func isSafeSegment(_ segment: String) -> Bool {
        let bytes = segment.utf8
        return !bytes.isEmpty && bytes.count <= DirectorySubpath.maxSegmentBytes && bytes.first != UInt8(ascii: ".")
            && !bytes.contains(0) && !bytes.contains(UInt8(ascii: "/")) && !bytes.contains(UInt8(ascii: "\\"))
    }

    // MARK: walk (file queue only)

    private func onFileQueue(_ body: @escaping @Sendable (MappedDirectoryResolver) -> DirectoryResolution) async -> DirectoryResolution {
        do {
            return try await OwnedFiles.run(on: runner) { [self] in body(self) }
        } catch {
            return .unavailable(error as? OwnedFileError ?? OwnedFileError(.ioFailure))
        }
    }

    private static let intermediateFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    private static let finalFlags = O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC
    private static let indexName = "index.html"

    /// At every point this walk owns exactly one descriptor, and every return path either closes it or
    /// hands it to a lease.
    private func walk(root: URL, segments: [String], servesIndex: Bool) -> DirectoryResolution {
        // The root itself is the user's choice and may be reached through a symlink.
        let rootDescriptor = root.path.withCString { open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC) }
        guard rootDescriptor >= 0 else { return .unavailable(OwnedFileError(.assetUnavailable, errno: errno)) }
        var current = rootDescriptor
        for (index, segment) in segments.enumerated() {
            let flags = index == segments.count - 1 ? Self.finalFlags : Self.intermediateFlags
            let opened = Self.openChild(segment, of: current, flags: flags)
            close(current)
            switch opened {
            case .descriptor(let next): current = next
            case .answer(let resolution): return resolution
            }
        }
        return settle(current, name: segments.last ?? Self.indexName, servesIndex: servesIndex)
    }

    /// Consumes `descriptor`: a regular file becomes a lease, a directory falls through to its index
    /// (one level, never again for a directory named `index.html`), anything else is not found.
    private func settle(_ descriptor: Int32, name: String, servesIndex: Bool) -> DirectoryResolution {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            let code = errno
            close(descriptor)
            return .unavailable(OwnedFileError(.ioFailure, errno: code))
        }
        switch info.st_mode & S_IFMT {
        case S_IFREG:
            guard info.st_size <= Int64(limits.assetFileBytes) else {
                close(descriptor)
                return .unavailable(OwnedFileError(.fileTooLarge))
            }
            let lease = OwnedFileLease(
                id: UUID(), size: Int64(info.st_size), descriptor: descriptor, chunkBytes: limits.ioChunkBytes,
                budgets: budgets, runner: runner, onRelease: {})
            return .file(lease, contentType: MIMETypes.contentType(forFileName: name))
        case S_IFDIR where servesIndex:
            let opened = Self.openChild(Self.indexName, of: descriptor, flags: Self.finalFlags)
            close(descriptor)
            switch opened {
            case .descriptor(let index): return settle(index, name: Self.indexName, servesIndex: false)
            case .answer(let resolution): return resolution
            }
        default:
            close(descriptor)
            return .notFound
        }
    }

    private enum Opened {
        case descriptor(Int32)
        case answer(DirectoryResolution)
    }

    /// Errors that mean "nothing servable by that name": missing, a symlink (`ELOOP`), a non-directory
    /// used as one, no permission, a name the file system rejects, or an object that cannot be opened.
    private static let missingErrors: Set<Int32> = [
        ENOENT, ENOTDIR, ELOOP, EACCES, EPERM, ENAMETOOLONG, EILSEQ, EISDIR, ENXIO, EOPNOTSUPP, ENODEV, EFTYPE,
    ]

    /// One `openat` of a single, already checked name relative to `directory`.
    private static func openChild(_ name: String, of directory: Int32, flags: Int32) -> Opened {
        while true {
            let descriptor = name.withCString { openat(directory, $0, flags) }
            if descriptor >= 0 { return .descriptor(descriptor) }
            let code = errno
            if code == EINTR { continue }
            return .answer(missingErrors.contains(code) ? .notFound : .unavailable(OwnedFileError(.ioFailure, errno: code)))
        }
    }
}

/// Bookmark data for a Map Local directory (F1). The app is not sandboxed today; the bookmark is how
/// a rule keeps finding its directory after a rename or move.
public enum DirectoryBookmark {
    /// Tries a read-only security-scoped bookmark first and falls back to a plain one.
    public static func make(for directory: URL) throws -> Data {
        if let scoped = try? directory.bookmarkData(
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)
        {
            return scoped
        }
        do {
            return try directory.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        } catch {
            throw OwnedFileError(.assetUnavailable)
        }
    }

    /// Resolves once: as a security-scoped bookmark first, then as a plain one, never with UI and
    /// never mounting a volume. A stale bookmark still resolves (the rule is not rewritten here). The
    /// result must currently be a directory; anything else throws `assetUnavailable`.
    public static func resolve(_ data: Data) throws -> URL {
        guard !data.isEmpty, data.count <= MapLocalDirectoryAction.maxBookmarkBytes else {
            throw OwnedFileError(.assetUnavailable)
        }
        guard let url = resolved(data, [.withSecurityScope, .withoutUI, .withoutMounting]) ?? resolved(data, [.withoutUI, .withoutMounting])
        else { throw OwnedFileError(.assetUnavailable) }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var info = stat()
        guard url.path.withCString({ stat($0, &info) }) == 0 else { throw OwnedFileError(.assetUnavailable, errno: errno) }
        guard info.st_mode & S_IFMT == S_IFDIR else { throw OwnedFileError(.assetUnavailable) }
        return url
    }

    private static func resolved(_ data: Data, _ options: URL.BookmarkResolutionOptions) -> URL? {
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: options, relativeTo: nil, bookmarkDataIsStale: &isStale),
            url.isFileURL
        else { return nil }
        return url
    }
}
