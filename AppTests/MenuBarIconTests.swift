import AppKit
import Foundation
import Testing
@testable import ProxyWoman

/// The menu bar mark comes from the app bundle's Resources; without it (`swift run`, tests) the SF Symbol label is used.
@MainActor @Suite(.productionChinese) struct MenuBarIconTests {
    private static let resources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("App/Resources", isDirectory: true)

    private static func makeBundle(copying names: [String]) throws -> Bundle {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MenuBarIconTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in names {
            try FileManager.default.copyItem(at: resources.appendingPathComponent(name),
                                             to: directory.appendingPathComponent(name))
        }
        return try #require(Bundle(path: directory.path))
    }

    @Test func missingResourceFallsBackToNil() throws {
        let bundle = try Self.makeBundle(copying: [])
        #expect(MenuBarIconImage.templateImage(bundle: bundle) == nil)
    }

    @Test func bundledResourcesLoadAsRetinaTemplate() throws {
        let bundle = try Self.makeBundle(copying: ["menubar-diamond.png", "menubar-diamond@2x.png"])
        let image = try #require(MenuBarIconImage.templateImage(bundle: bundle))
        #expect(image.isTemplate)
        #expect(image.size == NSSize(width: 18, height: 18))
        #expect(image.representations.count == 2)
        #expect(image.representations.map(\.pixelsWide).sorted() == [18, 36])
    }

    @Test func onlyThe1xResourceStillLoads() throws {
        let bundle = try Self.makeBundle(copying: ["menubar-diamond.png"])
        let image = try #require(MenuBarIconImage.templateImage(bundle: bundle))
        #expect(image.isTemplate)
        #expect(image.representations.count == 1)
    }
}
