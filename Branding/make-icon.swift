// Draws the MacAwake app icon and writes Resources/AppIcon.icns.
//
//   swift Branding/make-icon.swift            # from the repo root
//
// The icon is drawn with plain shapes (no SF Symbols, which Apple's licence doesn't allow in app icons):
// a latte-coloured line-art coffee cup with steam, softly glowing on an espresso-brown tile.
// The cup is centred by what it actually paints, so the artwork has equal margins on all sides.
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let work = FileManager.default.temporaryDirectory.appendingPathComponent("macawake-icon-\(getpid())")
let iconset = work.appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

let latte = color(0xF2CF9C)
let glowColor = color(0xE09A55, 0.7)

/// The tile: Apple's macOS icon grid (824 pt body on a 1024 canvas), espresso brown, with a drop shadow.
func drawBackground() {
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowBlurRadius = 28
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    color(0x432C22).setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    NSGradient(colors: [color(0x432C22), color(0x1C120E)], atLocations: [0, 1], colorSpace: .sRGB)!
        .draw(in: body, angle: -90)
    NSGraphicsContext.restoreGraphicsState()
}

/// The cup, drawn around the origin. `drawIcon` measures it and moves it to the centre.
func drawCup() {
    NSGraphicsContext.saveGraphicsState()
    let glow = NSShadow()
    glow.shadowColor = glowColor
    glow.shadowBlurRadius = 36
    glow.shadowOffset = .zero
    glow.set()
    latte.setStroke()

    // Body: slightly tapered, rounded at the bottom.
    let cup = NSBezierPath()
    cup.move(to: NSPoint(x: -170, y: 150))
    cup.line(to: NSPoint(x: 170, y: 150))
    cup.line(to: NSPoint(x: 145, y: -60))
    cup.curve(to: NSPoint(x: 60, y: -170), controlPoint1: NSPoint(x: 135, y: -130), controlPoint2: NSPoint(x: 110, y: -170))
    cup.line(to: NSPoint(x: -60, y: -170))
    cup.curve(to: NSPoint(x: -145, y: -60), controlPoint1: NSPoint(x: -110, y: -170), controlPoint2: NSPoint(x: -135, y: -130))
    cup.close()
    cup.lineWidth = 40
    cup.lineJoinStyle = .round
    cup.stroke()

    // Handle.
    let handle = NSBezierPath()
    handle.appendArc(withCenter: NSPoint(x: 175, y: 40), radius: 65, startAngle: 90, endAngle: -90, clockwise: true)
    handle.lineWidth = 36
    handle.lineCapStyle = .round
    handle.stroke()

    // Saucer, centred under the cup body.
    let saucer = NSBezierPath()
    saucer.move(to: NSPoint(x: -215, y: -180))
    saucer.line(to: NSPoint(x: 215, y: -180))
    saucer.lineWidth = 40
    saucer.lineCapStyle = .round
    saucer.stroke()

    // Steam: three short S-curves.
    for x in [-70.0, 0, 70] {
        let steam = NSBezierPath()
        steam.move(to: NSPoint(x: x, y: 210))
        steam.curve(to: NSPoint(x: x, y: 305),
                    controlPoint1: NSPoint(x: x - 32, y: 242), controlPoint2: NSPoint(x: x + 32, y: 273))
        steam.lineWidth = 30
        steam.lineCapStyle = .round
        steam.stroke()
    }
    NSGraphicsContext.restoreGraphicsState()
}

/// Bounding box of what `art` paints (alpha above 50%, so the soft glow doesn't count), in its own coordinates.
func paintedBounds(_ art: () -> Void) -> NSRect {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current!.cgContext.translateBy(x: 512, y: 512)
    art()
    NSGraphicsContext.restoreGraphicsState()
    let data = rep.bitmapData!, row = rep.bytesPerRow
    var minX = 1024, maxX = -1, minY = 1024, maxY = -1
    for y in 0..<1024 {
        for x in 0..<1024 where data[y * row + x * 4 + 3] > 127 {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        }
    }
    // Bitmap rows run top-down; drawing coordinates run bottom-up.
    return NSRect(x: minX - 512, y: 1023 - maxY - 512, width: maxX - minX + 1, height: maxY - minY + 1)
}

let cupBounds = paintedBounds(drawCup)

/// Draws the icon into a 1024×1024 coordinate space (origin bottom-left).
func drawIcon() {
    drawBackground()
    NSGraphicsContext.saveGraphicsState()
    let centre = NSAffineTransform()
    centre.translateX(by: 512 - cupBounds.midX, yBy: 512 - cupBounds.midY)
    centre.concat()
    drawCup()
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
let left = Int(512 - cupBounds.width / 2), bottom = Int(512 - cupBounds.height / 2)
print("Cup centred: margins left/right \(left), bottom/top \(bottom) (of 1024)")
print("Wrote \(out.path) and \(preview.path)")
