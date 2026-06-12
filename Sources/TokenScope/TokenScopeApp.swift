import SwiftUI
import AppKit

final class AppServices {
    static let shared = AppServices()

    let store: UsageStore
    let watcher: TranscriptWatcher
    let proxy: OllamaProxy
    let ollamaStatus: OllamaStatusPoller

    private init() {
        let s = UsageStore()
        store = s
        watcher = TranscriptWatcher(store: s)
        proxy = OllamaProxy(store: s)
        ollamaStatus = OllamaStatusPoller(store: s)
        watcher.start()
        proxy.start()
        ollamaStatus.start()
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

    var body: some Scene {
        MenuBarExtra {
            MenuView(store: store)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "gauge.with.needle")
                Text(store.menuTitle).monospacedDigit()
            }
        }
        .menuBarExtraStyle(.window)
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
