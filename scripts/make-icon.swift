import AppKit

// Renders Posture.icns from scratch so the icon lives in version control as
// code rather than as an opaque binary nobody can edit.

let outputDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build"

let top = NSColor(srgbRed: 0.20, green: 0.78, blue: 0.53, alpha: 1)
let bottom = NSColor(srgbRed: 0.02, green: 0.55, blue: 0.42, alpha: 1)

func render(size: CGFloat) -> NSImage {
    NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
        let rect = NSRect(x: 0, y: 0, width: size, height: size)

        // macOS does not mask app icons, so the squircle is drawn in.
        // 22.37% is Apple's continuous-corner ratio for macOS icons.
        let squircle = NSBezierPath(
            roundedRect: rect.insetBy(dx: size * 0.06, dy: size * 0.06),
            xRadius: size * 0.2237, yRadius: size * 0.2237)
        squircle.addClip()
        NSGradient(starting: top, ending: bottom)?.draw(in: rect, angle: -90)

        guard
            let symbol = NSImage(
                systemSymbolName: "figure.stand", accessibilityDescription: nil)
        else { return true }

        let glyphHeight = size * 0.52
        let aspect = symbol.size.width / symbol.size.height
        let glyph = NSRect(
            x: (size - glyphHeight * aspect) / 2,
            y: (size - glyphHeight) / 2,
            width: glyphHeight * aspect,
            height: glyphHeight)

        // Mask white through the symbol's alpha — drawing a template image
        // directly ignores the fill colour.
        NSImage(size: glyph.size, flipped: false) { inner in
            NSColor.white.setFill()
            inner.fill()
            symbol.draw(in: inner, from: .zero, operation: .destinationIn, fraction: 1)
            return true
        }
        .draw(in: glyph, from: .zero, operation: .sourceOver, fraction: 1)

        return true
    }
}

func write(_ image: NSImage, to url: URL, pixels: Int) throws {
    guard
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    else { return }
    rep.size = NSSize(width: pixels, height: pixels)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(
        in: NSRect(x: 0, y: 0, width: pixels, height: pixels),
        from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()

    guard let data = rep.representation(using: .png, properties: [:]) else { return }
    try data.write(to: url)
}

let iconset = URL(fileURLWithPath: outputDir).appendingPathComponent("Posture.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = base * scale
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try write(
            render(size: CGFloat(pixels)), to: iconset.appendingPathComponent(name),
            pixels: pixels)
    }
}

print(iconset.path)
