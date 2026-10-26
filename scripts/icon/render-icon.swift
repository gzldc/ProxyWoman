// Renders the ProxyWoman app icon ("4A: diamond on a line") with CoreGraphics only.
// Usage: swift scripts/icon/render-icon.swift <outdir>
// Writes:
//   <outdir>/AppIcon.iconset/icon_{16x16,32x32,128x128,256x256,512x512}[@2x].png   (feed to `iconutil -c icns`)
//   <outdir>/brand/appicon-{light,dark,tinted}-1024.png                              (full icon with grid + shadow)
//   <outdir>/brand/layer-{background,line,diamond}.png                               (Icon Composer layers, 1024, transparent)
//   <outdir>/brand/menubar-diamond.png, menubar-diamond@2x.png                       (18pt template image, alpha only)
// Geometry lives in a 100x100 "body" space mapped onto the 824x824 body of the macOS 1024 icon grid.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Palette

func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

struct Palette {
    var backgroundTop: CGColor
    var backgroundBottom: CGColor
    var border: CGColor?
    var line: CGColor
    var diamond: CGColor

    static let light = Palette(
        backgroundTop: color(0xFFFFFF), backgroundBottom: color(0xEEF0F4),
        border: color(0xDCDFE6), line: color(0xA3A8B3), diamond: color(0xF2553D))
    static let dark = Palette(
        backgroundTop: color(0x2E2E36), backgroundBottom: color(0x16161B),
        border: nil, line: color(0xA3A8B3), diamond: color(0xF2553D))
    static let tinted = Palette(
        backgroundTop: color(0x3B404B), backgroundBottom: color(0x23272F),
        border: nil, line: color(0xC9CED8, alpha: 0.5), diamond: color(0xC9CED8))
}

// MARK: - Geometry (all of it is computed top-down, then flipped into CoreGraphics' bottom-up space)

struct Geometry {
    let size: CGFloat
    /// Body rect in top-down pixel coordinates.
    let body: CGRect
    /// Pixels per body unit (body space is 100x100).
    let unit: CGFloat
    /// Small sizes snap the body to whole pixels and drop the shadow.
    let small: Bool

    init(size: Int) {
        self.size = CGFloat(size)
        small = size <= 32
        let scale = CGFloat(size) / 1024
        if small {
            let margin = (100 * scale).rounded()
            body = CGRect(x: margin, y: margin, width: CGFloat(size) - 2 * margin, height: CGFloat(size) - 2 * margin)
        } else {
            body = CGRect(x: 100 * scale, y: 100 * scale, width: 824 * scale, height: 824 * scale)
        }
        unit = body.width / 100
    }

    var scale: CGFloat { size / 1024 }
    /// 185 px on the 824 px body of the 1024 grid.
    var cornerRadius: CGFloat { body.width * 185 / 824 }
    var borderWidth: CGFloat { small ? 1 : max(2 * scale, 1) }
    var lineWidth: CGFloat { small ? max(1, (5 * unit).rounded()) : 5 * unit }

    /// Centre of the line and the diamond, snapped so 1 px strokes stay crisp at small sizes.
    var center: CGPoint {
        var c = CGPoint(x: body.midX, y: body.midY)
        if small, Int(lineWidth) % 2 == 1 {
            c.x = c.x.rounded(.down) + 0.5
            c.y = c.y.rounded(.down) + 0.5
        }
        return c
    }

    func bodyPoint(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: body.minX + x * unit, y: body.minY + y * unit)
    }

    func flip(_ path: CGPath) -> CGPath {
        var transform = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: size)
        return path.copy(using: &transform) ?? path
    }

    /// Rounded square with continuous (squircle) corners: the Big Sur+ icon body.
    func bodyPath() -> CGPath {
        flip(continuousRoundedRect(body, radius: cornerRadius, smoothing: 0.6))
    }

    func linePath() -> CGPath {
        let path = CGMutablePath()
        let c = center
        path.move(to: CGPoint(x: bodyPoint(14, 50).x, y: c.y))
        path.addLine(to: CGPoint(x: bodyPoint(86, 50).x, y: c.y))
        return flip(path)
    }

    /// 26x26 square, corner radius 6, rotated 45 degrees about (50,50).
    func diamondPath() -> CGPath {
        diamond(side: 26 * unit, radius: 6 * unit, center: center)
    }

    func diamond(side: CGFloat, radius: CGFloat, center: CGPoint) -> CGPath {
        let rect = CGRect(x: -side / 2, y: -side / 2, width: side, height: side)
        var transform = CGAffineTransform(translationX: center.x, y: center.y).rotated(by: .pi / 4)
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: &transform)
        return flip(path)
    }
}

/// Figma-style corner smoothing: a straight edge eases into a circular arc through two cubic segments per corner.
func continuousRoundedRect(_ rect: CGRect, radius r: CGFloat, smoothing: CGFloat) -> CGPath {
    let budget = min(rect.width, rect.height) / 2
    var smoothing = smoothing
    var p = (1 + smoothing) * r
    let maxSmoothing = budget / r - 1
    if smoothing > maxSmoothing { smoothing = maxSmoothing }
    p = min(p, budget)

    let arcMeasure = 90 * (1 - smoothing) * .pi / 180            // angle of the circular part
    let arcSectionLength = sin(arcMeasure / 2) * r * 2.0.squareRoot()
    let angleAlpha = (.pi / 2 - arcMeasure) / 2
    let p3ToP4 = r * tan(angleAlpha / 2)
    let angleBeta = 45 * smoothing * .pi / 180
    let c = p3ToP4 * cos(angleBeta)
    let d = c * tan(angleBeta)
    let b = (p - arcSectionLength - c - d) / 3
    let a = 2 * b

    // Circular part approximated by one cubic Bezier.
    let kappa = 4.0 / 3.0 * tan(arcMeasure / 4)
    let startTangent = CGFloat.pi / 4 - arcMeasure / 2
    let endTangent = CGFloat.pi / 4 + arcMeasure / 2

    let path = CGMutablePath()
    // Corner frames are the top-right frame rotated clockwise by 90 degrees each.
    let starts = [
        CGPoint(x: rect.maxX - p, y: rect.minY),
        CGPoint(x: rect.maxX, y: rect.maxY - p),
        CGPoint(x: rect.minX + p, y: rect.maxY),
        CGPoint(x: rect.minX, y: rect.minY + p),
    ]
    for (index, start) in starts.enumerated() {
        func rotate(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            switch index {
            case 0: return CGPoint(x: x, y: y)
            case 1: return CGPoint(x: -y, y: x)
            case 2: return CGPoint(x: -x, y: -y)
            default: return CGPoint(x: y, y: -x)
            }
        }
        func at(_ origin: CGPoint, _ x: CGFloat, _ y: CGFloat) -> CGPoint {
            let v = rotate(x, y)
            return CGPoint(x: origin.x + v.x, y: origin.y + v.y)
        }
        if index == 0 { path.move(to: start) } else { path.addLine(to: start) }
        let p0 = start
        let p1 = at(p0, a + b + c, d)
        path.addCurve(to: p1, control1: at(p0, a, 0), control2: at(p0, a + b, 0))
        let p2 = at(p1, arcSectionLength, arcSectionLength)
        path.addCurve(
            to: p2,
            control1: at(p1, kappa * r * cos(startTangent), kappa * r * sin(startTangent)),
            control2: at(p2, -kappa * r * cos(endTangent), -kappa * r * sin(endTangent)))
        let p3 = at(p2, d, a + b + c)
        path.addCurve(to: p3, control1: at(p2, d, c), control2: at(p2, d, b + c))
    }
    path.closeSubpath()
    return path
}

// MARK: - Drawing

func makeContext(width: Int, height: Int) -> CGContext {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)
    context.interpolationQuality = .high
    return context
}

func drawGradientBackground(_ context: CGContext, _ geometry: Geometry, _ palette: Palette) {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let gradient = CGGradient(colorsSpace: space, colors: [palette.backgroundTop, palette.backgroundBottom] as CFArray,
                              locations: [0, 1])!
    // Context is bottom-up: the body's top edge has the larger y.
    let top = geometry.size - geometry.body.minY
    let bottom = geometry.size - geometry.body.maxY
    context.saveGState()
    context.addPath(geometry.bodyPath())
    context.clip()
    context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: top), end: CGPoint(x: 0, y: bottom), options: [])
    context.restoreGState()
}

func drawBorder(_ context: CGContext, _ geometry: Geometry, _ borderColor: CGColor) {
    context.saveGState()
    context.addPath(geometry.bodyPath())
    context.clip()
    context.addPath(geometry.bodyPath())
    context.setStrokeColor(borderColor)
    context.setLineWidth(geometry.borderWidth * 2)  // half of it is clipped away: the border sits inside the body
    context.strokePath()
    context.restoreGState()
}

func drawLine(_ context: CGContext, _ geometry: Geometry, _ lineColor: CGColor) {
    context.saveGState()
    context.addPath(geometry.linePath())
    context.setStrokeColor(lineColor)
    context.setLineWidth(geometry.lineWidth)
    context.setLineCap(.round)
    context.strokePath()
    context.restoreGState()
}

func drawDiamond(_ context: CGContext, _ geometry: Geometry, _ diamondColor: CGColor) {
    context.saveGState()
    context.addPath(geometry.diamondPath())
    context.setFillColor(diamondColor)
    context.fillPath()
    context.restoreGState()
}

/// Soft shadow under the body: +10 px down, 28 px blur, black 30% at 1024 (scaled with the canvas).
func drawShadow(_ context: CGContext, _ geometry: Geometry) {
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10 * geometry.scale), blur: 28 * geometry.scale,
                      color: color(0x000000, alpha: 0.30))
    context.addPath(geometry.bodyPath())
    context.setFillColor(color(0xFFFFFF))
    context.fillPath()
    context.restoreGState()
}

func renderIcon(size: Int, palette: Palette) -> CGImage {
    let geometry = Geometry(size: size)
    let context = makeContext(width: size, height: size)
    if !geometry.small { drawShadow(context, geometry) }
    drawGradientBackground(context, geometry, palette)
    if let border = palette.border { drawBorder(context, geometry, border) }
    drawLine(context, geometry, palette.line)
    drawDiamond(context, geometry, palette.diamond)
    return context.makeImage()!
}

enum Layer { case background, line, diamond }

func renderLayer(_ layer: Layer, size: Int = 1024) -> CGImage {
    let geometry = Geometry(size: size)
    let context = makeContext(width: size, height: size)
    switch layer {
    case .background: drawGradientBackground(context, geometry, .light)
    case .line: drawLine(context, geometry, Palette.light.line)
    case .diamond: drawDiamond(context, geometry, Palette.light.diamond)
    }
    return context.makeImage()!
}

/// Alpha-only menu bar mark: a diamond sitting on a short line, with a small gap so the line reads as stopped.
func renderMenuBar(pixels: Int) -> CGImage {
    let points: CGFloat = 18
    let k = CGFloat(pixels) / points
    let context = makeContext(width: pixels, height: pixels)
    let black = color(0x000000)
    let center = CGPoint(x: 9 * k, y: 9 * k)  // symmetric, so top-down or bottom-up is the same

    context.setStrokeColor(black)
    context.setLineWidth(2 * k)
    context.setLineCap(.round)
    context.move(to: CGPoint(x: 1.5 * k, y: center.y))
    context.addLine(to: CGPoint(x: 16.5 * k, y: center.y))
    context.strokePath()

    func diamond(side: CGFloat, radius: CGFloat) -> CGPath {
        let rect = CGRect(x: -side / 2, y: -side / 2, width: side, height: side)
        var transform = CGAffineTransform(translationX: center.x, y: center.y).rotated(by: .pi / 4)
        return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: &transform)
    }
    context.saveGState()
    context.setBlendMode(.clear)
    context.addPath(diamond(side: 9 * k, radius: 2.5 * k))
    context.fillPath()
    context.restoreGState()
    context.setFillColor(black)
    context.addPath(diamond(side: 7 * k, radius: 1.5 * k))
    context.fillPath()
    return context.makeImage()!
}

// MARK: - Output

func writePNG(_ image: CGImage, to url: URL, dpi: Double = 72) throws {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw CocoaError(.fileWriteUnknown)
    }
    let properties: [CFString: Any] = [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi]
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
}

func run() throws {
    let arguments = CommandLine.arguments
    guard arguments.count == 2 else {
        FileHandle.standardError.write(Data("usage: swift scripts/icon/render-icon.swift <outdir>\n".utf8))
        exit(64)
    }
    let outputRoot = URL(fileURLWithPath: arguments[1], isDirectory: true)
    let iconset = outputRoot.appendingPathComponent("AppIcon.iconset", isDirectory: true)
    let brand = outputRoot.appendingPathComponent("brand", isDirectory: true)
    let fileManager = FileManager.default
    try fileManager.createDirectory(at: iconset, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: brand, withIntermediateDirectories: true)

    let iconsetFiles: [(name: String, pixels: Int)] = [
        ("icon_16x16", 16), ("icon_16x16@2x", 32),
        ("icon_32x32", 32), ("icon_32x32@2x", 64),
        ("icon_128x128", 128), ("icon_128x128@2x", 256),
        ("icon_256x256", 256), ("icon_256x256@2x", 512),
        ("icon_512x512", 512), ("icon_512x512@2x", 1024),
    ]
    for file in iconsetFiles {
        let dpi: Double = file.name.hasSuffix("@2x") ? 144 : 72
        try writePNG(renderIcon(size: file.pixels, palette: .light),
                     to: iconset.appendingPathComponent("\(file.name).png"), dpi: dpi)
    }

    try writePNG(renderIcon(size: 1024, palette: .light), to: brand.appendingPathComponent("appicon-light-1024.png"))
    try writePNG(renderIcon(size: 1024, palette: .dark), to: brand.appendingPathComponent("appicon-dark-1024.png"))
    try writePNG(renderIcon(size: 1024, palette: .tinted), to: brand.appendingPathComponent("appicon-tinted-1024.png"))
    try writePNG(renderLayer(.background), to: brand.appendingPathComponent("layer-background.png"))
    try writePNG(renderLayer(.line), to: brand.appendingPathComponent("layer-line.png"))
    try writePNG(renderLayer(.diamond), to: brand.appendingPathComponent("layer-diamond.png"))
    try writePNG(renderMenuBar(pixels: 18), to: brand.appendingPathComponent("menubar-diamond.png"), dpi: 72)
    try writePNG(renderMenuBar(pixels: 36), to: brand.appendingPathComponent("menubar-diamond@2x.png"), dpi: 144)
    print("Rendered icons into \(outputRoot.path)")
}

do { try run() } catch {
    FileHandle.standardError.write(Data("render-icon failed: \(error)\n".utf8))
    exit(1)
}
