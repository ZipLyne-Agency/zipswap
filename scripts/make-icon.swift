// Renders the ZipSwap app icon into Resources/Assets.xcassets/AppIcon.appiconset.
// Usage: swift scripts/make-icon.swift
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath)
let assets = root.appendingPathComponent("Resources/Assets.xcassets")
let iconset = assets.appendingPathComponent("AppIcon.appiconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 1024
    let ctx = NSGraphicsContext.current!.cgContext

    // macOS icon grid: 824pt body centered on a 1024 canvas.
    let body = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185 * s, yRadius: 185 * s)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 28 * s, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    color(0x16181B).setFill()
    shape.fill()
    ctx.restoreGState()

    shape.addClip()
    let gradient = NSGradient(colors: [color(0x1F2226), color(0x121315)])!
    gradient.draw(in: body, angle: -90)

    // Mint tile with the two swap arrows.
    let tile = CGRect(x: 262 * s, y: 262 * s, width: 500 * s, height: 500 * s)
    color(0x7CE0B5).setFill()
    NSBezierPath(roundedRect: tile, xRadius: 130 * s, yRadius: 130 * s).fill()

    let u = 500 * s / 16
    func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: tile.minX + x * u, y: tile.maxY - y * u) }
    let arrows = NSBezierPath()
    arrows.move(to: p(3, 5.5)); arrows.line(to: p(12.5, 5.5))
    arrows.move(to: p(10, 3)); arrows.line(to: p(12.5, 5.5)); arrows.line(to: p(10, 8))
    arrows.move(to: p(13, 10.5)); arrows.line(to: p(3.5, 10.5))
    arrows.move(to: p(6, 8)); arrows.line(to: p(3.5, 10.5)); arrows.line(to: p(6, 13))
    arrows.lineWidth = 1.9 * u
    arrows.lineCapStyle = .round
    arrows.lineJoinStyle = .round
    color(0x101113).setStroke()
    arrows.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

var images: [[String: String]] = []
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try render(size * scale).write(to: iconset.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(size)x\(size)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: iconset.appendingPathComponent("Contents.json"))
try JSONSerialization.data(withJSONObject: ["info": ["author": "xcode", "version": 1]], options: .prettyPrinted)
    .write(to: assets.appendingPathComponent("Contents.json"))
print("icon written to \(iconset.path)")
