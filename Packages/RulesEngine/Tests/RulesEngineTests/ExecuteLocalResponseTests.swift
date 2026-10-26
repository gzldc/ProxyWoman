import FlowStore
import Foundation
import Testing

@testable import RulesEngine

private func header(_ name: String, _ value: String) -> HeaderField { HeaderField(name: name, value: value) }
private func row(_ field: ConditionField, _ op: ConditionOperator = .equals, _ value: String) -> ConditionRow {
    ConditionRow(field: field, op: op, value: value)
}
private let markRed = ActionKind.mark(MarkAction(background: "#FF3B30"))
private func codes(_ evaluation: ExecuteEvaluation, of rule: Rule) -> [RuleOutcomeCode] {
    (evaluation.matches?.outcomes ?? []).filter { $0.ruleID == rule.id }.map(\.code)
}
private func status(_ head: HTTPMessageHead?) -> Int? {
    if case .response(let status, _, _)? = head { return status }
    return nil
}

/// A directory tree under a temporary root, and a Return File (directory) rule serving it under `/static/`.
private struct DirectoryFixture {
    var root: URL
    var served: URL
    var assets: AssetFixture

    static func make() async throws -> DirectoryFixture {
        let assets = try await AssetFixture.make(Data("unused".utf8))
        let served = assets.root.appendingPathComponent("site")
        try FileManager.default.createDirectory(at: served, withIntermediateDirectories: true)
        writeFile(served.appendingPathComponent("index.html"), Data("<h1>home</h1>".utf8))
        writeFile(served.appendingPathComponent("app.css"), Data("body{}".utf8))
        return DirectoryFixture(root: assets.root, served: served, assets: assets)
    }

    func rule(missing: MissingFilePolicy = .notFound, headers: [HeaderField] = []) throws -> Rule {
        let action = MapLocalDirectoryAction(
            bookmark: try DirectoryBookmark.make(for: served), displayName: "site", servesIndex: true, missing: missing,
            headers: headers)
        return ExecuteFixtures.rule("dir", .returnDirectory(action, pathPrefix: "/static/"))
    }

    func evaluate(_ flow: Flow, _ snapshot: RuleSnapshot) async throws -> ExecuteEvaluation {
        try await ExecuteEngine.evaluate(
            flow, snapshot: snapshot, environment: ExecuteFixtures.environment(assets: assets.store))
    }

    func remove() { assets.remove() }
}

@Suite("ExecuteEngine local responses")
struct ExecuteLocalResponseTests {
    @Test func returnFileReadsTheAssetWithStatusAndHeaders() async throws {
        let assets = try await AssetFixture.make(Data("{\"ok\":true}".utf8))
        defer { assets.remove() }
        let file = ExecuteFixtures.rule(
            "file",
            .returnFile(
                MapLocalAction(
                    assetID: assets.id, status: 201,
                    headers: [header("Content-Type", "application/json"), header("Content-Length", "999")])))
        let evaluation = try await ExecuteEngine.evaluate(
            ExecuteFixtures.flow(), snapshot: ExecuteFixtures.snapshot(file),
            environment: ExecuteFixtures.environment(assets: assets.store))
        #expect(
            evaluation.local
                == LocalResponse(
                    status: 201, reason: nil,
                    headers: [header("Content-Type", "application/json"), header("Content-Length", "11")],
                    body: Data("{\"ok\":true}".utf8)))
        #expect(status(evaluation.response?.effectiveHead) == 201)
        #expect(codes(evaluation, of: file) == [.applied])
    }

    @Test func returnFileOverTheCapIsRejected() async throws {
        let limits = RulesLimits(rewriteBodyBytes: 8)
        let assets = try await AssetFixture.make(Data("more than eight bytes".utf8), limits: limits)
        defer { assets.remove() }
        let file = ExecuteFixtures.rule("file", .returnFile(MapLocalAction(assetID: assets.id, headers: [])))
        let response = ExecuteFixtures.rule("response", rows: [row(.statusCode, .equals, "200")], markRed)
        let done = ExecuteFixtures.rule("done", rows: [row(.durationMs, .greaterOrEqual, "0")], .hide)
        // The response rule sits above the file rule so the cut does not hide it; it must still not run.
        let evaluation = try await ExecuteEngine.evaluate(
            ExecuteFixtures.flow(), snapshot: ExecuteFixtures.snapshot(response, done, file),
            environment: ExecuteFixtures.environment(assets: assets.store, limits: limits))
        #expect(evaluation.local == nil)
        #expect(evaluation.response == nil)
        #expect(codes(evaluation, of: file) == [.rejected])
        #expect(codes(evaluation, of: response).isEmpty)
        #expect(evaluation.annotations == [.hide])
    }

    @Test func missingAssetIsRejected() async throws {
        let file = ExecuteFixtures.rule("file", .returnFile(MapLocalAction(assetID: UUID(), headers: [])))
        let evaluation = try await ExecuteEngine.evaluate(
            ExecuteFixtures.flow(), snapshot: ExecuteFixtures.snapshot(file), environment: ExecuteFixtures.environment())
        #expect(evaluation.local == nil)
        #expect(evaluation.response == nil)
        #expect(codes(evaluation, of: file) == [.rejected])
    }

    @Test func directoryServesIndexAndContentType() async throws {
        let tree = try await DirectoryFixture.make()
        defer { tree.remove() }
        let index = try await tree.evaluate(
            ExecuteFixtures.flow(path: "/static/"), ExecuteFixtures.snapshot(try tree.rule(headers: [header("X-Dir", "1")])))
        #expect(index.local?.status == 200)
        #expect(index.local?.body == Data("<h1>home</h1>".utf8))
        #expect(
            index.local?.headers
                == [
                    header("Content-Type", MIMETypes.contentType(forFileName: "index.html")), header("X-Dir", "1"),
                    header("Content-Length", "13"),
                ])

        // A Content-Type of the action wins over the file's.
        let css = try await tree.evaluate(
            ExecuteFixtures.flow(path: "/static/app.css"),
            ExecuteFixtures.snapshot(try tree.rule(headers: [header("Content-Type", "text/x-mine")])))
        #expect(css.local?.headers == [header("Content-Type", "text/x-mine"), header("Content-Length", "6")])
        #expect(css.local?.body == Data("body{}".utf8))
    }

    @Test func directoryMissingWithNetworkPolicyFallsBackToTheOriginalResponse() async throws {
        let tree = try await DirectoryFixture.make()
        defer { tree.remove() }
        let move = ExecuteFixtures.rule(
            "move", .mapRemote(MapRemoteAction(targetScheme: "https", targetHost: "b.test", targetPort: 443, path: .preserve)))
        let directory = try tree.rule(missing: .network)
        let originRule = ExecuteFixtures.rule(
            "origin", .editHeaders(direction: .response, operations: [.set(name: "X-O", value: "1")]))
        let evaluation = try await tree.evaluate(
            ExecuteFixtures.flow(path: "/static/missing.txt", status: 203), ExecuteFixtures.snapshot(originRule, move, directory))
        #expect(evaluation.local == nil)
        #expect(status(evaluation.response?.effectiveHead) == 203)
        #expect(evaluation.response?.effectiveHead.headers.contains(header("X-O", "1")) == true)
        guard case .remote(let remote)? = evaluation.request?.route else {
            Issue.record("expected the Map Remote route, got \(String(describing: evaluation.request?.route))")
            return
        }
        #expect(remote.targetHost == "b.test")

        // Without a Map Remote before it the request goes on unchanged.
        let plain = try await tree.evaluate(
            ExecuteFixtures.flow(path: "/static/missing.txt", status: 203), ExecuteFixtures.snapshot(directory))
        #expect(plain.request?.route == .original)
        #expect(status(plain.response?.effectiveHead) == 203)
    }

    @Test func directoryMissingWithNotFoundPolicyIs404() async throws {
        let tree = try await DirectoryFixture.make()
        defer { tree.remove() }
        let evaluation = try await tree.evaluate(
            ExecuteFixtures.flow(path: "/static/missing.txt"), ExecuteFixtures.snapshot(try tree.rule()))
        #expect(
            evaluation.local
                == LocalResponse(
                    status: 404, reason: nil,
                    headers: [header("X-ProxyWoman-Map-Local", "not-found"), header("Content-Length", "0")], body: Data()))
        #expect(status(evaluation.response?.effectiveHead) == 404)
    }

    @Test func directoryUnsafePathIs404() async throws {
        let tree = try await DirectoryFixture.make()
        defer { tree.remove() }
        // Even with the network policy an unsafe path never reaches the network.
        let evaluation = try await tree.evaluate(
            ExecuteFixtures.flow(path: "/static/../secret"), ExecuteFixtures.snapshot(try tree.rule(missing: .network)))
        #expect(evaluation.local?.status == 404)
        #expect(evaluation.local?.headers.first == header("X-ProxyWoman-Map-Local", "not-found"))
    }

    @Test func directoryMethodNotAllowedIs405() async throws {
        let tree = try await DirectoryFixture.make()
        defer { tree.remove() }
        let evaluation = try await tree.evaluate(
            ExecuteFixtures.flow(method: "POST", path: "/static/app.css"), ExecuteFixtures.snapshot(try tree.rule()))
        #expect(
            evaluation.local
                == LocalResponse(
                    status: 405, reason: nil,
                    headers: [
                        header("Allow", "GET, HEAD"), header("X-ProxyWoman-Map-Local", "method-not-allowed"),
                        header("Content-Length", "0"),
                    ], body: Data()))
    }

    @Test func cancelledReadReleasesTheLease() async throws {
        let limits = RulesLimits(ioChunkBytes: 4)
        let assets = try await AssetFixture.make(Data("sixteen bytes!!!".utf8), limits: limits)
        defer { assets.remove() }
        let lease = try await assets.store.lease(assets.id)
        let task = Task {
            // Cancelled before the first chunk: nothing is read and the lease goes.
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ExecuteEngine.readLease(lease, cap: 1_024)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        await #expect(throws: OwnedFileError(.cancelled)) { try await lease.read(offset: 0, maxBytes: 4) }

        // The engine itself stops with a CancellationError. (A cancel landing between two chunks of one read is
        // not exercised: the lease's file queue offers no deterministic seam for it.)
        let file = ExecuteFixtures.rule("file", .returnFile(MapLocalAction(assetID: assets.id, headers: [])))
        let run = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ExecuteEngine.evaluate(
                ExecuteFixtures.flow(), snapshot: ExecuteFixtures.snapshot(file),
                environment: ExecuteFixtures.environment(assets: assets.store, limits: limits))
        }
        await #expect(throws: CancellationError.self) { try await run.value }

        // Uncancelled, the same lease reads in chunks of `ioChunkBytes`.
        let fresh = try await assets.store.lease(assets.id)
        let whole = try await ExecuteEngine.readLease(fresh, cap: 1_024, chunkBytes: limits.ioChunkBytes)
        #expect(whole == .data(Data("sixteen bytes!!!".utf8)))
        await #expect(throws: OwnedFileError(.cancelled)) { try await fresh.read(offset: 0, maxBytes: 4) }
    }
}
