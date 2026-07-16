import SwiftUI
import AppKit

/// Headless render of the menu for development: `TokenScope --snapshot out.png`
/// starts the real services, lets them populate, and writes the menu as a PNG.
enum Snapshot {
    @MainActor
    static func run(path: String) {
        // Let snapshots exercise specific UI states, e.g.:
        //   SNAPSHOT_PERIOD=month SNAPSHOT_HIDE_WEEKENDS=1 TokenScope --snapshot out.png
        let env = ProcessInfo.processInfo.environment
        if let p = env["SNAPSHOT_PERIOD"] { UserDefaults.standard.set(p, forKey: "StatsPeriod") }
        if let w = env["SNAPSHOT_HIDE_WEEKENDS"] { UserDefaults.standard.set(w == "1", forKey: "HideWeekends") }
        if let s = env["SNAPSHOT_BAR_STYLE"] { UserDefaults.standard.set(s, forKey: "BarChartStyle") }
        if let c = env["SNAPSHOT_INCLUDE_CACHE"] { UserDefaults.standard.set(c == "1", forKey: "ChartIncludeCache") }
        if let t = env["SNAPSHOT_TAB"] { UserDefaults.standard.set(t, forKey: "ActiveTab") }
        // Custom provider colors so snapshots can verify the palette drives the
        // heatmap/bars/marks (the bare binary otherwise renders defaults).
        if let c = env["SNAPSHOT_PROVIDER_CLAUDE"] { UserDefaults.standard.set(c, forKey: "ProviderColorClaude") }
        if let c = env["SNAPSHOT_PROVIDER_CODEX"] { UserDefaults.standard.set(c, forKey: "ProviderColorCodex") }
        if let c = env["SNAPSHOT_PROVIDER_OLLAMA"] { UserDefaults.standard.set(c, forKey: "ProviderColorOllama") }
        let dark = env["SNAPSHOT_APPEARANCE"] == "dark"
        let limitFixture = snapshotLimits(env["SNAPSHOT_LIMITS"])

        let services = AppServices.shared
        // Let the transcript replay, proxy, and pollers populate the store.
        RunLoop.main.run(until: Date().addingTimeInterval(8))

        let view = MenuView(store: services.store, limits: services.limits,
                            openAILimits: services.openAILimits,
                            chatGPTLimits: services.chatGPTLimits,
                            status: services.status, openAIStatus: services.openAIStatus,
                            snapshotInline: true, snapshotLimitReadings: limitFixture)
            .environment(\.colorScheme, dark ? .dark : .light)
            // ImageRenderer otherwise emits a transparent popup; alpha compositing
            // can make subtle primary-color cards opaque and hide their text in
            // image viewers. A deterministic test backdrop matches the scheme.
            .background(dark ? Color.black : Color.white)
        var flattened: CGImage?
        for _ in 0..<12 {
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            guard let rendered = renderer.cgImage else { continue }

            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
            guard let context = CGContext(data: nil, width: rendered.width, height: rendered.height,
                                          bitsPerComponent: 8, bytesPerRow: 0,
                                          space: colorSpace, bitmapInfo: bitmapInfo.rawValue) else { continue }
            context.setFillColor((dark ? NSColor.black : NSColor.white).cgColor)
            context.fill(CGRect(x: 0, y: 0, width: rendered.width, height: rendered.height))
            context.draw(rendered, in: CGRect(x: 0, y: 0,
                                              width: rendered.width, height: rendered.height))
            if (dark || darkPixelFraction(context, width: rendered.width, height: rendered.height) < 0.08),
               let candidate = context.makeImage() {
                flattened = candidate
                break
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        }
        guard let flattened,
              let png = NSBitmapImageRep(cgImage: flattened)
                .representation(using: .png, properties: [:]) else {
            print("snapshot render failed integrity check")
            exit(1)
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            print("wrote \(path)")
            exit(0)
        } catch {
            print("snapshot write failed: \(error)")
            exit(1)
        }
    }

    private static func darkPixelFraction(_ context: CGContext, width: Int, height: Int) -> Double {
        guard let raw = context.data else { return 0 }
        let bytes = raw.assumingMemoryBound(to: UInt8.self)
        let rowBytes = context.bytesPerRow
        var dark = 0
        var sampled = 0
        for y in stride(from: 0, to: height, by: 8) {
            for x in stride(from: 0, to: width, by: 8) {
                let offset = y * rowBytes + x * 4
                sampled += 1
                if bytes[offset] < 10 && bytes[offset + 1] < 10 && bytes[offset + 2] < 10 {
                    dark += 1
                }
            }
        }
        return sampled == 0 ? 0 : Double(dark) / Double(sampled)
    }

    /// `all|three|two|one|none` fixtures verify that the pinned rail closes
    /// missing-window gaps instead of reserving four hard-coded columns.
    private static func snapshotLimits(_ raw: String?) -> [LimitRailReading]? {
        guard let raw else { return nil }
        let reset = Date().addingTimeInterval(2 * 3600)
        let all = [
            LimitRailReading(id: "codex-primary", provider: .codex, period: .primary,
                             label: "Codex 5h", utilization: 78, resetsAt: reset),
            LimitRailReading(id: "codex-secondary", provider: .codex, period: .secondary,
                             label: "Codex 7d", utilization: 45, resetsAt: reset),
            LimitRailReading(id: "claude-primary", provider: .claude, period: .primary,
                             label: "Claude 5h", utilization: 34, resetsAt: reset),
            LimitRailReading(id: "claude-secondary", provider: .claude, period: .secondary,
                             label: "Claude 7d", utilization: 61, resetsAt: reset),
        ]
        switch raw.lowercased() {
        case "all": return all
        case "three": return [all[0], all[2], all[3]]
        case "two": return [all[1], all[2]]
        case "one": return [all[3]]
        case "none": return []
        default: return nil
        }
    }
}
