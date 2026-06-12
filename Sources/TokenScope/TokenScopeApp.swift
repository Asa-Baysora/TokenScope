import SwiftUI
import AppKit

final class AppServices {
    static let shared = AppServices()

    let store: UsageStore
    let watcher: TranscriptWatcher
    let proxy: OllamaProxy
    let ollamaStatus: OllamaStatusPoller
    let limits: LimitsManager
    let status: StatusManager

    private init() {
        let s = UsageStore()
        store = s
        watcher = TranscriptWatcher(store: s)
        proxy = OllamaProxy(store: s)
        ollamaStatus = OllamaStatusPoller(store: s)
        limits = LimitsManager()
        status = StatusManager()
        Notifier.requestAuthorization()
        watcher.start()
        proxy.start()
        ollamaStatus.start()
        limits.start()
        status.start()
        FileLog.log("TokenScope started")
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

struct TokenScopeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var store = AppServices.shared.store
    @StateObject private var limits = AppServices.shared.limits
    @StateObject private var status = AppServices.shared.status
    // Which fields the menu bar shows, in order: any of session,weekly,tokens.
    @AppStorage("MenuBarItems") private var menuBarItemsRaw = "tokens"

    var body: some Scene {
        MenuBarExtra {
            MenuView(store: store, limits: limits, status: status)
        } label: {
            menuBarContent
        }
        .menuBarExtraStyle(.window)
    }

    /// Menu-bar content. The colored gauge (a non-template image) carries the
    /// nearest-wall utilization and its color, since text color is forced
    /// monochrome in the status bar. Each value is prefixed with an intuitive
    /// SF Symbol — a clock for the 5-hour session, a calendar for the week — so
    /// the numbers are self-explanatory (no cryptic "5h"). Always shows the token
    /// count if nothing else is selected, so the bar is never empty.
    private var menuBarContent: some View {
        let items = menuBarItemsRaw.split(separator: ",").map(String.init)
        let showSession = items.contains("session") && limits.sessionPercent != nil
        let showWeekly = items.contains("weekly") && limits.weeklyPercent != nil
        let showTokens = items.contains("tokens") || (!showSession && !showWeekly)
        return HStack(spacing: 5) {
            Image(nsImage: MenuBarGauge.image(fraction: gaugeFraction))
            if showSession, let p = limits.sessionPercent {
                Label("\(p)%", systemImage: "clock")
                    .labelStyle(.titleAndIcon)
            }
            if showWeekly, let p = limits.weeklyPercent {
                Label("\(p)%", systemImage: "calendar")
                    .labelStyle(.titleAndIcon)
            }
            if showTokens {
                Text(store.menuTitle)
            }
        }
        .imageScale(.small)
        .monospacedDigit()
    }

    /// What the gauge fill/needle and color represent: the nearest rate-limit
    /// wall (max of session/weekly) when connected; empty when not.
    private var gaugeFraction: Double? {
        guard limits.connected, let peak = limits.peakPercent else { return nil }
        return Double(peak) / 100
    }
}

@main
enum Main {
    static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), args.indices.contains(i + 1) {
            MainActor.assumeIsolated { Snapshot.run(path: args[i + 1]) }
        } else if let i = args.firstIndex(of: "--gauges"), args.indices.contains(i + 1) {
            dumpGauges(dir: args[i + 1])
        } else {
            TokenScopeApp.main()
        }
    }

    /// Renders the menu-bar gauge at representative levels into <dir>/gauge-NN.png
    /// (and a "not connected" one) so the drawing + gradient can be eyeballed
    /// without the un-screenshottable status bar.
    private static func dumpGauges(dir: String) {
        let levels: [Double?] = [nil, 0.10, 0.50, 0.77, 0.83, 0.88, 0.96]
        for f in levels {
            let img = MenuBarGauge.image(fraction: f)
            // Upscale 8× on a dark backdrop so the small icon is inspectable.
            let scale: CGFloat = 8
            let out = NSImage(size: NSSize(width: img.size.width * scale, height: img.size.height * scale))
            out.lockFocus()
            NSColor(white: 0.12, alpha: 1).setFill()
            NSRect(origin: .zero, size: out.size).fill()
            img.draw(in: NSRect(origin: .zero, size: out.size))
            out.unlockFocus()
            let name = f.map { "gauge-\(Int($0 * 100)).png" } ?? "gauge-none.png"
            if let tiff = out.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
            }
        }
        print("wrote gauges to \(dir)")
    }
}
