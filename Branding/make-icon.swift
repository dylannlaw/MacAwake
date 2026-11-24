// Draws the MacAwake app icon and writes Resources/AppIcon.icns.
//
//   swift Branding/make-icon.swift            # from the repo root
//
// The icon is drawn with plain shapes (no SF Symbols, which Apple's licence doesn't allow in app icons):
// a night-to-sunrise gradient, a steaming coffee cup and a small crescent moon.
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let work = FileManager.default.temporaryDirectory.appendingPathComponent("macawake-icon-\(getpid())")
let iconset = work.appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

/// Draws the icon into a 1024×1024 coordinate space (origin bottom-left).
func drawIcon() {
    // Base squircle, inset like Apple's macOS icon grid (824 pt body on a 1024 canvas).
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = 28
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    color(0x1B2163).setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Night sky at the top, sunrise at the bottom.
    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    NSGradient(colors: [color(0x141A52), color(0x3B3FA8), color(0xC2618A), color(0xFF9A4D)],
               atLocations: [0, 0.38, 0.72, 1], colorSpace: .sRGB)!
        .draw(in: body, angle: -90)

    // A few stars.
    for (x, y, r) in [(215.0, 790.0, 7.0), (300, 870, 5), (280, 700, 4), (190, 620, 4), (600, 885, 5)] {
        color(0xFFFFFF, 0.75).setFill()
        NSBezierPath(ovalIn: NSRect(x: x - r, y: y - r, width: r * 2, height: r * 2)).fill()
    }

    // Crescent moon, top right.
    // Clip out the "bite" circle, then fill the full disc, leaving a crescent.
    NSGraphicsContext.saveGraphicsState()
    let bite = NSBezierPath(rect: body)
    bite.append(NSBezierPath(ovalIn: NSRect(x: 698, y: 738, width: 138, height: 138)))
    bite.windingRule = .evenOdd
    bite.addClip()
    color(0xFFE9A8).setFill()
    NSBezierPath(ovalIn: NSRect(x: 650, y: 700, width: 150, height: 150)).fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.restoreGraphicsState()

    let white = color(0xFFFFFF)

    // The cup is drawn in its own coordinates below, then shifted so that the cup unit
    // (saucer, body, rim and handle; steam excluded) is centred on the canvas.
    // Unit bounds in those coordinates: x 274.5...744.5 (saucer; the handle reaches 719), y 262...620 (saucer to rim).
    NSGraphicsContext.saveGraphicsState()
    let centre = NSAffineTransform()
    centre.translateX(by: 512 - (274.5 + 744.5) / 2, yBy: 512 - (262 + 620) / 2)
    centre.concat()

    // Saucer, centred under the cup and handle together.
    white.withAlphaComponent(0.92).setFill()
    NSBezierPath(roundedRect: NSRect(x: 274.5, y: 262, width: 470, height: 42), xRadius: 21, yRadius: 21).fill()

    // Cup body: slightly tapered, rounded at the bottom.
    let cup = NSBezierPath()
    cup.move(to: NSPoint(x: 300, y: 600))
    cup.line(to: NSPoint(x: 640, y: 600))
    cup.line(to: NSPoint(x: 615, y: 400))
    cup.curve(to: NSPoint(x: 520, y: 318), controlPoint1: NSPoint(x: 605, y: 345), controlPoint2: NSPoint(x: 570, y: 318))
    cup.line(to: NSPoint(x: 420, y: 318))
    cup.curve(to: NSPoint(x: 325, y: 400), controlPoint1: NSPoint(x: 370, y: 318), controlPoint2: NSPoint(x: 335, y: 345))
    cup.close()
    white.setFill()
    cup.fill()

    // Rim and coffee surface.
    NSBezierPath(ovalIn: NSRect(x: 300, y: 580, width: 340, height: 40)).fill()
    color(0x6B3A2A).setFill()
    NSBezierPath(ovalIn: NSRect(x: 322, y: 588, width: 296, height: 26)).fill()

    // Handle.
    let handle = NSBezierPath()
    handle.appendArc(withCenter: NSPoint(x: 640, y: 490), radius: 62, startAngle: 90, endAngle: -90, clockwise: true)
    handle.lineWidth = 34
    handle.lineCapStyle = .round
    white.setStroke()
    handle.stroke()

    // Steam: three soft S-curves.
    for (i, x) in [395.0, 470, 545].enumerated() {
        let steam = NSBezierPath()
        let base = 640.0 + Double(i % 2) * 18
        steam.move(to: NSPoint(x: x, y: base))
        steam.curve(to: NSPoint(x: x, y: base + 120),
                    controlPoint1: NSPoint(x: x - 40, y: base + 40), controlPoint2: NSPoint(x: x + 40, y: base + 80))
        steam.lineWidth = 24
        steam.lineCapStyle = .round
        white.withAlphaComponent(0.8).setStroke()
        steam.stroke()
    }
    NSGraphicsContext.restoreGraphicsState()
}

func render(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    ctx.imageInterpolation = .high
    let scale = CGFloat(pixels) / 1024
    ctx.cgContext.scaleBy(x: scale, y: scale)
    drawIcon()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try render(pixels: size).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(pixels: size * 2).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
let preview = root.appendingPathComponent("Branding/AppIcon-1024.png")
try render(pixels: 1024).write(to: preview)

let out = root.appendingPathComponent("Resources/AppIcon.icns")
try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try p.run()
p.waitUntilExit()
try? FileManager.default.removeItem(at: work)
guard p.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Wrote \(out.path) and \(preview.path)")
