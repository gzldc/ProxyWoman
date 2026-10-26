import FlowStore
import Foundation
import Testing

@testable import AppCore

private func withStore(_ body: (FlowStore, Int) throws -> Void) rethrows {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pw-ann-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = FlowStore(bodyDirectory: directory)
    let id = store.begin { Flow(id: $0, scheme: "https", method: "GET", host: "h", port: 443, path: "/") }
    try body(store, id)
}

@Suite(.productionChinese) struct FlowAnnotationCommandsTests {
    @Test func markingWithAPresetStoresItsLightHexAsAManualMark() throws {
        try withStore { store, id in
            FlowAnnotationCommands(store: store).mark(MarkPalette.presets[0], flowID: id)
            let mark = try #require(store.flow(id)?.manualMark)
            #expect(mark.background == "#FF3B30" && mark.source == .manual && mark.text == nil)
        }
    }

    @Test func markingWithACustomHexNormalises() {
        withStore { store, id in
            #expect(FlowAnnotationCommands(store: store).markCustom(hex: "ff8000", flowID: id))
            #expect(store.flow(id)?.manualMark?.background == "#FF8000")
        }
    }

    @Test func invalidCustomHexChangesNothing() {
        withStore { store, id in
            let commands = FlowAnnotationCommands(store: store)
            commands.mark(MarkPalette.presets[1], flowID: id)
            #expect(!commands.markCustom(hex: "zzz", flowID: id))
            #expect(store.flow(id)?.manualMark?.background == "#FF9500")
        }
    }

    @Test func clearingTheManualMarkRestoresTheRuleMark() throws {
        try withStore { store, id in
            let rule = try #require(FlowMark(background: "#34C759", source: .rule(id: UUID(), name: "R")))
            store.update(id) { $0.ruleMark = rule }
            let commands = FlowAnnotationCommands(store: store)
            commands.mark(MarkPalette.presets[0], flowID: id)
            #expect(store.flow(id)?.displayMark?.background == "#FF3B30")
            commands.clearMark(flowID: id)
            let flow = try #require(store.flow(id))
            #expect(flow.manualMark == nil && flow.displayMark == rule)
        }
    }

    @Test func commentIsLimitedAndEmptyClearsIt() {
        withStore { store, id in
            let commands = FlowAnnotationCommands(store: store)
            commands.setComment(String(repeating: "a", count: 5000), flowID: id)
            #expect(store.flow(id)?.comment?.utf8.count == Flow.maxCommentBytes)
            commands.setComment("  ", flowID: id)
            #expect(store.flow(id)?.comment == nil)
            commands.setComment("x", flowID: id)
            commands.setComment(nil, flowID: id)
            #expect(store.flow(id)?.comment == nil)
        }
    }
}
