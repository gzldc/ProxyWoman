import AppCore
import AppKit
import Localization
import SwiftUI
import Testing
@testable import ProxyWoman

/// The breakpoint editor's URL, method, status, reason and header fields are standard AppKit text fields
/// (editable, labelled, writing through their binding), like the Compose window's. Read from an
/// in-process hosting view that is never shown.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)), .productionChinese) struct BreakpointFieldRowTests {
    private final class Box {
        var text: String
        init(_ text: String) { self.text = text }
    }

    private static func fields(in view: NSView) -> [NSTextField] {
        (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap { fields(in: $0) }
    }

    private static func host<V: View>(_ view: V) -> (NSHostingView<some View>, NSWindow) {
        let host = NSHostingView(rootView: view.frame(width: 520, height: 120))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 120), styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        return (host, window)
    }

    private static func binding(_ box: Box) -> Binding<String> {
        Binding(get: { box.text }, set: { box.text = $0 })
    }

    @Test func theUrlRowIsOneEditableLabelledTextField() throws {
        let box = Box("https://a.test/")
        let (host, window) = Self.host(BreakpointFieldRow(title: "URL", text: Self.binding(box), monospaced: true))
        let editable = Self.fields(in: host).filter(\.isEditable)
        #expect(editable.count == 1)
        let field = try #require(editable.first)
        #expect(field.isEnabled)
        #expect(field.stringValue == "https://a.test/")
        // A bordered, standard text field like the Compose window's (the old grouped-form row was borderless).
        #expect(field.isBezeled)
        // Typing reaches the binding.
        #expect(window.makeFirstResponder(field))
        let editor = try #require(field.currentEditor())
        editor.selectedRange = NSRange(location: editor.string.count, length: 0)
        editor.insertText("x")
        #expect(box.text == "https://a.test/x")
    }

    @Test func aRowThatCannotBeEditedIsDisabled() throws {
        let box = Box("m")
        let (host, _) = Self.host(BreakpointFieldRow(title: "Method", text: Self.binding(box), isEditable: false))
        let field = try #require(Self.fields(in: host).first { $0.stringValue == "m" })
        #expect(!field.isEnabled)
    }

    @Test func aHeaderRowHasTwoEditableLabelledFields() throws {
        struct Harness: View {
            @State var row = HeaderFieldRow(name: "X-A", value: "1")
            var body: some View { BreakpointHeaderEditRow(row: $row) {} }
        }
        let (host, _) = Self.host(Harness())
        let editable = Self.fields(in: host).filter(\.isEditable)
        #expect(editable.count == 2)
        #expect(editable.allSatisfy { $0.isBezeled })
        #expect(editable.map(\.stringValue) == ["X-A", "1"])
    }
}
