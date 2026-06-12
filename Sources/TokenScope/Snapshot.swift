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
        if let t = env["SNAPSHOT_TAB"] { UserDefaults.standard.set(t, forKey: "ActiveTab") }

        let services = AppServices.shared
        // Let the transcript replay, proxy, and pollers populate the store.
        RunLoop.main.run(until: Date().addingTimeInterval(8))

        let view = MenuView(store: services.store, limits: services.limits, status: services.status, snapshotInline: true)
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
