// Renders a placeholder app icon (black island on a gradient) into Resources/AppIcon.icns.
// Usage: swift scripts/make-icon.swift   (replace with a designed icon before launch)
import AppKit

let sizes = [16, 32, 64, 128, 256, 512, 1024]
let iconset = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    let inset = s * 0.1
    let body = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let bg = NSBezierPath(roundedRect: body, xRadius: body.width * 0.225, yRadius: body.width * 0.225)
    NSGradient(colors: [NSColor(calibratedRed: 0.33, green: 0.36, blue: 0.98, alpha: 1),
                        NSColor(calibratedRed: 0.75, green: 0.35, blue: 0.95, alpha: 1)])!.draw(in: bg, angle: -60)
    let pillW = body.width * 0.62, pillH = body.width * 0.2
    let pill = NSRect(x: body.midX - pillW / 2, y: body.maxY - pillH - body.height * 0.2, width: pillW, height: pillH)
    NSColor.black.setFill()
    NSBezierPath(roundedRect: pill, xRadius: pillH / 2, yRadius: pillH / 2).fill()
    NSColor.white.withAlphaComponent(0.9).setFill()
    let dot = pillH * 0.36
    NSBezierPath(ovalIn: NSRect(x: pill.maxX - pillH * 0.5 - dot / 2, y: pill.midY - dot / 2, width: dot, height: dot)).fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in sizes where size <= 512 {
    try render(size).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(size * 2).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
print(iconset.path)
