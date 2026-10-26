import FlowStore
import Foundation
import Localization
import os
import RulesEngine
import Testing

@testable import AppCore

// MARK: support

final class IDLog: Sendable {
    private let state = OSAllocatedUnfairLock<[UUID]>(initialState: [])
    var ids: [UUID] { state.withLock { $0 } }
    func add(_ ids: Set<UUID>) { state.withLock { $0.append(contentsOf: ids) } }
}

let zhLocalizer = Localizer(bundle: L10n.bundle, preferredLanguages: ["zh-Hans"])

func plainRule(_ name: String, group: UUID? = nil, order: Int = 0, enabled: Bool = true) -> Rule {
    Rule(name: name, enabled: enabled, groupID: group, order: order, actions: [RuleAction(.hide)])
}

/// Builds a real pack: each entry of `files` is imported into a scratch store and returned by one rule.
func makePackPreview(
    ruleNames: [String] = ["a"], files: [String] = [], groups: [RuleGroup] = [], extraRules: [Rule] = []
) async throws -> RulePackPreview {
    let source = RulesFixture(); defer { source.remove() }
    var rules = ruleNames.map { plainRule($0) } + extraRules
    for (index, text) in files.enumerated() {
        let asset = try await source.assets.importFile(source.sourceFile("f\(index).txt", text), displayName: "f\(index).txt")
        rules.append(
            Rule(
                name: "file\(index)", order: index,
                actions: [RuleAction(.returnFile(MapLocalAction(assetID: asset.id, status: 200, headers: [])))]))
    }
    let export = try await RulePackExporter.export(
        groups: groups, rules: rules, selection: nil, assets: source.assets, limits: RulesLimits(), appVersion: "1",
        now: Date(timeIntervalSince1970: 0))
    return try RulePackReader.inspect(export.data, limits: RulesLimits())
}

func fakePackClient(
    _ result: Result<RulePackPreview, any Error>, reads: CallCounter = CallCounter(), readGate: Gate? = nil
) -> RulePackClient {
    RulePackClient(
        read: { _ in
            reads.increment()
            await readGate?.pass()
            return try result.get()
        },
        export: { _, _, _ in throw RulePackError.nothingToExport },
        write: { _, _ in })
}

@MainActor
func loadedModel(
    _ fixture: RulesFixture, groups: [RuleGroup] = [], rules: [Rule] = [], limits: RulesLimits = RulesLimits(),
    client: RulesRepositoryClient? = nil, liveBreakpoints: Bool = false
) async throws -> RulesEditorModel {
    _ = try await fixture.repository.load()
    if !groups.isEmpty || !rules.isEmpty {
        _ = try await fixture.repository.save(groups: groups, rules: rules, expectedRevision: 0)
    }
    let model = RulesEditorModel(
        client: client ?? fixture.client(), limits: limits, liveBreakpoints: liveBreakpoints)
    await model.load()
    return model
}

/// The fixture client with counted/gated `importStream` and a record of what was discarded.
func spyClient(
    _ fixture: RulesFixture, saves: CallCounter? = nil, streams: CallCounter? = nil, streamGate: Gate? = nil,
    discarded: IDLog? = nil, failSave: (any Error)? = nil
) -> RulesRepositoryClient {
    var client = fixture.client(saves: saves)
    let importStream = client.importStream, discard = client.discardImports
    client.importStream = { size, name, read in
        streams?.increment()
        await streamGate?.pass()
        return try await importStream(size, name, read)
    }
    client.discardImports = { ids in
        discarded?.add(ids)
        await discard(ids)
    }
    if let failSave {
        client.save = { _, _, _ in throw failSave }
    }
    return client
}

@MainActor
func makeImporter(
    _ model: RulesEditorModel, _ client: RulePackClient
) -> RulePackImporter {
    RulePackImporter(model: model, client: client, localizer: zhLocalizer)
}

let packURL = URL(fileURLWithPath: "/tmp/Shared Rules.pwrules")

// MARK: tests

@MainActor @Suite(.productionChinese, .timeLimit(.minutes(1))) struct RulePackImporterTests {
    @Test func beginReadsAndShowsAPreview() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let model = try await loadedModel(fixture)
        let reads = CallCounter()
        let importer = makeImporter(model, fakePackClient(.success(try await makePackPreview(ruleNames: ["a", "b"], files: ["xyz"])), reads: reads))
        await importer.begin(file: packURL)
        guard case .preview(let preview) = importer.phase else { Issue.record("phase \(importer.phase)"); return }
        #expect(reads.value == 1)
        #expect(preview.fileName == "Shared Rules.pwrules")
        #expect(preview.groupName == "导入 · Shared Rules")
        #expect(preview.lines == ["3 条规则", "0 个分组", "1 个返回文件（共 \(RulePackPresentation.byteCount(3))）"])
        #expect(preview.warnings.isEmpty)
        #expect(preview.note.contains("导入 · Shared Rules"))
        // Nothing is copied or saved before the user confirms.
        #expect(fixture.assetFiles().isEmpty)
        #expect(model.rules.isEmpty)
    }

    @Test func previewShowsPlanCountsNotManifestCounts() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let model = try await loadedModel(fixture)
        var pack = try await makePackPreview(ruleNames: ["a", "b"])
        pack.manifest.ruleCount = 999
        pack.manifest.groupCount = 888
        pack.manifest.assetCount = 777
        let importer = makeImporter(model, fakePackClient(.success(pack)))
        await importer.begin(file: packURL)
        guard case .preview(let preview) = importer.phase else { Issue.record("phase \(importer.phase)"); return }
        #expect(preview.lines == ["2 条规则", "0 个分组"])
    }

    @Test func failedInspectionShowsTheError() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let before = [plainRule("keep")]
        let model = try await loadedModel(fixture, rules: before)
        let errors: [RulePackError] = [
            .exportTooLarge, .nothingToExport, .notAPack, .notThisFormat, .newerVersion(9), .undecodableContent,
            .tooLarge(limit: 5), .tooManyEntries, .expandedTooLarge, .assetTooLarge(limit: 5), .unsafeEntry,
            .unexpectedEntry, .duplicateEntry, .encrypted, .unsupportedCompression, .symlink, .corrupt,
            .invalidRule(index: 2), .invalidStructure, .directoryMapping, .missingAsset, .assetMismatch,
            .tooManyRules(have: 5, limit: 4), .saveFailed, .readFailed, .cancelled,
        ]
        for error in errors {
            let importer = makeImporter(model, fakePackClient(.failure(error)))
            await importer.begin(file: packURL)
            #expect(importer.phase == .failed(error))
            importer.dismiss()
            #expect(importer.phase == .idle)
        }
        // An error that is not a pack error is a read failure.
        let importer = makeImporter(model, fakePackClient(.failure(CocoaError(.fileReadNoPermission))))
        await importer.begin(file: packURL)
        #expect(importer.phase == .failed(.readFailed))
        #expect(model.rules.map(\.id) == before.map(\.id) && model.revision == 1)
    }

    @Test func farxFileIsReportedWithoutParsing() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let model = try await loadedModel(fixture)
        let reads = CallCounter()
        let importer = makeImporter(model, fakePackClient(.failure(RulePackError.corrupt), reads: reads))
        await importer.begin(file: URL(fileURLWithPath: "/tmp/rules.FARX"))
        #expect(importer.phase == .failed(.farxUnsupported))
        #expect(reads.value == 0)
    }

    @Test func importAddsAGroupAtTheTopAndNeverReplaces() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let g = RuleGroup(name: "G", order: 0)
        let existing = [plainRule("in", group: g.id, order: 0), plainRule("root", order: 1, enabled: false)]
        let model = try await loadedModel(fixture, groups: [g], rules: existing)
        let packGroup = RuleGroup(name: "PG", order: 0)
        let pack = try await makePackPreview(ruleNames: ["x"], groups: [packGroup], extraRules: [plainRule("y", group: packGroup.id)])
        let importer = makeImporter(model, fakePackClient(.success(pack)))
        await importer.begin(file: packURL)
        await importer.confirm()
        guard case .finished(let ruleCount, let groupCount, let wrapperID) = importer.phase else {
            Issue.record("phase \(importer.phase)"); return
        }
        #expect(ruleCount == 2 && groupCount == 1)
        let wrapper = try #require(model.groups.first { $0.id == wrapperID })
        #expect(wrapper.name == "导入 · Shared Rules" && !wrapper.enabled && wrapper.parentID == nil && wrapper.order == 0)
        // Existing items keep id, content and enabled state; only the root order moves down.
        let oldGroup = try #require(model.groups.first { $0.id == g.id })
        #expect(oldGroup.name == "G" && oldGroup.enabled && oldGroup.order == 1)
        for rule in existing {
            let now = try #require(model.rules.first { $0.id == rule.id })
            #expect(now.name == rule.name && now.enabled == rule.enabled && now.actions == rule.actions && now.groupID == rule.groupID)
        }
        #expect(model.rules.count == 4 && model.groups.count == 3)
        let imported = model.rules.filter { !existing.map(\.id).contains($0.id) }
        #expect(imported.count == 2)
        #expect(!imported.contains { $0.id == pack.rules[0].id })  // ids are fresh
    }

    @Test func confirmCopiesEachAssetAndSavesOnce() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let saves = CallCounter(), streams = CallCounter()
        let model = try await loadedModel(fixture, client: spyClient(fixture, saves: saves, streams: streams))
        let before = saves.value
        let importer = makeImporter(model, fakePackClient(.success(try await makePackPreview(ruleNames: [], files: ["one", "twotwo"]))))
        await importer.begin(file: packURL)
        await importer.confirm()
        guard case .finished = importer.phase else { Issue.record("phase \(importer.phase)"); return }
        #expect(saves.value - before == 1)
        #expect(streams.value == 2)
        #expect(fixture.assetFiles().count == 2)
        for rule in model.rules {
            guard case .returnFile(let local)? = rule.actions.first?.kind else { Issue.record("no file action"); continue }
            #expect(model.knownAssets[local.assetID] != nil)
        }
        #expect(Set(model.knownAssets.values.map(\.size)) == [3, 6])
    }

    @Test func cancelDiscardsDraftAssets() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let discarded = IDLog(), saves = CallCounter()
        let gate = Gate(passFirst: 1)
        let existing = [plainRule("keep")]
        let model = try await loadedModel(
            fixture, rules: existing, client: spyClient(fixture, saves: saves, streamGate: gate, discarded: discarded))
        let before = saves.value
        let importer = makeImporter(model, fakePackClient(.success(try await makePackPreview(ruleNames: [], files: ["one", "two", "three"]))))
        await importer.begin(file: packURL)
        let running = Task { await importer.confirm() }
        await gate.arrived()  // the first file is copied, the second waits
        importer.cancel()
        #expect(importer.phase == .idle)
        await gate.open()
        await running.value
        #expect(importer.phase == .idle)
        #expect(!discarded.ids.isEmpty)
        #expect(saves.value == before)
        #expect(model.rules.map(\.id) == existing.map(\.id))
        #expect(fixture.assetFiles().isEmpty)  // no orphan
        #expect(model.canMutate)
    }

    @Test func saveConflictDiscardsAssetsAndReportsSaveFailed() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let discarded = IDLog()
        let existing = [plainRule("keep")]
        let model = try await loadedModel(
            fixture, rules: existing,
            client: spyClient(fixture, discarded: discarded, failSave: RuleRepositoryError.conflict(current: RuleSnapshot(revision: 1, groups: [], rules: []))))
        let importer = makeImporter(model, fakePackClient(.success(try await makePackPreview(ruleNames: [], files: ["one", "two"]))))
        await importer.begin(file: packURL)
        await importer.confirm()
        #expect(importer.phase == .failed(.saveFailed))
        #expect(discarded.ids.count == 2)
        #expect(model.rules.map(\.id) == existing.map(\.id))
    }

    @Test func savingTooManyRulesIsRefusedWithCounts() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        var limits = RulesLimits(); limits.ruleCount = 3
        let streams = CallCounter()
        let model = try await loadedModel(
            fixture, rules: [plainRule("a"), plainRule("b", order: 1)], limits: limits,
            client: spyClient(fixture, streams: streams))
        let importer = makeImporter(model, fakePackClient(.success(try await makePackPreview(ruleNames: ["x", "y"]))))
        await importer.begin(file: packURL)
        #expect(importer.phase == .failed(.tooManyRules(have: 4, limit: 3)))
        #expect(streams.value == 0 && model.rules.count == 2)
    }

    @Test func tooManyRulesAtConfirmCopiesNothing() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        var limits = RulesLimits(); limits.ruleCount = 3
        let streams = CallCounter()
        let model = try await loadedModel(fixture, rules: [plainRule("a")], limits: limits, client: spyClient(fixture, streams: streams))
        let importer = makeImporter(model, fakePackClient(.success(try await makePackPreview(ruleNames: [], files: ["one", "two"]))))
        await importer.begin(file: packURL)
        guard case .preview = importer.phase else { Issue.record("phase \(importer.phase)"); return }
        #expect(await model.commitNewRule(plainRule("new"), inParent: nil))  // the list grew while the sheet was open
        await importer.confirm()
        #expect(importer.phase == .failed(.tooManyRules(have: 4, limit: 3)))
        #expect(streams.value == 0 && fixture.assetFiles().isEmpty)
        #expect(model.canMutate)
    }

    @Test func beginIsIgnoredUnlessIdle() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let model = try await loadedModel(fixture)
        let reads = CallCounter()
        let importer = makeImporter(model, fakePackClient(.success(try await makePackPreview()), reads: reads))
        await importer.begin(file: packURL)
        let shown = importer.phase
        await importer.begin(file: URL(fileURLWithPath: "/tmp/Other.pwrules"))
        #expect(importer.phase == shown && reads.value == 1)
    }

    @Test func importIsRefusedWhileBusyOrUnloaded() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let reads = CallCounter()
        let pack = try await makePackPreview()
        let unloaded = RulesEditorModel(client: fixture.client(), limits: RulesLimits())
        let a = makeImporter(unloaded, fakePackClient(.success(pack), reads: reads))
        await a.begin(file: packURL)
        #expect(a.phase == .idle)

        let model = try await loadedModel(fixture)
        let b = makeImporter(model, fakePackClient(.success(pack), reads: reads))
        model.isBusy = true
        await b.begin(file: packURL)
        #expect(b.phase == .idle && reads.value == 0)
        model.endBusy()
        await b.begin(file: packURL)
        guard case .preview = b.phase else { Issue.record("phase \(b.phase)"); return }
        model.isBusy = true
        await b.confirm()
        guard case .preview = b.phase else { Issue.record("phase \(b.phase)"); return }
        model.endBusy()
    }

    @Test func pendingEditorDraftIsUntouched() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let model = try await loadedModel(fixture, rules: [plainRule("keep")])
        model.beginDraft(kind: .rewriteStatus)
        let draft = try #require(model.draft)
        let importer = makeImporter(model, fakePackClient(.success(try await makePackPreview())))
        await importer.begin(file: packURL)
        await importer.confirm()
        guard case .finished = importer.phase else { Issue.record("phase \(importer.phase)"); return }
        #expect(model.draft == draft)
    }

    @Test func cancelWhileReadingIgnoresTheLateResult() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let model = try await loadedModel(fixture)
        let gate = Gate()
        let importer = makeImporter(model, fakePackClient(.success(try await makePackPreview()), readGate: gate))
        let running = Task { await importer.begin(file: packURL) }
        await gate.arrived()
        #expect(importer.phase == .reading(fileName: "Shared Rules.pwrules"))
        importer.cancel()
        await gate.open()
        await running.value
        #expect(importer.phase == .idle)
    }

    @Test func breakpointRulesAreDisabledWhenBreakpointsAreNotLive() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let model = try await loadedModel(fixture)
        let pack = try await makePackPreview(ruleNames: [], extraRules: [
            Rule(name: "bp", actions: [RuleAction(.breakpoint(direction: .request, mode: .headers))])
        ])
        let importer = makeImporter(model, fakePackClient(.success(pack)))
        await importer.begin(file: packURL)
        guard case .preview(let preview) = importer.phase else { Issue.record("phase \(importer.phase)"); return }
        #expect(preview.warnings == ["有 1 条含断点的规则将被停用（断点窗口尚不可用）"])
        await importer.confirm()
        #expect(model.rules.allSatisfy { !$0.enabled })
    }

    @Test func editorStaysBusyUntilPostSaveWorkEnds() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        var client = fixture.client()
        let gate = Gate()
        let lookup = client.asset
        client.asset = { id in
            await gate.pass()
            return await lookup(id)
        }
        let model = try await loadedModel(fixture, client: client)
        let importer = makeImporter(model, fakePackClient(.success(try await makePackPreview(ruleNames: [], files: ["one"]))))
        await importer.begin(file: packURL)
        let running = Task { await importer.confirm() }
        await gate.arrived()  // saved; the importer is refreshing asset metadata
        #expect(!model.canMutate)
        #expect(await model.commitNewRule(plainRule("late"), inParent: nil) == false)
        #expect(model.isBusy)
        await gate.open()
        await running.value
        #expect(model.canMutate && !model.isBusy)
    }

    @Test func editorStaysBusyWhileFailedImportCleansUp() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        var client = spyClient(
            fixture, failSave: RuleRepositoryError.conflict(current: RuleSnapshot(revision: 1, groups: [], rules: [])))
        let gate = Gate()
        let discard = client.discardImports
        client.discardImports = { ids in
            await gate.pass()
            await discard(ids)
        }
        let model = try await loadedModel(fixture, client: client)
        let importer = makeImporter(model, fakePackClient(.success(try await makePackPreview(ruleNames: [], files: ["one"]))))
        await importer.begin(file: packURL)
        let running = Task { await importer.confirm() }
        await gate.arrived()
        #expect(!model.canMutate && model.isBusy)
        await gate.open()
        await running.value
        #expect(importer.phase == .failed(.saveFailed))
        #expect(!model.isBusy)
        #expect(fixture.assetFiles().isEmpty)
    }

    @Test func beginAfterCancelWorksOnceConfirmUnwound() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let gate = Gate(passFirst: 1)
        let model = try await loadedModel(fixture, client: spyClient(fixture, streamGate: gate))
        let pack = try await makePackPreview(ruleNames: [], files: ["one", "two"])
        let importer = makeImporter(model, fakePackClient(.success(pack)))
        await importer.begin(file: packURL)
        let running = Task { await importer.confirm() }
        await gate.arrived()
        importer.cancel()
        await importer.begin(file: packURL)  // still unwinding: ignored
        #expect(importer.phase == .idle)
        await gate.open()
        await running.value
        await importer.begin(file: packURL)
        guard case .preview = importer.phase else { Issue.record("phase \(importer.phase)"); return }
    }
}
