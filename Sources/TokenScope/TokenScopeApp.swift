import SwiftUI
import AppKit

final class AppServices {
    static let shared = AppServices()

    let store: UsageStore
    let watcher: TranscriptWatcher
    let codexWatcher: CodexTranscriptWatcher
    let proxy: OllamaProxy
    let ollamaStatus: OllamaStatusPoller
    let limits: LimitsManager
    let openAILimits: OpenAILimitsManager
    let chatGPTLimits: ChatGPTLimitsManager
    let status: StatusManager
    let openAIStatus: StatusManager
    let appearance: AppearanceWatcher
    let palette = ProviderPalette.shared

    private init() {
        let s = UsageStore()
        store = s
        watcher = TranscriptWatcher(store: s)
        openAILimits = OpenAILimitsManager()
        codexWatcher = CodexTranscriptWatcher(store: s, limits: openAILimits)
        proxy = OllamaProxy(store: s)
        ollamaStatus = OllamaStatusPoller(store: s)
        limits = LimitsManager()
        chatGPTLimits = ChatGPTLimitsManager()
        status = StatusManager()
        openAIStatus = StatusManager(service: .openAI)
        appearance = AppearanceWatcher()
        Notifier.requestAuthorization()
        watcher.start()
        codexWatcher.start()
        proxy.start()
        ollamaStatus.start()
        limits.start()
        chatGPTLimits.start()
        status.start()
        openAIStatus.start()
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
    @StateObject private var openAILimits = AppServices.shared.openAILimits
    @StateObject private var chatGPTLimits = AppServices.shared.chatGPTLimits
    @StateObject private var status = AppServices.shared.status
    @StateObject private var openAIStatus = AppServices.shared.openAIStatus
    @StateObject private var appearance = AppServices.shared.appearance
    // Observed so a provider-color edit re-runs body and rebuilds the menu-bar
    // bitmap (its brand marks read the palette) — same mechanism as `appearance`.
    @StateObject private var palette = AppServices.shared.palette
    // Which fields the menu bar shows: any Claude/Codex limit window plus tokens.
    @AppStorage("MenuBarItems") private var menuBarItemsRaw = "tokens"

    var body: some Scene {
        MenuBarExtra {
            MenuView(store: store, limits: limits, openAILimits: openAILimits,
                     chatGPTLimits: chatGPTLimits, status: status, openAIStatus: openAIStatus)
        } label: {
            // ONE image — the menu bar reliably renders a single Image but drops
            // elements from a multi-part label and strips text color.
            Image(nsImage: menuBarImage)
        }
        .menuBarExtraStyle(.window)
    }

    /// Composited menu-bar bitmap: a labeled colored gauge per selected limit
    /// window (5h session, 7d weekly), plus the daily token count. Each gauge
    /// fills/colors to ITS OWN utilization. Always shows tokens if nothing else
    /// resolves, so the bar is never empty.
    private var menuBarImage: NSImage {
        // The persisted item ids keep the legacy "chatgpt*" spelling (renaming
        // them would silently reset users' menu-bar choices); everything in-memory
        // uses the Codex domain.
        let items = Set(menuBarItemsRaw.split(separator: ",").map(String.init))
        var gauges: [MenuBarRender.Gauge] = []
        if items.contains("session"), let p = limits.sessionPercent {
            gauges.append(.init(origin: .claudeCode, period: "5h", pct: p))
        }
        if items.contains("weekly"), let p = limits.weeklyPercent {
            gauges.append(.init(origin: .claudeCode, period: "7d", pct: p))
        }
        if items.contains("chatgptPrimary"), let p = openAILimits.primaryPercent {
            gauges.append(.init(origin: .codex, period: openAILimits.primaryDuration ?? "", pct: p))
        }
        if items.contains("chatgptSecondary"), let p = openAILimits.secondaryPercent {
            gauges.append(.init(origin: .codex, period: openAILimits.secondaryDuration ?? "", pct: p))
        }
        let wantTokens = items.contains("tokens") || gauges.isEmpty
        return MenuBarRender.image(
            gauges: gauges,
            tokens: wantTokens ? store.menuTitle : nil,
            dark: appearance.dark)
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
        } else if let i = args.firstIndex(of: "--menubar"), args.indices.contains(i + 1) {
            MainActor.assumeIsolated { dumpMenuBar(path: args[i + 1]) }
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

    /// Renders the composited menu-bar label (session + weekly gauges + tokens)
    /// onto a dark backdrop so the actual bar content can be eyeballed offline.
    @MainActor
    private static func dumpMenuBar(path: String) {
        // Several selections stacked, to verify separators and the both-on labels.
        let cases: [NSImage] = [
            MenuBarRender.image(gauges: [.init(origin: .claudeCode, period: "5h", pct: 28)], tokens: nil, dark: true),
            MenuBarRender.image(gauges: [.init(origin: .claudeCode, period: "5h", pct: 28)], tokens: "2.85M", dark: true),
            MenuBarRender.image(gauges: [
                .init(origin: .claudeCode, period: "5h", pct: 28),
                .init(origin: .claudeCode, period: "7d", pct: 21),
                .init(origin: .codex, period: "5h", pct: 48),
                .init(origin: .codex, period: "7d", pct: 7),
            ], tokens: "2.85M", dark: true),
        ]
        let scale: CGFloat = 6
        let rowH = (cases.map(\.size.height).max() ?? 16) * scale
        let width = (cases.map(\.size.width).max() ?? 100) * scale
        let gap: CGFloat = 10
        let out = NSImage(size: NSSize(width: width, height: rowH * CGFloat(cases.count) + gap * CGFloat(cases.count + 1)))
        out.lockFocus()
        NSColor(white: 0.13, alpha: 1).setFill()
        NSRect(origin: .zero, size: out.size).fill()
        for (i, label) in cases.enumerated() {
            let y = gap + (rowH + gap) * CGFloat(cases.count - 1 - i)
            label.draw(in: NSRect(x: gap, y: y, width: label.size.width * scale, height: rowH))
        }
        out.unlockFocus()
        if let tiff = out.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
        print("wrote menubar mock to \(path)")
    }
}
