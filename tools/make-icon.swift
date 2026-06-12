// Renders AppIcon.iconset/*.png for TokenScope: a white gauge on a dark
// indigo gradient squircle, with an orange (Claude) and blue (Ollama) dot
// at the ends of the arc. Run: swift tools/make-icon.swift
import AppKit

let sizes: [(px: Int, name: String)] = [
    (16, "icon_16x16"), (32, "icon_16x16@2x"),
    (32, "icon_32x32"), (64, "icon_32x32@2x"),
    (128, "icon_128x128"), (256, "icon_128x128@2x"),
    (256, "icon_256x256"), (512, "icon_256x256@2x"),
    (512, "icon_512x512"), (1024, "icon_512x512@2x"),
]

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: s, height: s)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // Squircle background with the standard macOS icon margin.
    let inset = s * 0.09
    let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let bg = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    NSGradient(colors: [
        NSColor(calibratedRed: 0.16, green: 0.20, blue: 0.38, alpha: 1),
        NSColor(calibratedRed: 0.06, green: 0.07, blue: 0.14, alpha: 1),
    ])!.draw(in: bg, angle: -90)

    // Gauge arc, swept over the top from lower-left to lower-right.
    let center = NSPoint(x: s / 2, y: s * 0.44)
    let radius = s * 0.26
    let stroke = max(1.0, s * 0.055)
    let arc = NSBezierPath()
    arc.appendArc(withCenter: center, radius: radius, startAngle: 200, endAngle: -20, clockwise: true)
    arc.lineWidth = stroke
    arc.lineCapStyle = .round
    NSColor.white.withAlphaComponent(0.92).setStroke()
    arc.stroke()

    // Needle pointing up-right, with a hub dot.
    let angle: CGFloat = 55 * .pi / 180
    let tip = NSPoint(x: center.x + cos(angle) * radius * 0.78,
                      y: center.y + sin(angle) * radius * 0.78)
    let needle = NSBezierPath()
    needle.move(to: center)
    needle.line(to: tip)
    needle.lineWidth = stroke * 0.9
    needle.lineCapStyle = .round
    NSColor.white.setStroke()
    needle.stroke()
    let hubR = stroke * 0.95
    NSColor.white.setFill()
    NSBezierPath(ovalIn: NSRect(x: center.x - hubR, y: center.y - hubR,
                                width: hubR * 2, height: hubR * 2)).fill()

    // End dots: orange = Claude, blue = Ollama.
    func dot(_ deg: CGFloat, _ color: NSColor) {
        let a = deg * .pi / 180
        let p = NSPoint(x: center.x + cos(a) * radius, y: center.y + sin(a) * radius)
        let r = stroke * 1.05
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)).fill()
    }
    dot(200, NSColor(calibratedRed: 0.96, green: 0.58, blue: 0.20, alpha: 1))
    dot(-20, NSColor(calibratedRed: 0.35, green: 0.62, blue: 0.98, alpha: 1))

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let out = URL(fileURLWithPath: "AppIcon.iconset")
try? FileManager.default.removeItem(at: out)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for (px, name) in sizes {
    try render(px).write(to: out.appendingPathComponent("\(name).png"))
}
print("wrote \(sizes.count) PNGs to AppIcon.iconset")
