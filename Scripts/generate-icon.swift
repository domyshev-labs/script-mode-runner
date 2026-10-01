import AppKit
import Foundation

// Draw vector geometry at every icon size to keep small Finder icons sharp.
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let variants = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]
for (points, scale) in variants {
    let pixels = points * scale
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                  isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let transform = AffineTransform(scale: CGFloat(pixels) / 1024)
    (transform as NSAffineTransform).concat()
    let tile = NSBezierPath(roundedRect: NSRect(x: 80, y: 80, width: 864, height: 864), xRadius: 190, yRadius: 190)
    NSGradient(starting: NSColor(calibratedRed: 0.18, green: 0.23, blue: 0.31, alpha: 1),
               ending: NSColor(calibratedRed: 0.06, green: 0.09, blue: 0.15, alpha: 1))!.draw(in: tile, angle: -90)
    NSColor.white.withAlphaComponent(0.16).setStroke()
    tile.lineWidth = 8
    tile.stroke()
    let prompt = NSBezierPath()
    prompt.move(to: NSPoint(x: 265, y: 625))
    prompt.line(to: NSPoint(x: 415, y: 505))
    prompt.line(to: NSPoint(x: 265, y: 385))
    prompt.lineWidth = 58
    prompt.lineCapStyle = .round
    prompt.lineJoinStyle = .round
    NSColor(calibratedWhite: 0.95, alpha: 1).setStroke()
    prompt.stroke()
    let cursor = NSBezierPath()
    cursor.move(to: NSPoint(x: 485, y: 385))
    cursor.line(to: NSPoint(x: 650, y: 385))
    cursor.lineWidth = 58
    cursor.lineCapStyle = .round
    cursor.stroke()
    let indicator = NSBezierPath(ovalIn: NSRect(x: 695, y: 665, width: 100, height: 100))
    NSColor(calibratedRed: 0.25, green: 0.88, blue: 0.48, alpha: 1).setFill()
    indicator.fill()
    NSGraphicsContext.restoreGraphicsState()
    let suffix = scale == 2 ? "@2x" : ""
    let filename = "icon_\(points)x\(points)\(suffix).png"
    try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(filename))
}
