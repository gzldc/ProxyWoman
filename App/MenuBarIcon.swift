import AppKit
import SwiftUI

/// The menu bar mark: the diamond-on-a-line template image shipped in the app bundle's Resources,
/// with the "network" SF Symbol as the fallback for `swift run` and tests (no bundled resources there).
@MainActor enum MenuBarIconImage {
    static let resourceName = "menubar-diamond"
    /// Menu bar template images are 18 pt; the @2x file adds the Retina representation.
    static let pointSize = NSSize(width: 18, height: 18)

    /// Loaded once for the app's lifetime; nil when the bundle has no menu bar resource.
    static let shared: NSImage? = templateImage()

    /// Nil when the 1x resource is missing from `bundle`; the image always renders as a template.
    static func templateImage(bundle: Bundle = .main) -> NSImage? {
        guard let url = bundle.url(forResource: resourceName, withExtension: "png"),
              let base = NSBitmapImageRep(data: (try? Data(contentsOf: url)) ?? Data()) else { return nil }
        let image = NSImage(size: pointSize)
        base.size = pointSize
        image.addRepresentation(base)
        if let retinaURL = bundle.url(forResource: "\(resourceName)@2x", withExtension: "png"),
           let retinaData = try? Data(contentsOf: retinaURL),
           let retina = NSBitmapImageRep(data: retinaData) {
            retina.size = pointSize
            image.addRepresentation(retina)
        }
        image.isTemplate = true
        return image
    }
}

/// Label of the app's `MenuBarExtra`; the accessibility label is the product name either way.
struct MenuBarIconLabel: View {
    var body: some View {
        if let image = MenuBarIconImage.shared {
            Image(nsImage: image)
                .accessibilityLabel(AppInfo.name)
        } else {
            Label(AppInfo.name, systemImage: "network")
        }
    }
}
