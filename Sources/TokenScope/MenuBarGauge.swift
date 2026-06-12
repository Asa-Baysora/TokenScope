import AppKit

/// Draws the menu-bar gauge as a NON-template NSImage so its color survives in
/// the status bar (SwiftUI `Text`/template symbols are forced monochrome there).
/// The needle sweeps up and the arc fills as utilization rises, tinted by the
/// same green→yellow→red gradient used everywhere else. `fraction == nil` means
/// "not connected": a neutral, empty gauge.
enum MenuBarGauge {
    private static let startAngle: CGFloat = 215   // lower-left
    private static let sweep: CGFloat = 250        // clockwise to lower-right

    static func image(fraction: Double?) -> NSImage {
        let size = NSSize(width: 20, height: 15)
        let img = NSImage(size: size)
        img.lockFocus()

        let center = NSPoint(x: size.width / 2, y: 4.5)
        let radius: CGFloat = 6.5
        let lineWidth: CGFloat = 2.0

        // Track (unfilled background arc).
        let track = NSBezierPath()
        track.lineWidth = lineWidth
        track.lineCapStyle = .round
        track.appendArc(withCenter: center, radius: radius,
                        startAngle: startAngle, endAngle: startAngle - sweep, clockwise: true)
        NSColor(white: 0.55, alpha: 0.45).setStroke()
        track.stroke()

        if let fraction {
            let f = CGFloat(min(max(fraction, 0), 1))
            let tint = LimitsManager.nsColor(forPercent: Double(f) * 100)
            let valueAngle = startAngle - sweep * f

            // Filled portion of the arc.
            if f > 0.001 {
                let fill = NSBezierPath()
                fill.lineWidth = lineWidth
                fill.lineCapStyle = .round
                fill.appendArc(withCenter: center, radius: radius,
                               startAngle: startAngle, endAngle: valueAngle, clockwise: true)
                tint.setStroke()
                fill.stroke()
            }

            // Needle pointing at the current level.
            let a = valueAngle * .pi / 180
            let tip = NSPoint(x: center.x + cos(a) * radius * 0.92,
                              y: center.y + sin(a) * radius * 0.92)
            let needle = NSBezierPath()
            needle.lineWidth = 1.6
            needle.lineCapStyle = .round
            needle.move(to: center)
            needle.line(to: tip)
            tint.setStroke()
            needle.stroke()

            // Hub.
            let hubR: CGFloat = 1.7
            tint.setFill()
            NSBezierPath(ovalIn: NSRect(x: center.x - hubR, y: center.y - hubR,
                                        width: hubR * 2, height: hubR * 2)).fill()
        }

        img.unlockFocus()
        img.isTemplate = false
        return img
    }
}
