import Darwin
import Foundation
import Testing

@testable import RulesEngine

// MARK: support

/// What a resolution amounted to, without holding on to a lease.
private enum Outcome: Equatable {
    case file(contentType: String, size: Int64)
    case notFound
    case unsafe
    case methodNotAllowed
    case unavailable(OwnedFileError.Code)
}

private func outcome(_ resolution: DirectoryResolution) -> Outcome {
    switch resolution {
    case .file(let lease, let contentType):
        defer { lease.cancel() }
        return .file(contentType: contentType, size: lease.size)
    case .notFound: return .notFound
    case .unsafe: return .unsafe
    case .methodNotAllowed: return .methodNotAllowed
    case .unavailable(let error): return .unavailable(error.code)
    }
}

/// One scratch tree per test: `root` is served, `outside` is a sibling that must never be reachable.
private struct Tree {
    let base = makeTempDirectory()
    var root: URL { base.appendingPathComponent("root") }
    var outside: URL { base.appendingPathComponent("outside") }

    init() {
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try! FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    }

    @discardableResult
    func file(_ relative: String, _ text: String, in directory: URL? = nil) -> URL {
        file(relative, Data(text.utf8), in: directory)
    }

    @discardableResult
    func file(_ relative: String, _ data: Data, in directory: URL? = nil) -> URL {
        let url = (directory ?? root).appendingPathComponent(relative)
        try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return writeFile(url, data)
    }

    func directory(_ relative: String) {
        try! FileManager.default.createDirectory(at: root.appendingPathComponent(relative), withIntermediateDirectories: true)
    }

    func symlink(_ relative: String, to destination: String) {
        let link = root.appendingPathComponent(relative)
        try! FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        #expect(Darwin.symlink(destination, link.path) == 0)
    }

    func remove() { removeTree(base) }
}

private func makeResolver(limits: RulesLimits = RulesLimits()) -> (MappedDirectoryResolver, OwnedFileBudgets) {
    let budgets = OwnedFileBudgets(limits: limits, freeDiskBytes: ample)
    return (MappedDirectoryResolver(limits: limits, budgets: budgets), budgets)
}

private func resolve(
    _ resolver: MappedDirectoryResolver, root: URL, _ segments: [String], method: String = "GET", servesIndex: Bool = true
) async -> DirectoryResolution {
    await resolver.resolve(root: root, subpath: .safe(segments), method: method, servesIndex: servesIndex)
}

private func route(bookmark: Data, _ segments: [String], method: String = "GET", servesIndex: Bool = true) -> DirectoryRoute {
    DirectoryRoute(
        action: MapLocalDirectoryAction(bookmark: bookmark, displayName: "dist", servesIndex: servesIndex),
        subpath: .safe(segments), method: method)
}

/// The served bytes, read through the lease in bounded chunks; nil when the resolution is not a file.
private func served(_ resolution: DirectoryResolution) async throws -> Data? {
    guard case .file(let lease, _) = resolution else { return nil }
    defer { lease.cancel() }
    return try await readAll(lease)
}

/// Open descriptors of this process whose path lies under `directory` (by `F_GETPATH`). Scoped to
/// one test's private tree, so parallel tests elsewhere in the process cannot disturb the count.
private func descriptors(under directory: URL) -> Int {
    guard let real = realpath(directory.path, nil) else { return -1 }
    let prefix = String(cString: real)
    free(real)
    let names = (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd")) ?? []
    var count = 0
    for name in names {
        guard let descriptor = Int32(name) else { continue }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(descriptor, F_GETPATH, &buffer) == 0 else { continue }
        let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        if path == prefix || path.hasPrefix(prefix + "/") { count += 1 }
    }
    return count
}

// MARK: tests

@Suite struct MappedDirectoryResolverTests {
    @Test func servesRegularFileWithTypeAndSize() async throws {
        let tree = Tree(); defer { tree.remove() }
        tree.file("css/app.css", "body{}")
        let (resolver, _) = makeResolver()
        let resolution = await resolve(resolver, root: tree.root, ["css", "app.css"])
        guard case .file(let lease, let contentType) = resolution else {
            Issue.record("expected a file, got \(outcome(resolution))"); return
        }
        defer { lease.cancel() }
        #expect(contentType == "text/css; charset=utf-8")
        #expect(lease.size == 6)
        #expect(try await readAll(lease) == Data("body{}".utf8))
    }

    @Test func readsMultiChunkFileExactly() async throws {
        let tree = Tree(); defer { tree.remove() }
        let bytes = randomData(65_536 + 1)
        tree.file("blob.bin", bytes)
        let (resolver, _) = makeResolver()
        let resolution = await resolve(resolver, root: tree.root, ["blob.bin"])
        guard case .file(let lease, let contentType) = resolution else {
            Issue.record("expected a file, got \(outcome(resolution))"); return
        }
        defer { lease.cancel() }
        #expect(contentType == "application/octet-stream")
        let first = try await lease.read(offset: 0, maxBytes: 65_536)
        let second = try await lease.read(offset: 65_536, maxBytes: 65_536)
        let end = try await lease.read(offset: 65_537, maxBytes: 65_536)
        #expect(first.count == 65_536)
        #expect(second.count == 1)
        #expect(end.isEmpty)
        #expect(first + second == bytes)
    }

    @Test func directoryServesIndexWhenEnabled() async throws {
        let tree = Tree(); defer { tree.remove() }
        tree.file("docs/index.html", "<h1>docs</h1>")
        let (resolver, _) = makeResolver()
        let resolution = await resolve(resolver, root: tree.root, ["docs"])
        #expect(outcome(resolution) == .file(contentType: "text/html; charset=utf-8", size: 13))
        #expect(try await served(await resolve(resolver, root: tree.root, ["docs"])) == Data("<h1>docs</h1>".utf8))
    }

    @Test func directoryWithoutIndexIsNotFound() async {
        let tree = Tree(); defer { tree.remove() }
        tree.file("docs/readme.txt", "no index here")
        let (resolver, _) = makeResolver()
        #expect(outcome(await resolve(resolver, root: tree.root, ["docs"])) == .notFound)
    }

    @Test func indexThatIsADirectoryIsNotFound() async {
        let tree = Tree(); defer { tree.remove() }
        tree.directory("docs/index.html")
        let (resolver, _) = makeResolver()
        #expect(outcome(await resolve(resolver, root: tree.root, ["docs"])) == .notFound)
    }

    @Test func indexDisabledIsNotFound() async {
        let tree = Tree(); defer { tree.remove() }
        tree.file("docs/index.html", "<h1>docs</h1>")
        tree.file("index.html", "<h1>root</h1>")
        let (resolver, _) = makeResolver()
        #expect(outcome(await resolve(resolver, root: tree.root, ["docs"], servesIndex: false)) == .notFound)
        #expect(outcome(await resolve(resolver, root: tree.root, [], servesIndex: false)) == .notFound)
        // The index file itself, named explicitly, is still an ordinary file.
        #expect(outcome(await resolve(resolver, root: tree.root, ["docs", "index.html"], servesIndex: false))
            == .file(contentType: "text/html; charset=utf-8", size: 13))
    }

    @Test func rootRequestServesRootIndex() async throws {
        let tree = Tree(); defer { tree.remove() }
        tree.file("index.html", "<h1>root</h1>")
        let (resolver, _) = makeResolver()
        #expect(try await served(await resolve(resolver, root: tree.root, [])) == Data("<h1>root</h1>".utf8))
    }

    @Test func missingFileIsNotFound() async {
        let tree = Tree(); defer { tree.remove() }
        tree.file("a.txt", "a")
        let (resolver, _) = makeResolver()
        #expect(outcome(await resolve(resolver, root: tree.root, ["b.txt"])) == .notFound)
        #expect(outcome(await resolve(resolver, root: tree.root, ["nope", "b.txt"])) == .notFound)
        // A regular file used as an intermediate directory.
        #expect(outcome(await resolve(resolver, root: tree.root, ["a.txt", "b.txt"])) == .notFound)
    }

    @Test func symlinkToFileInsideRootIsNotFound() async {
        let tree = Tree(); defer { tree.remove() }
        tree.file("real.txt", "inside")
        tree.symlink("link.txt", to: "real.txt")
        let (resolver, _) = makeResolver()
        #expect(outcome(await resolve(resolver, root: tree.root, ["real.txt"])) == .file(contentType: "text/plain; charset=utf-8", size: 6))
        #expect(outcome(await resolve(resolver, root: tree.root, ["link.txt"])) == .notFound)
    }

    @Test func symlinkToFileOutsideRootIsNotFoundAndSecretNeverOpened() async {
        let tree = Tree(); defer { tree.remove() }
        let secret = tree.file("secret.txt", "SECRET", in: tree.outside)
        tree.symlink("leak.txt", to: secret.path)
        tree.symlink("relative-leak.txt", to: "../outside/secret.txt")
        let (resolver, _) = makeResolver()
        for name in ["leak.txt", "relative-leak.txt"] {
            let resolution = await resolve(resolver, root: tree.root, [name])
            #expect(outcome(resolution) == .notFound)
            #expect(descriptors(under: tree.outside) == 0)
        }
    }

    @Test func symlinkedIntermediateDirectoryIsNotFound() async {
        let tree = Tree(); defer { tree.remove() }
        tree.file("secret.txt", "SECRET", in: tree.outside)
        tree.file("real/inner.txt", "inner")
        tree.symlink("alias", to: "real")
        tree.symlink("escape", to: tree.outside.path)
        let (resolver, _) = makeResolver()
        #expect(outcome(await resolve(resolver, root: tree.root, ["real", "inner.txt"])) == .file(contentType: "text/plain; charset=utf-8", size: 5))
        #expect(outcome(await resolve(resolver, root: tree.root, ["alias", "inner.txt"])) == .notFound)
        #expect(outcome(await resolve(resolver, root: tree.root, ["escape", "secret.txt"])) == .notFound)
        // A symlinked directory as the last segment is not followed for its index either.
        tree.file("index.html", "x", in: tree.outside)
        #expect(outcome(await resolve(resolver, root: tree.root, ["escape"])) == .notFound)
    }

    @Test func symlinkedIndexFileIsNotFound() async {
        let tree = Tree(); defer { tree.remove() }
        tree.file("docs/real.html", "<p>real</p>")
        tree.symlink("docs/index.html", to: "real.html")
        tree.file("secret.html", "SECRET", in: tree.outside)
        tree.symlink("index.html", to: tree.outside.appendingPathComponent("secret.html").path)
        let (resolver, _) = makeResolver()
        #expect(outcome(await resolve(resolver, root: tree.root, ["docs"])) == .notFound)
        #expect(outcome(await resolve(resolver, root: tree.root, [])) == .notFound)
    }

    @Test func symlinkedRootIsAllowed() async throws {
        let tree = Tree(); defer { tree.remove() }
        tree.file("app.js", "let a = 1")
        let alias = tree.base.appendingPathComponent("alias")
        #expect(Darwin.symlink(tree.root.path, alias.path) == 0)
        let (resolver, _) = makeResolver()
        let resolution = await resolve(resolver, root: alias, ["app.js"])
        #expect(outcome(resolution) == .file(contentType: "text/javascript; charset=utf-8", size: 9))
        #expect(try await served(await resolve(resolver, root: alias, ["app.js"])) == Data("let a = 1".utf8))
    }

    @Test(.timeLimit(.minutes(1))) func fifoIsNotFoundWithoutBlocking() async {
        let tree = Tree(); defer { tree.remove() }
        #expect(mkfifo(tree.root.appendingPathComponent("pipe").path, 0o600) == 0)
        tree.directory("fifo-index")
        #expect(mkfifo(tree.root.appendingPathComponent("fifo-index/index.html").path, 0o600) == 0)
        let (resolver, _) = makeResolver()
        #expect(outcome(await resolve(resolver, root: tree.root, ["pipe"])) == .notFound)
        #expect(outcome(await resolve(resolver, root: tree.root, ["fifo-index"])) == .notFound)
        #expect(descriptors(under: tree.root) == 0)
    }

    @Test func socketIsNotFound() async throws {
        // A UNIX socket path must stay short, so this tree lives directly under /tmp.
        let base = URL(fileURLWithPath: "/tmp/pw-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { removeTree(base) }
        let socketPath = base.appendingPathComponent("s").path
        let server = socket(AF_UNIX, SOCK_STREAM, 0)
        #expect(server >= 0)
        defer { close(server) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            socketPath.utf8CString.withUnsafeBytes { buffer.copyMemory(from: UnsafeRawBufferPointer(rebasing: $0.prefix(buffer.count))) }
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(server, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        #expect(bound == 0)
        let (resolver, _) = makeResolver()
        #expect(outcome(await resolve(resolver, root: base, ["s"])) == .notFound)
    }

    @Test func unsafeSubpathNeverTouchesFileSystem() async {
        let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
        let (resolver, _) = makeResolver()
        for method in ["GET", "HEAD", "POST", "DELETE"] {
            let resolution = await resolver.resolve(root: missing, subpath: .unsafe, method: method, servesIndex: true)
            #expect(outcome(resolution) == .unsafe)
        }
        // A garbage bookmark is never even resolved for an unsafe route.
        let routed = await resolver.resolve(DirectoryRoute(
            action: MapLocalDirectoryAction(bookmark: Data("garbage".utf8), displayName: "dist"), subpath: .unsafe, method: "POST"))
        #expect(outcome(routed) == .unsafe)
    }

    @Test func forgedSafeSegmentsAreRejectedAsUnsafe() async {
        // `.safe` is constructible by anyone; the resolver re-checks every segment itself.
        let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
        let (resolver, _) = makeResolver()
        let forged: [[String]] = [
            [".."], ["."], ["a", ".."], [""], ["a/b"], ["../etc"], [".env"], ["a\u{0}b"], ["a\\b"],
            [String(repeating: "x", count: 256)],
        ]
        for segments in forged {
            #expect(outcome(await resolve(resolver, root: missing, segments)) == .unsafe, "\(segments)")
        }
    }

    /// `DirectorySubpath` rejects decoded control bytes outright; the resolver, which also accepts
    /// segments from other callers, still treats them as plain file name bytes.
    @Test func controlCharactersInSegmentsAreJustFileNameBytes() async throws {
        let tree = Tree(); defer { tree.remove() }
        tree.file("secret.txt", "SECRET", in: tree.outside)
        let odd = "a\r\nb\u{7F}"
        tree.file(odd, "odd")
        #expect(DirectorySubpath.resolve(pathAndQuery: "/s/a%0D%0Ab%7F", prefix: "/s/") == .unsafe)
        let subpath = DirectorySubpath.safe([odd])
        let (resolver, _) = makeResolver()
        let resolution = await resolver.resolve(root: tree.root, subpath: subpath, method: "GET", servesIndex: true)
        #expect(try await served(resolution) == Data("odd".utf8))
        // CR/LF/DEL cannot form a separator or a parent reference; nothing outside the root is reached.
        for segments in [["\r\n", "secret.txt"], ["\u{7F}..", "outside", "secret.txt"], ["\r", "\n..", "secret.txt"]] {
            #expect(outcome(await resolve(resolver, root: tree.root, segments)) == .notFound, "\(segments)")
        }
        #expect(descriptors(under: tree.outside) == 0)
    }

    @Test func nonGetHeadMethodIsMethodNotAllowed() async {
        let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
        let (resolver, _) = makeResolver()
        for method in ["POST", "PUT", "DELETE", "OPTIONS", "PATCH", "get", "TRACE"] {
            #expect(outcome(await resolve(resolver, root: missing, ["a.txt"], method: method)) == .methodNotAllowed, "\(method)")
        }
        let routed = await resolver.resolve(route(bookmark: Data("garbage".utf8), ["a.txt"], method: "PUT"))
        #expect(outcome(routed) == .methodNotAllowed)
    }

    @Test func headIsServed() async {
        let tree = Tree(); defer { tree.remove() }
        tree.file("data.json", "{}")
        let (resolver, _) = makeResolver()
        #expect(outcome(await resolve(resolver, root: tree.root, ["data.json"], method: "HEAD"))
            == .file(contentType: "application/json; charset=utf-8", size: 2))
    }

    @Test func oversizedFileIsUnavailable() async {
        let tree = Tree(); defer { tree.remove() }
        tree.file("big.bin", randomData(101))
        tree.file("ok.bin", randomData(100))
        tree.file("big/index.html", randomData(101))
        let (resolver, _) = makeResolver(limits: RulesLimits(assetFileBytes: 100))
        #expect(outcome(await resolve(resolver, root: tree.root, ["big.bin"])) == .unavailable(.fileTooLarge))
        #expect(outcome(await resolve(resolver, root: tree.root, ["big"])) == .unavailable(.fileTooLarge))
        #expect(outcome(await resolve(resolver, root: tree.root, ["ok.bin"])) == .file(contentType: "application/octet-stream", size: 100))
        #expect(descriptors(under: tree.root) == 0)
    }

    @Test func rootRemovedIsUnavailable() async {
        let tree = Tree(); defer { tree.remove() }
        tree.file("a.txt", "a")
        let (resolver, _) = makeResolver()
        #expect(outcome(await resolve(resolver, root: tree.root, ["a.txt"])) == .file(contentType: "text/plain; charset=utf-8", size: 1))
        removeTree(tree.root)
        #expect(outcome(await resolve(resolver, root: tree.root, ["a.txt"])) == .unavailable(.assetUnavailable))
        #expect(outcome(await resolve(resolver, root: tree.root, [])) == .unavailable(.assetUnavailable))
        // A root that is now a regular file is not a directory either.
        tree.file("root", "not a directory", in: tree.base)
        #expect(outcome(await resolve(resolver, root: tree.root, ["a.txt"])) == .unavailable(.assetUnavailable))
    }

    @Test func garbageBookmarkIsUnavailable() async {
        let (resolver, _) = makeResolver()
        for garbage in [Data("garbage".utf8), Data([0x00]), Data(repeating: 0xFF, count: 512)] {
            #expect(outcome(await resolver.resolve(route(bookmark: garbage, ["a.txt"]))) == .unavailable(.assetUnavailable))
        }
        #expect(throws: OwnedFileError.self) { try DirectoryBookmark.resolve(Data("garbage".utf8)) }
    }

    // Uses real bookmarks from `DirectoryBookmark.make`.
    @Test func plainBookmarkRoundTripsAndFollowsRename() async throws {
        let tree = Tree(); defer { tree.remove() }
        tree.file("css/app.css", "body{}")
        let bookmark = try DirectoryBookmark.make(for: tree.root)
        #expect(!bookmark.isEmpty && bookmark.count <= MapLocalDirectoryAction.maxBookmarkBytes)
        let resolved = try DirectoryBookmark.resolve(bookmark)
        #expect(resolved.standardizedFileURL.resolvingSymlinksInPath().path == tree.root.standardizedFileURL.resolvingSymlinksInPath().path)
        let (resolver, _) = makeResolver()
        #expect(try await served(await resolver.resolve(route(bookmark: bookmark, ["css", "app.css"]))) == Data("body{}".utf8))

        let renamed = tree.base.appendingPathComponent("renamed")
        #expect(Darwin.rename(tree.root.path, renamed.path) == 0)
        #expect(try await served(await resolver.resolve(route(bookmark: bookmark, ["css", "app.css"]))) == Data("body{}".utf8))
    }

    // A real plain (non-security-scoped) bookmark: the scoped resolution rejects it, the fallback serves it.
    @Test func plainBookmarkFallbackResolvesAndFollowsRename() async throws {
        let tree = Tree(); defer { tree.remove() }
        tree.file("index.html", "<p>plain</p>")
        let plain = try tree.root.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        let (resolver, _) = makeResolver()
        #expect(try await served(await resolver.resolve(route(bookmark: plain, []))) == Data("<p>plain</p>".utf8))
        #expect(Darwin.rename(tree.root.path, tree.base.appendingPathComponent("moved").path) == 0)
        #expect(try await served(await resolver.resolve(route(bookmark: plain, []))) == Data("<p>plain</p>".utf8))
        #expect(outcome(await resolver.resolve(route(bookmark: plain, [], servesIndex: false))) == .notFound)
    }

    // Uses real bookmarks from `DirectoryBookmark.make`.
    @Test func bookmarkMustResolveToDirectory() async throws {
        let tree = Tree(); defer { tree.remove() }
        let file = tree.file("a.txt", "a")
        let bookmark = try DirectoryBookmark.make(for: file)
        #expect(throws: OwnedFileError.self) { try DirectoryBookmark.resolve(bookmark) }
        let (resolver, _) = makeResolver()
        #expect(outcome(await resolver.resolve(route(bookmark: bookmark, []))) == .unavailable(.assetUnavailable))
    }

    // Uses real bookmarks from `DirectoryBookmark.make`.
    @Test func bookmarkedRootRemovedIsUnavailable() async throws {
        let tree = Tree(); defer { tree.remove() }
        tree.file("a.txt", "a")
        let bookmark = try DirectoryBookmark.make(for: tree.root)
        removeTree(tree.root)
        let (resolver, _) = makeResolver()
        #expect(outcome(await resolver.resolve(route(bookmark: bookmark, ["a.txt"]))) == .unavailable(.assetUnavailable))
    }

    @Test(.timeLimit(.minutes(1))) func descriptorsDoNotLeakOnFailureAndCancel() async throws {
        let tree = Tree(); defer { tree.remove() }
        tree.file("a/b/c.txt", "c")
        tree.file("a/index.html", "i")
        tree.file("big.bin", randomData(64))
        tree.directory("empty")
        tree.symlink("a/link.txt", to: "b/c.txt")
        tree.symlink("a/dirlink", to: "b")
        #expect(mkfifo(tree.root.appendingPathComponent("a/pipe").path, 0o600) == 0)
        let (resolver, _) = makeResolver(limits: RulesLimits(assetFileBytes: 32))

        // The probe sees a held lease: its descriptor is the one open file under the tree.
        let held = await resolve(resolver, root: tree.root, ["a", "b", "c.txt"])
        #expect(descriptors(under: tree.root) == 1)
        _ = outcome(held)
        #expect(descriptors(under: tree.root) == 0)

        let cases: [[String]] = [
            ["a", "b", "c.txt"], ["a"], ["a", "missing"], ["a", "b", "missing", "x"], ["a", "link.txt"],
            ["a", "dirlink", "c.txt"], ["a", "dirlink"], ["a", "pipe"], ["big.bin"], ["empty"], ["a", "b"],
            ["a", "b", "c.txt", "deeper"],
        ]
        for _ in 0..<20 {
            for segments in cases {
                _ = outcome(await resolve(resolver, root: tree.root, segments))
                _ = outcome(await resolve(resolver, root: tree.root, segments, servesIndex: false))
            }
        }
        #expect(descriptors(under: tree.root) == 0)

        // Leases dropped without cancel close on deinit; a cancelled reader closes after its read.
        for _ in 0..<20 {
            let resolution = await resolve(resolver, root: tree.root, ["a", "b", "c.txt"])
            guard case .file(let lease, _) = resolution else { Issue.record("expected a file"); return }
            _ = try await lease.read(offset: 0, maxBytes: 1)
        }
        #expect(descriptors(under: tree.root) == 0)

        // Cancelling the requesting task does not strand a descriptor.
        for _ in 0..<20 {
            let task = Task { await resolve(resolver, root: tree.root, ["a", "b", "c.txt"]) }
            task.cancel()
            _ = outcome(await task.value)
        }
        #expect(descriptors(under: tree.root) == 0)

        // A lease cancelled while a read is in flight releases once the read settles.
        let resolution = await resolve(resolver, root: tree.root, ["a", "b", "c.txt"])
        guard case .file(let lease, _) = resolution else { Issue.record("expected a file"); return }
        async let read = lease.read(offset: 0, maxBytes: 1)
        lease.cancel()
        _ = try? await read
        await #expect(throws: OwnedFileError.self) { _ = try await lease.read(offset: 0, maxBytes: 1) }
        #expect(descriptors(under: tree.root) == 0)
    }

    @Test func leaseReleaseReturnsBudget() async throws {
        let tree = Tree(); defer { tree.remove() }
        tree.file("blob.bin", randomData(3 * 65_536 + 7))
        let (resolver, budgets) = makeResolver()
        let resolution = await resolve(resolver, root: tree.root, ["blob.bin"])
        guard case .file(let lease, _) = resolution else { Issue.record("expected a file"); return }
        #expect(budgets.snapshot().reservedBytes == 0)
        let data = try await readAll(lease)
        #expect(data.count == 3 * 65_536 + 7)
        #expect(budgets.snapshot().peak[.io] == 65_536)
        lease.cancel()
        #expect(budgets.snapshot().reservedBytes == 0)
        #expect(descriptors(under: tree.root) == 0)
    }

    @Test func readFailsWhenBudgetIsExhausted() async throws {
        let tree = Tree(); defer { tree.remove() }
        tree.file("blob.bin", randomData(100))
        let limits = RulesLimits(ioChunkBytes: 64, ioBufferBytes: 64)
        let (resolver, budgets) = makeResolver(limits: limits)
        let blocker = try budgets.reserve(category: .io, bytes: 64)
        let resolution = await resolve(resolver, root: tree.root, ["blob.bin"])
        guard case .file(let lease, _) = resolution else { Issue.record("expected a file"); return }
        defer { lease.cancel() }
        await #expect(throws: OwnedFileError(.capacityExceeded)) { _ = try await lease.read(offset: 0, maxBytes: 64) }
        blocker.release()
        #expect(try await lease.read(offset: 0, maxBytes: 1000).count == 64)
    }

    @Test func assetStoreVendsOneResolverOnItsBudgets() async throws {
        let tree = Tree(); defer { tree.remove() }
        tree.file("a.txt", "hello")
        let budgets = OwnedFileBudgets(limits: RulesLimits(), freeDiskBytes: ample)
        let store = ManagedAssetStore(directory: tree.base.appendingPathComponent("assets"), limits: RulesLimits(), budgets: budgets)
        let resolver = store.directoryResolver()
        #expect(resolver === store.directoryResolver())
        let resolution = await resolver.resolve(root: tree.root, subpath: .safe(["a.txt"]), method: "GET", servesIndex: true)
        guard case .file(let lease, _) = resolution else { Issue.record("expected a file"); return }
        _ = try await lease.read(offset: 0, maxBytes: 5)
        #expect(budgets.snapshot().peak[.io] == 5)
        lease.cancel()
    }
}
