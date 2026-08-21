import AppKit

// Renders the DMG window background. Kept as code, like the icon, so it can be
// edited rather than hunted for inside a binary.
//
// The motif is the landing page's hero: a head-angle vector drooping past a
// dashed baseline, with a protractor scale. Faint enough to sit behind the
// icons Finder draws on top, so app, site and installer all look related.

let args = CommandLine.arguments
let outputDir = args.count > 1 ? args[1] : "build"
let version = args.count > 2 ? args[2] : ""

let paper = NSColor(srgbRed: 0.973, green: 0.968, blue: 0.957, alpha: 1)
let ink = NSColor(srgbRed: 0.24, green: 0.23, blue: 0.21, alpha: 1)
let muted = NSColor(srgbRed: 0.47, green: 0.46, blue: 0.44, alpha: 1)
let faint = NSColor(srgbRed: 0.68, green: 0.67, blue: 0.65, alpha: 1)
let rule = NSColor(srgbRed: 0.87, green: 0.86, blue: 0.84, alpha: 1)
let signal = NSColor(srgbRed: 0.09, green: 0.60, blue: 0.39, alpha: 1)

let W: CGFloat = 640
let H: CGFloat = 400
/// Finder places icon centres 170pt from the top; AppKit measures from the
/// bottom, so everything on the icon row lines up here.
let row = H - 170

func text(_ string: String, size: CGFloat, weight: NSFont.Weight, color: NSColor,
          centerX: CGFloat? = nil, x: CGFloat = 0, baseline: CGFloat,
          tracking: CGFloat = 0) {
    var attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color,
    ]
    if tracking != 0 { attrs[.kern] = tracking }
    let attributed = NSAttributedString(string: string, attributes: attrs)
    let measured = attributed.size()
    let originX = centerX.map { $0 - measured.width / 2 } ?? x
    attributed.draw(at: NSPoint(x: originX, y: baseline))
}

func drawBackground() {
    paper.setFill()
    NSRect(x: 0, y: 0, width: W, height: H).fill()

    // — the angle motif, confined to the band above the icons —
    let pivot = NSPoint(x: 58, y: H - 46)
    let drop: CGFloat = 14 * .pi / 180

    let baseline = NSBezierPath()
    baseline.move(to: pivot)
    baseline.line(to: NSPoint(x: W - 40, y: pivot.y))
    baseline.lineWidth = 1
    baseline.setLineDash([2, 5], count: 2, phase: 0)
    rule.setStroke()
    baseline.stroke()

    // Stops short of the icon row: a diagonal running through the Applications
    // folder reads as a scratch, not a motif.
    let armLength: CGFloat = 236
    let arm = NSBezierPath()
    arm.move(to: pivot)
    arm.line(to: NSPoint(
        x: pivot.x + armLength * cos(drop), y: pivot.y - armLength * sin(drop)))
    arm.lineWidth = 1.5
    arm.lineCapStyle = .round
    signal.withAlphaComponent(0.3).setStroke()
    arm.stroke()

    for degrees in stride(from: 2, through: 14, by: 2) {
        let angle = CGFloat(degrees) * .pi / 180
        let inner: CGFloat = 92, outer: CGFloat = degrees % 6 == 0 ? 104 : 99
        let tick = NSBezierPath()
        tick.move(to: NSPoint(x: pivot.x + inner * cos(angle), y: pivot.y - inner * sin(angle)))
        tick.line(to: NSPoint(x: pivot.x + outer * cos(angle), y: pivot.y - outer * sin(angle)))
        tick.lineWidth = 1
        rule.setStroke()
        tick.stroke()
    }

    let arc = NSBezierPath()
    arc.appendArc(withCenter: pivot, radius: 78, startAngle: -14, endAngle: 0)
    arc.lineWidth = 1
    signal.withAlphaComponent(0.3).setStroke()
    arc.stroke()

    text("14° below baseline", size: 10.5, weight: .regular,
         color: faint, x: pivot.x + 116, baseline: pivot.y - 34)

    // — the drag instruction —
    let arrowY = row - 4
    let from: CGFloat = 262, to: CGFloat = 378

    // Ruler ticks under the arrow: the same protractor language, and they give
    // the eye a sense of travel from one icon to the other.
    for i in 0...8 {
        let x = from + (to - from) * CGFloat(i) / 8
        let height: CGFloat = i % 4 == 0 ? 6 : 3
        let tick = NSBezierPath()
        tick.move(to: NSPoint(x: x, y: arrowY - 11))
        tick.line(to: NSPoint(x: x, y: arrowY - 11 - height))
        tick.lineWidth = 1
        signal.withAlphaComponent(0.3).setStroke()
        tick.stroke()
    }

    let shaft = NSBezierPath()
    shaft.move(to: NSPoint(x: from, y: arrowY))
    shaft.line(to: NSPoint(x: to - 11, y: arrowY))
    shaft.lineWidth = 2
    shaft.lineCapStyle = .round
    signal.setStroke()
    shaft.stroke()

    let head = NSBezierPath()
    head.move(to: NSPoint(x: to, y: arrowY))
    head.line(to: NSPoint(x: to - 13, y: arrowY + 7))
    head.line(to: NSPoint(x: to - 13, y: arrowY - 7))
    head.close()
    signal.setFill()
    head.fill()

    // — captions —
    text("Drag Posture to Applications", size: 16, weight: .semibold,
         color: ink, centerX: W / 2, baseline: 92)
    text("macOS 14 or later · Apple Silicon · motion-capable AirPods",
         size: 11.5, weight: .regular, color: muted, centerX: W / 2, baseline: 68)

    // — footer rule and metadata —
    let footer = NSBezierPath()
    footer.move(to: NSPoint(x: 40, y: 44))
    footer.line(to: NSPoint(x: W - 40, y: 44))
    footer.lineWidth = 1
    rule.setStroke()
    footer.stroke()

    text(version.isEmpty ? "POSTURE" : "POSTURE \(version)", size: 9.5,
         weight: .medium, color: faint, x: 40, baseline: 24, tracking: 1.4)
    let site = "posture.einargudni.com"
    let siteWidth = NSAttributedString(
        string: site,
        attributes: [.font: NSFont.systemFont(ofSize: 9.5, weight: .regular), .kern: 1.4]
    ).size().width
    text(site, size: 9.5, weight: .regular, color: faint,
         x: W - 40 - siteWidth, baseline: 24, tracking: 1.4)
}

func render(scale: CGFloat) -> NSBitmapImageRep? {
    guard
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(W * scale), pixelsHigh: Int(H * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    else { return nil }
    rep.size = NSSize(width: W, height: H)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    drawBackground()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

for (scale, name) in [(CGFloat(1), "background-1x.png"), (CGFloat(2), "background-2x.png")] {
    guard let rep = render(scale: scale),
          let data = rep.representation(using: .png, properties: [:])
    else { continue }
    let url = URL(fileURLWithPath: outputDir).appendingPathComponent(name)
    try data.write(to: url)
    print(url.path)
}
