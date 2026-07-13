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

        let services = AppServices.shared
        // Let the transcript replay, proxy, and pollers populate the store.
        RunLoop.main.run(until: Date().addingTimeInterval(8))

        let view = MenuView(store: services.store, limits: services.limits,
                            openAILimits: services.openAILimits,
                            chatGPTLimits: services.chatGPTLimits,
                            status: services.status, openAIStatus: services.openAIStatus,
                            snapshotInline: true)
            .environment(\.colorScheme, dark ? .dark : .light)
            // ImageRenderer otherwise emits a transparent popup; alpha compositing
            // can make subtle primary-color cards opaque and hide their text in
            // image viewers. A deterministic test backdrop matches the scheme.
            .background(dark ? Color.black : Color.white)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let img = renderer.nsImage,
              let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            print("snapshot render failed")
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
}
