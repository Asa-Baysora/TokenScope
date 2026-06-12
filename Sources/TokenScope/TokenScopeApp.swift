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
            HStack(spacing: 3) {
                // Gauge tints to the nearest-wall limit color when claude.ai is
                // connected, else to the service-status color; plain otherwise.
                Image(systemName: "gauge.with.needle")
                    .foregroundStyle(menuTint)
                menuBarLabel.monospacedDigit()
            }
        }
        .menuBarExtraStyle(.window)
    }

    /// Composes the menu-bar text from the chosen fields. Each limit % is colored
    /// green/yellow/red by the same thresholds the rest of the app uses; the token
    /// count stays primary (and becomes a live ↓ counter mid-stream). Falls back
    /// to the token count if nothing else is available, so the bar is never empty.
    private var menuBarLabel: Text {
        let items = menuBarItemsRaw.split(separator: ",").map(String.init)
        var segs: [Text] = []
        if items.contains("session"), let p = limits.sessionPercent {
            segs.append(Text("5h \(p)%").foregroundColor(LimitsManager.color(forPercent: Double(p))))
        }
        if items.contains("weekly"), let p = limits.weeklyPercent {
            segs.append(Text("wk \(p)%").foregroundColor(LimitsManager.color(forPercent: Double(p))))
        }
        if items.contains("tokens") || segs.isEmpty {
            segs.append(Text(store.menuTitle).foregroundColor(.primary))
        }
        var out = Text("")
        for (i, seg) in segs.enumerated() {
            out = i == 0 ? seg : out + Text("  ") + seg
        }
        return out
    }

    private var menuTint: Color {
        if let c = limits.menuColor { return c }
        if !status.allOperational { return status.color }
        return .primary
    }
}

@main
enum Main {
    static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), args.indices.contains(i + 1) {
            MainActor.assumeIsolated { Snapshot.run(path: args[i + 1]) }
        } else {
            TokenScopeApp.main()
        }
    }
}
